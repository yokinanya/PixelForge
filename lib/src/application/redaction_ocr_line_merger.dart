/// Reconstructs a single reading-order OCR line from multiple recognizers.
library;

import 'dart:math' as math;

import 'redaction_models.dart';

class RedactionOcrLineMerger {
  List<RawDetection> merge(List<RawDetection> raw) {
    final textLines =
        raw
            .where((item) => item.kind == 'textLine' && _isLineGeometry(item))
            .toList()
          ..sort(_comparePosition);
    final groups = <List<RawDetection>>[];
    for (final line in textLines) {
      final group = _findGroup(groups, line);
      if (group == null) {
        groups.add([line]);
      } else {
        group.add(line);
      }
    }
    final merged = <RawDetection>[
      ...raw.where((item) => item.kind != 'textLine'),
      for (final group in groups) _mergeGroup(group),
    ]..sort(_comparePosition);
    return merged;
  }

  List<RawDetection>? _findGroup(
    List<List<RawDetection>> groups,
    RawDetection candidate,
  ) {
    for (final group in groups) {
      if (_sameVisualLine(group, candidate)) return group;
    }
    return null;
  }

  RawDetection _mergeGroup(List<RawDetection> group) {
    if (group.length == 1) return group.single;
    final ordered = [...group]..sort(_compareRecognizerPriority);
    final primary = ordered.first;
    final symbols = _mergeSymbols(ordered);
    if (symbols.isEmpty) return primary;
    final symbolText = symbols.map((symbol) => symbol.text).join();
    final compatible = _compatibleText(primary.text, symbolText);
    final text = compatible ? symbolText : primary.text ?? symbolText;
    final symbolRect = symbols
        .skip(1)
        .fold(symbols.first.rect, (rect, symbol) => rect.union(symbol.rect));
    return RawDetection(
      kind: 'textLine',
      text: text,
      rect: group
          .skip(1)
          .fold(group.first.rect, (rect, item) => rect.union(item.rect)),
      confidence: group.map((item) => item.confidence).reduce(math.max),
      recognizer: primary.recognizer,
      fragments: compatible
          ? [TextFragment(text: text, rect: symbolRect, symbols: symbols)]
          : primary.fragments,
    );
  }

  bool _compatibleText(String? primary, String symbols) {
    if (primary == null || primary.trim().isEmpty) return true;
    final first = _compact(primary);
    final second = _compact(symbols);
    return first == second;
  }

  String _compact(String value) =>
      value.replaceAll(RegExp(r'[\s，。；：、！？（）【】「」“”‘’]'), '');

  List<TextSymbol> _mergeSymbols(List<RawDetection> lines) {
    final merged = <TextSymbol>[];
    for (final line in lines) {
      for (final fragment in line.fragments) {
        for (final symbol in fragment.symbols) {
          if (_hasOverlappingSymbol(merged, symbol)) continue;
          merged.add(symbol);
        }
      }
    }
    return merged..sort(_compareSymbolPosition);
  }

  bool _hasOverlappingSymbol(List<TextSymbol> symbols, TextSymbol candidate) {
    return symbols.any((existing) {
      final overlapWidth =
          math.min(existing.rect.right, candidate.rect.right) -
          math.max(existing.rect.left, candidate.rect.left);
      final overlapHeight =
          math.min(existing.rect.bottom, candidate.rect.bottom) -
          math.max(existing.rect.top, candidate.rect.top);
      if (overlapWidth <= 0 || overlapHeight <= 0) return false;
      final minWidth = math.min(existing.rect.width, candidate.rect.width);
      final minHeight = math.min(existing.rect.height, candidate.rect.height);
      return overlapWidth / minWidth >= 0.45 &&
          overlapHeight / minHeight >= 0.45;
    });
  }

  bool _sameVisualLine(List<RawDetection>? group, RawDetection candidate) {
    if (group == null || group.isEmpty) return false;
    if (!_isLineGeometry(candidate)) return false;
    return group.any((line) {
      if (!_isLineGeometry(line)) return false;
      final verticalOverlap =
          math.min(line.rect.bottom, candidate.rect.bottom) -
          math.max(line.rect.top, candidate.rect.top);
      if (verticalOverlap <= 0) return false;
      final height = math.min(line.rect.height, candidate.rect.height);
      if (verticalOverlap / height < 0.45) return false;
      if (line.fragments.every((fragment) => fragment.symbols.isEmpty) &&
          candidate.fragments.every((fragment) => fragment.symbols.isEmpty)) {
        final horizontalOverlap =
            math.min(line.rect.right, candidate.rect.right) -
            math.max(line.rect.left, candidate.rect.left);
        final minWidth = math.min(line.rect.width, candidate.rect.width);
        if (horizontalOverlap / minWidth < 0.65) return false;
      }
      final horizontalGap = _horizontalGap(line.rect, candidate.rect);
      return horizontalGap <=
          math.max(line.rect.height, candidate.rect.height) * 2.5;
    });
  }

  bool _isLineGeometry(RawDetection item) {
    final width = item.rect.width;
    final height = item.rect.height;
    if (width <= 0 || height <= 0) return false;
    return height <= width * 8;
  }

  static double _horizontalGap(PixelRect first, PixelRect second) {
    if (first.overlaps(second)) return 0;
    if (first.right < second.left) return second.left - first.right;
    return first.left - second.right;
  }

  static int _comparePosition(RawDetection first, RawDetection second) {
    final top = first.rect.top.compareTo(second.rect.top);
    return top == 0 ? first.rect.left.compareTo(second.rect.left) : top;
  }

  static int _compareSymbolPosition(TextSymbol first, TextSymbol second) {
    final top = first.rect.top.compareTo(second.rect.top);
    return top == 0 ? first.rect.left.compareTo(second.rect.left) : top;
  }

  static int _compareRecognizerPriority(
    RawDetection first,
    RawDetection second,
  ) {
    final firstScore = _recognizerScore(first);
    final secondScore = _recognizerScore(second);
    if (firstScore != secondScore) return secondScore.compareTo(firstScore);
    return second.fragments.length.compareTo(first.fragments.length);
  }

  static int _recognizerScore(RawDetection item) {
    final text = item.text ?? '';
    final hasHan = RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
    final hasLatin = RegExp(r'[A-Za-z0-9]').hasMatch(text);
    if (item.recognizer == 'chinese' && hasHan) return 4;
    if (item.recognizer == 'latin' && !hasHan && hasLatin) return 3;
    if (hasHan) return 2;
    return hasLatin ? 1 : 0;
  }
}
