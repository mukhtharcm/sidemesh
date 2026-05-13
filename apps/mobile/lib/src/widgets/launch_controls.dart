import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'mesh_widgets.dart';

/// Shared visual atoms used by launch-option surfaces (create-session,
/// new-session defaults in settings, per-session overrides).
///
/// These widgets used to live as private helpers inside
/// `screens/create_session_sheet.dart`. They were extracted so that
/// `LaunchOptionsForm` (and the simpler defaults sheet) can reuse the
/// exact same visual treatment, rather than each surface inventing its
/// own pills/cards/switches.

/// Bordered "icon · label · field" frame used for top-level inputs
/// (working directory, prompt, etc).
class LaunchFieldFrame extends StatelessWidget {
  const LaunchFieldFrame({
    super.key,
    required this.icon,
    required this.label,
    required this.child,
    this.alignTop = false,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Widget child;
  final bool alignTop;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: alignTop
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Padding(
            padding: EdgeInsets.only(top: alignTop ? 2 : 0),
            child: _IconChip(icon: icon, tone: _IconChipTone.surface),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CapsLabel(text: label),
                const SizedBox(height: 6),
                child,
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// One-line "open a chooser" row. Renders icon + label + value + optional
/// detail line + chevron, in the same frame as [LaunchFieldFrame] but
/// tappable.
class LaunchSelectorRow extends StatelessWidget {
  const LaunchSelectorRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.detail = '',
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: Row(
        children: [
          _IconChip(icon: icon, tone: _IconChipTone.accent),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CapsLabel(text: label),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: AppWeights.title,
                      ),
                ),
                if (detail.trim().isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      color: colors.textTertiary,
                      fontSize: 11,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.keyboard_arrow_down_rounded, color: colors.accent),
        ],
      ),
    );
  }
}

/// Outlined group container with an icon, title, optional trailing widget,
/// and a vertical stack of children.
class LaunchControlGroup extends StatelessWidget {
  const LaunchControlGroup({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshSurface(
      width: double.infinity,
      radius: AppRadii.control,
      padding: AppPadding.cardSm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.accent),
              const SizedBox(width: AppSpacing.sm),
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
      ),
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
            Icon(icon, size: 14, color: colors.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: AppWeights.emphasis,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: options.map((option) {
            final selected = option == value;
            final optionDanger = danger?.call(option) ?? false;
            final accent = optionDanger ? colors.danger : colors.accent;
            return InkWell(
              onTap: () => onChanged(option),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: AppPadding.pill,
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.14)
                      : colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: selected ? accent : colors.border),
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
                      const SizedBox(width: 5),
                      Text(
                        'default',
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: colors.textTertiary,
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
    final colors = context.colors;
    return MeshSurface(
      tone: value ? MeshSurfaceTone.surface : MeshSurfaceTone.muted,
      selected: value,
      radius: AppRadii.control,
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: value ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: AppWeights.title,
                        color: colors.textPrimary,
                      ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: 1.25,
                      ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: enabled ? onChanged : null),
        ],
      ),
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
        Icon(icon, size: 15, color: colors.textTertiary),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                  height: 1.3,
                ),
          ),
        ),
      ],
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.tone});

  final IconData icon;
  final _IconChipTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bg = switch (tone) {
      _IconChipTone.surface => colors.surface,
      _IconChipTone.accent => colors.accentMuted,
    };
    final border = switch (tone) {
      _IconChipTone.surface => colors.border,
      _IconChipTone.accent => colors.accent.withValues(alpha: 0.24),
    };
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: border),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: colors.accent, size: 17),
    );
  }
}

enum _IconChipTone { surface, accent }

class _CapsLabel extends StatelessWidget {
  const _CapsLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.textSecondary,
            fontWeight: AppWeights.title,
            letterSpacing: 0.4,
          ),
    );
  }
}
