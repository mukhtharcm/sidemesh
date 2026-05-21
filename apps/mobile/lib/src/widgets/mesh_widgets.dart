import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../app_icons.dart';

/// Small pill chip used for status / metadata.
class MeshPill extends StatelessWidget {
  const MeshPill({
    super.key,
    required this.label,
    this.tone = MeshPillTone.neutral,
    this.icon,
    this.bold = true,
    this.mono = false,
  });

  final String label;
  final MeshPillTone tone;
  final IconData? icon;
  final bool bold;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final toneColors = meshPillColors(colors, tone);
    final bg = toneColors.background;
    final fg = toneColors.foreground;
    final border = toneColors.border;

    final textStyle = mono
        ? monoStyle(
            color: fg,
            fontSize: 11.5,
            fontWeight: AppWeights.title,
          ).copyWith(letterSpacing: 0.2)
        : Theme.of(context).textTheme.labelMedium?.copyWith(
            color: fg,
            fontWeight: bold ? AppWeights.emphasis : AppWeights.body,
            letterSpacing: 0.2,
          );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon == null ? 10 : 8,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }
}

enum MeshPillTone { neutral, accent, success, danger, warning, info }

({Color background, Color foreground, Color border}) meshPillColors(
  AppColors colors,
  MeshPillTone tone,
) {
  final (bg, preferredFg, preferredBorder) = switch (tone) {
    MeshPillTone.neutral => (
      colors.surfaceMuted,
      colors.textSecondary,
      colors.border,
    ),
    MeshPillTone.accent => (
      colors.accentMuted,
      colors.accent,
      colors.accent.withValues(alpha: 0.4),
    ),
    MeshPillTone.success => (
      colors.successMuted,
      colors.success,
      colors.success.withValues(alpha: 0.4),
    ),
    MeshPillTone.danger => (
      colors.dangerMuted,
      colors.danger,
      colors.danger.withValues(alpha: 0.4),
    ),
    MeshPillTone.warning => (
      colors.warningMuted,
      colors.warning,
      colors.warning.withValues(alpha: 0.4),
    ),
    MeshPillTone.info => (
      colors.infoMuted,
      colors.info,
      colors.info.withValues(alpha: 0.4),
    ),
  };
  final fg = readableSemanticForeground(
    colors,
    background: bg,
    preferred: preferredFg,
  );
  return (background: bg, foreground: fg, border: preferredBorder);
}

/// Canonical Sidemesh surface primitive.
///
/// Use this for app-owned panels, rows, and tool wells before reaching for
/// Material [Card]. It keeps border, radius, fill, selection, and tap feedback
/// consistent across mobile and desktop.
class MeshSurface extends StatelessWidget {
  const MeshSurface({
    super.key,
    required this.child,
    this.padding = AppPadding.card,
    this.onTap,
    this.tone = MeshSurfaceTone.surface,
    this.borderColor,
    this.selected = false,
    this.enabled = true,
    this.radius = AppRadii.surface,
    this.width,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final MeshSurfaceTone tone;
  final Color? borderColor;
  final bool selected;
  final bool enabled;
  final double radius;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final effectiveEnabled = enabled && onTap != null;
    final bg = selected
        ? colors.accentMuted.withValues(alpha: 0.72)
        : switch (tone) {
            MeshSurfaceTone.surface => colors.surface,
            MeshSurfaceTone.elevated => colors.surfaceElevated,
            MeshSurfaceTone.muted => colors.surfaceMuted,
            MeshSurfaceTone.accent => colors.accentMuted.withValues(
              alpha: 0.72,
            ),
            MeshSurfaceTone.warning => colors.warningMuted.withValues(
              alpha: 0.62,
            ),
            MeshSurfaceTone.danger => colors.dangerMuted.withValues(
              alpha: 0.58,
            ),
          };
    final border =
        borderColor ??
        (selected
            ? colors.accent.withValues(alpha: 0.52)
            : switch (tone) {
                MeshSurfaceTone.warning => colors.warning.withValues(
                  alpha: 0.36,
                ),
                MeshSurfaceTone.danger => colors.danger.withValues(alpha: 0.36),
                MeshSurfaceTone.accent => colors.accent.withValues(alpha: 0.36),
                _ => colors.border,
              });
    final borderRadius = BorderRadius.circular(radius);

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      width: width,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: borderRadius,
        border: Border.all(color: border),
        boxShadow: tone == MeshSurfaceTone.elevated
            ? [
                BoxShadow(
                  color: colors.textPrimary.withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Padding(padding: padding, child: child),
      ),
    );

    if (!effectiveEnabled) {
      return content;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        hoverColor: colors.surfaceElevated.withValues(alpha: 0.5),
        splashColor: colors.accent.withValues(alpha: 0.08),
        child: content,
      ),
    );
  }
}

