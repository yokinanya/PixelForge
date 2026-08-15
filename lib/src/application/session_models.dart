/// 会话编辑状态模型。
library;

import 'package:pixelforge/src/domain/models.dart';

const defaultRetainedBottomEdgePx = 24;
const _statusBarDivisor = 3;
const _minimumStatusBarPx = 48;
const _maximumStatusBarPx = 160;

class SeamState {
  SeamState({required this.analysis});

  PairAnalysis analysis;
  bool manual = false;
  int? manualTopCut;
  int? manualBottomCut;

  int get automaticBottomCut => analysis.topBar?.h ?? 0;

  /// 从固定顶部区域估算系统状态栏高度，避免把应用导航栏一起裁掉。
  int get statusBarHeight => estimateStatusBarHeight(analysis.topBar?.h ?? 0);

  /// 检测到的底部固定内容上方空白区域高度。
  int get bottomWhitespaceHeight => analysis.bottomWhitespace?.h ?? 0;

  /// 第一张图的结束行。
  int get topCut => manualTopCut ?? analysis.dy + automaticBottomCut;

  /// 第二张图的开始行。
  int get bottomCut => manualBottomCut ?? automaticBottomCut;

  /// 兼容 Rust 合成器的相对偏移：topCut - bottomCut。
  int get dy => topCut - bottomCut;

  int get dx => analysis.dx;
}

int estimateStatusBarHeight(int topBarHeight) {
  if (topBarHeight == 0) return 0;
  final minHeight = topBarHeight < _minimumStatusBarPx
      ? topBarHeight
      : _minimumStatusBarPx;
  final maxHeight = topBarHeight < _maximumStatusBarPx
      ? topBarHeight
      : _maximumStatusBarPx;
  return (topBarHeight / _statusBarDivisor)
      .round()
      .clamp(minHeight, maxHeight)
      .toInt();
}

class ExportSettings {
  ExportSettings({
    this.format = ExportFormat.png,
    this.jpegQuality = 95,
    this.scalePercent = 100,
    this.removeStatusBar = true,
    this.trimBottomWhitespace = false,
    this.retainedBottomEdge = defaultRetainedBottomEdgePx,
  });

  ExportFormat format;
  int jpegQuality;
  int scalePercent;
  bool removeStatusBar;
  bool trimBottomWhitespace;
  int retainedBottomEdge;
}
