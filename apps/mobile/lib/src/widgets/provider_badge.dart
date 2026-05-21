import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hugeicons/hugeicons.dart';

import '../models.dart';
import '../provider_labels.dart';
import '../theme/app_colors.dart';

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
          _providerIcon(providerKind, iconSize, fg),
          SizedBox(width: compact ? 4 : 5),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 92 : 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: fg,
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Provider icon resolver
// ---------------------------------------------------------------------------

/// Returns the appropriate brand icon for a given [providerKind].
///
/// Known providers use SVG brand assets from [assets/icons/brands/] so they
/// are rendered with a precise, colourable shape.  Unknown or test providers
/// fall back to matching [HugeIcons] glyphs.
Widget _providerIcon(String? providerKind, double size, Color color) {
  Widget svg(String name) => SvgPicture.asset(
    'assets/icons/brands/$name.svg',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  );

  Widget huge(List<List<dynamic>> icon) =>
      HugeIcon(icon: icon, size: size, color: color);

  return switch ((providerKind ?? '').toLowerCase()) {
    // OpenAI / Codex
    'codex' => svg('openai'),
    // GitHub Copilot
    'copilot' => svg('githubcopilot'),
    // Anthropic products (claude, etc.)
    'anthropic' || 'claude' => svg('anthropic'),
    // Pi (Inflection AI assistant)
    'pi' => huge(HugeIcons.strokeRoundedAiBrain01),
    // Hugging Face hosted models
    'huggingface' || 'hf' => svg('huggingface'),
    // Deterministic test harness
    'fake' => huge(HugeIcons.strokeRoundedTestTube01),
    // Generic fallback
    _ => huge(HugeIcons.strokeRoundedRobot01),
  };
}
