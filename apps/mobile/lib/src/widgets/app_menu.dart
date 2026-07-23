import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

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
    this.mutuallyExclusive = false,
    this.closeOnActivate = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? leadingIcon;
  final bool? selected;
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
        inMutuallyExclusiveGroup: selected == null
            ? false
            : mutuallyExclusive,
        child: MenuItemButton(
          closeOnActivate: closeOnActivate,
          leadingIcon: leadingIcon == null
              ? null
              : Icon(leadingIcon, size: AppSizes.icon),
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
