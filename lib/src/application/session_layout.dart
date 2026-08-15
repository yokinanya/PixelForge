part of 'session_controller.dart';

/// 与 Rust 合成器保持一致的预览布局信息。
extension SessionLayout on SessionController {
  ImageSize? get previewSize {
    if (!hasCompleteAnalysis) return null;
    final offsets = _previewOffsets();
    if (offsets.isEmpty) return null;
    final last = _images.length - 1;
    final height =
        offsets.last +
        _images[last].size.height -
        _cropTop(last) -
        _cropBottom(last) +
        _bottomBar(last);
    return ImageSize(_images.first.size.width, height);
  }

  /// 每个后续截图在最终长图中的接缝 y 坐标。
  List<int> get previewSeamOffsets {
    final offsets = _previewOffsets();
    return offsets.length > 1 ? offsets.sublist(1) : const [];
  }

  List<int> _previewOffsets() {
    if (!hasCompleteAnalysis) return const [];
    final offsets = <int>[];
    var y = 0;
    for (var i = 0; i < _images.length; i++) {
      offsets.add(y);
      if (i + 1 >= _images.length) continue;
      y += _seams[i]!.dy + _cropTop(i + 1) - _cropTop(i);
    }
    return offsets;
  }

  int _topBar(int index) {
    if (_images.length == 1) return 0;
    if (index == 0) return _seams.first!.analysis.topBar?.h ?? 0;
    return _seams[index - 1]!.analysis.topBar?.h ?? 0;
  }

  int _statusBar() {
    if (_images.length == 1) return 0;
    return _seams.first!.statusBarHeight;
  }

  int _bottomBar(int index) {
    if (_images.length == 1) return 0;
    if (index == _images.length - 1) {
      return _seams.last!.analysis.bottomBar?.h ?? 0;
    }
    return _seams[index]!.analysis.bottomBar?.h ?? 0;
  }

  int _cropTop(int index) {
    if (index > 0) return _topBar(index);
    return exportSettings.removeStatusBar ? _statusBar() : 0;
  }

  int _cropBottom(int index) {
    if (index + 1 < _images.length) return _bottomBar(index);
    final bottomBar = _bottomBar(index);
    final whitespace = exportSettings.trimBottomWhitespace
        ? _seams.last!.bottomWhitespaceHeight
        : 0;
    final retained = exportSettings.retainedBottomEdge
        .clamp(0, whitespace)
        .toInt();
    return bottomBar + whitespace - retained;
  }
}
