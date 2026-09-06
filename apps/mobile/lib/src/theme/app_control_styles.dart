import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_tokens.dart';
import 'color_contrast.dart';

/// Variants that cannot be expressed by the default Material component theme.
abstract final class AppControlStyles {
  static ButtonStyle foreground(Color color) =>
      TextButton.styleFrom(foregroundColor: color);

  static ButtonStyle danger(AppColors colors) => OutlinedButton.styleFrom(
    foregroundColor: colors.danger,
    side: BorderSide(color: colors.danger.withValues(alpha: AppEmphasis.muted)),
  );

  static ButtonStyle confirmDanger(AppColors colors) => FilledButton.styleFrom(
    backgroundColor: colors.danger,
    foregroundColor: readableActionForeground(colors, colors.danger),
  );

  static ButtonStyle review({
    required Color background,
    required Color foreground,
    required Color border,
  }) => FilledButton.styleFrom(
    backgroundColor: background,
    foregroundColor: foreground,
    side: BorderSide(color: border),
  );

  static ButtonStyle sheetIcon(AppColors colors) => IconButton.styleFrom(
    backgroundColor: colors.surfaceElevated,
    foregroundColor: colors.textPrimary,
    minimumSize: const Size.square(AppSizes.menuItem),
    shape: const CircleBorder(),
  );

  static ButtonStyle select(BuildContext context) => TextButton.styleFrom(
    textStyle: Theme.of(context).textTheme.bodyMedium,
    foregroundColor: context.colors.textPrimary,
    alignment: Alignment.centerLeft,
  );

  static ButtonStyle menuItem(Color? foreground) => ButtonStyle(
    foregroundColor: foreground == null
        ? null
        : WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.disabled) ? null : foreground,
          ),
    iconColor: foreground == null
        ? null
        : WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.disabled) ? null : foreground,
          ),
  );

  static const actionMenu = MenuStyle(
    visualDensity: VisualDensity.standard,
    alignment: AlignmentDirectional.bottomEnd,
    fixedSize: WidgetStatePropertyAll(
      Size(AppSizes.actionMenuWidth, double.infinity),
    ),
  );

  static TextStyle? searchText(BuildContext context) {
    final theme = Theme.of(context);
    return AppSizes.usesPointerControls(theme.platform)
        ? theme.textTheme.bodyMedium?.copyWith(
            fontSize: AppFontSizes.compact,
            height: AppLineHeights.tight,
          )
        : theme.textTheme.bodyLarge;
  }

  static InputDecoration search(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.capsule),
      borderSide: BorderSide(color: colors.borderStrong),
    );
    final pointer = AppSizes.usesPointerControls(theme.platform);
    return InputDecoration(
      isDense: pointer,
      constraints: BoxConstraints(
        minHeight: pointer ? AppSizes.compactControl : AppSizes.control,
      ),
      prefixIconConstraints: pointer
          ? const BoxConstraints(
              minWidth: AppSizes.compactControl,
              minHeight: AppSizes.compactControl,
            )
          : null,
      suffixIconConstraints: pointer
          ? const BoxConstraints(
              minWidth: AppSizes.compactControl,
              minHeight: AppSizes.compactControl,
            )
          : null,
      hintStyle: searchText(
        context,
      )?.copyWith(color: theme.inputDecorationTheme.hintStyle?.color),
      filled: true,
      fillColor: colors.surfaceElevated,
      border: border,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: pointer
          ? border.copyWith(
              borderSide: theme.inputDecorationTheme.focusedBorder?.borderSide,
            )
          : border,
      errorBorder: border.copyWith(
        borderSide: theme.inputDecorationTheme.errorBorder?.borderSide,
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: theme.inputDecorationTheme.focusedErrorBorder?.borderSide,
      ),
      prefixIcon: Icon(
        Icons.search_rounded,
        size: pointer ? AppSizes.compactIcon : AppSizes.icon,
      ),
      contentPadding: EdgeInsets.symmetric(
        horizontal: pointer ? AppSpacing.md : AppSpacing.lg,
        vertical: pointer ? AppSpacing.xs : AppSpacing.md,
      ),
    );
  }
}