enum MeshSurfaceTone { surface, elevated, muted, accent, warning, danger }

class MeshStatusRail extends StatefulWidget {
  const MeshStatusRail({
    super.key,
    required this.label,
    this.icon,
    this.progress,
    this.active = false,
    this.trailing,
    this.tone = MeshStatusRailTone.accent,
    this.surfaceTone = MeshSurfaceTone.muted,
    this.mono = false,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 10),
    this.radius = AppRadii.control,
  });

  final String label;
  final IconData? icon;
  final double? progress;
  final bool active;
  final Widget? trailing;
  final MeshStatusRailTone tone;
  final MeshSurfaceTone surfaceTone;
  final bool mono;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  State<MeshStatusRail> createState() => _MeshStatusRailState();
}

class _MeshStatusRailState extends State<MeshStatusRail>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _updateAnimation();
  }

  @override
  void didUpdateWidget(covariant MeshStatusRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.progress != widget.progress) {
      _updateAnimation();
    }
  }

  void _updateAnimation() {
    final shouldAnimate = widget.active && widget.progress == null;
    if (shouldAnimate) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
      return;
    }
    if (_controller.isAnimating) {
      _controller.stop();
    }
    _controller.value = 0;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final barColor = switch (widget.tone) {
      MeshStatusRailTone.neutral => colors.textSecondary,
      MeshStatusRailTone.accent => colors.accent,
      MeshStatusRailTone.warning => colors.warning,
      MeshStatusRailTone.info => colors.info,
    };
    final labelStyle = widget.mono
        ? monoStyle(
            color: colors.textSecondary,
            fontSize: 10.5,
            fontWeight: AppWeights.title,
          ).copyWith(letterSpacing: 0.2)
        : Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
            fontWeight: AppWeights.emphasis,
          );

    return MeshSurface(
      tone: widget.surfaceTone,
      radius: widget.radius,
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: barColor),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle,
                ),
              ),
              if (widget.trailing != null) ...[
                const SizedBox(width: 8),
                widget.trailing!,
              ],
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: barColor.withValues(alpha: 0.16),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final progress = widget.progress;
                    if (progress != null) {
                      final clamped = progress.clamp(0.0, 1.0);
                      if (clamped <= 0) {
                        return const SizedBox.shrink();
                      }
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: clamped,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: barColor,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      );
                    }
                    if (!widget.active) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: 0.22,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: barColor.withValues(alpha: 0.48),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                      );
                    }
                    final segmentWidth = constraints.maxWidth < 96
                        ? constraints.maxWidth * 0.32
                        : 72.0;
                    return AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        final travel = constraints.maxWidth + segmentWidth;
                        final left =
                            (travel * _controller.value) - segmentWidth;
                        return Stack(
                          children: [
                            Positioned(
                              left: left,
                              top: 0,
                              bottom: 0,
                              child: Container(
                                width: segmentWidth,
                                decoration: BoxDecoration(
                                  color: barColor,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum MeshStatusRailTone { neutral, accent, warning, info }

/// Standard list row shell for session, host, file, and settings rows.
class MeshListRow extends StatelessWidget {
  const MeshListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.meta,
    this.leading,
    this.trailing,
    this.badges = const [],
    this.onTap,
    this.selected = false,
    this.enabled = true,
    this.dense = false,
    this.tone = MeshSurfaceTone.surface,
    this.framed = true,
    this.radius = AppRadii.surface,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? meta;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> badges;
  final VoidCallback? onTap;
  final bool selected;
  final bool enabled;
  final bool dense;
  final MeshSurfaceTone tone;
  final bool framed;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rowPadding = dense
        ? const EdgeInsets.fromLTRB(12, 10, 10, 10)
        : const EdgeInsets.fromLTRB(14, 14, 12, 14);
    final gap = dense ? AppSpacing.sm : AppSpacing.md;
    final borderRadius = BorderRadius.circular(radius);
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leading != null) ...[leading!, SizedBox(width: gap)],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: title),
                  if (badges.isNotEmpty) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Flexible(
                      child: Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        alignment: WrapAlignment.end,
                        children: badges,
                      ),
                    ),
                  ],
                ],
              ),
              if (subtitle != null) ...[
                SizedBox(height: dense ? 3 : AppSpacing.xs),
                subtitle!,
              ],
              if (meta != null) ...[
                SizedBox(height: dense ? 3 : AppSpacing.xs),
                meta!,
              ],
            ],
          ),
        ),
        if (trailing != null) ...[SizedBox(width: gap), trailing!],
      ],
    );

    if (framed) {
      return MeshSurface(
        tone: tone,
        selected: selected,
        enabled: enabled,
        onTap: onTap,
        padding: rowPadding,
        radius: radius,
        child: row,
      );
    }

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: selected
            ? colors.accentMuted.withValues(alpha: 0.56)
            : Colors.transparent,
        borderRadius: borderRadius,
        border: selected
            ? Border.all(color: colors.accent.withValues(alpha: 0.28))
            : null,
      ),
      child: Padding(padding: rowPadding, child: row),
    );

    if (!enabled || onTap == null) {
      return content;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        hoverColor: colors.surfaceMuted.withValues(alpha: 0.62),
        splashColor: colors.accent.withValues(alpha: 0.08),
        child: content,
      ),
    );
  }
}

