import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:xterm/xterm.dart' as xterm;

import 'app_colors.dart';
import 'app_tokens.dart';
import 'color_contrast.dart';

/// Code and terminal palettes share the app's readable foreground colors.
Map<String, TextStyle> buildSyntaxTheme(
  AppColors colors, {
  required bool dark,
}) {
  final base = dark ? atomOneDarkTheme : githubTheme;
  return {
    ...base,
    'root': (base['root'] ?? const TextStyle()).copyWith(
      backgroundColor: Colors.transparent,
      color: colors.codeForeground,
    ),
  };
}

xterm.TerminalTheme buildTerminalTheme(AppColors colors) {
  Color terminalColor(Color color) =>
      readableTerminalColorOn(colors, preferred: color);

  return xterm.TerminalTheme(
    cursor: visibleUiColorOn(
      colors,
      background: colors.codeBackground,
      preferred: colors.accent,
    ),
    selection: colors.accentMuted.withValues(alpha: AppEmphasis.secondary),
    foreground: colors.codeForeground,
    background: colors.codeBackground,
    black: colors.textTertiary,
    red: terminalColor(colors.danger),
    green: terminalColor(colors.success),
    yellow: terminalColor(colors.warning),
    blue: terminalColor(colors.accent),
    magenta: terminalColor(colors.info),
    cyan: terminalColor(colors.info),
    white: colors.codeForeground,
    brightBlack: terminalColor(colors.textSecondary),
    brightRed: terminalColor(_brightTerminalColor(colors.danger)),
    brightGreen: terminalColor(_brightTerminalColor(colors.success)),
    brightYellow: terminalColor(_brightTerminalColor(colors.warning)),
    brightBlue: terminalColor(_brightTerminalColor(colors.accent)),
    brightMagenta: terminalColor(_brightTerminalColor(colors.info)),
    brightCyan: terminalColor(_brightTerminalColor(colors.info)),
    brightWhite: colors.textPrimary,
    searchHitBackground: colors.warningMuted,
    searchHitBackgroundCurrent: colors.accentMuted,
    searchHitForeground: colors.textPrimary,
  );
}

Color _brightTerminalColor(Color color) =>
    Color.lerp(color, const Color(0xFFD8D8D8), 0.18)!;
