/// Controls for the visual style of all current redaction regions.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/application/redaction_controller.dart';
import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/features/redaction/redaction_color_picker.dart';

class RedactionStyleControls extends StatelessWidget {
  const RedactionStyleControls({super.key, required this.session});

  final RedactionController session;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('实心块'),
              selected: session.maskStyle == MaskStyle.solid,
              onSelected: (_) => session.setMaskStyle(MaskStyle.solid),
            ),
            ChoiceChip(
              label: const Text('模糊'),
              selected: session.maskStyle == MaskStyle.blur,
              onSelected: (_) => session.setMaskStyle(MaskStyle.blur),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('遮罩边缘扩展 ${session.maskPadding.round()} px'),
        Slider(
          value: session.maskPadding,
          min: 0,
          max: 12,
          divisions: 6,
          label: '${session.maskPadding.round()} px',
          onChanged: session.setMaskPadding,
        ),
        const SizedBox(height: 4),
        if (session.maskStyle == MaskStyle.solid) ...[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('自适应'),
                selected: session.maskColorMode == MaskColorMode.adaptive,
                onSelected: (_) =>
                    session.setMaskColorMode(MaskColorMode.adaptive),
              ),
              for (final preset in _presetColors)
                _ColorChip(preset: preset, session: session),
              ChoiceChip(
                avatar: _ColorSwatch(color: Color(session.maskColor)),
                label: const Text('自选'),
                selected: _isCustomColor(session),
                onSelected: (_) => _showColorDialog(context, session),
              ),
            ],
          ),
        ],
      ],
    );
  }

  bool _isCustomColor(RedactionController session) =>
      session.maskColorMode == MaskColorMode.fixed &&
      !_presetColors.any((preset) => preset.color == session.maskColor);

  Future<void> _showColorDialog(
    BuildContext context,
    RedactionController session,
  ) async {
    final color = await showDialog<int>(
      context: context,
      builder: (dialogContext) => MediaQuery.removeViewInsets(
        context: dialogContext,
        removeBottom: true,
        child: RedactionColorPickerDialog(initialColor: session.maskColor),
      ),
    );
    if (color != null) session.setMaskColor(color);
  }
}

class _ColorChip extends StatelessWidget {
  const _ColorChip({required this.preset, required this.session});

  final _PresetColor preset;
  final RedactionController session;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    avatar: _ColorSwatch(color: Color(preset.color)),
    label: Text(preset.label),
    selected:
        session.maskColorMode == MaskColorMode.fixed &&
        session.maskColor == preset.color,
    onSelected: (_) => session.setMaskColor(preset.color),
  );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: 9,
    backgroundColor: color,
    child: color.computeLuminance() < 0.35
        ? const Icon(Icons.check, size: 12, color: Colors.white)
        : const Icon(Icons.check, size: 12, color: Colors.black),
  );
}

class _PresetColor {
  const _PresetColor(this.label, this.color);

  final String label;
  final int color;
}

const _presetColors = <_PresetColor>[
  _PresetColor('黑色', 0xFF000000),
  _PresetColor('白色', 0xFFFFFFFF),
];
