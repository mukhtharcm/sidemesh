import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../theme/app_control_styles.dart';
import '../theme/app_status_styles.dart';

/// A compact, delayed activity indicator for background verification.
///
/// The fixed footprint prevents nearby header content from shifting. Short
/// refreshes stay invisible so cached content can appear immediately without
/// flashing progress chrome.
class MeshDelayedActivityIndicator extends StatefulWidget {
  const MeshDelayedActivityIndicator({
    super.key,
    required this.active,
    this.delay = const Duration(milliseconds: 800),
    this.size = 12,
    this.strokeWidth = AppStrokes.focus,
    this.semanticLabel = 'Checking for updates',
  });

  final bool active;
  final Duration delay;
  final double size;
  final double strokeWidth;
  final String semanticLabel;

  @override
  State<MeshDelayedActivityIndicator> createState() =>
      _MeshDelayedActivityIndicatorState();
}

class _MeshDelayedActivityIndicatorState
    extends State<MeshDelayedActivityIndicator> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _syncVisibility();
  }

  @override
  void didUpdateWidget(covariant MeshDelayedActivityIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active || widget.delay != oldWidget.delay) {
      _syncVisibility();
    }
  }

  void _syncVisibility() {
    _timer?.cancel();
    _timer = null;
    if (!widget.active) {
      _visible = false;
      return;
    }
    if (_visible) {
      return;
    }
    _timer = Timer(widget.delay, () {
      if (!mounted || !widget.active) {
        return;
      }
      setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: _visible
          ? Semantics(
              label: widget.semanticLabel,
              liveRegion: true,
              child: CircularProgressIndicator(
                color: context.colors.accent,
                strokeWidth: widget.strokeWidth,
              ),
            )
          : null,
    );
  }
}

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
            fontSize: AppFontSizes.caption,
            fontWeight: AppWeights.title,
          ).copyWith(letterSpacing: AppLetterSpacing.caps)
        : Theme.of(context).textTheme.labelMedium?.copyWith(
            color: fg,
            fontWeight: bold ? AppWeights.emphasis : AppWeights.body,
            letterSpacing: AppLetterSpacing.caps,
          );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon == null ? AppSpacing.compact : AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppShapes.badge,
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: AppSizes.smallIcon, color: fg),
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
    this.bordered = true,
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
  final bool bordered;
  final double radius;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final effectiveEnabled = enabled && onTap != null;
    final surfaceColors = meshSurfaceColors(colors, tone, selected: selected);
    final bg = surfaceColors.background;
    final border = borderColor ?? surfaceColors.border;
    final borderRadius = BorderRadius.circular(radius);

    final content = AnimatedContainer(
      duration: AppMotion.quick,
      curve: AppMotion.standard,
      width: width,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: borderRadius,
        border: bordered ? Border.all(color: border) : null,
        boxShadow: tone == MeshSurfaceTone.elevated
            ? [AppShadows.surface(colors.textPrimary)]
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
        hoverColor: colors.surfaceElevated.withValues(
          alpha: AppEmphasis.disabled,
        ),
        splashColor: colors.accent.withValues(alpha: AppEmphasis.focus),
        child: content,
      ),
    );
  }
}

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
        ? const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          )
        : AppPadding.listRow;
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
      duration: AppMotion.quick,
      curve: AppMotion.standard,
      decoration: BoxDecoration(
        color: selected
            ? colors.accentMuted.withValues(alpha: AppEmphasis.medium)
            : Colors.transparent,
        borderRadius: borderRadius,
        border: selected
            ? Border.all(
                color: colors.accent.withValues(alpha: AppEmphasis.borderTint),
              )
            : null,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.rowMinHeight),
        child: Padding(padding: rowPadding, child: row),
      ),
    );

    if (!enabled || onTap == null) {
      return content;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: onTap,
        hoverColor: colors.surfaceMuted.withValues(alpha: AppEmphasis.medium),
        splashColor: colors.accent.withValues(alpha: AppEmphasis.focus),
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
          fontSize: compact ? AppFontSizes.micro : AppFontSizes.metadata,
          fontWeight: AppWeights.emphasis,
          letterSpacing: AppLetterSpacing.body,
          height: AppLineHeights.tight,
        ) ??
        TextStyle(
          color: fg,
          fontSize: compact ? AppFontSizes.micro : AppFontSizes.metadata,
          fontWeight: AppWeights.emphasis,
          height: AppLineHeights.tight,
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
            Icon(
              icon,
              size: compact ? AppSizes.tinyIcon : AppSizes.smallIcon,
              color: fg,
            ),
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

/// Deliberate destructive action primitive for approval and host/file surfaces.
class MeshDangerAction extends StatelessWidget {
  const MeshDangerAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.delete_outline_rounded,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: AppSizes.inlineIcon),
      label: Text(label),
      style: AppControlStyles.danger(colors),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.tight,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.pill,
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.textSecondary,
          letterSpacing: AppLetterSpacing.caps,
        ),
      ),
    );
  }
}

