import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palettes.dart';

enum InterfaceFontFamily {
  spaceGrotesk,
  systemSans;

  String get id => switch (this) {
    InterfaceFontFamily.spaceGrotesk => 'space_grotesk',
    InterfaceFontFamily.systemSans => 'system_sans',
  };

  String get label => switch (this) {
    InterfaceFontFamily.spaceGrotesk => 'Brand Sans',
    InterfaceFontFamily.systemSans => 'System',
  };

  String get description => switch (this) {
    InterfaceFontFamily.spaceGrotesk =>
      'Adds a little more character to headings and controls.',
    InterfaceFontFamily.systemSans =>
      'Matches the platform UI for a calmer, more familiar feel.',
  };

  String? get fontFamily => switch (this) {
    InterfaceFontFamily.spaceGrotesk => 'SpaceGrotesk',
    InterfaceFontFamily.systemSans => null,
  };

  static InterfaceFontFamily fromId(
    String? id, {
    InterfaceFontFamily fallback = InterfaceFontFamily.systemSans,
  }) {
    for (final family in values) {
      if (family.id == id) return family;
    }
    return fallback;
  }
}

enum TextSizePreset {
  compact,
  standard,
  large;

  String get id => switch (this) {
    TextSizePreset.compact => 'compact',
    TextSizePreset.standard => 'standard',
    TextSizePreset.large => 'large',
  };

  String get label => switch (this) {
    TextSizePreset.compact => 'Compact',
    TextSizePreset.standard => 'Default',
    TextSizePreset.large => 'Large',
  };

  String get description => switch (this) {
    TextSizePreset.compact => 'Fits more on screen.',
    TextSizePreset.standard => 'Balanced size and spacing.',
    TextSizePreset.large => 'Easier to read at a glance.',
  };

  double get factor => switch (this) {
    TextSizePreset.compact => 0.92,
    TextSizePreset.standard => 1,
    TextSizePreset.large => 1.12,
  };

  static TextSizePreset fromId(
    String? id, {
    TextSizePreset fallback = TextSizePreset.standard,
  }) {
    for (final preset in values) {
      if (preset.id == id) return preset;
    }
    return fallback;
  }
}

@immutable
class AppTypographyPreferences {
  const AppTypographyPreferences({
    this.interfaceFont = InterfaceFontFamily.systemSans,
    this.interfaceScale = TextSizePreset.standard,
  });

  final InterfaceFontFamily interfaceFont;
  final TextSizePreset interfaceScale;

  static const defaults = AppTypographyPreferences();

  AppTypographyPreferences copyWith({
    InterfaceFontFamily? interfaceFont,
    TextSizePreset? interfaceScale,
  }) {
    return AppTypographyPreferences(
      interfaceFont: interfaceFont ?? this.interfaceFont,
      interfaceScale: interfaceScale ?? this.interfaceScale,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AppTypographyPreferences &&
        other.interfaceFont == interfaceFont &&
        other.interfaceScale == interfaceScale;
  }

  @override
  int get hashCode => Object.hash(interfaceFont, interfaceScale);

  bool get isStandardScale => interfaceScale == TextSizePreset.standard;

  TextScaler buildTextScaler(TextScaler base) {
    if (isStandardScale) return base;
    return _InterfaceTextScaler(base: base, factor: interfaceScale.factor);
  }
}

class _InterfaceTextScaler extends TextScaler {
  const _InterfaceTextScaler({required this.base, required this.factor});

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // Flutter still requires this getter while steering callers toward scale().
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) {
    return other is _InterfaceTextScaler &&
        other.base == base &&
        other.factor == factor;
  }

  @override
  int get hashCode => Object.hash(base, factor);
}

/// Owns the active [ThemeMode] and [ThemeVariant] and persists them across
/// launches.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._mode, this._variant, this._typography);

  static const _prefsKey = 'sidemesh_theme_mode_v1';
  static const _variantPrefsKey = 'sidemesh_theme_variant_v1';
  static const _interfaceFontPrefsKey = 'sidemesh_interface_font_v1';
  static const _interfaceScalePrefsKey = 'sidemesh_interface_scale_v1';

  ThemeMode _mode;
  ThemeVariant _variant;
  AppTypographyPreferences _typography;

  ThemeMode get mode => _mode;
  ThemeVariant get variant => _variant;
  AppTypographyPreferences get typography => _typography;

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
    final typography = AppTypographyPreferences(
      interfaceFont: InterfaceFontFamily.fromId(
        prefs.getString(_interfaceFontPrefsKey),
      ),
      interfaceScale: TextSizePreset.fromId(
        prefs.getString(_interfaceScalePrefsKey),
      ),
    );
    return ThemeController._(mode, variant, typography);
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

  Future<void> setTypography(AppTypographyPreferences typography) async {
    if (typography == _typography) return;
    _typography = typography;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString(_interfaceFontPrefsKey, typography.interfaceFont.id),
      prefs.setString(_interfaceScalePrefsKey, typography.interfaceScale.id),
    ]);
  }

  Future<void> setInterfaceFont(InterfaceFontFamily family) {
    return setTypography(_typography.copyWith(interfaceFont: family));
  }

  Future<void> setInterfaceScale(TextSizePreset preset) {
    return setTypography(_typography.copyWith(interfaceScale: preset));
  }

  Future<void> resetTypography() {
    return setTypography(AppTypographyPreferences.defaults);
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
