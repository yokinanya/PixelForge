/// Immutable snapshots used by the redaction undo/redo stack.
library;

import 'redaction_models.dart';

class RedactionSnapshot {
  const RedactionSnapshot(this.candidates, this.masks, this.settings);

  final List<DetectionCandidate> candidates;
  final List<MaskRegion> masks;
  final MaskStyleSettings settings;
}
