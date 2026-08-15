/// 导出面板：格式、尺寸、质量、文件名与保存位置。
library;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/features/export/image_export_controls.dart';

enum ExportAction { save, share }

class ExportResult {
  const ExportResult({
    required this.path,
    required this.format,
    required this.fileName,
    required this.mimeType,
    required this.location,
    required this.action,
  });

  final String path;
  final String format;
  final String fileName;
  final String mimeType;
  final ExportLocation location;
  final ExportAction action;
}

/// 导出设置底部面板。
class ExportSheet extends StatefulWidget {
  const ExportSheet({super.key, required this.session});

  final SessionController session;

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  static const _customScale = 0;

  late ExportFormat _format;
  late ExportLocation _location;
  late int _quality;
  late int _scaleChoice;
  late TextEditingController _fileNameController;
  late TextEditingController _customWidthController;
  bool _saving = false;
  String? _errorText;

  int get _originalWidth => widget.session.images.first.size.width;

  @override
  void initState() {
    super.initState();
    final settings = widget.session.exportSettings;
    _format = settings.format;
    _location = ExportLocation.pictures;
    _quality = imageJpegQualityOptions.containsKey(settings.jpegQuality)
        ? settings.jpegQuality
        : 95;
    _scaleChoice = switch (settings.scalePercent) {
      100 || 90 || 75 => settings.scalePercent,
      _ => _customScale,
    };
    final customWidth = (_originalWidth * settings.scalePercent / 100).round();
    _customWidthController = TextEditingController(
      text: customWidth.toString(),
    );
    _fileNameController = TextEditingController(
      text: 'pixelforge_export_${DateTime.now().millisecondsSinceEpoch}',
    );
  }

  @override
  void dispose() {
    _fileNameController.dispose();
    _customWidthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final customScale = _scaleChoice == _customScale;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('导出设置', style: theme.textTheme.titleMedium),
              const SizedBox(height: 12),
              _sectionLabel('格式', theme),
              ExportFormatSelector(
                value: _format,
                enabled: !_saving,
                onChanged: (format) => setState(() => _format = format),
              ),
              const SizedBox(height: 12),
              _sectionLabel('导出尺寸', theme),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _scaleChip(100, '原图'),
                  _scaleChip(90, '90%'),
                  _scaleChip(75, '75%'),
                  _scaleChip(_customScale, '自定义'),
                ],
              ),
              if (customScale) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _customWidthController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '宽度（px）',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() => _errorText = null),
                ),
              ],
              if (_format == ExportFormat.jpeg) ...[
                const SizedBox(height: 12),
                JpegQualitySelector(
                  quality: _quality,
                  enabled: !_saving,
                  onChanged: (quality) => setState(() => _quality = quality),
                ),
              ],
              const SizedBox(height: 12),
              _sectionLabel('文件名', theme),
              TextField(
                controller: _fileNameController,
                decoration: const InputDecoration(
                  hintText: '不含扩展名',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() => _errorText = null),
              ),
              const SizedBox(height: 12),
              _sectionLabel('保存位置', theme),
              ExportLocationSelector(
                value: _location,
                enabled: !_saving,
                onChanged: (location) => setState(() => _location = location),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorText!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _share,
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('分享'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_alt),
                      label: Text(_saving ? '准备中…' : '保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: theme.textTheme.labelLarge),
  );

  Widget _scaleChip(int value, String label) => ChoiceChip(
    label: Text(label),
    selected: _scaleChoice == value,
    onSelected: _saving
        ? null
        : (_) => setState(() {
            _scaleChoice = value;
            _errorText = null;
          }),
  );

  int? _resolveScalePercent() {
    if (_scaleChoice != _customScale) return _scaleChoice;
    final width = int.tryParse(_customWidthController.text.trim());
    if (width == null || width <= 0) {
      _errorText = '请输入有效的图片宽度';
      return null;
    }
    if (_originalWidth <= 0 || width > _originalWidth) {
      _errorText = '自定义宽度不能大于原图宽度';
      return null;
    }
    return (width * 100 / _originalWidth).round().clamp(1, 100).toInt();
  }

  String? _resolveFileName() {
    final name = _fileNameController.text.trim();
    if (name.isEmpty) {
      _errorText = '请输入文件名';
      return null;
    }
    if (name.contains(RegExp(r'[\\/:*?"<>|]'))) {
      _errorText = '文件名包含不可用字符';
      return null;
    }
    return '$name.${_format.extension}';
  }

  Future<void> _save() => _prepare(ExportAction.save);

  Future<void> _share() => _prepare(ExportAction.share);

  Future<void> _prepare(ExportAction action) async {
    final scalePercent = _resolveScalePercent();
    final fileName = _resolveFileName();
    if (scalePercent == null || fileName == null) {
      setState(() {});
      return;
    }
    setState(() => _saving = true);
    try {
      widget.session.applyExportSettings(
        format: _format,
        jpegQuality: _quality,
        scalePercent: scalePercent,
        removeStatusBar: widget.session.exportSettings.removeStatusBar,
        trimBottomWhitespace:
            widget.session.exportSettings.trimBottomWhitespace,
        retainedBottomEdge: widget.session.exportSettings.retainedBottomEdge,
        refreshPreview: false,
      );
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$fileName';
      if (!mounted) return;
      Navigator.pop(
        context,
        ExportResult(
          path: path,
          format: _format.rustName,
          fileName: fileName,
          mimeType: _format.mimeType,
          location: _location,
          action: action,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _errorText = '准备导出失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