/// Compact status label with one visual grammar for live, waiting, failed,
/// stale, queued, approval, and offline states.
class MeshStatusBadge extends StatelessWidget {
  const MeshStatusBadge({
    super.key,
    required this.label,
    this.tone = MeshStatusTone.neutral,
    this.icon,
    this.live = false,
    this.compact = false,
  });

  final String label;
  final MeshStatusTone tone;
  final IconData? icon;
  final bool live;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final toneColors = meshStatusBadgeColors(colors, tone);
    final bg = toneColors.background;
    final fg = toneColors.foreground;
    final border = toneColors.border;
    final horizontal = compact ? 7.0 : 9.0;
    final vertical = compact ? 3.0 : 4.0;
    final textStyle =
        Theme.of(context).textTheme.labelSmall?.copyWith(
          color: fg,
          fontSize: compact ? 10.2 : 11,
          fontWeight: AppWeights.emphasis,
          letterSpacing: AppLetterSpacing.body,
          height: 1.1,
        ) ??
        TextStyle(
          color: fg,
          fontSize: compact ? 10.2 : 11,
          fontWeight: AppWeights.emphasis,
          height: 1.1,
        );

    return Container(
      padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: vertical),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadii.badge),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live) ...[
            LivePulse(color: fg),
            const SizedBox(width: AppSpacing.xs),
          ] else if (icon != null) ...[
            Icon(icon, size: compact ? 12 : 13, color: fg),
            const SizedBox(width: AppSpacing.xs),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: textStyle,
            ),
          ),
        ],
      ),
    );
  }
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
      colors.success.withValues(alpha: 0.4),
    ),
    MeshStatusTone.waiting => (
      colors.warningMuted,
      colors.warning,
      colors.warning.withValues(alpha: 0.42),
    ),
    MeshStatusTone.approval => (
      colors.warningMuted,
      colors.warning,
      colors.warning.withValues(alpha: 0.52),
    ),
    MeshStatusTone.queued => (
      colors.infoMuted,
      colors.info,
      colors.info.withValues(alpha: 0.42),
    ),
    MeshStatusTone.success => (
      colors.successMuted,
      colors.success,
      colors.success.withValues(alpha: 0.4),
    ),
    MeshStatusTone.danger => (
      colors.dangerMuted,
      colors.danger,
      colors.danger.withValues(alpha: 0.42),
    ),
    MeshStatusTone.offline => (
      colors.surfaceMuted,
      colors.textTertiary,
      colors.border,
    ),
    MeshStatusTone.stale => (
      colors.surfaceMuted,
      colors.textSecondary,
      colors.borderStrong.withValues(alpha: 0.72),
    ),
  };
  final fg = readableSemanticForeground(
    colors,
    background: bg,
    preferred: preferredFg,
  );
  return (background: bg, foreground: fg, border: preferredBorder);
}

