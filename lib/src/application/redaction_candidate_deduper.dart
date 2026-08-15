/// Removes duplicate candidates emitted by overlapping OCR rules.
library;

import 'redaction_models.dart';

class RedactionCandidateDeduper {
  List<DetectionCandidate> deduplicate(List<DetectionCandidate> candidates) {
    final result = <DetectionCandidate>[];
    for (final candidate in candidates) {
      if (result.any((existing) => _isDuplicate(existing, candidate))) {
        continue;
      }
      result.add(candidate);
    }
    return result;
  }

  bool _isDuplicate(DetectionCandidate first, DetectionCandidate second) {
    if (first.kind != second.kind) return false;
    if (second.kind == DetectionKind.textLine) {
      return _sameText(first, second) && _close(first.rect, second.rect);
    }
    return first.rect.overlaps(second.rect) ||
        (_sameText(first, second) && _close(first.rect, second.rect));
  }

  bool _sameText(DetectionCandidate first, DetectionCandidate second) =>
      first.text != null &&
      first.text!.trim() == second.text?.trim() &&
      first.text!.trim().isNotEmpty;

  bool _close(PixelRect first, PixelRect second) {
    final horizontalGap = _gap(
      first.left,
      first.right,
      second.left,
      second.right,
    );
    final verticalGap = _gap(
      first.top,
      first.bottom,
      second.top,
      second.bottom,
    );
    return horizontalGap <= 8 && verticalGap <= 8;
  }

  double _gap(
    double firstStart,
    double firstEnd,
    double secondStart,
    double secondEnd,
  ) {
    if (firstStart <= secondEnd && secondStart <= firstEnd) return 0;
    return firstStart > secondEnd
        ? firstStart - secondEnd
        : secondStart - firstEnd;
  }
}
