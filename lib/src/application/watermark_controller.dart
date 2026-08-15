/// 隐私保护水印会话状态。
library;

import 'package:flutter/foundation.dart';
import 'package:pixelforge/src/application/watermark_renderer.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/storage/watermark_store.dart';

const defaultWatermarkText = '仅供XX办理使用';

class WatermarkController extends ChangeNotifier {
  WatermarkController({required this.store});

  final WatermarkStore store;

  String? _imagePath;
  ImageSize? _imageSize;
  var _text = defaultWatermarkText;
  var _exporting = false;
  Future<void>? _exportRun;
  Future<int>? _cacheRun;
  var _operationToken = 0;
  String? _error;

  String? get imagePath => _imagePath;
  ImageSize? get imageSize => _imageSize;
  String get text => _text;
  bool get exporting => _exporting;
  String? get error => _error;

  Future<void> importImage(String sourcePath) async {
    final token = ++_operationToken;
    final exportRun = _exportRun;
    if (exportRun != null) await exportRun;
    if (token != _operationToken) return;
    final previousPath = _takeCurrentImage();
    String? importedPath;
    try {
      if (previousPath != null) await store.deleteFile(previousPath);
      if (token != _operationToken) return;
      importedPath = await store.importFile(sourcePath);
      final size = await store.readSize(importedPath);
      if (token != _operationToken) {
        return;
      }
      if (size.width <= 0 || size.height <= 0) {
        throw const FormatException('无法读取图片尺寸');
      }
      _imagePath = importedPath;
      importedPath = null;
      _imageSize = size;
      _error = null;
      notifyListeners();
    } catch (error) {
      if (token != _operationToken) return;
      _imagePath = null;
      _imageSize = null;
      _error = '导入图片失败：$error';
      notifyListeners();
    } finally {
      if (importedPath != null) await store.deleteFile(importedPath);
    }
  }

  void setText(String text) {
    if (_text == text) return;
    _text = text;
    notifyListeners();
  }

  String exportPath(String fileName) => store.exportPath(fileName);

  Future<bool> exportNow({required String outPath}) async {
    final cacheRun = _cacheRun;
    if (cacheRun != null) await cacheRun;
    final running = _exportRun;
    if (running != null) {
      await running;
      return false;
    }
    final run = _performExport(outPath: outPath);
    late final Future<void> tracked;
    tracked = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _exportRun = tracked;
    try {
      return await run;
    } finally {
      if (identical(_exportRun, tracked)) _exportRun = null;
    }
  }

  Future<bool> _performExport({required String outPath}) async {
    final source = _imagePath;
    if (source == null) {
      _error = '请先选择图片';
      notifyListeners();
      return false;
    }
    if (_text.trim().isEmpty) {
      _error = '请输入水印文字';
      notifyListeners();
      return false;
    }
    _exporting = true;
    _error = null;
    notifyListeners();
    try {
      await store.ensureExportDirectory();
      await WatermarkRenderer.render(
        sourcePath: source,
        text: _text,
        outPath: outPath,
      );
      return true;
    } catch (error) {
      _error = '生成水印图片失败：$error';
      return false;
    } finally {
      _exporting = false;
      notifyListeners();
    }
  }

  Future<int> cacheSize() => store.cacheSize();

  Future<int> clearCache() async {
    final running = _cacheRun;
    if (running != null) return running;
    final run = _clearCache(_exportRun);
    _cacheRun = run;
    try {
      return await run;
    } finally {
      if (identical(_cacheRun, run)) _cacheRun = null;
    }
  }

  Future<int> _clearCache(Future<void>? exportRun) async {
    if (exportRun != null) await exportRun;
    return store.clearCache();
  }

  Future<void> clear() async {
    final token = ++_operationToken;
    final previousPath = _takeCurrentImage();
    final exportRun = _exportRun;
    _exporting = false;
    _imageSize = null;
    _error = null;
    notifyListeners();
    try {
      if (exportRun != null) await exportRun;
      if (previousPath != null) await store.deleteFile(previousPath);
    } catch (error) {
      _error = '清理图片失败：$error';
      notifyListeners();
      rethrow;
    }
    if (token == _operationToken) notifyListeners();
  }

  String? _takeCurrentImage() {
    final path = _imagePath;
    _imagePath = null;
    return path;
  }
}
