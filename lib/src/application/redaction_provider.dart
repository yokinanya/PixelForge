/// Application-level redaction provider.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/redaction_controller.dart';

final redactionProvider = ChangeNotifierProvider<RedactionController>((ref) {
  throw UnimplementedError('在 main 中初始化');
});
