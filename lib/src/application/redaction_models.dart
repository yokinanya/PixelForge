/// Domain models for the local image redaction workflow.
library;

import 'package:pixelforge/src/domain/models.dart';

enum RedactionStage { empty, previewing, analyzing, editing }

enum RedactionInteractionMode { normal, selection, freeBox }

enum DetectionKind {
  textLine,
  phone,
  email,
  url,
  ipAddress,
  longNumber,
  personName,
  address,
  qrCode,
  barcode,
  face,
}

enum MaskSource { automatic, manual }

enum MaskStyle { solid, blur }

enum MaskColorMode { adaptive, fixed }

class MaskStyleSettings {
  const MaskStyleSettings({
    required this.style,
    required this.colorMode,
    required this.color,
    required this.padding,
  });

  static const defaultSettings = MaskStyleSettings(
    style: MaskStyle.solid,
    colorMode: MaskColorMode.adaptive,
    color: 0xFF000000,
    padding: 2,
  );

  final MaskStyle style;
  final MaskColorMode colorMode;
  final int color;
  final double padding;

  MaskStyleSettings copyWith({
    MaskStyle? style,
    MaskColorMode? colorMode,
    int? color,
    double? padding,
  }) => MaskStyleSettings(
    style: style ?? this.style,
    colorMode: colorMode ?? this.colorMode,
    color: color ?? this.color,
    padding: padding ?? this.padding,
  );
}

class PixelRect {
  const PixelRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  PixelRect normalized() => PixelRect(
    left: left <= right ? left : right,
    top: top <= bottom ? top : bottom,
    right: left <= right ? right : left,
    bottom: top <= bottom ? bottom : top,
  );

  PixelRect expand(double amount) => PixelRect(
    left: left - amount,
    top: top - amount,
    right: right + amount,
    bottom: bottom + amount,
  );

  PixelRect clampTo(ImageSize size) {
    final rect = normalized();
    return PixelRect(
      left: rect.left.clamp(0, size.width.toDouble()).toDouble(),
      top: rect.top.clamp(0, size.height.toDouble()).toDouble(),
      right: rect.right.clamp(0, size.width.toDouble()).toDouble(),
      bottom: rect.bottom.clamp(0, size.height.toDouble()).toDouble(),
    );
  }

  bool contains(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  bool overlaps(PixelRect other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;

  PixelRect union(PixelRect other) => PixelRect(
    left: left < other.left ? left : other.left,
    top: top < other.top ? top : other.top,
    right: right > other.right ? right : other.right,
    bottom: bottom > other.bottom ? bottom : other.bottom,
  );

  Map<String, dynamic> toJson() => {
    'x': left.round(),
    'y': top.round(),
    'w': width.round(),
    'h': height.round(),
  };

  factory PixelRect.fromJson(Map<String, dynamic> json) {
    final x = (json['x'] as num).toDouble();
    final y = (json['y'] as num).toDouble();
    final width = (json['w'] as num).toDouble();
    final height = (json['h'] as num).toDouble();
    return PixelRect(left: x, top: y, right: x + width, bottom: y + height);
  }
}

class DetectionCandidate {
  const DetectionCandidate({
    required this.id,
    required this.kind,
    required this.text,
    required this.rect,
    required this.confidence,
    required this.selected,
    this.groupId,
  });

  final String id;
  final DetectionKind kind;
  final String? text;
  final PixelRect rect;
  final double confidence;
  final bool selected;
  final String? groupId;

  DetectionCandidate copyWith({bool? selected, PixelRect? rect}) =>
      DetectionCandidate(
        id: id,
        kind: kind,
        text: text,
        rect: rect ?? this.rect,
        confidence: confidence,
        selected: selected ?? this.selected,
        groupId: groupId,
      );

  MaskRegion toMask({
    MaskStyleSettings settings = MaskStyleSettings.defaultSettings,
  }) => MaskRegion(
    id: 'mask_$id',
    rect: rect.expand(settings.padding),
    sourceRect: rect,
    source: MaskSource.automatic,
    style: settings.style,
    colorMode: settings.colorMode,
    color: settings.color,
  );
}

class MaskRegion {
  const MaskRegion({
    required this.id,
    required this.rect,
    required this.sourceRect,
    required this.source,
    required this.style,
    required this.colorMode,
    required this.color,
  });

  final String id;
  final PixelRect rect;
  final PixelRect sourceRect;
  final MaskSource source;
  final MaskStyle style;
  final MaskColorMode colorMode;
  final int color;

  MaskRegion copyWith({
    PixelRect? rect,
    PixelRect? sourceRect,
    MaskStyle? style,
    MaskColorMode? colorMode,
    int? color,
  }) => MaskRegion(
    id: id,
    rect: rect ?? this.rect,
    sourceRect: sourceRect ?? this.sourceRect,
    source: source,
    style: style ?? this.style,
    colorMode: colorMode ?? this.colorMode,
    color: color ?? this.color,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'rect': rect.toJson(),
    'source': source.name,
    'style': style.name,
    'adaptive': colorMode == MaskColorMode.adaptive,
    'color': color,
  };
}

class RedactionDetectionResult {
  const RedactionDetectionResult({
    required this.size,
    required this.rawDetections,
  });

  final ImageSize size;
  final List<RawDetection> rawDetections;
}

class TextFragment {
  const TextFragment({
    required this.text,
    required this.rect,
    this.symbols = const [],
  });

  final String text;
  final PixelRect rect;
  final List<TextSymbol> symbols;
}

class TextSymbol {
  const TextSymbol({required this.text, required this.rect});

  final String text;
  final PixelRect rect;
}

class RawDetection {
  const RawDetection({
    required this.kind,
    required this.rect,
    this.text,
    this.confidence = 0.0,
    this.fragments = const [],
    this.recognizer,
  });

  final String kind;
  final PixelRect rect;
  final String? text;
  final double confidence;
  final List<TextFragment> fragments;
  final String? recognizer;
}
