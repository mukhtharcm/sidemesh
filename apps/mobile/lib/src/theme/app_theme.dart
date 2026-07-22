import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'color_contrast.dart';
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
  final actionForeground = readableActionForeground(palette, palette.accent);
  final secondaryForeground = readableTextOn(
    palette,
    background: palette.info,
    preferred: palette.accentOn,
  );
  final errorForeground = readableTextOn(
    palette,
    background: palette.danger,
    preferred: palette.accentOn,
  );
  final accentOnSurface = readableTextOn(
    palette,
    background: palette.surface,
    preferred: palette.accent,
  );
  final focusOutline = visibleUiColorOn(
    palette,
    background: palette.surface,
    preferred: palette.accent,
  );
  final inputLabelColor = readableTextOn(
    palette,
    background: palette.surface,
    preferred: palette.textSecondary,
  );
  final inputHintColor = readableTextOn(
    palette,
    background: palette.surface,
    preferred: palette.textTertiary,
    additionalFallbacks: <Color>[palette.textSecondary],
  );
  final controlBorder = visibleBorderOn(
    palette,
    background: palette.surface,
    preferred: palette.border,
  );
  final disabledControlForeground = visibleUiColorOn(
    palette,
    background: palette.surfaceMuted,
    preferred: palette.textSecondary,
  );
  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: palette.accent,
    onPrimary: actionForeground,
    secondary: palette.info,
    onSecondary: secondaryForeground,
    error: palette.danger,
    onError: errorForeground,
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

  final fontFamily = typography.interfaceFont.fontFamily;
  final textTheme = base.textTheme
      .copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontSize: 24,
          height: 1.2,
          fontWeight: AppWeights.strong,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          height: 1.25,
          fontWeight: AppWeights.strong,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontSize: 16,
          height: 1.3,
          fontWeight: AppWeights.title,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          fontSize: 14,
          height: 1.3,
          fontWeight: AppWeights.title,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          fontSize: 16,
          height: 1.45,
          fontWeight: AppWeights.body,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14,
          height: 1.4,
          fontWeight: AppWeights.body,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          fontSize: 12,
          height: 1.35,
          fontWeight: AppWeights.body,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          fontSize: 14,
          height: 1.2,
          fontWeight: AppWeights.title,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          fontSize: 12,
          height: 1.2,
          fontWeight: AppWeights.emphasis,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontSize: 11,
          height: 1.2,
          fontWeight: AppWeights.emphasis,
        ),
      )
      .apply(
        fontFamily: fontFamily,
        bodyColor: palette.textPrimary,
        displayColor: palette.textPrimary,
      );

  return base.copyWith(
    textTheme: textTheme,
    extensions: <ThemeExtension<dynamic>>[palette],
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: focusOutline,
      selectionColor: selectionFillForBackground(
        palette,
        background: palette.surface,
        foreground: palette.accent,
      ),
      selectionHandleColor: focusOutline,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.canvas,
      foregroundColor: palette.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        fontWeight: AppWeights.strong,
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
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.input,
        side: BorderSide(color: palette.border),
      ),
      actionTextColor: accentOnSurface,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: palette.textPrimary.withValues(alpha: 0.08),
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
          palette.textPrimary.withValues(alpha: 0.08),
        ),
        elevation: WidgetStateProperty.all(6),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: AppShapes.card,
            side: BorderSide(color: palette.border),
          ),
        ),
        padding: WidgetStateProperty.all(const EdgeInsets.all(4)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: palette.accentMuted,
      indicatorShape: RoundedRectangleBorder(borderRadius: AppShapes.input),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? accentOnSurface : inputLabelColor,
          size: 22,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return textTheme.labelMedium?.copyWith(
          color: selected ? accentOnSurface : inputLabelColor,
          fontWeight: AppWeights.emphasis,
          letterSpacing: AppLetterSpacing.body,
        );
      }),
      height: 68,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: actionForeground,
        disabledBackgroundColor: palette.surfaceMuted,
        disabledForegroundColor: disabledControlForeground,
        shape: RoundedRectangleBorder(borderRadius: AppShapes.input),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
        minimumSize: const Size(0, AppSizes.control),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.textPrimary,
        side: BorderSide(color: controlBorder),
        shape: RoundedRectangleBorder(borderRadius: AppShapes.input),
        minimumSize: const Size(0, AppSizes.control),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accentOnSurface,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
        minimumSize: const Size(0, AppSizes.control),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: palette.textSecondary,
        minimumSize: const Size.square(AppSizes.control),
        maximumSize: const Size.square(AppSizes.control),
        iconSize: AppSizes.icon,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surface,
      hoverColor: palette.surfaceElevated,
      border: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: controlBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: controlBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: focusOutline, width: 1.5),
      ),
      labelStyle: TextStyle(color: inputLabelColor),
      hintStyle: TextStyle(color: inputHintColor),
      constraints: const BoxConstraints(minHeight: AppSizes.control),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
    ),
    dividerTheme: DividerThemeData(color: palette.border, space: 1),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.accent,
      foregroundColor: actionForeground,
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
      shape: RoundedRectangleBorder(borderRadius: AppShapes.badge),
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
