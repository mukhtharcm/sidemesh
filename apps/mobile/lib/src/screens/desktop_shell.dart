import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_window_utils/macos_window_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../approval_inbox_store.dart';
import '../host_status_store.dart';
import '../host_store.dart';
import '../live_activity_service.dart';
import '../local_notification_service.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/desktop_sidebar_search_field.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/notification_permission_banner.dart';
import '../widgets/recent_session_controls_menu.dart';
import '../onboarding_store.dart';
import '../theme/theme_controller.dart';
import 'desktop_welcome_overlay.dart';
import 'create_session_sheet.dart';
import 'home_screen.dart';
import 'host_detail_screen.dart';
import 'inspector/inspector_controller.dart';
import 'settings_screen.dart';
import 'session_screen.dart';
import 'usage_pane.dart';

/// macOS shell with rail, list pane, active detail, and optional tools pane.
/// Reuses the same panes as the mobile home
/// screen, so we keep a single source of truth for session data.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

enum _SidebarSection { recent, inbox, hosts }

class _OnboardingEmptyState extends StatelessWidget {
  const _OnboardingEmptyState({required this.colors, required this.onAddHost});

  final AppColors colors;
  final VoidCallback onAddHost;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: AppShapes.sheet,
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.4),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.hub_rounded, size: 32, color: colors.accent),
              ),
              const SizedBox(height: 24),
              Text(
                'Connect a machine',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Install Sidemesh on the machine you want to control, then add that host here.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onAddHost,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add your first host'),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: onAddHost,
                child: const Text('Enter host details manually'),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: AppShapes.dialog,
                  border: Border.all(color: colors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Quick setup',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Run these once on the machine you want to control.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _CommandBlock(
                      text:
                          'npm install -g sidemesh\nsidemesh setup\nsidemesh pair',
                      colors: colors,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommandBlock extends StatelessWidget {
  const _CommandBlock({required this.text, required this.colors});

  final String text;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final lines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.codeBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '\$',
                        style: monoStyle(color: colors.accent, fontSize: 12),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          lines[i],
                          style: monoStyle(
                            color: colors.codeForeground,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveSession {
  const _ActiveSession({
    required this.host,
    required this.session,
    required this.serial,
    this.composerSeed,
  });
  final HostProfile host;
  final SessionSummary session;
  final int serial;
  final SessionComposerSeed? composerSeed;
}

class _DesktopShellState extends State<DesktopShell> {
  final HostStore _store = HostStore();
  final ApiClient _api = ApiClient();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'sidebar-search');
  final InspectorController _inspector = InspectorController();

  List<HostProfile> _hosts = const [];
  bool _loading = true;
  _SidebarSection _section = _SidebarSection.recent;
  _ActiveSession? _active;
  HostProfile? _activeHost;
  bool _showUsage = false;
  int _activeCount = 0;
  int _inboxCount = 0;
  int _sessionOpenSerial = 0;
  String _query = '';
  RecentSessionFilters _recentFilters = const RecentSessionFilters();
  double _sidebarWidth = _defaultSidebarWidth;
  Timer? _searchDebounce;
  // Used to trigger refresh of sidebar panes after a host/session mutation.
  int _refreshTick = 0;
  bool _handlingNotificationIntent = false;
  bool _showWelcome = false;

  List<HostProfile> get _enabledHosts =>
      _hosts.where((host) => host.enabled).toList(growable: false);

  // Reserve space under the macOS titlebar so traffic lights & drag area
  // stay clean. 28pt matches the standard NSWindow titlebar height.
  static const double _titlebarInset = 28;
  static const double _railWidth = 76;
  static const double _defaultSidebarWidth = 352;
  static const double _minSidebarWidth = 300;
  static const double _maxSidebarWidth = 440;
  static const String _sidebarWidthPref = 'sidemesh.desktop.sidebarWidth';
  static const double _defaultInspectorWidth = 380;
  static const double _minInspectorWidth = 320;
  static const double _maxInspectorWidth = 640;
  static const String _inspectorWidthPref = 'sidemesh.desktop.inspectorWidth';

  double _inspectorWidth = _defaultInspectorWidth;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    LocalNotificationService.instance.routeIntent.addListener(
      _onNotificationRouteIntent,
    );
    _loadHosts();
    _loadSidebarWidth();
    _loadInspectorWidth();
    _searchController.addListener(() {
      final next = _searchController.text;
      if (next == _query) return;
      _searchDebounce?.cancel();
      // Apply instantly when clearing so the UI feels responsive; otherwise
      // coalesce typing bursts.
      if (next.isEmpty) {
        setState(() => _query = '');
        return;
      }
      _searchDebounce = Timer(const Duration(milliseconds: 140), () {
        if (!mounted) return;
        setState(() => _query = _searchController.text);
      });
    });
  }

  @override
  void dispose() {
    LocalNotificationService.instance.routeIntent.removeListener(
      _onNotificationRouteIntent,
    );
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _inspector.dispose();
    super.dispose();
  }

  void _setRecentRunningOnly(bool enabled) {
    if (_recentFilters.runningOnly == enabled) return;
    setState(() {
      _recentFilters = _recentFilters.copyWith(runningOnly: enabled);
    });
  }

  void _setRecentUnreadOnly(bool enabled) {
    if (_recentFilters.unreadOnly == enabled) return;
    setState(() {
      _recentFilters = _recentFilters.copyWith(unreadOnly: enabled);
    });
  }

  void _setRecentFavoritesOnly(bool enabled) {
    if (_recentFilters.favoritesOnly == enabled) return;
    setState(() {
      _recentFilters = _recentFilters.copyWith(favoritesOnly: enabled);
    });
  }

  Future<void> _checkOnboarding() async {
    final completed = await OnboardingStore.instance.isCompleted;
    if (!mounted) return;
    setState(() => _showWelcome = !completed);
  }

  Future<void> _loadHosts() async {
    final hosts = await _store.loadHosts();
    if (!mounted) return;
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
    unawaited(_handleNotificationRouteIntent());
  }

  Future<void> _loadSidebarWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_sidebarWidthPref);
      if (stored != null && mounted) {
        setState(() {
          _sidebarWidth = stored.clamp(_minSidebarWidth, _maxSidebarWidth);
        });
      }
    } catch (_) {
      // Preferences unavailable — stick with the default.
    }
  }

  void _resizeSidebar(double delta) {
    final next = (_sidebarWidth + delta).clamp(
      _minSidebarWidth,
      _maxSidebarWidth,
    );
    if (next == _sidebarWidth) return;
    setState(() => _sidebarWidth = next);
  }

  void _resetSidebarWidth() {
    if (_sidebarWidth == _defaultSidebarWidth) return;
    setState(() => _sidebarWidth = _defaultSidebarWidth);
    _persistSidebarWidth();
  }

  Future<void> _persistSidebarWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_sidebarWidthPref, _sidebarWidth);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  Future<void> _loadInspectorWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_inspectorWidthPref);
      if (stored != null && mounted) {
        setState(() {
          _inspectorWidth = stored.clamp(
            _minInspectorWidth,
            _maxInspectorWidth,
          );
        });
      }
    } catch (_) {
      // Preferences unavailable — stick with the default.
    }
  }

  void _resizeInspector(double delta) {
    // Dragging the handle right should shrink the inspector (detail grows).
    final next = (_inspectorWidth - delta).clamp(
      _minInspectorWidth,
      _maxInspectorWidth,
    );
    if (next == _inspectorWidth) return;
    setState(() => _inspectorWidth = next);
  }

  void _resetInspectorWidth() {
    if (_inspectorWidth == _defaultInspectorWidth) return;
    setState(() => _inspectorWidth = _defaultInspectorWidth);
    _persistInspectorWidth();
  }

  Future<void> _persistInspectorWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_inspectorWidthPref, _inspectorWidth);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  void _showShortcutsSheet() {
    final colors = context.colors;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final sections =
            <({String title, List<({String keys, String label})> items})>[
              (
                title: 'Move around',
                items: [
                  (
                    keys: '⌘1 / ⌘2 / ⌘3',
                    label: 'Switch between Sessions, Inbox, and Machines',
                  ),
                  (keys: '⌘F', label: 'Focus search'),
                  (keys: '⌘J', label: 'Focus the composer'),
                  (keys: '⌘R', label: 'Refresh the current list'),
                  (keys: '⌘W', label: 'Close the current session'),
                ],
              ),
              (
                title: 'Write messages',
                items: [
                  (keys: 'Enter', label: 'Send the current message'),
                  (keys: 'Shift+Enter', label: 'Start a new line'),
                  (keys: 'Long-press', label: 'Copy a message'),
                ],
              ),
              (
                title: 'Help',
                items: [(keys: '⌘/', label: 'Open this shortcut list')],
              ),
            ];
        return Dialog(
          backgroundColor: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colors.border),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.keyboard_rounded,
                        size: 18,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Keyboard shortcuts',
                        style: Theme.of(dialogContext).textTheme.titleMedium
                            ?.copyWith(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Close',
                        iconSize: 18,
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: Icon(
                          Icons.close_rounded,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use these desktop shortcuts to move faster through the home surfaces.',
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(color: colors.textSecondary, height: 1.35),
                  ),
                  const SizedBox(height: 14),
                  for (final section in sections) ...[
                    Text(
                      section.title,
                      style: Theme.of(dialogContext).textTheme.labelLarge
                          ?.copyWith(
                            color: colors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    for (final e in section.items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.label,
                                style: TextStyle(
                                  color: colors.textPrimary,
                                  fontSize: 13,
                                  height: 1.3,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: colors.surfaceMuted,
                                borderRadius: AppShapes.badge,
                                border: Border.all(color: colors.border),
                              ),
                              child: Text(
                                e.keys,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (section != sections.last) const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _openSettings() {
    unawaited(
      openSettingsScreen(
        context,
        onResetSidebarWidth: _resetSidebarWidth,
        onResetInspectorWidth: _resetInspectorWidth,
      ),
    );
  }

  Future<void> _startSessionFromSidebar() async {
    if (_hosts.isEmpty) {
      await _showHostEditor();
      return;
    }
    if (_enabledHosts.isEmpty) {
      showAppSnackBar(context, 'Enable a host before starting a session.');
      return;
    }
    final result = await showCreateSessionHostLauncher(
      context,
      hosts: _enabledHosts,
      api: _api,
    );
    if (!mounted || result == null) {
      return;
    }
    _openSession(result.host, result.session);
  }

  Future<void> _showHostEditor({HostProfile? initial}) async {
    final result = await showModalBottomSheet<HostProfile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => HostEditorSheet(initialHost: initial),
    );
    if (result == null) return;
    final exists = _hosts.any((h) => h.id == result.id);
    final updated = exists
        ? _hosts.map((h) => h.id == result.id ? result : h).toList()
        : [..._hosts, result];
    await _store.saveHosts(updated);
    await _loadHosts();
    _bumpRefresh();
  }

  Future<void> _removeHost(HostProfile host) async {
    final active = _active;
    final updated = _hosts.where((h) => h.id != host.id).toList();
    await _store.saveHosts(updated);
    if (active?.host.id == host.id) {
      _inspector.closeForOwner('${active!.host.id}|${active.session.id}');
      setState(() => _active = null);
    }
    if (_activeHost?.id == host.id) {
      setState(() => _activeHost = null);
    }
    await _loadHosts();
    _bumpRefresh();
  }

  Future<void> _toggleHostEnabled(HostProfile host) async {
    final disabling = host.enabled;
    final active = _active;
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
    if (active?.host.id == host.id && disabling) {
      _inspector.closeForOwner('${active!.host.id}|${active.session.id}');
      setState(() => _active = null);
    }
    if (_activeHost?.id == host.id && disabling) {
      setState(() => _activeHost = null);
    }
    await _loadHosts();
    _bumpRefresh();
  }

  void _openUsage() {
    final current = _active;
    if (current != null) {
      _inspector.closeForOwner('${current.host.id}|${current.session.id}');
    }
    setState(() {
      _showUsage = true;
      _active = null;
      _activeHost = null;
    });
  }

  void _openSession(
    HostProfile host,
    SessionSummary session, {
    SessionComposerSeed? composerSeed,
  }) {
    if (!host.enabled) {
      showAppSnackBar(context, 'Enable ${host.label} before opening sessions.');
      return;
    }
    // We don't close the old session's inspector here — the newly mounted
    // SessionScreen decides: it will either replace the surface with its
    // own restored one (smooth swap) or close the orphan if it has no
    // saved state. That avoids a close/open flash when crossing sessions
    // that both want the inspector open.
    setState(() {
      _active = _ActiveSession(
        host: host,
        session: session,
        serial: ++_sessionOpenSerial,
        composerSeed: composerSeed,
      );
      _activeHost = null;
      _showUsage = false;
    });
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
      if (Platform.isMacOS) unawaited(WindowManipulator.orderFrontRegardless());
      if (_section != _SidebarSection.inbox) {
        setState(() => _section = _SidebarSection.inbox);
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
      _openSession(
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

  void _openHostDetail(HostProfile host) {
    if (!host.enabled) {
      showAppSnackBar(context, 'Enable ${host.label} before opening details.');
      return;
    }
    final current = _active;
    if (current != null) {
      _inspector.closeForOwner('${current.host.id}|${current.session.id}');
    }
    setState(() {
      _activeHost = host;
      _active = null;
      _showUsage = false;
    });
  }

  void _handleActiveSessionArchived(HostProfile host, SessionSummary session) {
    _inspector.closeForOwner('${host.id}|${session.id}');
    setState(() {
      _active = null;
      _activeHost = host;
      _showUsage = false;
    });
    _bumpRefresh();
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

  void _bumpRefresh() {
    setState(() => _refreshTick++);
  }

  /// Figures out how wide each column should be given the available [total]
  /// width. The rail stays fixed; the list pane and inspector give up space
  /// before the detail pane does.
  ({double rail, double sidebar, double detail, double inspector})
  _computePaneWidths(double total) {
    // Resizer is 6pt (see _SidebarResizer). When inspector is open,
    // the inspector pane gets its own resize handle on its left edge.
    const double resizer = 6;
    const double inspectorMin = _minInspectorWidth;
    const double detailMin = 560;
    final inspectorOpen = _inspector.current != null;

    double sidebar = _sidebarWidth.clamp(_minSidebarWidth, _maxSidebarWidth);
    double inspector = inspectorOpen
        ? _inspectorWidth.clamp(_minInspectorWidth, _maxInspectorWidth)
        : 0;
    double inspectorResizer = inspectorOpen ? resizer : 0;

    double detail =
        total - _railWidth - sidebar - resizer - inspectorResizer - inspector;

    if (inspectorOpen && detail < detailMin) {
      // Shrink the sidebar toward its min first; session titles stay
      // readable as long as we don't go below that.
      final sidebarSlack = sidebar - _minSidebarWidth;
      if (sidebarSlack > 0) {
        final needed = detailMin - detail;
        final take = needed < sidebarSlack ? needed : sidebarSlack;
        sidebar -= take;
        detail += take;
      }
    }

    if (inspectorOpen && detail < detailMin) {
      // Then shrink the inspector toward its own min.
      final inspectorSlack = inspector - inspectorMin;
      if (inspectorSlack > 0) {
        final needed = detailMin - detail;
        final take = needed < inspectorSlack ? needed : inspectorSlack;
        inspector -= take;
        detail += take;
      }
    }

    // If detail is still under min we let it float; the overlay
    // fallback is a later-phase task.
    return (
      rail: _railWidth,
      sidebar: sidebar,
      detail: detail,
      inspector: inspector,
    );
  }

  void _toggleInspectorDebug() {
    final ownerKey = _active != null
        ? '${_active!.host.id}|${_active!.session.id}'
        : 'shell';
    final hasActiveSession = _active != null;
    _inspector.toggle(
      InspectorSurface(
        kind: InspectorSurfaceKind.debug,
        ownerKey: ownerKey,
        title: 'Side panel',
        icon: Icons.tune_rounded,
        bodyBuilder: (context) {
          final colors = context.colors;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasActiveSession
                      ? 'No extra details yet'
                      : 'Open a session to use this panel',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.title,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  hasActiveSession
                      ? 'This side panel is reserved for extra details and '
                            'tools for the current session.'
                      : 'This side panel is reserved for extra details and '
                            'tools. Open a machine or session to show them '
                            'here.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: Stack(
        children: [
          Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.keyR, meta: true):
                  _RefreshIntent(),
              SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                  _FocusSearchIntent(),
              SingleActivator(LogicalKeyboardKey.keyW, meta: true):
                  _CloseActiveSessionIntent(),
              SingleActivator(LogicalKeyboardKey.keyI, meta: true, shift: true):
                  _ToggleInspectorDebugIntent(),
              SingleActivator(LogicalKeyboardKey.slash, meta: true):
                  _ShowShortcutsIntent(),
              SingleActivator(
                LogicalKeyboardKey.slash,
                meta: true,
                shift: true,
              ): _ShowShortcutsIntent(),
              SingleActivator(LogicalKeyboardKey.digit1, meta: true):
                  _SwitchSectionIntent(_SidebarSection.recent),
              SingleActivator(LogicalKeyboardKey.digit2, meta: true):
                  _SwitchSectionIntent(_SidebarSection.inbox),
              SingleActivator(LogicalKeyboardKey.digit3, meta: true):
                  _SwitchSectionIntent(_SidebarSection.hosts),
            },
            child: Actions(
              actions: <Type, Action<Intent>>{
                _RefreshIntent: CallbackAction<_RefreshIntent>(
                  onInvoke: (_) {
                    _loadHosts();
                    _bumpRefresh();
                    return null;
                  },
                ),
                _FocusSearchIntent: CallbackAction<_FocusSearchIntent>(
                  onInvoke: (_) {
                    _searchFocus.requestFocus();
                    _searchController.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: _searchController.text.length,
                    );
                    return null;
                  },
                ),
                _CloseActiveSessionIntent:
                    CallbackAction<_CloseActiveSessionIntent>(
                      onInvoke: (_) {
                        if (_active != null) {
                          setState(() => _active = null);
                        }
                        return null;
                      },
                    ),
                _ShowShortcutsIntent: CallbackAction<_ShowShortcutsIntent>(
                  onInvoke: (_) {
                    _showShortcutsSheet();
                    return null;
                  },
                ),
                _SwitchSectionIntent: CallbackAction<_SwitchSectionIntent>(
                  onInvoke: (intent) {
                    setState(() => _section = intent.section);
                    return null;
                  },
                ),
                _ToggleInspectorDebugIntent:
                    CallbackAction<_ToggleInspectorDebugIntent>(
                      onInvoke: (_) {
                        _toggleInspectorDebug();
                        return null;
                      },
                    ),
              },
              child: Focus(
                autofocus: true,
                child: InspectorScope(
                  controller: _inspector,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return AnimatedBuilder(
                        animation: _inspector,
                        builder: (context, _) {
                          final widths = _computePaneWidths(
                            constraints.maxWidth,
                          );
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: widths.rail,
                                child: _DesktopRail(
                                  titlebarInset: _titlebarInset,
                                  section: _section,
                                  inboxCount: _inboxCount,
                                  activeCount: _activeCount,
                                  hostCount: _hosts.length,
                                  onSelectSection: (s) =>
                                      setState(() => _section = s),
                                  onShowShortcuts: _showShortcutsSheet,
                                  onOpenSettings: _openSettings,
                                  onOpenUsage: _openUsage,
                                ),
                              ),
                              SizedBox(
                                width: widths.sidebar,
                                child: ListenableBuilder(
                                  listenable: ApprovalInboxStore.instance,
                                  builder: (context, _) => _Sidebar(
                                    titlebarInset: _titlebarInset,
                                    width: widths.sidebar,
                                    hosts: _hosts,
                                    loading: _loading,
                                    api: _api,
                                    section: _section,
                                    refreshTick: _refreshTick,
                                    inboxCount: _inboxCount,
                                    selectedSessionId: _active?.session.id,
                                    selectedHostId: _activeHost?.id,
                                    searchController: _searchController,
                                    searchFocus: _searchFocus,
                                    query: _query,
                                    onClearSearch: () {
                                      _searchController.clear();
                                    },
                                    onOpenSession: _openSession,
                                    onOpenSessionFromAction: (host, action) =>
                                        _openSession(
                                          host,
                                          _sessionFromAction(action),
                                        ),
                                    onOpenPendingSession:
                                        (host, session, seed) async {
                                          _openSession(
                                            host,
                                            session,
                                            composerSeed: seed,
                                          );
                                        },
                                    onOpenHostDetail: _openHostDetail,
                                    onAddHost: () => _showHostEditor(),
                                    onStartSession: _startSessionFromSidebar,
                                    onEditHost: (h) =>
                                        _showHostEditor(initial: h),
                                    onRemoveHost: _removeHost,
                                    onToggleHostEnabled: _toggleHostEnabled,
                                    onActiveCountChanged: (n) {
                                      if (!mounted) return;
                                      setState(() => _activeCount = n);
                                    },
                                    onInboxCountChanged: (n) {
                                      if (!mounted || n == _inboxCount) return;
                                      setState(() => _inboxCount = n);
                                    },
                                    recentFilters: _recentFilters,
                                    onRecentRunningOnlyChanged:
                                        _setRecentRunningOnly,
                                    onRecentUnreadOnlyChanged:
                                        _setRecentUnreadOnly,
                                    onRecentFavoritesOnlyChanged:
                                        _setRecentFavoritesOnly,
                                  ),
                                ),
                              ),
                              _SidebarResizer(
                                color: colors.border,
                                onDrag: _resizeSidebar,
                                onDragEnd: _persistSidebarWidth,
                              ),
                              SizedBox(
                                width: widths.detail,
                                child: _DetailPane(
                                  titlebarInset: _titlebarInset,
                                  active: _active,
                                  activeHost: _activeHost,
                                  showUsage: _showUsage,
                                  hosts: _hosts,
                                  enabledHosts: _enabledHosts,
                                  api: _api,
                                  onClose: () {
                                    final current = _active;
                                    if (current != null) {
                                      _inspector.closeForOwner(
                                        '${current.host.id}|${current.session.id}',
                                      );
                                    }
                                    setState(() {
                                      _active = null;
                                      _activeHost = null;
                                      _showUsage = false;
                                    });
                                  },
                                  onOpenSession: _openSession,
                                  onArchived: _handleActiveSessionArchived,
                                  onAddHost: () => _showHostEditor(),
                                  onShowHosts: () => setState(
                                    () => _section = _SidebarSection.hosts,
                                  ),
                                ),
                              ),
                              if (_inspector.current != null) ...[
                                _SidebarResizer(
                                  color: colors.border,
                                  onDrag: _resizeInspector,
                                  onDragEnd: _persistInspectorWidth,
                                  onDoubleTap: _resetInspectorWidth,
                                ),
                                SizedBox(
                                  width: widths.inspector,
                                  child: _InspectorPane(
                                    surface: _inspector.current!,
                                    onClose: _inspector.close,
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          if (_showWelcome)
            DesktopWelcomeOverlay(
              themeController: ThemeScope.of(context),
              onDismissed: () {
                setState(() => _showWelcome = false);
              },
              onAddHost: () => _showHostEditor(),
            ),
        ],
      ),
    );
  }
}

class _RefreshIntent extends Intent {
  const _RefreshIntent();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

class _CloseActiveSessionIntent extends Intent {
  const _CloseActiveSessionIntent();
}

class _ShowShortcutsIntent extends Intent {
  const _ShowShortcutsIntent();
}

class _SwitchSectionIntent extends Intent {
  const _SwitchSectionIntent(this.section);
  final _SidebarSection section;
}

class _ToggleInspectorDebugIntent extends Intent {
  const _ToggleInspectorDebugIntent();
}

String _sidebarSectionTitle(_SidebarSection section) {
  return switch (section) {
    _SidebarSection.recent => 'Sessions',
    _SidebarSection.inbox => 'Inbox',
    _SidebarSection.hosts => 'Machines',
  };
}

IconData _sidebarSectionIcon(_SidebarSection section) {
  return switch (section) {
    _SidebarSection.recent => Icons.chat_bubble_outline_rounded,
    _SidebarSection.inbox => Icons.all_inbox_rounded,
    _SidebarSection.hosts => Icons.devices_rounded,
  };
}

class _DesktopRail extends StatelessWidget {
  const _DesktopRail({
    required this.titlebarInset,
    required this.section,
    required this.inboxCount,
    required this.activeCount,
    required this.hostCount,
    required this.onSelectSection,
    required this.onShowShortcuts,
    required this.onOpenSettings,
    required this.onOpenUsage,
  });

  final double titlebarInset;
  final _SidebarSection section;
  final int inboxCount;
  final int activeCount;
  final int hostCount;
  final ValueChanged<_SidebarSection> onSelectSection;
  final VoidCallback onShowShortcuts;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenUsage;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.canvas,
        border: Border(right: BorderSide(color: colors.borderStrong)),
      ),
      child: Column(
        children: [
          SizedBox(height: titlebarInset + 12),
          Tooltip(
            message: 'Sidemesh',
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.hub_rounded,
                size: 18,
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _RailItem(
            selected: section == _SidebarSection.recent,
            icon: _sidebarSectionIcon(_SidebarSection.recent),
            label: 'Sessions',
            badge: activeCount > 0 ? activeCount.toString() : null,
            onTap: () => onSelectSection(_SidebarSection.recent),
          ),
          const SizedBox(height: 6),
          _RailItem(
            selected: section == _SidebarSection.inbox,
            icon: _sidebarSectionIcon(_SidebarSection.inbox),
            label: 'Inbox',
            badge: inboxCount > 0 ? inboxCount.toString() : null,
            onTap: () => onSelectSection(_SidebarSection.inbox),
          ),
          const SizedBox(height: 6),
          _RailItem(
            selected: section == _SidebarSection.hosts,
            icon: _sidebarSectionIcon(_SidebarSection.hosts),
            label: 'Machines',
            badge: hostCount > 0 ? hostCount.toString() : null,
            onTap: () => onSelectSection(_SidebarSection.hosts),
          ),
          const Spacer(),
          _RailUtilityButton(
            icon: Icons.keyboard_rounded,
            label: 'Shortcuts',
            onTap: onShowShortcuts,
          ),
          const SizedBox(height: 8),
          _RailUtilityButton(
            icon: Icons.speed_rounded,
            label: 'Usage',
            onTap: onOpenUsage,
          ),
          const SizedBox(height: 8),
          _RailUtilityButton(
            icon: Icons.tune_rounded,
            label: 'Settings',
            onTap: onOpenSettings,
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = selected
        ? visibleUiColorOn(
            colors,
            background: colors.canvas,
            preferred: colors.accent,
          )
        : colors.textSecondary;
    final badgeForeground = readableActionForeground(colors, colors.accent);
    return Tooltip(
      message: label,
      child: Semantics(
        selected: selected,
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: SizedBox(
              width: 54,
              height: 48,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.accentMuted.withValues(alpha: 0.72)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 18, color: foreground),
                  ),
                  if (badge != null)
                    Positioned(
                      top: 3,
                      right: 3,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 17),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: selected ? colors.accent : colors.canvas,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: colors.border),
                        ),
                        child: Text(
                          badge!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: selected
                                    ? badgeForeground
                                    : colors.textSecondary,
                                fontWeight: AppWeights.emphasis,
                                height: 1,
                              ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailUtilityButton extends StatelessWidget {
  const _RailUtilityButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(
              width: 48,
              height: 38,
              child: Icon(icon, size: 18, color: colors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.titlebarInset,
    required this.width,
    required this.hosts,
    required this.loading,
    required this.api,
    required this.section,
    required this.refreshTick,
    required this.inboxCount,
    required this.selectedSessionId,
    required this.selectedHostId,
    required this.searchController,
    required this.searchFocus,
    required this.query,
    required this.onClearSearch,
    required this.onOpenSession,
    required this.onOpenSessionFromAction,
    required this.onOpenPendingSession,
    required this.onOpenHostDetail,
    required this.onAddHost,
    required this.onStartSession,
    required this.onEditHost,
    required this.onRemoveHost,
    required this.onToggleHostEnabled,
    required this.onActiveCountChanged,
    required this.onInboxCountChanged,
    this.recentFilters = const RecentSessionFilters(),
    this.onRecentRunningOnlyChanged,
    this.onRecentUnreadOnlyChanged,
    this.onRecentFavoritesOnlyChanged,
  });

  final double titlebarInset;
  final double width;
  final List<HostProfile> hosts;
  final bool loading;
  final ApiClient api;
  final _SidebarSection section;
  final int refreshTick;
  final int inboxCount;
  final String? selectedSessionId;
  final String? selectedHostId;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final String query;
  final VoidCallback onClearSearch;
  final void Function(HostProfile, SessionSummary) onOpenSession;
  final void Function(HostProfile, PendingAction) onOpenSessionFromAction;
  final OpenPendingSessionCallback onOpenPendingSession;
  final ValueChanged<HostProfile> onOpenHostDetail;
  final VoidCallback onAddHost;
  final VoidCallback onStartSession;
  final HostProfileActionCallback onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;
  final HostProfileActionCallback onToggleHostEnabled;
  final ValueChanged<int> onActiveCountChanged;
  final ValueChanged<int> onInboxCountChanged;
  final RecentSessionFilters recentFilters;
  final ValueChanged<bool>? onRecentRunningOnlyChanged;
  final ValueChanged<bool>? onRecentUnreadOnlyChanged;
  final ValueChanged<bool>? onRecentFavoritesOnlyChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabledHosts = hosts
        .where((host) => host.enabled)
        .toList(growable: false);
    final canStartSession = enabledHosts.isNotEmpty;
    final Widget headerAction = switch (section) {
      _SidebarSection.recent => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RecentSessionControlsMenu(
            showGrouping: query.trim().isEmpty,
            filters: recentFilters,
            onRunningOnlyChanged: onRecentRunningOnlyChanged,
            onUnreadOnlyChanged: onRecentUnreadOnlyChanged,
            onFavoritesOnlyChanged: onRecentFavoritesOnlyChanged,
          ),
          const SizedBox(width: AppSpacing.xs),
          _ListPaneActionButton(
            icon: Icons.add_rounded,
            label: 'New',
            onTap: hosts.isEmpty || canStartSession ? onStartSession : null,
          ),
        ],
      ),
      _SidebarSection.hosts => _ListPaneActionButton(
        icon: Icons.add_link_rounded,
        label: 'Add',
        onTap: onAddHost,
      ),
      _SidebarSection.inbox => _SidebarCountPill(label: '$inboxCount'),
    };
    return SizedBox(
      width: width,
      child: Container(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: titlebarInset + 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _ListPaneHeader(
                title: _sidebarSectionTitle(section),
                trailing: headerAction,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: DesktopSidebarSearchField(
                controller: searchController,
                focusNode: searchFocus,
                onClear: onClearSearch,
              ),
            ),
            if (!canStartSession && section == _SidebarSection.recent)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  hosts.isEmpty
                      ? 'Add a machine to start your first session.'
                      : 'Enable a machine before starting a new session.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.35,
                  ),
                ),
              ),
            const NotificationPermissionBanner(
              margin: EdgeInsets.fromLTRB(16, 0, 16, 10),
              compact: true,
            ),
            Expanded(
              child: loading
                  ? _DesktopSidebarLoadingState(section: section)
                  : _SidebarPane(
                      key: ValueKey('pane-${section.name}-$refreshTick'),
                      section: section,
                      hosts: hosts,
                      api: api,
                      selectedSessionId: selectedSessionId,
                      selectedHostId: selectedHostId,
                      query: query,
                      onOpenSession: onOpenSession,
                      onOpenSessionFromAction: onOpenSessionFromAction,
                      onOpenPendingSession: onOpenPendingSession,
                      onOpenHostDetail: onOpenHostDetail,
                      onEditHost: onEditHost,
                      onRemoveHost: onRemoveHost,
                      onAddHost: onAddHost,
                      onActiveCountChanged: onActiveCountChanged,
                      onInboxCountChanged: onInboxCountChanged,
                      onToggleHostEnabled: onToggleHostEnabled,
                      recentFilters: recentFilters,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopSidebarLoadingState extends StatelessWidget {
  const _DesktopSidebarLoadingState({required this.section});

  final _SidebarSection section;

  @override
  Widget build(BuildContext context) {
    final spacing = section == _SidebarSection.hosts ? 8.0 : 10.0;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (section != _SidebarSection.hosts) ...[
          MeshListRowSkeleton(
            dense: true,
            titleWidthFactor: 0.56,
            subtitleWidthFactor: 0.76,
            showMeta: true,
            badgeCount: section == _SidebarSection.inbox ? 1 : 2,
          ),
          SizedBox(height: spacing),
        ],
        MeshListRowSkeleton(
          dense: true,
          titleWidthFactor: section == _SidebarSection.hosts ? 0.42 : 0.48,
          subtitleWidthFactor: section == _SidebarSection.hosts ? 0.68 : 0.7,
          showMeta: section != _SidebarSection.inbox,
          badgeCount: section == _SidebarSection.recent ? 1 : 0,
        ),
        SizedBox(height: spacing),
        MeshListRowSkeleton(
          dense: true,
          titleWidthFactor: section == _SidebarSection.inbox ? 0.52 : 0.44,
          subtitleWidthFactor: section == _SidebarSection.hosts ? 0.62 : 0.66,
          showMeta: section != _SidebarSection.inbox,
          showTrailing: section != _SidebarSection.hosts,
        ),
        SizedBox(height: spacing),
        MeshListRowSkeleton(
          dense: true,
          titleWidthFactor: 0.5,
          subtitleWidthFactor: 0.72,
          showMeta: true,
          badgeCount: section == _SidebarSection.recent ? 1 : 0,
        ),
      ],
    );
  }
}

class _ListPaneHeader extends StatelessWidget {
  const _ListPaneHeader({required this.title, required this.trailing});

  final String title;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: 34,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colors.textPrimary,
                fontWeight: AppWeights.title,
                letterSpacing: AppLetterSpacing.headline,
              ),
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
  }
}

class _ListPaneActionButton extends StatelessWidget {
  const _ListPaneActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onTap != null;
    return Tooltip(
      message: enabled ? label : 'No machine ready',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppShapes.badge,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: enabled ? colors.canvas : colors.surfaceMuted,
              borderRadius: AppShapes.badge,
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: enabled ? colors.accent : colors.textTertiary,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: enabled ? colors.accent : colors.textTertiary,
                    fontWeight: AppWeights.emphasis,
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

class _SidebarCountPill extends StatelessWidget {
  const _SidebarCountPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: AppShapes.badge,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.textPrimary,
              fontWeight: AppWeights.emphasis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarPane extends StatelessWidget {
  const _SidebarPane({
    super.key,
    required this.section,
    required this.hosts,
    required this.api,
    required this.selectedSessionId,
    required this.selectedHostId,
    required this.query,
    required this.onOpenSession,
    required this.onOpenSessionFromAction,
    required this.onOpenPendingSession,
    required this.onOpenHostDetail,
    required this.onEditHost,
    required this.onRemoveHost,
    required this.onAddHost,
    required this.onToggleHostEnabled,
    required this.onActiveCountChanged,
    required this.onInboxCountChanged,
    this.recentFilters = const RecentSessionFilters(),
  });

  final _SidebarSection section;
  final List<HostProfile> hosts;
  final ApiClient api;
  final String? selectedSessionId;
  final String? selectedHostId;
  final String query;
  final void Function(HostProfile, SessionSummary) onOpenSession;
  final void Function(HostProfile, PendingAction) onOpenSessionFromAction;
  final OpenPendingSessionCallback onOpenPendingSession;
  final ValueChanged<HostProfile> onOpenHostDetail;
  final HostProfileActionCallback onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;
  final VoidCallback onAddHost;
  final HostProfileActionCallback onToggleHostEnabled;
  final ValueChanged<int> onActiveCountChanged;
  final ValueChanged<int> onInboxCountChanged;
  final RecentSessionFilters recentFilters;

  @override
  Widget build(BuildContext context) {
    final enabledHosts = hosts
        .where((host) => host.enabled)
        .toList(growable: false);
    switch (section) {
      case _SidebarSection.recent:
        return RecentPane(
          hosts: enabledHosts,
          api: api,
          onOpenSession: onOpenSession,
          onActiveCountChanged: onActiveCountChanged,
          query: query,
          selectedSessionId: selectedSessionId,
          dense: true,
          hasSavedHosts: hosts.isNotEmpty,
          screenAwakeSourceKey: 'desktop-recent-sessions',
          filters: recentFilters,
        );
      case _SidebarSection.inbox:
        return InboxPane(
          hosts: enabledHosts,
          allHosts: hosts,
          api: api,
          onOpenSession: onOpenSessionFromAction,
          onOpenPendingSession: onOpenPendingSession,
          onEditHost: onEditHost,
          onToggleHostEnabled: onToggleHostEnabled,
          onInboxCountChanged: onInboxCountChanged,
          query: query,
          dense: true,
          hasSavedHosts: hosts.isNotEmpty,
        );
      case _SidebarSection.hosts:
        return HostsPane(
          hostNodes: {},
          hosts: hosts,
          installedAppVersion: '',
          onOpenHost: onOpenHostDetail,
          onEditHost: onEditHost,
          onRemoveHost: onRemoveHost,
          onToggleEnabled: onToggleHostEnabled,
          onAddHost: onAddHost,
          query: query,
          dense: true,
          selectedHostId: selectedHostId,
        );
    }
  }
}

class _DetailPane extends StatefulWidget {
  const _DetailPane({
    required this.titlebarInset,
    required this.active,
    required this.activeHost,
    required this.showUsage,
    required this.hosts,
    required this.enabledHosts,
    required this.api,
    required this.onClose,
    required this.onOpenSession,
    required this.onArchived,
    required this.onAddHost,
    required this.onShowHosts,
  });

  final double titlebarInset;
  final _ActiveSession? active;
  final HostProfile? activeHost;
  final bool showUsage;
  final List<HostProfile> hosts;
  final List<HostProfile> enabledHosts;
  final ApiClient api;
  final VoidCallback onClose;
  final void Function(HostProfile, SessionSummary) onOpenSession;
  final void Function(HostProfile, SessionSummary) onArchived;
  final VoidCallback onAddHost;
  final VoidCallback onShowHosts;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
  Future<void> _startSessionFromEmptyState() async {
    if (widget.hosts.isEmpty) {
      widget.onAddHost();
      return;
    }
    if (widget.enabledHosts.isEmpty) {
      return;
    }
    final result = await showCreateSessionHostLauncher(
      context,
      hosts: widget.enabledHosts,
      api: widget.api,
    );
    if (!mounted || result == null) {
      return;
    }
    widget.onOpenSession(result.host, result.session);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final activeHost = widget.activeHost;
    Widget child;
    if (widget.showUsage) {
      child = UsagePane(
        key: const ValueKey('usage'),
        hosts: widget.enabledHosts,
        api: widget.api,
        topPadding: widget.titlebarInset,
        dense: true,
      );
    } else if (active != null) {
      child = _buildActive(
        context,
        active,
        key: ValueKey('active-${active.host.id}-${active.session.id}'),
      );
    } else if (activeHost != null) {
      child = _buildHost(
        context,
        activeHost,
        key: ValueKey('host-${activeHost.id}'),
      );
    } else {
      child = _buildEmpty(context, key: const ValueKey('empty'));
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: child,
    );
  }

  Widget _buildEmpty(BuildContext context, {required Key key}) {
    final colors = context.colors;
    final hasEnabledHosts = widget.enabledHosts.isNotEmpty;
    return Container(
      key: key,
      color: colors.canvas,
      child: Column(
        children: [
          SizedBox(height: widget.titlebarInset + 16),
          Expanded(
            child: widget.hosts.isEmpty
                ? _OnboardingEmptyState(
                    colors: colors,
                    onAddHost: widget.onAddHost,
                  )
                : Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: colors.surfaceMuted,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: colors.border),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            hasEnabledHosts
                                ? Icons.play_circle_outline_rounded
                                : Icons.hub_rounded,
                            color: hasEnabledHosts
                                ? colors.textSecondary
                                : colors.textTertiary,
                            size: 26,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          hasEnabledHosts
                              ? 'Choose a session or start a new one'
                              : 'Turn on a host',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: AppWeights.title),
                        ),
                        const SizedBox(height: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Text(
                            hasEnabledHosts
                                ? 'Pick a session from the sidebar, or start a new one on any machine that is ready.'
                                : 'Open Machines to enable a saved machine before you launch an agent.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.textSecondary),
                          ),
                        ),
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          onPressed: hasEnabledHosts
                              ? _startSessionFromEmptyState
                              : widget.onShowHosts,
                          icon: Icon(
                            hasEnabledHosts
                                ? Icons.play_arrow_rounded
                                : Icons.hub_rounded,
                          ),
                          label: Text(
                            hasEnabledHosts
                                ? 'Start a session'
                                : 'Open machines',
                          ),
                        ),
                        if (widget.hosts.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          MeshPill(
                            label:
                                '${widget.enabledHosts.length} of ${widget.hosts.length} machines ready',
                            icon: Icons.hub_rounded,
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildActive(
    BuildContext context,
    _ActiveSession active, {
    required Key key,
  }) {
    return SessionScreen(
      key: ValueKey(
        'session-${active.host.id}-${active.session.id}-${active.serial}',
      ),
      host: active.host,
      session: active.session,
      api: widget.api,
      initialComposerSeed: active.composerSeed,
      onOpenSession: (session) => widget.onOpenSession(active.host, session),
      onArchived: () => widget.onArchived(active.host, active.session),
      onClose: widget.onClose,
      topPadding: widget.titlebarInset + 6,
      desktopMode: true,
    );
  }

  Widget _buildHost(
    BuildContext context,
    HostProfile host, {
    required Key key,
  }) {
    return Stack(
      key: key,
      children: [
        Positioned.fill(
          child: HostDetailScreen(
            key: ValueKey('host-detail-${host.id}'),
            host: host,
            api: widget.api,
            embedded: true,
            topPadding: widget.titlebarInset + 6,
            showMobileClientCompatibility: false,
            onOpenSession: (session) => widget.onOpenSession(host, session),
          ),
        ),
        Positioned(
          top: 6,
          right: 10,
          child: _CloseSessionButton(onClose: widget.onClose),
        ),
      ],
    );
  }
}

class _CloseSessionButton extends StatelessWidget {
  const _CloseSessionButton({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: 'Close panel',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppShapes.badge,
          onTap: onClose,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.7),
              borderRadius: AppShapes.badge,
              border: Border.all(color: colors.border),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.close_rounded,
              size: 15,
              color: colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A thin vertical splitter that shows a resize cursor on hover and forwards
/// horizontal drag deltas to the shell, which clamps and persists the width.
class _SidebarResizer extends StatefulWidget {
  const _SidebarResizer({
    required this.color,
    required this.onDrag,
    required this.onDragEnd,
    this.onDoubleTap,
  });

  final Color color;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;
  final VoidCallback? onDoubleTap;

  @override
  State<_SidebarResizer> createState() => _SidebarResizerState();
}

class _SidebarResizerState extends State<_SidebarResizer> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: widget.onDoubleTap,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: SizedBox(
          width: 5,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: active ? 2 : 1,
              color: widget.color.withValues(alpha: active ? 0.9 : 1.0),
            ),
          ),
        ),
      ),
    );
  }
}

/// The desktop-shell's third pane ("inspector"). Draws the header
/// chrome (title + optional surface actions + close button) and hands
/// the body area over to the surface.
class _InspectorPane extends StatelessWidget {
  const _InspectorPane({required this.surface, required this.onClose});

  final InspectorSurface surface;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final actions = surface.actionsBuilder?.call(context) ?? const <Widget>[];
    return Container(
      color: colors.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                if (surface.icon != null) ...[
                  Icon(surface.icon, size: 16, color: colors.textSecondary),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    surface.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: AppWeights.title,
                    ),
                  ),
                ),
                ...actions,
                if (actions.isNotEmpty) const SizedBox(width: 4),
                InkResponse(
                  radius: 18,
                  onTap: onClose,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: surface.bodyBuilder(context)),
        ],
      ),
    );
  }
}
