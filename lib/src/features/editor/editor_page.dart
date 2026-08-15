/// 导入与排序页面。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/application/session_provider.dart';
import 'package:pixelforge/src/features/editor/image_sequence_view.dart';

export 'package:pixelforge/src/application/session_provider.dart';

class EditorPage extends ConsumerWidget {
  const EditorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final hasImages = session.images.isNotEmpty;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(session.clearAll());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('导入截图'),
          leading: hasImages
              ? IconButton(
                  tooltip: '清空会话',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => _confirmClear(context, session),
                )
              : null,
          actions: [
            if (hasImages)
              IconButton(
                tooltip: '添加截图',
                icon: const Icon(Icons.add_photo_alternate_outlined),
                onPressed: session.analyzing
                    ? null
                    : () => _pickImages(session),
              ),
          ],
        ),
        body: hasImages
            ? ImageSequenceView(session: session)
            : _EmptyState(onPick: () => _pickImages(session)),
      ),
    );
  }

  Future<void> _pickImages(SessionController session) async {
    final picked = await ImagePicker().pickMultiImage(imageQuality: null);
    if (picked.isEmpty) return;
    final paths = picked.map((image) => image.path).toList();
    await session.addImages(paths);
  }

  Future<void> _confirmClear(
    BuildContext context,
    SessionController session,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空当前会话？'),
        content: const Text('当前导入的图片和拼接结果都会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) await session.clearAll();
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.photo_library_outlined,
              size: 72,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('选择要拼接的截图', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '确认图片顺序后，点击“下一步”进入拼接预览。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('选择截图'),
            ),
          ],
        ),
      ),
    );
  }
}
