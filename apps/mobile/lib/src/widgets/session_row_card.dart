import 'package:flutter/material.dart';
import 'app_menu.dart';

import '../models.dart';
import '../provider_labels.dart';
import '../relative_time_ticker.dart';
import '../search_query.dart';
import '../session_read_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import 'mesh_widgets.dart';
import '../theme/app_status_styles.dart';

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
    final contextLabel =
        secondaryLabel ??
        [
          if (showHost) host.label,
          _workspaceLabel(session.cwd),
          if (agentProviderDisplayLabel(session.provider)
              case final String label)
            label,
        ].join(' · ');
    final status = _sessionStatusBadge(session);
    if (dense && query.trim().isEmpty) {
      return Tooltip(
        message:
            '${session.title}\n$contextLabel · ${sessionTimeLabel(session.updatedAt)}',
        child: Semantics(
          selected: selected,
          label: unread ? 'Unread session' : null,
          child: Material(
            color: selected ? colors.surfaceMuted : Colors.transparent,
            borderRadius: AppShapes.input,
            child: InkWell(
              onTap: onTap,
              borderRadius: AppShapes.input,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 32),
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: AppSpacing.compact,
                    right: AppSpacing.xs,
                  ),
                  child: Row(
                    children: [
                      if (running)
                        LivePulse(color: colors.success)
                      else
                        Icon(
                          favorite ? Icons.star_rounded : Icons.circle,
                          size: favorite
                              ? AppSizes.tinyIcon
                              : AppSizes.statusDot,
                          color: unread ? colors.accent : colors.textTertiary,
                        ),
                      const SizedBox(width: AppSpacing.compact),
                      Expanded(
                        child: Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: AppWeights.body,
                          ),
                        ),
                      ),
                      ?status,
                      SizedBox(
                        width: 28,
                        height: 32,
                        child: AppMenuButton(
                          tooltip: 'Session options',
                          children: [
                            AppMenuItem(
                              label: favorite
                                  ? 'Remove favorite'
                                  : 'Add favorite',
                              leadingIcon: favorite
                                  ? Icons.star_rounded
                                  : Icons.star_outline_rounded,
                              onPressed: onToggleFavorite,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      selected: selected,
      label: [
        if (unread) 'Unread session',
        if (running) 'Running session',
      ].join(', '),
      child: Material(
        color: selected ? colors.surfaceMuted : colors.surfaceElevated,
        borderRadius: AppShapes.card,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppShapes.card,
          child: Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.xs,
              top: AppSpacing.sm,
              bottom: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (running) ...[
                      LivePulse(color: colors.success),
                      const SizedBox(width: AppSpacing.sm),
                    ] else if (unread) ...[
                      _UnreadDot(color: colors.accent),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    Expanded(
                      child: Text(
                        session.title,
                        maxLines: dense ? 1 : 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            (dense
                                    ? theme.textTheme.bodyMedium
                                    : theme.textTheme.bodyLarge)
                                ?.copyWith(
                                  fontWeight: unread
                                      ? AppWeights.emphasis
                                      : AppWeights.body,
                                ),
                      ),
                    ),
                    if (favorite)
                      Icon(
                        Icons.star_rounded,
                        size: AppSizes.compactIcon,
                        color: colors.warning,
                      ),
                    AppMenuButton(
                      tooltip: 'Session options',
                      children: [
                        AppMenuItem(
                          label: favorite ? 'Remove favorite' : 'Add favorite',
                          leadingIcon: favorite
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          onPressed: onToggleFavorite,
                        ),
                      ],
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          contextLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      ListenableBuilder(
                        listenable: RelativeTimeTicker.minutes,
                        builder: (_, _) => Text(
                          sessionTimeLabel(session.updatedAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (status != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  status,
                ],
                if (query.trim().isNotEmpty &&
                    (session.matchSnippet ?? session.preview).isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  _HighlightedSnippet(
                    text: session.matchSnippet ?? session.preview,
                    query: query,
                    style: theme.textTheme.bodySmall!.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Private helpers ──────────────────────────────────────────────────────────

Widget? _sessionStatusBadge(SessionSummary session) {
  final status = session.status;
  return switch (status) {
    'waiting_for_approval' || 'pendingApproval' => const _SessionStatusLabel(
      label: 'approval',
      tone: MeshStatusTone.approval,
      icon: Icons.verified_user_outlined,
    ),
    'waiting_for_input' => const _SessionStatusLabel(
      label: 'waiting',
      tone: MeshStatusTone.waiting,
      icon: Icons.question_answer_outlined,
    ),
    'queued' => const _SessionStatusLabel(
      label: 'queued',
      tone: MeshStatusTone.queued,
      icon: Icons.schedule_rounded,
    ),
    'blocked' => const _SessionStatusLabel(
      label: 'blocked',
      tone: MeshStatusTone.waiting,
      icon: Icons.pause_circle_outline_rounded,
    ),
    'failed' || 'errored' => const _SessionStatusLabel(
      label: 'failed',
      tone: MeshStatusTone.danger,
      icon: Icons.error_outline_rounded,
    ),
    'stale' => const _SessionStatusLabel(
      label: 'stale',
      tone: MeshStatusTone.stale,
      icon: Icons.history_toggle_off_rounded,
    ),
    'active' || 'running' => const _SessionStatusLabel(
      label: 'running',
      tone: MeshStatusTone.running,
      live: true,
    ),
    _ =>
      session.isActive
          ? const _SessionStatusLabel(
              label: 'running',
              tone: MeshStatusTone.running,
              live: true,
            )
          : null,
  };
}

class _SessionStatusLabel extends StatelessWidget {
  const _SessionStatusLabel({
    required this.label,
    required this.tone,
    this.icon,
    this.live = false,
  });

  final String label;
  final MeshStatusTone tone;
  final IconData? icon;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final color = meshStatusBadgeColors(context.colors, tone).foreground;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live)
          LivePulse(color: color)
        else if (icon != null)
          Icon(icon, size: AppSizes.smallIcon, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: AppWeights.emphasis,
          ),
        ),
      ],
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
            fontWeight: AppWeights.title,
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
