/// Builds privacy candidates from local OCR and visual detectors.
library;

import 'redaction_address_merger.dart';
import 'redaction_candidate_deduper.dart';
import 'redaction_geometry.dart';
import 'redaction_models.dart';
import 'redaction_ocr_line_merger.dart';
import 'redaction_ocr_normalizer.dart';
import 'redaction_rule_models.dart';
import 'redaction_text_rules.dart';
import 'redaction_word_tokenizer.dart';

class SensitiveTextClassifier {
  static const _labeledNameConfidence = 0.95;
  static const _narrativeNameLeadingOffsetRatio = 0.2;

  final _lineMerger = RedactionOcrLineMerger();
  final _addressMerger = RedactionAddressMerger();
  final _candidateDeduper = RedactionCandidateDeduper();

  List<DetectionCandidate> classify(List<RawDetection> raw) {
    final lines = _addressMerger.merge(_lineMerger.merge(raw));
    final candidates = <DetectionCandidate>[];
    for (var index = 0; index < lines.length; index++) {
      _addCandidates(candidates, lines[index], lines, index);
    }
    final visible = _suppressTextUnderCodes(candidates);
    return _candidateDeduper.deduplicate(visible);
  }

  void _addCandidates(
    List<DetectionCandidate> output,
    RawDetection item,
    List<RawDetection> context,
    int index,
  ) {
    final visualKind = _visualKind(item.kind);
    if (visualKind != null) {
      output.add(
        _candidate(
          id: 'candidate_${output.length}',
          kind: visualKind,
          text: item.text,
          rect: item.rect,
          confidence: item.confidence > 0 ? item.confidence : 0.98,
          selected: true,
        ),
      );
      return;
    }
    final text = RedactionOcrNormalizer.normalize(item.text ?? '');
    if (text.trim().isEmpty || !_hasRecognizedCharacter(text)) return;
    final matches = _matches(item, text, context, index);
    for (final match in matches) {
      output.add(
        _candidate(
          id: 'candidate_${output.length}',
          kind: match.kind,
          text: match.text,
          rect: _rectForMatch(item, match),
          confidence: match.confidence,
          selected:
              match.selected ||
              (match.kind == DetectionKind.personName &&
                  _hasExplicitNameContext(context, index)),
        ),
      );
    }
    if (item.kind != 'textLine') return;
    if (!_isLikelyText(text)) return;
    _addWordCandidates(output, item, text, matches);
  }

  List<TextRuleMatch> _matches(
    RawDetection item,
    String text,
    List<RawDetection> context,
    int index,
  ) {
    final matches = RedactionTextRules.matches(
      item: RawDetection(
        kind: item.kind,
        rect: item.rect,
        text: text,
        confidence: item.confidence,
        fragments: item.fragments,
        recognizer: item.recognizer,
      ),
      previousText: _contextText(context, index - 1),
      nextText: _contextText(context, index + 1),
    );
    if (matches.any((match) => match.kind == DetectionKind.address) ||
        !_isAddressBlock(item, context, index)) {
      return matches;
    }
    return [
      ...matches,
      TextRuleMatch(
        kind: DetectionKind.address,
        start: 0,
        end: text.length,
        text: text.trim(),
        confidence: 0.72,
        selected: true,
      ),
    ];
  }

  void _addWordCandidates(
    List<DetectionCandidate> output,
    RawDetection item,
    String text,
    List<TextRuleMatch> matches,
  ) {
    final sensitiveRects = [
      for (final match in matches) RedactionGeometry.forMatch(item, match),
    ];
    final protectedTokens = [
      for (final match in matches)
        if (match.kind == DetectionKind.personName)
          RedactionWordToken(
            start: match.start,
            end: match.end,
            text: match.text,
          ),
    ];
    final tokens = RedactionWordTokenizer.tokenize(
      text,
      protectedTokens: protectedTokens,
    );
    final groupId = 'text_group_${output.length}';
    final hasNonTokenSensitive = matches.any(
      (match) =>
          match.kind != DetectionKind.address &&
          match.kind != DetectionKind.personName,
    );
    for (final token in tokens) {
      final rect = RedactionGeometry.forSpan(item, token.start, token.end);
      if (rect.width < 2 || rect.height < 2) continue;
      if (hasNonTokenSensitive && sensitiveRects.any(rect.overlaps)) continue;
      output.add(
        _candidate(
          id: 'text_word_${output.length}',
          kind: DetectionKind.textLine,
          text: token.text,
          rect: rect,
          confidence: item.confidence,
          selected: false,
          groupId: groupId,
        ),
      );
    }
  }

