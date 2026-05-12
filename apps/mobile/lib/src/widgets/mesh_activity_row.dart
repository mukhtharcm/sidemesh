import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// A single-line, tap-to-expand activity/event row for the session timeline.
///
/// Default (collapsed) renders as:
///   [icon] [title] [monospace target?] ·· [status dot] [timestamp]
///
/// Tapping expands an inline [expandedBody] beneath the header row. The
/// expansion is animated with [AnimatedSize].
///
/// This replaces the heavy `MeshCard`-wrapped activity cards that were used
/// for tool calls, shell commands, and file patches in the session timeline.
class MeshActivityRow extends StatefulWidget {
  const MeshActivityRow({
    super.key,
    required this.icon,
    required this.title,
    this.target,
    this.status = MeshActivityStatus.running,
    this.timestamp,
    this.expandedBody,
    this.initiallyExpanded = false,
    this.trailing,
    this.footer,
  });

  /// Icon to show at the leading edge. Typically 16px.
  final IconData icon;

  /// Short human-readable title (e.g. "Write file", "Run shell").
  final String title;

  /// Optional monospace identifier: file path, command, URL.
  final String? target;

  final MeshActivityStatus status;
  final String? timestamp;

  /// Widget revealed when the row is expanded. If null the row is not
  /// tappable and always shows collapsed.
  final Widget? expandedBody;

  final bool initiallyExpanded;

  /// Optional widget at the far right of the header row (e.g. diff stats).
  final Widget? trailing;

  /// Optional widget shown below the header at all times (e.g. approval
  /// action row). Unlike [expandedBody] this is always visible.
  final Widget? footer;

  @override
  State<MeshActivityRow> createState() => _MeshActivityRowState();
}

class _MeshActivityRowState extends State<MeshActivityRow> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  void _toggle() {
    if (widget.expandedBody == null) return;
    HapticFeedback.selectionClick();
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isExpandable = widget.expandedBody != null;

    return GestureDetector(
      onTap: _toggle,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Header row ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                _StatusIcon(status: widget.status, icon: widget.icon, colors: colors),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              color: colors.textSecondary,
                              fontWeight: AppWeights.emphasis,
                            ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                      if (widget.target != null) ...[
                        const SizedBox(width: AppSpacing.xs),
                        Flexible(
                          child: Text(
                            widget.target!,
                            style: monoStyle(
                              color: colors.textTertiary,
                              fontSize: 11,
                              fontWeight: AppWeights.body,
                            ).copyWith(overflow: TextOverflow.ellipsis),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  widget.trailing!,
                ],
                if (widget.timestamp != null) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    widget.timestamp!,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.textTertiary,
                        ),
                  ),
                ],
                if (isExpandable) ...[
                  const SizedBox(width: AppSpacing.xs),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.expand_more_rounded,
                      size: 15,
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // ── Expanded body ────────────────────────────────────────────────
          if (widget.expandedBody != null)
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.only(
                        left: AppSpacing.lg + AppSpacing.sm,
                        bottom: AppSpacing.sm,
                      ),
                      child: widget.expandedBody,
                    )
                  : const SizedBox.shrink(),
            ),
          // ── Always-visible footer (e.g. approval actions) ───────────────
          if (widget.footer != null)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.lg + AppSpacing.sm,
                bottom: AppSpacing.sm,
              ),
              child: widget.footer,
            ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({
    required this.status,
    required this.icon,
    required this.colors,
  });

  final MeshActivityStatus status;
  final IconData icon;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      MeshActivityStatus.running => SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: colors.accent,
          ),
        ),
      MeshActivityStatus.success => Icon(
          Icons.check_rounded,
          size: 14,
          color: colors.success,
        ),
      MeshActivityStatus.error => Icon(
          Icons.close_rounded,
          size: 14,
          color: colors.danger,
        ),
      MeshActivityStatus.waiting => Icon(
          Icons.hourglass_empty_rounded,
          size: 14,
          color: colors.warning,
        ),
      MeshActivityStatus.skipped => Icon(
          Icons.remove_rounded,
          size: 14,
          color: colors.textTertiary,
        ),
      MeshActivityStatus.neutral => Icon(
          icon,
          size: 14,
          color: colors.textSecondary,
        ),
    };
  }
}

enum MeshActivityStatus { running, success, error, waiting, skipped, neutral }
