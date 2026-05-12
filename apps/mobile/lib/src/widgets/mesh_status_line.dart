import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'mesh_widgets.dart';

/// A compact status bar that replaces the Material [AppBar] + subtitle row
/// pattern across session, host, file, and terminal screens.
///
/// Renders as a single row with:
///   [dot] [segments…] [trailing]
///
/// - [segments] are monospace for identifiers (host names, IDs, paths) and
///   regular-weight for labels. They are separated by a `·` glyph.
/// - [live] controls whether a [LivePulse] dot appears at the leading edge.
/// - Long-press anywhere on the bar calls [onLongPress] — the canonical
///   command-palette trigger.
/// - [actions] render as small icons at the trailing edge (max 2–3; anything
///   more belongs in the command palette).
class MeshStatusLine extends StatelessWidget {
  const MeshStatusLine({
    super.key,
    required this.segments,
    this.live = false,
    this.liveColor,
    this.trailing,
    this.actions = const [],
    this.onLongPress,
    this.backgroundColor,
  });

  final List<MeshStatusSegment> segments;
  final bool live;
  final Color? liveColor;
  final Widget? trailing;
  final List<Widget> actions;
  final VoidCallback? onLongPress;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bg = backgroundColor ?? colors.canvas;

    return GestureDetector(
      onLongPress: () {
        HapticFeedback.lightImpact();
        onLongPress?.call();
      },
      child: Container(
        height: 36,
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Row(
          children: [
            if (live) ...[
              LivePulse(color: liveColor ?? colors.success),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(
              child: _SegmentsRow(segments: segments, colors: colors),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.xs),
              ...actions,
            ],
          ],
        ),
      ),
    );
  }
}

class _SegmentsRow extends StatelessWidget {
  const _SegmentsRow({required this.segments, required this.colors});

  final List<MeshStatusSegment> segments;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    if (segments.isEmpty) return const SizedBox.shrink();
    final List<InlineSpan> spans = [];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      spans.add(
        TextSpan(
          text: seg.text,
          style: seg.mono
              ? monoStyle(
                  color: seg.color ?? colors.textSecondary,
                  fontSize: 11.5,
                  fontWeight: AppWeights.emphasis,
                )
              : TextStyle(
                  color: seg.color ?? colors.textSecondary,
                  fontSize: 12,
                  fontWeight: AppWeights.emphasis,
                  letterSpacing: AppLetterSpacing.body,
                ),
        ),
      );
      if (i < segments.length - 1) {
        spans.add(
          TextSpan(
            text: '  ·  ',
            style: TextStyle(
              color: colors.textTertiary,
              fontSize: 11,
              fontWeight: AppWeights.body,
            ),
          ),
        );
      }
    }
    return RichText(
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      text: TextSpan(children: spans),
    );
  }
}

/// A single segment in a [MeshStatusLine].
///
/// [mono] = true for identifiers (host name, session ID, branch, path).
/// [mono] = false for human-readable labels (state names, counts).
class MeshStatusSegment {
  const MeshStatusSegment(
    this.text, {
    this.mono = false,
    this.color,
  });

  final String text;
  final bool mono;
  final Color? color;
}
