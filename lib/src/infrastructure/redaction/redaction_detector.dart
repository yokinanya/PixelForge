/// Android MethodChannel adapter for local ML Kit detection.
library;

import 'package:flutter/services.dart';
import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/domain/models.dart';

abstract interface class RedactionDetector {
  Future<RedactionDetectionResult> analyze(String imagePath);
}

class MethodChannelRedactionDetector implements RedactionDetector {
  const MethodChannelRedactionDetector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('pixelforge/redaction');

  final MethodChannel _channel;

  @override
  Future<RedactionDetectionResult> analyze(String imagePath) async {
    final response = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'analyzeImage',
      {'imagePath': imagePath},
    );
    if (response == null) throw const FormatException('检测服务未返回结果');
    final width = (response['width'] as num?)?.toInt() ?? 0;
    final height = (response['height'] as num?)?.toInt() ?? 0;
    final raw = ((response['detections'] as List?) ?? const [])
        .map((item) => _parseRaw(item as Map<dynamic, dynamic>))
        .toList();
    return RedactionDetectionResult(
      size: ImageSize(width, height),
      rawDetections: raw,
    );
  }

  RawDetection _parseRaw(Map<dynamic, dynamic> item) {
    final fragments = ((item['fragments'] as List?) ?? const []).map((
      fragment,
    ) {
      final data = fragment as Map;
      final symbols = ((data['symbols'] as List?) ?? const []).map((symbol) {
        final symbolData = symbol as Map;
        return TextSymbol(
          text: symbolData['text'] as String,
          rect: PixelRect.fromJson(
            Map<String, dynamic>.from(symbolData['rect'] as Map),
          ),
        );
      }).toList();
      return TextFragment(
        text: data['text'] as String,
        rect: PixelRect.fromJson(
          Map<String, dynamic>.from(data['rect'] as Map),
        ),
        symbols: symbols,
      );
    }).toList();
    return RawDetection(
      kind: item['kind'] as String,
      text: item['text'] as String?,
      rect: PixelRect.fromJson(Map<String, dynamic>.from(item['rect'] as Map)),
      confidence: (item['confidence'] as num?)?.toDouble() ?? 0,
      fragments: fragments,
      recognizer: item['recognizer'] as String?,
    );
  }
}