/// Plain card surface shared by page content; explicit status borders are kept.
class MeshCard extends StatelessWidget {
  const MeshCard({
    super.key,
    required this.child,
    this.padding = AppPadding.card,
    this.onTap,
    this.tone = MeshCardTone.elevated,
    this.borderColor,
    this.bordered,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final MeshCardTone tone;
  final Color? borderColor;
  final bool? bordered;

  @override
  Widget build(BuildContext context) {
    return MeshSurface(
      padding: padding,
      onTap: onTap,
      tone: _meshSurfaceToneForCardTone(tone),
      borderColor: borderColor,
      bordered: bordered ?? borderColor != null,
      child: child,
    );
  }
}

MeshSurfaceTone _meshSurfaceToneForCardTone(MeshCardTone tone) {
  return switch (tone) {
    MeshCardTone.surface => MeshSurfaceTone.elevated,
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
    this.body = '',
    this.action,
  }) : compact = false;

  /// In-list / inline variant with a plain icon and tighter padding.
  /// Use when the empty state lives inside a list, sheet, or pane that
  /// already has its own outer padding.
  const MeshEmptyState.compact({
    super.key,
    required this.icon,
    required this.title,
    this.body = '',
    this.action,
  }) : compact = true;

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final padding = compact ? AppSpacing.lg : AppSpacing.xl;
    final iconSize = compact ? AppSizes.icon : AppSizes.largeIcon;
    final spacingTop = compact ? AppSpacing.md : AppSpacing.lg;
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (compact)
              Icon(icon, size: iconSize, color: colors.textSecondary)
            else
              Container(
                width: AppSizes.emptyIconWell,
                height: AppSizes.emptyIconWell,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: BorderRadius.circular(AppRadii.surface),
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
            if (body.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                  height: AppLineHeights.reading,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              action!,
            ],
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
    this.framed = true,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? color;
  final bool framed;

  /// Accessibility label surfaced to screen readers. Defaults to [tooltip].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = semanticLabel ?? tooltip;
    final content = SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Icon(
          icon,
          size: AppSizes.inlineIcon,
          color: color ?? colors.textSecondary,
        ),
      ),
    );
    final interactive = framed
        ? MeshSurface(
            onTap: onTap,
            padding: EdgeInsets.zero,
            radius: AppRadii.control,
            child: content,
          )
        : Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: AppShapes.input,
              onTap: onTap,
              child: content,
            ),
          );
    final button = Semantics(label: label, button: true, child: interactive);
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
    _controller = AnimationController(duration: AppMotion.breathe, vsync: this)
      ..repeat(reverse: true);
    _opacity = Tween<double>(begin: 1.0, end: 0.3).animate(
      CurvedAnimation(parent: _controller, curve: AppMotion.continuous),
    );
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

/// Quiet first-load state; refreshes keep the loaded content visible.
class MeshLoader extends StatelessWidget {
  const MeshLoader({super.key, this.size = 20, this.label = 'Loading'});

  final double size;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
    child: Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: size,
            child: CircularProgressIndicator.adaptive(
              strokeWidth: AppStrokes.indicator,
              semanticsLabel: label,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
