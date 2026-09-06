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
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_menu.dart';
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
import '../theme/app_control_styles.dart';

/// macOS shell with rail, list pane, active detail, and optional tools pane.
/// Reuses the same panes as the mobile home
/// screen, so we keep a single source of truth for session data.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key, this.api, this.hostStore});

  final ApiClient? api;
  final HostStore? hostStore;

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
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.hub_rounded,
                size: AppSizes.iconWell,
                color: colors.textSecondary,
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Connect a machine',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: AppWeights.strong,
                  color: colors.textPrimary,
                  letterSpacing: AppLetterSpacing.headline,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Install Sidemesh on the machine you want to control, then connect it here.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                  height: AppLineHeights.body,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              FilledButton.icon(
                onPressed: onAddHost,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add machine'),
              ),
              const SizedBox(height: AppSpacing.xl),
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
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
                    const SizedBox(height: AppSpacing.tight),
                    Text(
                      'Run these once on the machine you want to control.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: AppLineHeights.body,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.compact,
      ),
      decoration: BoxDecoration(
        color: colors.codeBackground,
        borderRadius: BorderRadius.circular(AppRadii.panel),
        border: Border.all(color: colors.codeBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < lines.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.tight),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '\$',
                        style: monoStyle(
                          color: colors.accent,
                          fontSize: AppFontSizes.caption,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          lines[i],
                          style: monoStyle(
                            color: colors.codeForeground,
                            fontSize: AppFontSizes.caption,
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

class _DesktopSessionDraft {
  const _DesktopSessionDraft({required this.host, required this.serial});

  final HostProfile host;
  final int serial;
}

class _DesktopShellState extends State<DesktopShell> {
  late final HostStore _store = widget.hostStore ?? HostStore();
  late final ApiClient _api;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'sidebar-search');
  final InspectorController _inspector = InspectorController();

  List<HostProfile> _hosts = const [];
  bool _loading = true;
  bool _loadingHosts = false;
  bool _hostLoadSlow = false;
  Object? _hostLoadError;
  _SidebarSection _section = _SidebarSection.recent;
  _ActiveSession? _active;
  _DesktopSessionDraft? _draft;
  HostProfile? _activeHost;
  bool _showUsage = false;
  int _inboxCount = 0;
  bool _recentVerificationActive = false;
  int _sessionOpenSerial = 0;
  int _draftSerial = 0;
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
  static const double _defaultSidebarWidth = 320;
  static const double _minSidebarWidth = 280;
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
    _api = widget.api ?? ApiClient();
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
    if (_loadingHosts) return;
    _loadingHosts = true;
    setState(() {
      _loading = true;
      _hostLoadSlow = false;
      _hostLoadError = null;
    });
    final slowLoad = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _hostLoadSlow = true);
    });
    try {
      final hosts = await _store.loadHosts();
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        _loading = false;
        final draft = _draft;
        if (draft != null) {
          final matchingHosts = hosts.where((host) => host.id == draft.host.id);
          final updatedHost = matchingHosts.isEmpty
              ? null
              : matchingHosts.first;
          _draft = updatedHost == null || !updatedHost.enabled
              ? null
              : _DesktopSessionDraft(host: updatedHost, serial: draft.serial);
        }
      });
      for (final host in hosts) {
        if (!host.enabled) {
          HostStatusStore.instance.clear(host.id);
        }
      }
      ApprovalInboxStore.instance.configure(hosts: _enabledHosts, api: _api);
      unawaited(_handleNotificationRouteIntent());
    } catch (error) {
      if (mounted) setState(() => _hostLoadError = error);
    } finally {
      slowLoad.cancel();
      _loadingHosts = false;
      if (mounted) setState(() => _loading = false);
    }
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
            borderRadius: BorderRadius.circular(AppRadii.panel),
            side: BorderSide(color: colors.border),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.lg,
                AppSpacing.xl,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.keyboard_rounded,
                        size: AppSizes.inlineIcon,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        'Keyboard shortcuts',
                        style: Theme.of(dialogContext).textTheme.titleMedium
                            ?.copyWith(
                              color: colors.textPrimary,
                              fontWeight: AppWeights.title,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Close',
                        iconSize: AppSizes.inlineIcon,
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: Icon(
                          Icons.close_rounded,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Use these desktop shortcuts to move faster through the home surfaces.',
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(
                          color: colors.textSecondary,
                          height: AppLineHeights.caption,
                        ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  for (final section in sections) ...[
                    Text(
                      section.title,
                      style: Theme.of(dialogContext).textTheme.labelLarge
                          ?.copyWith(
                            color: colors.textSecondary,
                            fontWeight: AppWeights.strong,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    for (final e in section.items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                e.label,
                                style: TextStyle(
                                  color: colors.textPrimary,
                                  fontSize: AppFontSizes.compact,
                                  height: AppLineHeights.label,
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.md),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.compact,
                                vertical: AppSpacing.xs,
                              ),
                              decoration: BoxDecoration(
                                color: colors.surfaceMuted,
                                borderRadius: AppShapes.badge,
                                border: Border.all(color: colors.border),
                              ),
                              child: Text(
                                e.keys,
                                style: const TextStyle(
                                  fontSize: AppFontSizes.caption,
                                  fontFamily: AppFonts.code,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (section != sections.last)
                      const SizedBox(height: AppSpacing.sm),
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
    final existingDraft = _draft;
    if (existingDraft != null) {
      _inspector.close();
      setState(() {
        _active = null;
        _activeHost = null;
        _showUsage = false;
      });
      return;
    }
    final enabledHosts = _enabledHosts;
    final currentHost = _active?.host ?? _activeHost;
    final host =
        enabledHosts.where((host) => host.id == currentHost?.id).firstOrNull ??
        enabledHosts.first;
    _inspector.close();
    setState(() {
      _draft = _DesktopSessionDraft(host: host, serial: ++_draftSerial);
      _active = null;
      _activeHost = null;
      _showUsage = false;
    });
  }

  Future<void> _showHostEditor({HostProfile? initial}) async {
    final result = await showDialog<HostProfile>(
      context: context,
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
    if (_draft?.host.id == host.id) {
      setState(() => _draft = null);
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
    if (_draft?.host.id == host.id && disabling) {
      setState(() => _draft = null);
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
    bool clearDraft = false,
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
      if (clearDraft) _draft = null;
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

  bool _searchOpen = false;

  Future<void> _openSessionSearch() async {
    if (_searchOpen) return;
    _searchOpen = true;
    try {
      final result = await showSessionSearch(context, hosts: _hosts, api: _api);
      if (mounted && result != null) _openSession(result.host, result.session);
    } finally {
      _searchOpen = false;
    }
  }

  void _bumpRefresh() {
    setState(() => _refreshTick++);
  }

  /// Figures out how wide each column should be given the available [total]
  /// width. The list pane and inspector give up space
  /// before the detail pane does.
  ({double sidebar, double detail, double inspector}) _computePaneWidths(
    double total,
  ) {
    // Resizer is 6pt (see _SidebarResizer). When inspector is open,
    // the inspector pane gets its own resize handle on its left edge.
    const double resizer = 6;
    const double inspectorMin = _minInspectorWidth;
    const double detailMin = 560;
    final inspectorOpen =
        _inspector.current != null &&
        total >= _minSidebarWidth + inspectorMin + detailMin + resizer * 2;

    double sidebar = _sidebarWidth.clamp(_minSidebarWidth, _maxSidebarWidth);
    double inspector = inspectorOpen
        ? _inspectorWidth.clamp(_minInspectorWidth, _maxInspectorWidth)
        : 0;
    double inspectorResizer = inspectorOpen ? resizer : 0;

    double detail = total - sidebar - resizer - inspectorResizer - inspector;

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

    // At narrow widths the inspector is drawn over the conversation.
    // It does not reduce the width of the transcript behind it.
    return (sidebar: sidebar, detail: detail, inspector: inspector);
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
            padding: const EdgeInsets.all(AppSpacing.lg),
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
                const SizedBox(height: AppSpacing.sm),
                Text(
                  hasActiveSession
                      ? 'This side panel is reserved for extra details and '
                            'tools for the current session.'
                      : 'This side panel is reserved for extra details and '
                            'tools. Open a machine or session to show them '
                            'here.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: AppLineHeights.body,
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
                    if (_section == _SidebarSection.recent) {
                      unawaited(_openSessionSearch());
                      return null;
                    }
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
                          final overlayInspector =
                              _inspector.current != null &&
                              widths.inspector == 0;
                          return Stack(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SizedBox(
                                    width: widths.sidebar,
                                    child: Column(
                                      children: [
                                        SizedBox(height: _titlebarInset),
                                        if (_section != _SidebarSection.recent)
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: TextButton.icon(
                                              onPressed: () => setState(
                                                () => _section =
                                                    _SidebarSection.recent,
                                              ),
                                              icon: const Icon(
                                                Icons.arrow_back_rounded,
                                                size: AppSizes.inlineIcon,
                                              ),
                                              label: const Text(
                                                'Back to sessions',
                                              ),
                                            ),
                                          ),
                                        if (_section ==
                                                _SidebarSection.recent &&
                                            _inboxCount > 0)
                                          ListTile(
                                            leading: const Icon(
                                              Icons.inbox_outlined,
                                              size: AppSizes.icon,
                                            ),
                                            title: const Text('Needs you'),
                                            trailing: Text('$_inboxCount'),
                                            onTap: () => setState(
                                              () => _section =
                                                  _SidebarSection.inbox,
                                            ),
                                          ),
                                        Expanded(
                                          child: ListenableBuilder(
                                            listenable:
                                                ApprovalInboxStore.instance,
                                            builder: (context, _) => _Sidebar(
                                              titlebarInset: 0,
                                              width: widths.sidebar,
                                              hosts: _hosts,
                                              loading: _loading,
                                              loadError: _hostLoadError,
                                              onRetry: _loadHosts,
                                              api: _api,
                                              section: _section,
                                              refreshTick: _refreshTick,
                                              inboxCount: _inboxCount,
                                              selectedSessionId:
                                                  _active?.session.id,
                                              selectedHostId: _activeHost?.id,
                                              searchController:
                                                  _searchController,
                                              searchFocus: _searchFocus,
                                              query:
                                                  _section ==
                                                      _SidebarSection.recent
                                                  ? ''
                                                  : _query,
                                              onSearch: _openSessionSearch,
                                              onClearSearch: () {
                                                _searchController.clear();
                                              },
                                              onOpenSession: _openSession,
                                              onOpenSessionFromAction:
                                                  (host, action) =>
                                                      _openSession(
                                                        host,
                                                        _sessionFromAction(
                                                          action,
                                                        ),
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
                                              onAddHost: () =>
                                                  _showHostEditor(),
                                              onStartSession:
                                                  _startSessionFromSidebar,
                                              onEditHost: (h) =>
                                                  _showHostEditor(initial: h),
                                              onRemoveHost: _removeHost,
                                              onToggleHostEnabled:
                                                  _toggleHostEnabled,
                                              onActiveCountChanged: (_) {},
                                              recentVerificationActive:
                                                  _recentVerificationActive,
                                              onRecentVerificationChanged: (active) {
                                                if (!mounted ||
                                                    active ==
                                                        _recentVerificationActive) {
                                                  return;
                                                }
                                                setState(
                                                  () =>
                                                      _recentVerificationActive =
                                                          active,
                                                );
                                              },
                                              onInboxCountChanged: (n) {
                                                if (!mounted ||
                                                    n == _inboxCount) {
                                                  return;
                                                }
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
                                        _DesktopNavigation(
                                          onSelectSection: (s) =>
                                              setState(() => _section = s),
                                          onShowShortcuts: _showShortcutsSheet,
                                          onOpenSettings: _openSettings,
                                          onOpenUsage: _openUsage,
                                        ),
                                      ],
                                    ),
                                  ),
                                  _SidebarResizer(
                                    color: colors.border,
                                    onDrag: _resizeSidebar,
                                    onDragEnd: _persistSidebarWidth,
                                  ),
                                  SizedBox(
                                    key: const ValueKey('desktop-session-area'),
                                    width: widths.detail,
                                    child:
                                        _hosts.isEmpty &&
                                            (_loading || _hostLoadError != null)
                                        ? _SavedMachinesState(
                                            loading: _loading,
                                            slow: _hostLoadSlow,
                                            onRetry: _loadHosts,
                                          )
                                        : _DetailPane(
                                            titlebarInset: _titlebarInset,
                                            active: _active,
                                            draft: _draft,
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
                                            onCreatedSession: (host, session) =>
                                                _openSession(
                                                  host,
                                                  session,
                                                  clearDraft: true,
                                                ),
                                            onCancelDraft: () =>
                                                setState(() => _draft = null),
                                            onStartSession: () => unawaited(
                                              _startSessionFromSidebar(),
                                            ),
                                            onArchived:
                                                _handleActiveSessionArchived,
                                            onAddHost: () => _showHostEditor(),
                                            onShowHosts: () => setState(
                                              () => _section =
                                                  _SidebarSection.hosts,
                                            ),
                                          ),
                                  ),
                                  if (_inspector.current != null &&
                                      !overlayInspector) ...[
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
                              ),
                              if (overlayInspector) ...[
                                Positioned.fill(
                                  child: ModalBarrier(
                                    key: const ValueKey('inspector-barrier'),
                                    color: AppOverlayColors.modalBarrier,
                                    dismissible: true,
                                    onDismiss: _inspector.close,
                                  ),
                                ),
                                Positioned(
                                  top: _titlebarInset,
                                  bottom: 0,
                                  right: 0,
                                  width: _inspectorWidth
                                      .clamp(
                                        _minInspectorWidth,
                                        _maxInspectorWidth,
                                      )
                                      .clamp(0, constraints.maxWidth),
                                  child: FocusScope(
                                    autofocus: true,
                                    child: CallbackShortcuts(
                                      bindings: {
                                        const SingleActivator(
                                          LogicalKeyboardKey.escape,
                                        ): _inspector.close,
                                      },
                                      child: Focus(
                                        autofocus: true,
                                        child: _InspectorPane(
                                          surface: _inspector.current!,
                                          onClose: _inspector.close,
                                        ),
                                      ),
                                    ),
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
          if (_showWelcome && !_loading && _hostLoadError == null)
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

class _DesktopNavigation extends StatelessWidget {
  const _DesktopNavigation({
    required this.onSelectSection,
    required this.onShowShortcuts,
    required this.onOpenSettings,
    required this.onOpenUsage,
  });

  final ValueChanged<_SidebarSection> onSelectSection;
  final VoidCallback onShowShortcuts;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenUsage;

  @override
  Widget build(BuildContext context) => Material(
    color: context.colors.canvas,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () => onSelectSection(_SidebarSection.hosts),
            icon: const Icon(Icons.devices_outlined, size: AppSizes.inlineIcon),
            label: const Text('Machines'),
            style: AppControlStyles.foreground(context.colors.textSecondary),
          ),
          const Spacer(),
          IconButton(
            onPressed: onOpenSettings,
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, size: AppSizes.icon),
          ),
          AppMenuButton(
            tooltip: 'More',
            children: [
              AppMenuItem(
                label: 'Needs you',
                leadingIcon: Icons.inbox_outlined,
                onPressed: () => onSelectSection(_SidebarSection.inbox),
              ),
              AppMenuItem(
                label: 'Usage',
                leadingIcon: Icons.data_usage_rounded,
                onPressed: onOpenUsage,
              ),
              AppMenuItem(
                label: 'Keyboard shortcuts',
                leadingIcon: Icons.keyboard_outlined,
                onPressed: onShowShortcuts,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.titlebarInset,
    required this.width,
    required this.hosts,
    required this.loading,
    required this.loadError,
    required this.onRetry,
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
    required this.onSearch,
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
    required this.recentVerificationActive,
    required this.onRecentVerificationChanged,
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
  final Object? loadError;
  final VoidCallback onRetry;
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
  final VoidCallback onSearch;
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
  final bool recentVerificationActive;
  final ValueChanged<bool> onRecentVerificationChanged;
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
          IconButton(
            tooltip: 'Search sessions (⌘F)',
            onPressed: onSearch,
            icon: const Icon(Icons.search_rounded, size: AppSizes.icon),
          ),
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
            onTap:
                !loading &&
                    loadError == null &&
                    (hosts.isEmpty || canStartSession)
                ? onStartSession
                : null,
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
        color: colors.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: titlebarInset + 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.compact,
              ),
              child: _ListPaneHeader(
                title: _sidebarSectionTitle(section),
                trailing: headerAction,
                verificationActive:
                    section == _SidebarSection.recent &&
                    recentVerificationActive,
              ),
            ),
            if (section != _SidebarSection.recent)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.compact,
                ),
                child: DesktopSidebarSearchField(
                  controller: searchController,
                  focusNode: searchFocus,
                  onClear: onClearSearch,
                ),
              ),
            if (!loading &&
                loadError == null &&
                !canStartSession &&
                section == _SidebarSection.recent)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.compact,
                ),
                child: Text(
                  hosts.isEmpty
                      ? 'Add a machine to start your first session.'
                      : 'Enable a machine before starting a new session.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: AppLineHeights.caption,
                  ),
                ),
              ),
            const NotificationPermissionBanner(
              margin: EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.compact,
              ),
              compact: true,
            ),
            Expanded(
              child: loading
                  ? const MeshLoader(label: 'Loading machines')
                  : loadError != null
                  ? _SavedMachinesState(
                      loading: false,
                      slow: false,
                      onRetry: onRetry,
                    )
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
                      onRecentVerificationChanged: onRecentVerificationChanged,
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

class _ListPaneHeader extends StatelessWidget {
  const _ListPaneHeader({
    required this.title,
    required this.trailing,
    this.verificationActive = false,
  });

  final String title;
  final Widget trailing;
  final bool verificationActive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: 34,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
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
                const SizedBox(width: AppSpacing.sm),
                MeshDelayedActivityIndicator(
                  key: const ValueKey('recent-freshness-indicator'),
                  active: verificationActive,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.compact),
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
            duration: AppMotion.quick,
            curve: AppMotion.standard,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.sm,
            ),
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
                  size: AppSizes.compactIcon,
                  color: enabled ? colors.accent : colors.textTertiary,
                ),
                const SizedBox(width: AppSpacing.xs),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
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
    required this.onRecentVerificationChanged,
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
  final ValueChanged<bool> onRecentVerificationChanged;
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
          onVerificationChanged: onRecentVerificationChanged,
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
    required this.draft,
    required this.activeHost,
    required this.showUsage,
    required this.hosts,
    required this.enabledHosts,
    required this.api,
    required this.onClose,
    required this.onOpenSession,
    required this.onCreatedSession,
    required this.onCancelDraft,
    required this.onStartSession,
    required this.onArchived,
    required this.onAddHost,
    required this.onShowHosts,
  });

  final double titlebarInset;
  final _ActiveSession? active;
  final _DesktopSessionDraft? draft;
  final HostProfile? activeHost;
  final bool showUsage;
  final List<HostProfile> hosts;
  final List<HostProfile> enabledHosts;
  final ApiClient api;
  final VoidCallback onClose;
  final void Function(HostProfile, SessionSummary) onOpenSession;
  final void Function(HostProfile, SessionSummary) onCreatedSession;
  final VoidCallback onCancelDraft;
  final VoidCallback onStartSession;
  final void Function(HostProfile, SessionSummary) onArchived;
  final VoidCallback onAddHost;
  final VoidCallback onShowHosts;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final draft = widget.draft;
    final activeHost = widget.activeHost;
    final draftVisible =
        draft != null &&
        !widget.showUsage &&
        active == null &&
        activeHost == null;
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
    final primary = AnimatedSwitcher(
      duration: AppMotion.quick,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: child,
    );
    if (draft == null) return primary;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: draftVisible,
          child: TickerMode(enabled: !draftVisible, child: primary),
        ),
        Offstage(
          offstage: !draftVisible,
          child: TickerMode(
            enabled: draftVisible,
            child: CreateSessionHostForm(
              key: ValueKey(
                'desktop-new-session-${draft.host.id}-${draft.serial}',
              ),
              initialHost: draft.host,
              hosts: widget.enabledHosts,
              api: widget.api,
              presentation: CreateSessionPresentation.pane,
              topPadding: widget.titlebarInset + 6,
              paneActive: draftVisible,
              onCreated: widget.onCreatedSession,
              onCancel: widget.onCancelDraft,
            ),
          ),
        ),
      ],
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
                            borderRadius: BorderRadius.circular(AppRadii.panel),
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
                            size: AppSizes.largeIcon,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Text(
                          hasEnabledHosts
                              ? 'Ready when you are'
                              : 'Turn on a machine',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: AppWeights.title),
                        ),
                        const SizedBox(height: AppSpacing.tight),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Text(
                            hasEnabledHosts
                                ? 'Choose a session from the sidebar to continue.'
                                : 'Open Machines to enable a saved machine before you launch an agent.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.textSecondary),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        FilledButton.icon(
                          onPressed: hasEnabledHosts
                              ? widget.onStartSession
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
                          const SizedBox(height: AppSpacing.compact),
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
              color: colors.surface.withValues(alpha: AppEmphasis.secondary),
              borderRadius: AppShapes.badge,
              border: Border.all(color: colors.border),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.close_rounded,
              size: AppSizes.compactIcon,
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
              duration: AppMotion.quick,
              width: active ? 2 : 1,
              color: widget.color.withValues(
                alpha: active ? AppEmphasis.strong : AppEmphasis.full,
              ),
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
            constraints: const BoxConstraints(minHeight: AppSizes.control),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.border,
                  width: AppStrokes.border,
                ),
              ),
            ),
            child: Row(
              children: [
                if (surface.icon != null) ...[
                  Icon(
                    surface.icon,
                    size: AppSizes.compactIcon,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
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
                if (actions.isNotEmpty) const SizedBox(width: AppSpacing.xs),
                IconButton(
                  tooltip: 'Close panel',
                  onPressed: onClose,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: AppSizes.compactIcon,
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

/// Loading stored machines is not an empty fleet, including while keychain waits.
class _SavedMachinesState extends StatelessWidget {
  const _SavedMachinesState({
    required this.loading,
    required this.slow,
    required this.onRetry,
  });
  final bool loading;
  final bool slow;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading)
            const MeshLoader(label: 'Loading saved machines')
          else
            Text(
              'Could not load saved machines',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          if (slow || !loading) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              loading
                  ? 'Waiting for secure storage. Complete the system access prompt if one is open.'
                  : 'Your saved settings have not been changed. Try loading them again.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          ],
          if (!loading)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    ),
  );
}
