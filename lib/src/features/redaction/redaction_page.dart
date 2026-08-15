/// Single-image automatic redaction workflow.
library;

import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pixelforge/src/application/redaction_controller.dart';
import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/application/redaction_provider.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/features/redaction/redaction_canvas.dart';
import 'package:pixelforge/src/features/export/image_export_sheet.dart';
import 'package:pixelforge/src/features/redaction/redaction_panels.dart';
import 'package:pixelforge/src/features/redaction/redaction_selection_list.dart';
import 'package:pixelforge/src/features/redaction/redaction_word_dialog.dart';
import 'package:pixelforge/src/infrastructure/storage/public_media_store.dart';
import 'package:pixelforge/src/infrastructure/storage/share_store.dart';

class RedactionPage extends ConsumerStatefulWidget {
  const RedactionPage({super.key});

  @override
  ConsumerState<RedactionPage> createState() => _RedactionPageState();
}

class _RedactionPageState extends ConsumerState<RedactionPage> {
  var _mode = RedactionInteractionMode.normal;
  var _styleExpanded = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(redactionProvider);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) unawaited(session.clear());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('自动打码'),
          actions: [
            if (session.imagePath != null)
              IconButton(
                tooltip: '重新选择图片',
                icon: const Icon(Icons.add_photo_alternate_outlined),
                onPressed: session.analyzing ? null : () => _pickImage(session),
              ),
            if (session.stage == RedactionStage.editing) ...[
              IconButton(
                tooltip: '撤销',
                icon: const Icon(Icons.undo),
                onPressed: session.canUndo ? session.undo : null,
              ),
              IconButton(
                tooltip: '重做',
                icon: const Icon(Icons.redo),
                onPressed: session.canRedo ? session.redo : null,
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
                onPressed: session.exporting || session.masks.isEmpty
                    ? null
                    : () => _openExport(session),
              ),
            ],
          ],
        ),
        body: _buildBody(session),
      ),
    );
  }

  Widget _buildBody(RedactionController session) {
    final path = session.imagePath;
    final size = session.imageSize;
    if (path == null || size == null) {
      return _EmptyRedactionState(onPick: () => _pickImage(session));
    }
    return Column(
      children: [
        if (session.error != null)
          MaterialBanner(
            content: Text(session.error!),
            actions: [
              TextButton(onPressed: session.clear, child: const Text('清除')),
            ],
          ),
        Expanded(
          child: RedactionCanvas(
            path: path,
            size: size,
            candidates: session.candidates,
            masks: session.masks,
            mode: _mode,
            onSelectCandidate: (id) => _handleCandidateTap(session, id),
            onAddManualRect: session.addManualRect,
          ),
        ),
        if (session.analyzing) const LinearProgressIndicator(minHeight: 3),
        RedactionWorkspacePanel(
          session: session,
          mode: _mode,
          styleExpanded: _styleExpanded,
          enabled:
              session.stage == RedactionStage.editing && !session.analyzing,
          onOpenList: () => _openCandidateList(session),
          onModeChanged: (mode) => setState(() => _mode = mode),
          onToggleStyle: () => setState(() => _styleExpanded = !_styleExpanded),
        ),
      ],
    );
  }

  Future<void> _pickImage(RedactionController session) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: null,
    );
    if (picked != null) {
      setState(() {
        _mode = RedactionInteractionMode.normal;
        _styleExpanded = false;
      });
      await session.importImage(picked.path);
    }
  }

  void _handleCandidateTap(RedactionController session, String id) {
    final index = session.candidates.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final candidate = session.candidates[index];
    if (candidate.kind == DetectionKind.textLine) {
      unawaited(_openWordSelection(session, candidate));
      return;
    }
    session.toggleCandidate(id);
  }

  Future<void> _openWordSelection(
    RedactionController session,
    DetectionCandidate tapped,
  ) async {
    final group = session.candidates
        .where(
          (candidate) =>
              candidate.kind == DetectionKind.textLine &&
              candidate.groupId == tapped.groupId,
        )
        .toList();
    if (group.isEmpty) return;
    final selectedIds = await showRedactionWordSelectionDialog(
      context: context,
      words: group,
    );
    if (selectedIds == null) return;
    for (final word in group) {
      final selected = selectedIds.contains(word.id);
      if (word.selected != selected) session.toggleCandidate(word.id);
    }
  }

  Future<void> _openCandidateList(RedactionController session) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RedactionSelectionList(session: session),
    );
  }

  Future<void> _openExport(RedactionController session) async {
    final result = await showModalBottomSheet<ImageExportResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ImageExportSheet(
        title: '导出打码图片',
        fileNamePrefix: 'pixelforge_redacted',
        exportPath: session.exportPath,
        formats: ExportFormat.values,
      ),
    );
    if (result == null || !mounted) return;
    try {
      final ok = await session.exportNow(
        outPath: result.path,
        format: result.format,
        quality: result.quality,
      );
      if (!ok) {
        _showMessage(session.error ?? '导出失败');
        return;
      }
      if (result.action == ImageExportAction.save) {
        final savedPath = await PublicMediaStore.saveImage(
          sourcePath: result.path,
          displayName: result.fileName,
          mimeType: result.mimeType,
          location: result.location,
        );
        _showMessage('已保存到 $savedPath');
      } else {
        await _share(result);
      }
    } catch (error) {
      _showMessage('导出完成，但后续操作失败：$error');
    } finally {
      final file = File(result.path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _share(ImageExportResult result) async {
    await ShareStore.shareImage(
      sourcePath: result.path,
      displayName: result.fileName,
      mimeType: result.mimeType,
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _EmptyRedactionState extends StatelessWidget {
  const _EmptyRedactionState({required this.onPick});

  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.security_outlined, size: 72),
            const SizedBox(height: 16),
            Text('选择要保护的图片', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('选择图片'),
            ),
          ],
        ),
      ),
    );
  }
}
