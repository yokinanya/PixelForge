/// 将会话状态转换为 Rust 合成请求。
library;

import 'package:pixelforge/src/application/session_models.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/ffi/rust_bridge.dart';

ComposeRequest buildComposeRequest({
  required List<SessionImage> images,
  required List<SeamState?> seams,
  required ExportSettings settings,
  required String outPath,
  required ExportFormat format,
  int scalePercent = 100,
}) {
  return ComposeRequest(
    paths: [for (final image in images) image.path],
    seams: [for (final seam in seams) (dx: seam!.dx, dy: seam.dy)],
    topBars: images.length == 1
        ? [0]
        : [
            for (var i = 0; i < images.length; i++)
              i == 0
                  ? (settings.removeStatusBar
                        ? seams.first!.statusBarHeight
                        : 0)
                  : (seams[i - 1]!.analysis.topBar?.h ?? 0),
          ],
    bottomBars: images.length == 1
        ? [0]
        : [
            for (var i = 0; i < images.length; i++)
              i == images.length - 1
                  ? (seams.last!.analysis.bottomBar?.h ?? 0)
                  : (seams[i]!.analysis.bottomBar?.h ?? 0),
          ],
    lastBottomWhitespace: images.length == 1
        ? 0
        : seams.last!.bottomWhitespaceHeight,
    removeFirstStatusBar: settings.removeStatusBar,
    trimLastBottomWhitespace: settings.trimBottomWhitespace,
    retainedBottomEdge: settings.trimBottomWhitespace
        ? settings.retainedBottomEdge
        : 0,
    format: format,
    quality: format == ExportFormat.jpeg ? settings.jpegQuality : 100,
    scalePercent: scalePercent,
    outPath: outPath,
  );
}
