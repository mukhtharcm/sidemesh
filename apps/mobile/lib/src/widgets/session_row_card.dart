import 'package:flutter/material.dart';

import '../models.dart';
import '../relative_time_ticker.dart';
import '../search_query.dart';
import '../session_read_store.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'mesh_widgets.dart';
import 'provider_badge.dart';

/// Returns a short human-readable label for how long ago [updatedAt] was.
String sessionTimeLabel(DateTime updatedAt) {
  final elapsed = DateTime.now().difference(updatedAt);
  if (elapsed.inSeconds < 60) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  if (elapsed.inDays < 7) return '${elapsed.inDays}d ago';
  return '${(elapsed.inDays / 7).floor()}w ago';
}

/// The canonical session list card used on both the Recent tab and the Host
/// Detail screen.  Supports a full mobile variant and a compact desktop
/// sidebar variant via [dense].
class SessionRowCard extends StatelessWidget {
  const SessionRowCard({
    super.key,
    required this.host,
    required this.session,
    required this.favorite,
    required this.onTap,
    required this.onToggleFavorite,
    this.selected = false,
    this.dense = false,
    this.query = '',
    this.showHost = true,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool favorite;
  final bool selected;
  final bool dense;
  final String query;
  final bool showHost;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = session.isActive;
    return ListenableBuilder(
      listenable: SessionReadStore.instance,
      builder: (context, _) {
        final unread =
            !selected && SessionReadStore.instance.isUnread(host, session);
        return _buildBody(context, colors, running, unread);
      },
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppColors colors,
    bool running,
    bool unread,
  ) {
    if (dense) {
      // Compact variant for the desktop sidebar — plain InkWell with tinted
      // selection fill, no card chrome.
      final bgColor = selected ? colors.accentMuted : Colors.transparent;
      final borderColor = selected
          ? colors.accent.withValues(alpha: 0.35)
          : Colors.transparent;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.fromLTRB(10, 9, 8, 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  // Status was conveyed by colour alone (live pulse vs grey
                  // dot) which fails WCAG 1.4.1. Expose a textual status to
                  // assistive tech without changing the visual.
                  child: Semantics(
                    label: running ? 'Running' : 'Idle',
                    container: true,
                    child: ExcludeSemantics(
                      child: running
                          ? LivePulse(color: colors.success)
                          : Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: selected
                                    ? colors.accent
                                    : colors.textTertiary.withValues(alpha: 0.35),
                                shape: BoxShape.circle,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontWeight: AppWeights.body,
                                    height: 1.25,
                                    color: selected
                                        ? colors.accent
                                        : colors.textPrimary,
                                  ),
                            ),
                          ),
                          if (session.provider != null) ...[
                            const SizedBox(width: 6),
                            AgentProviderBadge(
                              providerKind: session.provider,
                              compact: true,
                            ),
                          ],
                          if (session.isSubAgent) ...[
                            const SizedBox(width: 6),
                            const _SubAgentBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${host.label} · ${session.cwd}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 10.5,
                        ),
                      ),
                      if (session.preview.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          session.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.textSecondary,
                                height: 1.3,
                                fontSize: 11.5,
                              ),
                        ),
                      ],
                      if (session.matchSnippet != null &&
                          session.matchSnippet!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _HighlightedSnippet(
                          text: session.matchSnippet!,
                          query: query,
                          style: Theme.of(context).textTheme.bodySmall!
                              .copyWith(
                                color: colors.textSecondary,
                                height: 1.3,
                                fontSize: 11.5,
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (unread) ...[
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Semantics(
                      label: 'Unread updates',
                      child: ExcludeSemantics(
                        child: _UnreadDot(color: colors.accent),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                if (favorite)
                  Padding(
                    padding: const EdgeInsets.only(left: 6, top: 2),
                    child: Icon(
                      Icons.star_rounded,
                      size: 13,
                      color: colors.warning,
                    ),
                  )
                else
                  InkWell(
                    onTap: onToggleFavorite,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.star_outline_rounded,
                        size: 13,
                        color: colors.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    // ── Mobile / full-width variant ──────────────────────────────────────────
    final branch = session.gitInfo?.branch;
    final hasBranch = branch != null && branch.isNotEmpty;
    return MeshCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      accentStrip: running
          ? colors.success
          : (selected
              ? colors.accent
              : (unread ? colors.accent.withValues(alpha: 0.45) : null)),
      borderColor: selected ? colors.accent : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running) ...[
                LivePulse(color: colors.success),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: unread ? AppWeights.title : AppWeights.emphasis,
                  ),
                ),
              ),
              if (unread) ...[
                const SizedBox(width: 6),
                _UnreadDot(color: colors.accent),
                const SizedBox(width: 4),
              ],
              IconButton(
                onPressed: onToggleFavorite,
                tooltip: favorite ? 'Remove favorite' : 'Add favorite',
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                icon: Icon(
                  favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: favorite ? colors.warning : colors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (showHost) ...[
                Icon(Icons.dns_rounded, size: 13, color: colors.textTertiary),
                const SizedBox(width: 4),
                Flexible(
                  flex: 0,
                  child: Text(
                    host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (session.provider != null) ...[
                if (!showHost) const SizedBox(width: 0),
                AgentProviderBadge(
                  providerKind: session.provider,
                  compact: !showHost,
                ),
                const SizedBox(width: 8),
              ],
              if (session.isSubAgent) ...[
                const _SubAgentBadge(),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  session.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 11.5),
                ),
              ),
              const SizedBox(width: 8),
              ListenableBuilder(
                listenable: RelativeTimeTicker.minutes,
                builder: (_, _) => Text(
                  sessionTimeLabel(session.updatedAt),
                  style: monoStyle(
                    color: colors.textTertiary,
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ),
          if (hasBranch) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.account_tree_rounded,
                  size: 12,
                  color: colors.textTertiary,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    branch,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (session.runtime != null) ...[
            const SizedBox(height: AppSpacing.sm),
            SessionRuntimeCardWrap(runtime: session.runtime),
          ],
          if (session.preview.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              session.preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          if (session.matchSnippet != null &&
              session.matchSnippet!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _HighlightedSnippet(
              text: session.matchSnippet!,
              query: query,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Private helpers ──────────────────────────────────────────────────────────

class _SubAgentBadge extends StatelessWidget {
  const _SubAgentBadge();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.info.withValues(alpha: 0.3)),
      ),
      child: Text(
        'Sub-agent',
        style: monoStyle(
          color: colors.info,
          fontSize: 9,
          fontWeight: AppWeights.emphasis,
        ),
      ),
    );
  }
}

class _UnreadDot extends StatelessWidget {
  const _UnreadDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _HighlightedSnippet extends StatelessWidget {
  const _HighlightedSnippet({
    required this.text,
    required this.query,
    required this.style,
  });

  final String text;
  final String query;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final matches = searchQueryMatchRanges(text, query);
    if (matches.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    }

    final spans = <TextSpan>[];
    var start = 0;
    for (final match in matches) {
      if (match.start > start) {
        spans.add(
          TextSpan(text: text.substring(start, match.start), style: style),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: style.copyWith(
            color: colors.accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      start = match.end;
    }

    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: style));
    }

    return RichText(
      text: TextSpan(children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