/// Deliberate destructive action primitive for approval and host/file surfaces.
class MeshDangerAction extends StatelessWidget {
  const MeshDangerAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = AppIcons.delete_outline_rounded,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.danger,
        side: BorderSide(color: colors.danger.withValues(alpha: 0.46)),
        backgroundColor: colors.dangerMuted.withValues(alpha: 0.28),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
      ),
    );
  }
}

/// Skeleton block that matches the Mesh surface geometry.
class MeshSkeleton extends StatefulWidget {
  const MeshSkeleton({
    super.key,
    this.width,
    required this.height,
    this.radius = AppRadii.control,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<MeshSkeleton> createState() => _MeshSkeletonState();
}

class _MeshSkeletonState extends State<MeshSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final pulse = 0.38 + (0.18 * (1 - (2 * t - 1).abs()));
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: colors.surfaceMuted.withValues(alpha: pulse),
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(color: colors.border.withValues(alpha: 0.42)),
          ),
        );
      },
    );
  }
}

/// Loading heading placeholder for section titles and short blurbs.
class MeshSectionHeadingSkeleton extends StatelessWidget {
  const MeshSectionHeadingSkeleton({
    super.key,
    this.titleWidthFactor = 0.26,
    this.subtitleWidthFactor = 0.48,
  });

  final double titleWidthFactor;
  final double subtitleWidthFactor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FractionallySizedBox(
          widthFactor: titleWidthFactor,
          alignment: Alignment.centerLeft,
          child: const MeshSkeleton(height: 16, radius: AppRadii.badge),
        ),
        const SizedBox(height: 6),
        FractionallySizedBox(
          widthFactor: subtitleWidthFactor,
          alignment: Alignment.centerLeft,
          child: const MeshSkeleton(height: 12, radius: AppRadii.badge),
        ),
      ],
    );
  }
}

/// Loading row placeholder with the same proportions as [MeshListRow].
class MeshListRowSkeleton extends StatelessWidget {
  const MeshListRowSkeleton({
    super.key,
    this.showLeading = true,
    this.showTrailing = true,
    this.showSubtitle = true,
    this.showMeta = false,
    this.badgeCount = 0,
    this.dense = false,
    this.tone = MeshSurfaceTone.surface,
    this.framed = true,
    this.radius = AppRadii.surface,
    this.titleWidthFactor = 0.46,
    this.subtitleWidthFactor = 0.74,
    this.metaWidthFactor = 0.34,
  });

  final bool showLeading;
  final bool showTrailing;
  final bool showSubtitle;
  final bool showMeta;
  final int badgeCount;
  final bool dense;
  final MeshSurfaceTone tone;
  final bool framed;
  final double radius;
  final double titleWidthFactor;
  final double subtitleWidthFactor;
  final double metaWidthFactor;

  @override
  Widget build(BuildContext context) {
    final rowPadding = dense
        ? const EdgeInsets.fromLTRB(12, 10, 10, 10)
        : const EdgeInsets.fromLTRB(14, 14, 12, 14);
    final gap = dense ? AppSpacing.sm : AppSpacing.md;
    final leadingSize = dense ? 34.0 : 40.0;

    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLeading) ...[
          MeshSkeleton(
            width: leadingSize,
            height: leadingSize,
            radius: dense ? AppRadii.control : AppRadii.surface,
          ),
          SizedBox(width: gap),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FractionallySizedBox(
                      widthFactor: titleWidthFactor,
                      alignment: Alignment.centerLeft,
                      child: MeshSkeleton(
                        height: dense ? 14 : 16,
                        radius: AppRadii.badge,
                      ),
                    ),
                  ),
                  if (badgeCount > 0) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: List<Widget>.generate(badgeCount, (index) {
                        final width = index.isEven ? 48.0 : 40.0;
                        return MeshSkeleton(
                          width: width,
                          height: 18,
                          radius: 999,
                        );
                      }),
                    ),
                  ],
                ],
              ),
              if (showSubtitle) ...[
                SizedBox(height: dense ? 6 : 8),
                FractionallySizedBox(
                  widthFactor: subtitleWidthFactor,
                  alignment: Alignment.centerLeft,
                  child: const MeshSkeleton(height: 12, radius: AppRadii.badge),
                ),
              ],
              if (showMeta) ...[
                const SizedBox(height: 6),
                FractionallySizedBox(
                  widthFactor: metaWidthFactor,
                  alignment: Alignment.centerLeft,
                  child: const MeshSkeleton(height: 10, radius: AppRadii.badge),
                ),
              ],
            ],
          ),
        ),
        if (showTrailing) ...[
          SizedBox(width: gap),
          MeshSkeleton(
            width: dense ? 34 : 42,
            height: dense ? 12 : 14,
            radius: AppRadii.badge,
          ),
        ],
      ],
    );

    if (!framed) {
      return Padding(padding: rowPadding, child: row);
    }

    return MeshSurface(
      padding: rowPadding,
      tone: tone,
      radius: radius,
      child: row,
    );
  }
}

