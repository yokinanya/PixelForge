/// Custom painters for the HSV color picker controls.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class RedactionSaturationValuePainter extends CustomPainter {
  const RedactionSaturationValuePainter(this.color);

  final HSVColor color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = color.withSaturation(1).withValue(1).toColor();
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(size.width, 0), [
          Colors.white,
          hue,
        ]),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), [
          Colors.transparent,
          Colors.black,
        ]),
    );
    final thumb = Offset(
      color.saturation * size.width,
      (1 - color.value) * size.height,
    );
    canvas.drawCircle(thumb, 9, Paint()..color = Colors.white);
    canvas.drawCircle(thumb, 7, Paint()..color = color.toColor());
  }

  @override
  bool shouldRepaint(RedactionSaturationValuePainter oldDelegate) =>
      oldDelegate.color != color;
}

class RedactionHuePainter extends CustomPainter {
  const RedactionHuePainter(this.hue);

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final colors = [
      for (final value in [0, 60, 120, 180, 240, 300, 360])
        HSVColor.fromAHSV(1, value.toDouble(), 1, 1).toColor(),
    ];
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(14)),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, 0),
          colors,
        ),
    );
    final x = hue / 360 * size.width;
    final center = Offset(x, size.height / 2);
    canvas.drawCircle(center, 9, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      7,
      Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
    );
  }

  @override
  bool shouldRepaint(RedactionHuePainter oldDelegate) => oldDelegate.hue != hue;
}
