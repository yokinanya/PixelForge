/// Deterministic, context-aware rules for sensitive OCR text.
library;

import 'redaction_models.dart';
import 'redaction_pinyin_name_rules.dart';
import 'redaction_rule_models.dart';

class RedactionTextRules {
  static final _email = RegExp(r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+');
  static final _url = RegExp(r'(?:https?://|www\.)\S+', caseSensitive: false);
  static final _ip = RegExp(r'(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)');
  static final _phone = RegExp(r'(?:\+?86[\s-]?)?1[3-9]\d{9}');
  static final _longNumber = RegExp(r'(?<!\d)\d{6,}(?!\d)');
  static final _nameLabel = RegExp(
    r'(?:姓\s*名|联\s*系\s*人|收\s*件\s*人|开\s*户\s*名|负\s*责\s*人|作\s*者|著\s*作\s*权\s*人|创\s*作\s*者)\s*[:：]?\s*([\u4e00-\u9fff](?:\s*[\u4e00-\u9fff]){1,3})',
  );
  static final _addressLabel = RegExp(
    r'(?:地\s*址|收\s*货\s*地\s*址|收\s*件\s*地\s*址|住\s*址|家\s*庭\s*住\s*址|发\s*货\s*地\s*址|联\s*系\s*地\s*址|详\s*细\s*地\s*址)\s*[:：]?\s*.+',
  );
  static final _identifierLabel = RegExp(
    r'(?:登\s*记\s*号|注\s*册\s*号|证\s*件\s*号|编\s*号|统\s*一\s*社\s*会\s*信\s*用\s*代\s*码)\s*[:：]?\s*\S+',
  );
  static final _residentialAddress = RegExp(
    r'[\u4e00-\u9fff]{2,12}\s*(?:苑|园|庭|府|湾|城|里|居|村|庄|小区)\s*[A-Za-z]?\d{2,5}(?:\s*(?:室|号|房))?',
  );
  static final _addressShape = RegExp(r'(?:省|市|区|县|镇|乡|街道|路|巷|号|栋|单元|室|村|弄|里)');
  static final _narrativeName = RegExp(
    r'(?:(?:^|[，,。；;：:\s])([\u4e00-\u9fff]{2,4})'
    r'(?=\s*(?:经|于|由|向|在|已|将|作为|签署|审核))|'
    r'(?:由|申请人|联\s*系\s*人|负\s*责\s*人)\s*('
    r'[\u4e00-\u9fff](?:\s*[\u4e00-\u9fff]){1,3})'
    r'(?=\s*(?:申请|办理|提交|签署|审核|负责|制作|完成)))',
  );
  static final _onlyChineseName = RegExp(r'^[\u4e00-\u9fff]{2,4}$');
  static final _commonNameLikeText = <String>{
    '以上事项',
    '作品名称',
    '作品类别',
    '作品样品',
    '登记日期',
    '创作完成日期',
    '广东省版权局',
    '中华人民共和国',
  };
  static const _commonSurnames =
      '赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛范彭郎鲁韦昌马苗方俞任袁柳唐费薛雷贺倪汤滕殷罗毕郝安常乐于傅齐康伍余顾孟平黄和穆萧尹姚邵汪毛禹狄米贝明戴谈宋庞熊纪舒屈项董梁杜阮蓝闵季麻强贾路江童颜郭梅盛林钟徐邱骆高夏蔡田樊胡凌霍虞万柯管卢莫房解宗丁宣邓郁杭洪包左石崔吉龚程邢裴陆荣翁荀羊惠曲家靳刘景詹束龙叶司黎白蒲卓蔺屠蒙池乔谭卓';
  static const _genericNarrativeWords = <String>{
    '图片',
    '设备',
    '本地',
    '识别',
    '确认',
    '选择',
    '遮挡',
    '区域',
    '内容',
    '文字',
  };

  static List<TextRuleMatch> matches({
    required RawDetection item,
    String? previousText,
    String? nextText,
  }) {
    final text = item.text ?? '';
    if (text.isEmpty || item.kind != 'textLine' && item.kind != 'addressLine') {
      return const [];
    }
    final found = <TextRuleMatch>[];
    _addPattern(found, text, _phone, DetectionKind.phone, 0.99, true);
    _addPattern(found, text, _email, DetectionKind.email, 0.99, true);
    _addUrls(found, text);
    _addIps(found, text);
    _addIdentifier(found, text);
    _addPattern(found, text, _longNumber, DetectionKind.longNumber, 0.96, true);
    _addNameLabel(found, text);
    _addAddress(found, text, item.kind == 'addressLine');
    _addResidentialAddress(found, text);
    _addNarrativeName(found, text);
    _addIsolatedName(found, text, previousText, nextText);
    found.addAll(
      RedactionPinyinNameRules.matches(
        text: text,
        previousText: previousText,
        nextText: nextText,
      ),
    );
    return _removeOverlapping(found);
  }

  static void _addPattern(
    List<TextRuleMatch> found,
    String text,
    RegExp pattern,
    DetectionKind kind,
    double confidence,
    bool selected,
  ) {
    for (final match in pattern.allMatches(text)) {
      found.add(
        TextRuleMatch(
          kind: kind,
          start: match.start,
          end: match.end,
          text: match.group(0)!,
          confidence: confidence,
          selected: selected,
        ),
      );
    }
  }

  static void _addUrls(List<TextRuleMatch> found, String text) {
    for (final match in _url.allMatches(text)) {
      final value = match.group(0)!.replaceFirst(RegExp(r'[，。；;、）】】]+$'), '');
      found.add(
        TextRuleMatch(
          kind: DetectionKind.url,
          start: match.start,
          end: match.start + value.length,
          text: value,
          confidence: 0.98,
          selected: true,
        ),
      );
    }
  }

  static void _addIps(List<TextRuleMatch> found, String text) {
    for (final match in _ip.allMatches(text)) {
      final value = match.group(0)!;
      final valid = value.split('.').every((part) => int.parse(part) <= 255);
      if (valid) {
        found.add(
          TextRuleMatch(
            kind: DetectionKind.ipAddress,
            start: match.start,
            end: match.end,
            text: value,
            confidence: 0.99,
            selected: true,
          ),
        );
      }
    }
  }

  static void _addIdentifier(List<TextRuleMatch> found, String text) {
    for (final match in _identifierLabel.allMatches(text)) {
      final start = _labelValueStart(text, match);
      final span = _trimmedSpan(text, start, match.end);
      if (span.start >= span.end) continue;
      found.add(
        TextRuleMatch(
          kind: DetectionKind.longNumber,
          start: span.start,
          end: span.end,
          text: text.substring(span.start, span.end),
          confidence: 0.99,
          selected: true,
        ),
      );
    }
  }

  static void _addNameLabel(List<TextRuleMatch> found, String text) {
    for (final match in _nameLabel.allMatches(text)) {
      final value = match.group(1);
      if (value == null || _commonNameLikeText.contains(value)) continue;
      found.add(
        TextRuleMatch(
          kind: DetectionKind.personName,
          start: match.end - value.length,
          end: match.end,
          text: value,
          confidence: 0.96,
          selected: true,
        ),
      );
    }
  }

  static void _addAddress(
    List<TextRuleMatch> found,
    String text,
    bool mergedLine,
  ) {
    final label = _addressLabel.firstMatch(text);
    if (label != null) {
      final start = _labelValueStart(text, label);
      final span = _trimmedSpan(text, start, label.end);
      if (span.start < span.end) {
        found.add(_addressMatch(text, span, selected: true));
      }
      return;
    }
    if (mergedLine || _looksLikeAddress(text)) {
      found.add(
        TextRuleMatch(
          kind: DetectionKind.address,
          start: 0,
          end: text.length,
          text: text,
          confidence: mergedLine ? 0.82 : 0.72,
          selected: true,
        ),
      );
    }
  }

  static TextRuleMatch _addressMatch(
    String text,
    ({int start, int end}) span, {
    required bool selected,
  }) => TextRuleMatch(
    kind: DetectionKind.address,
    start: span.start,
    end: span.end,
    text: text.substring(span.start, span.end),
    confidence: selected ? 0.96 : 0.72,
    selected: selected,
  );

  static void _addResidentialAddress(List<TextRuleMatch> found, String text) {
    for (final match in _residentialAddress.allMatches(text)) {
      final value = match.group(0)?.trim();
      if (value == null || value.isEmpty) continue;
      found.add(
        TextRuleMatch(
          kind: DetectionKind.address,
          start: match.start,
          end: match.end,
          text: value,
          confidence: 0.78,
          selected: true,
        ),
      );
    }
  }

  static void _addNarrativeName(List<TextRuleMatch> found, String text) {
    for (final match in _narrativeName.allMatches(text)) {
      final value = match.group(1) ?? match.group(2);
      if (value == null) continue;
      if (_isNarrativeNameLike(value)) {
        final valueStart = match.start + match.group(0)!.lastIndexOf(value);
        found.add(
          TextRuleMatch(
            kind: DetectionKind.personName,
            start: valueStart,
            end: valueStart + value.length,
            text: value,
            confidence: match.group(2) == null ? 0.74 : 0.92,
            selected: true,
          ),
        );
      }
    }
  }

  static void _addIsolatedName(
    List<TextRuleMatch> found,
    String text,
    String? previousText,
    String? nextText,
  ) {
    if (!_onlyChineseName.hasMatch(text) || !_isNameLike(text)) return;
    final context = '${previousText ?? ''}${nextText ?? ''}';
    final hasLabel = RegExp(
      r'(?:姓\s*名|作\s*者|联\s*系\s*人|收\s*件\s*人|负\s*责\s*人|开\s*户\s*名)',
    ).hasMatch(context);
    if (!hasLabel) return;
    found.add(
      TextRuleMatch(
        kind: DetectionKind.personName,
        start: 0,
        end: text.length,
        text: text,
        confidence: 0.9,
        selected: true,
      ),
    );
  }

  static bool _isNameLike(String value) {
    final normalized = value.replaceAll(RegExp(r'\s'), '');
    return normalized.length >= 2 &&
        normalized.length <= 4 &&
        _commonSurnames.contains(normalized.substring(0, 1)) &&
        !_commonNameLikeText.contains(normalized);
  }

  static bool _isNarrativeNameLike(String value) {
    final normalized = value.replaceAll(RegExp(r'\s'), '');
    return normalized.length >= 2 &&
        normalized.length <= 4 &&
        !_commonNameLikeText.contains(normalized) &&
        !_genericNarrativeWords.any(normalized.contains);
  }

  static bool _looksLikeAddress(String text) {
    if (text.length < 5 || !_addressShape.hasMatch(text)) return false;
    final markerCount = _addressShape.allMatches(text).length;
    final hasRegion = RegExp(r'(?:省|市|区|县|镇|乡)').hasMatch(text);
    final hasDetail = RegExp(r'(?:街道|路|巷|号|栋|单元|室|村|弄|里)').hasMatch(text);
    return markerCount >= 2 &&
        hasRegion &&
        (hasDetail || RegExp(r'\d').hasMatch(text));
  }

  static List<TextRuleMatch> _removeOverlapping(List<TextRuleMatch> matches) {
    final sorted = [...matches]
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = <TextRuleMatch>[];
    for (final match in sorted) {
      final overlaps = kept.any(
        (item) => match.start < item.end && match.end > item.start,
      );
      if (!overlaps) kept.add(match);
    }
    return kept..sort((a, b) => a.start.compareTo(b.start));
  }

  static int _labelValueStart(String text, RegExpMatch match) {
    final colon = text.indexOf(':', match.start);
    final chineseColon = text.indexOf('：', match.start);
    final positions = [colon, chineseColon]
        .where((position) => position >= match.start && position < match.end)
        .toList();
    return positions.isEmpty ? match.start : positions.reduce(_min) + 1;
  }

  static int _min(int first, int second) => first < second ? first : second;

  static ({int start, int end}) _trimmedSpan(String text, int start, int end) {
    while (start < end && text[start].trim().isEmpty) {
      start++;
    }
    while (end > start && text[end - 1].trim().isEmpty) {
      end--;
    }
    return (start: start, end: end);
  }
}
