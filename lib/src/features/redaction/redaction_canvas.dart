/// Zoomable image canvas with redaction and interaction overlays.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/features/redaction/redaction_candidate_layout.dart';

const _maxPreviewDecodeWidth = 4096;

class RedactionCanvas extends StatefulWidget {
  const RedactionCanvas({
    super.key,
    required this.path,
    required this.size,
    required this.candidates,
    required this.masks,
    required this.mode,
    required this.onSelectCandidate,
    required this.onAddManualRect,
  });

  final String path;
  final ImageSize size;
  final List<DetectionCandidate> candidates;
  final List<MaskRegion> masks;
  final RedactionInteractionMode mode;
  final ValueChanged<String> onSelectCandidate;
  final ValueChanged<PixelRect> onAddManualRect;

  @override
  State<RedactionCanvas> createState() => _RedactionCanvasState();
}

class _RedactionCanvasState extends State<RedactionCanvas> {
  Offset? _dragStart;
  Offset? _dragCurrent;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = widget.size.width.toDouble();
        final height = widget.size.height.toDouble();
        final fitScale = math.min(
          constraints.maxWidth / width,
          constraints.maxHeight / height,
        );
        final scale = fitScale.isFinite && fitScale > 0 ? fitScale : 1.0;
        final childWidth = width * scale;
        final childHeight = height * scale;
        final freeBox = widget.mode == RedactionInteractionMode.freeBox;
        final scheme = Theme.of(context).colorScheme;
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: InteractiveViewer(
              constrained: false,
              panEnabled: !freeBox,
              scaleEnabled: !freeBox,
              minScale: 1,
              maxScale: 6,
              boundaryMargin: const EdgeInsets.all(80),
              child: SizedBox(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                child: Center(
                  child: SizedBox(
                    width: childWidth,
                    height: childHeight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (details) =>
                          _selectAt(details.localPosition, scale),
                      onPanStart: freeBox
                          ? (details) => setState(() {
                              _dragStart = details.localPosition;
                              _dragCurrent = details.localPosition;
                            })
                          : null,
                      onPanUpdate: freeBox
                          ? (details) => setState(() {
                              _dragCurrent = details.localPosition;
                            })
                          : null,
                      onPanEnd: freeBox ? (_) => _finishDrag(scale) : null,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            File(widget.path),
                            fit: BoxFit.fill,
                            cacheWidth:
                                (childWidth *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .ceil()
                                    .clamp(1, _maxPreviewDecodeWidth)
                                    .toInt(),
                            filterQuality: FilterQuality.medium,
                            errorBuilder: (_, _, error) =>
                                Center(child: Text('图片无法读取：$error')),
                          ),
                          for (final mask in widget.masks)
                            if (mask.style == MaskStyle.blur)
                              Positioned(
                                left: mask.rect.left * scale,
                                top: mask.rect.top * scale,
                                width: mask.rect.width * scale,
                                height: mask.rect.height * scale,
                                child: ClipRect(
                                  child: BackdropFilter(
                                    filter: ui.ImageFilter.blur(
                                      sigmaX: _blurSigma,
                                      sigmaY: _blurSigma,
                                    ),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ),
                          CustomPaint(
                            painter: _RedactionPainter(
                              scale: scale,
                              candidates: widget.candidates,
                              masks: widget.masks,
                              mode: widget.mode,
                              draft: _draft(scale),
                              draftColor: scheme.primary,
                              candidateColor: scheme.secondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  PixelRect? _draft(double scale) {
    if (_dragStart == null || _dragCurrent == null) return null;
    return PixelRect(
      left: _dragStart!.dx / scale,
      top: _dragStart!.dy / scale,
      right: _dragCurrent!.dx / scale,
      bottom: _dragCurrent!.dy / scale,
    ).normalized();
  }

  void _selectAt(Offset position, double scale) {
    if (widget.mode != RedactionInteractionMode.selection) return;
    final x = position.dx / scale;
    final y = position.dy / scale;
    final visible =
        widget.candidates
            .where((candidate) => candidate.rect.contains(x, y))
            .toList()
          ..sort(_compareTapPriority);
    if (visible.isNotEmpty) widget.onSelectCandidate(visible.first.id);
  }

  int _compareTapPriority(DetectionCandidate first, DetectionCandidate second) {
    final firstIsWord = first.kind == DetectionKind.textLine;
    final secondIsWord = second.kind == DetectionKind.textLine;
    if (firstIsWord != secondIsWord) return firstIsWord ? -1 : 1;
    return _area(first.rect).compareTo(_area(second.rect));
  }

  double _area(PixelRect rect) => rect.width * rect.height;

  void _finishDrag(double scale) {
    final draft = _draft(scale);
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
    });
    if (draft != null && draft.width >= 2 && draft.height >= 2) {
      widget.onAddManualRect(draft);
    }
  }
}

class _RedactionPainter extends CustomPainter {
  _RedactionPainter({
    required this.scale,
    required this.candidates,
    required this.masks,
    required this.mode,
    required this.draft,
    required this.draftColor,
    required this.candidateColor,
  });

  final double scale;
  final List<DetectionCandidate> candidates;
  final List<MaskRegion> masks;
  final RedactionInteractionMode mode;
  final PixelRect? draft;
  final Color draftColor;
  final Color candidateColor;

  @override
  void paint(Canvas canvas, Size displaySize) {
    _drawMasks(canvas);
    if (mode == RedactionInteractionMode.selection) _drawCandidates(canvas);
    if (mode == RedactionInteractionMode.freeBox && draft != null) {
      _drawRect(
        canvas,
        draft!,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = draftColor,
      );
    }
  }

  void _drawMasks(Canvas canvas) {
    for (final mask in masks) {
      if (mask.style != MaskStyle.solid) continue;
      final color = mask.colorMode == MaskColorMode.adaptive
          ? _adaptivePreviewColor
          : Color(mask.color);
      _drawRect(canvas, mask.rect, Paint()..color = color);
    }
  }

  void _drawCandidates(Canvas canvas) {
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = candidateColor;
    for (final rect in mergeAdjacentTextCandidateRects(
      candidates,
      includeSelected: true,
    )) {
      _drawRect(canvas, rect, outline);
    }
    for (final candidate in candidates) {
      if (candidate.kind == DetectionKind.textLine) continue;
      _drawRect(canvas, candidate.rect, outline);
    }
  }

  void _drawRect(Canvas canvas, PixelRect rect, Paint paint) {
    canvas.drawRect(
      Rect.fromLTRB(
        rect.left * scale,
        rect.top * scale,
        rect.right * scale,
        rect.bottom * scale,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _RedactionPainter oldDelegate) =>
      oldDelegate.scale != scale ||
      oldDelegate.mode != mode ||
      oldDelegate.candidates != candidates ||
      oldDelegate.masks != masks ||
      oldDelegate.draft != draft ||
      oldDelegate.draftColor != draftColor ||
      oldDelegate.candidateColor != candidateColor;
}

const _adaptivePreviewColor = Color(0xFFBDBDBD);
const _blurSigma = 8.0;
