/// Visual layout helpers for the manual text selection mode.
library;

import 'dart:math' as math;

import 'package:pixelforge/src/application/redaction_models.dart';

List<PixelRect> mergeAdjacentTextCandidateRects(
  Iterable<DetectionCandidate> candidates, {
  bool includeSelected = false,
}) {
  final boxes =
      candidates
          .where(
            (candidate) =>
                candidate.kind == DetectionKind.textLine &&
                (includeSelected || !candidate.selected) &&
                candidate.rect.width >= 2 &&
                candidate.rect.height >= 2,
          )
          .map((candidate) => candidate.rect)
          .toList()
        ..sort(_compareTopLeft);
  final rows = <_TextRow>[];
  for (final box in boxes) {
    final row = rows.lastWhere(
      (candidate) => candidate.canContain(box),
      orElse: () => _TextRow.empty(),
    );
    if (row.isEmpty) {
      rows.add(_TextRow(box));
    } else {
      row.add(box);
    }
  }
  return rows.expand(_mergeRow).toList();
}

int _compareTopLeft(PixelRect first, PixelRect second) {
  final topDifference = first.top.compareTo(second.top);
  return topDifference == 0 ? first.left.compareTo(second.left) : topDifference;
}

List<PixelRect> _mergeRow(_TextRow row) {
  final boxes = [...row.boxes]
    ..sort((first, second) => first.left.compareTo(second.left));
  if (boxes.isEmpty) return const [];
  final merged = <PixelRect>[];
  var current = boxes.first;
  for (final next in boxes.skip(1)) {
    final gap = next.left - current.right;
    final maxGap = math.max(math.max(current.height, next.height) * 0.7, 6);
    if (gap <= maxGap) {
      current = current.union(next);
    } else {
      merged.add(current);
      current = next;
    }
  }
  merged.add(current);
  return merged;
}

class _TextRow {
  _TextRow(PixelRect first) : boxes = [first];

  _TextRow.empty() : boxes = [];

  final List<PixelRect> boxes;

  bool get isEmpty => boxes.isEmpty;

  bool canContain(PixelRect box) {
    final row = boxes.last;
    final centerDifference =
        ((row.top + row.bottom) - (box.top + box.bottom)).abs() / 2;
    final maxHeight = math.max(row.height, box.height);
    return centerDifference <= maxHeight * 0.55;
  }

  void add(PixelRect box) => boxes.add(box);
}
