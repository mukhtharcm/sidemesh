import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../approval_inbox_store.dart';
import '../host_status_store.dart';
import '../host_store.dart';
import '../models.dart';
import '../session_favorites_store.dart';
import '../session_overrides_store.dart';
import '../session_read_store.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/appearance_sheet.dart';
import '../widgets/mesh_widgets.dart';
import 'create_session_sheet.dart';
import 'host_detail_screen.dart';
import 'session_screen.dart';

class SidemeshHomeScreen extends StatefulWidget {
  const SidemeshHomeScreen({super.key});

  @override
  State<SidemeshHomeScreen> createState() => _SidemeshHomeScreenState();
}

class _SidemeshHomeScreenState extends State<SidemeshHomeScreen>
    with WidgetsBindingObserver {
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
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  Timer? _heartbeatTimer;
  bool _heartbeatInFlight = false;
  static const Duration _heartbeatInterval = Duration(seconds: 45);
  List<HostProfile> _hosts = const [];
  bool _loading = true;
  int _tabIndex = 0;
  int _activeCount = 0;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshHosts();
    _searchController.addListener(() {
      final next = _searchController.text;
      _searchDebounce?.cancel();
      if (next.isEmpty) {
        if (_query.isNotEmpty) setState(() => _query = '');
        return;
      }
      _searchDebounce = Timer(const Duration(milliseconds: 140), () {
        if (!mounted) return;
        if (next == _query) return;
        setState(() => _query = next);
      });
    });
    _startHeartbeat();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchDebounce?.cancel();
    _heartbeatTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Kick an immediate probe on foreground so the dots reflect reality
      // before the next scheduled tick.
      _startHeartbeat();
      unawaited(_runHeartbeat());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => unawaited(_runHeartbeat()),
    );
  }

  Future<void> _runHeartbeat() async {
    if (_heartbeatInFlight || _hosts.isEmpty) return;
    _heartbeatInFlight = true;
    try {
      final store = HostStatusStore.instance;
      await Future.wait(
        _hosts.map((host) async {
          try {
            await _api.fetchNode(host);
            store.markOnline(host.id);
          } catch (error) {
            store.markOffline(host.id, error: friendlyError(error));
          }
        }),
        eagerError: false,
      );
    } finally {
      _heartbeatInFlight = false;
    }
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
    ApprovalInboxStore.instance.configure(hosts: hosts, api: _api);
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
        builder: (context) => SessionScreen(
          host: host,
          session: session,
          api: _api,
          onOpenSession: (next) => unawaited(_openSession(host, next)),
        ),
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

  Future<void> _startSessionFromHome() async {
    if (_hosts.isEmpty) {
      await _showHostEditor();
      return;
    }
    final result = await showCreateSessionHostLauncher(
      context,
      hosts: _hosts,
      api: _api,
    );
    if (!mounted || result == null) {
      return;
    }
    await _openSession(result.host, result.session);
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
      gitInfo: null,
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
            _TopBar(
              tab: tab,
              onRefresh: _refreshHosts,
              onStartSession: _startSessionFromHome,
            ),
            _HomeSearchBar(
              controller: _searchController,
              hintText: 'Search ${tab.title.toLowerCase()}',
            ),
            Expanded(
              child: _loading
                  ? const MeshLoader()
                  : IndexedStack(
                      index: _tabIndex,
                      children: [
                        RecentPane(
                          hosts: _hosts,
                          api: _api,
                          query: _query,
                          onOpenSession: _openSession,
                          onActiveCountChanged: (count) {
                            if (!mounted) return;
                            setState(() => _activeCount = count);
                          },
                        ),
                        InboxPane(
                          hosts: _hosts,
                          api: _api,
                          query: _query,
                          onOpenSession: (host, action) =>
                              _openSession(host, _sessionFromAction(action)),
                          onInboxCountChanged: (_) {},
                        ),
                        HostsPane(
                          hosts: _hosts,
                          query: _query,
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
      bottomNavigationBar: ListenableBuilder(
        listenable: ApprovalInboxStore.instance,
        builder: (context, _) => _MeshNavBar(
          tabs: _tabs,
          currentIndex: _tabIndex,
          onTap: (index) => setState(() => _tabIndex = index),
          badges: [_activeCount, ApprovalInboxStore.instance.count, 0],
        ),
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
  const _TopBar({
    required this.tab,
    required this.onRefresh,
    required this.onStartSession,
  });

  final _TabDef tab;
  final VoidCallback onRefresh;
  final VoidCallback onStartSession;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final controller = ThemeScope.of(context);
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
            icon: Icons.terminal_rounded,
            tooltip: 'New session',
            onTap: onStartSession,
          ),
          const SizedBox(width: 8),
          MeshIconButton(
            icon: switch (controller.mode) {
              ThemeMode.dark => Icons.dark_mode_rounded,
              ThemeMode.light => Icons.light_mode_rounded,
              ThemeMode.system => Icons.brightness_auto_rounded,
            },
            tooltip: 'Appearance',
            onTap: () => showAppearanceSheet(context),
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
    this.dense = false,
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final void Function(HostProfile host, SessionSummary session) onOpenSession;
  final ValueChanged<int> onActiveCountChanged;
  final String query;
  final String? selectedSessionId;
  final EdgeInsets? padding;
  final bool dense;

  @override
  State<RecentPane> createState() => _RecentPaneState();
}

bool _sameHostIds(List<HostProfile> a, List<HostProfile> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

class _RecentPaneState extends State<RecentPane> {
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;
  final HostStatusStore _statuses = HostStatusStore.instance;
  // Progressive load state: entries stream in per-host as each fetch
  // resolves rather than blocking on Future.wait(all).
  List<RemoteSessionEntry> _entries = const [];
  Set<String> _pendingHostIds = <String>{};
  List<String> _failedHostLabels = const [];
  int _loadGen = 0;
  bool _initialLoadStarted = false;
  Timer? _refreshTimer;
  static const Duration _refreshInterval = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _favorites.ensureLoaded();
    SessionReadStore.instance.ensureLoaded();
    _kickoffLoad();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RecentPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameHostIds(oldWidget.hosts, widget.hosts)) {
      _kickoffLoad();
    }
  }

  void _kickoffLoad() {
    final gen = ++_loadGen;
    _initialLoadStarted = true;
    setState(() {
      _entries = const [];
      _pendingHostIds = widget.hosts.map((h) => h.id).toSet();
      _failedHostLabels = const [];
    });
    for (final host in widget.hosts) {
      _statuses.markProbing(host.id);
      _loadHost(host, gen);
    }
    if (widget.hosts.isEmpty) {
      // Emit zero active so the nav badge clears immediately.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onActiveCountChanged(0);
      });
    }
  }

  Future<void> _silentRefresh() async {
    if (!mounted || widget.hosts.isEmpty) return;
    // Fetch per host without tearing down the current list. Merge fresh
    // entries by (host, session) so the unread store sees new updatedAt
    // values even when the user hasn't pulled-to-refresh.
    final hosts = widget.hosts.toList();
    final fetches = await Future.wait(
      hosts.map<Future<List<SessionSummary>?>>((host) async {
        try {
          return await widget.api.fetchSessions(host, limit: 40);
        } catch (_) {
          return null;
        }
      }),
      eagerError: false,
    );
    if (!mounted) return;
    final merged = <RemoteSessionEntry>[];
    final handled = <String>{};
    for (var i = 0; i < hosts.length; i++) {
      final host = hosts[i];
      final fresh = fetches[i];
      if (fresh == null) {
        // Fetch failed — keep whatever we had for this host.
        merged.addAll(_entries.where((e) => e.host.id == host.id));
        handled.add(host.id);
        continue;
      }
      for (final session in fresh.take(20)) {
        merged.add(RemoteSessionEntry(host: host, session: session));
      }
      handled.add(host.id);
    }
    // Preserve entries from hosts no longer in widget.hosts (rare) just
    // in case — they'll fall off the next kickoff.
    for (final entry in _entries) {
      if (!handled.contains(entry.host.id)) {
        merged.add(entry);
      }
    }
    setState(() {
      _entries = merged;
    });
    _emitActiveCount();
  }

  Future<void> _loadHost(HostProfile host, int gen) async {
    try {
      final sessions = await widget.api.fetchSessions(host, limit: 40);
      if (!mounted || gen != _loadGen) return;
      _statuses.markOnline(host.id);
      final newEntries = sessions
          .take(20)
          .map((session) => RemoteSessionEntry(host: host, session: session))
          .toList();
      setState(() {
        _entries = [..._entries, ...newEntries];
        _pendingHostIds = {..._pendingHostIds}..remove(host.id);
      });
      _emitActiveCount();
    } catch (error) {
      if (!mounted || gen != _loadGen) return;
      _statuses.markOffline(host.id, error: friendlyError(error));
      setState(() {
        _failedHostLabels = [..._failedHostLabels, host.label];
        _pendingHostIds = {..._pendingHostIds}..remove(host.id);
      });
      _emitActiveCount();
    }
  }

  void _emitActiveCount() {
    final count = _entries.where((e) => e.session.isActive).length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onActiveCountChanged(count);
    });
  }

  List<RemoteSessionEntry> _sortEntries(List<RemoteSessionEntry> entries) {
    final overrides = SessionOverridesStore.instance;
    final overlaid = entries
        .map(
          (entry) => RemoteSessionEntry(
            host: entry.host,
            session: overrides.overlay(entry.host.id, entry.session),
          ),
        )
        .toList();
    final query = widget.query.trim().toLowerCase();
    Iterable<RemoteSessionEntry> visible = overlaid;
    if (query.isNotEmpty) {
      visible = overlaid.where((entry) {
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

    final stillLoadingInitial =
        _initialLoadStarted &&
        _entries.isEmpty &&
        _failedHostLabels.isEmpty &&
        _pendingHostIds.isNotEmpty;

    if (stillLoadingInitial) {
      return const MeshLoader();
    }

    return ListenableBuilder(
      listenable: Listenable.merge([
        _favorites,
        _statuses,
        SessionOverridesStore.instance,
      ]),
      builder: (context, _) {
        final sortedEntries = _sortEntries(_entries);
        final isRefreshing = _pendingHostIds.isNotEmpty;
        final hasFailures = _failedHostLabels.isNotEmpty;
        final noResults = sortedEntries.isEmpty;
        final basePadding =
            widget.padding ??
            (widget.dense
                ? const EdgeInsets.fromLTRB(6, 4, 6, 24)
                : const EdgeInsets.fromLTRB(16, 8, 16, 32));
        Future<void> handleRefresh() async {
          _kickoffLoad();
        }

        if (noResults) {
          return RefreshIndicator(
            color: context.colors.accent,
            onRefresh: handleRefresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (isRefreshing)
                  _RecentProgressStrip(
                    remaining: _pendingHostIds.length,
                    total: widget.hosts.length,
                  ),
                if (hasFailures)
                  _RecentErrorBanner(
                    hostLabels: _failedHostLabels,
                    onRetry: handleRefresh,
                  ),
                const SizedBox(height: 80),
                MeshEmptyState(
                  icon: widget.query.trim().isEmpty
                      ? Icons.cloud_off_rounded
                      : Icons.search_off_rounded,
                  title: widget.query.trim().isEmpty
                      ? 'No reachable sessions'
                      : 'No matches',
                  body: widget.query.trim().isEmpty
                      ? 'Saved hosts look fine, but none returned recent sessions right now.'
                      : 'No sessions match "${widget.query.trim()}". Clear the filter to see everything.',
                ),
              ],
            ),
          );
        }
        final leadingStrips = (isRefreshing ? 1 : 0) + (hasFailures ? 1 : 0);
        return RefreshIndicator(
          color: context.colors.accent,
          onRefresh: handleRefresh,
          child: ListView.separated(
            padding: basePadding,
            itemCount: sortedEntries.length + leadingStrips,
            separatorBuilder: (_, _) => SizedBox(height: widget.dense ? 2 : 10),
            itemBuilder: (context, index) {
              var offset = 0;
              if (isRefreshing) {
                if (index == offset) {
                  return _RecentProgressStrip(
                    remaining: _pendingHostIds.length,
                    total: widget.hosts.length,
                  );
                }
                offset += 1;
              }
              if (hasFailures) {
                if (index == offset) {
                  return _RecentErrorBanner(
                    hostLabels: _failedHostLabels,
                    onRetry: handleRefresh,
                  );
                }
                offset += 1;
              }
              final entry = sortedEntries[index - offset];
              return _SessionRowCard(
                host: entry.host,
                session: entry.session,
                favorite: _favorites.isFavorite(entry.host, entry.session.id),
                selected: widget.selectedSessionId == entry.session.id,
                dense: widget.dense,
                onTap: () => widget.onOpenSession(entry.host, entry.session),
                onToggleFavorite: () {
                  _favorites.toggleFavorite(entry.host, entry.session.id);
                },
              );
            },
          ),
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
    this.dense = false,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool favorite;
  final bool selected;
  final bool dense;
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
      // Compact variant used in the desktop sidebar. Uses a plain
      // InkWell + tinted fill for selection rather than the old accent
      // strip — closer to modern macOS sidebars (Raycast/Linear).
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
                  child: running
                      ? _RunningDot(color: colors.success)
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
                      Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                          color: selected ? colors.accent : colors.textPrimary,
                        ),
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
    return MeshCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      accentStrip: running ? colors.success : (selected ? colors.accent : null),
      borderColor: selected ? colors.accent : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running) ...[
                _RunningDot(color: colors.success),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: unread ? FontWeight.w800 : FontWeight.w700,
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
    this.dense = false,
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final void Function(HostProfile host, PendingAction action) onOpenSession;
  final ValueChanged<int> onInboxCountChanged;
  final String query;
  final bool dense;

  @override
  State<InboxPane> createState() => _InboxPaneState();
}

class _InboxPaneState extends State<InboxPane> {
  final ApprovalInboxStore _store = ApprovalInboxStore.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _store.configure(hosts: widget.hosts, api: widget.api);
    _emitCount();
  }

  @override
  void didUpdateWidget(covariant InboxPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameHostIds(oldWidget.hosts, widget.hosts)) {
      _store.configure(hosts: widget.hosts, api: widget.api);
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
    _emitCount();
  }

  void _emitCount() {
    final count = _store.count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onInboxCountChanged(count);
    });
  }

  Future<void> _refresh() => _store.refresh();

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
      if (!mounted) return;
      // Optimistically drop the entry so the list feels responsive; the
      // background poll will reconcile within a few seconds.
      _store.removeEntry(action.id);
      unawaited(_store.refresh());
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Failed to resolve action: ${friendlyError(error)}',
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

    final stillLoadingInitial = !_store.hasLoadedOnce && _store.isLoading;
    if (stillLoadingInitial) {
      return const MeshLoader();
    }

    final query = widget.query.trim().toLowerCase();
    final allEntries = _store.entries;
    final entries = query.isEmpty
        ? allEntries
        : allEntries.where((entry) {
            final a = entry.action;
            return (a.sessionTitle ?? '').toLowerCase().contains(query) ||
                a.detail.toLowerCase().contains(query) ||
                (a.cwd ?? '').toLowerCase().contains(query) ||
                entry.host.label.toLowerCase().contains(query);
          }).toList();

    final isRefreshing = _store.isLoading;
    final hasFailures = _store.failedHostLabels.isNotEmpty;

    if (entries.isEmpty) {
      return RefreshIndicator(
        color: colors.accent,
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (isRefreshing)
              _RecentProgressStrip(
                remaining: _store.pendingHostsRemaining,
                total: _store.totalHosts,
              ),
            if (hasFailures)
              _RecentErrorBanner(
                hostLabels: _store.failedHostLabels,
                onRetry: _refresh,
              ),
            const SizedBox(height: 80),
            if (query.isNotEmpty)
              MeshEmptyState(
                icon: Icons.search_off_rounded,
                title: 'No matches',
                body: 'No pending actions match "${widget.query.trim()}".',
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

    final leadingStrips = (isRefreshing ? 1 : 0) + (hasFailures ? 1 : 0);
    return RefreshIndicator(
      color: colors.accent,
      onRefresh: _refresh,
      child: ListView.separated(
        padding: widget.dense
            ? const EdgeInsets.fromLTRB(8, 4, 8, 24)
            : const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: entries.length + leadingStrips,
        separatorBuilder: (_, _) => SizedBox(height: widget.dense ? 4 : 10),
        itemBuilder: (context, index) {
          var offset = 0;
          if (isRefreshing) {
            if (index == offset) {
              return _RecentProgressStrip(
                remaining: _store.pendingHostsRemaining,
                total: _store.totalHosts,
              );
            }
            offset += 1;
          }
          if (hasFailures) {
            if (index == offset) {
              return _RecentErrorBanner(
                hostLabels: _store.failedHostLabels,
                onRetry: _refresh,
              );
            }
            offset += 1;
          }
          final entry = entries[index - offset];
          return _InboxCard(
            entry: entry,
            dense: widget.dense,
            onOpenSession: () => widget.onOpenSession(entry.host, entry.action),
            onRespond: (decision) =>
                _respond(entry.host, entry.action, decision),
          );
        },
      ),
    );
  }
}

class _InboxCard extends StatelessWidget {
  const _InboxCard({
    required this.entry,
    required this.onOpenSession,
    required this.onRespond,
    this.dense = false,
  });

  final PendingActionEntry entry;
  final VoidCallback onOpenSession;
  final ValueChanged<String> onRespond;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final action = entry.action;
    if (dense) {
      // Compact row for the desktop sidebar — tap the row to open the
      // session; inline ✓/✕ buttons let the user resolve without leaving
      // the sidebar. Long-press on approve surfaces "approve for session".
      return Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpenSession,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 6, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colors.warning,
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
                              action.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    height: 1.25,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          MeshPill(
                            label: _actionKindLabel(action.kind),
                            tone: MeshPillTone.warning,
                            mono: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${entry.host.label} · ${action.sessionTitle ?? action.sessionId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                _InboxDenseActions(action: action, onRespond: onRespond),
              ],
            ),
          ),
        ),
      );
    }
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: colors.warning.withValues(alpha: 0.35),
      accentStrip: colors.warning,
      onTap: onOpenSession,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  action.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.25,
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
          const SizedBox(height: 6),
          Text(
            '${entry.host.label} · ${action.sessionTitle ?? action.sessionId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(color: colors.textTertiary, fontSize: 11),
          ),
          if (action.detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              action.detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (action.canApproveForSession)
                _MobileInboxAction(
                  icon: Icons.history_toggle_off_rounded,
                  tooltip: 'Approve for session',
                  foreground: colors.textSecondary,
                  background: colors.surfaceMuted,
                  onTap: () => onRespond('acceptForSession'),
                ),
              if (action.canDecline) ...[
                if (action.canApproveForSession) const SizedBox(width: 8),
                _MobileInboxAction(
                  icon: Icons.close_rounded,
                  tooltip: 'Decline',
                  foreground: colors.danger,
                  background: colors.danger.withValues(alpha: 0.12),
                  onTap: () => onRespond('decline'),
                ),
              ],
              if (action.canApprove) ...[
                const SizedBox(width: 8),
                _MobileInboxAction(
                  icon: Icons.check_rounded,
                  tooltip: 'Approve',
                  foreground: Colors.white,
                  background: colors.success,
                  onTap: () => onRespond('accept'),
                ),
              ],
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

/// Compact approve/decline cluster used by the dense inbox rows in the
/// desktop sidebar so users can resolve pending actions without having
/// to open the chat.
class _InboxDenseActions extends StatelessWidget {
  const _InboxDenseActions({required this.action, required this.onRespond});

  final PendingAction action;
  final ValueChanged<String> onRespond;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final canExtended = action.canApproveForSession;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (action.canApprove)
          _SquareIconAction(
            icon: Icons.check_rounded,
            tooltip: canExtended ? 'Approve (right-click for more)' : 'Approve',
            foreground: colors.success,
            background: colors.success.withValues(alpha: 0.12),
            onTap: () => onRespond('accept'),
            onSecondaryTap: canExtended
                ? (pos) => _showExtendedMenu(context, pos)
                : null,
          ),
        if (action.canDecline) ...[
          const SizedBox(width: 4),
          _SquareIconAction(
            icon: Icons.close_rounded,
            tooltip: 'Decline',
            foreground: colors.danger,
            background: colors.danger.withValues(alpha: 0.12),
            onTap: () => onRespond('decline'),
          ),
        ],
      ],
    );
  }

  Future<void> _showExtendedMenu(BuildContext context, Offset globalPos) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        globalPos.dx,
        globalPos.dy,
      ),
      items: const [
        PopupMenuItem(value: 'accept', child: Text('Approve once')),
        PopupMenuItem(
          value: 'acceptForSession',
          child: Text('Approve for session'),
        ),
      ],
    );
    if (result != null) onRespond(result);
  }
}

