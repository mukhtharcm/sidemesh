import 'dart:math';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../host_store.dart';
import '../models.dart';
import '../session_favorites_store.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/mesh_widgets.dart';
import 'host_detail_screen.dart';
import 'session_screen.dart';

class SidemeshHomeScreen extends StatefulWidget {
  const SidemeshHomeScreen({super.key});

  @override
  State<SidemeshHomeScreen> createState() => _SidemeshHomeScreenState();
}

class _SidemeshHomeScreenState extends State<SidemeshHomeScreen> {
  static const _tabs = [
    _TabDef(
      title: 'Recent',
      subtitle: 'Latest activity across the fleet',
      icon: Icons.schedule_rounded,
      selectedIcon: Icons.schedule_rounded,
    ),
    _TabDef(
      title: 'Inbox',
      subtitle: 'Pending approvals from every host',
      icon: Icons.all_inbox_outlined,
      selectedIcon: Icons.all_inbox_rounded,
    ),
    _TabDef(
      title: 'Hosts',
      subtitle: 'Your mesh of Codex nodes',
      icon: Icons.hub_outlined,
      selectedIcon: Icons.hub_rounded,
    ),
  ];

  final HostStore _store = HostStore();
  final ApiClient _api = ApiClient();
  List<HostProfile> _hosts = const [];
  bool _loading = true;
  int _tabIndex = 0;
  int _activeCount = 0;
  int _inboxCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshHosts();
  }

  Future<void> _refreshHosts() async {
    final hosts = await _store.loadHosts();
    if (!mounted) {
      return;
    }
    setState(() {
      _hosts = hosts;
      _loading = false;
    });
  }

  Future<void> _showHostEditor({HostProfile? initialHost}) async {
    final result = await showModalBottomSheet<HostProfile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => HostEditorSheet(initialHost: initialHost),
    );
    if (result == null) {
      return;
    }
    final exists = _hosts.any((item) => item.id == result.id);
    final updated = exists
        ? _hosts.map((item) => item.id == result.id ? result : item).toList()
        : [..._hosts, result];
    await _store.saveHosts(updated);
    await _refreshHosts();
  }

  Future<void> _removeHost(HostProfile host) async {
    final updated = _hosts.where((item) => item.id != host.id).toList();
    await _store.saveHosts(updated);
    await _refreshHosts();
  }

  Future<void> _openSession(HostProfile host, SessionSummary session) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            SessionScreen(host: host, session: session, api: _api),
      ),
    );
    if (!mounted) {
      return;
    }
    await _refreshHosts();
  }

  Future<void> _openHost(HostProfile host) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HostDetailScreen(
          host: host,
          api: _api,
          onOpenSession: (session) => _openSession(host, session),
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    await _refreshHosts();
  }

  SessionSummary _sessionFromAction(PendingAction action) {
    return SessionSummary(
      id: action.sessionId,
      title: action.sessionTitle ?? 'Session',
      preview: action.detail,
      cwd: action.cwd ?? '',
      createdAt: action.requestedAt,
      updatedAt: action.requestedAt,
      source: 'appServer',
      status: 'pendingApproval',
      runtime: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tab = _tabs[_tabIndex];
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(tab: tab, onRefresh: _refreshHosts),
            Expanded(
              child: _loading
                  ? const MeshLoader()
                  : IndexedStack(
                      index: _tabIndex,
                      children: [
                        RecentPane(
                          hosts: _hosts,
                          api: _api,
                          onOpenSession: _openSession,
                          onActiveCountChanged: (count) {
                            if (!mounted) return;
                            setState(() => _activeCount = count);
                          },
                        ),
                        InboxPane(
                          hosts: _hosts,
                          api: _api,
                          onOpenSession: (host, action) =>
                              _openSession(host, _sessionFromAction(action)),
                          onInboxCountChanged: (count) {
                            if (!mounted) return;
                            setState(() => _inboxCount = count);
                          },
                        ),
                        HostsPane(
                          hosts: _hosts,
                          onOpenHost: _openHost,
                          onEditHost: (host) =>
                              _showHostEditor(initialHost: host),
                          onRemoveHost: _removeHost,
                          onAddHost: () => _showHostEditor(),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: _tabIndex == 2 && _hosts.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _showHostEditor(),
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Add host'),
            )
          : null,
      bottomNavigationBar: _MeshNavBar(
        tabs: _tabs,
        currentIndex: _tabIndex,
        onTap: (index) => setState(() => _tabIndex = index),
        badges: [_activeCount, _inboxCount, 0],
      ),
    );
  }
}

class _TabDef {
  const _TabDef({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selectedIcon,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final IconData selectedIcon;
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.tab, required this.onRefresh});

  final _TabDef tab;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final controller = ThemeScope.of(context);
    final isDark = controller.isDark(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: BorderRadius.circular(11),
              boxShadow: [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.graphic_eq_rounded,
              color: colors.accentOn,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'sidemesh',
                      style: monoStyle(
                        color: colors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ).copyWith(letterSpacing: -0.4),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '/ ${tab.title.toLowerCase()}',
                      style: monoStyle(
                        color: colors.accent,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Text(
                  tab.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          MeshIconButton(
            icon: isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            tooltip: isDark ? 'Light mode' : 'Dark mode',
            onTap: () => controller.toggle(context),
          ),
          const SizedBox(width: 8),
          MeshIconButton(
            icon: Icons.refresh_rounded,
            tooltip: 'Refresh',
            onTap: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _MeshNavBar extends StatelessWidget {
  const _MeshNavBar({
    required this.tabs,
    required this.currentIndex,
    required this.onTap,
    required this.badges,
  });

  final List<_TabDef> tabs;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final List<int> badges;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
      decoration: BoxDecoration(
        color: colors.canvas,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: List.generate(tabs.length, (index) {
            final tab = tabs[index];
            final selected = index == currentIndex;
            final badge = index < badges.length ? badges[index] : 0;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => onTap(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: selected
                            ? colors.accentMuted
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selected
                              ? colors.accent.withValues(alpha: 0.4)
                              : Colors.transparent,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _NavIconWithBadge(
                            icon: selected ? tab.selectedIcon : tab.icon,
                            selected: selected,
                            badge: badge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tab.title,
                            style: monoStyle(
                              color: selected
                                  ? colors.accent
                                  : colors.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ).copyWith(letterSpacing: 0.3),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _NavIconWithBadge extends StatelessWidget {
  const _NavIconWithBadge({
    required this.icon,
    required this.selected,
    required this.badge,
  });

  final IconData icon;
  final bool selected;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconColor = selected ? colors.accent : colors.textSecondary;
    final label = badge > 99 ? '99+' : '$badge';
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(icon, size: 22, color: iconColor),
        if (badge > 0)
          Positioned(
            top: -6,
            right: -10,
            child: Container(
              constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: colors.danger,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: colors.canvas, width: 2),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: monoStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ).copyWith(height: 1.1),
              ),
            ),
          ),
      ],
    );
  }
}

class RecentPane extends StatefulWidget {
  const RecentPane({
    super.key,
    required this.hosts,
    required this.api,
    required this.onOpenSession,
    required this.onActiveCountChanged,
    this.query = '',
    this.selectedSessionId,
    this.padding,
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final void Function(HostProfile host, SessionSummary session) onOpenSession;
  final ValueChanged<int> onActiveCountChanged;
  final String query;
  final String? selectedSessionId;
  final EdgeInsets? padding;

  @override
  State<RecentPane> createState() => _RecentPaneState();
}

class _RecentPaneState extends State<RecentPane> {
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;
  late Future<_RecentLoadResult> _future;

  @override
  void initState() {
    super.initState();
    _favorites.ensureLoaded();
    _future = _loadRecent();
  }

  @override
  void didUpdateWidget(covariant RecentPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hosts != widget.hosts) {
      _future = _loadRecent();
    }
  }

  Future<_RecentLoadResult> _loadRecent() async {
    final failures = <String>[];
    final results = await Future.wait(
      widget.hosts.map((host) async {
        try {
          final sessions = await widget.api.fetchSessions(host, limit: 40);
          return sessions
              .take(20)
              .map(
                (session) => RemoteSessionEntry(host: host, session: session),
              )
              .toList();
        } catch (_) {
          failures.add(host.label);
          return const <RemoteSessionEntry>[];
        }
      }),
    );

    final merged = results.expand((entries) => entries).toList();
    merged.sort(
      (left, right) =>
          right.session.updatedAt.compareTo(left.session.updatedAt),
    );
    final activeCount = merged.where((entry) => entry.session.isActive).length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onActiveCountChanged(activeCount);
    });
    return _RecentLoadResult(entries: merged, failedHosts: failures);
  }

  List<RemoteSessionEntry> _sortEntries(List<RemoteSessionEntry> entries) {
    final query = widget.query.trim().toLowerCase();
    Iterable<RemoteSessionEntry> visible = entries;
    if (query.isNotEmpty) {
      visible = entries.where((entry) {
        final session = entry.session;
        final host = entry.host;
        return session.title.toLowerCase().contains(query) ||
            session.preview.toLowerCase().contains(query) ||
            session.cwd.toLowerCase().contains(query) ||
            host.label.toLowerCase().contains(query);
      });
    }
    final sorted = visible.toList();
    sorted.sort((left, right) {
      final leftFavorite = _favorites.isFavorite(left.host, left.session.id);
      final rightFavorite = _favorites.isFavorite(right.host, right.session.id);
      if (leftFavorite != rightFavorite) {
        return leftFavorite ? -1 : 1;
      }
      return right.session.updatedAt.compareTo(left.session.updatedAt);
    });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hosts.isEmpty) {
      return const MeshEmptyState(
        icon: Icons.schedule_rounded,
        title: 'No sessions yet',
        body:
            'Add a host first — your most recent Codex sessions will land here.',
      );
    }

    return FutureBuilder<_RecentLoadResult>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MeshLoader();
        }
        final result = snapshot.data ?? const _RecentLoadResult.empty();
        final entries = result.entries;
        final failures = result.failedHosts;
        if (entries.isEmpty) {
          return RefreshIndicator(
            color: context.colors.accent,
            onRefresh: () async {
              setState(() => _future = _loadRecent());
              await _future;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (failures.isNotEmpty)
                  _RecentErrorBanner(
                    hostLabels: failures,
                    onRetry: () {
                      setState(() => _future = _loadRecent());
                    },
                  ),
                const SizedBox(height: 80),
                const MeshEmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'No reachable sessions',
                  body:
                      'Saved hosts look fine, but none returned recent sessions right now.',
                ),
              ],
            ),
          );
        }
        return ListenableBuilder(
          listenable: _favorites,
          builder: (context, _) {
            final sortedEntries = _sortEntries(entries);
            if (sortedEntries.isEmpty) {
              return RefreshIndicator(
                color: context.colors.accent,
                onRefresh: () async {
                  setState(() => _future = _loadRecent());
                  await _future;
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    if (failures.isNotEmpty)
                      _RecentErrorBanner(
                        hostLabels: failures,
                        onRetry: () {
                          setState(() => _future = _loadRecent());
                        },
                      ),
                    const SizedBox(height: 80),
                    MeshEmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No matches',
                      body:
                          'No sessions match "${widget.query.trim()}". Clear the filter to see everything.',
                    ),
                  ],
                ),
              );
            }
            final basePadding =
                widget.padding ?? const EdgeInsets.fromLTRB(16, 8, 16, 32);
            return RefreshIndicator(
              color: context.colors.accent,
              onRefresh: () async {
                setState(() => _future = _loadRecent());
                await _future;
              },
              child: ListView.separated(
                padding: basePadding,
                itemCount: sortedEntries.length + (failures.isNotEmpty ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  if (failures.isNotEmpty && index == 0) {
                    return _RecentErrorBanner(
                      hostLabels: failures,
                      onRetry: () {
                        setState(() => _future = _loadRecent());
                      },
                    );
                  }
                  final entryIndex =
                      failures.isNotEmpty ? index - 1 : index;
                  final entry = sortedEntries[entryIndex];
                  return _SessionRowCard(
                    host: entry.host,
                    session: entry.session,
                    favorite: _favorites.isFavorite(
                      entry.host,
                      entry.session.id,
                    ),
                    selected:
                        widget.selectedSessionId == entry.session.id,
                    onTap: () =>
                        widget.onOpenSession(entry.host, entry.session),
                    onToggleFavorite: () {
                      _favorites.toggleFavorite(entry.host, entry.session.id);
                    },
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}

class _SessionRowCard extends StatelessWidget {
  const _SessionRowCard({
    required this.host,
    required this.session,
    required this.favorite,
    required this.onTap,
    required this.onToggleFavorite,
    this.selected = false,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool favorite;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = session.isActive;
    return MeshCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      accentStrip: running
          ? colors.success
          : (selected ? colors.accent : null),
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
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: onToggleFavorite,
                tooltip: favorite ? 'Remove favorite' : 'Add favorite',
                visualDensity: VisualDensity.compact,
                iconSize: 20,
                splashRadius: 18,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: Icon(
                  favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                  color: favorite ? colors.warning : colors.textTertiary,
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.dns_rounded, size: 13, color: colors.textTertiary),
              const SizedBox(width: 4),
              Text(
                host.label,
                style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  session.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 11.5),
                ),
              ),
            ],
          ),
          if (session.runtime != null) ...[
            const SizedBox(height: 10),
            SessionRuntimeWrap(runtime: session.runtime),
          ],
          if (session.preview.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              session.preview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
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

class InboxPane extends StatefulWidget {
  const InboxPane({
    super.key,
    required this.hosts,
    required this.api,
    required this.onOpenSession,
    required this.onInboxCountChanged,
    this.query = '',
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final void Function(HostProfile host, PendingAction action) onOpenSession;
  final ValueChanged<int> onInboxCountChanged;
  final String query;

  @override
  State<InboxPane> createState() => _InboxPaneState();
}

class _InboxPaneState extends State<InboxPane> {
  late Future<List<PendingActionEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadInbox();
  }

  @override
  void didUpdateWidget(covariant InboxPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hosts != widget.hosts) {
      _future = _loadInbox();
    }
  }

  Future<List<PendingActionEntry>> _loadInbox() async {
    final results = await Future.wait(
      widget.hosts.map((host) async {
        try {
          final actions = await widget.api.fetchPendingActions(host);
          return actions
              .map((action) => PendingActionEntry(host: host, action: action))
              .toList();
        } catch (_) {
          return const <PendingActionEntry>[];
        }
      }),
    );

    final merged = results.expand((entries) => entries).toList();
    merged.sort(
      (left, right) =>
          right.action.requestedAt.compareTo(left.action.requestedAt),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onInboxCountChanged(merged.length);
    });
    return merged;
  }

  Future<void> _refresh() async {
    setState(() => _future = _loadInbox());
    await _future;
  }

  Future<void> _respond(
    HostProfile host,
    PendingAction action,
    String decision,
  ) async {
    try {
      await widget.api.respondToAction(
        host,
        actionId: action.id,
        decision: decision,
      );
      if (!mounted) {
        return;
      }
      await _refresh();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resolve action: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (widget.hosts.isEmpty) {
      return const MeshEmptyState(
        icon: Icons.all_inbox_rounded,
        title: 'Inbox is empty',
        body:
            'Add a host first. Pending approvals from every machine will show up here.',
      );
    }

    return FutureBuilder<List<PendingActionEntry>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const MeshLoader();
        }

        final allEntries = snapshot.data ?? const [];
        final query = widget.query.trim().toLowerCase();
        final entries = query.isEmpty
            ? allEntries
            : allEntries.where((entry) {
                final a = entry.action;
                return (a.sessionTitle ?? '').toLowerCase().contains(query) ||
                    a.detail.toLowerCase().contains(query) ||
                    (a.cwd ?? '').toLowerCase().contains(query) ||
                    entry.host.label.toLowerCase().contains(query);
              }).toList();
        if (entries.isEmpty) {
          return RefreshIndicator(
            color: colors.accent,
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 80),
                if (query.isNotEmpty)
                  MeshEmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'No matches',
                    body:
                        'No pending actions match "${widget.query.trim()}".',
                  )
                else
                  const MeshEmptyState(
                    icon: Icons.verified_rounded,
                    title: 'No pending approvals',
                    body:
                        'Command, file, and permission prompts from your Codex nodes will appear here.',
                  ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          color: colors.accent,
          onRefresh: _refresh,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _InboxCard(
                entry: entry,
                onOpenSession: () =>
                    widget.onOpenSession(entry.host, entry.action),
                onRespond: (decision) =>
                    _respond(entry.host, entry.action, decision),
              );
            },
          ),
        );
      },
    );
  }
}

class _InboxCard extends StatelessWidget {
  const _InboxCard({
    required this.entry,
    required this.onOpenSession,
    required this.onRespond,
  });

  final PendingActionEntry entry;
  final VoidCallback onOpenSession;
  final ValueChanged<String> onRespond;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final action = entry.action;
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: colors.warning.withValues(alpha: 0.35),
      accentStrip: colors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  action.title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              MeshPill(
                label: _actionKindLabel(action.kind),
                tone: MeshPillTone.warning,
                mono: true,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.dns_rounded, size: 13, color: colors.textTertiary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '${entry.host.label}  •  ${action.sessionTitle ?? action.sessionId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
              ),
            ],
          ),
          if ((action.cwd ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              action.cwd!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textTertiary, fontSize: 11.5),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            action.detail,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onOpenSession,
                icon: const Icon(Icons.forum_outlined, size: 18),
                label: const Text('Open session'),
              ),
              if (action.canApprove)
                FilledButton.icon(
                  onPressed: () => onRespond('accept'),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Approve'),
                ),
              if (action.canApproveForSession)
                OutlinedButton(
                  onPressed: () => onRespond('acceptForSession'),
                  child: const Text('Approve for session'),
                ),
              if (action.canDecline)
                OutlinedButton.icon(
                  onPressed: () => onRespond('decline'),
                  icon: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: colors.danger,
                  ),
                  label: Text(
                    'Decline',
                    style: TextStyle(color: colors.danger),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: colors.danger.withValues(alpha: 0.5),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _actionKindLabel(String kind) {
  return switch (kind) {
    'command' => 'command',
    'file_change' => 'files',
    'permissions' => 'permissions',
    _ => kind,
  };
}

class HostsPane extends StatelessWidget {
  const HostsPane({
    super.key,
    required this.hosts,
    required this.onOpenHost,
    required this.onEditHost,
    required this.onRemoveHost,
    required this.onAddHost,
    this.query = '',
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onOpenHost;
  final ValueChanged<HostProfile> onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;
  final VoidCallback onAddHost;
  final String query;

  @override
  Widget build(BuildContext context) {
    if (hosts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MeshEmptyState(
                icon: Icons.route_rounded,
                title: 'No hosts yet',
                body:
                    'Add a MacBook or VPS node by pasting its Tailscale address and shared token.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onAddHost,
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Add your first host'),
              ),
            ],
          ),
        ),
      );
    }

    final q = query.trim().toLowerCase();
    final visibleHosts = q.isEmpty
        ? hosts
        : hosts
              .where(
                (h) =>
                    h.label.toLowerCase().contains(q) ||
                    h.baseUrl.toLowerCase().contains(q),
              )
              .toList();
    if (visibleHosts.isEmpty) {
      return MeshEmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matching hosts',
        body: 'No hosts match "${query.trim()}".',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      itemCount: visibleHosts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final host = visibleHosts[index];
        return _HostRowCard(
          host: host,
          onTap: () => onOpenHost(host),
          onEdit: () => onEditHost(host),
          onRemove: () => onRemoveHost(host),
        );
      },
    );
  }
}

