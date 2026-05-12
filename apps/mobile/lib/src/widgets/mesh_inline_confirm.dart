import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// An inline confirmation widget that replaces [AlertDialog] for
/// save/delete/reset confirmations.
///
/// Shows a compact danger banner with:
///   [icon] [title] · [subtitle]       [confirm button]  [cancel ×]
///
/// No modal, no dialog, no blocking overlay. Slot this inline wherever the
/// action originates. The caller controls visibility via [visible].
///
/// Example usage (file save discard):
/// ```dart
/// MeshInlineConfirm(
///   visible: _showDiscard,
///   title: 'Discard changes?',
///   confirmLabel: 'Discard',
///   onConfirm: _discardEdits,
///   onCancel: () => setState(() => _showDiscard = false),
///   tone: MeshInlineConfirmTone.danger,
/// )
/// ```
class MeshInlineConfirm extends StatelessWidget {
  const MeshInlineConfirm({
    super.key,
    required this.visible,
    required this.title,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onCancel,
    this.subtitle,
    this.tone = MeshInlineConfirmTone.danger,
    this.loading = false,
  });

  final bool visible;
  final String title;
  final String? subtitle;
  final String confirmLabel;
  final VoidCallback? onConfirm;
  final VoidCallback? onCancel;
  final MeshInlineConfirmTone tone;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: visible ? _body(context) : const SizedBox.shrink(),
    );
  }

  Widget _body(BuildContext context) {
    final colors = context.colors;
    final (bg, fg, border, icon) = switch (tone) {
      MeshInlineConfirmTone.danger => (
          colors.dangerMuted,
          colors.danger,
          colors.danger.withValues(alpha: 0.35),
          Icons.warning_amber_rounded,
        ),
      MeshInlineConfirmTone.warning => (
          colors.warningMuted,
          colors.warning,
          colors.warning.withValues(alpha: 0.35),
          Icons.info_outline_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppShapes.input,
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: fg,
                        fontWeight: AppWeights.emphasis,
                      ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: fg.withValues(alpha: 0.75),
                        ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          TextButton(
            onPressed: loading ? null : onConfirm,
            style: TextButton.styleFrom(
              foregroundColor: fg,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(fontWeight: AppWeights.title),
            ),
            child: loading
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: fg),
                  )
                : Text(confirmLabel),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onCancel,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 15,
                color: fg.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum MeshInlineConfirmTone { danger, warning }
