import 'package:flutter/material.dart';

import '../models.dart';
import '../relative_time_ticker.dart';
import '../search_query.dart';
import '../session_read_store.dart';
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

String _workspaceLabel(String cwd) {
  final trimmed = cwd.trim();
  if (trimmed.isEmpty) return 'Workspace';
  final parts = trimmed.split(RegExp(r'[\\/]'));
  for (var i = parts.length - 1; i >= 0; i -= 1) {
    final part = parts[i].trim();
    if (part.isNotEmpty) {
      return part;
    }
  }
  return trimmed;
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
    /// When set, replaces the default "host · workspace" secondary line in
    /// the dense sidebar variant. Used by grouped views to show the git
    /// branch name instead of the folder (which is already the group header).
    this.secondaryLabel,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool favorite;
  final bool selected;
  final bool dense;
  final String query;
  final bool showHost;
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
    final workspaceLabel = _workspaceLabel(session.cwd);
    final supportingText = session.matchSnippet?.isNotEmpty == true
        ? session.matchSnippet!
        : session.preview;
    if (dense) {
      // Compact variant for the desktop sidebar — plain InkWell with tinted
      // selection fill, no card chrome.
      final bgColor = selected
          ? colors.accentMuted.withValues(alpha: 0.48)
          : Colors.transparent;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppShapes.badge,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.fromLTRB(10, 9, 8, 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: AppShapes.badge,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
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
                              style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: AppWeights.body,
                                    height: 1.25,
                                    color: colors.textPrimary,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              // secondaryLabel overrides the default
                              // "host · workspace" line when we're inside a
                              // grouped view (e.g. show branch name instead).
                              secondaryLabel ??
                              (showHost
                                  ? '${host.label} · $workspaceLabel'
                                  : workspaceLabel),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.textSecondary,
                                fontSize: 11.5,
                                height: 1.25,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ListenableBuilder(
                            listenable: RelativeTimeTicker.minutes,
                            builder: (_, _) => Text(
                              sessionTimeLabel(session.updatedAt),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.textTertiary,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (session.provider != null || session.isSubAgent) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (session.provider != null)
                              AgentProviderBadge(
                                providerKind: session.provider,
                                compact: true,
                              ),
                            if (session.isSubAgent) const _SubAgentBadge(),
                          ],
                        ),
                      ],
                      if (supportingText.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        if (session.matchSnippet?.isNotEmpty == true)
                          _HighlightedSnippet(
                            text: supportingText,
                            query: query,
                            style: theme.textTheme.bodySmall!.copyWith(
                              color: colors.textSecondary,
                              height: 1.3,
                              fontSize: 11.5,
                            ),
                          )
                        else
                          Text(
                            supportingText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
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
                    child: _UnreadDot(color: colors.accent),
                  ),
                  const SizedBox(width: 2),
                ],
                InkWell(
                  onTap: onToggleFavorite,
                  borderRadius: AppShapes.badge,
                  child: SizedBox(
                    width: 30,
                    height: 30,
                    child: Icon(
                      favorite
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      size: 15,
                      color:
                          favorite ? colors.warning : colors.textTertiary,
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
    final statusBadge = _sessionStatusBadge(session);
    return MeshSurface(
      onTap: onTap,
      selected: selected,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      borderColor: selected ? colors.accent : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
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
              if (statusBadge != null) ...[
                const SizedBox(width: AppSpacing.sm),
                statusBadge,
              ],
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
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
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
                Icon(Icons.dns_rounded, size: 14, color: colors.textTertiary),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Icon(Icons.folder_outlined, size: 14, color: colors.textTertiary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  workspaceLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ListenableBuilder(
                listenable: RelativeTimeTicker.minutes,
                builder: (_, _) => Text(
                  sessionTimeLabel(session.updatedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          if (session.provider != null || session.isSubAgent) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (session.provider != null)
                  AgentProviderBadge(providerKind: session.provider),
                if (session.isSubAgent) const _SubAgentBadge(),
              ],
            ),
          ],
          if (supportingText.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            if (session.matchSnippet?.isNotEmpty == true)
              _HighlightedSnippet(
                text: supportingText,
                query: query,
                style: theme.textTheme.bodySmall!.copyWith(
                  color: colors.textSecondary,
                  height: 1.35,
                ),
              )
            else
              Text(
                supportingText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
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

MeshStatusBadge? _sessionStatusBadge(SessionSummary session) {
  final status = session.status;
  return switch (status) {
    'waiting_for_approval' || 'pendingApproval' => const MeshStatusBadge(
        label: 'approval',
        tone: MeshStatusTone.approval,
        icon: Icons.verified_user_outlined,
        compact: true,
      ),
    'waiting_for_input' => const MeshStatusBadge(
        label: 'waiting',
        tone: MeshStatusTone.waiting,
        icon: Icons.question_answer_outlined,
        compact: true,
      ),
    'queued' => const MeshStatusBadge(
        label: 'queued',
        tone: MeshStatusTone.queued,
        icon: Icons.schedule_rounded,
        compact: true,
      ),
    'blocked' => const MeshStatusBadge(
        label: 'blocked',
        tone: MeshStatusTone.waiting,
        icon: Icons.pause_circle_outline_rounded,
        compact: true,
      ),
    'failed' || 'errored' => const MeshStatusBadge(
        label: 'failed',
        tone: MeshStatusTone.danger,
        icon: Icons.error_outline_rounded,
        compact: true,
      ),
    'stale' => const MeshStatusBadge(
        label: 'stale',
        tone: MeshStatusTone.stale,
        icon: Icons.history_toggle_off_rounded,
        compact: true,
      ),
    'active' || 'running' => const MeshStatusBadge(
        label: 'running',
        tone: MeshStatusTone.running,
        live: true,
        compact: true,
      ),
    _ => session.isActive
        ? const MeshStatusBadge(
            label: 'running',
            tone: MeshStatusTone.running,
            live: true,
            compact: true,
          )
        : null,
  };
}

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
