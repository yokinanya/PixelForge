/// Persisted application theme preference.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ThemePreference {
  system('跟随系统'),
  light('浅色'),
  dark('深色');

  const ThemePreference(this.label);

  final String label;

  ThemeMode get themeMode => switch (this) {
    ThemePreference.system => ThemeMode.system,
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark => ThemeMode.dark,
  };
}

class ThemeController extends ChangeNotifier {
  ThemeController._(this._preferences, this._preference);

  static const _preferenceKey = 'theme_preference';

  final SharedPreferences _preferences;
  ThemePreference _preference;

  ThemePreference get preference => _preference;
  ThemeMode get themeMode => _preference.themeMode;

  static Future<ThemeController> fromPreferences(
    SharedPreferences preferences,
  ) async {
    final stored = preferences.getString(_preferenceKey);
    final preference = _parsePreference(stored);
    if (stored != null && preference == null) {
      final removed = await preferences.remove(_preferenceKey);
      if (!removed) {
        debugPrint('无法清除无效主题配置，将使用系统主题');
      }
    }
    return ThemeController._(preferences, preference ?? ThemePreference.system);
  }

  static ThemePreference? _parsePreference(String? stored) {
    if (stored == null) return ThemePreference.system;
    for (final preference in ThemePreference.values) {
      if (preference.name == stored) return preference;
    }
    return null;
  }

  Future<void> setPreference(ThemePreference preference) async {
    if (_preference == preference) return;
    final persisted = await _preferences.setString(
      _preferenceKey,
      preference.name,
    );
    if (!persisted) {
      throw StateError('无法保存主题设置');
    }
    _preference = preference;
    notifyListeners();
  }
}
