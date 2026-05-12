import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// A full-width, single-tap option row for question-tool choices and approval
/// actions.
///
/// Each row shows:
///   [leading glyph] [title]  [trailing indicator]
///
/// States:
/// - [MeshOptionState.idle]       — neutral background, tappable.
/// - [MeshOptionState.selected]   — leading glyph turns [accent], subtle tint.
/// - [MeshOptionState.submitting] — mini spinner replaces the leading glyph.
/// - [MeshOptionState.confirmed]  — check icon in [success] color.
/// - [MeshOptionState.error]      — retry icon in [danger] color.
///
/// Used by:
/// - `_QuestionBlock` in `session_screen_timeline.dart` for user_input choices.
/// - `_ApprovalFooter` in `session_screen_timeline.dart` for approve/decline.
class MeshOptionRow extends StatefulWidget {
  const MeshOptionRow({
    super.key,
    required this.label,
    required this.state,
    required this.onTap,
    this.leading,
    this.sublabel,
    this.isPrimary = false,
    this.isDanger = false,
  });

  final String label;
  final MeshOptionState state;
  final VoidCallback? onTap;

  /// Leading widget. If null, no leading is shown.
  final Widget? leading;

  /// Optional second line below [label].
  final String? sublabel;

  /// When true, the label is rendered with accent weight (primary action).
  final bool isPrimary;

  /// When true, the label and leading indicator are danger-tinted.
  final bool isDanger;

  @override
  State<MeshOptionRow> createState() => _MeshOptionRowState();
}

class _MeshOptionRowState extends State<MeshOptionRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
    );
    _scale = Tween<double>(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTapDown(_) => _controller.forward();
  void _onTapUp(_) => _controller.reverse();
  void _onTapCancel() => _controller.reverse();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final state = widget.state;
    final isInteractive = state == MeshOptionState.idle && widget.onTap != null;
    final isActive = state == MeshOptionState.selected ||
        state == MeshOptionState.confirmed;

    final bg = switch (state) {
      MeshOptionState.selected => widget.isDanger
          ? colors.dangerMuted
          : colors.accentMuted,
      MeshOptionState.confirmed => colors.successMuted,
      MeshOptionState.error => colors.dangerMuted,
      _ => Colors.transparent,
    };

    final labelColor = switch (state) {
      MeshOptionState.selected || MeshOptionState.submitting =>
        widget.isDanger ? colors.danger : colors.accent,
      MeshOptionState.confirmed => colors.success,
      MeshOptionState.error => colors.danger,
      _ => widget.isDanger
          ? colors.danger
          : widget.isPrimary
              ? colors.textPrimary
              : colors.textSecondary,
    };

    Widget leadingWidget = _buildLeadingIndicator(colors, state);

    return GestureDetector(
      onTapDown: isInteractive ? _onTapDown : null,
      onTapUp: isInteractive ? _onTapUp : null,
      onTapCancel: isInteractive ? _onTapCancel : null,
      onTap: isInteractive
          ? () {
              HapticFeedback.selectionClick();
              widget.onTap?.call();
            }
          : null,
      child: ScaleTransition(
        scale: _scale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: AppShapes.input,
          ),
          child: Row(
            children: [
              leadingWidget,
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 150),
                      style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                            color: labelColor,
                            fontWeight: (widget.isPrimary || isActive)
                                ? AppWeights.emphasis
                                : AppWeights.body,
                          ),
                      child: Text(widget.label),
                    ),
                    if (widget.sublabel != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.sublabel!,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colors.textTertiary,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeadingIndicator(AppColors colors, MeshOptionState state) {
    if (widget.leading != null && state == MeshOptionState.idle) {
      return widget.leading!;
    }
    return switch (state) {
      MeshOptionState.submitting => SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: widget.isDanger ? colors.danger : colors.accent,
          ),
        ),
      MeshOptionState.confirmed => Icon(
          Icons.check_rounded,
          size: 16,
          color: colors.success,
        ),
      MeshOptionState.error => Icon(
          Icons.refresh_rounded,
          size: 16,
          color: colors.danger,
        ),
      MeshOptionState.selected => Icon(
          Icons.check_rounded,
          size: 16,
          color: widget.isDanger ? colors.danger : colors.accent,
        ),
      _ => widget.leading ??
          const SizedBox(width: 16, height: 16),
    };
  }
}

enum MeshOptionState {
  idle,
  selected,
  submitting,
  confirmed,
  error,
}
