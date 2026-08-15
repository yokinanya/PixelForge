/// Length-preserving OCR correction for the local redaction pipeline.
library;

import 'redaction_word_lexicon.dart';

class RedactionOcrNormalizer {
  static const _aliases = <String, String>{'版權': '版权', '廣東省': '广东省'};

  static String normalize(String text) {
    var result = text;
    for (final entry in _aliases.entries) {
      result = _replaceExactTerm(result, entry.key, entry.value);
    }
    final terms = RedactionWordLexicon.correctionTerms.toList()
      ..sort((first, second) => second.length.compareTo(first.length));
    final replaced = <int>{};
    for (var start = 0; start < result.length; start++) {
      if (_isWhitespace(result[start]) || replaced.contains(start)) continue;
      for (final term in terms) {
        final positions = _nonWhitespaceSpan(result, start, term.length);
        if (positions == null || _distance(result, positions, term) != 1) {
          continue;
        }
        for (var index = 0; index < positions.length; index++) {
          result = result.replaceRange(
            positions[index],
            positions[index] + 1,
            term[index],
          );
          replaced.add(positions[index]);
        }
        break;
      }
    }
    return result;
  }

  static String _replaceExactTerm(
    String text,
    String source,
    String replacement,
  ) {
    var result = text;
    final replaced = <int>{};
    for (var start = 0; start < result.length; start++) {
      if (replaced.contains(start)) continue;
      final positions = _nonWhitespaceSpan(result, start, source.length);
      if (positions == null) continue;
      var matches = true;
      for (var index = 0; index < positions.length; index++) {
        if (result[positions[index]] != source[index]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      for (var index = 0; index < positions.length; index++) {
        result = result.replaceRange(
          positions[index],
          positions[index] + 1,
          replacement[index],
        );
        replaced.add(positions[index]);
      }
    }
    return result;
  }

  static List<int>? _nonWhitespaceSpan(String text, int start, int length) {
    final positions = <int>[];
    var index = start;
    while (index < text.length && positions.length < length) {
      if (_isWhitespace(text[index])) {
        index++;
        continue;
      }
      if (!_isHan(text[index])) return null;
      positions.add(index++);
    }
    return positions.length == length ? positions : null;
  }

  static int _distance(String text, List<int> positions, String term) {
    var distance = 0;
    for (var index = 0; index < positions.length; index++) {
      if (text[positions[index]] != term[index]) distance++;
    }
    return distance;
  }

  static bool _isHan(String value) {
    final code = value.codeUnitAt(0);
    return code >= 0x4E00 && code <= 0x9FFF;
  }

  static bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);
}
