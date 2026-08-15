/// Maps OCR character spans to original-image pixel rectangles.
library;

import 'redaction_models.dart';
import 'redaction_rule_models.dart';

class RedactionGeometry {
  static final _whitespace = RegExp(r'\s');

  static PixelRect forSpan(RawDetection item, int start, int end) {
    final text = item.text ?? '';
    final safeStart = start.clamp(0, text.length).toInt();
    final safeEnd = end.clamp(safeStart, text.length).toInt();
    final regions = _fragmentRects(
      item,
      TextRuleMatch(
        kind: DetectionKind.textLine,
        start: safeStart,
        end: safeEnd,
        text: text.substring(safeStart, safeEnd),
        confidence: item.confidence,
        selected: false,
      ),
    );
    if (regions.isEmpty) {
      return _proportionalRect(
        item.rect,
        text.length,
        TextRuleMatch(
          kind: DetectionKind.textLine,
          start: safeStart,
          end: safeEnd,
          text: text.substring(safeStart, safeEnd),
          confidence: item.confidence,
          selected: false,
        ),
      );
    }
    return regions
        .skip(1)
        .fold(regions.first, (rect, next) => rect.union(next));
  }

  static PixelRect forMatch(RawDetection item, TextRuleMatch match) {
    final fragments = _fragmentRects(item, match);
    if (fragments.isNotEmpty) {
      return fragments
          .skip(1)
          .fold(fragments.first, (rect, next) => rect.union(next));
    }
    return _proportionalRect(item.rect, item.text?.length ?? 0, match);
  }

  static List<PixelRect> _fragmentRects(
    RawDetection item,
    TextRuleMatch match,
  ) {
    final text = item.text ?? '';
    final located = _locateFragments(text, item.fragments);
    final rects = <PixelRect>[];
    for (final item in located) {
      final overlapStart = item.start > match.start ? item.start : match.start;
      final overlapEnd = item.end < match.end ? item.end : match.end;
      if (overlapStart >= overlapEnd) continue;
      rects.addAll(
        _symbolRects(item.fragment, item.start, overlapStart, overlapEnd),
      );
      if (item.fragment.symbols.isEmpty &&
          overlapStart <= item.start &&
          overlapEnd >= item.end) {
        rects.add(item.fragment.rect);
      }
    }
    return rects;
  }

  static List<_LocatedFragment> _locateFragments(
    String text,
    List<TextFragment> fragments,
  ) {
    final located = <_LocatedFragment>[];
    var searchFrom = 0;
    for (final fragment in fragments) {
      final normalized = fragment.text.replaceAll(_whitespace, '');
      if (normalized.isEmpty) continue;
      final match = _findIgnoringWhitespace(text, normalized, searchFrom);
      if (match == null) continue;
      located.add(_LocatedFragment(fragment, match.start, match.end));
      searchFrom = match.end;
    }
    return located;
  }

  static _TextSpan? _findIgnoringWhitespace(
    String text,
    String needle,
    int searchFrom,
  ) {
    for (var start = searchFrom; start < text.length; start++) {
      if (_whitespace.hasMatch(text[start])) continue;
      var cursor = start;
      var needleIndex = 0;
      while (cursor < text.length && needleIndex < needle.length) {
        while (cursor < text.length && _whitespace.hasMatch(text[cursor])) {
          cursor++;
        }
        if (cursor >= text.length || text[cursor] != needle[needleIndex]) {
          break;
        }
        cursor++;
        needleIndex++;
      }
      if (needleIndex == needle.length) {
        return _TextSpan(start, cursor);
      }
    }
    return null;
  }

  static List<PixelRect> _symbolRects(
    TextFragment fragment,
    int fragmentStart,
    int overlapStart,
    int overlapEnd,
  ) {
    final regions = <PixelRect>[];
    var searchFrom = 0;
    for (final symbol in fragment.symbols) {
      final symbolStart = fragment.text.indexOf(symbol.text, searchFrom);
      if (symbolStart < 0) continue;
      final symbolEnd = symbolStart + symbol.text.length;
      if (symbolStart < overlapEnd - fragmentStart &&
          symbolEnd > overlapStart - fragmentStart) {
        regions.add(symbol.rect);
      }
      searchFrom = symbolEnd;
    }
    return regions;
  }

  static PixelRect _proportionalRect(
    PixelRect line,
    int textLength,
    TextRuleMatch match,
  ) {
    final length = textLength.clamp(1, 100000).toInt();
    return PixelRect(
      left: line.left + line.width * match.start / length,
      top: line.top,
      right: line.left + line.width * match.end / length,
      bottom: line.bottom,
    );
  }
}

class _LocatedFragment {
  const _LocatedFragment(this.fragment, this.start, this.end);

  final TextFragment fragment;
  final int start;
  final int end;
}

class _TextSpan {
  const _TextSpan(this.start, this.end);

  final int start;
  final int end;
}
