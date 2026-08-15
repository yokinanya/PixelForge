/// 水印预览与导出共用的绘制逻辑。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

const _watermarkOpacity = 0.18;
const _watermarkFontScale = 0.02;

void paintWatermark(Canvas canvas, Size size, String text) {
  final value = text.trim();
  if (value.isEmpty || size.isEmpty) return;
  final fontSize = (size.shortestSide * _watermarkFontScale)
      .clamp(10.0, 140.0)
      .toDouble();
  final painter = TextPainter(
    text: TextSpan(
      text: value,
      style: TextStyle(
        color: Colors.white.withValues(alpha: _watermarkOpacity),
        fontSize: fontSize,
        fontWeight: FontWeight.w400,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final stepX = math.max(painter.width * 1.8, fontSize * 8);
  final stepY = math.max(painter.height * 2.2, fontSize * 5);
  final range = size.longestSide * 1.35;
  // Difference mode automatically produces a light mark on dark pixels and
  // a dark mark on light pixels without sampling the full-resolution image.
  canvas.clipRect(Offset.zero & size, doAntiAlias: false);
  canvas.saveLayer(null, Paint()..blendMode = BlendMode.difference);
  canvas.translate(size.width / 2, size.height / 2);
  canvas.rotate(-math.pi / 7);
  for (var y = -range; y <= range; y += stepY) {
    for (var x = -range; x <= range; x += stepX) {
      painter.paint(canvas, Offset(x, y));
    }
  }
  canvas.restore();
}

class WatermarkPainter extends CustomPainter {
  const WatermarkPainter(this.text);

  final String text;

  @override
  void paint(Canvas canvas, Size size) => paintWatermark(canvas, size, text);

  @override
  bool shouldRepaint(covariant WatermarkPainter oldDelegate) =>
      oldDelegate.text != text;
}
