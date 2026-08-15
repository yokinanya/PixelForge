/// Reusable visual pieces for the redaction color picker.
library;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/features/redaction/redaction_color_picker_painters.dart';

class RedactionPickerHeader extends StatelessWidget {
  const RedactionPickerHeader({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(
        child: Text(
          '选择遮挡颜色',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
      ),
      RedactionColorPreview(color: color, radius: 17),
    ],
  );
}

class RedactionPickerBody extends StatelessWidget {
  const RedactionPickerBody({
    super.key,
    required this.color,
    required this.controller,
    required this.error,
    required this.onSaturationValueChanged,
    required this.onHueChanged,
    required this.onColorSelected,
    required this.onHexChanged,
    required this.onSubmit,
  });

  final HSVColor color;
  final TextEditingController controller;
  final String? error;
  final void Function(double saturation, double value) onSaturationValueChanged;
  final ValueChanged<double> onHueChanged;
  final ValueChanged<Color> onColorSelected;
  final ValueChanged<String> onHexChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RedactionSaturationValuePicker(
          color: color,
          onChanged: onSaturationValueChanged,
        ),
        const SizedBox(height: 12),
        RedactionHuePicker(hue: color.hue, onChanged: onHueChanged),
        const SizedBox(height: 16),
        Text('常用颜色', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final paletteColor in _palette)
              _PaletteColorButton(
                color: paletteColor,
                selected: paletteColor.toARGB32() == color.toColor().toARGB32(),
                onTap: () => onColorSelected(paletteColor),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: controller,
          autofocus: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
          onChanged: onHexChanged,
          decoration: InputDecoration(
            labelText: '颜色值',
            hintText: '#RRGGBB 或 #AARRGGBB',
            prefixIcon: const Icon(Icons.tag),
            suffixIcon: RedactionColorPreview(color: color.toColor()),
            errorText: error,
            border: const OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.characters,
        ),
      ],
    ),
  );
}

class RedactionPickerActions extends StatelessWidget {
  const RedactionPickerActions({
    super.key,
    required this.onCancel,
    required this.onSubmit,
  });

  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Wrap(
      spacing: 8,
      children: [
        TextButton(onPressed: onCancel, child: const Text('取消')),
        FilledButton(onPressed: onSubmit, child: const Text('应用')),
      ],
    ),
  );
}

class RedactionColorPreview extends StatelessWidget {
  const RedactionColorPreview({
    super.key,
    required this.color,
    this.radius = 12,
  });

  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(8),
    child: CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Icon(
        Icons.check,
        size: radius,
        color: color.computeLuminance() < 0.35 ? Colors.white : Colors.black,
      ),
    ),
  );
}

class RedactionSaturationValuePicker extends StatelessWidget {
  const RedactionSaturationValuePicker({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final HSVColor color;
  final void Function(double saturation, double value) onChanged;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1.35,
    child: LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onPanDown: (details) => _update(details.localPosition, constraints),
        onPanUpdate: (details) => _update(details.localPosition, constraints),
        child: CustomPaint(
          painter: RedactionSaturationValuePainter(color),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  void _update(Offset position, BoxConstraints constraints) {
    final saturation = (position.dx / constraints.maxWidth).clamp(0.0, 1.0);
    final value = (1 - position.dy / constraints.maxHeight).clamp(0.0, 1.0);
    onChanged(saturation, value);
  }
}

class RedactionHuePicker extends StatelessWidget {
  const RedactionHuePicker({
    super.key,
    required this.hue,
    required this.onChanged,
  });

  final double hue;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    child: LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onPanDown: (details) => _update(details.localPosition.dx, constraints),
        onPanUpdate: (details) =>
            _update(details.localPosition.dx, constraints),
        child: CustomPaint(
          painter: RedactionHuePainter(hue),
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  void _update(double x, BoxConstraints constraints) {
    onChanged((x / constraints.maxWidth * 360).clamp(0.0, 360.0));
  }
}

class _PaletteColorButton extends StatelessWidget {
  const _PaletteColorButton({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message:
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected ? _paletteCheck(color) : null,
      ),
    ),
  );

  Widget _paletteCheck(Color color) => Icon(
    Icons.check,
    size: 18,
    color: color.computeLuminance() < 0.35 ? Colors.white : Colors.black,
  );
}

const _palette = <Color>[
  Color(0xFF000000),
  Color(0xFF434343),
  Color(0xFF999999),
  Color(0xFFFFFFFF),
  Color(0xFFFF0000),
  Color(0xFFFF9900),
  Color(0xFFFFFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFFF),
  Color(0xFF4A86E8),
  Color(0xFF0000FF),
  Color(0xFFFF00FF),
];
