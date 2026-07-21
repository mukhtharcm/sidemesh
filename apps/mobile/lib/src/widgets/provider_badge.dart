import 'package:flutter/material.dart';

import '../models.dart';
import '../provider_labels.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

class AgentProviderBadge extends StatelessWidget {
  const AgentProviderBadge({
    super.key,
    required this.providerKind,
    this.nodeInfo,
    this.compact = false,
  });

  final String? providerKind;
  final NodeInfo? nodeInfo;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = agentProviderDisplayLabel(providerKind, nodeInfo: nodeInfo);
    if (label == null) {
      return const SizedBox.shrink();
    }

    final colors = context.colors;
    final fg = colors.textSecondary;
    final bg = colors.surfaceMuted;
    final border = colors.borderStrong.withValues(alpha: 0.68);
    final fontSize = compact ? 10.5 : 11.2;
    final iconSize = compact ? 11.0 : 12.0;

    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_rounded, size: iconSize, color: fg),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 92),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fg,
                fontSize: fontSize,
                fontWeight: AppWeights.emphasis,
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: AppShapes.badge,
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_rounded, size: iconSize, color: fg),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fg,
                fontSize: fontSize,
                fontWeight: AppWeights.emphasis,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