class _SquareIconAction extends StatelessWidget {
  const _SquareIconAction({
    required this.icon,
    required this.tooltip,
    required this.foreground,
    required this.background,
    required this.onTap,
    this.onSecondaryTap,
  });

  final IconData icon;
  final String tooltip;
  final Color foreground;
  final Color background;
  final VoidCallback onTap;
  final void Function(Offset globalPos)? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          onSecondaryTapDown: onSecondaryTap == null
              ? null
              : (details) => onSecondaryTap!(details.globalPosition),
          child: SizedBox(
            width: 26,
            height: 26,
            child: Icon(icon, size: 16, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// Touch-sized inline action button for the mobile inbox cards — same
/// square vibe as the desktop `_SquareIconAction` but with a larger hit
/// target suitable for fingers.
class _MobileInboxAction extends StatelessWidget {
  const _MobileInboxAction({
    required this.icon,
    required this.tooltip,
    required this.foreground,
    required this.background,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color foreground;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(icon, size: 22, color: foreground),
          ),
        ),
      ),
    );
  }
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
    this.dense = false,
    this.selectedHostId,
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onOpenHost;
  final ValueChanged<HostProfile> onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;
  final VoidCallback onAddHost;
  final String query;
  final bool dense;
  final String? selectedHostId;

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
      padding: dense
          ? const EdgeInsets.fromLTRB(6, 4, 6, 24)
          : const EdgeInsets.fromLTRB(16, 8, 16, 120),
      itemCount: visibleHosts.length,
      separatorBuilder: (_, _) => SizedBox(height: dense ? 2 : 10),
      itemBuilder: (context, index) {
        final host = visibleHosts[index];
        return _HostRowCard(
          host: host,
          dense: dense,
          selected: dense && selectedHostId == host.id,
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
    this.dense = false,
    this.selected = false,
  });

