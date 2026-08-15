/// Shared controls used by image export sheets.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/domain/models.dart';

const imageJpegQualityOptions = <int, String>{95: '高', 85: '标准', 70: '小文件'};

class ExportFormatSelector extends StatelessWidget {
  const ExportFormatSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final ExportFormat value;
  final ValueChanged<ExportFormat> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final format in ExportFormat.values)
        ChoiceChip(
          label: Text(format.label),
          selected: value == format,
          onSelected: enabled ? (_) => onChanged(format) : null,
        ),
    ],
  );
}

class JpegQualitySelector extends StatelessWidget {
  const JpegQualitySelector({
    super.key,
    required this.quality,
    required this.onChanged,
    this.enabled = true,
  });

  final int quality;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('JPEG 质量', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in imageJpegQualityOptions.entries)
            ChoiceChip(
              label: Text('${entry.value} ${entry.key}'),
              selected: quality == entry.key,
              onSelected: enabled ? (_) => onChanged(entry.key) : null,
            ),
        ],
      ),
    ],
  );
}

class ExportLocationSelector extends StatelessWidget {
  const ExportLocationSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final ExportLocation value;
  final ValueChanged<ExportLocation> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final location in ExportLocation.values)
        ChoiceChip(
          label: Text(location.label),
          selected: value == location,
          onSelected: enabled ? (_) => onChanged(location) : null,
        ),
    ],
  );
}
