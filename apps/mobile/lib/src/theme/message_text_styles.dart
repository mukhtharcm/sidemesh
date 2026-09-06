import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'color_contrast.dart';
import 'app_tokens.dart';

export 'color_contrast.dart'
    show contrastRatio, minimumReadableTextContrast, readableColorForBackground;

Color messageLinkColor(AppColors colors, {required bool userBubble}) {
  final background = userBubble ? colors.userBubble : colors.canvas;
  final preferred = userBubble ? colors.userBubbleOn : colors.accent;
  final fallbacks = userBubble
      ? <Color>[
          colors.userBubbleOn,
          colors.accentOn,
          colors.textPrimary,
          colors.textSecondary,
        ]
      : <Color>[
          colors.accent,
          colors.info,
          colors.textPrimary,
          colors.textSecondary,
        ];
  return readableColorForBackground(
    background: background,
    preferred: preferred,
    fallbacks: fallbacks,
  );
}

Color messageBodyColor(AppColors colors, {required bool userBubble}) {
  final background = userBubble ? colors.userBubble : colors.canvas;
  final preferred = userBubble ? colors.userBubbleOn : colors.textPrimary;
  return readableTextOn(colors, background: background, preferred: preferred);
}

Color messageMetaColor(AppColors colors, {required bool userBubble}) {
  final background = userBubble ? colors.userBubble : colors.canvas;
  final preferred = userBubble ? colors.userBubbleOn : colors.textTertiary;
  final fallbacks = userBubble
      ? <Color>[colors.userBubbleOn, colors.accentOn, colors.textPrimary]
      : <Color>[colors.textSecondary, colors.textPrimary, colors.accent];
  return readableColorForBackground(
    background: background,
    preferred: preferred,
    fallbacks: fallbacks,
  );
}

TextStyle messageLinkStyle(
  AppColors colors, {
  required bool userBubble,
  TextStyle? baseStyle,
}) {
  final linkColor = messageLinkColor(colors, userBubble: userBubble);
  return linkTextStyleForBackground(
    background: userBubble ? colors.userBubble : colors.canvas,
    preferred: linkColor,
    fallbacks: const <Color>[],
    baseStyle: baseStyle,
  );
}

TextStyle linkTextStyleForBackground({
  required Color background,
  required Color preferred,
  required Iterable<Color> fallbacks,
  TextStyle? baseStyle,
}) {
  final linkColor = readableColorForBackground(
    background: background,
    preferred: preferred,
    fallbacks: fallbacks,
  );
  final source = baseStyle ?? const TextStyle();
  return source.copyWith(
    color: linkColor,
    decoration: TextDecoration.underline,
    decorationColor: linkColor.withValues(alpha: AppEmphasis.strong),
    decorationThickness: AppStrokes.focus,
    fontWeight: source.fontWeight ?? AppWeights.emphasis,
  );
}
