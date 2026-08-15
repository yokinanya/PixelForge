/// In-app color picker for solid redaction masks.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/features/redaction/redaction_color_picker_widgets.dart';

class RedactionColorPickerDialog extends StatefulWidget {
  const RedactionColorPickerDialog({super.key, required this.initialColor});

  final int initialColor;

  @override
  State<RedactionColorPickerDialog> createState() =>
      _RedactionColorPickerDialogState();
}

class _RedactionColorPickerDialogState
    extends State<RedactionColorPickerDialog> {
  late final TextEditingController _controller;
  late HSVColor _selected;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected = HSVColor.fromColor(Color(widget.initialColor));
    _controller = TextEditingController(text: _hex(widget.initialColor));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 620),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RedactionPickerHeader(color: _selected.toColor()),
            const SizedBox(height: 14),
            Flexible(
              child: RedactionPickerBody(
                color: _selected,
                controller: _controller,
                error: _error,
                onSaturationValueChanged: _setSaturationAndValue,
                onHueChanged: _setHue,
                onColorSelected: _setColor,
                onHexChanged: _previewHex,
                onSubmit: _submit,
              ),
            ),
            const SizedBox(height: 8),
            RedactionPickerActions(
              onCancel: () => Navigator.pop(context),
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    ),
  );

  void _setSaturationAndValue(double saturation, double value) {
    _setSelection(_selected.withSaturation(saturation).withValue(value));
  }

  void _setHue(double hue) => _setSelection(_selected.withHue(hue));

  void _setColor(Color color) => _setSelection(HSVColor.fromColor(color));

  void _setSelection(HSVColor color) {
    final value = _hex(color.toColor().toARGB32());
    setState(() {
      _selected = color;
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      _error = null;
    });
  }

  void _previewHex(String value) {
    final parsed = _parseColor(value);
    if (parsed == null) return;
    setState(() {
      _selected = HSVColor.fromColor(Color(parsed));
      _error = null;
    });
  }

  void _submit() {
    final parsed = _parseColor(_controller.text);
    if (parsed == null) {
      setState(() => _error = '请输入 6 位或 8 位十六进制颜色');
      return;
    }
    Navigator.pop(context, parsed);
  }

  int? _parseColor(String value) {
    final raw = value.trim().replaceFirst('#', '');
    if (raw.length != 6 && raw.length != 8) return null;
    final parsed = int.tryParse(raw, radix: 16);
    if (parsed == null) return null;
    return raw.length == 6 ? 0xFF000000 | parsed : parsed;
  }

  String _hex(int color) =>
      '#${(color & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}
