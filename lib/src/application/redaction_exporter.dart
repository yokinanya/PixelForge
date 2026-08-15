/// Native export adapter for redaction masks.
library;

import 'package:pixelforge/src/application/redaction_models.dart';
import 'package:pixelforge/src/domain/models.dart';
import 'package:pixelforge/src/infrastructure/ffi/rust_bridge.dart';

class RedactionExporter {
  const RedactionExporter(this.bridge);

  final RustBridge? bridge;

  Future<void> export({
    required String sourcePath,
    required List<MaskRegion> masks,
    required ExportFormat format,
    required int quality,
    required String outPath,
  }) async {
    final native = bridge;
    if (native == null) throw RustBridgeUnavailable();
    await runRedactionInIsolate(
      RedactionRequest(
        sourcePath: sourcePath,
        masks: [
          for (final mask in masks)
            {
              ...mask.rect.toJson(),
              'color': mask.color,
              'style': mask.style.name,
              'adaptive': mask.colorMode == MaskColorMode.adaptive,
            },
        ],
        format: format,
        quality: quality,
        outPath: outPath,
      ),
    );
  }
}
