/// Weighted Chinese word segmentation with pixel-preserving source offsets.
library;

import 'redaction_word_lexicon.dart';

class RedactionWordToken {
  const RedactionWordToken({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}

class RedactionWordTokenizer {
  static const _hanStart = 0x4E00;
  static const _hanEnd = 0x9FFF;
  static const _maxFallbackLength = 4;

  static List<RedactionWordToken> tokenize(
    String text, {
    List<RedactionWordToken> protectedTokens = const [],
  }) {
    final sorted = [...protectedTokens]
      ..sort((first, second) => first.start.compareTo(second.start));
    final tokens = <RedactionWordToken>[];
    var cursor = 0;
    for (final protectedToken in sorted) {
      final start = protectedToken.start.clamp(cursor, text.length).toInt();
      final end = protectedToken.end.clamp(start, text.length).toInt();
      if (start > cursor) tokens.addAll(_tokenizeRange(text, cursor, start));
      if (end <= start) continue;
      tokens.add(
        RedactionWordToken(
          start: start,
          end: end,
          text: protectedToken.text.replaceAll(_whitespace, ''),
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      tokens.addAll(_tokenizeRange(text, cursor, text.length));
    }
    return tokens;
  }

  static List<RedactionWordToken> _tokenizeRange(
    String text,
    int rangeStart,
    int rangeEnd,
  ) {
    final tokens = <RedactionWordToken>[];
    var index = rangeStart;
    while (index < rangeEnd) {
      if (_isSeparator(text.codeUnitAt(index))) {
        index++;
        continue;
      }
      final run = _readRun(text, index, rangeEnd);
      if (run.characters.isEmpty) {
        index++;
        continue;
      }
      tokens.addAll(
        run.isHan ? _segmentHanRun(run) : [_token(text, run.positions)],
      );
      index = run.end;
    }
    return tokens;
  }

  static List<RedactionWordToken> _segmentHanRun(_TextRun run) {
    final length = run.characters.length;
    final best = List<_Path?>.filled(length + 1, null);
    best[length] = const _Path(score: 0, words: []);
    for (var start = length - 1; start >= 0; start--) {
      final options = _matchesAt(run.characters, start);
      for (final option in options) {
        final tail = best[option.end];
        if (tail == null) continue;
        final candidate = _Path(
          score: option.score + tail.score,
          words: [option, ...tail.words],
        );
        if (best[start] == null || candidate.score > best[start]!.score) {
          best[start] = candidate;
        }
      }
    }
    final path = best.first;
    if (path == null) return [_tokenFromRun(run, 0, length)];
    return [
      for (final word in path.words) _tokenFromRun(run, word.start, word.end),
    ];
  }

  static List<_WordOption> _matchesAt(List<String> characters, int start) {
    final options = <_WordOption>[];
    for (final entry in RedactionWordLexicon.weights.entries) {
      final word = entry.key;
      if (!_matches(characters, word, start)) continue;
      options.add(
        _WordOption(
          start: start,
          end: start + word.length,
          score: entry.value + word.length * 0.22,
        ),
      );
    }
    final maxLength = (characters.length - start).clamp(1, _maxFallbackLength);
    for (var length = 1; length <= maxLength; length++) {
      options.add(
        _WordOption(
          start: start,
          end: start + length,
          score: _fallbackScore(length),
        ),
      );
    }
    return options;
  }

  static double _fallbackScore(int length) => switch (length) {
    1 => 0.35,
    2 => 1.15,
    3 => 1.5,
    _ => 3.2,
  };

  static bool _matches(List<String> characters, String word, int start) {
    if (start + word.length > characters.length) return false;
    for (var index = 0; index < word.length; index++) {
      if (characters[start + index] != word[index]) return false;
    }
    return true;
  }

  static _TextRun _readRun(String text, int start, int end) {
    final positions = <int>[];
    final characters = <String>[];
    final isHan = _isHan(text.codeUnitAt(start));
    var index = start;
    while (index < end) {
      final code = text.codeUnitAt(index);
      if (isHan && _isHan(code)) {
        positions.add(index);
        characters.add(text[index]);
        index++;
        continue;
      }
      if (isHan && _isWhitespace(code)) {
        var next = index + 1;
        while (next < end && _isWhitespace(text.codeUnitAt(next))) {
          next++;
        }
        if (next < end && _isHan(text.codeUnitAt(next))) {
          index = next;
          continue;
        }
      }
      if (!isHan && (_isAlphaNumeric(code) || _isWordConnector(code))) {
        positions.add(index);
        characters.add(text[index]);
        index++;
        continue;
      }
      break;
    }
    while (positions.isNotEmpty &&
        _isWordConnector(text.codeUnitAt(positions.last))) {
      positions.removeLast();
      characters.removeLast();
      index = positions.isEmpty ? start : positions.last + 1;
    }
    return _TextRun(index, isHan, characters, positions);
  }

  static RedactionWordToken _token(String text, List<int> positions) =>
      RedactionWordToken(
        start: positions.first,
        end: positions.last + 1,
        text: positions.map((index) => text[index]).join(),
      );

  static RedactionWordToken _tokenFromRun(_TextRun run, int start, int end) =>
      RedactionWordToken(
        start: run.positions[start],
        end: run.positions[end - 1] + 1,
        text: run.characters.sublist(start, end).join(),
      );

  static bool _isHan(int codeUnit) =>
      codeUnit >= _hanStart && codeUnit <= _hanEnd;

  static bool _isAlphaNumeric(int codeUnit) =>
      codeUnit >= 0x30 && codeUnit <= 0x39 ||
      codeUnit >= 0x41 && codeUnit <= 0x5A ||
      codeUnit >= 0x61 && codeUnit <= 0x7A;

  static bool _isWordConnector(int codeUnit) =>
      codeUnit == 0x2B ||
      codeUnit == 0x2D ||
      codeUnit == 0x2E ||
      codeUnit == 0x2F ||
      codeUnit == 0x3A ||
      codeUnit == 0x40 ||
      codeUnit == 0x5F;

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0B ||
      codeUnit == 0x0C ||
      codeUnit == 0x0D ||
      codeUnit == 0x20 ||
      codeUnit == 0xA0 ||
      codeUnit == 0x3000;

  static bool _isSeparator(int codeUnit) =>
      !_isHan(codeUnit) && !_isAlphaNumeric(codeUnit);
}

class _TextRun {
  const _TextRun(this.end, this.isHan, this.characters, this.positions);

  final int end;
  final bool isHan;
  final List<String> characters;
  final List<int> positions;
}

class _Path {
  const _Path({required this.score, required this.words});

  final double score;
  final List<_WordOption> words;
}

class _WordOption {
  const _WordOption({
    required this.start,
    required this.end,
    required this.score,
  });

  final int start;
  final int end;
  final double score;
}

final _whitespace = RegExp(r'\s');
