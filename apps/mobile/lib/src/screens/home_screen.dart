import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../app_version_store.dart';
import '../approval_inbox_store.dart';
import '../host_status_store.dart';
import '../relative_time_ticker.dart';
import '../host_store.dart';
import '../live_activity_service.dart';
import '../local_notification_service.dart';
import '../mobile_client_version_policy.dart';
import '../models.dart';
import '../pending_send_recovery.dart';
import '../recent_sessions_live_store.dart';
import '../recent_session_filter.dart';
import '../screen_awake_controller.dart';
import '../search_query.dart';
import '../session_local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../session_overrides_store.dart';
import '../session_read_store.dart';
import '../session_send_outbox_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/session_row_card.dart';
import '../widgets/notification_permission_banner.dart';
import 'create_session_sheet.dart';
import 'host_detail_screen.dart';
import 'pair_scanner_sheet.dart';
import 'settings_screen.dart';
import 'session_screen.dart';
import 'usage_pane.dart';

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
      subtitle: 'Pick up where your agents left off',
      icon: Icons.schedule_rounded,
      selectedIcon: Icons.schedule_rounded,
    ),
    _TabDef(
      title: 'Inbox',
      subtitle: 'Approvals and pending replies in one place',
      icon: Icons.all_inbox_rounded,
      selectedIcon: Icons.all_inbox_rounded,
    ),
    _TabDef(
      title: 'Usage',
      subtitle: 'Limits, versions, and host health',
      icon: Icons.speed_rounded,
      selectedIcon: Icons.speed_rounded,
    ),
    _TabDef(
      title: 'Hosts',
      subtitle: 'Machines you can reach from this device',
      icon: Icons.hub_rounded,
      selectedIcon: Icons.hub_rounded,
    ),
  ];

  static const _dismissedRecommendedMobileClientVersionKey =
      'sidemesh_dismissed_mobile_client_recommended_version_v1';

  final HostStore _store = HostStore();
  final ApiClient _api = ApiClient();
  final AppVersionStore _appVersionStore = AppVersionStore.instance;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  Timer? _heartbeatTimer;
  bool _heartbeatInFlight = false;
  static const Duration _heartbeatInterval = Duration(minutes: 5);
  List<HostProfile> _hosts = const [];
  bool _loading = true;
  int _tabIndex = 0;
  int _activeCount = 0;
  int _inboxCount = 0;
  String _query = '';
  SessionViewMode _recentViewMode = SessionViewMode.flat;
  RecentSessionFilters _recentFilters = const RecentSessionFilters();
  bool _handlingNotificationIntent = false;
  String? _dismissedRecommendedMobileClientVersion;
  final Map<String, NodeInfo> _hostNodeInfo = {};

  List<HostProfile> get _enabledHosts =>
      _hosts.where((host) => host.enabled).toList(growable: false);

  bool _searchVisibleForTab(_TabDef tab, int enabledHostCount) {
    if (tab.title == 'Usage') return false;
    return tab.title != 'Hosts' || enabledHostCount >= 4;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LocalNotificationService.instance.routeIntent.addListener(
      _onNotificationRouteIntent,
    );
    _appVersionStore.addListener(_handleAppVersionChanged);
    unawaited(_appVersionStore.ensureLoaded());
    unawaited(_loadDismissedMobileClientVersion());
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
    _loadRecentViewMode();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LocalNotificationService.instance.routeIntent.removeListener(
      _onNotificationRouteIntent,
    );
    _appVersionStore.removeListener(_handleAppVersionChanged);
    _searchDebounce?.cancel();
    _stopHeartbeat();
    _searchController.dispose();
    super.dispose();
  }

  void _handleAppVersionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadDismissedMobileClientVersion() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getString(
      _dismissedRecommendedMobileClientVersionKey,
    );
    if (!mounted) return;
    setState(() => _dismissedRecommendedMobileClientVersion = dismissed);
  }

  Future<void> _dismissRecommendedMobileClientNotice(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedRecommendedMobileClientVersionKey, version);
    if (!mounted) return;
    setState(() => _dismissedRecommendedMobileClientVersion = version);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Kick an immediate probe on foreground so the dots reflect reality
      // before the next scheduled tick.
      _startHeartbeat();
      unawaited(_runHeartbeat());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
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
      bool nodesChanged = false;
      await Future.wait(
        hosts.map((host) async {
          try {
            final node = await _api.fetchNode(host);
            store.markOnline(host.id);
            final previousNode = _hostNodeInfo[host.id];
            if (previousNode?.updateAvailable != node.updateAvailable ||
                previousNode?.updateChannel != node.updateChannel ||
                previousNode?.recommendedMobileClientVersion !=
                    node.recommendedMobileClientVersion ||
                previousNode?.minimumMobileClientVersion !=
                    node.minimumMobileClientVersion) {
              nodesChanged = true;
            }
            _hostNodeInfo[host.id] = node;
          } catch (error) {
            store.markOffline(host.id, error: friendlyError(error));
            if (_hostNodeInfo.remove(host.id) != null) {
              nodesChanged = true;
            }
          }
        }),
        eagerError: false,
      );
      if (mounted && nodesChanged) setState(() {});
    } finally {
      _heartbeatInFlight = false;
    }
  }

  Future<void> _loadRecentViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('sidemesh.recent.viewMode');
    if (!mounted) return;
    setState(() {
      _recentViewMode = switch (raw) {
        'byCwd' => SessionViewMode.byCwd,
        'byHost' => SessionViewMode.byHost,
        _ => SessionViewMode.flat,
      };
    });
  }

  Future<void> _setRecentViewMode(SessionViewMode mode) async {
    if (_recentViewMode == mode) return;
    setState(() => _recentViewMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sidemesh.recent.viewMode', switch (mode) {
      SessionViewMode.byCwd => 'byCwd',
      SessionViewMode.byHost => 'byHost',
      SessionViewMode.flat => 'flat',
    });
  }

  void _toggleRecentRunningOnly(bool enabled) {
    if (_recentFilters.runningOnly == enabled) return;
    setState(() {
      _recentFilters = _recentFilters.copyWith(runningOnly: enabled);
    });
  }

  void _toggleRecentUnreadOnly(bool enabled) {
    if (_recentFilters.unreadOnly == enabled) return;
    setState(() {
      _recentFilters = _recentFilters.copyWith(unreadOnly: enabled);
    });
  }

  Future<void> _refreshHosts() async {
    final hosts = await _store.loadHosts();
    if (!mounted) {
      return;
    }
    final hostIds = hosts.map((host) => host.id).toSet();
    setState(() {
      _hosts = hosts;
      _loading = false;
      _hostNodeInfo.removeWhere((id, _) => !hostIds.contains(id));
      for (final host in hosts) {
        if (!host.enabled) {
          _hostNodeInfo.remove(host.id);
        }
      }
    });
    for (final host in hosts) {
      if (!host.enabled) {
        HostStatusStore.instance.clear(host.id);
      }
    }
    ApprovalInboxStore.instance.configure(hosts: _enabledHosts, api: _api);
    _startHeartbeat();
    unawaited(_runHeartbeat());
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
      _hostNodeInfo.remove(previousHost.id);
      HostStatusStore.instance.clear(previousHost.id);
      await SessionLocalStore.instance.clearHost(previousHost);
    }
    await _store.saveHosts(updated);
    await _refreshHosts();
  }

  Future<void> _removeHost(HostProfile host) async {
    final updated = _hosts.where((item) => item.id != host.id).toList();
    await SessionLocalStore.instance.clearHost(host);
    _hostNodeInfo.remove(host.id);
    HostStatusStore.instance.clear(host.id);
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
    _hostNodeInfo.remove(host.id);
    HostStatusStore.instance.clear(host.id);
    if (disabling) {
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

  Future<void> _openMobileClientCompatibilityNotice(
    MobileClientCompatibilityNotice notice,
  ) async {
    if (notice.affectedHostCount == 1) {
      final host = notice.primaryHost;
      await _openHost(host);
      return;
    }
    if (!mounted) return;
    setState(() => _tabIndex = 2);
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

  _HomePrimaryAction _primaryActionForTab(_TabDef tab) {
    if (_hosts.isEmpty || tab.title == 'Hosts') {
      return _HomePrimaryAction(
        label: 'Add host',
        icon: Icons.add_link_rounded,
        onTap: () => _showHostEditor(),
      );
    }
    if (_enabledHosts.isEmpty) {
      return _HomePrimaryAction(
        label: 'Open hosts',
        icon: Icons.hub_rounded,
        onTap: () => setState(() => _tabIndex = 3),
      );
    }
    return _HomePrimaryAction(
      label: 'New session',
      icon: Icons.add_rounded,
      onTap: _startSessionFromHome,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tab = _tabs[_tabIndex];
    final enabledHosts = _enabledHosts;
    final primaryAction = _primaryActionForTab(tab);
    final installedAppVersion = _appVersionStore.info.comparableVersion;
    final mobileClientNotice = summarizeMobileClientCompatibility(
      installedVersion: installedAppVersion,
      hosts: enabledHosts,
      hostNodes: _hostNodeInfo,
      dismissedRecommendedVersion: _dismissedRecommendedMobileClientVersion,
    );
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _HomeStickyHeader(
              tab: tab,
              primaryAction: primaryAction,
              searchController: _searchController,
              searchVisible: _searchVisibleForTab(tab, enabledHosts.length),
              viewMode: _tabIndex == 0 ? _recentViewMode : null,
              onViewModeChanged: _tabIndex == 0 ? _setRecentViewMode : null,
              recentFilters: _tabIndex == 0 ? _recentFilters : null,
              onRunningOnlyChanged: _tabIndex == 0
                  ? _toggleRecentRunningOnly
                  : null,
              onUnreadOnlyChanged: _tabIndex == 0
                  ? _toggleRecentUnreadOnly
                  : null,
              onRefresh: _refreshHosts,
              onOpenSettings: _openSettings,
            ),
            const NotificationPermissionBanner(),
            if (mobileClientNotice != null)
              _MobileClientUpdateBanner(
                notice: mobileClientNotice,
                onReview: () => unawaited(
                  _openMobileClientCompatibilityNotice(mobileClientNotice),
                ),
                onDismiss:
                    mobileClientNotice.level ==
                        MobileClientCompatibilityLevel.recommended
                    ? () => unawaited(
                        _dismissRecommendedMobileClientNotice(
                          mobileClientNotice.targetVersion,
                        ),
                      )
                    : null,
              ),
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
                          onAddHost: () => _showHostEditor(),
                          onActiveCountChanged: (count) {
                            if (!mounted) return;
                            setState(() => _activeCount = count);
                          },
                          viewMode: _recentViewMode,
                          onViewModeChanged: _setRecentViewMode,
                          filters: _recentFilters,
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
                        UsagePane(
                          hosts: enabledHosts,
                          api: _api,
                          active: _tabIndex == 2,
                        ),
                        HostsPane(
                          hosts: _hosts,
                          hostNodes: _hostNodeInfo,
                          installedAppVersion: installedAppVersion,
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
      floatingActionButton: _tabIndex == 3 && _hosts.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: () => _showHostEditor(),
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Add host'),
            )
          : null,
      bottomNavigationBar: _MeshNavBar(
        tabs: _tabs,
        currentIndex: _tabIndex,
        onTap: (index) {
          setState(() {
            _tabIndex = index;
            final tab = _tabs[index];
            final showSearch = _searchVisibleForTab(tab, _enabledHosts.length);
            if (!showSearch &&
                (_query.isNotEmpty || _searchController.text.isNotEmpty)) {
              _query = '';
              _searchController.clear();
            }
          });
        },
        badges: [_activeCount, _inboxCount, 0, 0],
      ),
    );
  }
}

enum SessionViewMode { flat, byCwd, byHost }

enum _HomeHeaderMenuAction { refresh, settings }

String _sessionViewModeLabel(SessionViewMode mode) {
  return switch (mode) {
    SessionViewMode.flat => 'List',
    SessionViewMode.byCwd => 'Folders',
    SessionViewMode.byHost => 'Hosts',
  };
}

IconData _sessionViewModeIcon(SessionViewMode mode) {
  return switch (mode) {
    SessionViewMode.flat => Icons.view_list_rounded,
    SessionViewMode.byCwd => Icons.folder_rounded,
    SessionViewMode.byHost => Icons.hub_rounded,
  };
}

class RecentSessionFilters {
  const RecentSessionFilters({
    this.runningOnly = false,
    this.unreadOnly = false,
  });

  final bool runningOnly;
  final bool unreadOnly;

  bool get isAnyActive => runningOnly || unreadOnly;

  RecentSessionFilters copyWith({bool? runningOnly, bool? unreadOnly}) {
    return RecentSessionFilters(
      runningOnly: runningOnly ?? this.runningOnly,
      unreadOnly: unreadOnly ?? this.unreadOnly,
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

class _HomePrimaryAction {
  const _HomePrimaryAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

class _HomeStickyHeader extends StatelessWidget {
  const _HomeStickyHeader({
    required this.tab,
    required this.primaryAction,
    required this.searchController,
    required this.searchVisible,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.recentFilters,
    required this.onRunningOnlyChanged,
    required this.onUnreadOnlyChanged,
    required this.onRefresh,
    required this.onOpenSettings,
  });

  final _TabDef tab;
  final _HomePrimaryAction primaryAction;
  final TextEditingController searchController;
  final bool searchVisible;
  final SessionViewMode? viewMode;
  final ValueChanged<SessionViewMode>? onViewModeChanged;
  final RecentSessionFilters? recentFilters;
  final ValueChanged<bool>? onRunningOnlyChanged;
  final ValueChanged<bool>? onUnreadOnlyChanged;
  final VoidCallback onRefresh;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sidemesh',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: AppWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tab.title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: colors.textPrimary,
                            fontWeight: AppWeights.title,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tab.subtitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              PopupMenuButton<_HomeHeaderMenuAction>(
                tooltip: 'More',
                onSelected: (action) {
                  switch (action) {
                    case _HomeHeaderMenuAction.refresh:
                      onRefresh();
                    case _HomeHeaderMenuAction.settings:
                      onOpenSettings();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _HomeHeaderMenuAction.refresh,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.refresh_rounded),
                      title: Text('Refresh'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _HomeHeaderMenuAction.settings,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.tune_rounded),
                      title: Text('Settings'),
                    ),
                  ),
                ],
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: AppShapes.input,
                    border: Border.all(color: colors.border),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.more_horiz_rounded,
                    color: colors.textSecondary,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: primaryAction.onTap,
              icon: Icon(primaryAction.icon, size: 18),
              label: Text(primaryAction.label),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: searchVisible
                ? _HomeSearchField(
                    controller: searchController,
                    hintText: 'Search ${tab.title.toLowerCase()}',
                    viewMode: viewMode,
                    onViewModeChanged: onViewModeChanged,
                    recentFilters: recentFilters,
                    onRunningOnlyChanged: onRunningOnlyChanged,
                    onUnreadOnlyChanged: onUnreadOnlyChanged,
                  )
                : const SizedBox(key: ValueKey('no-search'), height: 0),
          ),
        ],
      ),
    );
  }
}

