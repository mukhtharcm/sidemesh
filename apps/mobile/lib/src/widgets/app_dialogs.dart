import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
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
    this.maxWidth = 440,
    this.danger = false,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
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
  final EdgeInsetsGeometry padding;
  final bool showCloseButton;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final accent = danger ? colors.danger : colors.accent;
    final muted = danger ? colors.dangerMuted : colors.accentMuted;
    final iconForeground = readableSemanticForeground(
      colors,
      background: muted,
      preferred: accent,
    );
    final narrowScreen = MediaQuery.sizeOf(context).width < 420;
    return Dialog(
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrowScreen ? AppSpacing.lg : AppSpacing.xxl,
        vertical: AppSpacing.xl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceElevated,
            borderRadius: AppShapes.dialog,
            border: Border.all(color: colors.border),
            boxShadow: AppShadows.dialog(colors.textPrimary),
          ),
          child: ClipRRect(
            borderRadius: AppShapes.dialog,
            child: Padding(
              padding: padding,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compactActions = constraints.maxWidth < 380;
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: muted,
                              borderRadius: AppShapes.iconWell,
                              border: Border.all(
                                color: accent.withValues(
                                  alpha: AppEmphasis.borderTint,
                                ),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              icon,
                              size: AppSizes.inlineIcon,
                              color: iconForeground,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: colors.textPrimary,
                                        fontWeight: AppWeights.title,
                                        letterSpacing:
                                            AppLetterSpacing.headline,
                                      ),
                                ),
                                if (description != null) ...[
                                  const SizedBox(height: AppSpacing.xs),
                                  Text(
                                    description!,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: colors.textSecondary,
                                          height: 1.38,
                                        ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (showCloseButton) ...[
                            const SizedBox(width: AppSpacing.sm),
                            IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                size: AppSizes.inlineIcon,
                              ),
                              tooltip: 'Close',
                              visualDensity: VisualDensity.compact,
                              onPressed:
                                  onClose ??
                                  () => Navigator.of(context).maybePop(),
                            ),
                          ],
                        ],
                      ),
                      if (child != null) ...[
                        const SizedBox(height: AppSpacing.lg),
                        child!,
                      ],
                      if (actions.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.lg),
                        if (compactActions)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final action in actions.reversed) ...[
                                SizedBox(width: double.infinity, child: action),
                                if (action != actions.first)
                                  const SizedBox(height: AppSpacing.sm),
                              ],
                            ],
                          )
                        else
                          Align(
                            alignment: Alignment.centerRight,
                            child: Wrap(
                              spacing: AppSpacing.sm,
                              runSpacing: AppSpacing.sm,
                              alignment: WrapAlignment.end,
                              children: actions,
                            ),
                          ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
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
  double maxWidth = 440,
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
