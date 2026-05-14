import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'mesh_widgets.dart';

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
    this.padding = const EdgeInsets.all(18),
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? child;
  final List<Widget> actions;
  final double maxWidth;
  final bool danger;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final accent = danger ? colors.danger : colors.accent;
    final muted = danger ? colors.dangerMuted : colors.accentMuted;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: MeshCard(
          tone: MeshCardTone.surface,
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: muted,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withValues(alpha: 0.24)),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 20, color: accent),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: AppWeights.title),
              ),
              if (description != null) ...[
                const SizedBox(height: 6),
                Text(
                  description!,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
              if (child != null) ...[const SizedBox(height: 16), child!],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 18),
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
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: colors.danger,
                    foregroundColor: colors.accentOn,
                  )
                : null,
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
