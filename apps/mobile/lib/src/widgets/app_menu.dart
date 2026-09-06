import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../theme/app_control_styles.dart';

const appActionMenuWidth = AppSizes.actionMenuWidth;
const appActionMenuStyle = AppControlStyles.actionMenu;

/// A compact menu row using the app's shared type, spacing, and selection
/// vocabulary. Selection is shown with one quiet trailing checkmark rather
/// than embedding a full-size form control inside the menu.
class AppMenuItem extends StatelessWidget {
  const AppMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.selected,
    this.foregroundColor,
    this.mutuallyExclusive = false,
    this.closeOnActivate = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? leadingIcon;
  final bool? selected;
  final Color? foregroundColor;
  final bool mutuallyExclusive;
  final bool closeOnActivate;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selectionIcon = selected == null
        ? null
        : SizedBox(
            width: AppSizes.icon,
            child: selected == true
                ? Icon(
                    Icons.check_rounded,
                    size: AppSizes.compactIcon,
                    color: colors.accent,
                  )
                : null,
          );

    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        checked: selected,
        inMutuallyExclusiveGroup: selected == null ? false : mutuallyExclusive,
        child: MenuItemButton(
          style: AppControlStyles.menuItem(foregroundColor),
          closeOnActivate: closeOnActivate,
          leadingIcon: leadingIcon == null
              ? null
              : Icon(leadingIcon, size: AppSizes.compactIcon),
          trailingIcon: selectionIcon,
          onPressed: onPressed,
          child: Text(label),
        ),
      ),
    );
  }
}

/// Low-emphasis label separating related choices inside an app menu.
class AppMenuSectionLabel extends StatelessWidget {
  const AppMenuSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: context.colors.textTertiary,
          fontWeight: AppWeights.emphasis,
        ),
      ),
    );
  }
}

/// Shared trigger for desktop tool and action menus.
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.tooltip,
    required this.children,
    this.icon = Icons.more_horiz_rounded,
  });
  final String tooltip;
  final List<Widget> children;
  final IconData icon;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    style: appActionMenuStyle,
    crossAxisUnconstrained: false,
    alignmentOffset: const Offset(-appActionMenuWidth, 4),
    menuChildren: children,
    builder: (context, controller, _) => IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: AppSizes.inlineIcon),
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}

/// A value selector with the same menu and selection states as action menus.
class AppSelect<T> extends StatelessWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.values,
    required this.label,
    required this.onChanged,
    this.hint = 'Select',
    this.expanded = false,
  });
  final T? value;
  final List<T> values;
  final String Function(T) label;
  final ValueChanged<T>? onChanged;
  final String hint;
  final bool expanded;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final option in values)
        AppMenuItem(
          label: label(option),
          selected: value == option,
          onPressed: onChanged == null ? null : () => onChanged!(option),
        ),
    ],
    builder: (context, controller, _) => TextButton(
      style: AppControlStyles.select(context),
      onPressed: onChanged == null
          ? null
          : () => controller.isOpen ? controller.close() : controller.open(),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              value == null ? hint : label(value as T),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.expand_more_rounded, size: AppSizes.compactIcon),
        ],
      ),
    ),
  );
}
