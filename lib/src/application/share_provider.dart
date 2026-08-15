/// 应用级系统分享 Provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/share_controller.dart';

final shareProvider = ChangeNotifierProvider<ShareController>((ref) {
  throw UnimplementedError('在 main 中初始化');
});