class _HostRowCard extends StatelessWidget {
  const _HostRowCard({
    required this.host,
    required this.onTap,
    required this.onEdit,
    required this.onRemove,
  });

  final HostProfile host;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.dns_rounded, color: colors.accent, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  host.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Edit host',
            onPressed: onEdit,
            icon: Icon(
              Icons.edit_outlined,
              size: 20,
              color: colors.textSecondary,
            ),
          ),
          IconButton(
            tooltip: 'Remove host',
            onPressed: onRemove,
            icon: Icon(
              Icons.delete_outline,
              size: 20,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class HostEditorSheet extends StatefulWidget {
  const HostEditorSheet({super.key, this.initialHost});

  final HostProfile? initialHost;

  @override
  State<HostEditorSheet> createState() => _HostEditorSheetState();
}

class _HostEditorSheetState extends State<HostEditorSheet> {
  late final TextEditingController _labelController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(
      text: widget.initialHost?.label ?? '',
    );
    _baseUrlController = TextEditingController(
      text: widget.initialHost?.baseUrl ?? '',
    );
    _tokenController = TextEditingController(
      text: widget.initialHost?.token ?? '',
    );
  }

  @override
  void dispose() {
    _labelController.dispose();
    _baseUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final isEditing = widget.initialHost != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.accentMuted,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    isEditing ? Icons.edit_rounded : Icons.add_link_rounded,
                    color: colors.accent,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  isEditing ? 'Edit host' : 'Add host',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'MacBook or VPS-1',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'http://macbook.tailnet.ts.net:8787',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(labelText: 'Shared token'),
            ),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () {
                  final label = _labelController.text.trim();
                  final baseUrl = normalizeBaseUrl(_baseUrlController.text);
                  final token = _tokenController.text.trim();
                  if (label.isEmpty || baseUrl.isEmpty || token.isEmpty) {
                    return;
                  }
                  Navigator.of(context).pop(
                    HostProfile(
                      id: widget.initialHost?.id ?? _randomId(),
                      label: label,
                      baseUrl: baseUrl,
                      token: token,
                    ),
                  );
                },
                icon: const Icon(Icons.check_rounded),
                label: Text(isEditing ? 'Save changes' : 'Save host'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RemoteSessionEntry {
  const RemoteSessionEntry({required this.host, required this.session});

  final HostProfile host;
  final SessionSummary session;
}

class PendingActionEntry {
  const PendingActionEntry({required this.host, required this.action});

  final HostProfile host;
  final PendingAction action;
}

String _randomId() {
  final random = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(
    12,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

class _RecentLoadResult {
  const _RecentLoadResult({required this.entries, required this.failedHosts});
  const _RecentLoadResult.empty()
    : entries = const [],
      failedHosts = const [];

  final List<RemoteSessionEntry> entries;
  final List<String> failedHosts;
}

class _RecentErrorBanner extends StatelessWidget {
  const _RecentErrorBanner({
    required this.hostLabels,
    required this.onRetry,
  });

  final List<String> hostLabels;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final summary = hostLabels.length == 1
        ? '${hostLabels.first} is unreachable.'
        : '${hostLabels.length} hosts are unreachable: ${hostLabels.join(', ')}.';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: colors.warningMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: colors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              summary,
              style: TextStyle(
                color: colors.warning,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: colors.warning,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              visualDensity: VisualDensity.compact,
              textStyle: const TextStyle(fontWeight: FontWeight.w700),
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
