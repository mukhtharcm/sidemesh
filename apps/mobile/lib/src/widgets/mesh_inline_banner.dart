import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// A compact inline banner for action confirmations and error feedback.
///
/// Replaces [AppSnackbar] for results that are contextually attached to the
/// thing you just acted on (e.g. "answer sent", "file saved", "declined").
/// Keep the global [AppSnackbar] queue only for host-level notifications.
///
/// Shows as a slim row:
///   [icon] [message]  [action?]  [×]
///
/// Auto-dismisses after [autoDismissDuration] if non-null.
class MeshInlineBanner extends StatefulWidget {
  const MeshInlineBanner({
    super.key,
    required this.visible,
    required this.message,
    this.tone = MeshInlineBannerTone.success,
    this.action,
    this.actionLabel,
    this.onDismiss,
    this.autoDismissDuration = const Duration(seconds: 4),
  });

  final bool visible;
  final String message;
  final MeshInlineBannerTone tone;

  /// Optional callback for an action button (e.g. "Undo", "View").
  final VoidCallback? action;
  final String? actionLabel;
  final VoidCallback? onDismiss;

  /// If non-null the banner auto-dismisses after this duration.
  final Duration? autoDismissDuration;

  @override
  State<MeshInlineBanner> createState() => _MeshInlineBannerState();
}

class _MeshInlineBannerState extends State<MeshInlineBanner> {
  @override
  void didUpdateWidget(MeshInlineBanner old) {
    super.didUpdateWidget(old);
    if (widget.visible && !old.visible && widget.autoDismissDuration != null) {
      _scheduleAutoDismiss();
    }
  }

  void _scheduleAutoDismiss() {
    Future.delayed(widget.autoDismissDuration!, () {
      if (mounted) widget.onDismiss?.call();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: widget.visible ? _body(context) : const SizedBox.shrink(),
    );
  }

  Widget _body(BuildContext context) {
    final colors = context.colors;
    final (bg, fg, icon) = switch (widget.tone) {
      MeshInlineBannerTone.success => (
          colors.successMuted,
          colors.success,
          Icons.check_circle_outline_rounded,
        ),
      MeshInlineBannerTone.error => (
          colors.dangerMuted,
          colors.danger,
          Icons.error_outline_rounded,
        ),
      MeshInlineBannerTone.info => (
          colors.infoMuted,
          colors.info,
          Icons.info_outline_rounded,
        ),
      MeshInlineBannerTone.warning => (
          colors.warningMuted,
          colors.warning,
          Icons.warning_amber_rounded,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppShapes.input,
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              widget.message,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: fg,
                    fontWeight: AppWeights.emphasis,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.action != null && widget.actionLabel != null) ...[
            const SizedBox(width: AppSpacing.sm),
            GestureDetector(
              onTap: widget.action,
              child: Text(
                widget.actionLabel!,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: fg,
                      fontWeight: AppWeights.title,
                      decoration: TextDecoration.underline,
                      decorationColor: fg,
                    ),
              ),
            ),
          ],
          if (widget.onDismiss != null) ...[
            const SizedBox(width: AppSpacing.xs),
            GestureDetector(
              onTap: widget.onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.close_rounded,
                  size: 13,
                  color: fg.withValues(alpha: 0.65),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum MeshInlineBannerTone { success, error, info, warning }