/// Small inline badge for dense metadata tags inside selection and picker rows.
class MeshInlineBadge extends StatelessWidget {
  const MeshInlineBadge({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.pill,
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Shared selection card used for compact model/profile pickers.
class MeshSelectionCard extends StatelessWidget {
  const MeshSelectionCard({
    super.key,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.loading,
    required this.badges,
    required this.onTap,
    this.icon,
    this.error,
    this.currentValue,
    this.currentValueLabel = 'Current setting',
    this.onRetry,
    this.retryLabel = 'Retry loading',
    this.compact = false,
  });

  final String title;
  final String value;
  final String subtitle;
  final bool loading;
  final List<String> badges;
  final VoidCallback? onTap;
  final IconData? icon;
  final String? error;
  final String? currentValue;
  final String currentValueLabel;
  final VoidCallback? onRetry;
  final String retryLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshSurface(
      onTap: loading ? null : onTap,
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: colors.textSecondary),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  AppIcons.keyboard_arrow_down_rounded,
                  color: colors.textSecondary,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(fontWeight: AppWeights.body),
              ),
              ...badges.map((badge) => MeshInlineBadge(label: badge)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: compact ? 2 : null,
            overflow: compact ? TextOverflow.ellipsis : null,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: compact ? 1.25 : 1.35,
            ),
          ),
          if ((currentValue ?? '').trim().isNotEmpty &&
              currentValue!.trim() != value.trim()) ...[
            const SizedBox(height: 8),
            Text(
              '$currentValueLabel: ${currentValue!.trim()}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ],
          if (error != null && onRetry != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(AppIcons.refresh_rounded, size: 18),
              label: Text(retryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// Skeleton companion for [MeshSelectionCard].
class MeshSelectionCardSkeleton extends StatelessWidget {
  const MeshSelectionCardSkeleton({
    super.key,
    this.showIcon = true,
    this.compact = false,
    this.badgeCount = 2,
    this.showCurrentValue = false,
  });

  final bool showIcon;
  final bool compact;
  final int badgeCount;
  final bool showCurrentValue;

  @override
  Widget build(BuildContext context) {
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showIcon) ...[
                const MeshSkeleton(width: 16, height: 16, radius: 6),
                const SizedBox(width: 8),
              ],
              const Expanded(
                child: FractionallySizedBox(
                  widthFactor: 0.28,
                  alignment: Alignment.centerLeft,
                  child: MeshSkeleton(height: 14, radius: AppRadii.badge),
                ),
              ),
              const SizedBox(width: 12),
              const MeshSkeleton(width: 18, height: 18, radius: 999),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const MeshSkeleton(
                width: 112,
                height: 16,
                radius: AppRadii.badge,
              ),
              ...List<Widget>.generate(
                badgeCount,
                (index) => MeshSkeleton(
                  width: index.isEven ? 48 : 42,
                  height: 18,
                  radius: 999,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const MeshSkeleton(height: 12, radius: AppRadii.badge),
          const SizedBox(height: 6),
          FractionallySizedBox(
            widthFactor: compact ? 0.72 : 0.58,
            alignment: Alignment.centerLeft,
            child: const MeshSkeleton(height: 12, radius: AppRadii.badge),
          ),
          if (showCurrentValue) ...[
            const SizedBox(height: 8),
            const FractionallySizedBox(
              widthFactor: 0.46,
              alignment: Alignment.centerLeft,
              child: MeshSkeleton(height: 12, radius: AppRadii.badge),
            ),
          ],
        ],
      ),
    );
  }
}

/// Skeleton chips row for loading option groups such as reasoning presets.
class MeshChipSkeletonWrap extends StatelessWidget {
  const MeshChipSkeletonWrap({super.key, this.widths = const [72, 92, 78]});

  final List<double> widths;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: widths
          .map(
            (width) => MeshSkeleton(
              width: width,
              height: 40,
              radius: AppRadii.control,
            ),
          )
          .toList(growable: false),
    );
  }
}

/// Outlined card container used across the app. Replaces the Material [Card].
class MeshCard extends StatelessWidget {
  const MeshCard({
    super.key,
    required this.child,
    this.padding = AppPadding.card,
    this.onTap,
    this.tone = MeshCardTone.surface,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final MeshCardTone tone;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return MeshSurface(
      padding: padding,
      onTap: onTap,
      tone: _meshSurfaceToneForCardTone(tone),
      borderColor: borderColor,
      child: child,
    );
  }
}

MeshSurfaceTone _meshSurfaceToneForCardTone(MeshCardTone tone) {
  return switch (tone) {
    MeshCardTone.surface => MeshSurfaceTone.surface,
    MeshCardTone.elevated => MeshSurfaceTone.elevated,
    MeshCardTone.muted => MeshSurfaceTone.muted,
  };
}

enum MeshCardTone { surface, elevated, muted }

/// Large empty state placeholder.
class MeshEmptyState extends StatelessWidget {
  const MeshEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  }) : compact = false;

  /// In-list / inline variant — smaller icon bubble, tighter padding.
  /// Use when the empty state lives inside a list, sheet, or pane that
  /// already has its own outer padding.
  const MeshEmptyState.compact({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  }) : compact = true;

  final IconData icon;
  final String title;
  final String body;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final padding = compact ? 20.0 : 32.0;
    final bubble = compact ? 52.0 : 72.0;
    final bubbleRadius = compact ? 16.0 : 22.0;
    final iconSize = compact ? 24.0 : 32.0;
    final spacingTop = compact ? 12.0 : 18.0;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: bubble,
              height: bubble,
              decoration: BoxDecoration(
                color: colors.accentMuted,
                borderRadius: BorderRadius.circular(bubbleRadius),
                border: Border.all(color: colors.accent.withValues(alpha: 0.4)),
              ),
              child: Icon(icon, size: iconSize, color: colors.accent),
            ),
            SizedBox(height: spacingTop),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: AppWeights.title,
                color: colors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A very small icon button built on top of [Material]+[InkWell].
class MeshIconButton extends StatelessWidget {
  const MeshIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.color,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? color;

