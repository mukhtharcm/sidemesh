import 'package:flutter/material.dart';

import '../models.dart';
import '../workspace_label.dart';
import '../relative_time_ticker.dart';
import '../search_query.dart';
import '../session_read_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

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
    this.showWorkspace = true,
    this.showProvider = false,

    /// Optional inline metadata for ungrouped rows.
    this.secondaryLabel,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool favorite;
  final bool selected;
  final bool dense;
  final String query;
  final bool showHost;
  final bool showWorkspace;
  final bool showProvider;
  final String? secondaryLabel;
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
    final theme = Theme.of(context);
    final needsYou = session.status == 'waiting_for_approval' ||
        session.status == 'waiting_for_input';
    final status = needsYou ? 'Needs you' : running ? 'Running' :
        switch (session.status) {
          'failed' || 'errored' => 'Failed',
          'queued' => 'Queued',
          'blocked' => 'Blocked',
          'stale' => 'Stale',
          _ => null,
        };
    final metadata = [
      if (showHost) host.label,
      if (showWorkspace) workspaceLabel(session.cwd),
      if (secondaryLabel?.isNotEmpty == true) secondaryLabel!,
      if (showProvider && session.provider != null) session.provider!,
    ].join(' · ');
    return Semantics(
      label: [session.title, if (metadata.isNotEmpty) metadata, ?status].join(', '),
      child: Material(
        color: selected ? colors.surfaceMuted : Colors.transparent,
        borderRadius: AppShapes.badge,
        child: InkWell(
          borderRadius: AppShapes.badge,
          onTap: onTap,
          onLongPress: onToggleFavorite,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: dense ? 0 : AppSpacing.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: dense ? AppSizes.compactControl : AppSizes.menuItem),
                  child: Row(
                    children: [
                      SizedBox.square(
                        dimension: AppSizes.compactIcon,
                        child: Center(child: Icon(
                          session.isSubAgent ? Icons.account_tree_outlined
                              : unread ? Icons.circle : Icons.circle_outlined,
                          size: session.isSubAgent ? AppSizes.compactIcon : 6,
                          color: unread ? colors.accent : colors.textTertiary,
                        )),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(session.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: AppWeights.body, letterSpacing: 0)),
                      ),
                      if (showWorkspace || showHost) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Flexible(
                          child: Tooltip(
                            message: metadata,
                            child: Text(metadata, maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary)),
                          ),
                        ),
                      ],
                      if (!showWorkspace && !showHost && showProvider && session.provider != null) ...[
                        const SizedBox(width: AppSpacing.sm),
                        Text(session.provider!, style: theme.textTheme.labelSmall),
                      ],
                      const SizedBox(width: AppSpacing.sm),
                      ListenableBuilder(
                        listenable: RelativeTimeTicker.minutes,
                        builder: (_, _) => Text(status ?? sessionTimeLabel(session.updatedAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 11, letterSpacing: 0,
                            color: needsYou ? colors.accent : running ? colors.success : colors.textTertiary)),
                      ),
                      if (favorite) ...[
                        const SizedBox(width: AppSpacing.xs),
                        Icon(Icons.star_rounded, size: 14, color: colors.textSecondary),
                      ],
                    ],
                  ),
                ),
                if (query.isNotEmpty && session.matchSnippet?.isNotEmpty == true)
                  _HighlightedSnippet(text: session.matchSnippet!, query: query,
                    style: theme.textTheme.bodySmall!.copyWith(color: colors.textSecondary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Private helpers ──────────────────────────────────────────────────────────

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
