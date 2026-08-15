/// Combines visually adjacent OCR lines when they form one address.
library;

import 'redaction_models.dart';

class RedactionAddressMerger {
  List<RawDetection> merge(List<RawDetection> raw) {
    final merged = <RawDetection>[];
    var index = 0;
    while (index < raw.length) {
      final current = raw[index];
      var nextIndex = index + 1;
      var combined = current;
      while (nextIndex < raw.length && _canMerge(combined, raw[nextIndex])) {
        combined = _mergePair(combined, raw[nextIndex]);
        nextIndex++;
      }
      merged.add(combined);
      index = nextIndex;
    }
    return merged;
  }

  RawDetection _mergePair(RawDetection first, RawDetection second) =>
      RawDetection(
        kind: 'addressLine',
        text: '${first.text?.trim() ?? ''}${second.text?.trim() ?? ''}',
        rect: first.rect.union(second.rect),
        confidence: (first.confidence + second.confidence) / 2,
        fragments: [...first.fragments, ...second.fragments],
      );

  bool _canMerge(RawDetection first, RawDetection second) {
    if (first.kind != 'textLine' && first.kind != 'addressLine') return false;
    if (second.kind != 'textLine') return false;
    final firstText = first.text?.trim() ?? '';
    final secondText = second.text?.trim() ?? '';
    final hasContinuationMarker = RegExp(
      r'(?:省|市|区|县|镇|乡|街道|路|巷|号|栋|单元|室|村|弄|里)',
    ).hasMatch(secondText);
    if (!hasContinuationMarker) return false;
    final height = first.rect.height > second.rect.height
        ? first.rect.height
        : second.rect.height;
    final gap = second.rect.top - first.rect.bottom;
    final close = gap >= -4 && gap <= height * 1.5;
    final hasAddressLabel = RegExp(
      r'(?:地址|收货地址|收件地址|住址|发货地址|联系地址)',
    ).hasMatch(firstText);
    return close &&
        hasAddressLabel &&
        _looksLikeAddress('$firstText$secondText');
  }

  bool looksLikeAddress(String text) => _looksLikeAddress(text);

  bool _looksLikeAddress(String text) {
    final markers = RegExp(
      r'(?:省|市|区|县|镇|乡|街道|路|巷|号|栋|单元|室|村|弄|里)',
    ).allMatches(text).length;
    final hasRegion = RegExp(r'(?:省|市|区|县|镇|乡)').hasMatch(text);
    final hasDetail = RegExp(r'(?:街道|路|巷|号|栋|单元|室|村|弄|里)').hasMatch(text);
    return text.length >= 5 && markers >= 2 && hasRegion && hasDetail;
  }
}
