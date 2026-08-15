/// 领域模型：会话中的图片、接缝、固定元素与导出配置。
library;

/// 图片尺寸（原始像素）。
class ImageSize {
  const ImageSize(this.width, this.height);
  final int width;
  final int height;
}

/// 会话中的一张截图。
class SessionImage {
  const SessionImage({required this.path, required this.size});

  final String path;
  final ImageSize size;
}

/// 像素矩形区域。
class PixelRegion {
  const PixelRegion({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final int x;
  final int y;
  final int w;
  final int h;

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};

  static PixelRegion fromJson(Map<String, dynamic> json) => PixelRegion(
    x: (json['x'] as num).toInt(),
    y: (json['y'] as num).toInt(),
    w: (json['w'] as num).toInt(),
    h: (json['h'] as num).toInt(),
  );
}

/// 一个接缝候选（dx/dy 偏移 + 成本）。
class SeamCandidate {
  const SeamCandidate({required this.dx, required this.dy, required this.cost});
  final int dx;
  final int dy;
  final double cost;

  factory SeamCandidate.fromJson(Map<String, dynamic> json) => SeamCandidate(
    dx: (json['dx'] as num).toInt(),
    dy: (json['dy'] as num).toInt(),
    cost: (json['cost'] as num).toDouble(),
  );
}

/// 相邻两张截图之间的分析结果。
class PairAnalysis {
  const PairAnalysis({
    required this.plausible,
    required this.confidence,
    required this.dx,
    required this.dy,
    required this.candidates,
    this.topBar,
    this.bottomBar,
    this.bottomWhitespace,
  });

  /// 匹配是否可信。
  final bool plausible;

  /// 置信度 [0, 1]。
  final double confidence;

  /// 最佳横向偏移（正 = 后图在右）。
  final int dx;

  /// 最佳纵向偏移（后图第一行在前图中的行号）。
  final int dy;

  /// 所有候选（按成本升序）。
  final List<SeamCandidate> candidates;

  /// 前图底部检测到的固定区域（前图坐标系）。
  final PixelRegion? bottomBar;

  /// 后图顶部检测到的固定区域（后图坐标系）。
  final PixelRegion? topBar;

  /// 后图底部固定区域上方的空白内容区域。
  final PixelRegion? bottomWhitespace;

  factory PairAnalysis.fromJson(Map<String, dynamic> json) => PairAnalysis(
    plausible: json['plausible'] as bool? ?? false,
    confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
    dx: (json['dx'] as num?)?.toInt() ?? 0,
    dy: (json['dy'] as num?)?.toInt() ?? 0,
    candidates: ((json['candidates'] as List?) ?? const [])
        .map((e) => SeamCandidate.fromJson(e as Map<String, dynamic>))
        .toList(),
    topBar: json['top_bar'] == null
        ? null
        : PixelRegion.fromJson(json['top_bar'] as Map<String, dynamic>),
    bottomBar: json['bottom_bar'] == null
        ? null
        : PixelRegion.fromJson(json['bottom_bar'] as Map<String, dynamic>),
    bottomWhitespace: json['bottom_whitespace'] == null
        ? null
        : PixelRegion.fromJson(
            json['bottom_whitespace'] as Map<String, dynamic>,
          ),
  );
}

/// 导出的图像格式。
enum ExportFormat {
  png('png', 'PNG'),
  jpeg('jpeg', 'JPEG'),
  webp('webp', 'WebP');

  const ExportFormat(this.rustName, this.label);
  final String rustName;
  final String label;

  String get extension => switch (this) {
    ExportFormat.png => 'png',
    ExportFormat.jpeg => 'jpg',
    ExportFormat.webp => 'webp',
  };

  String get mimeType => switch (this) {
    ExportFormat.png => 'image/png',
    ExportFormat.jpeg => 'image/jpeg',
    ExportFormat.webp => 'image/webp',
  };
}

/// Android 公共保存位置。
enum ExportLocation {
  pictures('pictures', '图片'),
  downloads('downloads', '下载');

  const ExportLocation(this.key, this.label);
  final String key;
  final String label;
}

/// 首图顶部 / 末图底部固定区域的处理策略。
enum BarAction {
  keep('保留'),
  remove('移除');

  const BarAction(this.label);
  final String label;
}
