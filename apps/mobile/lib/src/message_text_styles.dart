import 'package:flutter/material.dart';

import 'theme/app_colors.dart';
import 'theme/app_tokens.dart';

const double minimumReadableTextContrast = 4.5;

double contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

Color readableColorForBackground({
  required Color background,
  required Color preferred,
  required Iterable<Color> fallbacks,
  double minimumContrast = minimumReadableTextContrast,
}) {
  var best = preferred;
  var bestContrast = contrastRatio(preferred, background);
  if (bestContrast >= minimumContrast) {
    return preferred;
  }

  for (final candidate in fallbacks) {
    final candidateContrast = contrastRatio(candidate, background);
    if (candidateContrast >= minimumContrast) {
      return candidate;
    }
    if (candidateContrast > bestContrast) {
      best = candidate;
      bestContrast = candidateContrast;
    }
  }

  return best;
}

Color messageLinkColor(AppColors colors, {required bool userBubble}) {
  final background = userBubble ? colors.userBubble : colors.assistantBubble;
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

Color messageMetaColor(AppColors colors, {required bool userBubble}) {
  final background = userBubble ? colors.userBubble : colors.assistantBubble;
  final preferred = userBubble ? colors.userBubbleOn : colors.textTertiary;
  final fallbacks = userBubble
      ? <Color>[
          colors.userBubbleOn,
          colors.accentOn,
          colors.textPrimary,
        ]
      : <Color>[
          colors.textSecondary,
          colors.textPrimary,
          colors.accent,
        ];
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
    background: userBubble ? colors.userBubble : colors.assistantBubble,
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
    decorationColor: linkColor.withValues(alpha: 0.86),
    decorationThickness: 1.35,
    fontWeight: source.fontWeight ?? AppWeights.emphasis,
  );
}
