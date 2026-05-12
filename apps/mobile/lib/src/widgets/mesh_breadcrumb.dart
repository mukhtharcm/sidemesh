import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// Tappable breadcrumb trail used in file, host, and session path contexts.
///
/// Renders as a horizontal scrollable row of segments separated by `›`:
///   root  ›  src  ›  widgets  ›  mesh_widgets.dart
///
/// The last segment is rendered in [textPrimary]; earlier segments in
/// [textTertiary] and are tappable if their [onTap] callback is non-null.
class MeshBreadcrumb extends StatelessWidget {
  const MeshBreadcrumb({
    super.key,
    required this.segments,
    this.scrollController,
  });

  final List<MeshBreadcrumbSegment> segments;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (segments.isEmpty) return const SizedBox.shrink();

    final List<Widget> children = [];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final isLast = i == segments.length - 1;

      children.add(
        _BreadcrumbChunk(
          segment: seg,
          isLast: isLast,
          colors: colors,
        ),
      );

      if (!isLast) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '›',
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 11,
                fontWeight: AppWeights.body,
              ),
            ),
          ),
        );
      }
    }

    return SingleChildScrollView(
      controller: scrollController,
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }
}

class _BreadcrumbChunk extends StatelessWidget {
  const _BreadcrumbChunk({
    required this.segment,
    required this.isLast,
    required this.colors,
  });

  final MeshBreadcrumbSegment segment;
  final bool isLast;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final color = isLast ? colors.textPrimary : colors.textTertiary;
    final weight = isLast ? AppWeights.emphasis : AppWeights.body;

    final text = Text(
      segment.label,
      style: TextStyle(
        color: color,
        fontSize: 12,
        fontWeight: weight,
        letterSpacing: AppLetterSpacing.body,
      ),
    );

    if (segment.onTap == null) return text;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        segment.onTap!();
      },
      child: text,
    );
  }
}

/// A single segment in a [MeshBreadcrumb].
class MeshBreadcrumbSegment {
  const MeshBreadcrumbSegment({
    required this.label,
    this.onTap,
  });

  final String label;
  final VoidCallback? onTap;
}