class _HomeSearchField extends StatelessWidget {
  const _HomeSearchField({
    required this.controller,
    required this.hintText,
    this.viewMode,
    this.onViewModeChanged,
    this.recentFilters,
    this.onRunningOnlyChanged,
    this.onUnreadOnlyChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final SessionViewMode? viewMode;
  final ValueChanged<SessionViewMode>? onViewModeChanged;
  final RecentSessionFilters? recentFilters;
  final ValueChanged<bool>? onRunningOnlyChanged;
  final ValueChanged<bool>? onUnreadOnlyChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final filters = recentFilters;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
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
                suffixIcon: controller.text.isNotEmpty
                    ? IconButton(
                        tooltip: 'Clear',
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
                  borderRadius: AppShapes.pill,
                  borderSide: BorderSide(color: colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: AppShapes.pill,
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: AppShapes.pill,
                  borderSide: BorderSide(color: colors.accent, width: 1.2),
                ),
              ),
            ),
            if (viewMode != null ||
                (filters != null &&
                    (onRunningOnlyChanged != null ||
                        onUnreadOnlyChanged != null))) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  if (viewMode != null && onViewModeChanged != null)
                    PopupMenuButton<SessionViewMode>(
                      tooltip: 'View mode',
                      onSelected: onViewModeChanged,
                      itemBuilder: (context) => [
                        for (final mode in SessionViewMode.values)
                          PopupMenuItem(
                            value: mode,
                            child: Row(
                              children: [
                                Icon(_sessionViewModeIcon(mode), size: 18),
                                const SizedBox(width: 10),
                                Text(_sessionViewModeLabel(mode)),
                                if (viewMode == mode) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.check_rounded, size: 16),
                                ],
                              ],
                            ),
                          ),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: AppShapes.pill,
                          border: Border.all(color: colors.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _sessionViewModeIcon(viewMode!),
                              size: 16,
                              color: colors.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _sessionViewModeLabel(viewMode!),
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: colors.textPrimary,
                                    fontWeight: AppWeights.emphasis,
                                  ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.expand_more_rounded,
                              size: 16,
                              color: colors.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (filters != null) ...[
                    FilterChip(
                      label: const Text('Running'),
                      selected: filters.runningOnly,
                      onSelected: onRunningOnlyChanged,
                      visualDensity: VisualDensity.compact,
                    ),
                    FilterChip(
                      label: const Text('Unread'),
                      selected: filters.unreadOnly,
                      onSelected: onUnreadOnlyChanged,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
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
                    borderRadius: AppShapes.input,
                    onTap: () => onTap(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                        color: selected
                            ? colors.accentMuted
                            : Colors.transparent,
                        borderRadius: AppShapes.input,
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
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: selected
                                      ? colors.accent
                                      : colors.textSecondary,
                                  fontWeight: AppWeights.emphasis,
                                ),
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
                  fontWeight: AppWeights.emphasis,
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
    this.viewMode = SessionViewMode.flat,
    this.filters = const RecentSessionFilters(),
    this.onViewModeChanged,
    this.onAddHost,
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
  final SessionViewMode viewMode;
  final RecentSessionFilters filters;
  final ValueChanged<SessionViewMode>? onViewModeChanged;
  final VoidCallback? onAddHost;

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

List<String> _mergeHostLabels(List<String> a, List<String> b) {
  final labels = <String>{
    ...a.where((label) => label.trim().isNotEmpty),
    ...b.where((label) => label.trim().isNotEmpty),
  }.toList();
  labels.sort();
  return labels;
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

@immutable
class _SessionGroup {
  const _SessionGroup({required this.title, required this.entries});
  final String title;
  final List<RemoteSessionEntry> entries;
}

class _RecentPaneState extends State<RecentPane> {
  final SessionLocalStore _localStore = SessionLocalStore.instance;
  final RecentSessionsStore _store = RecentSessionsStore();

  // Search mode state
  List<RemoteSessionEntry>? _searchEntries;
  List<String> _searchFailedHostLabels = const <String>[];
  bool _searchLoading = false;
  Timer? _searchDebounce;
  int _searchRequestId = 0;

  @override
  void initState() {
    super.initState();

    _localStore.ensureLoaded();
    SessionReadStore.instance.ensureLoaded();
    _store.addListener(_handleStoreChanged);
    _store.configure(hosts: widget.hosts, api: widget.api);
  }

  String _cwdBasename(String cwd) {
    if (cwd.isEmpty || cwd == '/') return 'Unknown';
    final parts = cwd.split('/');
    return parts.lastWhere((p) => p.isNotEmpty, orElse: () => 'Unknown');
  }

  List<_SessionGroup> _groupEntries(List<RemoteSessionEntry> entries) {
    if (widget.viewMode == SessionViewMode.flat) return const [];
    final groups = <String, List<RemoteSessionEntry>>{};
    for (final entry in entries) {
      final key = switch (widget.viewMode) {
        SessionViewMode.byCwd => _cwdBasename(entry.session.cwd),
        SessionViewMode.byHost => entry.host.label,
        SessionViewMode.flat => '',
      };
      (groups[key] ??= []).add(entry);
    }
    for (final list in groups.values) {
      list.sort((a, b) => b.session.updatedAt.compareTo(a.session.updatedAt));
    }
    final sortedKeys = groups.keys.toList()
      ..sort((a, b) {
        if (a == 'Unknown') return 1;
        if (b == 'Unknown') return -1;
        return a.compareTo(b);
      });
    return sortedKeys
        .map((k) => _SessionGroup(title: k, entries: groups[k]!))
        .toList();
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
    if (widget.query != oldWidget.query ||
        !_sameHostList(widget.hosts, oldWidget.hosts)) {
      _onQueryChanged(widget.query);
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

  void _onQueryChanged(String query) {
    _searchDebounce?.cancel();
    _searchRequestId++;
    final trimmed = query.trim();
    if (trimmed.isEmpty || trimmed.length < 2) {
      if (mounted) {
        setState(() {
          _searchEntries = null;
          _searchFailedHostLabels = const <String>[];
          _searchLoading = false;
        });
      }
      return;
    }
    final requestId = _searchRequestId;
    if (mounted) {
      setState(() => _searchLoading = true);
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _performSearch(trimmed, requestId);
    });
  }

  Future<void> _performSearch(String query, int requestId) async {
    if (!mounted) return;
    final hosts = widget.hosts.where((h) => h.enabled).toList();
    if (hosts.isEmpty) {
      if (mounted && requestId == _searchRequestId) {
        setState(() {
          _searchEntries = [];
          _searchFailedHostLabels = const <String>[];
          _searchLoading = false;
        });
      }
      return;
    }

    final results = <RemoteSessionEntry>[];
    final failedHostLabels = <String>[];
    await Future.wait(
      hosts.map((host) async {
        try {
          final sessions = await widget.api.searchSessions(
            host,
            query: query,
            limit: 40,
          );
          for (final session in sessions) {
            results.add(RemoteSessionEntry(host: host, session: session));
          }
        } catch (_) {
          failedHostLabels.add(host.label);
        }
      }),
      eagerError: false,
    );

    if (!mounted ||
        requestId != _searchRequestId ||
        widget.query.trim() != query) {
      return;
    }
    final dedupedResults = _dedupeSearchEntries(results)
      ..sort(_compareSearchEntryRank);

    setState(() {
      _searchEntries = dedupedResults;
      _searchFailedHostLabels = failedHostLabels.toSet().toList()..sort();
      _searchLoading = false;
    });
  }

  List<RemoteSessionEntry> _dedupeSearchEntries(
    List<RemoteSessionEntry> entries,
  ) {
    final bestByKey = <String, RemoteSessionEntry>{};
    for (final entry in entries) {
      final key = _searchDedupKey(entry);
      final existing = bestByKey[key];
      if (existing == null || _compareSearchEntryRank(entry, existing) < 0) {
        bestByKey[key] = entry;
      }
    }
    return bestByKey.values.toList(growable: false);
  }

  String _searchDedupKey(RemoteSessionEntry entry) {
    final session = entry.session;
    return [session.provider ?? '', session.id].join('\n');
  }

  int _compareSearchEntryRank(
    RemoteSessionEntry left,
    RemoteSessionEntry right,
  ) {
    final leftRank = left.session.matchRank;
    final rightRank = right.session.matchRank;
    if (leftRank != null || rightRank != null) {
      if (leftRank == null) return 1;
      if (rightRank == null) return -1;
      final rankCompare = leftRank.toDouble().compareTo(rightRank.toDouble());
      if (rankCompare != 0) {
        return rankCompare;
      }
    }

    final updatedCompare = right.session.updatedAt.compareTo(
      left.session.updatedAt,
    );
    if (updatedCompare != 0) {
      return updatedCompare;
    }
    return left.session.id.compareTo(right.session.id);
  }

  bool _matchesRecentFilters(RemoteSessionEntry entry) {
    final filters = widget.filters;
    if (filters.runningOnly && !entry.session.isActive) {
      return false;
    }
    if (filters.unreadOnly &&
        !SessionReadStore.instance.isUnread(entry.host, entry.session)) {
      return false;
    }
    return true;
  }

  String _emptyStateTitle() {
    if (_searchLoading) {
      return 'Searching…';
    }
    if (widget.query.trim().isNotEmpty) {
      return 'No matches';
    }
    if (widget.filters.runningOnly && widget.filters.unreadOnly) {
      return 'No running unread sessions';
    }
    if (widget.filters.runningOnly) {
      return 'No running sessions';
    }
    if (widget.filters.unreadOnly) {
      return 'No unread sessions';
    }
    return 'No reachable sessions';
  }

  String _emptyStateBody() {
    if (widget.query.trim().isNotEmpty) {
      if (_searchLoading) {
        return 'Looking across all your sessions…';
      }
      return 'No sessions match "${widget.query.trim()}". Clear the filter to see everything.';
    }
    if (widget.filters.runningOnly && widget.filters.unreadOnly) {
      return 'No sessions are both active and unread right now.';
    }
    if (widget.filters.runningOnly) {
      return 'No agents are active right now.';
    }
    if (widget.filters.unreadOnly) {
      return 'Everything in recents has already been read on this device.';
    }
    return 'Saved hosts look fine, but none returned recent sessions right now.';
  }

  List<RemoteSessionEntry> _sortEntries(List<RemoteSessionEntry> entries) {
    final isSearchResults = _searchEntries != null;
    final overrides = SessionOverridesStore.instance;
    final sourceEntries = _searchEntries ?? entries;
    final overlaid = sourceEntries
        .map(
          (entry) => RemoteSessionEntry(
            host: entry.host,
            session: overrides.overlay(entry.host.id, entry.session),
          ),
        )
        .toList();
    final query = widget.query.trim().toLowerCase();
    Iterable<RemoteSessionEntry> visible = overlaid;
    if (_searchEntries == null && query.isNotEmpty) {
      visible = overlaid.where((entry) {
        return recentSessionMatchesQuery(entry.host, entry.session, query);
      });
    }
    visible = visible.where(_matchesRecentFilters);
    final sorted = visible.toList();
    // Preserve server relevance order for remote search results.
    if (!isSearchResults && widget.viewMode == SessionViewMode.flat) {
      sorted.sort(
        (left, right) =>
            right.session.updatedAt.compareTo(left.session.updatedAt),
      );
    }
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hosts.isEmpty) {
      if (!widget.hasSavedHosts) {
        // No hosts at all — show a clear call-to-action to add one
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const MeshEmptyState(
                  icon: Icons.hub_rounded,
                  title: 'Connect a machine',
                  body:
                      'Add a host to check sessions, approvals, files, and terminals from this device.',
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  onPressed: widget.onAddHost,
                  icon: const Icon(Icons.add_link_rounded),
                  label: const Text('Add your first host'),
                ),
              ],
            ),
          ),
        );
      }
      return const MeshEmptyState(
        icon: Icons.pause_circle_outline_rounded,
        title: 'No enabled hosts',
        body: 'Enable a saved host from Hosts to load recent sessions.',
      );
    }

    return ListenableBuilder(
      listenable: Listenable.merge([
        _store,
        SessionLocalStore.instance,
        HostStatusStore.instance,
        SessionOverridesStore.instance,
        SessionReadStore.instance,
      ]),
      builder: (context, _) {
        final stillLoadingInitial =
            !_store.hasLoadedOnce &&
            _store.entries.isEmpty &&
            _store.failedHostLabels.isEmpty &&
            _store.pendingHostIds.isNotEmpty;
        if (stillLoadingInitial) {
          return const MeshLoader();
        }
        final sortedEntries = _sortEntries(_store.entries);
        // Pinned shelf: only surface it when it actively helps.
        final showPinnedShelf =
            widget.viewMode == SessionViewMode.flat &&
            widget.query.trim().isEmpty &&
            !widget.filters.isAnyActive &&
            _searchEntries == null;
        final pinnedEntries = showPinnedShelf
            ? sortedEntries
                  .where((e) => _localStore.isFavorite(e.host, e.session.id))
                  .toList(growable: false)
            : const <RemoteSessionEntry>[];
        final listEntries =
            showPinnedShelf && widget.dense && pinnedEntries.isNotEmpty
            ? sortedEntries
                  .where((e) => !_localStore.isFavorite(e.host, e.session.id))
                  .toList(growable: false)
            : sortedEntries;
        final groups = _groupEntries(listEntries);
        final isGrouped = groups.isNotEmpty;
        final hasCachedEntries =
            _store.entries.isNotEmpty &&
            _store.confirmedHostIds.length < widget.hosts.length;
        final isRefreshing = _store.pendingHostIds.isNotEmpty;
        final failureLabels = _mergeHostLabels(
          _store.failedHostLabels,
          _searchFailedHostLabels,
        );
        final hasFailures = failureLabels.isNotEmpty;
        final noResults = sortedEntries.isEmpty;
        final basePadding =
            widget.padding ??
            (widget.dense
                ? const EdgeInsets.fromLTRB(6, 4, 6, 24)
                : const EdgeInsets.fromLTRB(16, 8, 16, 32));
        Future<void> handleRefresh() async {
          await _store.refresh();
          if (widget.query.trim().length >= 2) {
            _onQueryChanged(widget.query);
          }
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
                    hostLabels: failureLabels,
                    onRetry: handleRefresh,
                  ),
                const SizedBox(height: 80),
                MeshEmptyState(
                  icon: widget.query.trim().isEmpty
                      ? (widget.filters.isAnyActive
                            ? Icons.filter_alt_off_rounded
                            : Icons.cloud_off_rounded)
                      : Icons.search_off_rounded,
                  title: _emptyStateTitle(),
                  body: _emptyStateBody(),
                ),
              ],
            ),
          );
        }
        final leadingStrips = (isRefreshing ? 1 : 0) + (hasFailures ? 1 : 0);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_searchLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            if (showPinnedShelf && pinnedEntries.isNotEmpty)
              _FavoritesShelf(
                entries: pinnedEntries,
                onOpen: widget.onOpenSession,
                onUnpin: (host, sessionId) =>
                    _localStore.toggleFavorite(host, sessionId),
                dense: widget.dense,
              ),
            SizedBox(height: widget.dense ? 4 : 8),
            Expanded(
              child: RefreshIndicator(
                color: context.colors.accent,
                onRefresh: handleRefresh,
                child: isGrouped
                    ? _buildGroupedList(
                        context,
                        groups,
                        isRefreshing: isRefreshing,
                        hasFailures: hasFailures,
                        failureLabels: failureLabels,
                        hasCachedEntries: hasCachedEntries,
                        handleRefresh: handleRefresh,
                      )
                    : ListView.separated(
                        padding: basePadding,
                        itemCount: listEntries.length + leadingStrips,
                        separatorBuilder: (_, _) =>
                            SizedBox(height: widget.dense ? 2 : AppSpacing.sm),
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
                                hostLabels: failureLabels,
                                onRetry: handleRefresh,
                              );
                            }
                            offset += 1;
                          }
                          final entry = listEntries[index - offset];
                          return _buildSessionRow(entry);
                        },
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildGroupedList(
    BuildContext context,
    List<_SessionGroup> groups, {
    required bool isRefreshing,
    required bool hasFailures,
    required List<String> failureLabels,
    required bool hasCachedEntries,
    required Future<void> Function() handleRefresh,
  }) {
    final padding =
        widget.padding ??
        (widget.dense
            ? const EdgeInsets.fromLTRB(6, 4, 6, 24)
            : const EdgeInsets.fromLTRB(16, 8, 16, 32));
    return ListView.builder(
      padding: padding,
      itemCount:
          (isRefreshing ? 1 : 0) +
          (hasFailures ? 1 : 0) +
          groups.fold<int>(0, (sum, g) => sum + g.entries.length + 1),
      itemBuilder: (context, index) {
        var offset = 0;
        if (isRefreshing) {
          if (index == offset) {
            return Padding(
              padding: EdgeInsets.only(bottom: widget.dense ? 6 : 10),
              child: _RecentProgressStrip(
                remaining: _store.pendingHostIds.length,
                total: widget.hosts.length,
                showingCached: hasCachedEntries,
              ),
            );
          }
          offset += 1;
        }
        if (hasFailures) {
          if (index == offset) {
            return Padding(
              padding: EdgeInsets.only(bottom: widget.dense ? 6 : 10),
              child: _RecentErrorBanner(
                hostLabels: failureLabels,
                onRetry: handleRefresh,
              ),
            );
          }
          offset += 1;
        }
        var current = offset;
        for (final group in groups) {
          final headerIndex = current;
          final entriesStart = headerIndex + 1;
          final entriesEnd = entriesStart + group.entries.length;
          if (index == headerIndex) {
            return Padding(
              padding: EdgeInsets.only(
                top: widget.dense ? 8 : 14,
                bottom: widget.dense ? 4 : 8,
              ),
              child: _buildSessionSectionHeader(
                context,
                title: group.title,
                icon: widget.viewMode == SessionViewMode.byCwd
                    ? Icons.folder_rounded
                    : Icons.hub_rounded,
                count: group.entries.length,
              ),
            );
          }
          if (index >= entriesStart && index < entriesEnd) {
            final entry = group.entries[index - entriesStart];
            return Padding(
              padding: EdgeInsets.only(
                bottom: widget.dense ? 2 : AppSpacing.sm,
              ),
              child: _buildSessionRow(entry),
            );
          }
          current = entriesEnd;
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildSessionSectionHeader(
    BuildContext context, {
    required String title,
    required IconData icon,
    required int count,
  }) {
    final colors = context.colors;
    return Row(
      children: [
        Icon(icon, size: 14, color: colors.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: widget.dense ? 10 : 11,
              fontWeight: AppWeights.emphasis,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: colors.surfaceElevated,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors.border),
          ),
          child: Text(
            '$count',
            style: monoStyle(
              color: colors.textTertiary,
              fontSize: 10,
              fontWeight: AppWeights.emphasis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSessionRow(RemoteSessionEntry entry) {
    return SessionRowCard(
      host: entry.host,
      session: entry.session,
      favorite: _localStore.isFavorite(entry.host, entry.session.id),
      selected: widget.selectedSessionId == entry.session.id,
      dense: widget.dense,
      query: widget.query,
      onTap: () {
        _localStore.updateGhost(entry.host, entry.session);
        widget.onOpenSession(entry.host, entry.session);
      },
      onToggleFavorite: () {
        _localStore.toggleFavorite(entry.host, entry.session.id);
      },
    );
  }
}

// ── Pinned / Favourites Shelf ────────────────────────────────────────────────

/// Compact horizontal strip of pinned sessions rendered above the recents list.
/// Only shown when there are pins to surface.
class _FavoritesShelf extends StatelessWidget {
  const _FavoritesShelf({
    required this.entries,
    required this.onOpen,
    required this.onUnpin,
    this.dense = false,
  });

  final List<RemoteSessionEntry> entries;
  final void Function(HostProfile, SessionSummary) onOpen;
  final void Function(HostProfile host, String sessionId) onUnpin;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    if (dense) {
      final visibleRows = entries.length > 3 ? 3 : entries.length;
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.push_pin_rounded, size: 13, color: colors.warning),
                const SizedBox(width: 6),
                Text(
                  'Pinned',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                const Spacer(),
                Text(
                  '${entries.length}',
                  style: monoStyle(
                    color: colors.textTertiary,
                    fontSize: 10,
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: visibleRows * 48.0 + (visibleRows - 1) * 3.0,
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 3),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return _FavoritePinnedRow(
                    entry: entry,
                    onTap: () => onOpen(entry.host, entry.session),
                    onUnpin: () => onUnpin(entry.host, entry.session.id),
                  );
                },
              ),
            ),
          ],
        ),
      );
    }
    final horizontalPadding = dense ? 10.0 : 16.0;
    final chipWidth = dense ? 156.0 : 184.0;
    final listHeight = dense ? 68.0 : 74.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            dense ? 6 : 10,
            horizontalPadding,
            4,
          ),
          child: Row(
            children: [
              Text(
                'Pinned',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.textSecondary,
                  fontWeight: AppWeights.emphasis,
                ),
              ),
              const Spacer(),
              Text(
                '${entries.length} ${entries.length == 1 ? "session" : "sessions"}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textTertiary,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              0,
              horizontalPadding,
              dense ? 6 : 8,
            ),
            itemCount: entries.length,
            separatorBuilder: (_, _) => SizedBox(width: dense ? 8 : 10),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _FavoriteChip(
                entry: entry,
                width: chipWidth,
                dense: dense,
                onTap: () => onOpen(entry.host, entry.session),
                onUnpin: () => onUnpin(entry.host, entry.session.id),
              );
            },
          ),
        ),
        SizedBox(height: dense ? 2 : 6),
      ],
    );
  }
}

