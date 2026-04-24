import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_favorites_store.dart';
import '../session_overrides_store.dart';
import '../session_read_store.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';
import 'create_session_sheet.dart';

class HostDetailScreen extends StatefulWidget {
  const HostDetailScreen({
    super.key,
    required this.host,
    required this.api,
    required this.onOpenSession,
    this.embedded = false,
    this.topPadding = 0,
  });

  final HostProfile host;
  final ApiClient api;
  final ValueChanged<SessionSummary> onOpenSession;

  /// When true, drop Scaffold/AppBar/FAB chrome and render a slim header
  /// suitable for embedding inside the desktop two-pane shell.
  final bool embedded;

  /// Extra padding reserved at the top (e.g. macOS titlebar inset).
  final double topPadding;

  @override
  State<HostDetailScreen> createState() => _HostDetailScreenState();
}

class _HostDetailScreenState extends State<HostDetailScreen> {
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;
  late Future<_HostOverview> _future;
  Timer? _refreshTimer;
  static const Duration _refreshInterval = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _favorites.ensureLoaded();
    SessionReadStore.instance.ensureLoaded();
    _future = _load();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _silentRefresh() async {
    if (!mounted) return;
    try {
      final fresh = await _load();
      if (!mounted) return;
      setState(() => _future = Future.value(fresh));
    } catch (_) {
      // Keep the last good snapshot on transient errors.
    }
  }