  DetectionCandidate _candidate({
    required String id,
    required DetectionKind kind,
    required String? text,
    required PixelRect rect,
    required double confidence,
    required bool selected,
    String? groupId,
  }) => DetectionCandidate(
    id: id,
    kind: kind,
    text: text,
    rect: rect,
    confidence: confidence,
    selected: selected,
    groupId: groupId,
  );

  PixelRect _rectForMatch(RawDetection item, TextRuleMatch match) {
    final rect = RedactionGeometry.forMatch(item, match);
    if (match.kind != DetectionKind.personName ||
        match.confidence >= _labeledNameConfidence) {
      return rect;
    }
    final offset = rect.height * _narrativeNameLeadingOffsetRatio;
    return PixelRect(
      left: rect.left - offset,
      top: rect.top,
      right: rect.right - offset,
      bottom: rect.bottom,
    );
  }

  String? _contextText(List<RawDetection> context, int index) {
    if (index < 0 || index >= context.length) return null;
    return RedactionOcrNormalizer.normalize(context[index].text ?? '');
  }

  bool _hasExplicitNameContext(List<RawDetection> context, int index) {
    final text = [
      _contextText(context, index - 1),
      _contextText(context, index),
      _contextText(context, index + 1),
    ].whereType<String>().join();
    return RegExp(
      r'(?:姓\s*名|联\s*系\s*人|收\s*件\s*人|开\s*户\s*名|负\s*责\s*人|作\s*者|著\s*作\s*权\s*人|创\s*作\s*者)',
    ).hasMatch(text);
  }

  DetectionKind? _visualKind(String kind) => switch (kind) {
    'qrCode' => DetectionKind.qrCode,
    'barcode' => DetectionKind.barcode,
    'face' => DetectionKind.face,
    _ => null,
  };

  bool _isAddressBlock(
    RawDetection line,
    List<RawDetection> context,
    int index,
  ) {
    final lineText = RedactionOcrNormalizer.normalize(line.text ?? '').trim();
    if (lineText.isEmpty) return false;
    final start = (index - 3).clamp(0, index).toInt();
    for (var anchorIndex = start; anchorIndex < index; anchorIndex++) {
      final anchor = context[anchorIndex];
      final anchorText = RedactionOcrNormalizer.normalize(anchor.text ?? '');
      final hasLabel = RegExp(
        r'(?:地\s*址|收\s*货\s*地\s*址|收\s*件\s*地\s*址|住\s*址|发\s*货\s*地\s*址)',
      ).hasMatch(anchorText);
      if (!hasLabel && !_addressMerger.looksLikeAddress(anchorText)) continue;
      final height = anchor.rect.height > line.rect.height
          ? anchor.rect.height
          : line.rect.height;
      final startsBelow = line.rect.top >= anchor.rect.top - height * 0.4;
      final close = line.rect.top <= anchor.rect.bottom + height * 4;
      final aligned = (anchor.rect.left - line.rect.left).abs() <= height * 2.2;
      if (startsBelow && close && aligned) return true;
    }
    return false;
  }

  List<DetectionCandidate> _suppressTextUnderCodes(
    List<DetectionCandidate> candidates,
  ) {
    final codes = candidates.where(
      (candidate) =>
          candidate.kind == DetectionKind.qrCode ||
          candidate.kind == DetectionKind.barcode,
    );
    return [
      for (final candidate in candidates)
        if (!codes.any(
          (code) =>
              code.rect.overlaps(candidate.rect) &&
              candidate.kind != DetectionKind.qrCode &&
              candidate.kind != DetectionKind.barcode,
        ))
          candidate,
    ];
  }

  bool _hasRecognizedCharacter(String text) =>
      RegExp(r'[\u4e00-\u9fffA-Za-z0-9]').hasMatch(text);

  bool _isLikelyText(String text) {
    final compact = text.replaceAll(RegExp(r'\s'), '');
    if (compact.length < 8) return true;
    final unique = compact.runes.toSet().length;
    return unique / compact.length >= 0.35;
  }
}
