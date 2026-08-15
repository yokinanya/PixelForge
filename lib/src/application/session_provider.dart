/// 应用级会话 Provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/session_controller.dart';

final sessionProvider = ChangeNotifierProvider<SessionController>((ref) {
  throw UnimplementedError('在 main 中初始化');
});
