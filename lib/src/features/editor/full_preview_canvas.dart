/// 结果页使用的完整长图预览。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/domain/models.dart';

const _maxPreviewDecodeWidth = 4096;

class FullPreviewCanvas extends StatelessWidget {
  const FullPreviewCanvas({
    super.key,
    required this.path,
    required this.size,
    required this.session,
    required this.selectedPair,
    required this.onSelectPair,
  });

  final String path;
  final ImageSize size;
  final SessionController session;
  final int? selectedPair;
  final ValueChanged<int> onSelectPair;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportW = constraints.maxWidth;
        final viewportH = constraints.maxHeight;
        final scale = math.min(viewportW / size.width, viewportH / size.height);
        final imageW = size.width * scale;
        final imageH = size.height * scale;
        final imageLeft = (viewportW - imageW) / 2;
        final imageTop = (viewportH - imageH) / 2;
        final offsets = session.previewSeamOffsets;
        final canvas = SizedBox(
          width: viewportW,
          height: viewportH,
          child: Stack(
            children: [
              Positioned(
                left: imageLeft,
                top: imageTop,
                width: imageW,
                height: imageH,
                child: Image.file(
                  File(path),
                  fit: BoxFit.fill,
                  cacheWidth: (imageW * MediaQuery.devicePixelRatioOf(context))
                      .ceil()
                      .clamp(1, _maxPreviewDecodeWidth)
                      .toInt(),
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, error) => PreviewMessage(
                    icon: Icons.broken_image_outlined,
                    text: '预览文件无法读取：$error',
                  ),
                ),
              ),
              for (var i = 0; i < offsets.length; i++)
                _buildSeamMarker(
                  context,
                  pairIndex: i,
                  y: imageTop + offsets[i] * scale,
                  width: viewportW,
                  height: viewportH,
                ),
            ],
          ),
        );
        return ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: InteractiveViewer(
            constrained: false,
            minScale: 1,
            maxScale: 6,
            boundaryMargin: const EdgeInsets.all(80),
            child: canvas,
          ),
        );
      },
    );
  }

  Widget _buildSeamMarker(
    BuildContext context, {
    required int pairIndex,
    required double y,
    required double width,
    required double height,
  }) {
    final active = selectedPair == pairIndex;
    final scheme = Theme.of(context).colorScheme;
    final lineColor = active ? scheme.primary : scheme.outlineVariant;
    final labelColor = active ? scheme.primary : scheme.surfaceContainerHighest;
    final labelForeground = active ? scheme.onPrimary : scheme.onSurface;
    final top = (y - 22).clamp(0.0, math.max(0.0, height - 44)).toDouble();
    return Positioned(
      left: 0,
      top: top,
      width: width,
      height: 44,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => onSelectPair(pairIndex),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 21,
              height: active ? 3 : 2,
              child: ColoredBox(color: lineColor),
            ),
            Positioned(
              left: 8,
              top: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: labelColor.withValues(alpha: active ? 0.95 : 0.95),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  child: Text(
                    '接缝 ${pairIndex + 1} · 点击调整',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: labelForeground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PreviewMessage extends StatelessWidget {
  const PreviewMessage({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