  Future<_HostOverview> _load() async {
    final results = await Future.wait<Object>([
      widget.api.fetchNode(widget.host),
      widget.api.fetchSessions(widget.host),
    ]);
    final node = results[0] as NodeInfo;
    final sessions = results[1] as List<SessionSummary>;
    final workspaces = _buildWorkspaces(sessions);
    return _HostOverview(
      node: node,
      workspaces: workspaces,
      sessions: sessions,
    );
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  List<SessionSummary> _sortSessions(List<SessionSummary> sessions) {
    final overrides = SessionOverridesStore.instance;
    final sorted = sessions
        .map((s) => overrides.overlay(widget.host.id, s))
        .toList();
    sorted.sort((left, right) {
      final leftFavorite = _favorites.isFavorite(widget.host, left.id);
      final rightFavorite = _favorites.isFavorite(widget.host, right.id);
      if (leftFavorite != rightFavorite) {
        return leftFavorite ? -1 : 1;
      }
      return right.updatedAt.compareTo(left.updatedAt);
    });
    return sorted;
  }

  List<WorkspaceSummary> _buildWorkspaces(List<SessionSummary> sessions) {
    final grouped = <String, WorkspaceSummary>{};
    for (final session in sessions) {
      final parts = session.cwd.split('/').where((part) => part.isNotEmpty);
      final label = parts.isEmpty ? session.cwd : parts.last;
      final existing = grouped[session.cwd];
      if (existing == null) {
        grouped[session.cwd] = WorkspaceSummary(
          cwd: session.cwd,
          label: label.isEmpty ? session.cwd : label,
          sessionCount: 1,
          lastUsedAt: session.updatedAt,
        );
        continue;
      }
      grouped[session.cwd] = WorkspaceSummary(
        cwd: existing.cwd,
        label: existing.label,
        sessionCount: existing.sessionCount + 1,
        lastUsedAt: existing.lastUsedAt.isAfter(session.updatedAt)
            ? existing.lastUsedAt
            : session.updatedAt,
      );
    }

    final workspaces = grouped.values.toList();
    workspaces.sort(
      (left, right) => right.lastUsedAt.compareTo(left.lastUsedAt),
    );
    return workspaces;
  }

  Future<void> _startSession({String? prefilledCwd}) async {
    final created = await showCreateSessionLauncher(
      context,
      host: widget.host,
      api: widget.api,
      initialCwd: prefilledCwd,
    );
    if (created != null && mounted) {
      widget.onOpenSession(created);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (widget.embedded) {
      return Container(
        color: colors.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: widget.topPadding),
            _EmbeddedHostHeader(
              host: widget.host,
              onRefresh: _refresh,
              onNewSession: () => _startSession(),
            ),
            Expanded(child: _buildBody(context)),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        title: Text(widget.host.label),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startSession(),
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('New session'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<_HostOverview>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MeshLoader();
        }
        if (snapshot.hasError) {
          return MeshEmptyState(
            icon: Icons.wifi_off_rounded,
            title: 'Could not reach host',
            body: snapshot.error.toString(),
          );
        }
        final data = snapshot.data!;
        return ListenableBuilder(
          listenable: Listenable.merge([
            _favorites,
            SessionOverridesStore.instance,
          ]),
          builder: (context, _) {
            final sortedSessions = _sortSessions(data.sessions);
            return RefreshIndicator(
              color: colors.accent,
              onRefresh: _refresh,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  widget.embedded ? 32 : 120,
                ),
                children: [
                  _NodeCard(host: widget.host, node: data.node),
                  const SizedBox(height: 18),
                  _SectionHeader(
                    icon: Icons.folder_open_rounded,
                    title: 'Workspaces',
                    subtitle:
                        '${data.workspaces.length} ${data.workspaces.length == 1 ? "entry" : "entries"}',
                  ),
                  const SizedBox(height: 8),
                  if (data.workspaces.isEmpty)
                    const MeshEmptyState(
                      icon: Icons.folder_off_outlined,
                      title: 'No workspaces',
                      body: 'Start a session and this host will remember it.',
                    )
                  else
                    ...data.workspaces.map(
                      (workspace) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _WorkspaceCard(
                          workspace: workspace,
                          onTap: () =>
                              _startSession(prefilledCwd: workspace.cwd),
                        ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  _SectionHeader(
                    icon: Icons.history_rounded,
                    title: 'Recent sessions',
                    subtitle:
                        '${data.sessions.length} ${data.sessions.length == 1 ? "session" : "sessions"}',
                  ),
                  const SizedBox(height: 8),
                  if (sortedSessions.isEmpty)
                    const MeshEmptyState(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: 'No sessions yet',
                      body: 'Tap "New session" to start one on this host.',
                    )
                  else
                    ...sortedSessions.map(
                      (session) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _SessionRow(
                          host: widget.host,
                          session: session,
                          favorite: _favorites.isFavorite(
                            widget.host,
                            session.id,
                          ),
                          onTap: () => widget.onOpenSession(session),
                          onToggleFavorite: () {
                            _favorites.toggleFavorite(widget.host, session.id);
                          },
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _EmbeddedHostHeader extends StatelessWidget {
  const _EmbeddedHostHeader({
    required this.host,
    required this.onRefresh,
    required this.onNewSession,
  });

  final HostProfile host;
  final VoidCallback onRefresh;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.dns_rounded, size: 17, color: colors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  host.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: onRefresh,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onNewSession,
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: const Text('New session'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.accentOn,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({required this.host, required this.node});

  final HostProfile host;
  final NodeInfo node;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.elevated,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.3),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.dns_rounded, color: colors.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.label.isNotEmpty ? node.label : host.label,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host.baseUrl,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: node.hostname,
                icon: Icons.memory_rounded,
                tone: MeshPillTone.neutral,
                mono: true,
              ),
              MeshPill(
                label: node.platform,
                icon: Icons.devices_other_rounded,
                tone: MeshPillTone.neutral,
                mono: true,
              ),
              MeshPill(
                label: 'codex ${node.codexVersion}',
                icon: Icons.auto_awesome_rounded,
                tone: MeshPillTone.accent,
                mono: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.accent),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          Text(
            subtitle,
            style: monoStyle(color: colors.textTertiary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({required this.workspace, required this.onTap});

  final WorkspaceSummary workspace;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Icon(Icons.folder_rounded, color: colors.accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  workspace.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          MeshPill(
            label: '${workspace.sessionCount}',
            icon: Icons.forum_outlined,
            tone: MeshPillTone.neutral,
            mono: true,
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.host,
    required this.session,
    required this.favorite,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool favorite;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = session.isActive;
    return ListenableBuilder(
      listenable: SessionReadStore.instance,
      builder: (context, _) {
        final unread = SessionReadStore.instance.isUnread(host, session);
        return MeshCard(
          onTap: onTap,
          accentStrip: running ? colors.success : null,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                        fontWeight: unread ? FontWeight.w800 : FontWeight.w700,
                      ),
                    ),
                  ),
                  if (unread) ...[
                    const SizedBox(width: 6),
                    _UnreadDot(color: colors.accent),
                    const SizedBox(width: 6),
                  ],
                  IconButton(
                    onPressed: onToggleFavorite,
                    tooltip: favorite ? 'Remove favorite' : 'Add favorite',
                    visualDensity: VisualDensity.compact,
                    iconSize: 20,
                    splashRadius: 18,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    icon: Icon(
                      favorite
                          ? Icons.star_rounded
                          : Icons.star_outline_rounded,
                      color: favorite ? colors.warning : colors.textTertiary,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                session.cwd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(color: colors.textTertiary, fontSize: 11.5),
              ),
              if (session.runtime != null) ...[
                const SizedBox(height: 8),
                SessionRuntimeWrap(runtime: session.runtime),
              ],
            ],
          ),
        );
      },
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

class _HostOverview {
  const _HostOverview({
    required this.node,
    required this.workspaces,
    required this.sessions,
  });

  final NodeInfo node;
  final List<WorkspaceSummary> workspaces;
  final List<SessionSummary> sessions;
}