  /// Accessibility label surfaced to screen readers. Defaults to [tooltip].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = semanticLabel ?? tooltip;
    final button = Semantics(
      label: label,
      button: true,
      child: MeshSurface(
        onTap: onTap,
        padding: EdgeInsets.zero,
        radius: AppRadii.control,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Icon(icon, size: 18, color: color ?? colors.textSecondary),
          ),
        ),
      ),
    );
    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

/// A live-status indicator that pulses with a gentle opacity animation
/// to communicate active agent activity.
///
/// The animation is driven by a [SingleTickerProviderStateMixin] and
/// automatically pauses when the app is backgrounded via
/// [WidgetsBindingObserver]. Because [ListView.builder] destroys
/// off-screen items, the ticker is also naturally disposed when the
/// widget scrolls out of the viewport — keeping resource usage minimal.
class LivePulse extends StatefulWidget {
  const LivePulse({super.key, this.color});

  final Color? color;

  @override
  State<LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<LivePulse>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);
    _opacity = Tween<double>(
      begin: 1.0,
      end: 0.3,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (!_controller.isAnimating) _controller.repeat(reverse: true);
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.colors.success;
    // RepaintBoundary isolates the opacity repaint to this 8×8 region so
    // the animation doesn't trigger repaints in ancestor widgets.
    return RepaintBoundary(
      child: FadeTransition(
        opacity: _opacity,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// Loading spinner with Sidemesh tone.
class MeshLoader extends StatelessWidget {
  const MeshLoader({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: colors.accent,
        ),
      ),
    );
  }
}
