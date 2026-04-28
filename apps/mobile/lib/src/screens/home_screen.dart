import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../approval_inbox_store.dart';
import '../host_status_store.dart';
import '../host_store.dart';
import '../live_activity_service.dart';
import '../local_notification_service.dart';
import '../models.dart';
import '../pending_send_recovery.dart';
import '../recent_sessions_live_store.dart';
import '../screen_awake_controller.dart';
import '../session_favorites_store.dart';
import '../session_cache_store.dart';
import '../session_overrides_store.dart';
import '../session_read_store.dart';
import '../session_runtime.dart';
import '../session_send_outbox_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/notification_permission_banner.dart';
import 'create_session_sheet.dart';
import 'host_detail_screen.dart';
import 'settings_screen.dart';
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
      subtitle: 'Your mesh of agent nodes',
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
  int _inboxCount = 0;
  String _query = '';
  bool _handlingNotificationIntent = false;

  List<HostProfile> get _enabledHosts =>
      _hosts.where((host) => host.enabled).toList(growable: false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LocalNotificationService.instance.routeIntent.addListener(
      _onNotificationRouteIntent,
    );
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
    LocalNotificationService.instance.routeIntent.removeListener(
      _onNotificationRouteIntent,
    );
    _searchDebounce?.cancel();
    _stopHeartbeat();
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
      _stopHeartbeat();
    }
  }

  void _startHeartbeat() {
    if (_enabledHosts.isEmpty) {
      _stopHeartbeat();
      return;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      _heartbeatInterval,
      (_) => unawaited(_runHeartbeat()),
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _runHeartbeat() async {
    final hosts = _enabledHosts;
    if (_heartbeatInFlight || hosts.isEmpty) return;
    _heartbeatInFlight = true;
    try {
      final store = HostStatusStore.instance;
      await Future.wait(
        hosts.map((host) async {
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
    for (final host in hosts) {
      if (!host.enabled) {
        HostStatusStore.instance.clear(host.id);
      }
    }
    ApprovalInboxStore.instance.configure(hosts: _enabledHosts, api: _api);
    _startHeartbeat();
    unawaited(_handleNotificationRouteIntent());
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
    final previousHost = exists
        ? _hosts.firstWhere((item) => item.id == result.id)
        : null;
    final updated = exists
        ? _hosts.map((item) => item.id == result.id ? result : item).toList()
        : [..._hosts, result];
    if (previousHost != null &&
        (previousHost.baseUrl != result.baseUrl ||
            previousHost.token != result.token)) {
      await SessionCacheStore.instance.clearHost(previousHost);
    }
    await _store.saveHosts(updated);
    await _refreshHosts();
  }

  Future<void> _removeHost(HostProfile host) async {
    final updated = _hosts.where((item) => item.id != host.id).toList();
    await SessionCacheStore.instance.clearHost(host);
    await _store.saveHosts(updated);
    await _refreshHosts();
  }

  Future<void> _toggleHostEnabled(HostProfile host) async {
    final disabling = host.enabled;
    final updated = _hosts
        .map(
          (item) =>
              item.id == host.id ? item.copyWith(enabled: !item.enabled) : item,
        )
        .toList();
    await _store.saveHosts(updated);
    if (disabling) {
      HostStatusStore.instance.clear(host.id);
      await LiveActivityService.instance.clearPrimarySessionForHost(host.id);
    }
    await _refreshHosts();
  }

  Future<void> _openSession(
    HostProfile host,
    SessionSummary session, {
    SessionComposerSeed? composerSeed,
  }) async {
    if (!host.enabled) {
      showAppSnackBar(context, 'Enable ${host.label} before opening sessions.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SessionScreen(
          host: host,
          session: session,
          api: _api,
          initialComposerSeed: composerSeed,
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
    if (!host.enabled) {
      showAppSnackBar(context, 'Enable ${host.label} before opening details.');
      return;
    }
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
    final enabledHosts = _enabledHosts;
    if (enabledHosts.isEmpty) {
      showAppSnackBar(context, 'Enable a host before starting a session.');
      return;
    }
    final result = await showCreateSessionHostLauncher(
      context,
      hosts: enabledHosts,
      api: _api,
    );
    if (!mounted || result == null) {
      return;
    }
    await _openSession(result.host, result.session);
  }

  void _openSettings() {
    unawaited(openSettingsScreen(context));
  }

  void _onNotificationRouteIntent() {
    unawaited(_handleNotificationRouteIntent());
  }

  Future<void> _handleNotificationRouteIntent() async {
    if (_handlingNotificationIntent || _loading) return;
    final service = LocalNotificationService.instance;
    final intent = service.routeIntent.value;
    if (intent == null || intent.type != 'approval') return;
    _handlingNotificationIntent = true;
    try {
      if (!mounted) return;
      if (_tabIndex != 1) {
        setState(() => _tabIndex = 1);
      }
      final host = _hostForIntent(intent);
      if (host == null) {
        service.markRouteIntentHandled(intent);
        return;
      }
      await ApprovalInboxStore.instance.refresh();
      if (!mounted) return;
      final entry = _entryForIntent(intent);
      service.markRouteIntentHandled(intent);
      await _openSession(
        host,
        entry == null
            ? _sessionFromNotificationIntent(intent)
            : _sessionFromAction(entry.action),
      );
    } finally {
      _handlingNotificationIntent = false;
    }
  }

  HostProfile? _hostForIntent(NotificationRouteIntent intent) {
    for (final host in _hosts) {
      if (host.id == intent.hostId && host.enabled) return host;
    }
    return null;
  }

  PendingActionEntry? _entryForIntent(NotificationRouteIntent intent) {
    for (final entry in ApprovalInboxStore.instance.entries) {
      if (entry.host.id == intent.hostId &&
          entry.action.id == intent.actionId) {
        return entry;
      }
    }
    return null;
  }

  SessionSummary _sessionFromNotificationIntent(
    NotificationRouteIntent intent,
  ) {
    final now = DateTime.now();
    return SessionSummary(
      id: intent.sessionId,
      title: 'Session',
      preview: 'Opened from approval notification',
      cwd: '',
      createdAt: now,
      updatedAt: now,
      source: 'appServer',
      provider: null,
      status: 'pendingApproval',
      runtime: null,
      gitInfo: null,
    );
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
      provider: null,
      status: 'pendingApproval',
      runtime: null,
      gitInfo: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tab = _tabs[_tabIndex];
    final enabledHosts = _enabledHosts;
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
              onOpenSettings: _openSettings,
            ),
            _HomeSearchBar(
              controller: _searchController,
              hintText: 'Search ${tab.title.toLowerCase()}',
            ),
            const NotificationPermissionBanner(),
            Expanded(
              child: _loading
                  ? const MeshLoader()
                  : IndexedStack(
                      index: _tabIndex,
                      children: [
                        RecentPane(
                          hosts: enabledHosts,
                          api: _api,
                          query: _query,
                          hasSavedHosts: _hosts.isNotEmpty,
                          screenAwakeSourceKey: 'mobile-recent-sessions',
                          onOpenSession: _openSession,
                          onActiveCountChanged: (count) {
                            if (!mounted) return;
                            setState(() => _activeCount = count);
                          },
                        ),
                        InboxPane(
                          hosts: enabledHosts,
                          api: _api,
                          query: _query,
                          hasSavedHosts: _hosts.isNotEmpty,
                          onOpenSession: (host, action) =>
                              _openSession(host, _sessionFromAction(action)),
                          onOpenPendingSession: (host, session, composerSeed) =>
                              _openSession(
                                host,
                                session,
                                composerSeed: composerSeed,
                              ),
                          onEditHost: (host) =>
                              _showHostEditor(initialHost: host),
                          onToggleHostEnabled: _toggleHostEnabled,
                          allHosts: _hosts,
                          onInboxCountChanged: (count) {
                            if (!mounted || count == _inboxCount) return;
                            setState(() => _inboxCount = count);
                          },
                        ),
                        HostsPane(
                          hosts: _hosts,
                          query: _query,
                          onOpenHost: _openHost,
                          onEditHost: (host) =>
                              _showHostEditor(initialHost: host),
                          onRemoveHost: _removeHost,
                          onToggleEnabled: _toggleHostEnabled,
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
  const _TopBar({
    required this.tab,
    required this.onRefresh,
    required this.onStartSession,
    required this.onOpenSettings,
  });

  final _TabDef tab;
  final VoidCallback onRefresh;
  final VoidCallback onStartSession;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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
            icon: Icons.tune_rounded,
            tooltip: 'Settings',
            onTap: onOpenSettings,
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
    this.hasSavedHosts = false,
    this.screenAwakeSourceKey,
    this.screenAwakeController,
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final void Function(HostProfile host, SessionSummary session) onOpenSession;
  final ValueChanged<int> onActiveCountChanged;
  final String query;
  final String? selectedSessionId;
  final EdgeInsets? padding;
  final bool dense;
  final bool hasSavedHosts;
  final String? screenAwakeSourceKey;
  final ScreenAwakeController? screenAwakeController;

  @override
  State<RecentPane> createState() => _RecentPaneState();
}

bool _sameHostList(List<HostProfile> a, List<HostProfile> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (_hostListSignature(a[i]) != _hostListSignature(b[i])) return false;
  }
  return true;
}

String _hostListSignature(HostProfile host) {
  return [
    host.id,
    host.label,
    host.baseUrl,
    host.token,
    host.enabled ? '1' : '0',
  ].join('\u001f');
}

class _RecentPaneState extends State<RecentPane> {
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;
  final RecentSessionsStore _store = RecentSessionsStore();

  @override
  void initState() {
    super.initState();
    _favorites.ensureLoaded();
    SessionReadStore.instance.ensureLoaded();
    _store.addListener(_handleStoreChanged);
    _store.configure(hosts: widget.hosts, api: widget.api);
  }

  @override
  void dispose() {
    _clearScreenAwakeSource(widget.screenAwakeSourceKey);
    _store.removeListener(_handleStoreChanged);
    _store.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RecentPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screenAwakeSourceKey != widget.screenAwakeSourceKey) {
      _clearScreenAwakeSource(oldWidget.screenAwakeSourceKey);
      _syncScreenAwakeSource(_screenAwakeActiveEntryCount() > 0);
    }
    _store.configure(hosts: widget.hosts, api: widget.api);
  }

  void _handleStoreChanged() {
    if (!mounted) return;
    _emitActiveCount();
  }

  void _emitActiveCount() {
    final count = _activeEntryCount();
    _syncScreenAwakeSource(_screenAwakeActiveEntryCount() > 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onActiveCountChanged(count);
    });
  }

  int _activeEntryCount() {
    return _store.entries.where((e) => e.session.isActive).length;
  }

  int _screenAwakeActiveEntryCount() {
    return _store.entries
        .where(
          (entry) =>
              entry.session.isActive &&
              _store.confirmedHostIds.contains(entry.host.id),
        )
        .length;
  }

  void _syncScreenAwakeSource(bool active) {
    final key = widget.screenAwakeSourceKey;
    if (key == null) return;
    (widget.screenAwakeController ?? ScreenAwakeController.instance)
        .setSourceActive(key, active);
  }

  void _clearScreenAwakeSource(String? key) {
    if (key == null) return;
    (widget.screenAwakeController ?? ScreenAwakeController.instance)
        .clearSource(key);
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
      return MeshEmptyState(
        icon: widget.hasSavedHosts
            ? Icons.pause_circle_outline_rounded
            : Icons.schedule_rounded,
        title: widget.hasSavedHosts ? 'No enabled hosts' : 'No sessions yet',
        body: widget.hasSavedHosts
            ? 'Enable a saved host from Hosts to load recent sessions.'
            : 'Add a host first — your most recent agent sessions will land here.',
      );
    }

    final stillLoadingInitial =
        !_store.hasLoadedOnce &&
        _store.entries.isEmpty &&
        _store.failedHostLabels.isEmpty &&
        _store.pendingHostIds.isNotEmpty;

    if (stillLoadingInitial) {
      return const MeshLoader();
    }

    return ListenableBuilder(
      listenable: Listenable.merge([
        _store,
        _favorites,
        HostStatusStore.instance,
        SessionOverridesStore.instance,
      ]),
      builder: (context, _) {
        final sortedEntries = _sortEntries(_store.entries);
        final hasCachedEntries =
            _store.entries.isNotEmpty &&
            _store.confirmedHostIds.length < widget.hosts.length;
        final isRefreshing = _store.pendingHostIds.isNotEmpty;
        final hasFailures = _store.failedHostLabels.isNotEmpty;
        final noResults = sortedEntries.isEmpty;
        final basePadding =
            widget.padding ??
            (widget.dense
                ? const EdgeInsets.fromLTRB(6, 4, 6, 24)
                : const EdgeInsets.fromLTRB(16, 8, 16, 32));
        Future<void> handleRefresh() async {
          await _store.refresh();
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
                    remaining: _store.pendingHostIds.length,
                    total: widget.hosts.length,
                    showingCached: hasCachedEntries,
                  ),
                if (hasFailures)
                  _RecentErrorBanner(
                    hostLabels: _store.failedHostLabels,
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
                    remaining: _store.pendingHostIds.length,
                    total: widget.hosts.length,
                    showingCached: hasCachedEntries,
                  );
                }
                offset += 1;
              }
              if (hasFailures) {
                if (index == offset) {
                  return _RecentErrorBanner(
                    hostLabels: _store.failedHostLabels,
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

typedef OpenPendingSessionCallback =
    Future<void> Function(
      HostProfile host,
      SessionSummary session,
      SessionComposerSeed? composerSeed,
    );
typedef HostProfileActionCallback = Future<void> Function(HostProfile host);

class InboxPane extends StatefulWidget {
  const InboxPane({
    super.key,
    required this.hosts,
    required this.allHosts,
    required this.api,
    required this.onOpenSession,
    required this.onOpenPendingSession,
    required this.onEditHost,
    required this.onToggleHostEnabled,
    required this.onInboxCountChanged,
    this.query = '',
    this.dense = false,
    this.hasSavedHosts = false,
  });

  final List<HostProfile> hosts;
  final List<HostProfile> allHosts;
  final ApiClient api;
  final void Function(HostProfile host, PendingAction action) onOpenSession;
  final OpenPendingSessionCallback onOpenPendingSession;
  final HostProfileActionCallback onEditHost;
  final HostProfileActionCallback onToggleHostEnabled;
  final ValueChanged<int> onInboxCountChanged;
  final String query;
  final bool dense;
  final bool hasSavedHosts;

  @override
  State<InboxPane> createState() => _InboxPaneState();
}

class _InboxPaneState extends State<InboxPane> {
  final ApprovalInboxStore _store = ApprovalInboxStore.instance;
  final SessionSendOutboxStore _outbox = SessionSendOutboxStore.instance;
  List<PendingSessionSend> _pendingSends = const [];
  Set<String> _retryingKeys = <String>{};

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
    _outbox.addListener(_onOutboxChanged);
    _store.configure(hosts: widget.hosts, api: widget.api);
    unawaited(_loadPendingSends());
    _emitCount();
  }

  @override
  void didUpdateWidget(covariant InboxPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameHostList(oldWidget.hosts, widget.hosts)) {
      _store.configure(hosts: widget.hosts, api: widget.api);
    }
    if (!_sameHostList(oldWidget.allHosts, widget.allHosts)) {
      _emitCount();
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _outbox.removeListener(_onOutboxChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted) return;
    setState(() {});
    _emitCount();
  }

  void _onOutboxChanged() {
    unawaited(_loadPendingSends());
  }

  void _emitCount() {
    final count = _store.count + _pendingSends.length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onInboxCountChanged(count);
    });
  }

  Future<void> _loadPendingSends() async {
    final pending = await _outbox.loadAll();
    if (!mounted) {
      return;
    }
    pending.sort(_comparePendingSends);
    setState(() {
      _pendingSends = pending;
      _retryingKeys = _retryingKeys
          .where((key) => pending.any((send) => send.key == key))
          .toSet();
    });
    _emitCount();
  }

  Future<void> _refresh() async {
    await Future.wait<dynamic>([_store.refresh(), _loadPendingSends()]);
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

  PendingSendAnalysis _analyzePendingSend(
    PendingSessionSend send, {
    bool retrying = false,
  }) {
    return analyzePendingSend(send, hosts: widget.allHosts, retrying: retrying);
  }

  Future<SessionSummary> _sessionSummaryForPendingSend(
    HostProfile host,
    PendingSessionSend send,
  ) async {
    final cached = await SessionCacheStore.instance.loadRecentSessions(host);
    for (final session in cached) {
      if (session.id == send.sessionId) {
        return session;
      }
    }
    final text = send.message.text.trim();
    return SessionSummary(
      id: send.sessionId,
      title: text.isEmpty ? 'Queued message' : _truncateSingleLine(text, 40),
      preview: send.lastError ?? _pendingSendPreview(send),
      cwd: '',
      createdAt: send.createdAt,
      updatedAt: send.updatedAt,
      source: 'appServer',
      provider: null,
      status: send.blocked ? 'blocked' : 'queued',
      runtime: SessionRuntimeSummary(
        model: send.model,
        serviceTier: send.fastMode == true ? 'fast' : null,
        reasoningEffort: send.reasoningEffort,
        approvalPolicy: send.approvalPolicy,
        sandboxMode: send.sandboxMode,
        networkAccess: send.networkAccess,
        updatedAt: send.updatedAt,
      ),
      gitInfo: null,
    );
  }

  Future<void> _openPendingSend(
    PendingSessionSend send, {
    bool seedComposer = false,
  }) async {
    final analysis = _analyzePendingSend(send);
    if (!analysis.canOpenSession) {
      showAppSnackBar(context, _pendingSendRecoveryMessage(analysis));
      return;
    }
    final host = analysis.host!;
    final session = await _sessionSummaryForPendingSend(host, send);
    if (!mounted) {
      return;
    }
    await widget.onOpenPendingSession(
      host,
      session,
      seedComposer
          ? SessionComposerSeed(text: send.text, inputItems: send.inputItems)
          : null,
    );
  }

  Future<void> _editPendingSend(PendingSessionSend send) async {
    final analysis = _analyzePendingSend(send);
    if (!analysis.canOpenSession) {
      showAppSnackBar(context, _pendingSendRecoveryMessage(analysis));
      return;
    }
    await _outbox.remove(send);
    if (!mounted) {
      return;
    }
    await _openPendingSend(send, seedComposer: true);
  }

  Future<void> _discardPendingSend(PendingSessionSend send) async {
    await _outbox.remove(send);
    if (!mounted) {
      return;
    }
    showAppSnackBar(context, 'Discarded queued message.');
  }

  Future<void> _retryPendingSend(PendingSessionSend send) async {
    if (_retryingKeys.contains(send.key)) {
      return;
    }
    final analysis = _analyzePendingSend(send);
    final host = analysis.host;
    if (!analysis.canRetryNow || host == null) {
      await _outbox.replaceIfPresent(
        send,
        send.copyWith(
          updatedAt: DateTime.now(),
          retryCount: send.retryCount + 1,
          lastError: _pendingSendRecoveryMessage(analysis),
          blocked: true,
        ),
      );
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, _pendingSendRecoveryMessage(analysis));
      return;
    }

    setState(() => _retryingKeys = {..._retryingKeys, send.key});
    try {
      await widget.api.sendInput(
        host,
        sessionId: send.sessionId,
        text: send.text,
        input: send.inputItems,
        clientMessageId: send.clientMessageId,
        model: send.model,
        mode: send.mode,
        reasoningEffort: send.reasoningEffort,
        fastMode: send.fastMode,
        approvalPolicy: send.approvalPolicy,
        sandboxMode: send.sandboxMode,
        networkAccess: send.networkAccess,
      );
      await _outbox.remove(send);
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Queued message sent.');
    } catch (error) {
      final message = friendlyError(error);
      if (isRetryableSendError(error)) {
        await _outbox.replaceIfPresent(
          send,
          send.copyWith(
            updatedAt: DateTime.now(),
            nextAttemptAt: DateTime.now().add(
              _pendingSendBackoff(send.retryCount + 1),
            ),
            retryCount: send.retryCount + 1,
            lastError: message,
            blocked: false,
          ),
        );
      } else {
        await _outbox.replaceIfPresent(
          send,
          send.copyWith(
            updatedAt: DateTime.now(),
            retryCount: send.retryCount + 1,
            lastError: message,
            blocked: true,
          ),
        );
      }
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Retry failed: $message');
    } finally {
      if (mounted) {
        setState(() => _retryingKeys = {..._retryingKeys}..remove(send.key));
      }
    }
  }

  Future<void> _fixPendingHost(PendingSendAnalysis analysis) async {
    final host = analysis.host;
    if (host == null) {
      showAppSnackBar(
        context,
        'The original host no longer exists. Recreate it from Hosts if needed.',
      );
      return;
    }
    await widget.onEditHost(host);
  }

  Future<void> _enablePendingHost(PendingSendAnalysis analysis) async {
    final host = analysis.host;
    if (host == null) {
      showAppSnackBar(context, 'The original host is no longer available.');
      return;
    }
    if (host.enabled) {
      return;
    }
    await widget.onToggleHostEnabled(host);
  }

  Future<void> _usePendingCurrentHost(PendingSendAnalysis analysis) async {
    final host = analysis.host;
    if (host == null) {
      showAppSnackBar(context, 'The original host is no longer available.');
      return;
    }
    await _outbox.remove(analysis.send);
    final rebound = analysis.send.copyWith(
      hostFingerprint: SessionSendOutboxStore.hostFingerprint(host),
      updatedAt: DateTime.now(),
      nextAttemptAt: DateTime.now(),
      lastError: 'Host configuration updated. Ready to retry.',
      blocked: false,
    );
    await _outbox.upsert(rebound);
    if (!mounted) {
      return;
    }
    showAppSnackBar(
      context,
      'Queued message is now bound to the current host configuration.',
    );
  }

  Widget _buildPendingSendCard(PendingSessionSend send) {
    final analysis = _analyzePendingSend(
      send,
      retrying: _retryingKeys.contains(send.key),
    );
    return _PendingSendCard(
      send: send,
      dense: widget.dense,
      analysis: analysis,
      onOpenSession: analysis.canOpenSession
          ? () => _openPendingSend(send)
          : null,
      onEditCopy: analysis.canOpenSession ? () => _editPendingSend(send) : null,
      onRetryNow: analysis.canRetryNow ? () => _retryPendingSend(send) : null,
      onDiscard: () => _discardPendingSend(send),
      onFixHost: analysis.canFixHost ? () => _fixPendingHost(analysis) : null,
      onUseCurrentHost: analysis.canUseCurrentHost
          ? () => _usePendingCurrentHost(analysis)
          : null,
      onEnableHost: analysis.canEnableHost
          ? () => _enablePendingHost(analysis)
          : null,
    );
  }

  Duration _pendingSendBackoff(int retryCount) {
    const steps = <Duration>[
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 45),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ];
    return steps[retryCount.clamp(0, steps.length - 1).toInt()];
  }

  int _comparePendingSends(PendingSessionSend left, PendingSessionSend right) {
    final leftAnalysis = _analyzePendingSend(left);
    final rightAnalysis = _analyzePendingSend(right);
    if (leftAnalysis.needsAttention != rightAnalysis.needsAttention) {
      return leftAnalysis.needsAttention ? -1 : 1;
    }
    final nextAttemptCompare = left.nextAttemptAt.compareTo(
      right.nextAttemptAt,
    );
    if (nextAttemptCompare != 0) {
      return nextAttemptCompare;
    }
    return right.updatedAt.compareTo(left.updatedAt);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final query = widget.query.trim().toLowerCase();
    final allPending = _pendingSends;
    final pending = query.isEmpty
        ? allPending
        : allPending
              .where((send) {
                final analysis = _analyzePendingSend(send);
                return _pendingSendPreview(
                      send,
                    ).toLowerCase().contains(query) ||
                    send.sessionId.toLowerCase().contains(query) ||
                    (send.lastError ?? '').toLowerCase().contains(query) ||
                    analysis.hostLabel.toLowerCase().contains(query) ||
                    (_pendingSendIssueLabel(analysis.issue) ?? '')
                        .toLowerCase()
                        .contains(query);
              })
              .toList(growable: false);

    if (widget.allHosts.isEmpty && allPending.isEmpty) {
      return MeshEmptyState(
        icon: widget.hasSavedHosts
            ? Icons.notifications_paused_rounded
            : Icons.all_inbox_rounded,
        title: widget.hasSavedHosts ? 'No enabled hosts' : 'Inbox is empty',
        body: widget.hasSavedHosts
            ? 'Enable a saved host from Hosts to receive pending approvals.'
            : 'Add a host first. Pending approvals from every machine will show up here.',
      );
    }

    final stillLoadingInitial = !_store.hasLoadedOnce && _store.isLoading;
    if (stillLoadingInitial) {
      return const MeshLoader();
    }

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
    final hasCachedEntries = allEntries.isNotEmpty;
    final hasVisibleContent = pending.isNotEmpty || entries.isNotEmpty;
    final sectionSpacing = SizedBox(height: widget.dense ? 8 : 12);
    final cardSpacing = SizedBox(height: widget.dense ? 4 : 10);
    return RefreshIndicator(
      color: colors.accent,
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: widget.dense
            ? const EdgeInsets.fromLTRB(8, 4, 8, 24)
            : const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (isRefreshing)
            _RecentProgressStrip(
              remaining: _store.pendingHostsRemaining,
              total: _store.totalHosts,
              showingCached: hasCachedEntries,
            ),
          if (isRefreshing) sectionSpacing,
          if (hasFailures)
            _RecentErrorBanner(
              hostLabels: _store.failedHostLabels,
              onRetry: _refresh,
            ),
          if (hasFailures) sectionSpacing,
          if (pending.isNotEmpty) ...[
            _InboxSectionHeader(
              icon: Icons.cloud_sync_rounded,
              title: pending.length == 1
                  ? '1 queued message'
                  : '${pending.length} queued messages',
              subtitle:
                  'Messages Sidemesh is holding until delivery succeeds or you intervene.',
            ),
            cardSpacing,
            for (var index = 0; index < pending.length; index += 1) ...[
              _buildPendingSendCard(pending[index]),
              if (index != pending.length - 1) cardSpacing,
            ],
            if (entries.isNotEmpty) sectionSpacing,
          ],
          if (entries.isNotEmpty) ...[
            _InboxSectionHeader(
              icon: Icons.verified_user_rounded,
              title: entries.length == 1
                  ? '1 approval pending'
                  : '${entries.length} approvals pending',
              subtitle:
                  'Command, file, and permission prompts waiting across your hosts.',
            ),
            cardSpacing,
            for (var index = 0; index < entries.length; index += 1) ...[
              _InboxCard(
                entry: entries[index],
                dense: widget.dense,
                onOpenSession: () => widget.onOpenSession(
                  entries[index].host,
                  entries[index].action,
                ),
                onRespond: (decision) => _respond(
                  entries[index].host,
                  entries[index].action,
                  decision,
                ),
              ),
              if (index != entries.length - 1) cardSpacing,
            ],
          ],
          if (!hasVisibleContent) ...[
            const SizedBox(height: 80),
            if (query.isNotEmpty)
              MeshEmptyState(
                icon: Icons.search_off_rounded,
                title: 'No matches',
                body:
                    'No queued messages or approvals match "${widget.query.trim()}".',
              )
            else
              const MeshEmptyState(
                icon: Icons.verified_rounded,
                title: 'Inbox is clear',
                body:
                    'Queued sends and approval prompts from your nodes will show up here.',
              ),
          ],
        ],
      ),
    );
  }
}

class _InboxSectionHeader extends StatelessWidget {
  const _InboxSectionHeader({
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.accent.withValues(alpha: 0.25)),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: colors.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PendingSendCard extends StatelessWidget {
  const _PendingSendCard({
    required this.send,
    required this.analysis,
    this.onOpenSession,
    this.onEditCopy,
    this.onRetryNow,
    required this.onDiscard,
    this.onFixHost,
    this.onUseCurrentHost,
    this.onEnableHost,
    this.dense = false,
  });

  final PendingSessionSend send;
  final PendingSendAnalysis analysis;
  final VoidCallback? onOpenSession;
  final VoidCallback? onEditCopy;
  final VoidCallback? onRetryNow;
  final VoidCallback onDiscard;
  final VoidCallback? onFixHost;
  final VoidCallback? onUseCurrentHost;
  final VoidCallback? onEnableHost;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = _pendingSendTitle(send);
    final detail = _pendingSendDetail(send, analysis);
    final hostMeta = '${analysis.hostLabel} · ${send.sessionId}';
    final stateTone = _pendingSendStateTone(analysis.state);
    final stateLabel = _pendingSendStateLabel(analysis.state);
    final issueLabel = _pendingSendIssueLabel(analysis.issue);
    final borderTone = analysis.needsAttention
        ? colors.warning.withValues(alpha: 0.35)
        : colors.info.withValues(alpha: 0.3);
    final accentTone = analysis.needsAttention ? colors.warning : colors.info;

    if (dense) {
      return MeshCard(
        tone: MeshCardTone.surface,
        borderColor: borderTone,
        accentStrip: accentTone,
        padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MeshPill(label: stateLabel, tone: stateTone, mono: true),
              ],
            ),
            if (issueLabel != null) ...[
              const SizedBox(height: 6),
              MeshPill(
                label: issueLabel,
                tone: _pendingSendIssueTone(analysis.issue),
                mono: true,
              ),
            ],
            const SizedBox(height: 4),
            Text(
              hostMeta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (onEnableHost != null)
                  _PendingSendActionChip(
                    icon: Icons.play_circle_outline_rounded,
                    label: 'Enable',
                    onTap: onEnableHost,
                  ),
                if (onFixHost != null)
                  _PendingSendActionChip(
                    icon: Icons.tune_rounded,
                    label: 'Fix host',
                    onTap: onFixHost,
                  ),
                if (onUseCurrentHost != null)
                  _PendingSendActionChip(
                    icon: Icons.link_rounded,
                    label: 'Use current',
                    onTap: onUseCurrentHost,
                  ),
                if (onOpenSession != null)
                  _PendingSendActionChip(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: 'Open',
                    onTap: onOpenSession,
                  ),
                if (onEditCopy != null)
                  _PendingSendActionChip(
                    icon: Icons.edit_outlined,
                    label: 'Edit',
                    onTap: onEditCopy,
                  ),
                if (onRetryNow != null)
                  _PendingSendActionChip(
                    icon: Icons.refresh_rounded,
                    label: analysis.state == PendingSendDisplayState.retrying
                        ? 'Retrying'
                        : 'Retry',
                    onTap: analysis.state == PendingSendDisplayState.retrying
                        ? null
                        : onRetryNow,
                  ),
                _PendingSendActionChip(
                  icon: Icons.delete_outline_rounded,
                  label: 'Discard',
                  destructive: true,
                  onTap: onDiscard,
                ),
              ],
            ),
          ],
        ),
      );
    }

    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: borderTone,
      accentStrip: accentTone,
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              MeshPill(label: stateLabel, tone: stateTone, mono: true),
            ],
          ),
          if (issueLabel != null) ...[
            const SizedBox(height: 8),
            MeshPill(
              label: issueLabel,
              tone: _pendingSendIssueTone(analysis.issue),
              mono: true,
            ),
          ],
          const SizedBox(height: 6),
          Text(
            hostMeta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(color: colors.textTertiary, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.38,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (onEnableHost != null)
                _PendingSendActionChip(
                  icon: Icons.play_circle_outline_rounded,
                  label: 'Enable host',
                  onTap: onEnableHost,
                ),
              if (onFixHost != null)
                _PendingSendActionChip(
                  icon: Icons.tune_rounded,
                  label: 'Fix host',
                  onTap: onFixHost,
                ),
              if (onUseCurrentHost != null)
                _PendingSendActionChip(
                  icon: Icons.link_rounded,
                  label: 'Use current host',
                  onTap: onUseCurrentHost,
                ),
              if (onOpenSession != null)
                _PendingSendActionChip(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: 'Open session',
                  onTap: onOpenSession,
                ),
              if (onEditCopy != null)
                _PendingSendActionChip(
                  icon: Icons.edit_outlined,
                  label: 'Edit copy',
                  onTap: onEditCopy,
                ),
              if (onRetryNow != null)
                _PendingSendActionChip(
                  icon: Icons.refresh_rounded,
                  label: analysis.state == PendingSendDisplayState.retrying
                      ? 'Retrying...'
                      : 'Retry now',
                  onTap: analysis.state == PendingSendDisplayState.retrying
                      ? null
                      : onRetryNow,
                ),
              _PendingSendActionChip(
                icon: Icons.delete_outline_rounded,
                label: 'Discard',
                destructive: true,
                onTap: onDiscard,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PendingSendActionChip extends StatelessWidget {
  const _PendingSendActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final disabled = onTap == null;
    final fg = disabled
        ? colors.textTertiary
        : destructive
        ? colors.danger
        : colors.textPrimary;
    final bg = disabled
        ? colors.surfaceMuted
        : destructive
        ? colors.dangerMuted
        : colors.surfaceMuted;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _pendingSendTitle(PendingSessionSend send) {
  final text = send.message.text.trim();
  if (text.isNotEmpty) {
    return _truncateSingleLine(text, 72);
  }
  final imageCount = send.message.attachments
      .where((item) => item.isImage)
      .length;
  if (imageCount > 0) {
    return imageCount == 1
        ? 'Queued image message'
        : 'Queued $imageCount-image message';
  }
  return 'Queued message';
}

String _pendingSendPreview(PendingSessionSend send) {
  final text = send.message.text.trim();
  if (text.isNotEmpty) {
    return _truncateSingleLine(text, 120);
  }
  final imageCount = send.message.attachments
      .where((item) => item.isImage)
      .length;
  if (imageCount > 0) {
    return imageCount == 1
        ? 'Contains 1 image attachment'
        : 'Contains $imageCount image attachments';
  }
  return 'No text content';
}

String _pendingSendDetail(
  PendingSessionSend send,
  PendingSendAnalysis analysis,
) {
  final nextAttempt = analysis.state == PendingSendDisplayState.retrying
      ? 'Retrying now'
      : analysis.state == PendingSendDisplayState.blocked
      ? 'Retry manually'
      : _formatPendingRetryAt(send.nextAttemptAt);
  final error = send.lastError?.trim();
  final reason = _pendingSendRecoveryMessage(analysis);
  if (analysis.needsAttention) {
    return '$reason · ${_pendingSendPreview(send)}';
  }
  final suffix = error == null || error.isEmpty || error == reason
      ? ''
      : ' · $error';
  return '$nextAttempt · ${_pendingSendPreview(send)}$suffix';
}

String _pendingSendRecoveryMessage(PendingSendAnalysis analysis) {
  return switch (analysis.issue) {
    PendingSendIssueKind.hostDisabled =>
      'Host is disabled. Enable it before retrying.',
    PendingSendIssueKind.hostMissing =>
      'The original host is gone. Discard or recreate the message.',
    PendingSendIssueKind.hostChanged =>
      'This host changed since the message was queued. Review its config first.',
    PendingSendIssueKind.unauthorized =>
      'Host token is invalid. Fix the host credentials, then retry.',
    PendingSendIssueKind.timeout => 'The host is taking too long to respond.',
    PendingSendIssueKind.unreachable => "Couldn't reach the host.",
    PendingSendIssueKind.server =>
      'The host reported a temporary server error.',
    PendingSendIssueKind.rateLimited => 'The host is rate limited right now.',
    PendingSendIssueKind.unknown =>
      analysis.send.lastError ??
          'This message needs attention before retrying.',
    PendingSendIssueKind.none =>
      analysis.send.lastError ?? 'Waiting to retry automatically.',
  };
}

String _pendingSendStateLabel(PendingSendDisplayState state) {
  return switch (state) {
    PendingSendDisplayState.queued => 'queued',
    PendingSendDisplayState.retrying => 'retrying',
    PendingSendDisplayState.blocked => 'blocked',
  };
}

MeshPillTone _pendingSendStateTone(PendingSendDisplayState state) {
  return switch (state) {
    PendingSendDisplayState.queued => MeshPillTone.info,
    PendingSendDisplayState.retrying => MeshPillTone.accent,
    PendingSendDisplayState.blocked => MeshPillTone.warning,
  };
}

String? _pendingSendIssueLabel(PendingSendIssueKind issue) {
  return switch (issue) {
    PendingSendIssueKind.none => null,
    PendingSendIssueKind.hostDisabled => 'host disabled',
    PendingSendIssueKind.hostMissing => 'host missing',
    PendingSendIssueKind.hostChanged => 'host changed',
    PendingSendIssueKind.unauthorized => 'bad token',
    PendingSendIssueKind.timeout => 'timeout',
    PendingSendIssueKind.unreachable => 'offline',
    PendingSendIssueKind.server => 'server error',
    PendingSendIssueKind.rateLimited => 'rate limited',
    PendingSendIssueKind.unknown => 'needs review',
  };
}

MeshPillTone _pendingSendIssueTone(PendingSendIssueKind issue) {
  return switch (issue) {
    PendingSendIssueKind.none => MeshPillTone.neutral,
    PendingSendIssueKind.timeout => MeshPillTone.info,
    PendingSendIssueKind.unreachable => MeshPillTone.info,
    PendingSendIssueKind.rateLimited => MeshPillTone.info,
    PendingSendIssueKind.server => MeshPillTone.warning,
    PendingSendIssueKind.hostDisabled => MeshPillTone.warning,
    PendingSendIssueKind.hostMissing => MeshPillTone.danger,
    PendingSendIssueKind.hostChanged => MeshPillTone.danger,
    PendingSendIssueKind.unauthorized => MeshPillTone.danger,
    PendingSendIssueKind.unknown => MeshPillTone.warning,
  };
}

String _formatPendingRetryAt(DateTime nextAttemptAt) {
  final remaining = nextAttemptAt.difference(DateTime.now());
  if (remaining <= Duration.zero) {
    return 'Retrying soon';
  }
  if (remaining.inMinutes >= 1) {
    return 'Next retry in ${remaining.inMinutes}m';
  }
  return 'Next retry in ${remaining.inSeconds}s';
}

String _truncateSingleLine(String value, int maxLength) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return '${normalized.substring(0, maxLength - 3)}...';
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
    'tool' => 'tool',
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
    required this.onToggleEnabled,
    required this.onAddHost,
    this.query = '',
    this.dense = false,
    this.selectedHostId,
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onOpenHost;
  final ValueChanged<HostProfile> onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;
  final ValueChanged<HostProfile> onToggleEnabled;
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
          onToggleEnabled: () => onToggleEnabled(host),
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
    required this.onToggleEnabled,
    this.dense = false,
    this.selected = false,
  });

  final HostProfile host;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onToggleEnabled;
  final bool dense;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListenableBuilder(
      listenable: HostStatusStore.instance,
      builder: (context, _) {
        final status = host.enabled
            ? HostStatusStore.instance.statusFor(host.id)
            : HostStatus.unknown;
        if (dense) {
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: host.enabled ? onTap : null,
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
                          child: _HostStatusDot(
                            status: status,
                            enabled: host.enabled,
                          ),
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
                                  color: host.enabled
                                      ? (selected ? colors.accent : null)
                                      : colors.textTertiary,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            host.enabled ? host.baseUrl : 'Disabled',
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
                      onTap: onToggleEnabled,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          host.enabled
                              ? Icons.pause_circle_outline_rounded
                              : Icons.play_circle_outline_rounded,
                          size: 14,
                          color: host.enabled
                              ? colors.textTertiary
                              : colors.accent,
                        ),
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
          onTap: host.enabled ? onTap : null,
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
                    child: _HostStatusDot(
                      status: status,
                      enabled: host.enabled,
                    ),
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
                        color: host.enabled ? null : colors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host.enabled
                          ? host.baseUrl
                          : 'Disabled · ${host.baseUrl}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                    if (!host.enabled ||
                        status.reachability != HostReachability.unknown) ...[
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
                tooltip: host.enabled ? 'Disable host' : 'Enable host',
                onPressed: onToggleEnabled,
                icon: Icon(
                  host.enabled
                      ? Icons.pause_circle_outline_rounded
                      : Icons.play_circle_outline_rounded,
                  size: 20,
                  color: host.enabled ? colors.textSecondary : colors.accent,
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
    if (!host.enabled) return 'Disabled';
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
    if (!host.enabled) return colors.textTertiary;
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
  const _HostStatusDot({required this.status, required this.enabled});

  final HostStatus status;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final Color fill;
    if (!enabled) {
      fill = colors.textTertiary;
    } else {
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
  late bool _enabled;

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
    _enabled = widget.initialHost?.enabled ?? true;
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
            const SizedBox(height: 14),
            SwitchListTile(
              value: _enabled,
              onChanged: (value) => setState(() => _enabled = value),
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              subtitle: Text(
                _enabled
                    ? 'Include this host in sessions, inbox, and background sync.'
                    : 'Keep this host saved, but skip automatic app traffic.',
              ),
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
                      enabled: _enabled,
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

String _randomId() {
  final random = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(
    12,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}

class _RecentProgressStrip extends StatelessWidget {
  const _RecentProgressStrip({
    required this.remaining,
    required this.total,
    required this.showingCached,
  });

  final int remaining;
  final int total;
  final bool showingCached;

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
              '${showingCached ? 'Refreshing cached sessions' : 'Loading hosts'} · $loaded of $total ready',
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
