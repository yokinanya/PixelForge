/// 会话状态机：图片列表、接缝分析与导出配置。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pixelforge/src/application/compose_request_builder.dart';
import 'package:pixelforge/src/application/session_models.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/ffi/rust_bridge.dart';
import 'package:pixelforge/src/infrastructure/storage/temp_store.dart';

part 'session_preview.dart';
part 'session_layout.dart';
part 'session_seam_adjustment.dart';

const _analysisWorkerCount = 2;

/// 会话状态。
class SessionController extends ChangeNotifier {
  SessionController({required this.store, RustBridge? bridge})
    : _bridge = bridge ?? RustBridge.instance();

  final TempStore store;
  final RustBridge? _bridge;

  final List<SessionImage> _images = [];
  final List<SeamState?> _seams = []; // 长度 = images.length - 1

  ExportSettings exportSettings = ExportSettings();

  /// 分析进行中的相邻下标集合。
  final Set<String> _analyzing = {};
  int _analysisGeneration = 0;
  Future<void>? _analysisRun;
  Future<void>? _exportRun;
  Future<int>? _cacheRun;
  bool _exporting = false;
  bool _previewing = false;
  final Set<Future<void>> _previewRuns = {};
  int _previewVersion = 0;
  String? _previewPath;
  String? _previewError;
  String? _exportProgress;
  String? _lastError;

  List<SessionImage> get images => List.unmodifiable(_images);
  List<SeamState?> get seams => List.unmodifiable(_seams);
  bool get analyzing => _analyzing.isNotEmpty;
  bool get exporting => _exporting;
  bool get previewing => _previewing;
  String? get previewPath => _previewPath;
  String? get previewError => _previewError;
  String? get exportProgress => _exportProgress;
  String? get lastError => _lastError;

  void _notifyStateChanged() => notifyListeners();
  bool get bridgeAvailable => _bridge != null;

  /// 是否还有未分析的相邻对。
  bool get hasPendingAnalysis {
    for (final s in _seams) {
      if (s == null) return true;
    }
    return false;
  }

  /// 有多少接缝需要人工确认（低置信或不可信）。
  int get needsAttentionCount => _seams.where((s) {
    if (s == null) return true;
    return !s.analysis.plausible || s.analysis.confidence < 0.3;
  }).length;

  /// 当前图片是否都有可用于合成的接缝结果。
  bool get hasCompleteAnalysis =>
      _images.isNotEmpty &&
      _seams.length == _images.length - 1 &&
      _seams.every((s) => s != null);

  /// 添加多张图片（按选择顺序），等待用户手动分析。
  Future<void> addImages(List<String> paths) async {
    if (paths.isEmpty) return;
    _analysisGeneration++;
    final importedPaths = <String>[];
    try {
      for (final p in paths) {
        if (_images.any((i) => i.path == p)) continue;
        final dest = await store.importFile(p, _images.length);
        try {
          final size = await store.readSize(dest);
          if (_images.isNotEmpty && size.width != _images.first.size.width) {
            throw FormatException(
              '截图宽度必须一致：期望 ${_images.first.size.width}px，实际 ${size.width}px',
            );
          }
          _images.add(SessionImage(path: dest, size: size));
          importedPaths.add(dest);
        } catch (_) {
          await store.deleteFile(dest);
          rethrow;
        }
      }
    } catch (error) {
      for (final path in importedPaths) {
        _images.removeWhere((image) => image.path == path);
        await store.deleteFile(path);
      }
      _syncSeamList();
      _lastError = '导入图片失败：$error';
      notifyListeners();
      rethrow;
    }
    _syncSeamList();
    _lastError = null;
    _invalidatePreview('截图已导入，请点击“下一步”');
    notifyListeners();
  }

  void _syncSeamList() {
    while (_seams.length < _images.length - 1) {
      _seams.add(null);
    }
    if (_seams.length > _images.length - 1) {
      _seams.removeRange(_images.length - 1, _seams.length);
    }
  }

