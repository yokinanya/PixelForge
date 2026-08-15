import 'package:flutter_test/flutter_test.dart';
import 'package:pixelforge/src/application/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('invalid persisted theme is removed and falls back to system', () async {
    SharedPreferences.setMockInitialValues({'theme_preference': 'legacy'});
    final preferences = await SharedPreferences.getInstance();

    final controller = await ThemeController.fromPreferences(preferences);

    expect(controller.preference, ThemePreference.system);
    expect(preferences.getString('theme_preference'), isNull);
  });
}