class _FavoritePinnedRow extends StatelessWidget {
  const _FavoritePinnedRow({
    required this.entry,
    required this.onTap,
    required this.onUnpin,
  });

  final RemoteSessionEntry entry;
  final VoidCallback onTap;
  final VoidCallback onUnpin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final running = entry.session.isActive;
    return Tooltip(
      message: entry.session.title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: Container(
            height: 48,
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              children: [
                running
                    ? LivePulse(color: colors.success)
                    : Icon(
                        Icons.push_pin_outlined,
                        size: 14,
                        color: colors.warning,
                      ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: AppWeights.emphasis,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.host.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.textTertiary,
                          height: 1.1,
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: onUnpin,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.star_rounded,
                      size: 15,
                      color: colors.warning,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FavoriteChip extends StatelessWidget {
  const _FavoriteChip({
    required this.entry,
    required this.width,
    required this.dense,
    required this.onTap,
    required this.onUnpin,
  });

  final RemoteSessionEntry entry;
  final double width;
  final bool dense;
  final VoidCallback onTap;
  final VoidCallback onUnpin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final running = entry.session.isActive;
    return Tooltip(
      message:
          '${entry.session.title}\n${entry.host.label}\n'
          'Long-press to remove from pinned',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onUnpin,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            width: width,
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 12 : 14,
              vertical: dense ? 8 : 9,
            ),
            decoration: BoxDecoration(
              color: running ? colors.successMuted : colors.surfaceMuted,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: running
                    ? colors.success.withValues(alpha: 0.32)
                    : colors.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (running)
                      LivePulse(color: colors.success)
                    else
                      Icon(
                        Icons.push_pin_outlined,
                        size: 14,
                        color: colors.textTertiary,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: AppWeights.emphasis,
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
                        entry.host.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      sessionTimeLabel(entry.session.updatedAt),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
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
    PendingActionResponseDraft response,
  ) async {
    try {
      await widget.api.respondToAction(
        host,
        actionId: action.id,
        response: response,
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
    final cached = await SessionLocalStore.instance.getRecentSessions(host);
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
    final query = widget.query.trim();
    final allPending = _pendingSends;
    final pending = query.isEmpty
        ? allPending
        : allPending
              .where((send) {
                final analysis = _analyzePendingSend(send);
                final haystack = [
                  _pendingSendPreview(send),
                  send.sessionId,
                  send.lastError ?? '',
                  analysis.hostLabel,
                  _pendingSendIssueLabel(analysis.issue) ?? '',
                ].join('\n');
                return matchesSearchQuery(haystack, query);
              })
              .toList(growable: false);

    if (widget.allHosts.isEmpty && allPending.isEmpty) {
      return MeshEmptyState(
        icon: widget.hasSavedHosts
            ? Icons.notifications_paused_rounded
            : Icons.checklist_rounded,
        title: widget.hasSavedHosts
            ? 'No enabled hosts'
            : 'Nothing needs attention',
        body: widget.hasSavedHosts
            ? 'Turn on a saved host to review approvals here.'
            : 'Add a host to review approvals and stuck messages from anywhere.',
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
            final haystack = [
              a.sessionTitle ?? '',
              a.detail,
              a.cwd ?? '',
              entry.host.label,
            ].join('\n');
            return matchesSearchQuery(haystack, query);
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
              title: 'Queued',
              subtitle: pending.length == 1
                  ? '1 message waiting to send'
                  : '${pending.length} messages waiting to send',
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
              title: 'Needs review',
              subtitle: entries.length == 1
                  ? '1 item waiting for your reply'
                  : '${entries.length} items waiting for your reply',
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
                    'No queued messages or requests match "${widget.query.trim()}".',
              )
            else
              const MeshEmptyState(
                icon: Icons.verified_rounded,
                title: 'Inbox is clear',
                body:
                    'Queued sends and agent requests from your nodes will show up here.',
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
        Icon(icon, size: 16, color: colors.textTertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: AppWeights.emphasis,
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
    final hostMeta = analysis.hostLabel;
    final stateTone = _pendingSendStateTone(analysis.state);
    final stateLabel = _pendingSendStateLabel(analysis.state);
    final stateIcon = _pendingSendStateIcon(analysis.state);
    final issueLabel = _pendingSendIssueLabel(analysis.issue);
    final borderTone = analysis.needsAttention
        ? colors.warning.withValues(alpha: 0.55)
        : colors.info.withValues(alpha: 0.45);

    if (dense) {
      return MeshCard(
        tone: MeshCardTone.surface,
        borderColor: borderTone,
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
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MeshStatusBadge(
                  label: stateLabel,
                  tone: stateTone,
                  icon: stateIcon,
                  compact: true,
                ),
              ],
            ),
            if (issueLabel != null) ...[
              const SizedBox(height: 6),
              MeshStatusBadge(
                label: issueLabel,
                tone: _pendingSendIssueTone(analysis.issue),
                icon: _pendingSendIssueIcon(analysis.issue),
                compact: true,
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
                    icon: Icons.edit_rounded,
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
                    fontWeight: AppWeights.title,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              MeshStatusBadge(
                label: stateLabel,
                tone: stateTone,
                icon: stateIcon,
                compact: true,
              ),
            ],
          ),
          if (issueLabel != null) ...[
            const SizedBox(height: 8),
            MeshStatusBadge(
              label: issueLabel,
              tone: _pendingSendIssueTone(analysis.issue),
              icon: _pendingSendIssueIcon(analysis.issue),
              compact: true,
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
                  label: 'Open',
                  onTap: onOpenSession,
                ),
              if (onEditCopy != null)
                _PendingSendActionChip(
                  icon: Icons.edit_rounded,
                  label: 'Edit',
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
    if (destructive) {
      return MeshDangerAction(label: label, icon: icon, onPressed: onTap);
    }
    final fg = disabled ? colors.textTertiary : colors.textPrimary;
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      radius: 999,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      enabled: !disabled,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: fg,
              fontWeight: AppWeights.emphasis,
            ),
          ),
        ],
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
    return '$reason ${_pendingSendPreview(send)}';
  }
  final suffix = error == null || error.isEmpty || error == reason
      ? ''
      : ' · $error';
  return '$nextAttempt · ${_pendingSendPreview(send)}$suffix';
}

String _pendingSendRecoveryMessage(PendingSendAnalysis analysis) {
  return switch (analysis.issue) {
    PendingSendIssueKind.hostDisabled =>
      'Turn this host back on before retrying.',
    PendingSendIssueKind.hostMissing =>
      'The original host is gone. Discard this message or bind it again.',
    PendingSendIssueKind.hostChanged =>
      'This host changed since the message was queued. Check it before retrying.',
    PendingSendIssueKind.unauthorized =>
      'This host token is no longer valid. Fix the host, then retry.',
    PendingSendIssueKind.timeout => 'The host is taking too long to respond.',
    PendingSendIssueKind.unreachable => "Can't reach this host right now.",
    PendingSendIssueKind.server =>
      'The host reported a temporary server problem.',
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

MeshStatusTone _pendingSendStateTone(PendingSendDisplayState state) {
  return switch (state) {
    PendingSendDisplayState.queued => MeshStatusTone.queued,
    PendingSendDisplayState.retrying => MeshStatusTone.running,
    PendingSendDisplayState.blocked => MeshStatusTone.waiting,
  };
}

IconData _pendingSendStateIcon(PendingSendDisplayState state) {
  return switch (state) {
    PendingSendDisplayState.queued => Icons.schedule_rounded,
    PendingSendDisplayState.retrying => Icons.sync_rounded,
    PendingSendDisplayState.blocked => Icons.pause_circle_outline_rounded,
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

MeshStatusTone _pendingSendIssueTone(PendingSendIssueKind issue) {
  return switch (issue) {
    PendingSendIssueKind.none => MeshStatusTone.neutral,
    PendingSendIssueKind.timeout => MeshStatusTone.queued,
    PendingSendIssueKind.unreachable => MeshStatusTone.offline,
    PendingSendIssueKind.rateLimited => MeshStatusTone.queued,
    PendingSendIssueKind.server => MeshStatusTone.waiting,
    PendingSendIssueKind.hostDisabled => MeshStatusTone.waiting,
    PendingSendIssueKind.hostMissing => MeshStatusTone.danger,
    PendingSendIssueKind.hostChanged => MeshStatusTone.danger,
    PendingSendIssueKind.unauthorized => MeshStatusTone.danger,
    PendingSendIssueKind.unknown => MeshStatusTone.waiting,
  };
}

IconData _pendingSendIssueIcon(PendingSendIssueKind issue) {
  return switch (issue) {
    PendingSendIssueKind.none => Icons.info_outline_rounded,
    PendingSendIssueKind.timeout => Icons.timer_outlined,
    PendingSendIssueKind.unreachable => Icons.wifi_off_rounded,
    PendingSendIssueKind.rateLimited => Icons.hourglass_top_rounded,
    PendingSendIssueKind.server => Icons.dns_rounded,
    PendingSendIssueKind.hostDisabled => Icons.pause_circle_outline_rounded,
    PendingSendIssueKind.hostMissing => Icons.dns_rounded,
    PendingSendIssueKind.hostChanged => Icons.sync_problem_rounded,
    PendingSendIssueKind.unauthorized => Icons.key_off_rounded,
    PendingSendIssueKind.unknown => Icons.report_problem_outlined,
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

String _hostEndpointLabel(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || uri.host.isEmpty) {
    return baseUrl.trim();
  }
  final hasDefaultPort =
      !uri.hasPort ||
      (uri.scheme == 'http' && uri.port == 80) ||
      (uri.scheme == 'https' && uri.port == 443);
  return hasDefaultPort ? uri.host : '${uri.host}:${uri.port}';
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
  final ValueChanged<PendingActionResponseDraft> onRespond;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final action = entry.action;
    final hostMeta = action.sessionTitle == null || action.sessionTitle!.isEmpty
        ? entry.host.label
        : '${entry.host.label} · ${action.sessionTitle}';
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
                                    fontWeight: AppWeights.body,
                                    height: 1.25,
                                  ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          MeshStatusBadge(
                            label: _actionKindLabel(action.kind),
                            tone: _actionKindTone(action.kind),
                            icon: _actionKindIcon(action.kind),
                            compact: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        hostMeta,
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
      borderColor: colors.warning.withValues(alpha: 0.55),
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
                    fontWeight: AppWeights.emphasis,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              MeshStatusBadge(
                label: _actionKindLabel(action.kind),
                tone: _actionKindTone(action.kind),
                icon: _actionKindIcon(action.kind),
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            hostMeta,
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
                  onTap: () => onRespond(
                    PendingActionResponseDraft.approval('acceptForSession'),
                  ),
                ),
              if (action.canDecline) ...[
                if (action.canApproveForSession) const SizedBox(width: 8),
                _MobileInboxAction(
                  icon: Icons.close_rounded,
                  tooltip: 'Decline',
                  foreground: colors.danger,
                  background: colors.danger.withValues(alpha: 0.12),
                  onTap: () =>
                      onRespond(PendingActionResponseDraft.approval('decline')),
                ),
              ],
              if (action.canApprove) ...[
                const SizedBox(width: 8),
                _MobileInboxAction(
                  icon: Icons.check_rounded,
                  tooltip: 'Approve',
                  foreground: Colors.white,
                  background: colors.success,
                  onTap: () =>
                      onRespond(PendingActionResponseDraft.approval('accept')),
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
    'permissions' => 'access',
    'user_input' => 'reply',
    'elicitation' => 'form',
    _ => kind,
  };
}

MeshStatusTone _actionKindTone(String kind) {
  return switch (kind) {
    'user_input' => MeshStatusTone.waiting,
    'elicitation' => MeshStatusTone.queued,
    _ => MeshStatusTone.approval,
  };
}

IconData _actionKindIcon(String kind) {
  return switch (kind) {
    'user_input' => Icons.chat_bubble_outline_rounded,
    'elicitation' => Icons.fact_check_rounded,
    'file_change' => Icons.description_outlined,
    'command' => Icons.terminal_rounded,
    _ => Icons.shield_rounded,
  };
}

/// Compact approve/decline cluster used by the dense inbox rows in the
/// desktop sidebar so users can resolve pending actions without having
/// to open the chat.
class _InboxDenseActions extends StatelessWidget {
  const _InboxDenseActions({required this.action, required this.onRespond});

  final PendingAction action;
  final ValueChanged<PendingActionResponseDraft> onRespond;

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
            onTap: () =>
                onRespond(PendingActionResponseDraft.approval('accept')),
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
            onTap: () =>
                onRespond(PendingActionResponseDraft.approval('decline')),
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
    if (result != null) {
      onRespond(PendingActionResponseDraft.approval(result));
    }
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
    required this.hostNodes,
    required this.installedAppVersion,
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
  final Map<String, NodeInfo> hostNodes;
  final String installedAppVersion;
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
                title: 'No machines yet',
                body: 'Add a laptop, desktop, or server to reach it from here.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onAddHost,
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Add a machine'),
              ),
            ],
          ),
        ),
      );
    }

    final q = query.trim();
    final visibleHosts = q.isEmpty
        ? hosts
        : hosts
              .where((h) => matchesSearchQuery('${h.label}\n${h.baseUrl}', q))
              .toList();
    if (visibleHosts.isEmpty) {
      return MeshEmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matching machines',
        body: 'No machines match "${query.trim()}".',
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
          node: hostNodes[host.id],
          installedAppVersion: installedAppVersion,
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
    this.node,
    required this.installedAppVersion,
    required this.onTap,
    required this.onEdit,
    required this.onRemove,
    required this.onToggleEnabled,
    this.dense = false,
    this.selected = false,
  });

  final HostProfile host;
  final NodeInfo? node;
  final String installedAppVersion;
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
        final compatibility = node == null || !host.enabled
            ? MobileClientCompatibility.none
            : evaluateMobileClientCompatibility(
                installedVersion: installedAppVersion,
                recommendedVersion: node!.recommendedMobileClientVersion,
                minimumVersion: node!.minimumMobileClientVersion,
              );
        final hostStatusBadge = _hostStatusBadge(status, host.enabled);
        final endpointLabel = _hostEndpointLabel(host.baseUrl);
        if (dense) {
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: host.enabled ? onTap : null,
              borderRadius: BorderRadius.circular(AppRadii.control),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.fromLTRB(10, 9, 6, 10),
                decoration: BoxDecoration(
                  color: selected ? colors.accentMuted : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadii.control),
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
                                  fontWeight: AppWeights.body,
                                  height: 1.25,
                                  color: host.enabled
                                      ? (selected ? colors.accent : null)
                                      : colors.textTertiary,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            host.enabled ? endpointLabel : 'Disabled',
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
                    const SizedBox(width: 8),
                    _HostRowActionsMenu(
                      hostEnabled: host.enabled,
                      onToggleEnabled: onToggleEnabled,
                      onEdit: onEdit,
                      onRemove: onRemove,
                      compact: true,
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        final showStatusLine =
            !host.enabled || status.reachability != HostReachability.unknown;
        final supplementalBadges = <Widget>[
          if (node?.updateAvailable == true && !dense)
            MeshPill(
              label: node?.usesBleedingEdgeTrack == true
                  ? 'New commits'
                  : 'App update',
              icon: Icons.system_update_alt_rounded,
              tone: MeshPillTone.warning,
            ),
          if (compatibility.level == MobileClientCompatibilityLevel.required)
            MeshPill(
              label:
                  'Mobile ${mobileClientVersionLabel(compatibility.targetVersion)} needed',
              icon: Icons.phone_android_rounded,
              tone: MeshPillTone.danger,
            )
          else if (compatibility.level ==
              MobileClientCompatibilityLevel.recommended)
            MeshPill(
              label:
                  'Mobile ${mobileClientVersionLabel(compatibility.targetVersion)} recommended',
              icon: Icons.phone_android_rounded,
              tone: MeshPillTone.info,
            ),
        ];
        return MeshSurface(
          onTap: host.enabled ? onTap : null,
          selected: selected,
          enabled: host.enabled,
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: colors.accentMuted,
                          borderRadius: BorderRadius.circular(AppRadii.control),
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
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                host.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      fontWeight: AppWeights.emphasis,
                                      color: host.enabled
                                          ? null
                                          : colors.textTertiary,
                                    ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            hostStatusBadge,
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          endpointLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(
                            color: host.enabled
                                ? colors.textSecondary
                                : colors.textTertiary,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  _HostRowActionsMenu(
                    hostEnabled: host.enabled,
                    onToggleEnabled: onToggleEnabled,
                    onEdit: onEdit,
                    onRemove: onRemove,
                    compact: false,
                  ),
                ],
              ),
              if (showStatusLine || supplementalBadges.isNotEmpty) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 56),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showStatusLine)
                        ListenableBuilder(
                          listenable: RelativeTimeTicker.minutes,
                          builder: (context, _) {
                            return Text(
                              _statusLine(status),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: monoStyle(
                                color: _statusColor(colors, status),
                                fontSize: 10.5,
                                fontWeight: AppWeights.body,
                              ),
                            );
                          },
                        ),
                      if (showStatusLine && supplementalBadges.isNotEmpty)
                        const SizedBox(height: 8),
                      if (supplementalBadges.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: supplementalBadges,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  String _statusLine(HostStatus status) {
    if (!host.enabled) return 'This machine is turned off in Sidemesh.';
    switch (status.reachability) {
      case HostReachability.online:
        final last = status.lastEventAt ?? status.lastOnlineAt;
        if (last != null) {
          final elapsed = DateTime.now().difference(last);
          if (elapsed.inSeconds >= 5) {
            if (elapsed.inMinutes < 1) {
              return 'Online. Activity seen just now.';
            } else if (elapsed.inHours < 1) {
              return 'Online. Activity seen ${elapsed.inMinutes}m ago.';
            } else {
              return 'Online. Activity seen ${elapsed.inHours}h ago.';
            }
          }
        }
        return 'Online';
      case HostReachability.offline:
        final last = status.lastOnlineAt;
        String suffix;
        if (last != null) {
          final elapsed = DateTime.now().difference(last);
          if (elapsed.inMinutes < 1) {
            suffix = 'last seen just now';
          } else if (elapsed.inHours < 1) {
            suffix = 'last seen ${elapsed.inMinutes}m ago';
          } else {
            suffix = 'last seen ${elapsed.inHours}h ago';
          }
        } else {
          suffix = 'never seen';
        }
        final err = status.lastError;
        if (err != null && err.isNotEmpty) {
          return 'Offline. $err. $suffix.';
        }
        return 'Offline. $suffix.';
      case HostReachability.probing:
        return 'Checking connection...';
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

enum _HostRowAction { toggleEnabled, edit, remove }

class _HostRowActionsMenu extends StatelessWidget {
  const _HostRowActionsMenu({
    required this.hostEnabled,
    required this.onToggleEnabled,
    required this.onEdit,
    required this.onRemove,
    this.compact = false,
  });

  final bool hostEnabled;
  final VoidCallback onToggleEnabled;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return PopupMenuButton<_HostRowAction>(
      tooltip: 'Host actions',
      position: PopupMenuPosition.under,
      color: colors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.control),
        side: BorderSide(color: colors.border),
      ),
      onSelected: (action) {
        switch (action) {
          case _HostRowAction.toggleEnabled:
            onToggleEnabled();
          case _HostRowAction.edit:
            onEdit();
          case _HostRowAction.remove:
            onRemove();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _HostRowAction.toggleEnabled,
          child: _HostActionMenuItem(
            icon: hostEnabled
                ? Icons.pause_circle_outline_rounded
                : Icons.play_circle_outline_rounded,
            label: hostEnabled ? 'Disable host' : 'Enable host',
            color: hostEnabled ? colors.textSecondary : colors.accent,
          ),
        ),
        PopupMenuItem(
          value: _HostRowAction.edit,
          child: _HostActionMenuItem(
            icon: Icons.edit_rounded,
            label: 'Edit host',
            color: colors.textSecondary,
          ),
        ),
        PopupMenuItem(
          value: _HostRowAction.remove,
          child: _HostActionMenuItem(
            icon: Icons.delete_outline,
            label: 'Remove host',
            color: colors.danger,
          ),
        ),
      ],
      child: MeshSurface(
        padding: EdgeInsets.zero,
        radius: AppRadii.control,
        tone: MeshSurfaceTone.muted,
        child: SizedBox(
          width: compact ? 34 : 40,
          height: compact ? 34 : 40,
          child: Icon(
            Icons.more_horiz_rounded,
            size: compact ? 18 : 22,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _HostActionMenuItem extends StatelessWidget {
  const _HostActionMenuItem({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}

MeshStatusBadge _hostStatusBadge(HostStatus status, bool enabled) {
  if (!enabled) {
    return const MeshStatusBadge(
      label: 'disabled',
      tone: MeshStatusTone.offline,
      icon: Icons.pause_circle_outline_rounded,
      compact: true,
    );
  }
  return switch (status.reachability) {
    HostReachability.online => const MeshStatusBadge(
      label: 'online',
      tone: MeshStatusTone.success,
      icon: Icons.check_circle_outline_rounded,
      compact: true,
    ),
    HostReachability.probing => const MeshStatusBadge(
      label: 'checking',
      tone: MeshStatusTone.queued,
      icon: Icons.sync_rounded,
      compact: true,
    ),
    HostReachability.offline => const MeshStatusBadge(
      label: 'offline',
      tone: MeshStatusTone.danger,
      icon: Icons.wifi_off_rounded,
      compact: true,
    ),
    HostReachability.unknown => const MeshStatusBadge(
      label: 'unknown',
      tone: MeshStatusTone.stale,
      icon: Icons.help_outline_rounded,
      compact: true,
    ),
  };
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
  String? _error;
  bool _testing = false;
  String? _testResult;
  bool _testSuccess = false;

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

  Future<void> _scanPairingQr() async {
    final payload = await showPairScannerSheet(context);
    if (!mounted || payload == null) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _labelController.text = payload.label;
      _baseUrlController.text = payload.baseUrl;
      _tokenController.text = payload.token;
      _enabled = true;
      _error = null;
    });
    showAppSnackBar(context, 'QR scanned — ${payload.label}');
  }

  Future<void> _testConnection() async {
    final label = _labelController.text.trim();
    final baseUrl = normalizeBaseUrl(_baseUrlController.text);
    final token = _tokenController.text.trim();
    if (baseUrl.isEmpty || token.isEmpty) {
      setState(() {
        _testResult = 'Enter an address and token first.';
        _testSuccess = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final probe = HostProfile(
        id: 'probe',
        label: label.isEmpty ? 'probe' : label,
        baseUrl: baseUrl,
        token: token,
      );
      final node = await ApiClient().fetchNode(probe);
      if (!mounted) return;
      // Auto-fill label if empty
      if (_labelController.text.trim().isEmpty) {
        _labelController.text = node.hostname;
      }
      setState(() {
        _testing = false;
        _testSuccess = true;
        _testResult = 'Connected to ${node.hostname} \u00b7 ${node.platform}';
      });
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testSuccess = false;
        _testResult = 'Could not reach this machine. ${friendlyError(e)}';
      });
    }
  }

  void _submit() {
    final label = _labelController.text.trim();
    final baseUrl = normalizeBaseUrl(_baseUrlController.text);
    final token = _tokenController.text.trim();
    if (label.isEmpty || baseUrl.isEmpty || token.isEmpty) {
      setState(() {
        _error = 'Name, address, and token are required.';
      });
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
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final isEditing = widget.initialHost != null;
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: EdgeInsets.fromLTRB(10, 8, 10, bottom + 10),
          child: MeshCard(
            tone: MeshCardTone.elevated,
            padding: const EdgeInsets.all(14),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: colors.accentMuted,
                            borderRadius: AppShapes.input,
                            border: Border.all(
                              color: colors.accent.withValues(alpha: 0.24),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            isEditing
                                ? Icons.edit_note_rounded
                                : Icons.add_link_rounded,
                            color: colors.accent,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isEditing ? 'Edit host' : 'Add host',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(
                                      fontWeight: AppWeights.title,
                                      letterSpacing: -0.4,
                                    ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                isEditing
                                    ? 'Update this machine connection.'
                                    : 'Connect a laptop, desktop, or server.',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: colors.textSecondary,
                                      fontWeight: AppWeights.body,
                                    ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        MeshIconButton(
                          icon: Icons.close_rounded,
                          tooltip: 'Close',
                          color: colors.textSecondary,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (canScanPairingQr) ...[
                      const _HostEditorSectionLabel(
                        title: 'Pairing',
                        subtitle: 'Start with a code if the machine is nearby.',
                      ),
                      const SizedBox(height: 8),
                      _HostEditorActionCard(
                        icon: Icons.qr_code_scanner_rounded,
                        title: isEditing
                            ? 'Replace from pairing code'
                            : 'Pair with a code',
                        subtitle:
                            'Run sidemesh pair on the machine, then scan the code here to fill this form.',
                        actionLabel: 'Scan code',
                        onTap: _scanPairingQr,
                      ),
                      const SizedBox(height: 16),
                    ],
                    const _HostEditorSectionLabel(
                      title: 'About this machine',
                      subtitle: 'Choose the name you want to see in Sidemesh.',
                    ),
                    const SizedBox(height: 8),
                    _HostEditorFieldFrame(
                      icon: Icons.label_rounded,
                      label: 'Name',
                      child: TextField(
                        controller: _labelController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          hintText: 'MacBook, office iMac, or VPS-1',
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const _HostEditorSectionLabel(
                      title: 'Connection',
                      subtitle: 'How this app reaches the machine.',
                    ),
                    const SizedBox(height: 8),
                    _HostEditorFieldFrame(
                      icon: Icons.link_rounded,
                      label: 'Address',
                      child: TextField(
                        controller: _baseUrlController,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          hintText: 'http://macbook.tailnet.ts.net:8787',
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _HostEditorFieldFrame(
                      icon: Icons.key_rounded,
                      label: 'Token',
                      child: TextField(
                        controller: _tokenController,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          hintText: 'Paste the pairing token',
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        onPressed: _testing ? null : _testConnection,
                        icon: _testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                ),
                              )
                            : const Icon(
                                Icons.wifi_tethering_rounded,
                                size: 18,
                              ),
                        label: Text(
                          _testing ? 'Checking...' : 'Check connection',
                        ),
                      ),
                    ),
                    if (_testResult != null) ...[
                      const SizedBox(height: 8),
                      _HostEditorStatusCard(
                        success: _testSuccess,
                        message: _testResult!,
                      ),
                    ],
                    const SizedBox(height: 16),
                    const _HostEditorSectionLabel(
                      title: 'Availability',
                      subtitle:
                          'Decide whether this machine is active in the app right now.',
                    ),
                    const SizedBox(height: 8),
                    _HostEnabledCard(
                      enabled: _enabled,
                      onChanged: (value) => setState(() => _enabled = value),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      _HostEditorError(message: _error!),
                    ],
                    const SizedBox(height: 16),
                    _HostEditorFooter(
                      isEditing: isEditing,
                      onCancel: () => Navigator.of(context).pop(),
                      onSubmit: _submit,
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
}

class _HostEditorActionCard extends StatelessWidget {
  const _HostEditorActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshListRow(
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      dense: true,
      onTap: onTap,
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: colors.infoMuted,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: colors.info.withValues(alpha: 0.24)),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: colors.info, size: 17),
      ),
      title: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.textPrimary,
          fontWeight: AppWeights.title,
        ),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
      ),
      trailing: Text(
        actionLabel,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: colors.info,
          fontWeight: AppWeights.title,
        ),
      ),
    );
  }
}

class _HostEditorSectionLabel extends StatelessWidget {
  const _HostEditorSectionLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.textPrimary,
            fontWeight: AppWeights.title,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.textSecondary,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _HostEditorFieldFrame extends StatelessWidget {
  const _HostEditorFieldFrame({
    required this.icon,
    required this.label,
    required this.child,
  });

  final IconData icon;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: colors.border),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: colors.accent, size: 17),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: AppWeights.title,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HostEditorStatusCard extends StatelessWidget {
  const _HostEditorStatusCard({required this.success, required this.message});

  final bool success;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = success ? colors.success : colors.warning;
    final muted = success ? colors.successMuted : colors.warningMuted;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: muted,
        borderRadius: AppShapes.input,
        border: Border.all(color: tone.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            success ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            color: tone,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textPrimary,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostEnabledCard extends StatelessWidget {
  const _HostEnabledCard({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshListRow(
      tone: MeshSurfaceTone.muted,
      selected: enabled,
      radius: AppRadii.control,
      dense: true,
      onTap: () => onChanged(!enabled),
      leading: Icon(
        enabled ? Icons.sensors_rounded : Icons.pause_rounded,
        color: enabled ? colors.accent : colors.textSecondary,
        size: 18,
      ),
      title: Text(
        enabled ? 'Use this machine in Sidemesh' : 'Machine is paused',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.textPrimary,
          fontWeight: AppWeights.title,
        ),
      ),
      subtitle: Text(
        enabled
            ? 'Show it in sessions, inbox, and syncing.'
            : 'Keep it saved, but leave it out of active work.',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
      ),
      trailing: _HostEditorToggle(value: enabled),
    );
  }
}

class _HostEditorToggle extends StatelessWidget {
  const _HostEditorToggle({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 52,
      height: 30,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? colors.accent : colors.surfaceMuted,
        borderRadius: AppShapes.pill,
        border: Border.all(color: value ? colors.accent : colors.borderStrong),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: value ? colors.accentOn : colors.surface,
            shape: BoxShape.circle,
            border: Border.all(
              color: value
                  ? colors.accentOn.withValues(alpha: 0.7)
                  : colors.border,
            ),
          ),
        ),
      ),
    );
  }
}

class _HostEditorError extends StatelessWidget {
  const _HostEditorError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.dangerMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: colors.danger, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.danger,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostEditorFooter extends StatelessWidget {
  const _HostEditorFooter({
    required this.isEditing,
    required this.onCancel,
    required this.onSubmit,
  });

  final bool isEditing;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;
        final saveButton = FilledButton.icon(
          onPressed: onSubmit,
          icon: const Icon(Icons.check_rounded),
          label: Text(isEditing ? 'Save changes' : 'Save host'),
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              saveButton,
              const SizedBox(height: 6),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
            ],
          );
        }
        return Row(
          children: [
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
            const Spacer(),
            saveButton,
          ],
        );
      },
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
    final theme = Theme.of(context);
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
              showingCached
                  ? 'Refreshing sessions, $loaded of $total hosts ready'
                  : 'Loading sessions, $loaded of $total hosts ready',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
              ),
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
    final theme = Theme.of(context);
    final summary = hostLabels.length == 1
        ? 'Cannot reach ${hostLabels.first}.'
        : 'Cannot reach ${hostLabels.length} hosts: ${hostLabels.join(', ')}.';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: colors.warningMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: colors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              summary,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.warning,
                fontWeight: AppWeights.body,
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
              textStyle: const TextStyle(fontWeight: AppWeights.emphasis),
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _MobileClientUpdateBanner extends StatelessWidget {
  const _MobileClientUpdateBanner({
    required this.notice,
    required this.onReview,
    this.onDismiss,
  });

  final MobileClientCompatibilityNotice notice;
  final VoidCallback onReview;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final requiresUpdate =
        notice.level == MobileClientCompatibilityLevel.required;
    final accent = requiresUpdate ? colors.danger : colors.info;
    final muted = requiresUpdate ? colors.dangerMuted : colors.infoMuted;
    final title = requiresUpdate
        ? 'Update this app to keep using some hosts'
        : 'A newer Sidemesh mobile build is recommended';
    final count = notice.affectedHostCount;
    final hostSummary = count == 1 ? notice.primaryHost.label : '$count hosts';
    final verb = count == 1
        ? (requiresUpdate ? 'requires' : 'recommends')
        : (requiresUpdate ? 'require' : 'recommend');
    final targetVersion = mobileClientVersionLabel(notice.targetVersion);
    final installedVersion = mobileClientVersionLabel(notice.installedVersion);
    late final String body;
    if (count == 1) {
      body =
          '$hostSummary $verb Sidemesh mobile $targetVersion or newer. '
          'You are on $installedVersion.';
    } else if (requiresUpdate) {
      body =
          'Update to Sidemesh mobile $targetVersion or newer to keep using '
          '$count hosts. You are on $installedVersion.';
    } else {
      body =
          'Update to Sidemesh mobile $targetVersion or newer to satisfy '
          'recommendations from $count hosts. You are on $installedVersion.';
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: muted,
        borderRadius: AppShapes.input,
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withValues(alpha: 0.28)),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.phone_android_rounded, size: 18, color: accent),
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
                    fontWeight: AppWeights.title,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      FilledButton.icon(
                        onPressed: onReview,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.visibility_rounded, size: 16),
                        label: Text(
                          count == 1 ? 'Review host' : 'Review hosts',
                        ),
                      ),
                      if (onDismiss != null)
                        OutlinedButton(
                          onPressed: onDismiss,
                          child: const Text('Later'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              onPressed: onDismiss,
              icon: Icon(Icons.close_rounded, color: colors.textSecondary),
            ),
        ],
      ),
    );
  }
}
