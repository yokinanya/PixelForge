import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/app_brand.dart';
import 'package:pixelforge/src/application/session_controller.dart';
import 'package:pixelforge/src/application/session_provider.dart';
import 'package:pixelforge/src/application/redaction_controller.dart';
import 'package:pixelforge/src/application/redaction_provider.dart';
import 'package:pixelforge/src/application/share_controller.dart';
import 'package:pixelforge/src/application/share_provider.dart';
import 'package:pixelforge/src/application/theme_controller.dart';
import 'package:pixelforge/src/application/theme_provider.dart';
import 'package:pixelforge/src/application/watermark_controller.dart';
import 'package:pixelforge/src/application/watermark_provider.dart';
import 'package:pixelforge/src/features/home/home_page.dart';
import 'package:pixelforge/src/infrastructure/storage/redaction_store.dart';
import 'package:pixelforge/src/infrastructure/storage/temp_store.dart';
import 'package:pixelforge/src/infrastructure/storage/watermark_store.dart';
import 'package:pixelforge/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化会话存储与控制器。
  final store = await TempStore.instance();
  await store.clear();
  final session = SessionController(store: store);
  final redactionStore = await RedactionStore.instance();
  await redactionStore.clear();
  final redaction = RedactionController(store: redactionStore);
  final watermarkStore = await WatermarkStore.instance();
  await watermarkStore.clear();
  final watermark = WatermarkController(store: watermarkStore);
  final preferences = await SharedPreferences.getInstance();
  final theme = await ThemeController.fromPreferences(preferences);
  final share = ShareController(preferences: preferences);
  await share.initialize();

  runApp(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWith((ref) => session),
        redactionProvider.overrideWith((ref) => redaction),
        watermarkProvider.overrideWith((ref) => watermark),
        shareProvider.overrideWith((ref) => share),
        themeProvider.overrideWith((ref) => theme),
      ],
      child: const PixelForgeApp(),
    ),
  );
}

class PixelForgeApp extends ConsumerWidget {
  const PixelForgeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<ShareController>(shareProvider, (_, controller) {
      if (!controller.hasPendingImages) return;
      _appNavigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
    return MaterialApp(
      navigatorKey: _appNavigatorKey,
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ref.watch(themeProvider).themeMode,
      home: const HomePage(),
    );
  }
}