  final HostProfile host;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final bool dense;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListenableBuilder(
      listenable: HostStatusStore.instance,
      builder: (context, _) {
        final status = HostStatusStore.instance.statusFor(host.id);
        if (dense) {
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.fromLTRB(10, 9, 6, 10),
                decoration: BoxDecoration(
                  color: selected ? colors.accentMuted : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected
                        ? colors.accent.withValues(alpha: 0.35)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: colors.accentMuted,
                            borderRadius: BorderRadius.circular(9),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.dns_rounded,
                            color: colors.accent,
                            size: 15,
                          ),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: _HostStatusDot(status: status),
                        ),
                      ],
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
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  height: 1.25,
                                  color: selected ? colors.accent : null,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            host.baseUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(
                              color: colors.textTertiary,
                              fontSize: 10.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    InkWell(
                      onTap: onEdit,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: colors.textTertiary,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: onRemove,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.delete_outline,
                          size: 14,
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
        return MeshCard(
          onTap: onTap,
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
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
                    child: Icon(
                      Icons.dns_rounded,
                      color: colors.accent,
                      size: 20,
                    ),
                  ),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: _HostStatusDot(status: status),
                  ),
                ],
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
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                    if (status.reachability != HostReachability.unknown) ...[
                      const SizedBox(height: 4),
                      Text(
                        _statusLine(status),
                        style: monoStyle(
                          color: _statusColor(colors, status),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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
      },
    );
  }

  String _statusLine(HostStatus status) {
    switch (status.reachability) {
      case HostReachability.online:
        return 'Online';
      case HostReachability.offline:
        final err = status.lastError;
        return err == null || err.isEmpty ? 'Offline' : 'Offline · $err';
      case HostReachability.probing:
        return 'Probing…';
      case HostReachability.unknown:
        return '';
    }
  }

  Color _statusColor(AppColors colors, HostStatus status) {
    switch (status.reachability) {
      case HostReachability.online:
        return colors.success;
      case HostReachability.offline:
        return colors.danger;
      case HostReachability.probing:
        return colors.textSecondary;
      case HostReachability.unknown:
        return colors.textTertiary;
    }
  }
}

class _HostStatusDot extends StatelessWidget {
  const _HostStatusDot({required this.status});

