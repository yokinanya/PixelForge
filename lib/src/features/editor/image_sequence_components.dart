/// 导入截图页面的预览与计算操作组件。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/features/editor/result_page.dart';

const _maxPreviewDecodeWidth = 2048;

class ImageSequencePreview extends StatelessWidget {
  const ImageSequencePreview({
    super.key,
    required this.controller,
    required this.images,
    required this.currentIndex,
    required this.onPageChanged,
  });

  final PageController controller;
  final List<SessionImage> images;
  final int currentIndex;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final image = images[currentIndex];
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                '第 ${currentIndex + 1} / ${images.length} 张',
                style: theme.textTheme.titleSmall,
              ),
              const Spacer(),
              Text(
                '${image.size.width} × ${image.size.height} px',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: PageView.builder(
              controller: controller,
              itemCount: images.length,
              onPageChanged: onPageChanged,
              itemBuilder: (context, index) => _FullImage(image: images[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class _FullImage extends StatelessWidget {
  const _FullImage({required this.image});

  final SessionImage image;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      boundaryMargin: const EdgeInsets.all(24),
      child: SizedBox.expand(
        child: Image.file(
          File(image.path),
          fit: BoxFit.contain,
          cacheWidth: image.size.width.clamp(1, _maxPreviewDecodeWidth).toInt(),
          errorBuilder: (_, _, error) => Center(child: Text('图片无法读取：$error')),
        ),
      ),
    );
  }
}

class CalculationFooter extends StatelessWidget {
  const CalculationFooter({super.key, required this.session});

  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final isCalculating = session.analyzing;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        children: [
          if (isCalculating)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: LinearProgressIndicator(),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isCalculating
                  ? null
                  : () => _nextStep(context, session),
              icon: const Icon(Icons.auto_awesome_motion_outlined),
              label: Text(isCalculating ? '正在分析接缝…' : '下一步'),
            ),
          ),
        ],
      ),
    );
  }

  void _nextStep(BuildContext context, SessionController session) {
    if (session.hasPendingAnalysis) {
      unawaited(session.recalculateStitch());
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => StitchResultPage(session: session)),
    );
  }
}
