import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'app_primitives.dart';

/// Shared visual atoms used by launch-option surfaces (create-session,
/// new-session defaults in settings, per-session overrides).
///
/// These widgets used to live as private helpers inside
/// `screens/create_session_sheet.dart`. They were extracted so that
/// `LaunchOptionsForm` (and the simpler defaults sheet) can reuse the
/// exact same visual treatment, rather than each surface inventing its
/// own pills/cards/switches.

/// Section heading with an optional trailing widget and a vertical stack of
/// controls. The section deliberately uses the page canvas instead of adding
/// another surface around controls that already have an edge.
class LaunchControlGroup extends StatelessWidget {
  const LaunchControlGroup({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: AppWeights.title,
                  color: colors.textPrimary,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ...children,
      ],
    );
  }
}

/// Wrap of choice chips. Selected option is filled with the accent (or
/// danger) tone; "default" options are subtly annotated.
class LaunchChoiceWrap<T> extends StatelessWidget {
  const LaunchChoiceWrap({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.optionLabel,
    required this.onChanged,
    this.isDefault,
    this.danger,
  });

  final IconData icon;
  final String label;
  final T? value;
  final List<T> options;
  final String Function(T) optionLabel;
  final bool Function(T)? isDefault;
  final bool Function(T)? danger;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: AppSizes.smallIcon, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.tight),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.textSecondary,
                fontWeight: AppWeights.emphasis,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: options.map((option) {
            final selected = option == value;
            final optionDanger = danger?.call(option) ?? false;
            final accent = optionDanger ? colors.danger : colors.accent;
            return InkWell(
              onTap: () => onChanged(option),
              borderRadius: BorderRadius.circular(AppRadii.capsule),
              child: Container(
                padding: AppPadding.pill,
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: AppEmphasis.tint)
                      : colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(AppRadii.capsule),
                  border: selected ? Border.all(color: accent) : null,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      optionLabel(option),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? accent : colors.textSecondary,
                        fontWeight: AppWeights.emphasis,
                      ),
                    ),
                    if (isDefault?.call(option) ?? false) ...[
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        'Default',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.textSecondary,
                          fontWeight: AppWeights.emphasis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// Compact toggle row with title + subtitle and a trailing [Switch].
class LaunchSwitchRow extends StatelessWidget {
  const LaunchSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return AppSettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
  }
}

/// Subtle informational line shown below a control group.
class LaunchInfoLine extends StatelessWidget {
  const LaunchInfoLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: AppSizes.compactIcon, color: colors.textTertiary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: AppLineHeights.label,
            ),
          ),
        ),
      ],
    );
  }
}
