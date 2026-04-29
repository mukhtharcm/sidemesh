import 'package:flutter/material.dart';

import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

String? agentProviderDisplayLabel(String? providerKind, {NodeInfo? nodeInfo}) {
  final kind = (providerKind ?? '').trim();
  if (kind.isEmpty) {
    return null;
  }

  final summary = nodeInfo?.providerSummary(kind);
  if (summary != null && summary.displayName.trim().isNotEmpty) {
    return summary.displayName.trim();
  }
  if (nodeInfo != null && kind == nodeInfo.provider) {
    return nodeInfo.providerDisplayName;
  }

  return switch (kind) {
    'codex' => 'Codex',
    'copilot' => 'GitHub Copilot',
    'fake' => 'Fake',
    _ => _titleCaseProviderKind(kind),
  };
}

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
    final fg = colors.info;
    final bg = colors.infoMuted;
    final border = colors.info.withValues(alpha: 0.38);
    final fontSize = compact ? 10.5 : 11.5;
    final iconSize = compact ? 11.0 : 13.0;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 7 : 8,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_rounded, size: iconSize, color: fg),
          SizedBox(width: compact ? 4 : 5),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 92 : 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                color: fg,
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
              ).copyWith(letterSpacing: 0.2),
            ),
          ),
        ],
      ),
    );
  }
}

String _titleCaseProviderKind(String kind) {
  final words = kind
      .split(RegExp(r'[-_\s]+'))
      .where((word) => word.trim().isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) {
    return kind;
  }
  return words
      .map((word) {
        if (word.length == 1) {
          return word.toUpperCase();
        }
        return '${word[0].toUpperCase()}${word.substring(1)}';
      })
      .join(' ');
}