  /// 删除一张图片，等待用户手动重新分析。
  Future<void> removeImage(int index) async {
    if (index < 0 || index >= _images.length) return;
    _analysisGeneration++;
    final analysisRun = _analysisRun;
    final exportRun = _exportRun;
    final previewRun = Future.wait(_previewRuns.toList(growable: false));
    final removed = _images.removeAt(index);
    _seams.clear();
    _syncSeamList();
    _lastError = null;
    _invalidatePreview('截图已删除，请点击“下一步”');
    notifyListeners();
    if (analysisRun != null) await analysisRun;
    if (exportRun != null) await exportRun;
    await previewRun;
    await store.deleteFile(removed.path);
  }

  /// 移动图片（拖拽排序），等待用户手动重新计算。
  Future<void> moveImage(int from, int to) async {
    if (from < 0 || to < 0 || from >= _images.length || to >= _images.length) {
      return;
    }
    _analysisGeneration++;
    final img = _images.removeAt(from);
    _images.insert(to, img);
    _seams.clear();
    _syncSeamList();
    _lastError = null;
    _invalidatePreview('顺序已调整，请点击“下一步”');
    notifyListeners();
  }

  /// 手动触发全部接缝分析和完整预览生成。
  Future<void> recalculateStitch() async {
    if (_images.isEmpty || analyzing || _analysisRun != null) return;
    _lastError = null;
    _previewError = null;
    notifyListeners();
    await analyzeAll();
    if (hasCompleteAnalysis) await refreshPreview();
  }

  void _invalidatePreview(String message) {
    _previewVersion++;
    final previous = _previewPath;
    _previewPath = null;
    _previewError = message;
    if (previous != null) unawaited(store.deleteFile(previous));
  }

  /// 清空会话。
  Future<void> clearAll() async {
    _analysisGeneration++;
    final analysisRun = _analysisRun;
    final exportRun = _exportRun;
    final previewRun = Future.wait(_previewRuns.toList(growable: false));
    _images.clear();
    _seams.clear();
    _analyzing.clear();
    _previewVersion++;
    _previewPath = null;
    _previewError = null;
    _lastError = null;
    notifyListeners();
    if (analysisRun != null) await analysisRun;
    if (exportRun != null) await exportRun;
    await previewRun;
    await store.clear();
    notifyListeners();
  }

  /// 清理应用缓存，不删除当前会话中的导入图片。
  Future<int> clearCache() async {
    final running = _cacheRun;
    if (running != null) return running;
    final run = _performClearCache();
    _cacheRun = run;
    try {
      return await run;
    } finally {
      if (identical(_cacheRun, run)) _cacheRun = null;
    }
  }

  Future<int> _performClearCache() async {
    final hadPreview = _previewPath != null || _previewRuns.isNotEmpty;
    _previewVersion++;
    _previewPath = null;
    _previewing = false;
    final previewRun = Future.wait(_previewRuns.toList(growable: false));
    final exportRun = _exportRun;
    notifyListeners();
    if (exportRun != null) await exportRun;
    await previewRun;
    final bytes = await store.clearCache();
    if (hadPreview) _previewError = '预览缓存已清理，请重新生成';
    notifyListeners();
    return bytes;
  }

  Future<int> cacheSize() => store.cacheSize();

  /// 分析所有相邻对（并发）。
  Future<void> analyzeAll() async {
    while (true) {
      final running = _analysisRun;
      if (running != null) {
        await running;
        continue;
      }
      final generation = _analysisGeneration;
      final run = _runAnalyzeAll(generation);
      late final Future<void> tracked;
      tracked = run.whenComplete(() {
        if (identical(_analysisRun, tracked)) _analysisRun = null;
      });
      _analysisRun = tracked;
      await tracked;
      if (generation == _analysisGeneration) return;
    }
  }

