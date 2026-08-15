/// Shared result types for deterministic OCR rules.
library;

import 'redaction_models.dart';

class TextRuleMatch {
  const TextRuleMatch({
    required this.kind,
    required this.start,
    required this.end,
    required this.text,
    required this.confidence,
    required this.selected,
  });

  final DetectionKind kind;
  final int start;
  final int end;
  final String text;
  final double confidence;
  final bool selected;
}
