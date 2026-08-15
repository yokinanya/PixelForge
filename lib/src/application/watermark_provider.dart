import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/watermark_controller.dart';

final watermarkProvider = ChangeNotifierProvider<WatermarkController>(
  (ref) => throw UnimplementedError('watermarkProvider must be overridden'),
);
