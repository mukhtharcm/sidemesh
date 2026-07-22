import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// Keeps primary app content on one predictable horizontal grid.
class AppContentColumn extends StatelessWidget {
  const AppContentColumn({
    super.key,
    required this.child,
    this.maxWidth = AppSizes.contentMaxWidth,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final double maxWidth;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

/// One section-heading grammar for settings and management surfaces.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            SizedBox(
              width: AppSizes.icon,
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, size: AppSizes.icon, color: colors.accent),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// A flat management row with fixed geometry and optional supporting content.
class AppSettingsRow extends StatelessWidget {
  const AppSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.footer,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? footer;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = danger ? colors.danger : colors.textPrimary;
    final iconColor = danger ? colors.danger : colors.textSecondary;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSizes.rowMinHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: AppSizes.icon,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(icon, size: AppSizes.icon, color: iconColor),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: Theme.of(
                          context,
                        ).textTheme.titleSmall?.copyWith(color: foreground),
                      ),
                      if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.md),
                  trailing!,
                ],
              ],
            ),
            if (footer != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSizes.icon + AppSpacing.sm,
                ),
                child: footer!,
              ),
            ],
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
        onTap: onTap,
        borderRadius: AppShapes.input,
        hoverColor: colors.surfaceMuted,
        child: content,
      ),
    );
  }
}

/// Small leading icon treatment for the few places that need a filled well.
class AppIconWell extends StatelessWidget {
  const AppIconWell({
    super.key,
    required this.icon,
    this.color,
    this.background,
    this.size = AppSizes.iconWell,
  });

  final IconData icon;
  final Color? color;
  final Color? background;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background ?? colors.surfaceMuted,
        borderRadius: AppShapes.input,
      ),
      child: Icon(
        icon,
        size: AppSizes.compactIcon,
        color: color ?? colors.accent,
      ),
    );
  }
}

/// A standard row for model, profile, permission, and other single choices.
///
/// Selection is communicated with a quiet fill and one radio/check signal,
/// rather than another bordered card.
class AppChoiceRow extends StatelessWidget {
  const AppChoiceRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.selected = false,
    this.enabled = true,
    this.selectedColor,
    this.selectedBackground,
    this.trailing,
    this.footer,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool enabled;
  final Color? selectedColor;
  final Color? selectedBackground;
  final Widget? trailing;
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final interactive = enabled && onTap != null;
    final activeSelectionColor = selectedColor ?? colors.accent;
    final titleColor = !interactive
        ? colors.textSecondary
        : selected && selectedColor != null
        ? activeSelectionColor
        : colors.textPrimary;
    final signalColor = selected ? activeSelectionColor : colors.textSecondary;
    return Semantics(
      button: true,
      enabled: interactive,
      selected: selected,
      child: Material(
        color: selected
            ? selectedBackground ?? colors.accentMuted
            : Colors.transparent,
        borderRadius: AppShapes.input,
        child: InkWell(
          onTap: interactive ? onTap : null,
          borderRadius: AppShapes.input,
          child: Padding(
            padding: AppPadding.listRow,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: AppSizes.iconWell,
                  height: AppSizes.iconWell,
                  child: Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : icon ?? Icons.radio_button_off_rounded,
                    size: AppSizes.icon,
                    color: interactive
                        ? signalColor
                        : signalColor.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(
                          context,
                        ).textTheme.titleSmall?.copyWith(color: titleColor),
                      ),
                      if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          subtitle!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.textSecondary,
                                height: 1.35,
                              ),
                        ),
                      ],
                      if (footer != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        footer!,
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact, flat section for inspector panes and narrow utility surfaces.
class AppListSection extends StatelessWidget {
  const AppListSection({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.dividerIndent = AppSizes.iconWell + AppSpacing.sm,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  subtitle!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (var index = 0; index < children.length; index++) ...[
          children[index],
          if (index != children.length - 1)
            Padding(
              padding: EdgeInsets.only(left: dividerIndent),
              child: Divider(height: 1, color: colors.border),
            ),
        ],
      ],
    );
  }
}