  Future<void> _runAnalyzeAll(int generation) async {
    if (_bridge == null) {
      _lastError = 'Rust 原生引擎未加载';
      notifyListeners();
      return;
    }
    final pending = [
      for (var i = 0; i < _images.length - 1; i++)
        if (_seams[i] == null) i,
    ];
    if (pending.isEmpty) return;
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < pending.length) {
        final index = pending[cursor++];
        await _analyzePair(index, generation);
      }
    }

    final workerCount = math.min(_analysisWorkerCount, pending.length);
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
  }

  Future<void> _analyzePair(int i, int generation) async {
    if (_bridge == null || generation != _analysisGeneration) return;
    if (i < 0 || i >= _images.length - 1) return;
    final top = _images[i];
    final bottom = _images[i + 1];
    final taskKey = '$generation:$i';
    _analyzing.add(taskKey);
    notifyListeners();
    try {
      final analysis = await runAnalyzePairInIsolate(top.path, bottom.path);
      final stillCurrent =
          generation == _analysisGeneration &&
          i < _images.length - 1 &&
          identical(_images[i], top) &&
          identical(_images[i + 1], bottom);
      if (stillCurrent) _seams[i] = SeamState(analysis: analysis);
    } catch (e) {
      if (generation == _analysisGeneration) {
        _lastError = '分析第 ${i + 1}-${i + 2} 张失败: $e';
      }
    } finally {
      _analyzing.remove(taskKey);
      notifyListeners();
    }
  }

  /// 设置固定区域高度（供导出使用）。
  int? topBarHeight(int pairIndex) => _seams[pairIndex]?.analysis.topBar?.h;

  int? bottomBarHeight(int pairIndex) =>
      _seams[pairIndex]?.analysis.bottomBar?.h;

  /// 组装并执行导出。成功返回 true。
  Future<bool> exportNow({
    required String outPath,
    required String outFormat,
  }) async {
    final cacheRun = _cacheRun;
    if (cacheRun != null) await cacheRun;
    final running = _exportRun;
    if (running != null) {
      await running;
      return false;
    }
    final run = _performExport(outPath: outPath, outFormat: outFormat);
    late final Future<void> tracked;
    tracked = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _exportRun = tracked;
    try {
      return await run;
    } finally {
      if (identical(_exportRun, tracked)) _exportRun = null;
    }
  }

  Future<bool> _performExport({
    required String outPath,
    required String outFormat,
  }) async {
    if (_bridge == null) {
      _lastError = 'Rust 原生引擎未加载';
      notifyListeners();
      return false;
    }
    if (!hasCompleteAnalysis) {
      _lastError = '仍有截图接缝未完成分析，无法导出';
      notifyListeners();
      return false;
    }
    final generation = _analysisGeneration;
    final images = List<SessionImage>.of(_images);
    final seams = List<SeamState?>.of(_seams);
    final format = switch (outFormat) {
      'jpeg' => ExportFormat.jpeg,
      'webp' => ExportFormat.webp,
      'png' => ExportFormat.png,
      _ => null,
    };
    if (format == null) {
      _lastError = '不支持的导出格式：$outFormat';
      notifyListeners();
      return false;
    }
    _exporting = true;
    _lastError = null;
    notifyListeners();
    try {
      final request = buildComposeRequest(
        images: images,
        seams: seams,
        settings: exportSettings,
        outPath: outPath,
        format: format,
        scalePercent: exportSettings.scalePercent,
      );
      await runComposeInIsolate(request);
      if (generation != _analysisGeneration) {
        await store.deleteFile(outPath);
        _lastError = '会话已改变，已丢弃本次导出结果';
        return false;
      }
      return true;
    } catch (e) {
      _lastError = '导出失败: $e';
      return false;
    } finally {
      _exporting = false;
      notifyListeners();
    }
  }

  /// 更新预览裁切与导出设置（格式、质量）。
  void applyExportSettings({
    required ExportFormat format,
    required int jpegQuality,
    int? scalePercent,
    required bool removeStatusBar,
    required bool trimBottomWhitespace,
    required int retainedBottomEdge,
    bool refreshPreview = true,
  }) {
    exportSettings.format = format;
    exportSettings.jpegQuality = jpegQuality;
    exportSettings.scalePercent = scalePercent ?? exportSettings.scalePercent;
    exportSettings.removeStatusBar = removeStatusBar;
    exportSettings.trimBottomWhitespace = trimBottomWhitespace;
    exportSettings.retainedBottomEdge = retainedBottomEdge;
    notifyListeners();
    if (refreshPreview) unawaited(this.refreshPreview());
  }
}
