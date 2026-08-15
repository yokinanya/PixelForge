/// 应用设置页。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pixelforge/src/application/redaction_provider.dart';
import 'package:pixelforge/src/application/session_provider.dart';
import 'package:pixelforge/src/application/share_provider.dart';
import 'package:pixelforge/src/application/theme_controller.dart';
import 'package:pixelforge/src/application/theme_provider.dart';
import 'package:pixelforge/src/application/watermark_provider.dart';
import 'package:pixelforge/src/infrastructure/storage/application_cache_store.dart';
import 'package:url_launcher/url_launcher.dart';

final _githubUrl = Uri.parse('https://github.com/yokinanya/PixelForge');

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _clearing = false;
  bool _changingShare = false;
  int? _cacheBytes;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCacheSize());
  }

  @override
  Widget build(BuildContext context) {
    final themeController = ref.watch(themeProvider);
    final shareController = Platform.isAndroid
        ? ref.watch(shareProvider)
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text('外观', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.brightness_6_outlined),
              title: const Text('深色模式'),
              subtitle: Text(themeController.preference.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _selectTheme(context, themeController),
            ),
          ),
          if (shareController != null) ...[
            const SizedBox(height: 24),
            Text('功能', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('接收系统分享'),
                subtitle: Text(
                  shareController.shareTargetEnabled
                      ? '分享菜单显示 PixelForge'
                      : '分享菜单已隐藏 PixelForge',
                ),
                trailing: Switch(
                  value: shareController.shareTargetEnabled,
                  onChanged: _changingShare ? null : _setShareTargetEnabled,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text('存储', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('清理缓存'),
              subtitle: Text(
                _cacheBytes == null
                    ? '正在计算'
                    : '可清除 ${_formatBytes(_cacheBytes!)}',
              ),
              trailing: _clearing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              enabled: !_clearing,
              onTap: _clearing ? null : _clearCache,
            ),
          ),
          const SizedBox(height: 24),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              title: const Text('github.com/yokinanya/PixelForge'),
              trailing: const Icon(Icons.open_in_new),
              onTap: _openGithub,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setShareTargetEnabled(bool enabled) async {
    if (_changingShare) return;
    setState(() => _changingShare = true);
    try {
      await ref.read(shareProvider).setShareTargetEnabled(enabled);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存分享设置失败：$error')));
    } finally {
      if (mounted) setState(() => _changingShare = false);
    }
  }

  Future<void> _selectTheme(
    BuildContext context,
    ThemeController controller,
  ) async {
    final selected = await showDialog<ThemePreference>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('深色模式'),
        content: RadioGroup<ThemePreference>(
          groupValue: controller.preference,
          onChanged: (value) {
            if (value != null) Navigator.pop(context, value);
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final preference in ThemePreference.values)
                RadioListTile<ThemePreference>(
                  value: preference,
                  title: Text(preference.label),
                  selected: preference == controller.preference,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    try {
      await controller.setPreference(selected);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        this.context,
      ).showSnackBar(SnackBar(content: Text('保存主题设置失败：$error')));
    }
  }

  Future<void> _openGithub() async {
    final opened = await launchUrl(
      _githubUrl,
      mode: LaunchMode.externalApplication,
    );
    if (opened || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开 GitHub 地址')));
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理缓存？'),
        content: const Text('只清理应用临时文件，不会删除已保存的图片。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      if (Platform.isAndroid) {
        await ref.read(shareProvider).dismissPendingImages();
      }
      final bytes = await _clearCacheStorage();
      if (!mounted) return;
      await _refreshCacheSize();
      if (!mounted) return;
      final message = bytes == 0 ? '没有可清理的缓存' : '已清理 ${_formatBytes(bytes)} 缓存';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _refreshCacheSize() async {
    final bytes = await _cacheStorageSize();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  Future<int> _cacheStorageSize() {
    if (Platform.isAndroid) return ApplicationCacheStore.runtimeCacheSize();
    return _dartCacheSize();
  }

  Future<int> _clearCacheStorage() {
    if (Platform.isAndroid) return ApplicationCacheStore.clearRuntimeCache();
    return _dartCacheClear();
  }

  Future<int> _dartCacheSize() async {
    final sizes = await Future.wait([
      ref.read(sessionProvider).cacheSize(),
      ref.read(redactionProvider).cacheSize(),
      ref.read(watermarkProvider).cacheSize(),
    ]);
    return sizes.fold<int>(0, (total, value) => total + value);
  }

  Future<int> _dartCacheClear() async {
    final cleared = await Future.wait([
      ref.read(sessionProvider).clearCache(),
      ref.read(redactionProvider).clearCache(),
      ref.read(watermarkProvider).clearCache(),
    ]);
    return cleared.fold<int>(0, (total, value) => total + value);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
