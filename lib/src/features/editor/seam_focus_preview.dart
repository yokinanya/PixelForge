/// 分别调整相邻两张截图截取位置的局部视图。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/domain/models.dart';

const _cropPanelHeight = 190.0;
const _maxPreviewDecodeWidth = 2048;

class SeamFocusPreview extends StatelessWidget {
  const SeamFocusPreview({
    super.key,
    required this.top,
    required this.bottom,
    required this.dx,
    required this.topCut,
    required this.bottomCut,
    required this.onTopCutChanged,
    required this.onBottomCutChanged,
    required this.onCommit,
  });

  final SessionImage top;
  final SessionImage bottom;
  final int dx;
  final int topCut;
  final int bottomCut;
  final ValueChanged<int> onTopCutChanged;
  final ValueChanged<int> onBottomCutChanged;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CropPanel(
          image: top,
          cut: topCut,
          horizontalOffset: 0,
          maskAfterCut: true,
          onChanged: onTopCutChanged,
          onCommit: onCommit,
        ),
        const SizedBox(height: 10),
        _CropPanel(
          image: bottom,
          cut: bottomCut,
          horizontalOffset: dx,
          maskAfterCut: false,
          onChanged: onBottomCutChanged,
          onCommit: onCommit,
        ),
      ],
    );
  }
}

class _CropPanel extends StatefulWidget {
  const _CropPanel({
    required this.image,
    required this.cut,
    required this.horizontalOffset,
    required this.maskAfterCut,
    required this.onChanged,
    required this.onCommit,
  });

  final SessionImage image;
  final int cut;
  final int horizontalOffset;
  final bool maskAfterCut;
  final ValueChanged<int> onChanged;
  final VoidCallback onCommit;

  @override
  State<_CropPanel> createState() => _CropPanelState();
}

class _CropPanelState extends State<_CropPanel> {
  double? _focusStart;
  int? _dragCut;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _CropPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.cut != widget.cut) {
      _focusStart = null;
      _dragCut = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final scale = width / widget.image.size.width;
        final visibleRows = _cropPanelHeight / scale;
        final cut = _dragCut ?? widget.cut;
        final start = _focusStart ?? _defaultStart(visibleRows, cut);
        final line = ((cut - start) * scale)
            .clamp(0.0, _cropPanelHeight)
            .toDouble();
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (_) => setState(() {
              _focusStart = start;
              _dragCut = cut;
              _dragging = true;
            }),
            onVerticalDragUpdate: (details) {
              final delta = details.primaryDelta;
              if (delta == null) return;
              final next = ((_dragCut ?? cut) + delta / scale).round().clamp(
                0,
                widget.image.size.height - 1,
              );
              setState(() => _dragCut = next);
              widget.onChanged(next);
            },
            onVerticalDragEnd: (_) {
              setState(() => _dragging = false);
              widget.onCommit();
            },
            onVerticalDragCancel: () => setState(() {
              _dragging = false;
              _dragCut = null;
            }),
            child: SizedBox(
              height: _cropPanelHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    _imageLayer(scale, start),
                    if (widget.maskAfterCut)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: line,
                        bottom: 0,
                        child: const _CropMask(),
                      )
                    else
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: line,
                        child: const _CropMask(),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: line - 1,
                      height: 2,
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  double _defaultStart(double visibleRows, int cut) {
    final maxStart = math.max(0, widget.image.size.height - visibleRows);
    return (cut - visibleRows / 2).clamp(0, maxStart).toDouble();
  }

  Widget _imageLayer(double scale, double start) {
    return Positioned(
      left: widget.horizontalOffset * scale,
      top: -start * scale,
      width: widget.image.size.width * scale,
      height: widget.image.size.height * scale,
      child: Image.file(
        File(widget.image.path),
        fit: BoxFit.fill,
        cacheWidth: widget.image.size.width
            .clamp(1, _maxPreviewDecodeWidth)
            .toInt(),
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }
}

class _CropMask extends StatelessWidget {
  const _CropMask();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.48),
    );
  }
}
