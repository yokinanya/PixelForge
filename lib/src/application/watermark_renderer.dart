/// 在图片上绘制重复斜向水印并导出 PNG。
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pixelforge/src/features/watermark/watermark_painter.dart';

class WatermarkRenderer {
  const WatermarkRenderer._();

  static Future<void> render({
    required String sourcePath,
    required String text,
    required String outPath,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(sourcePath);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final codec = await descriptor.instantiateCodec();
        try {
          await _renderCodec(codec, text, outPath);
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  static Future<void> _renderCodec(
    ui.Codec codec,
    String text,
    String outPath,
  ) async {
    final frame = await codec.getNextFrame();
    final source = frame.image;
    try {
      final size = Size(source.width.toDouble(), source.height.toDouble());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(source, Offset.zero, Paint());
      paintWatermark(canvas, size, text);
      final output = await recorder.endRecording().toImage(
        source.width,
        source.height,
      );
      try {
        final outputData = await output.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (outputData == null) throw StateError('无法生成水印图片');
        await _writeAtomic(outPath, outputData.buffer.asUint8List());
      } finally {
        output.dispose();
      }
    } finally {
      source.dispose();
    }
  }

  static Future<void> _writeAtomic(String outPath, List<int> bytes) async {
    final temporaryPath =
        '$outPath.tmp-${DateTime.now().microsecondsSinceEpoch}';
    final temporary = File(temporaryPath);
    try {
      await temporary.writeAsBytes(bytes);
      final target = File(outPath);
      if (await target.exists()) await target.delete();
      await temporary.rename(outPath);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}
