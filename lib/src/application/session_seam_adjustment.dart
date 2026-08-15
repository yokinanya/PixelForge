part of 'session_controller.dart';

extension SessionSeamAdjustment on SessionController {
  /// 分别设置前图结束行与后图开始行。
  bool setManualCuts(
    int pairIndex, {
    required int topCut,
    required int bottomCut,
  }) {
    if (pairIndex < 0 || pairIndex >= _seams.length) return false;
    final seam = _seams[pairIndex];
    if (seam == null) return false;
    final topHeight = _images[pairIndex].size.height;
    final bottomHeight = _images[pairIndex + 1].size.height;
    if (topCut < 0 || topCut >= topHeight) {
      _lastError = '前图结束行超出图片范围: $topCut';
      _notifyStateChanged();
      return false;
    }
    if (bottomCut < 0 || bottomCut >= bottomHeight) {
      _lastError = '后图开始行超出图片范围: $bottomCut';
      _notifyStateChanged();
      return false;
    }
    if (topCut < bottomCut) {
      _lastError = '前图结束行必须不早于后图开始行';
      _notifyStateChanged();
      return false;
    }
    seam.manual = true;
    seam.manualTopCut = topCut;
    seam.manualBottomCut = bottomCut;
    _notifyStateChanged();
    unawaited(refreshPreview());
    return true;
  }

  /// 兼容旧调用：只调整相对偏移，保留自动识别出的后图顶部栏切线。
  void setManualSeam(int pairIndex, int dy) {
    final seam = pairIndex >= 0 && pairIndex < _seams.length
        ? _seams[pairIndex]
        : null;
    final bottomCut = seam?.automaticBottomCut ?? 0;
    setManualCuts(pairIndex, topCut: dy + bottomCut, bottomCut: bottomCut);
  }

  /// 恢复自动检测。
  void resetSeam(int pairIndex) {
    final seam = _seams[pairIndex];
    if (seam == null) return;
    seam.manual = false;
    seam.manualTopCut = null;
    seam.manualBottomCut = null;
    _notifyStateChanged();
    unawaited(_reanalyzeAndRefresh(pairIndex));
  }

  Future<void> _reanalyzeAndRefresh(int pairIndex) async {
    await _analyzePair(pairIndex, _analysisGeneration);
    await refreshPreview();
  }
}
