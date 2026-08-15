/// Rust 核心引擎的 C FFI 绑定。
///
/// 所有跨边界数据都以 JSON 字符串传递；像素缓冲永远不跨越 FFI（只传
/// 文件路径与接缝）。返回的字符串必须用 [freeString] 释放。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'package:pixelforge/src/domain/models.dart';

// 原生签名（NativeType）与 Dart 签名（int/void）分开声明。
typedef _NativeAnalyzePair =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
    );
typedef _DartAnalyzePair =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Utf8>>,
    );

typedef _NativeCompose = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _DartCompose = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);

typedef _NativeRedact = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _DartRedact = int Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);

typedef _NativeFreeString = Void Function(Pointer<Utf8>);
typedef _DartFreeString = void Function(Pointer<Utf8>);

/// 底层 FFI 调用封装。
///
/// [DynamicLibrary] 延迟加载：桌面/测试环境没有原生库时抛出
/// [RustBridgeUnavailable]，由调用方降级处理。
class RustBridge {
  RustBridge._(this._lib);

  static RustBridge? _instance;
  static String? _lastLoadError;

  static String? get lastLoadError => _lastLoadError;

  /// 获取单例；原生库缺失时返回 null。
  static RustBridge? instance() {
    if (_instance != null) return _instance;
    try {
      final lib = _loadLibrary();
      _instance = RustBridge._(lib);
      _lastLoadError = null;
      return _instance;
    } catch (error, stack) {
      _lastLoadError = error.toString();
      debugPrint('Rust 原生引擎加载失败: $error');
      debugPrintStack(stackTrace: stack);
      return null;
    }
  }

  static DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libstitch_bridge.so');
    }
    if (Platform.isIOS) {
      return DynamicLibrary.process();
    }
    // 开发/测试环境：优先当前目录下的本地动态库。
    return DynamicLibrary.open('libstitch_bridge.so');
  }

  final DynamicLibrary _lib;

  late final _DartAnalyzePair _analyzePair = _lib
      .lookupFunction<_NativeAnalyzePair, _DartAnalyzePair>(
        'stitch_analyze_pair',
      );
  late final _DartCompose _compose = _lib
      .lookupFunction<_NativeCompose, _DartCompose>('stitch_compose');
  late final _DartRedact _redact = _lib
      .lookupFunction<_NativeRedact, _DartRedact>('stitch_redact');
  late final _DartFreeString _freeString = _lib
      .lookupFunction<_NativeFreeString, _DartFreeString>('stitch_free_string');

  void _free(Pointer<Utf8>? ptr) {
    if (ptr != null && ptr != nullptr) {
      _freeString(ptr);
    }
  }

  String _callJson(int Function(Pointer<Pointer<Utf8>>) invoke) {
    final out = calloc<Pointer<Utf8>>();
    Pointer<Utf8>? resultPointer;
    try {
      final code = invoke(out);
      resultPointer = out.value;
      if (resultPointer == nullptr) {
        throw RustBridgeException('原生调用未返回结果（错误码 $code）');
      }
      final json = resultPointer.toDartString();
      final decoded = jsonDecode(json);
      final ok = decoded is Map<String, dynamic> && decoded['ok'] == true;
      if (code != 0 || !ok) {
        throw RustBridgeException(
          decoded is Map<String, dynamic>
              ? decoded['error'] as String? ?? '未知错误（错误码 $code）'
              : '原生响应格式无效（错误码 $code）',
        );
      }
      return json;
    } finally {
      _free(resultPointer);
      calloc.free(out);
    }
  }

  /// 分析一对相邻截图，返回 JSON 字符串（调用方解析）。
  String analyzePairRaw(String topPath, String bottomPath) {
    final top = topPath.toNativeUtf8();
    final bottom = bottomPath.toNativeUtf8();
    final opts = '{}'.toNativeUtf8();
    try {
      return _callJson((out) => _analyzePair(top, bottom, opts, out));
    } finally {
      calloc.free(top);
      calloc.free(bottom);
      calloc.free(opts);
    }
  }

  /// 分析一对相邻截图并解析为 [PairAnalysis]。
  PairAnalysis analyzePair(String topPath, String bottomPath) {
    final json = analyzePairRaw(topPath, bottomPath);
    final decoded = jsonDecode(json);
    return PairAnalysis.fromJson(decoded['data'] as Map<String, dynamic>);
  }

  /// 合成导出，返回输出尺寸。
  Future<(int, int)> compose(ComposeRequest request) async {
    final payload = jsonEncode(request.toJson());
    final req = payload.toNativeUtf8();
    try {
      final json = _callJson((out) => _compose(req, out));
      final decoded = jsonDecode(json);
      final data = decoded['data'] as Map<String, dynamic>;
      return ((data['width'] as num).toInt(), (data['height'] as num).toInt());
    } finally {
      calloc.free(req);
    }
  }

  /// Apply opaque redaction masks and return the output size.
  Future<(int, int)> redact(RedactionRequest request) async {
    final payload = jsonEncode(request.toJson());
    final req = payload.toNativeUtf8();
    try {
      final json = _callJson((out) => _redact(req, out));
      final decoded = jsonDecode(json);
      final data = decoded['data'] as Map<String, dynamic>;
      return ((data['width'] as num).toInt(), (data['height'] as num).toInt());
    } finally {
      calloc.free(req);
    }
  }
}

