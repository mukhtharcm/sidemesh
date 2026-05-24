import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
/// are rendered with precise first-party marks. Unknown or test providers fall
/// back to small Material glyphs so we avoid carrying a separate icon package
/// just for a few non-brand cases.
Widget _providerIcon(String? providerKind, double size, Color color) {
  final spec = _providerIconSpec(providerKind);
  if (spec.assetName case final assetName?) {
    return SvgPicture.asset(
      'assets/icons/brands/$assetName.svg',
      width: size,
      height: size,
      colorFilter:
          spec.preserveOriginalColors
              ? null
              : ColorFilter.mode(color, BlendMode.srcIn),
    );
  }

  return Icon(spec.icon, size: size, color: color);
}

_ProviderIconSpec _providerIconSpec(String? providerKind) {
  return switch ((providerKind ?? '').toLowerCase()) {
    // OpenAI does not currently publish a distinct compact Codex badge, so use
    // a neutral product glyph instead of reusing the parent-company mark.
    'codex' => const _ProviderIconSpec.icon(Icons.terminal_rounded),
    'copilot' => const _ProviderIconSpec.svg('githubcopilot'),
    'anthropic' => const _ProviderIconSpec.svg('anthropic'),
    'claude' => const _ProviderIconSpec.svg(
      'claude',
      preserveOriginalColors: true,
    ),
    'pi' => const _ProviderIconSpec.svg('pi', preserveOriginalColors: true),
    'huggingface' || 'hf' => const _ProviderIconSpec.svg('huggingface'),
    'opencode' => const _ProviderIconSpec.icon(Icons.code_rounded),
    'acpx' => const _ProviderIconSpec.svg('acp'),
    'fake' => const _ProviderIconSpec.icon(Icons.science_rounded),
    _ => const _ProviderIconSpec.icon(Icons.smart_toy_rounded),
  };
}

final class _ProviderIconSpec {
  const _ProviderIconSpec._({
    this.assetName,
    this.icon,
    this.preserveOriginalColors = false,
  });

  const _ProviderIconSpec.svg(
    String assetName, {
    bool preserveOriginalColors = false,
  }) : this._(
         assetName: assetName,
         preserveOriginalColors: preserveOriginalColors,
       );

  const _ProviderIconSpec.icon(IconData icon) : this._(icon: icon);

  final String? assetName;
  final IconData? icon;
  final bool preserveOriginalColors;
}