  final HostStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final Color fill;
    switch (status.reachability) {
      case HostReachability.online:
        fill = colors.success;
        break;
      case HostReachability.offline:
        fill = colors.danger;
        break;
      case HostReachability.probing:
        fill = colors.warning;
        break;
      case HostReachability.unknown:
        fill = colors.textTertiary;
        break;
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: colors.canvas, width: 2),
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

String _randomId() {
  final random = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(
    12,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

class _RecentProgressStrip extends StatelessWidget {
  const _RecentProgressStrip({required this.remaining, required this.total});

  final int remaining;
  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final loaded = (total - remaining).clamp(0, total);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: colors.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Loading hosts · $loaded of $total ready',
              style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentErrorBanner extends StatelessWidget {
  const _RecentErrorBanner({required this.hostLabels, required this.onRetry});

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

class _HomeSearchBar extends StatelessWidget {
  const _HomeSearchBar({required this.controller, required this.hintText});

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final hasQuery = controller.text.isNotEmpty;
          return TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            style: TextStyle(color: colors.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: colors.surface,
              hintText: hintText,
              hintStyle: TextStyle(color: colors.textTertiary, fontSize: 14),
              prefixIcon: Icon(
                Icons.search_rounded,
                size: 18,
                color: colors.textSecondary,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 36,
                minHeight: 36,
              ),
              suffixIcon: hasQuery
                  ? IconButton(
                      tooltip: 'Clear',
                      splashRadius: 16,
                      iconSize: 16,
                      onPressed: controller.clear,
                      icon: Icon(
                        Icons.close_rounded,
                        color: colors.textSecondary,
                      ),
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: colors.accent, width: 1.2),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _RunningDot extends StatefulWidget {
  const _RunningDot({required this.color});

  final Color color;

  @override
  State<_RunningDot> createState() => _RunningDotState();
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

class _RunningDotState extends State<_RunningDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.35 + 0.35 * t),
                blurRadius: 4 + 4 * t,
                spreadRadius: 0.5 + 1.2 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}
