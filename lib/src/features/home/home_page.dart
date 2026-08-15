/// Home page that separates the two independent image workflows.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/app_brand.dart';
import 'package:pixelforge/src/application/redaction_provider.dart';
import 'package:pixelforge/src/application/share_controller.dart';
import 'package:pixelforge/src/application/share_provider.dart';
import 'package:pixelforge/src/application/watermark_provider.dart';
import 'package:pixelforge/src/features/editor/editor_page.dart';
import 'package:pixelforge/src/features/redaction/redaction_page.dart';
import 'package:pixelforge/src/features/settings/settings_page.dart';
import 'package:pixelforge/src/features/watermark/watermark_page.dart';

const _singleColumnBreakpoint = 360.0;
const _cardHeight = 84.0;
const _gridSpacing = 10.0;

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

enum _SharedAction { redaction, stitch, watermark }

class _HomePageState extends ConsumerState<HomePage> {
  var _showingSharedChooser = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<ShareController>(
      shareProvider,
      (_, controller) => _scheduleSharedChooser(controller),
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(appName),
        actions: [
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < _singleColumnBreakpoint
                ? 1
                : 2;
            return GridView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: 3,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: _gridSpacing,
                mainAxisSpacing: _gridSpacing,
                mainAxisExtent: _cardHeight,
              ),
              itemBuilder: (context, index) => switch (index) {
                0 => _FeatureCard(
                  key: const Key('home-tool-redaction'),
                  icon: Icons.security_outlined,
                  title: '自动打码',
                  enabled: Platform.isAndroid,
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(builder: (_) => const RedactionPage()),
                  ),
                ),
                1 => _FeatureCard(
                  key: const Key('home-tool-stitch'),
                  icon: Icons.auto_awesome_motion_outlined,
                  title: '长截图拼接',
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(builder: (_) => const EditorPage()),
                  ),
                ),
                _ => _FeatureCard(
                  key: const Key('home-tool-watermark'),
                  icon: Icons.badge_outlined,
                  title: '隐私保护水印',
                  enabled: Platform.isAndroid,
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(builder: (_) => const WatermarkPage()),
                  ),
                ),
              },
            );
          },
        ),
      ),
    );
  }

  void _scheduleSharedChooser(ShareController controller) {
    if (_showingSharedChooser || !controller.hasPendingImages) return;
    _showingSharedChooser = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openSharedChooser(controller);
    });
  }

  Future<void> _openSharedChooser(ShareController controller) async {
    final action = await _selectSharedAction(controller.pendingImages.length);
    if (action == null) {
      try {
        await controller.dismissPendingImages();
      } finally {
        _showingSharedChooser = false;
      }
      return;
    }
    if (!mounted) {
      try {
        await controller.dismissPendingImages();
      } finally {
        _showingSharedChooser = false;
      }
      return;
    }
    final paths = controller.takePendingImages();
    try {
      switch (action) {
        case _SharedAction.redaction:
          await _openRedaction(paths);
        case _SharedAction.stitch:
          await ref.read(sessionProvider).addImages(paths);
          if (!mounted) return;
          await Navigator.push<void>(
            context,
            MaterialPageRoute(builder: (_) => const EditorPage()),
          );
        case _SharedAction.watermark:
          await _openWatermark(paths);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入分享图片失败：$error')));
      }
    } finally {
      try {
        await controller.releaseSharedImages(paths);
      } finally {
        _showingSharedChooser = false;
      }
    }
  }

  Future<void> _openRedaction(List<String> paths) async {
    if (paths.length != 1) {
      throw StateError('自动打码一次只能处理一张图片');
    }
    final controller = ref.read(redactionProvider);
    await controller.importImage(paths.single);
    if (controller.imagePath == null) {
      throw StateError(controller.error ?? '无法导入图片');
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const RedactionPage()),
    );
  }

  Future<_SharedAction?> _selectSharedAction(int imageCount) {
    final redactionEnabled = Platform.isAndroid && imageCount == 1;
    final watermarkEnabled = Platform.isAndroid && imageCount == 1;
    return showModalBottomSheet<_SharedAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('选择功能')),
            if (redactionEnabled)
              ListTile(
                leading: const Icon(Icons.security_outlined),
                title: const Text('自动打码'),
                onTap: () => Navigator.pop(context, _SharedAction.redaction),
              ),
            if (watermarkEnabled)
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('隐私保护水印'),
                onTap: () => Navigator.pop(context, _SharedAction.watermark),
              ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_motion_outlined),
              title: const Text('长截图拼接'),
              onTap: () => Navigator.pop(context, _SharedAction.stitch),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _openWatermark(List<String> paths) async {
    if (paths.length != 1) {
      throw StateError('隐私保护水印一次只能处理一张图片');
    }
    final controller = ref.read(watermarkProvider);
    await controller.importImage(paths.single);
    if (controller.imagePath == null) {
      throw StateError(controller.error ?? '无法导入图片');
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const WatermarkPage()),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = enabled ? scheme.primary : scheme.outline;
    return Semantics(
      button: true,
      enabled: enabled,
      label: title,
      child: Card(
        color: enabled
            ? scheme.surfaceContainerLow
            : scheme.surfaceContainerHighest,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: _FeatureCardContent(
            icon: icon,
            title: _breakTitleAtSemanticBoundary(title),
            enabled: enabled,
            accent: accent,
          ),
        ),
      ),
    );
  }
}

class _FeatureCardContent extends StatelessWidget {
  const _FeatureCardContent({
    required this.icon,
    required this.title,
    required this.enabled,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final bool enabled;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: enabled
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: accent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            enabled ? Icons.arrow_forward_rounded : Icons.lock_outline,
            color: accent,
          ),
        ],
      ),
    );
  }
}

String _breakTitleAtSemanticBoundary(String title) => switch (title) {
  '长截图拼接' => '长截图\u200B拼接',
  '隐私保护水印' => '隐私保护\u200B水印',
  _ => title,
};
