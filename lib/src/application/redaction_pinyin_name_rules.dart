/// Context-aware rules for romanized Chinese names in OCR output.
library;

import 'redaction_models.dart';
import 'redaction_pinyin_lexicon.dart';
import 'redaction_rule_models.dart';

class RedactionPinyinNameRules {
  static const _minimumNameWords = 2;
  static const _maximumNameWords = 3;
  static const _maximumLatinWordLength = 32;
  static final _latinWord = RegExp('[A-Za-z]{2,$_maximumLatinWordLength}');
  static final _nameLabel = RegExp(
    r'(?:姓\s*名|联\s*系\s*人|收\s*件\s*人|开\s*户\s*名|负\s*责\s*人|作\s*者|著\s*作\s*权\s*人|创\s*作\s*者|(?:full\s+)?name\b|contact(?:\s+person)?\b|recipient\b|author\b|applicant\b|surname\b|given\s+name\b)\s*[:：=\-]?\s*',
    caseSensitive: false,
  );
  static final _nameSeparator = RegExp(r"^[\s·•.'-]+$");
  static final _standaloneBoundary = RegExp(
    r'''^[\s·•.,，。；;：:、（）()【】\[\]"“”‘’\-]+$''',
  );
  static final _narrativeBefore = RegExp(
    r'(?:由|申请人|联\s*系\s*人|收\s*件\s*人|负\s*责\s*人|作\s*者|来自|为|给|by|from|contact(?:ed)?|applicant|author|recipient)\s*$',
    caseSensitive: false,
  );
  static final _narrativeAfter = RegExp(
    r'^\s*(?:经|申请|办理|提交|签署|审核|负责|制作|完成|联系|寄送|applied|submitted|signed|reviewed|handled|contacted)\b',
    caseSensitive: false,
  );

  static List<TextRuleMatch> matches({
    required String text,
    String? previousText,
    String? nextText,
  }) {
    final found = <TextRuleMatch>[];
    final neighborLabel =
        _hasNameLabel(previousText) || _hasNameLabel(nextText);
    for (final candidate in _candidates(text)) {
      final inlineLabel = _hasInlineLabel(text, candidate);
      final narrative = _hasNarrativeContext(text, candidate);
      final standalone = _isStandalone(text, candidate);
      if (!inlineLabel && !neighborLabel && !narrative && !standalone) {
        continue;
      }
      found.add(
        TextRuleMatch(
          kind: DetectionKind.personName,
          start: candidate.start,
          end: candidate.end,
          text: candidate.text,
          confidence: inlineLabel || neighborLabel || standalone ? 0.96 : 0.88,
          selected: true,
        ),
      );
    }
    return found;
  }

  static List<_PinyinSpan> _candidates(String text) {
    final words = _latinWord.allMatches(text).toList();
    final candidates = <_PinyinSpan>[];
    var groupStart = 0;
    while (groupStart < words.length) {
      var groupEnd = groupStart;
      while (groupEnd + 1 < words.length &&
          _isSeparator(
            text.substring(words[groupEnd].end, words[groupEnd + 1].start),
          )) {
        groupEnd++;
      }
      _addGroupedCandidates(text, words, groupStart, groupEnd, candidates);
      groupStart = groupEnd + 1;
    }
    for (final word in words) {
      if (_isJoinedName(word.group(0)!)) {
        candidates.add(
          _PinyinSpan(start: word.start, end: word.end, text: word.group(0)!),
        );
      }
    }
    return _selectLongest(candidates);
  }

  static void _addGroupedCandidates(
    String text,
    List<RegExpMatch> words,
    int groupStart,
    int groupEnd,
    List<_PinyinSpan> output,
  ) {
    for (var size = _maximumNameWords; size >= _minimumNameWords; size--) {
      if (groupEnd - groupStart + 1 < size) continue;
      for (var start = groupStart; start + size - 1 <= groupEnd; start++) {
        final selected = words.sublist(start, start + size);
        final values = selected.map((word) => word.group(0)!).toList();
        if (!_isPinyinName(values)) continue;
        output.add(
          _PinyinSpan(
            start: selected.first.start,
            end: selected.last.end,
            text: text.substring(selected.first.start, selected.last.end),
          ),
        );
      }
    }
  }

  static List<_PinyinSpan> _selectLongest(List<_PinyinSpan> candidates) {
    final sorted = [...candidates]
      ..sort((first, second) {
        final start = first.start.compareTo(second.start);
        return start == 0
            ? (second.end - second.start).compareTo(first.end - first.start)
            : start;
      });
    final selected = <_PinyinSpan>[];
    for (final candidate in sorted) {
      final overlaps = selected.any(
        (item) => candidate.start < item.end && candidate.end > item.start,
      );
      if (!overlaps) selected.add(candidate);
    }
    return selected;
  }

  static bool _isPinyinName(List<String> words) {
    if (words.length < _minimumNameWords || words.length > _maximumNameWords) {
      return false;
    }
    final normalized = words.map((word) => word.toLowerCase()).toList();
    final hasSurname = normalized.any(RedactionPinyinLexicon.surnames.contains);
    return hasSurname && normalized.every(RedactionPinyinLexicon.isWord);
  }

  static bool _isJoinedName(String value) {
    final normalized = value.toLowerCase();
    final surnames = [...RedactionPinyinLexicon.surnames]
      ..sort((first, second) => second.length.compareTo(first.length));
    for (final surname in surnames) {
      if (!normalized.startsWith(surname) ||
          normalized.length <= surname.length + 1) {
        continue;
      }
      final givenName = normalized.substring(surname.length);
      if (RedactionPinyinLexicon.isWord(givenName)) return true;
    }
    return false;
  }

  static bool _hasInlineLabel(String text, _PinyinSpan candidate) {
    for (final label in _nameLabel.allMatches(text)) {
      if (label.end > candidate.start) continue;
      final gap = text.substring(label.end, candidate.start);
      if (_isSeparator(gap)) return true;
    }
    return false;
  }

  static bool _hasNameLabel(String? text) =>
      text != null && _nameLabel.hasMatch(text);

  static bool _isStandalone(String text, _PinyinSpan candidate) {
    final before = text.substring(0, candidate.start);
    final after = text.substring(candidate.end);
    return _isBoundary(before) && _isBoundary(after);
  }

  static bool _hasNarrativeContext(String text, _PinyinSpan candidate) {
    final beforeStart = (candidate.start - 32)
        .clamp(0, candidate.start)
        .toInt();
    final afterEnd = (candidate.end + 32)
        .clamp(candidate.end, text.length)
        .toInt();
    final before = text.substring(beforeStart, candidate.start);
    final after = text.substring(candidate.end, afterEnd);
    return _narrativeBefore.hasMatch(before) || _narrativeAfter.hasMatch(after);
  }

  static bool _isSeparator(String value) =>
      value.isNotEmpty && _nameSeparator.hasMatch(value);

  static bool _isBoundary(String value) =>
      value.isEmpty || _standaloneBoundary.hasMatch(value);
}

class _PinyinSpan {
  const _PinyinSpan({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}
