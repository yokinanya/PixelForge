/// 隐私保护水印页面。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pixelforge/src/application/watermark_controller.dart';
import 'package:pixelforge/src/application/watermark_provider.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/features/export/image_export_sheet.dart';
import 'package:pixelforge/src/features/watermark/watermark_painter.dart';
import 'package:pixelforge/src/infrastructure/storage/public_media_store.dart';
import 'package:pixelforge/src/infrastructure/storage/share_store.dart';

const _watermarkControlsReservedHeight = 92.0;

class WatermarkPage extends ConsumerStatefulWidget {
  const WatermarkPage({super.key, this.initialImagePath});

  final String? initialImagePath;

  @override
  ConsumerState<WatermarkPage> createState() => _WatermarkPageState();
}

class _WatermarkPageState extends ConsumerState<WatermarkPage> {
  late final TextEditingController _textController;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: defaultWatermarkText)
      ..addListener(_handleTextChanged);
    ref.read(watermarkProvider).setText(_textController.text);
    final path = widget.initialImagePath;
    if (path != null) unawaited(ref.read(watermarkProvider).importImage(path));
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_handleTextChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(watermarkProvider);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(session.clear());
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          title: const Text('隐私保护水印'),
          actions: session.imagePath == null
              ? null
              : [
                  IconButton(
                    tooltip: '重新选择图片',
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: _busy ? null : () => _pickImage(session),
                  ),
                  IconButton(
                    tooltip: '导出',
                    icon: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.ios_share_outlined),
                    onPressed: _busy ? null : () => _openExport(session),
                  ),
                ],
        ),
        body: session.imagePath == null
            ? _EmptyWatermarkState(
                error: session.error,
                onPick: () => _pickImage(session),
              )
            : _WatermarkWorkspace(
                session: session,
                textController: _textController,
                busy: _busy,
              ),
      ),
    );
  }

  void _handleTextChanged() {
    ref.read(watermarkProvider).setText(_textController.text);
  }

  Future<void> _pickImage(WatermarkController session) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: null,
    );
    if (picked != null) await session.importImage(picked.path);
  }

  Future<void> _openExport(WatermarkController session) async {
    if (_busy) return;
    final result = await showModalBottomSheet<ImageExportResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ImageExportSheet(
        title: '导出隐私水印',
        fileNamePrefix: 'pixelforge_watermark',
        exportPath: session.exportPath,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await session.exportNow(outPath: result.path);
      if (!ok) {
        _showMessage(session.error ?? '生成水印图片失败');
        return;
      }
      if (result.action == ImageExportAction.share) {
        await ShareStore.shareImage(
          sourcePath: result.path,
          displayName: result.fileName,
          mimeType: result.mimeType,
        );
      } else {
        final savedPath = await PublicMediaStore.saveImage(
          sourcePath: result.path,
          displayName: result.fileName,
          mimeType: result.mimeType,
          location: result.location,
        );
        _showMessage('已保存到 $savedPath');
      }
    } catch (error) {
      final action = result.action == ImageExportAction.share ? '分享' : '保存';
      _showMessage('$action失败：$error');
    } finally {
      await session.store.deleteFile(result.path);
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _WatermarkWorkspace extends StatelessWidget {
  const _WatermarkWorkspace({
    required this.session,
    required this.textController,
    required this.busy,
  });

  final WatermarkController session;
  final TextEditingController textController;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            bottom: _watermarkControlsReservedHeight,
          ),
          child: RepaintBoundary(
            child: _WatermarkPreview(
              path: session.imagePath!,
              imageSize: session.imageSize!,
              text: session.text,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Transform.translate(
            offset: Offset(0, -keyboardInset),
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: textController,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: '水印文字',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _WatermarkPreview extends StatelessWidget {
  const _WatermarkPreview({
    required this.path,
    required this.imageSize,
    required this.text,
  });

  final String path;
  final ImageSize imageSize;
  final String text;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspectRatio = imageSize.width / imageSize.height;
        var width = constraints.maxWidth;
        var height = width / aspectRatio;
        if (height > constraints.maxHeight) {
          height = constraints.maxHeight;
          width = height * aspectRatio;
        }
        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.hardEdge,
                children: [
                  Image.file(
                    File(path),
                    fit: BoxFit.fill,
                    cacheWidth: imageSize.width.clamp(1, 1024).toInt(),
                    filterQuality: FilterQuality.low,
                  ),
                  IgnorePointer(
                    child: CustomPaint(painter: WatermarkPainter(text)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyWatermarkState extends StatelessWidget {
  const _EmptyWatermarkState({required this.error, required this.onPick});

  final String? error;
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
              Icons.badge_outlined,
              size: 72,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text('选择证件照片', style: theme.textTheme.titleMedium),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('选择照片'),
            ),
          ],
        ),
      ),
    );
  }
}