/// 原生库不可用（桌面开发 / 测试环境）。
class RustBridgeUnavailable implements Exception {
  @override
  String toString() => 'Rust 原生库未加载';
}

/// FFI 调用失败。
class RustBridgeException implements Exception {
  RustBridgeException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 合成导出请求（JSON 序列化）。
class ComposeRequest {
  ComposeRequest({
    required this.paths,
    required this.seams,
    required this.topBars,
    required this.bottomBars,
    required this.lastBottomWhitespace,
    required this.removeFirstStatusBar,
    required this.trimLastBottomWhitespace,
    required this.retainedBottomEdge,
    required this.format,
    required this.quality,
    required this.scalePercent,
    required this.outPath,
  });

  final List<String> paths;
  final List<({int dx, int dy})> seams;
  final List<int> topBars;
  final List<int> bottomBars;
  final int lastBottomWhitespace;
  final bool removeFirstStatusBar;
  final bool trimLastBottomWhitespace;
  final int retainedBottomEdge;
  final ExportFormat format;
  final int quality;
  final int scalePercent;
  final String outPath;

  Map<String, dynamic> toJson() => {
    'paths': paths,
    'seams': [
      for (final s in seams) {'dx': s.dx, 'dy': s.dy},
    ],
    'top_bars': topBars,
    'bottom_bars': bottomBars,
    'last_bottom_whitespace': lastBottomWhitespace,
    'remove_first_status_bar': removeFirstStatusBar,
    'trim_last_bottom_whitespace': trimLastBottomWhitespace,
    'retained_bottom_edge': retainedBottomEdge,
    'format': format.rustName,
    'quality': quality,
    'scale_percent': scalePercent,
    'out_path': outPath,
  };
}

class RedactionRequest {
  RedactionRequest({
    required this.sourcePath,
    required this.masks,
    required this.format,
    required this.quality,
    required this.outPath,
  });

  final String sourcePath;
  final List<Map<String, dynamic>> masks;
  final ExportFormat format;
  final int quality;
  final String outPath;

  Map<String, dynamic> toJson() => {
    'source_path': sourcePath,
    'masks': masks,
    'format': format.rustName,
    'quality': quality,
    'out_path': outPath,
  };
}

/// 在 isolate 中运行 FFI 调用，避免阻塞 UI 线程。
Future<PairAnalysis> runAnalyzePairInIsolate(
  String topPath,
  String bottomPath,
) {
  return Isolate.run(() {
    final bridge = RustBridge.instance();
    if (bridge == null) {
      throw RustBridgeUnavailable();
    }
    return bridge.analyzePair(topPath, bottomPath);
  });
}

/// 在 isolate 中运行合成导出。
Future<(int, int)> runComposeInIsolate(ComposeRequest request) {
  return Isolate.run(() async {
    final bridge = RustBridge.instance();
    if (bridge == null) {
      throw RustBridgeUnavailable();
    }
    return bridge.compose(request);
  });
}

/// 在 isolate 中运行打码导出。
Future<(int, int)> runRedactionInIsolate(RedactionRequest request) {
  return Isolate.run(() async {
    final bridge = RustBridge.instance();
    if (bridge == null) {
      throw RustBridgeUnavailable();
    }
    return bridge.redact(request);
  });
}
