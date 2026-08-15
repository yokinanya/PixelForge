/// Shared export and save sheet for single-image tools.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/features/export/image_export_controls.dart';

enum ImageExportAction { save, share }

class ImageExportResult {
  const ImageExportResult({
    required this.path,
    required this.format,
    required this.quality,
    required this.fileName,
    required this.mimeType,
    required this.location,
    required this.action,
  });

  final String path;
  final ExportFormat format;
  final int quality;
  final String fileName;
  final String mimeType;
  final ExportLocation location;
  final ImageExportAction action;
}

class ImageExportSheet extends StatefulWidget {
  const ImageExportSheet({
    super.key,
    required this.title,
    required this.fileNamePrefix,
    required this.exportPath,
    this.formats = const [ExportFormat.png],
    this.initialFormat = ExportFormat.png,
  });

  final String title;
  final String fileNamePrefix;
  final String Function(String fileName) exportPath;
  final List<ExportFormat> formats;
  final ExportFormat initialFormat;

  @override
  State<ImageExportSheet> createState() => _ImageExportSheetState();
}

class _ImageExportSheetState extends State<ImageExportSheet> {
  static final _invalidFileName = RegExp(r'[\\/:*?"<>|]');

  late ExportFormat _format;
  var _quality = 95;
  var _location = ExportLocation.pictures;
  late final TextEditingController _nameController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _format = widget.formats.contains(widget.initialFormat)
        ? widget.initialFormat
        : widget.formats.first;
    _nameController = TextEditingController(
      text: '${widget.fileNamePrefix}_${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: theme.textTheme.titleMedium),
            if (widget.formats.length > 1) ...[
              const SizedBox(height: 16),
              _sectionLabel('格式', theme),
              ExportFormatSelector(
                value: _format,
                onChanged: (format) => setState(() => _format = format),
              ),
            ],
            if (_format == ExportFormat.jpeg) ...[
              const SizedBox(height: 16),
              JpegQualitySelector(
                quality: _quality,
                onChanged: (quality) => setState(() => _quality = quality),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '文件名（不含扩展名）',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 16),
            _sectionLabel('保存位置', theme),
            ExportLocationSelector(
              value: _location,
              onChanged: (location) => setState(() => _location = location),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 20),
            _actionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: theme.textTheme.labelLarge),
  );

  Widget _actionButtons() => Row(
    children: [
      Expanded(
        child: OutlinedButton.icon(
          onPressed: () => _submit(ImageExportAction.share),
          icon: const Icon(Icons.share_outlined),
          label: const Text('分享'),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FilledButton.icon(
          onPressed: () => _submit(ImageExportAction.save),
          icon: const Icon(Icons.save_alt),
          label: const Text('保存'),
        ),
      ),
    ],
  );

  void _submit(ImageExportAction action) {
    final baseName = _nameController.text.trim();
    if (baseName.isEmpty || baseName.contains(_invalidFileName)) {
      setState(() => _error = '请输入有效文件名');
      return;
    }
    final fileName = '$baseName.${_format.extension}';
    Navigator.pop(
      context,
      ImageExportResult(
        path: widget.exportPath(fileName),
        format: _format,
        quality: _quality,
        fileName: fileName,
        mimeType: _format.mimeType,
        location: _location,
        action: action,
      ),
    );
  }
}
