import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../theme/app_control_styles.dart';

class MeshDialogScaffold extends StatelessWidget {
  const MeshDialogScaffold({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.child,
    this.actions = const <Widget>[],
    this.maxWidth = AppSizes.confirmDialogWidth,
    this.danger = false,
    this.showCloseButton = false,
    this.onClose,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? child;
  final List<Widget> actions;
  final double maxWidth;
  final bool danger;
  final bool showCloseButton;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      constraints: BoxConstraints(maxWidth: maxWidth),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xl,
      ),
      titlePadding: const EdgeInsets.all(AppSpacing.lg),
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      actionsOverflowButtonSpacing: AppSpacing.sm,
      scrollable: true,
      title: Row(
        children: [
          Icon(
            icon,
            size: AppSizes.icon,
            color: danger ? colors.danger : colors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(title)),
          if (showCloseButton)
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Close',
              onPressed: onClose ?? () => Navigator.of(context).maybePop(),
            ),
        ],
      ),
      content: description == null && child == null
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (description != null) Text(description!),
                if (description != null && child != null)
                  const SizedBox(height: AppSpacing.md),
                ?child,
              ],
            ),
      actions: actions,
    );
  }
}

Future<bool> showMeshConfirmDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String description,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  bool danger = false,
  Widget? child,
  double maxWidth = AppSizes.confirmDialogWidth,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final colors = dialogContext.colors;
      return MeshDialogScaffold(
        icon: icon,
        title: title,
        description: description,
        danger: danger,
        maxWidth: maxWidth,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: danger ? AppControlStyles.confirmDanger(colors) : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
        child: child,
      );
    },
  );
  return confirmed == true;
}
