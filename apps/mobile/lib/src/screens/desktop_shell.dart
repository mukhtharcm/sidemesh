import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api_client.dart';
import '../host_store.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import '../widgets/mesh_widgets.dart';
import 'home_screen.dart';
import 'session_screen.dart';

/// Two-pane macOS shell — sidebar (Recent / Inbox / Hosts) on the left,
/// active session on the right. Reuses the same panes as the mobile home
/// screen, so we keep a single source of truth for session data.
class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

enum _SidebarSection { recent, inbox, hosts }

class _ActiveSession {
  const _ActiveSession({required this.host, required this.session});
  final HostProfile host;
  final SessionSummary session;
}

class _DesktopShellState extends State<DesktopShell> {
  final HostStore _store = HostStore();
  final ApiClient _api = ApiClient();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'sidebar-search');

  List<HostProfile> _hosts = const [];
  bool _loading = true;
  _SidebarSection _section = _SidebarSection.recent;
  _ActiveSession? _active;
  int _inboxCount = 0;
  int _activeCount = 0;
  String _query = '';
  double _sidebarWidth = _defaultSidebarWidth;
  Timer? _searchDebounce;
  // Used to trigger refresh of sidebar panes after a host/session mutation.
  int _refreshTick = 0;

  // Reserve space under the macOS titlebar so traffic lights & drag area
  // stay clean. 28pt matches the standard NSWindow titlebar height.
  static const double _titlebarInset = 28;
  static const double _defaultSidebarWidth = 304;
  static const double _minSidebarWidth = 240;
  static const double _maxSidebarWidth = 440;
  static const String _sidebarWidthPref = 'sidemesh.desktop.sidebarWidth';

  @override
  void initState() {
    super.initState();
    _loadHosts();
    _loadSidebarWidth();
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
      _searchDebounce = Timer(
        const Duration(milliseconds: 140),
        () {
          if (!mounted) return;
          setState(() => _query = _searchController.text);
        },
      );
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadHosts() async {
    final hosts = await _store.loadHosts();
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _loading = false;
    });
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

  Future<void> _persistSidebarWidth() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_sidebarWidthPref, _sidebarWidth);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  void _showShortcutsSheet() {
    final colors = context.colors;
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final entries = <({String keys, String label})>[
          (keys: '⌘F', label: 'Focus search'),
          (keys: '⌘R', label: 'Refresh'),
          (keys: '⌘W', label: 'Close active session'),
          (keys: '⌘1 / ⌘2 / ⌘3', label: 'Recent / Inbox / Hosts'),
          (keys: '⌘/', label: 'Show this help'),
          (keys: 'Enter', label: 'Send message'),
          (keys: 'Shift+Enter', label: 'Newline in composer'),
          (keys: 'Long-press', label: 'Copy message to clipboard'),
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
                        style: Theme.of(dialogContext)
                            .textTheme
                            .titleMedium
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
                  for (final e in entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.label,
                              style: TextStyle(
                                color: colors.textPrimary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surfaceMuted,
                              borderRadius: BorderRadius.circular(6),
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
                ],
              ),
            ),
          ),
        );
      },
    );
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
    final updated = _hosts.where((h) => h.id != host.id).toList();
    await _store.saveHosts(updated);
    if (_active?.host.id == host.id) {
      setState(() => _active = null);
    }
    await _loadHosts();
    _bumpRefresh();
  }

  void _openSession(HostProfile host, SessionSummary session) {
    setState(() {
      _active = _ActiveSession(host: host, session: session);
    });
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

  void _bumpRefresh() {
    setState(() => _refreshTick++);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.keyR, meta: true):
              _RefreshIntent(),
          SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _FocusSearchIntent(),
          SingleActivator(LogicalKeyboardKey.keyW, meta: true):
              _CloseActiveSessionIntent(),
          SingleActivator(LogicalKeyboardKey.slash, meta: true):
              _ShowShortcutsIntent(),
          SingleActivator(LogicalKeyboardKey.slash, meta: true, shift: true):
              _ShowShortcutsIntent(),
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
          },
          child: Focus(
            autofocus: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Sidebar(
                  titlebarInset: _titlebarInset,
                  width: _sidebarWidth,
                  hosts: _hosts,
                  loading: _loading,
                  api: _api,
                  section: _section,
                  refreshTick: _refreshTick,
                  inboxCount: _inboxCount,
                  activeCount: _activeCount,
                  selectedSessionId: _active?.session.id,
                  searchController: _searchController,
                  searchFocus: _searchFocus,
                  query: _query,
                  onClearSearch: () {
                    _searchController.clear();
                  },
                  onSelectSection: (s) => setState(() => _section = s),
                  onOpenSession: _openSession,
                  onOpenSessionFromAction: (host, action) =>
                      _openSession(host, _sessionFromAction(action)),
                  onAddHost: () => _showHostEditor(),
                  onEditHost: (h) => _showHostEditor(initial: h),
                  onRemoveHost: _removeHost,
                  onActiveCountChanged: (n) {
                    if (!mounted) return;
                    setState(() => _activeCount = n);
                  },
                  onInboxCountChanged: (n) {
                    if (!mounted) return;
                    setState(() => _inboxCount = n);
                  },
                  onShowShortcuts: _showShortcutsSheet,
                ),
                _SidebarResizer(
                  color: colors.border,
                  onDrag: _resizeSidebar,
                  onDragEnd: _persistSidebarWidth,
                ),
                Expanded(
                  child: _DetailPane(
                    titlebarInset: _titlebarInset,
                    active: _active,
                    api: _api,
                    onClose: () => setState(() => _active = null),
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
    required this.activeCount,
    required this.selectedSessionId,
    required this.searchController,
    required this.searchFocus,
    required this.query,
    required this.onClearSearch,
    required this.onSelectSection,
    required this.onOpenSession,
    required this.onOpenSessionFromAction,
    required this.onAddHost,
    required this.onEditHost,
    required this.onRemoveHost,
    required this.onActiveCountChanged,
    required this.onInboxCountChanged,
    required this.onShowShortcuts,
  });

  final double titlebarInset;
  final double width;
  final List<HostProfile> hosts;
  final bool loading;
  final ApiClient api;
  final _SidebarSection section;
  final int refreshTick;
  final int inboxCount;
  final int activeCount;
  final String? selectedSessionId;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final String query;
  final VoidCallback onClearSearch;
  final ValueChanged<_SidebarSection> onSelectSection;
  final void Function(HostProfile, SessionSummary) onOpenSession;
  final void Function(HostProfile, PendingAction) onOpenSessionFromAction;
  final VoidCallback onAddHost;
  final ValueChanged<HostProfile> onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;
  final ValueChanged<int> onActiveCountChanged;
  final ValueChanged<int> onInboxCountChanged;
  final VoidCallback onShowShortcuts;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: width,
      child: Container(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Draggable titlebar area with traffic-light inset.
            SizedBox(height: titlebarInset + 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(76, 0, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: colors.accentMuted,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.hub_rounded,
                      size: 14,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Sidemesh',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  _SidebarIconAction(
                    icon: Icons.add_rounded,
                    tooltip: 'Add host',
                    onTap: onAddHost,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: _SidebarSegments(
                section: section,
                inboxCount: inboxCount,
                activeCount: activeCount,
                onSelect: onSelectSection,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: _SidebarSearchField(
                controller: searchController,
                focusNode: searchFocus,
                onClear: onClearSearch,
              ),
            ),
            Expanded(
              child: loading
                  ? const MeshLoader()
                  : _SidebarPane(
                      key: ValueKey('pane-${section.name}-$refreshTick'),
                      section: section,
                      hosts: hosts,
                      api: api,
                      selectedSessionId: selectedSessionId,
                      query: query,
                      onOpenSession: onOpenSession,
                      onOpenSessionFromAction: onOpenSessionFromAction,
                      onEditHost: onEditHost,
                      onRemoveHost: onRemoveHost,
                      onAddHost: onAddHost,
                      onActiveCountChanged: onActiveCountChanged,
                      onInboxCountChanged: onInboxCountChanged,
                    ),
            ),
            Container(height: 1, color: colors.border),
            _SidebarFooter(
              onAddHost: onAddHost,
              onShowShortcuts: onShowShortcuts,
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarSegments extends StatelessWidget {
  const _SidebarSegments({
    required this.section,
    required this.inboxCount,
    required this.activeCount,
    required this.onSelect,
  });

  final _SidebarSection section;
  final int inboxCount;
  final int activeCount;
  final ValueChanged<_SidebarSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget pill(
      _SidebarSection s,
      String label,
      IconData icon, {
      int badge = 0,
    }) {
      final selected = section == s;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: selected ? colors.accentMuted : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelect(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 7,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 15,
                      color: selected ? colors.accent : colors.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: selected ? colors.accent : colors.textSecondary,
                      ),
                    ),
                    if (badge > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: colors.accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$badge',
                          style: TextStyle(
                            color: colors.accentOn,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        pill(
          _SidebarSection.recent,
          'Recent',
          Icons.schedule_rounded,
          badge: activeCount,
        ),
        pill(
          _SidebarSection.inbox,
          'Inbox',
          Icons.all_inbox_rounded,
          badge: inboxCount,
        ),
        pill(_SidebarSection.hosts, 'Hosts', Icons.hub_rounded),
      ],
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
    required this.query,
    required this.onOpenSession,
    required this.onOpenSessionFromAction,
    required this.onEditHost,
    required this.onRemoveHost,
    required this.onAddHost,
    required this.onActiveCountChanged,
    required this.onInboxCountChanged,
  });

  final _SidebarSection section;
  final List<HostProfile> hosts;
  final ApiClient api;
  final String? selectedSessionId;
  final String query;
  final void Function(HostProfile, SessionSummary) onOpenSession;
  final void Function(HostProfile, PendingAction) onOpenSessionFromAction;
  final ValueChanged<HostProfile> onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;
  final VoidCallback onAddHost;
  final ValueChanged<int> onActiveCountChanged;
  final ValueChanged<int> onInboxCountChanged;

  @override
  Widget build(BuildContext context) {
    switch (section) {
      case _SidebarSection.recent:
        return RecentPane(
          hosts: hosts,
          api: api,
          onOpenSession: onOpenSession,
          onActiveCountChanged: onActiveCountChanged,
          query: query,
          selectedSessionId: selectedSessionId,
        );
      case _SidebarSection.inbox:
        return InboxPane(
          hosts: hosts,
          api: api,
          onOpenSession: onOpenSessionFromAction,
          onInboxCountChanged: onInboxCountChanged,
          query: query,
        );
      case _SidebarSection.hosts:
        return HostsPane(
          hosts: hosts,
          onOpenHost: (h) {
            // On desktop, "opening" a host surfaces its sessions in Recent.
            // For now, just open the editor as a quick way to inspect.
            onEditHost(h);
          },
          onEditHost: onEditHost,
          onRemoveHost: onRemoveHost,
          onAddHost: onAddHost,
          query: query,
        );
    }
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({required this.onAddHost, required this.onShowShortcuts});

  final VoidCallback onAddHost;
  final VoidCallback onShowShortcuts;

  @override
  Widget build(BuildContext context) {
    // Slim status-bar footer. The prominent "Add host" action lives in the
    // sidebar header as a compact "+" so this row stays balanced with the
    // session composer on the detail pane.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Row(
        children: [
          _SidebarIconAction(
            icon: Icons.add_link_rounded,
            tooltip: 'Add host',
            onTap: onAddHost,
          ),
          const Spacer(),
          _SidebarIconAction(
            icon: Icons.keyboard_rounded,
            tooltip: 'Keyboard shortcuts (⌘/)',
            onTap: onShowShortcuts,
          ),
          const SizedBox(width: 6),
          const _ThemeToggleButton(),
        ],
      ),
    );
  }
}

class _SidebarIconAction extends StatefulWidget {
  const _SidebarIconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_SidebarIconAction> createState() => _SidebarIconActionState();
}

class _SidebarIconActionState extends State<_SidebarIconAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _hover ? colors.surfaceMuted : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(
                widget.icon,
                size: 16,
                color: _hover ? colors.textPrimary : colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeToggleButton extends StatefulWidget {
  const _ThemeToggleButton();

  @override
  State<_ThemeToggleButton> createState() => _ThemeToggleButtonState();
}

class _ThemeToggleButtonState extends State<_ThemeToggleButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final controller = ThemeScope.of(context);
    final IconData icon = switch (controller.mode) {
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };
    final String tooltip = switch (controller.mode) {
      ThemeMode.dark => 'Theme: dark (click for system)',
      ThemeMode.light => 'Theme: light (click for dark)',
      ThemeMode.system => 'Theme: system (click for light)',
    };
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              final next = switch (controller.mode) {
                ThemeMode.system => ThemeMode.light,
                ThemeMode.light => ThemeMode.dark,
                ThemeMode.dark => ThemeMode.system,
              };
              controller.setMode(next);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _hover ? colors.surfaceMuted : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 16,
                color: _hover ? colors.textPrimary : colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailPane extends StatefulWidget {
  const _DetailPane({
    required this.titlebarInset,
    required this.active,
    required this.api,
    required this.onClose,
  });

  final double titlebarInset;
  final _ActiveSession? active;
  final ApiClient api;
  final VoidCallback onClose;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
  bool _hoverClose = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    // Cross-fade between the empty placeholder and the active session so
    // closing/swapping doesn't snap the entire right-hand pane.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: active == null
          ? _buildEmpty(context, key: const ValueKey('empty'))
          : _buildActive(
              context,
              active,
              key: ValueKey('active-${active.host.id}-${active.session.id}'),
            ),
    );
  }

  Widget _buildEmpty(BuildContext context, {required Key key}) {
    final colors = context.colors;
    return Container(
      key: key,
      color: colors.canvas,
      child: Column(
        children: [
          SizedBox(height: widget.titlebarInset + 16),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: colors.accentMuted,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.forum_rounded,
                      color: colors.accent,
                      size: 26,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Pick a session',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Choose a host and session from the sidebar to get going.',
                    style: TextStyle(color: colors.textSecondary),
                  ),
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
    return MouseRegion(
      key: key,
      onEnter: (_) => setState(() => _hoverClose = true),
      onExit: (_) => setState(() => _hoverClose = false),
      child: Stack(
        children: [
          Positioned.fill(
            child: SessionScreen(
              key: ValueKey('session-${active.host.id}-${active.session.id}'),
              host: active.host,
              session: active.session,
              api: widget.api,
              topPadding: widget.titlebarInset + 6,
            ),
          ),
          Positioned(
            top: 6,
            right: 10,
            child: AnimatedOpacity(
              opacity: _hoverClose ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 140),
              child: IgnorePointer(
                ignoring: !_hoverClose,
                child: _CloseSessionButton(onClose: widget.onClose),
              ),
            ),
          ),
        ],
      ),
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
      message: 'Close session',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onClose,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(8),
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

class _SidebarSearchField extends StatefulWidget {
  const _SidebarSearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;

  @override
  State<_SidebarSearchField> createState() => _SidebarSearchFieldState();
}

class _SidebarSearchFieldState extends State<_SidebarSearchField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocus);
    _focused = widget.focusNode.hasFocus;
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocus);
    super.dispose();
  }

  void _handleFocus() {
    if (!mounted) return;
    if (widget.focusNode.hasFocus != _focused) {
      setState(() => _focused = widget.focusNode.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: colors.composerBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _focused ? colors.accent : colors.border,
          width: _focused ? 1.5 : 1,
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: colors.accent.withValues(alpha: 0.18),
                  blurRadius: 0,
                  spreadRadius: 2,
                ),
              ]
            : const [],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 15,
            color: _focused ? colors.accent : colors.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
              cursorColor: colors.accent,
              // Kill the default underline + Material focus halo so our
              // outer AnimatedContainer owns the focus visual.
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                hoverColor: Colors.transparent,
                focusColor: Colors.transparent,
                hintText: 'Search (⌘F)',
                hintStyle: TextStyle(
                  color: colors.textTertiary,
                  fontSize: 12.5,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              if (widget.controller.text.isEmpty) {
                return const SizedBox.shrink();
              }
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: widget.onClear,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: colors.textTertiary,
                  ),
                ),
              );
            },
          ),
        ],
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
  });

  final Color color;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

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
