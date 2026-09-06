import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'color_contrast.dart';
import 'app_tokens.dart';
import 'theme_controller.dart';

/// Builds a light [ThemeData] from the given palette.
ThemeData buildLightTheme(
  AppColors palette, {
  AppTypographyPreferences typography = AppTypographyPreferences.defaults,
  TargetPlatform? platform,
}) => _buildTheme(Brightness.light, palette, typography, platform);

/// Builds a dark [ThemeData] from the given palette.
ThemeData buildDarkTheme(
  AppColors palette, {
  AppTypographyPreferences typography = AppTypographyPreferences.defaults,
  TargetPlatform? platform,
}) => _buildTheme(Brightness.dark, palette, typography, platform);

ThemeData _buildTheme(
  Brightness brightness,
  AppColors palette,
  AppTypographyPreferences typography,
  TargetPlatform? platform,
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
    background: palette.surfaceMuted,
    preferred: palette.textSecondary,
  );
  final inputHintColor = readableTextOn(
    palette,
    background: palette.surfaceMuted,
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
    surfaceDim: palette.canvas,
    surfaceBright: palette.surfaceElevated,
    surfaceContainerLowest: palette.canvas,
    surfaceContainerLow: palette.surface,
    surfaceContainer: palette.surfaceMuted,
    surfaceContainerHigh: palette.surfaceElevated,
    surfaceContainerHighest: palette.surfaceElevated,
    outline: palette.border,
    outlineVariant: palette.borderStrong,
  );

  final base = ThemeData(
    platform: platform,
    brightness: brightness,
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: palette.canvas,
  );

  final desktop = AppSizes.usesPointerControls(base.platform);
  final controlSize = desktop ? AppSizes.compactControl : AppSizes.control;
  final menuRowHeight = desktop ? AppSizes.desktopMenuItem : AppSizes.menuItem;

  final fontFamily = typography.interfaceFont.fontFamily;
  final textTheme = base.textTheme
      .copyWith(
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.page,
          height: 1.2,
          fontWeight: AppWeights.strong,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.heading,
          height: 1.25,
          fontWeight: AppWeights.strong,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.reading,
          height: 1.3,
          fontWeight: AppWeights.title,
        ),
        titleSmall: base.textTheme.titleSmall?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.body,
          height: 1.3,
          fontWeight: AppWeights.title,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.reading,
          height: 1.45,
          fontWeight: AppWeights.body,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.body,
          height: 1.4,
          fontWeight: AppWeights.body,
        ),
        bodySmall: base.textTheme.bodySmall?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.caption,
          height: 1.35,
          fontWeight: AppWeights.body,
        ),
        labelLarge: base.textTheme.labelLarge?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.body,
          height: 1.2,
          fontWeight: AppWeights.title,
        ),
        labelMedium: base.textTheme.labelMedium?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.caption,
          height: 1.2,
          fontWeight: AppWeights.emphasis,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          letterSpacing: 0,
          fontSize: AppFontSizes.metadata,
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
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.dialog,
        side: BorderSide(color: palette.border),
      ),
      titleTextStyle: textTheme.titleMedium,
      contentTextStyle: textTheme.bodyMedium,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        textStyle: WidgetStatePropertyAll(textTheme.bodyMedium),
        minimumSize: WidgetStatePropertyAll(Size(0, controlSize)),
        visualDensity: VisualDensity.standard,
        foregroundColor: WidgetStatePropertyAll(palette.textPrimary),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.surfaceMuted
              : palette.surfaceElevated,
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppShapes.input),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: palette.border)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? disabledControlForeground
            : states.contains(WidgetState.selected)
            ? actionForeground
            : palette.textSecondary,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            !states.contains(WidgetState.disabled) &&
                states.contains(WidgetState.selected)
            ? palette.accent
            : palette.surfaceMuted,
      ),
    ),
    hoverColor: palette.textPrimary.withValues(alpha: AppEmphasis.hover),
    splashFactory: NoSplash.splashFactory,
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
      color: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: AppShapes.card),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.surfaceElevated,
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
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? disabledControlForeground
              : palette.textSecondary,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => palette.textPrimary.withValues(
            alpha: states.contains(WidgetState.focused)
                ? AppEmphasis.focus
                : AppEmphasis.hover,
          ),
        ),
        minimumSize: WidgetStatePropertyAll(Size(controlSize, controlSize)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(AppSpacing.xs)),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadii.hover)),
          ),
        ),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: AppEmphasis.popupElevation,
      shadowColor: palette.textPrimary.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: AppShapes.menu,
        side: BorderSide(color: palette.border),
      ),
      textStyle: textTheme.bodyMedium?.copyWith(
        color: palette.textPrimary,
        fontWeight: AppWeights.body,
      ),
      labelTextStyle: WidgetStateProperty.all(
        textTheme.bodyMedium?.copyWith(
          color: palette.textPrimary,
          fontWeight: AppWeights.body,
        ),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(palette.surfaceElevated),
        minimumSize: const WidgetStatePropertyAll(
          Size(AppSizes.menuMinWidth, 0),
        ),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        shadowColor: WidgetStateProperty.all(
          palette.textPrimary.withValues(alpha: 0.08),
        ),
        elevation: WidgetStateProperty.all(AppEmphasis.popupElevation),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: AppShapes.menu,
            side: BorderSide(color: palette.border),
          ),
        ),
        padding: WidgetStateProperty.all(const EdgeInsets.all(4)),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? disabledControlForeground
              : palette.textPrimary;
        }),
        iconColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.disabled)
              ? disabledControlForeground
              : palette.textSecondary;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)) {
            return palette.textPrimary.withValues(
              alpha: states.contains(WidgetState.focused)
                  ? AppEmphasis.focus
                  : AppEmphasis.hover,
            );
          }
          return Colors.transparent;
        }),
        textStyle: WidgetStatePropertyAll(
          textTheme.bodyMedium?.copyWith(fontWeight: AppWeights.body),
        ),
        minimumSize: WidgetStatePropertyAll(Size(0, menuRowHeight)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: AppSpacing.md),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: AppShapes.hover),
        ),
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
        visualDensity: VisualDensity.standard,
        backgroundColor: palette.accent,
        foregroundColor: actionForeground,
        disabledBackgroundColor: palette.surfaceMuted,
        disabledForegroundColor: disabledControlForeground,
        shape: RoundedRectangleBorder(borderRadius: AppShapes.input),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
        minimumSize: Size(0, controlSize),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.standard,
        foregroundColor: palette.textPrimary,
        side: BorderSide(color: controlBorder),
        shape: RoundedRectangleBorder(borderRadius: AppShapes.input),
        minimumSize: Size(0, controlSize),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.standard,
        foregroundColor: accentOnSurface,
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
        minimumSize: Size(0, controlSize),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceMuted,
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
        borderSide: BorderSide(
          color: visibleUiColorOn(
            palette,
            background: palette.surfaceMuted,
            preferred: palette.accent,
          ),
          width: AppStrokes.focus,
        ),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: palette.border),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: palette.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: palette.danger, width: AppStrokes.focus),
      ),
      labelStyle: TextStyle(color: inputLabelColor),
      hintStyle: TextStyle(color: inputHintColor),
      constraints: BoxConstraints(minHeight: controlSize),
      contentPadding: EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: desktop ? AppSpacing.sm : AppSpacing.md,
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: palette.accent,
      inactiveTrackColor: palette.surfaceMuted,
      thumbColor: palette.accent,
      overlayColor: palette.accent.withValues(alpha: AppEmphasis.tint),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: palette.textSecondary,
      collapsedIconColor: palette.textSecondary,
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
  double fontSize = AppFontSizes.code,
  double height = 1.45,
  FontWeight fontWeight = FontWeight.w500,
}) {
  return TextStyle(
    fontFamily: AppFonts.code,
    color: color,
    fontSize: fontSize,
    height: height,
    fontWeight: fontWeight,
  );
}
