import 'package:flutter/material.dart';

import 'app_colors.dart';

const double minimumReadableTextContrast = 4.5;
const double minimumUiContrast = 3.0;

const Color _contrastInk = Color(0xFF0B0F14);
const Color _contrastPaper = Color(0xFFFFFBF3);

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

Color readableTextOn(
  AppColors colors, {
  required Color background,
  required Color preferred,
  Iterable<Color> additionalFallbacks = const <Color>[],
  double minimumContrast = minimumReadableTextContrast,
}) {
  return readableColorForBackground(
    background: background,
    preferred: preferred,
    fallbacks: <Color>[
      ...additionalFallbacks,
      colors.textPrimary,
      colors.textSecondary,
      colors.accentOn,
      colors.userBubbleOn,
      colors.canvas,
      _contrastInk,
      _contrastPaper,
    ],
    minimumContrast: minimumContrast,
  );
}

Color readableActionForeground(AppColors colors, Color background) {
  return readableTextOn(
    colors,
    background: background,
    preferred: colors.accentOn,
    additionalFallbacks: <Color>[colors.textPrimary, colors.userBubbleOn],
  );
}

Color readableSemanticForeground(
  AppColors colors, {
  required Color background,
  required Color preferred,
}) {
  return readableTextOn(
    colors,
    background: background,
    preferred: preferred,
    additionalFallbacks: <Color>[colors.textPrimary],
  );
}

Color visibleUiColorOn(
  AppColors colors, {
  required Color background,
  required Color preferred,
}) {
  return readableTextOn(
    colors,
    background: background,
    preferred: preferred,
    additionalFallbacks: <Color>[colors.borderStrong, colors.textPrimary],
    minimumContrast: minimumUiContrast,
  );
}

Color selectionFillForBackground(
  AppColors colors, {
  required Color background,
  required Color foreground,
}) {
  final base = visibleUiColorOn(
    colors,
    background: background,
    preferred: foreground,
  );
  final backgroundIsLight = background.computeLuminance() > 0.45;
  return base.withValues(alpha: backgroundIsLight ? 0.24 : 0.30);
}
