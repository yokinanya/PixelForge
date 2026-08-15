/// 完整拼接结果页：只展示最终长图和可进入局部编辑的接缝入口。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/application/session_provider.dart';
import 'package:pixelforge/src/features/editor/full_preview_canvas.dart';
import 'package:pixelforge/src/features/editor/preview_settings_sheet.dart';
import 'package:pixelforge/src/features/editor/seam_edit_page.dart';
import 'package:pixelforge/src/features/export/export_sheet.dart';
import 'package:pixelforge/src/infrastructure/storage/public_media_store.dart';
import 'package:pixelforge/src/infrastructure/storage/share_store.dart';

class StitchResultPage extends ConsumerStatefulWidget {
  const StitchResultPage({super.key, required this.session});

  final SessionController session;

  @override
  ConsumerState<StitchResultPage> createState() => _StitchResultPageState();
}

class _StitchResultPageState extends ConsumerState<StitchResultPage> {
  int? _selectedPair;

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionProvider);
    final session = widget.session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('拼接结果'),
        actions: [
          IconButton(
            tooltip: '预览设置',
            icon: const Icon(Icons.tune_outlined),
            onPressed: () => _openPreviewSettings(context, session),
          ),
          IconButton(
            tooltip: '导出',
            icon: session.exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.ios_share_outlined),
            onPressed: session.exporting || !session.hasCompleteAnalysis
                ? null
                : () => _openExport(context, session),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _ResultPreview(
              session: session,
              selectedPair: _selectedPair,
              onSelectPair: _openSeam,
            ),
          ),
          _ResultFooter(
            session: session,
            selectedPair: _selectedPair,
            onSelectPair: _openSeam,
          ),
        ],
      ),
    );
  }

  Future<void> _openSeam(int pairIndex) async {
    setState(() => _selectedPair = pairIndex);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            SeamEditPage(session: widget.session, pairIndex: pairIndex),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openPreviewSettings(
    BuildContext context,
    SessionController session,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (_) => PreviewSettingsSheet(session: session),
    );
  }

  Future<void> _openExport(
    BuildContext context,
    SessionController session,
  ) async {
    final result = await showModalBottomSheet<ExportResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ExportSheet(session: session),
    );
    if (result == null || !context.mounted) return;
    final message = result.action == ExportAction.share
        ? await _shareExport(session, result)
        : await _exportToPublicMedia(session, result);
    if (message == null) return;
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String> _exportToPublicMedia(
    SessionController session,
    ExportResult result,
  ) async {
    try {
      final ok = await session.exportNow(
        outPath: result.path,
        outFormat: result.format,
      );
      if (!ok) return session.lastError ?? '导出失败';
      final savedPath = await PublicMediaStore.saveImage(
        sourcePath: result.path,
        displayName: result.fileName,
        mimeType: result.mimeType,
        location: result.location,
      );
      return '已保存到 $savedPath';
    } catch (error) {
      return '导出完成，但写入公共目录失败：$error';
    } finally {
      await _deleteTemporaryExport(result.path);
    }
  }

  Future<String?> _shareExport(
    SessionController session,
    ExportResult result,
  ) async {
    try {
      final ok = await session.exportNow(
        outPath: result.path,
        outFormat: result.format,
      );
      if (!ok) return session.lastError ?? '导出失败';
      await ShareStore.shareImage(
        sourcePath: result.path,
        displayName: result.fileName,
        mimeType: result.mimeType,
      );
      return null;
    } catch (error) {
      return '分享失败：$error';
    } finally {
      await _deleteTemporaryExport(result.path);
    }
  }

  Future<void> _deleteTemporaryExport(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

class _ResultPreview extends StatelessWidget {
  const _ResultPreview({
    required this.session,
    required this.selectedPair,
    required this.onSelectPair,
  });

  final SessionController session;
  final int? selectedPair;
  final ValueChanged<int> onSelectPair;

  @override
  Widget build(BuildContext context) {
    final path = session.previewPath;
    final size = session.previewSize;
    if (path == null || size == null) {
      final processing = session.previewing || session.analyzing;
      return PreviewMessage(
        icon: processing ? Icons.hourglass_top : Icons.image_search_outlined,
        text: session.previewError ?? (processing ? '正在生成完整预览…' : '等待拼接结果'),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FullPreviewCanvas(
          path: path,
          size: size,
          session: session,
          selectedPair: selectedPair,
          onSelectPair: onSelectPair,
        ),
      ),
    );
  }
}

class _ResultFooter extends StatelessWidget {
  const _ResultFooter({
    required this.session,
    required this.selectedPair,
    required this.onSelectPair,
  });

  final SessionController session;
  final int? selectedPair;
  final ValueChanged<int> onSelectPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = session.previewSize;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            size == null
                ? '拼接完成后显示完整长图'
                : '完整预览 · ${size.width} × ${size.height} px',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (session.seams.isEmpty)
            const Text('当前只有一张截图，没有需要调整的接缝。')
          else
            SizedBox(
              height: 58,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: session.seams.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, index) {
                  final seam = session.seams[index];
                  final confidence = seam?.analysis.confidence ?? 0;
                  return ChoiceChip(
                    selected: selectedPair == index,
                    onSelected: (_) => onSelectPair(index),
                    label: Text('接缝 ${index + 1} · ${seam?.dy ?? '…'} px'),
                    avatar: Icon(
                      seam == null || confidence < 0.3
                          ? Icons.warning_amber_outlined
                          : Icons.check_circle_outline,
                      size: 18,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
