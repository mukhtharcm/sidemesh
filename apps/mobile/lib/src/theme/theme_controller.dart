import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palettes.dart';

/// Owns the active [ThemeMode] and [ThemeVariant] and persists them across
/// launches.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._mode, this._variant);

  static const _prefsKey = 'sidemesh_theme_mode_v1';
  static const _variantPrefsKey = 'sidemesh_theme_variant_v1';

  ThemeMode _mode;
  ThemeVariant _variant;

  ThemeMode get mode => _mode;
  ThemeVariant get variant => _variant;

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
    final variant = ThemeVariant.fromId(prefs.getString(_variantPrefsKey));
    return ThemeController._(mode, variant);
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

  Future<void> setVariant(ThemeVariant variant) async {
    if (variant == _variant) return;
    _variant = variant;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_variantPrefsKey, variant.id);
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
