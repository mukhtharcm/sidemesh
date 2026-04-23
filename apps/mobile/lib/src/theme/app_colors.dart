import 'package:flutter/material.dart';

/// Theme extension that carries Sidemesh-specific semantic colors.
///
/// These colors are used for the terminal-inspired UI surfaces (diffs,
/// code blocks, activity cards, status pills, composer, etc.) and adapt
/// to the active brightness.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.canvas,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceMuted,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentMuted,
    required this.accentOn,
    required this.success,
    required this.successMuted,
    required this.danger,
    required this.dangerMuted,
    required this.warning,
    required this.warningMuted,
    required this.info,
    required this.infoMuted,
    required this.codeBackground,
    required this.codeBorder,
    required this.codeForeground,
    required this.diffAddLine,
    required this.diffAddGutter,
    required this.diffAddGlyph,
    required this.diffDelLine,
    required this.diffDelGutter,
    required this.diffDelGlyph,
    required this.diffMetaLine,
    required this.diffHunkLine,
    required this.diffGutterText,
    required this.userBubble,
    required this.userBubbleOn,
    required this.assistantBubble,
    required this.assistantBubbleBorder,
    required this.composerBackground,
  });

  final Color canvas;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceMuted;
  final Color border;
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color accent;
  final Color accentMuted;
  final Color accentOn;

  final Color success;
  final Color successMuted;
  final Color danger;
  final Color dangerMuted;
  final Color warning;
  final Color warningMuted;
  final Color info;
  final Color infoMuted;

  final Color codeBackground;
  final Color codeBorder;
  final Color codeForeground;

  final Color diffAddLine;
  final Color diffAddGutter;
  final Color diffAddGlyph;
  final Color diffDelLine;
  final Color diffDelGutter;
  final Color diffDelGlyph;
  final Color diffMetaLine;
  final Color diffHunkLine;
  final Color diffGutterText;

  final Color userBubble;
  final Color userBubbleOn;
  final Color assistantBubble;
  final Color assistantBubbleBorder;

  final Color composerBackground;

  /// Dark theme inspired by the Codex TUI: deep charcoal canvas, amber accent,
  /// GitHub-style green/red diff tints.
  static const dark = AppColors(
    canvas: Color(0xFF0B0F14),
    surface: Color(0xFF12171F),
    surfaceElevated: Color(0xFF171D27),
    surfaceMuted: Color(0xFF1D242F),
    border: Color(0xFF232B37),
    borderStrong: Color(0xFF30394A),
    textPrimary: Color(0xFFE6EDF3),
    textSecondary: Color(0xFF9AA7B4),
    textTertiary: Color(0xFF6E7A87),
    accent: Color(0xFFE78A3C),
    accentMuted: Color(0xFF3A2818),
    accentOn: Color(0xFF0B0F14),
    success: Color(0xFF3FB950),
    successMuted: Color(0xFF133A20),
    danger: Color(0xFFF85149),
    dangerMuted: Color(0xFF3B1418),
    warning: Color(0xFFD29922),
    warningMuted: Color(0xFF3A2E10),
    info: Color(0xFF58A6FF),
    infoMuted: Color(0xFF102A4A),
    codeBackground: Color(0xFF0E131A),
    codeBorder: Color(0xFF232B37),
    codeForeground: Color(0xFFD6DEE6),
    diffAddLine: Color(0xFF0F2A1A),
    diffAddGutter: Color(0xFF123A22),
    diffAddGlyph: Color(0xFF3FB950),
    diffDelLine: Color(0xFF2C0F11),
    diffDelGutter: Color(0xFF3B1418),
    diffDelGlyph: Color(0xFFF85149),
    diffMetaLine: Color(0xFF9AA7B4),
    diffHunkLine: Color(0xFF58A6FF),
    diffGutterText: Color(0xFF6E7A87),
    userBubble: Color(0xFFE78A3C),
    userBubbleOn: Color(0xFF0B0F14),
    assistantBubble: Color(0xFF12171F),
    assistantBubbleBorder: Color(0xFF232B37),
    composerBackground: Color(0xFF12171F),
  );

  /// Light theme with warm cream palette; accents and diffs match GitHub-light.
  static const light = AppColors(
    canvas: Color(0xFFF6EFE2),
    surface: Color(0xFFFFFBF3),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF1E7D3),
    border: Color(0xFFE6D9BF),
    borderStrong: Color(0xFFD1BF9E),
    textPrimary: Color(0xFF1C1812),
    textSecondary: Color(0xFF6D5B49),
    textTertiary: Color(0xFF9A8A75),
    accent: Color(0xFFCA6B1F),
    accentMuted: Color(0xFFF4DCC0),
    accentOn: Color(0xFFFFFBF3),
    success: Color(0xFF1A7F37),
    successMuted: Color(0xFFDCF3E0),
    danger: Color(0xFFCF222E),
    dangerMuted: Color(0xFFFBD6D3),
    warning: Color(0xFF9A6700),
    warningMuted: Color(0xFFFBEAC0),
    info: Color(0xFF0969DA),
    infoMuted: Color(0xFFDDEAFA),
    codeBackground: Color(0xFFF6EEDD),
    codeBorder: Color(0xFFE6D9BF),
    codeForeground: Color(0xFF1C1812),
    diffAddLine: Color(0xFFDAFBE1),
    diffAddGutter: Color(0xFFACEEBB),
    diffAddGlyph: Color(0xFF1A7F37),
    diffDelLine: Color(0xFFFFEBE9),
    diffDelGutter: Color(0xFFFFCECB),
    diffDelGlyph: Color(0xFFCF222E),
    diffMetaLine: Color(0xFF6D5B49),
    diffHunkLine: Color(0xFF0969DA),
    diffGutterText: Color(0xFF1F2328),
    userBubble: Color(0xFF1C1812),
    userBubbleOn: Color(0xFFFFFBF3),
    assistantBubble: Color(0xFFFBF3E1),
    assistantBubbleBorder: Color(0xFFD9C8A8),
    composerBackground: Color(0xFFFFFBF3),
  );

  @override
  AppColors copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceMuted,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentMuted,
    Color? accentOn,
    Color? success,
    Color? successMuted,
    Color? danger,
    Color? dangerMuted,
    Color? warning,
    Color? warningMuted,
    Color? info,
    Color? infoMuted,
    Color? codeBackground,
    Color? codeBorder,
    Color? codeForeground,
    Color? diffAddLine,
    Color? diffAddGutter,
    Color? diffAddGlyph,
    Color? diffDelLine,
    Color? diffDelGutter,
    Color? diffDelGlyph,
    Color? diffMetaLine,
    Color? diffHunkLine,
    Color? diffGutterText,
    Color? userBubble,
    Color? userBubbleOn,
    Color? assistantBubble,
    Color? assistantBubbleBorder,
    Color? composerBackground,
  }) {
    return AppColors(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      accentMuted: accentMuted ?? this.accentMuted,
      accentOn: accentOn ?? this.accentOn,
      success: success ?? this.success,
      successMuted: successMuted ?? this.successMuted,
      danger: danger ?? this.danger,
      dangerMuted: dangerMuted ?? this.dangerMuted,
      warning: warning ?? this.warning,
      warningMuted: warningMuted ?? this.warningMuted,
      info: info ?? this.info,
      infoMuted: infoMuted ?? this.infoMuted,
      codeBackground: codeBackground ?? this.codeBackground,
      codeBorder: codeBorder ?? this.codeBorder,
      codeForeground: codeForeground ?? this.codeForeground,
      diffAddLine: diffAddLine ?? this.diffAddLine,
      diffAddGutter: diffAddGutter ?? this.diffAddGutter,
      diffAddGlyph: diffAddGlyph ?? this.diffAddGlyph,
      diffDelLine: diffDelLine ?? this.diffDelLine,
      diffDelGutter: diffDelGutter ?? this.diffDelGutter,
      diffDelGlyph: diffDelGlyph ?? this.diffDelGlyph,
      diffMetaLine: diffMetaLine ?? this.diffMetaLine,
      diffHunkLine: diffHunkLine ?? this.diffHunkLine,
      diffGutterText: diffGutterText ?? this.diffGutterText,
      userBubble: userBubble ?? this.userBubble,
      userBubbleOn: userBubbleOn ?? this.userBubbleOn,
      assistantBubble: assistantBubble ?? this.assistantBubble,
      assistantBubbleBorder:
          assistantBubbleBorder ?? this.assistantBubbleBorder,
      composerBackground: composerBackground ?? this.composerBackground,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) {
      return this;
    }
    return AppColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      accentOn: Color.lerp(accentOn, other.accentOn, t)!,
      success: Color.lerp(success, other.success, t)!,
      successMuted: Color.lerp(successMuted, other.successMuted, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerMuted: Color.lerp(dangerMuted, other.dangerMuted, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningMuted: Color.lerp(warningMuted, other.warningMuted, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoMuted: Color.lerp(infoMuted, other.infoMuted, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      codeBorder: Color.lerp(codeBorder, other.codeBorder, t)!,
      codeForeground: Color.lerp(codeForeground, other.codeForeground, t)!,
      diffAddLine: Color.lerp(diffAddLine, other.diffAddLine, t)!,
      diffAddGutter: Color.lerp(diffAddGutter, other.diffAddGutter, t)!,
      diffAddGlyph: Color.lerp(diffAddGlyph, other.diffAddGlyph, t)!,
      diffDelLine: Color.lerp(diffDelLine, other.diffDelLine, t)!,
      diffDelGutter: Color.lerp(diffDelGutter, other.diffDelGutter, t)!,
      diffDelGlyph: Color.lerp(diffDelGlyph, other.diffDelGlyph, t)!,
      diffMetaLine: Color.lerp(diffMetaLine, other.diffMetaLine, t)!,
      diffHunkLine: Color.lerp(diffHunkLine, other.diffHunkLine, t)!,
      diffGutterText: Color.lerp(diffGutterText, other.diffGutterText, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      userBubbleOn: Color.lerp(userBubbleOn, other.userBubbleOn, t)!,
      assistantBubble: Color.lerp(assistantBubble, other.assistantBubble, t)!,
      assistantBubbleBorder:
          Color.lerp(assistantBubbleBorder, other.assistantBubbleBorder, t)!,
      composerBackground:
          Color.lerp(composerBackground, other.composerBackground, t)!,
    );
  }
}

extension AppColorsX on BuildContext {
  AppColors get colors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.dark;
}
