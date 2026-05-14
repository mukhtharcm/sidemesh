import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_tokens.dart';
import 'theme_controller.dart';

/// Builds a light [ThemeData] from the given palette.
ThemeData buildLightTheme(
  AppColors palette, {
  AppTypographyPreferences typography = AppTypographyPreferences.defaults,
}) => _buildTheme(Brightness.light, palette, typography);

/// Builds a dark [ThemeData] from the given palette.
ThemeData buildDarkTheme(
  AppColors palette, {
  AppTypographyPreferences typography = AppTypographyPreferences.defaults,
}) => _buildTheme(Brightness.dark, palette, typography);

ThemeData _buildTheme(
  Brightness brightness,
  AppColors palette,
  AppTypographyPreferences typography,
) {
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: palette.accent,
    onPrimary: palette.accentOn,
    secondary: palette.info,
    onSecondary: palette.accentOn,
    error: palette.danger,
    onError: palette.accentOn,
    surface: palette.surface,
    onSurface: palette.textPrimary,
    surfaceContainerHighest: palette.surfaceElevated,
    outline: palette.border,
    outlineVariant: palette.borderStrong,
  );

  final base = ThemeData(
    brightness: brightness,
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: palette.canvas,
  );

  final textTheme = base.textTheme.apply(
    fontFamily: typography.interfaceFont.fontFamily,
    bodyColor: palette.textPrimary,
    displayColor: palette.textPrimary,
  );

  return base.copyWith(
    textTheme: textTheme,
    extensions: <ThemeExtension<dynamic>>[palette],
    appBarTheme: AppBarTheme(
      backgroundColor: palette.canvas,
      foregroundColor: palette.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        fontWeight: AppWeights.title,
        letterSpacing: AppLetterSpacing.headline,
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.card,
        side: BorderSide(color: palette.border),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.surface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: palette.textPrimary,
        fontWeight: AppWeights.body,
      ),
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.input,
        side: BorderSide(color: palette.border),
      ),
      actionTextColor: palette.accent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 10,
      shadowColor: palette.textPrimary.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.card,
        side: BorderSide(color: palette.border),
      ),
      textStyle: textTheme.bodyMedium?.copyWith(
        color: palette.textPrimary,
        fontWeight: AppWeights.emphasis,
      ),
      labelTextStyle: WidgetStateProperty.all(
        textTheme.bodyMedium?.copyWith(
          color: palette.textPrimary,
          fontWeight: AppWeights.emphasis,
        ),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(palette.surfaceElevated),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shadowColor: WidgetStateProperty.all(
          palette.textPrimary.withValues(alpha: 0.12),
        ),
        elevation: WidgetStateProperty.all(10),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: AppShapes.card,
            side: BorderSide(color: palette.border),
          ),
        ),
        padding: WidgetStateProperty.all(const EdgeInsets.all(6)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: palette.accentMuted,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: AppShapes.input,
      ),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? palette.accent : palette.textSecondary,
          size: 22,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return textTheme.labelMedium?.copyWith(
          color: selected ? palette.accent : palette.textSecondary,
          fontWeight: AppWeights.title,
          letterSpacing: AppLetterSpacing.caps,
        );
      }),
      height: 68,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.accentOn,
        disabledBackgroundColor: palette.surfaceMuted,
        disabledForegroundColor: palette.textTertiary,
        shape: RoundedRectangleBorder(borderRadius: AppShapes.input),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.textPrimary,
        side: BorderSide(color: palette.border),
        shape: RoundedRectangleBorder(borderRadius: AppShapes.input),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accent,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: palette.textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      hoverColor: palette.surfaceElevated,
      border: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: palette.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: palette.accent, width: 1.5),
      ),
      labelStyle: TextStyle(color: palette.textSecondary),
      hintStyle: TextStyle(color: palette.textTertiary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    dividerTheme: DividerThemeData(color: palette.border, space: 1),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.accent,
      foregroundColor: palette.accentOn,
      elevation: 0,
      highlightElevation: 0,
      shape: RoundedRectangleBorder(borderRadius: AppShapes.card),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: AppShapes.sheetTop),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.accent),
    chipTheme: ChipThemeData(
      backgroundColor: palette.surfaceMuted,
      side: BorderSide(color: palette.border),
      labelStyle: textTheme.labelMedium?.copyWith(color: palette.textPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
  );
}

/// Monospace font used everywhere for code-like surfaces.
TextStyle monoStyle({
  required Color color,
  double fontSize = 12.5,
  double height = 1.45,
  FontWeight fontWeight = FontWeight.w500,
}) {
  return TextStyle(
    fontFamily: 'JetBrainsMono',
    color: color,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
  );
}
