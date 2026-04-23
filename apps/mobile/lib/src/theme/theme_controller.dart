import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns the active [ThemeMode] and persists it across launches.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._mode);

  static const _prefsKey = 'sidemesh_theme_mode_v1';

  ThemeMode _mode;

  ThemeMode get mode => _mode;

  bool isDark(BuildContext context) {
    if (_mode == ThemeMode.system) {
      return MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    }
    return _mode == ThemeMode.dark;
  }

  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final mode = switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.system,
    };
    return ThemeController._(mode);
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) {
      return;
    }
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  Future<void> toggle(BuildContext context) async {
    final next = isDark(context) ? ThemeMode.light : ThemeMode.dark;
    await setMode(next);
  }
}

/// InheritedNotifier that exposes the active [ThemeController].
class ThemeScope extends InheritedNotifier<ThemeController> {
  const ThemeScope({
    super.key,
    required ThemeController super.notifier,
    required super.child,
  });

  static ThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    assert(scope != null, 'ThemeScope missing in widget tree');
    return scope!.notifier!;
  }
}
