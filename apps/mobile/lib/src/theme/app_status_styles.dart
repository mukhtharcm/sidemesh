import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_tokens.dart';
import 'color_contrast.dart';

enum MeshPillTone { neutral, accent, success, danger, warning, info }

({Color background, Color foreground, Color border}) meshPillColors(
  AppColors colors,
  MeshPillTone tone,
) {
  final (bg, preferredFg, preferredBorder) = switch (tone) {
    MeshPillTone.neutral => (
      colors.surfaceMuted,
      colors.textSecondary,
      Colors.transparent,
    ),
    MeshPillTone.accent => (
      colors.accentMuted,
      colors.accent,
      colors.accent.withValues(alpha: AppEmphasis.muted),
    ),
    MeshPillTone.success => (
      colors.successMuted,
      colors.success,
      colors.success.withValues(alpha: AppEmphasis.muted),
    ),
    MeshPillTone.danger => (
      colors.dangerMuted,
      colors.danger,
      colors.danger.withValues(alpha: AppEmphasis.muted),
    ),
    MeshPillTone.warning => (
      colors.warningMuted,
      colors.warning,
      colors.warning.withValues(alpha: AppEmphasis.muted),
    ),
    MeshPillTone.info => (
      colors.infoMuted,
      colors.info,
      colors.info.withValues(alpha: AppEmphasis.muted),
    ),
  };
  final fg = readableSemanticForeground(
    colors,
    background: bg,
    preferred: preferredFg,
  );
  return (background: bg, foreground: fg, border: preferredBorder);
}

enum MeshStatusTone {
  neutral,
  running,
  waiting,
  approval,
  queued,
  success,
  danger,
  offline,
  stale,
}

({Color background, Color foreground, Color border}) meshStatusBadgeColors(
  AppColors colors,
  MeshStatusTone tone,
) {
  final (bg, preferredFg, preferredBorder) = switch (tone) {
    MeshStatusTone.neutral => (
      colors.surfaceMuted,
      colors.textSecondary,
      colors.border,
    ),
    MeshStatusTone.running => (
      colors.successMuted,
      colors.success,
      colors.success.withValues(alpha: AppEmphasis.muted),
    ),
    MeshStatusTone.waiting => (
      colors.warningMuted,
      colors.warning,
      colors.warning.withValues(alpha: AppEmphasis.muted),
    ),
    MeshStatusTone.approval => (
      colors.warningMuted,
      colors.warning,
      colors.warning.withValues(alpha: AppEmphasis.disabled),
    ),
    MeshStatusTone.queued => (
      colors.infoMuted,
      colors.info,
      colors.info.withValues(alpha: AppEmphasis.muted),
    ),
    MeshStatusTone.success => (
      colors.successMuted,
      colors.success,
      colors.success.withValues(alpha: AppEmphasis.muted),
    ),
    MeshStatusTone.danger => (
      colors.dangerMuted,
      colors.danger,
      colors.danger.withValues(alpha: AppEmphasis.muted),
    ),
    MeshStatusTone.offline => (
      colors.surfaceMuted,
      colors.textTertiary,
      colors.border,
    ),
    MeshStatusTone.stale => (
      colors.surfaceMuted,
      colors.textSecondary,
      colors.borderStrong.withValues(alpha: AppEmphasis.secondary),
    ),
  };
  final fg = readableSemanticForeground(
    colors,
    background: bg,
    preferred: preferredFg,
  );
  return (background: bg, foreground: fg, border: preferredBorder);
}

enum MeshSurfaceTone { surface, elevated, muted, accent, warning, danger }

({Color background, Color border}) meshSurfaceColors(
  AppColors colors,
  MeshSurfaceTone tone, {
  bool selected = false,
}) {
  final bg = selected
      ? colors.accentMuted.withValues(alpha: AppEmphasis.secondary)
      : switch (tone) {
          MeshSurfaceTone.surface => colors.surface,
          MeshSurfaceTone.elevated => colors.surfaceElevated,
          MeshSurfaceTone.muted => colors.surfaceMuted,
          MeshSurfaceTone.accent => colors.accentMuted.withValues(
            alpha: AppEmphasis.secondary,
          ),
          MeshSurfaceTone.warning => colors.warningMuted.withValues(
            alpha: AppEmphasis.medium,
          ),
          MeshSurfaceTone.danger => colors.dangerMuted.withValues(
            alpha: AppEmphasis.medium,
          ),
        };
  final border = (selected
      ? colors.accent.withValues(alpha: AppEmphasis.disabled)
      : switch (tone) {
          MeshSurfaceTone.warning => colors.warning.withValues(
            alpha: AppEmphasis.muted,
          ),
          MeshSurfaceTone.danger => colors.danger.withValues(
            alpha: AppEmphasis.muted,
          ),
          MeshSurfaceTone.accent => colors.accent.withValues(
            alpha: AppEmphasis.muted,
          ),
          _ => colors.border,
        });
  return (background: bg, border: border);
}
