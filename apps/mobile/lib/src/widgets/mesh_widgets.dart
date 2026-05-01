import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

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
    final (bg, fg, border) = switch (tone) {
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

    final textStyle = mono
        ? monoStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700)
            .copyWith(letterSpacing: 0.2)
        : Theme.of(context).textTheme.labelMedium?.copyWith(
              color: fg,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
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

/// Outlined card container used across the app. Replaces the Material [Card].
class MeshCard extends StatelessWidget {
  const MeshCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.tone = MeshCardTone.surface,
    this.borderColor,
    this.accentStrip,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final MeshCardTone tone;
  final Color? borderColor;
  final Color? accentStrip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bg = switch (tone) {
      MeshCardTone.surface => colors.surface,
      MeshCardTone.elevated => colors.surfaceElevated,
      MeshCardTone.muted => colors.surfaceMuted,
    };
    final border = borderColor ?? colors.border;

    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            if (accentStrip != null)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: accentStrip),
              ),
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );

    if (onTap == null) {
      return content;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        hoverColor: colors.surfaceElevated.withValues(alpha: 0.5),
        splashColor: colors.accent.withValues(alpha: 0.08),
        child: content,
      ),
    );
  }
}

enum MeshCardTone { surface, elevated, muted }

/// Large empty state placeholder.
class MeshEmptyState extends StatelessWidget {
  const MeshEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colors.accentMuted,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: colors.accent.withValues(alpha: 0.4)),
              ),
              child: Icon(icon, size: 32, color: colors.accent),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
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
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final button = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: color ?? colors.textSecondary),
        ),
      ),
    );
    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

/// A subtle "pulse" indicator used in running/live contexts.
class LivePulse extends StatefulWidget {
  const LivePulse({super.key, this.color});

  final Color? color;

  @override
  State<LivePulse> createState() => _LivePulseState();
}

class _LivePulseState extends State<LivePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.colors.success;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = (_controller.value * 2 - 1).abs();
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.2 + 0.4 * (1 - t)),
                blurRadius: 8 + 6 * (1 - t),
                spreadRadius: 0.5,
              ),
            ],
          ),
        );
      },
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
