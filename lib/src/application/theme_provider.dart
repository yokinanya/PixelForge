/// Application theme provider.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/theme_controller.dart';

final themeProvider = ChangeNotifierProvider<ThemeController>((ref) {
  throw UnimplementedError('在 main 中初始化');
});
