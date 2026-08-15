part of 'session_controller.dart';

extension SessionPreview on SessionController {
  /// 按当前接缝配置生成完整长图预览。
  Future<void> refreshPreview() {
    late final Future<void> run;
    run = _refreshPreview();
    _previewRuns.add(run);
    return run.whenComplete(() {
      _previewRuns.remove(run);
    });
  }

  Future<void> _refreshPreview() async {
    final cacheRun = _cacheRun;
    if (cacheRun != null) await cacheRun;
    final version = ++_previewVersion;
    if (_images.isEmpty) {
      _previewPath = null;
      _previewError = null;
      _notifyStateChanged();
      return;
    }
    if (_bridge == null) {
      _previewPath = null;
      _previewError = 'Rust 原生引擎未加载，无法生成拼接预览';
      _notifyStateChanged();
      return;
    }
    if (!hasCompleteAnalysis) {
      _previewPath = null;
      _previewError = '等待所有截图接缝分析完成';
      _notifyStateChanged();
      return;
    }

    final path = store.previewPath(version);
    _previewing = true;
    _previewError = null;
    _notifyStateChanged();
    try {
      await runComposeInIsolate(
        buildComposeRequest(
          images: _images,
          seams: _seams,
          settings: exportSettings,
          outPath: path,
          format: ExportFormat.png,
          scalePercent: 100,
        ),
      );
      if (version != _previewVersion) {
        await store.deleteFile(path);
        return;
      }
      final previous = _previewPath;
      _previewPath = path;
      if (previous != null && previous != path) {
        await store.deleteFile(previous);
      }
    } catch (e) {
      if (version == _previewVersion) {
        _previewPath = null;
        _previewError = '拼接预览失败: $e';
      }
    } finally {
      if (version == _previewVersion) {
        _previewing = false;
        _notifyStateChanged();
      }
    }
  }
}
