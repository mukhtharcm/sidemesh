import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/io.dart';

import '../api_client.dart';
import '../fs_languages.dart';
import '../models.dart';
import 'file_browser_screen.dart';
import 'file_viewer_pane.dart';
import 'file_viewer_screen.dart';
import 'inspector/inspector_controller.dart';
import 'inspector/inspector_file_browser.dart';
import 'inspector/inspector_persistence.dart';
import 'inspector/inspector_pinned.dart';
import 'inspector/inspector_search.dart';
import 'workspace_browser_dialog.dart';
import '../session_favorites_store.dart';
import '../session_overrides_store.dart';
import '../session_pins_store.dart';
import '../session_policy_store.dart';
import '../session_read_store.dart';
import '../session_turn_config_store.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/markdown_content.dart';
import '../widgets/diff_view.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/syntax_code_block.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.host,
    required this.session,
    required this.api,
    this.topPadding,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;
  // Extra top padding for embedded desktop use (to avoid overlapping the
  // transparent macOS titlebar). When null, SafeArea handles insets.
  final double? topPadding;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  static const _initialMessageLimit = 120;
  static const _initialActivityLimit = 80;
  static const _messagePageSize = 120;
  static const _activityPageSize = 80;
  static const _liveUpdateFlushInterval = Duration(milliseconds: 48);
  static const _maxDraftImageCount = 4;
  static const _maxDraftImageBytes = 5 * 1024 * 1024;
  static const _maxDraftPayloadBytes = 9 * 1024 * 1024;
  static const _maxDecodedDraftImageBytes = 18 * 1024 * 1024;

  final _composerController = TextEditingController();
  final _searchController = TextEditingController();
  final _composerFocusNode = FocusNode(debugLabel: 'session_composer');
  final _searchFocusNode = FocusNode(debugLabel: 'session_search');
  final _scrollController = ScrollController();
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;
  final SessionPinsStore _pinsStore = SessionPinsStore.instance;
  final SessionPolicyStore _policyStore = SessionPolicyStore.instance;
  final SessionReadStore _readStore = SessionReadStore.instance;
  final SessionTurnConfigStore _turnConfigStore =
      SessionTurnConfigStore.instance;
  final StringBuffer _assistantDeltaBuffer = StringBuffer();
  final Map<String, SessionActivity> _pendingActivityUpdates =
      <String, SessionActivity>{};

  // Live-streaming state is held in notifiers so that mid-stream deltas only
  // rebuild the tiny widgets that display them, not the whole Scaffold/list.
  final ValueNotifier<_LiveAssistantMessageState?> _liveAssistantNotifier =
      ValueNotifier<_LiveAssistantMessageState?>(null);
  final ValueNotifier<bool> _thinkingNotifier = ValueNotifier<bool>(false);

  SessionSummary? _session;
  List<SessionMessage> _messages = const [];
  List<SessionMessage> _optimisticMessages = const [];
  List<SessionActivity> _activities = const [];
  List<_ComposerImageAttachment> _draftAttachments =
      const <_ComposerImageAttachment>[];
  List<_ComposerSkillMention> _draftSkillMentions =
      const <_ComposerSkillMention>[];
  List<SkillSummary> _skills = const <SkillSummary>[];
  _ActiveComposerSkillQuery? _activeSkillQuery;
  SessionLogHistorySummary? _history;
  PendingAction? _pendingAction;
  int _messageLimit = _initialMessageLimit;
  int _activityLimit = _initialActivityLimit;
  bool _running = false;
  bool _loading = true;
  bool _loadingOlderHistory = false;
  bool _sending = false;
  bool _awaitingAssistantReply = false;
  bool _loadingSkills = false;
  String _searchQuery = '';
  String? _skillsError;
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _liveFlushTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  bool _restoreComposerFocusOnResume = false;
  int? _lastEventSeq;
  // Incremented whenever a fresh snapshot is requested so in-flight responses
  // from older requests can be discarded.
  int _snapshotRequestId = 0;
  // Buffer live events that arrive while a snapshot is in flight so we can
  // replay them after the snapshot's setState runs — prevents a stale
  // snapshot from clobbering an already-delivered action_opened / activity.
  final List<LiveEvent> _pendingLiveEvents = <LiveEvent>[];
  bool _snapshotInFlight = false;
  int _skillsRequestId = 0;

  // Memoized timeline entries so rebuilds that don't change list inputs skip
  // the list+sort work.
  List<SessionMessage>? _entriesMessagesRef;
  List<SessionMessage>? _entriesOptimisticRef;
  List<SessionActivity>? _entriesActivitiesRef;
  String? _entriesLiveAssistantId;
  List<_TimelineEntry> _cachedEntries = const [];

  _LiveAssistantMessageState? get _liveAssistantMessage =>
      _liveAssistantNotifier.value;

  String get _liveAssistantText => _liveAssistantMessage?.text ?? '';
  // Surfaces a "↓ New" pill when the user has scrolled away from the
  // bottom of the transcript so they can jump back to the live area.
  final ValueNotifier<bool> _showJumpToLatest = ValueNotifier<bool>(false);

  // Tracks which old-snapshot history banners the user has dismissed
  // this session. Reset whenever a brand-new snapshot arrives so the
  // banner can reappear if the truncation window changes.
  bool _historyBannerDismissed = false;
  SessionGitStatus? _gitStatus;
  bool _gitStatusLoading = false;
  String? _gitStatusError;
  int _gitStatusRequestId = 0;

  // Inspector (desktop pane-3) lifecycle tracking. Resolved in
  // [didChangeDependencies] so we can addListener/removeListener around
  // the same controller instance exposed by the shell's InspectorScope.
  InspectorController? _inspectorController;
  bool _inspectorRestoreAttempted = false;
  bool _inspectorSawOurSurface = false;

  // Ticks whenever the timeline inputs change so pane-3 surfaces
  // (currently the search panel) can rebuild with fresh records. A
  // simple ValueNotifier<int> is the lightest way to bridge the
  // session screen's state into a sibling pane.
  final ValueNotifier<int> _timelineRevision = ValueNotifier<int>(0);

  void _clearLiveAssistantMessage() {
    _liveAssistantNotifier.value = null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _favorites.ensureLoaded();
    _pinsStore.ensureLoaded();
    _pinsStore.addListener(_handlePinsChanged);
    _policyStore.ensureLoaded();
    _readStore.ensureLoaded();
    _composerController.addListener(_handleComposerChanged);
    _searchController.addListener(_handleSearchChanged);
    _session = widget.session;
    _scrollController.addListener(_onTranscriptScroll);
    _markCurrentSessionSeen();
    _loadSnapshot();
    _loadSkills();
    unawaited(_loadGitStatus(silent: true));
    _connectLive();
  }

  void _markCurrentSessionSeen() {
    final session = _session ?? widget.session;
    _readStore.markSeen(widget.host, session.id, session.updatedAt);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = InspectorScope.maybeOf(context);
    if (!identical(controller, _inspectorController)) {
      _inspectorController?.removeListener(_onInspectorChanged);
      _inspectorController = controller;
      _inspectorController?.addListener(_onInspectorChanged);
    }
    if (!_inspectorRestoreAttempted && controller != null) {
      _inspectorRestoreAttempted = true;
      unawaited(_restoreInspectorSurface());
    }
  }

  Future<void> _restoreInspectorSurface() async {
    final controller = _inspectorController;
    if (controller == null) return;
    // Pane 3 only materializes on wide shells; skip restoration on phones
    // so we don't surprise users with an unexpected sheet-equivalent on
    // resize-back to a small window.
    final width = MediaQuery.of(context).size.width;
    if (width < 900) return;
    final ownerKey = _inspectorOwnerKey();
    final kind = await InspectorPersistence.load(ownerKey);
    if (!mounted || _disposed) return;
    final cur = controller.current;
    // If a previous session's surface is still mounted in the pane, close
    // it now that our owner is active — otherwise we'd be inspecting the
    // wrong session.
    void closeOrphan() {
      final lingering = controller.current;
      if (lingering != null && lingering.ownerKey != ownerKey) {
        controller.closeForOwner(lingering.ownerKey);
      }
    }

    if (kind == null) {
      closeOrphan();
      return;
    }
    // If something else has already opened a surface for this owner
    // (e.g. the shell's debug shortcut) don't stomp it.
    if (cur != null && cur.ownerKey == ownerKey) return;
    switch (kind) {
      case InspectorSurfaceKind.search:
        controller.show(
          buildInspectorSearchSurface(
            ownerKey: ownerKey,
            controller: _searchController,
            focusNode: _searchFocusNode,
            recordsBuilder: _buildSearchRecords,
            refresh: _timelineRevision,
          ),
        );
        break;
      case InspectorSurfaceKind.fileBrowser:
        final session = _session ?? widget.session;
        controller.show(
          buildInspectorWorkspaceBrowserSurface(
            ownerKey: ownerKey,
            host: widget.host,
            api: widget.api,
            root: session.cwd,
          ),
        );
        break;
      case InspectorSurfaceKind.pinned:
        controller.show(
          buildInspectorPinnedSurface(
            ownerKey: ownerKey,
            pinsBuilder: _currentPins,
            onOpen: _showPinnedMessage,
            onUnpin: _unpinMessage,
            refresh: _pinsStore,
          ),
        );
        break;
      case InspectorSurfaceKind.debug:
      case InspectorSurfaceKind.gitDetails:
      case InspectorSurfaceKind.sessionDetails:
        // Not persisted / not owned by the session screen yet.
        break;
    }
  }

  void _onInspectorChanged() {
    if (!mounted || _disposed) return;
    final controller = _inspectorController;
    if (controller == null) return;
    final ownerKey = _inspectorOwnerKey();
    final cur = controller.current;
    if (cur != null && cur.ownerKey == ownerKey) {
      _inspectorSawOurSurface = true;
      unawaited(InspectorPersistence.save(ownerKey, cur.kind));
      return;
    }
    // cur is null or belongs to a different owner. We only persist "closed"
    // when the user actively dismissed OUR surface — a shell-driven
    // closeForOwner (session switch) leaves the saved state alone so we
    // can restore it next time the session becomes active again.
    if (cur == null &&
        _inspectorSawOurSurface &&
        controller.lastCloseWasUserInitiated) {
      unawaited(InspectorPersistence.save(ownerKey, null));
    }
    _inspectorSawOurSurface = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _inspectorController?.removeListener(_onInspectorChanged);
    _inspectorController = null;
    // Stamp the most recent session state as seen before we unmount so
    // anything that streamed in during the last turn counts as read on
    // the way out.
    _markCurrentSessionSeen();
    unawaited(_readStore.flush());
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _composerController.removeListener(_handleComposerChanged);
    _searchController.removeListener(_handleSearchChanged);
    _pinsStore.removeListener(_handlePinsChanged);
    _composerController.dispose();
    _searchController.dispose();
    _composerFocusNode.dispose();
    _searchFocusNode.dispose();
    _scrollController.removeListener(_onTranscriptScroll);
    _scrollController.dispose();
    _subscription?.cancel();
    _liveFlushTimer?.cancel();
    _channel?.sink.close();
    _liveAssistantNotifier.dispose();
    _thinkingNotifier.dispose();
    _showJumpToLatest.dispose();
    _timelineRevision.dispose();
    super.dispose();
  }

  void _handlePinsChanged() {
    if (!mounted || _disposed) return;
    setState(() {});
  }

  void _handleSearchChanged() {
    final query = _searchController.text;
    if (query == _searchQuery) return;
    setState(() => _searchQuery = query);
  }

  void _openSearchPanel() {
    final width = MediaQuery.of(context).size.width;
    final scope = InspectorScope.maybeOf(context);
    if (width >= 900 && scope != null) {
      scope.toggle(
        buildInspectorSearchSurface(
          ownerKey: _inspectorOwnerKey(),
          controller: _searchController,
          focusNode: _searchFocusNode,
          recordsBuilder: _buildSearchRecords,
          refresh: _timelineRevision,
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _disposed) return;
        if (_isSearchInspectorOpen(scope)) {
          _searchFocusNode.requestFocus();
        }
      });
      return;
    }
    final records = _buildSearchRecords();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final size = MediaQuery.of(sheetContext).size;
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: SizedBox(
            height: size.height * 0.85,
            child: SearchPanel(
              controller: _searchController,
              focusNode: _searchFocusNode,
              records: records,
              onClose: () => Navigator.of(sheetContext).maybePop(),
              showDragHandle: true,
              showCloseButton: false,
            ),
          ),
        );
      },
    );
  }

  String _inspectorOwnerKey() {
    final s = _session ?? widget.session;
    return '${widget.host.id}|${s.id}';
  }

  bool _isSearchInspectorOpen(InspectorController scope) {
    final cur = scope.current;
    return cur != null &&
        cur.kind == InspectorSurfaceKind.search &&
        cur.ownerKey == _inspectorOwnerKey();
  }

  bool _isPinnedInspectorOpen(InspectorController? scope) {
    if (scope == null) return false;
    final cur = scope.current;
    return cur != null &&
        cur.kind == InspectorSurfaceKind.pinned &&
        cur.ownerKey == _inspectorOwnerKey();
  }

  List<PinnedSessionMessage> _currentPins() {
    return _pinsStore.pinsFor(widget.host, (_session ?? widget.session).id);
  }

  void _openPinnedPanel() {
    final width = MediaQuery.of(context).size.width;
    final scope = InspectorScope.maybeOf(context);
    if (width >= 900 && scope != null) {
      scope.toggle(
        buildInspectorPinnedSurface(
          ownerKey: _inspectorOwnerKey(),
          pinsBuilder: _currentPins,
          onOpen: _showPinnedMessage,
          onUnpin: _unpinMessage,
          refresh: _pinsStore,
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final size = MediaQuery.of(sheetContext).size;
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: SizedBox(
            height: size.height * 0.75,
            child: _PinnedListSheet(
              pinsBuilder: _currentPins,
              refresh: _pinsStore,
              onOpen: (pin) {
                Navigator.of(sheetContext).maybePop();
                _showPinnedMessage(pin);
              },
              onUnpin: _unpinMessage,
              onClose: () => Navigator.of(sheetContext).maybePop(),
            ),
          ),
        );
      },
    );
  }

  void _toggleSearchPanel() {
    _openSearchPanel();
  }

  void _onTranscriptScroll() {
    if (!_scrollController.hasClients) return;
    // Reverse ListView: offset > 0 means the user has scrolled up away
    // from the newest message.
    final shouldShow = _scrollController.offset > 240;
    if (shouldShow != _showJumpToLatest.value) {
      _showJumpToLatest.value = shouldShow;
    }
  }

  Future<void> _loadSkills({bool forceReload = false}) async {
    final requestId = ++_skillsRequestId;
    if (mounted) {
      setState(() {
        _loadingSkills = true;
        _skillsError = null;
      });
    } else {
      _loadingSkills = true;
      _skillsError = null;
    }

    try {
      final catalog = await widget.api.fetchSkills(
        widget.host,
        cwd: (_session ?? widget.session).cwd,
        forceReload: forceReload,
      );
      if (!mounted || requestId != _skillsRequestId) {
        return;
      }
      setState(() {
        _skills = catalog.skills;
        _skillsError = catalog.errors.isEmpty
            ? null
            : catalog.errors.map((item) => item.message).join('\n');
        _loadingSkills = false;
      });
    } catch (error) {
      if (!mounted || requestId != _skillsRequestId) {
        return;
      }
      setState(() {
        _loadingSkills = false;
        _skillsError = friendlyError(error);
      });
    }
  }

  Future<void> _loadGitStatus({bool silent = false}) async {
    final requestId = ++_gitStatusRequestId;
    if (!silent && mounted) {
      setState(() {
        _gitStatusLoading = true;
        _gitStatusError = null;
      });
    }

    try {
      final status = await widget.api.fetchGitStatus(
        widget.host,
        widget.session.id,
      );
      if (!mounted || requestId != _gitStatusRequestId) {
        return;
      }
      setState(() {
        _gitStatus = status;
        _gitStatusLoading = false;
        _gitStatusError = status.error;
      });
    } catch (error) {
      if (!mounted || requestId != _gitStatusRequestId) {
        return;
      }
      setState(() {
        _gitStatusLoading = false;
        _gitStatusError = friendlyError(error);
      });
    }
  }

  void _handleComposerChanged() {
    final nextQuery = _extractActiveSkillQuery(_composerController.value);
    final nextDraftSkillMentions = _draftSkillMentions
        .where((item) => _composerController.text.contains(item.tokenText))
        .toList(growable: false);
    final queryChanged =
        nextQuery?.start != _activeSkillQuery?.start ||
        nextQuery?.end != _activeSkillQuery?.end ||
        nextQuery?.query != _activeSkillQuery?.query;
    final mentionsChanged = !listEquals(
      nextDraftSkillMentions,
      _draftSkillMentions,
    );
    if (queryChanged || mentionsChanged) {
      if (!mounted) {
        _activeSkillQuery = nextQuery;
        _draftSkillMentions = nextDraftSkillMentions;
      } else {
        setState(() {
          _activeSkillQuery = nextQuery;
          _draftSkillMentions = nextDraftSkillMentions;
        });
      }
    }
    if (nextQuery != null && _skills.isEmpty && !_loadingSkills) {
      unawaited(_loadSkills());
    }
  }

  _ActiveComposerSkillQuery? _extractActiveSkillQuery(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return null;
    }

    final text = value.text;
    final cursor = math.min(math.max(selection.extentOffset, 0), text.length);
    var start = cursor;
    while (start > 0 && !_isComposerWhitespace(text.codeUnitAt(start - 1))) {
      start -= 1;
    }
    var end = cursor;
    while (end < text.length && !_isComposerWhitespace(text.codeUnitAt(end))) {
      end += 1;
    }
    if (start >= end) {
      return null;
    }

    final token = text.substring(start, end);
    if (!token.startsWith(r'$')) {
      return null;
    }

    return _ActiveComposerSkillQuery(
      start: start,
      end: end,
      query: token.substring(1),
    );
  }

  bool _isComposerWhitespace(int codeUnit) {
    switch (codeUnit) {
      case 0x09:
      case 0x0A:
      case 0x0B:
      case 0x0C:
      case 0x0D:
      case 0x20:
        return true;
      default:
        return false;
    }
  }

  List<SkillSummary> get _skillSuggestions {
    final active = _activeSkillQuery;
    if (active == null) {
      return const <SkillSummary>[];
    }

    final query = active.query.trim().toLowerCase();
    final candidates = _skills.where((item) => item.enabled).toList();
    if (candidates.isEmpty) {
      return const <SkillSummary>[];
    }

    candidates.sort((left, right) {
      final leftScore = _skillSuggestionScore(left, query);
      final rightScore = _skillSuggestionScore(right, query);
      final scoreCompare = leftScore.compareTo(rightScore);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      );
    });

    return candidates
        .where((item) => _skillSuggestionScore(item, query) < 100)
        .take(6)
        .toList(growable: false);
  }

  int _skillSuggestionScore(SkillSummary skill, String query) {
    if (query.isEmpty) {
      return 0;
    }

    final displayName = skill.displayName.toLowerCase();
    final canonicalName = skill.name.toLowerCase();
    if (displayName.startsWith(query)) {
      return 0;
    }
    if (canonicalName.startsWith(query)) {
      return 1;
    }
    if (displayName.contains(query)) {
      return 2;
    }
    if (canonicalName.contains(query)) {
      return 3;
    }
    return 100;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isMacDesktop) {
      switch (state) {
        case AppLifecycleState.inactive:
        case AppLifecycleState.hidden:
        case AppLifecycleState.paused:
          _restoreComposerFocusOnResume = _composerFocusNode.hasFocus;
          break;
        case AppLifecycleState.resumed:
          final shouldRestoreFocus = _restoreComposerFocusOnResume;
          _restoreComposerFocusOnResume = false;
          if (shouldRestoreFocus) {
            _queueComposerFocusRestore();
          }
          break;
        case AppLifecycleState.detached:
          _restoreComposerFocusOnResume = false;
          break;
      }
    }
    if (state == AppLifecycleState.resumed && mounted && !_disposed) {
      // OS can pause or silently kill the socket while backgrounded; the
      // normal onDone / onError path often doesn't fire until a write
      // actually fails. Force a reconnect + re-sync on resume so the user
      // sees fresh state immediately — prefer the cheap events delta over
      // a full snapshot whenever we have a known lastSeq.
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
      unawaited(() async {
        final applied = await _resyncDelta();
        if (!applied && mounted) {
          await _loadSnapshot(
            messageLimit: _messageLimit,
            activityLimit: _activityLimit,
            scrollToBottom: false,
          );
        }
      }());
      _connectLive();
    }
  }

  bool get _isMacDesktop =>
      widget.topPadding != null &&
      defaultTargetPlatform == TargetPlatform.macOS;

  void _queueComposerFocusRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 140), () {
        if (!mounted || _disposed) {
          return;
        }
        _composerFocusNode.requestFocus();
      });
    });
  }

  Future<void> _loadSnapshot({
    int? messageLimit,
    int? activityLimit,
    bool scrollToBottom = true,
  }) async {
    final resolvedMessageLimit = messageLimit ?? _messageLimit;
    final resolvedActivityLimit = activityLimit ?? _activityLimit;
    final requestId = ++_snapshotRequestId;
    _snapshotInFlight = true;
    try {
      final log = await widget.api.fetchLog(
        widget.host,
        widget.session.id,
        messageLimit: resolvedMessageLimit,
        activityLimit: resolvedActivityLimit,
      );
      if (!mounted || requestId != _snapshotRequestId) {
        return;
      }
      final pendingAction = log.pendingAction;
      final livePersisted = _hasPersistedLiveAssistant(log.messages);
      // Capture any live events delivered while the snapshot was in flight —
      // we'll replay them after the snapshot setState so they aren't clobbered.
      final bufferedEvents = List<LiveEvent>.from(_pendingLiveEvents);
      _pendingLiveEvents.clear();
      setState(() {
        _session = log.session;
        _messages = log.messages;
        _optimisticMessages = _reconcileOptimisticMessages(log.messages);
        _activities = _sortActivities(log.activities);
        _history = log.history;
        _messageLimit = resolvedMessageLimit;
        _activityLimit = resolvedActivityLimit;
        _historyBannerDismissed = false;
        // Prefer a live-delivered pendingAction over a stale snapshot "none".
        // The server only exposes the most-recent action, so if live says one
        // is open we trust it until action_resolved arrives.
        _pendingAction = pendingAction ?? _pendingAction;
        _running = log.session.isActive;
        _loading = false;
        if (!_running || livePersisted) {
          _clearLiveAssistantMessage();
        }
        _awaitingAssistantReply =
            log.session.isActive &&
            _liveAssistantText.isEmpty &&
            _pendingAction == null;
        // Seed lastSeq from the snapshot so subsequent resyncs can use the
        // cheap delta endpoint instead of re-downloading everything.
        var highestSeq = _lastEventSeq ?? 0;
        for (final m in log.messages) {
          if (m.seq > highestSeq) highestSeq = m.seq;
        }
        for (final a in log.activities) {
          if (a.seq > highestSeq) highestSeq = a.seq;
        }
        if (highestSeq > 0) {
          _lastEventSeq = highestSeq;
        }
      });
      _refreshThinkingState();
      _markCurrentSessionSeen();
      // Replay live events that landed during the fetch so action_opened /
      // activity_updated aren't silently dropped.
      for (final event in bufferedEvents) {
        _handleEvent(event);
      }
      if (scrollToBottom) {
        await _scrollToBottom();
      }
    } catch (error) {
      if (!mounted || requestId != _snapshotRequestId) {
        return;
      }
      setState(() {
        _loading = false;
      });
      showAppSnackBar(
        context,
        "Failed to load session: ${friendlyError(error)}",
      );
    } finally {
      _snapshotInFlight = false;
    }
  }

  /// Cheap catchup using the events endpoint. Returns true if the delta
  /// was applied; false if we should fall back to a full snapshot.
  Future<bool> _resyncDelta() async {
    final last = _lastEventSeq;
    if (last == null) return false;
    try {
      final delta = await widget.api.fetchEvents(
        widget.host,
        widget.session.id,
        since: last,
      );
      if (!mounted) return true;
      if (delta.messages.isEmpty &&
          delta.activities.isEmpty &&
          delta.pendingAction == null &&
          delta.session == null) {
        return true;
      }
      setState(() {
        var mergedMessages = _messages;
        var nextRunning = _running;
        if (delta.session != null) {
          _session = delta.session!;
          nextRunning = delta.session!.isActive;
        }
        if (delta.messages.isNotEmpty) {
          final byId = <String, SessionMessage>{
            for (final m in _messages) m.id: m,
          };
          for (final m in delta.messages) {
            byId[m.id] = m;
          }
          mergedMessages = byId.values.toList()
            ..sort((a, b) {
              if (a.seq != b.seq) return a.seq.compareTo(b.seq);
              return a.createdAt.compareTo(b.createdAt);
            });
        }
        if (delta.activities.isNotEmpty) {
          final byId = <String, SessionActivity>{
            for (final a in _activities) a.id: a,
          };
          for (final a in delta.activities) {
            byId[a.id] = a;
          }
          _activities = _sortActivities(byId.values.toList());
        }
        _messages = mergedMessages;
        _optimisticMessages = _reconcileOptimisticMessages(mergedMessages);
        _pendingAction = delta.pendingAction ?? _pendingAction;
        _running = nextRunning;
        if (!nextRunning || _hasPersistedLiveAssistant(mergedMessages)) {
          _clearLiveAssistantMessage();
        }
        _awaitingAssistantReply =
            nextRunning && _liveAssistantText.isEmpty && _pendingAction == null;
        if (delta.nextSeq > (_lastEventSeq ?? 0)) {
          _lastEventSeq = delta.nextSeq;
        }
      });
      _refreshThinkingState();
      _markCurrentSessionSeen();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadOlderTranscript() async {
    final history = _history;
    if (_loadingOlderHistory || history == null || !history.isTruncated) {
      return;
    }
    final nextMessageLimit = _nextHistoryLimit(
      current: _messageLimit,
      pageSize: _messagePageSize,
      total: history.totalMessages,
    );
    final nextActivityLimit = _nextHistoryLimit(
      current: _activityLimit,
      pageSize: _activityPageSize,
      total: history.totalActivities,
    );
    if (nextMessageLimit == _messageLimit &&
        nextActivityLimit == _activityLimit) {
      return;
    }

    setState(() => _loadingOlderHistory = true);
    try {
      await _loadSnapshot(
        messageLimit: nextMessageLimit,
        activityLimit: nextActivityLimit,
        scrollToBottom: false,
      );
    } finally {
      if (mounted) {
        setState(() => _loadingOlderHistory = false);
      }
    }
  }

  int _nextHistoryLimit({
    required int current,
    required int pageSize,
    required int total,
  }) {
    if (total <= current) {
      return current;
    }
    final expanded = current + pageSize;
    return expanded > total ? total : expanded;
  }

  void _connectLive() {
    if (_disposed) return;
    _subscription?.cancel();
    _channel?.sink.close();
    _subscription = null;
    _channel = null;
    try {
      final channel = widget.api.openLive(widget.host, widget.session.id);
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleRawEvent,
        onError: (_) => _scheduleReconnect(),
        onDone: () {
          if (!_disposed) _scheduleReconnect();
        },
        cancelOnError: false,
      );
      // Successful connect — reset the backoff counter. If the stream dies
      // immediately onDone will re-arm it.
      _reconnectAttempts = 0;
    } catch (_) {
      _channel = null;
      _scheduleReconnect();
    }
  }

  void _handleRawEvent(dynamic raw) {
    LiveEvent? event;
    try {
      final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
      event = LiveEvent.fromJson(decoded);
    } catch (_) {
      // Swallow malformed frames — don't tear down the stream for a single
      // bad line. Transport-level errors land in onError / onDone instead.
      return;
    }
    _handleEvent(event);
  }

  void _scheduleReconnect() {
    if (_disposed || !mounted) return;
    _reconnectTimer?.cancel();
    _reconnectAttempts = (_reconnectAttempts + 1).clamp(1, 6);
    // 0.5s, 1s, 2s, 4s, 8s, 15s
    final delayMs = switch (_reconnectAttempts) {
      1 => 500,
      2 => 1000,
      3 => 2000,
      4 => 4000,
      5 => 8000,
      _ => 15000,
    };
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted || _disposed) return;
      // Re-sync on every reconnect: the session may have advanced while we
      // were disconnected, and we have no replay mechanism.
      unawaited(
        _loadSnapshot(
          messageLimit: _messageLimit,
          activityLimit: _activityLimit,
          scrollToBottom: false,
        ),
      );
      _connectLive();
    });
  }

  void _handleEvent(LiveEvent event) {
    if (!mounted || event.sessionId != widget.session.id) {
      return;
    }

    // If a snapshot is in flight, queue non-hello events so the snapshot's
    // setState can't clobber them. They'll be replayed when the snapshot
    // completes.
    if (_snapshotInFlight && event.type != 'hello') {
      _pendingLiveEvents.add(event);
      return;
    }

    // Track server seq; if we detect a gap relative to what the server tells
    // us it has emitted, trigger a snapshot re-fetch to re-sync.
    if (event.type == 'hello') {
      final nextSeq = event.nextSeq;
      final last = _lastEventSeq;
      if (nextSeq != null && last != null && nextSeq > last + 1) {
        // We missed events while disconnected; try the cheap delta first,
        // fall back to a full snapshot if that fails.
        unawaited(() async {
          final applied = await _resyncDelta();
          if (!applied && mounted) {
            await _loadSnapshot(
              messageLimit: _messageLimit,
              activityLimit: _activityLimit,
              scrollToBottom: false,
            );
          }
        }());
      }
      return;
    }
    final seq = event.seq;
    if (seq != null) {
      final last = _lastEventSeq;
      if (last == null || seq > last) {
        _lastEventSeq = seq;
      }
    }

    switch (event.type) {
      case 'user_message_submitted':
        final message = event.messageItem;
        if (message == null) {
          return;
        }
        setState(() {
          _upsertOptimisticMessage(message);
          _running = true;
          _awaitingAssistantReply = true;
        });
        _refreshThinkingState();
        _scrollToBottomFast();
      case 'turn_started':
        setState(() {
          _running = true;
          _awaitingAssistantReply =
              _liveAssistantText.isEmpty && _pendingAction == null;
        });
        _refreshThinkingState();
      case 'assistant_delta':
        final delta = event.delta;
        if (delta == null || delta.isEmpty) {
          return;
        }
        _assistantDeltaBuffer.write(delta);
        _scheduleLiveFlush();
      case 'assistant_message_completed':
        _flushPendingLiveUpdates();
        final message = event.messageItem;
        final committedLive = _liveAssistantMessage;
        setState(() {
          if (message != null) {
            _upsertOptimisticMessage(message);
          } else if (committedLive != null && committedLive.text.isNotEmpty) {
            _upsertOptimisticMessage(committedLive.toMessage());
          }
          _clearLiveAssistantMessage();
          final phase = message?.phase ?? committedLive?.phase;
          _awaitingAssistantReply =
              phase == 'commentary' && _running && _pendingAction == null;
        });
        _refreshThinkingState();
        _scrollToBottomFast();
      case 'turn_completed':
        _flushPendingLiveUpdates();
        final committedLive = _liveAssistantMessage;
        setState(() {
          _running = false;
          _awaitingAssistantReply = false;
          if (committedLive != null && committedLive.text.isNotEmpty) {
            final finalMsg = SessionMessage(
              id: committedLive.id,
              role: 'assistant',
              text: committedLive.text,
              attachments: const <SessionMessageAttachment>[],
              createdAt: committedLive.createdAt,
              seq: committedLive.seq,
              phase: 'final_answer',
            );
            _upsertOptimisticMessage(finalMsg);
          }
          _clearLiveAssistantMessage();
        });
        _thinkingNotifier.value = false;
        // Background reconcile; do not block UI. Delayed enough for Codex to
        // finish flushing the rollout .jsonl file — otherwise the snapshot
        // reads a partial file and the new assistant message appears to
        // vanish until the user reloads.
        Future<void>.delayed(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          unawaited(
            _loadSnapshot(
              messageLimit: _messageLimit,
              activityLimit: _activityLimit,
              scrollToBottom: false,
            ),
          );
          unawaited(_loadGitStatus(silent: true));
        });
      case 'activity_updated':
        final activity = event.activity;
        if (activity == null) {
          return;
        }
        _pendingActivityUpdates[activity.id] = activity;
        _scheduleLiveFlush();
      case 'action_opened':
        setState(() {
          _pendingAction = event.action;
          _awaitingAssistantReply = false;
        });
        _refreshThinkingState();
      case 'action_resolved':
        setState(() {
          _pendingAction = null;
          _awaitingAssistantReply = _running && _liveAssistantText.isEmpty;
        });
        _refreshThinkingState();
      case 'hello':
      case 'error':
        break;
    }
  }

  bool _shouldShowThinking() {
    return _running &&
        _awaitingAssistantReply &&
        _liveAssistantText.isEmpty &&
        _pendingAction == null;
  }

  void _refreshThinkingState() {
    _thinkingNotifier.value = _shouldShowThinking();
  }

  void _scheduleLiveFlush() {
    if (_liveFlushTimer != null) {
      return;
    }
    _liveFlushTimer = Timer(_liveUpdateFlushInterval, _flushPendingLiveUpdates);
  }

  void _flushPendingLiveUpdates() {
    _liveFlushTimer?.cancel();
    _liveFlushTimer = null;
    if (!mounted) {
      _assistantDeltaBuffer.clear();
      _pendingActivityUpdates.clear();
      return;
    }

    final hasDelta = _assistantDeltaBuffer.isNotEmpty;
    final delta = hasDelta ? _assistantDeltaBuffer.toString() : '';
    _assistantDeltaBuffer.clear();

    final activities = _pendingActivityUpdates.values.toList();
    _pendingActivityUpdates.clear();

    if (!hasDelta && activities.isEmpty) {
      return;
    }

    final currentLive = _liveAssistantMessage;
    final updatedLive = hasDelta
        ? _appendLiveAssistantDelta(currentLive, delta)
        : currentLive;
    final needsLiveInsert = hasDelta && currentLive == null;

    if (hasDelta) {
      if (needsLiveInsert || activities.isNotEmpty) {
        setState(() {
          _running = true;
          _awaitingAssistantReply = false;
          _liveAssistantNotifier.value = updatedLive;
          for (final activity in activities) {
            _upsertActivity(activity);
          }
        });
      } else {
        _running = true;
        _awaitingAssistantReply = false;
        _liveAssistantNotifier.value = updatedLive;
        if (_searchQuery.trim().isNotEmpty) {
          setState(() {});
        }
      }
      _thinkingNotifier.value = false;
    } else if (activities.isNotEmpty) {
      setState(() {
        for (final activity in activities) {
          _upsertActivity(activity);
        }
      });
    }
    _scrollToBottomFast();
  }

  Future<void> _pickComposerImages() async {
    if (_sending) {
      return;
    }

    try {
      final picked = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const <String>[
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
          'bmp',
          'heic',
          'heif',
        ],
      );
      if (!mounted || picked == null || picked.files.isEmpty) {
        return;
      }
      await _addPickedDraftAttachments(picked.files);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Failed to attach images: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _addPickedDraftAttachments(List<PlatformFile> files) async {
    final nextAttachments = List<_ComposerImageAttachment>.from(
      _draftAttachments,
    );
    var totalBytes = nextAttachments.fold<int>(
      0,
      (sum, item) => sum + item.byteLength,
    );

    for (final file in files) {
      if (nextAttachments.length >= _maxDraftImageCount) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          'You can attach up to $_maxDraftImageCount images per message.',
        );
        break;
      }

      final bytes = await _readPickedFileBytes(file);
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          'Could not read ${file.name.isEmpty ? 'that image' : file.name}.',
        );
        continue;
      }
      if (bytes.length > _maxDecodedDraftImageBytes) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          '${file.name.isEmpty ? 'That image' : file.name} is too large to process on-device.',
        );
        continue;
      }

      final mimeType = _mimeTypeForImageName(file.name);
      if (mimeType == null) {
        if (!mounted) return;
        showAppSnackBar(
          context,
          '${file.name.isEmpty ? 'That file' : file.name} is not a supported image.',
        );
        continue;
      }

      final prepared = await _prepareDraftImageAttachment(
        name: file.name.isEmpty ? 'image' : file.name,
        mimeType: mimeType,
        bytes: bytes,
      );
      if (!mounted) {
        return;
      }
      if (prepared.bytes.length > _maxDraftImageBytes) {
        showAppSnackBar(
          context,
          '${prepared.name} is still larger than 5 MB after compression.',
        );
        continue;
      }
      if (totalBytes + prepared.bytes.length > _maxDraftPayloadBytes) {
        showAppSnackBar(
          context,
          'Attached images are too large for one message. Remove one or pick a smaller file.',
        );
        break;
      }

      final dataUrl =
          'data:${prepared.mimeType};base64,${base64Encode(prepared.bytes)}';
      nextAttachments.add(
        _ComposerImageAttachment(
          id: 'draft-${DateTime.now().microsecondsSinceEpoch}-${nextAttachments.length}',
          name: prepared.name,
          mimeType: prepared.mimeType,
          bytes: prepared.bytes,
          dataUrl: dataUrl,
        ),
      );
      totalBytes += prepared.bytes.length;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _draftAttachments = nextAttachments;
    });
  }

  Future<Uint8List?> _readPickedFileBytes(PlatformFile file) async {
    if (file.bytes != null) {
      return file.bytes;
    }
    return file.xFile.readAsBytes();
  }

  Future<_PreparedDraftImage> _prepareDraftImageAttachment({
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    final payload = await compute(_compressDraftImagePayload, <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    });

    return _PreparedDraftImage(
      name: payload['name'] as String,
      mimeType: payload['mimeType'] as String,
      bytes: payload['bytes'] as Uint8List,
    );
  }

  void _removeDraftAttachment(String attachmentId) {
    setState(() {
      _draftAttachments = _draftAttachments
          .where((item) => item.id != attachmentId)
          .toList();
    });
  }

  String? _mimeTypeForImageName(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    if (lower.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lower.endsWith('.heif')) {
      return 'image/heif';
    }
    return null;
  }

  List<SessionInputItem> _buildComposerInputItems(
    String text,
    List<_ComposerImageAttachment> attachments,
    List<_ComposerSkillMention> skills,
  ) {
    return <SessionInputItem>[
      ...attachments.map((item) => SessionInputItem.image(item.dataUrl)),
      ...skills.map(
        (item) => SessionInputItem.skill(item.skill.name, item.skill.path),
      ),
      if (text.isNotEmpty) SessionInputItem.text(text),
    ];
  }

  List<SessionMessageAttachment> _buildDraftMessageAttachments(
    List<_ComposerImageAttachment> attachments,
  ) {
    return attachments
        .map(
          (item) => SessionMessageAttachment(type: 'image', url: item.dataUrl),
        )
        .toList(growable: false);
  }

  void _insertSkillMention(SkillSummary skill) {
    final active =
        _activeSkillQuery ??
        _extractActiveSkillQuery(_composerController.value);
    if (active == null) {
      return;
    }

    final tokenText = skill.mentionToken;
    final value = _composerController.value;
    final text = value.text;
    final replaced = text.replaceRange(active.start, active.end, '$tokenText ');
    final cursorOffset = active.start + tokenText.length + 1;
    _composerController.value = value.copyWith(
      text: replaced,
      selection: TextSelection.collapsed(offset: cursorOffset),
      composing: TextRange.empty,
    );

    final nextMentions = List<_ComposerSkillMention>.from(_draftSkillMentions);
    if (!nextMentions.any((item) => item.skill.path == skill.path)) {
      nextMentions.add(
        _ComposerSkillMention(skill: skill, tokenText: tokenText),
      );
    }

    HapticFeedback.selectionClick();
    if (!mounted) {
      _draftSkillMentions = nextMentions;
      _activeSkillQuery = null;
      return;
    }
    setState(() {
      _draftSkillMentions = nextMentions;
      _activeSkillQuery = null;
    });
  }

  void _removeDraftSkillMention(String skillPath) {
    _ComposerSkillMention? mention;
    for (final item in _draftSkillMentions) {
      if (item.skill.path == skillPath) {
        mention = item;
        break;
      }
    }
    if (mention == null) {
      return;
    }

    final nextText = _removeSkillTokenFromText(
      _composerController.text,
      mention.tokenText,
    );
    _composerController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    setState(() {
      _draftSkillMentions = _draftSkillMentions
          .where((item) => item.skill.path != skillPath)
          .toList(growable: false);
    });
  }

  String _removeSkillTokenFromText(String text, String tokenText) {
    final escaped = RegExp.escape(tokenText);
    var next = text.replaceAllMapped(
      RegExp('(^|\\s)$escaped(?=\\s|\$)'),
      (match) => match.group(1) ?? '',
    );
    next = next.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
    next = next.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return next.trim();
  }

  Future<void> _sendInput() async {
    final text = _composerController.text.trim();
    final draftAttachments = List<_ComposerImageAttachment>.from(
      _draftAttachments,
    );
    final draftSkillMentions = List<_ComposerSkillMention>.from(
      _draftSkillMentions.where((item) => text.contains(item.tokenText)),
    );
    if ((text.isEmpty && draftAttachments.isEmpty) || _sending) {
      return;
    }

    final wasRunning = _running;
    final inputItems = _buildComposerInputItems(
      text,
      draftAttachments,
      draftSkillMentions,
    );
    final optimisticMessage = SessionMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: 'user',
      text: text,
      attachments: _buildDraftMessageAttachments(draftAttachments),
      createdAt: DateTime.now(),
      seq: _nextTimelineSeq(),
    );

    _composerController.clear();
    setState(() {
      _sending = true;
      _running = true;
      _awaitingAssistantReply = true;
      _draftAttachments = const <_ComposerImageAttachment>[];
      _draftSkillMentions = const <_ComposerSkillMention>[];
      _clearLiveAssistantMessage();
      _upsertOptimisticMessage(optimisticMessage);
    });
    _refreshThinkingState();
    _scrollToBottomFast(force: true);
    try {
      final policy = _policyStore.policyFor(widget.host, widget.session.id);
      final turnConfig = _turnConfigStore.configFor(
        widget.host,
        widget.session.id,
      );
      await widget.api.sendInput(
        widget.host,
        sessionId: widget.session.id,
        text: text,
        input: inputItems,
        clientMessageId: optimisticMessage.id,
        model: turnConfig.model,
        reasoningEffort: turnConfig.reasoningEffort,
        fastMode: turnConfig.fastMode,
        approvalPolicy: policy.approval?.wire,
        sandboxMode: policy.sandbox?.wire,
        networkAccess: policy.networkAccess,
      );
      if (!mounted) {
        return;
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      _composerController.text = text;
      _composerController.selection = TextSelection.collapsed(
        offset: _composerController.text.length,
      );
      final stillHasPending = _pendingAction != null;
      final restoredAttachments = List<_ComposerImageAttachment>.from(
        draftAttachments,
      );
      final restoredSkillMentions = List<_ComposerSkillMention>.from(
        draftSkillMentions,
      );
      showAppSnackBar(context, "Failed to send: ${friendlyError(error)}");
      setState(() {
        _optimisticMessages = _optimisticMessages
            .where((message) => message.id != optimisticMessage.id)
            .toList();
        _draftAttachments = restoredAttachments;
        _draftSkillMentions = restoredSkillMentions;
        _running = wasRunning;
        _awaitingAssistantReply =
            wasRunning && _liveAssistantText.isEmpty && !stillHasPending;
      });
      _refreshThinkingState();
      if (_isMacDesktop) {
        _queueComposerFocusRestore();
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  Future<void> _stopSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop session?'),
        content: const Text(
          'The running task will be interrupted. In-flight tool calls may not complete cleanly.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep running'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.danger,
              foregroundColor: context.colors.accentOn,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    try {
      await widget.api.stopSession(widget.host, widget.session.id);
      if (!mounted) {
        return;
      }
      HapticFeedback.mediumImpact();
      setState(() {
        _running = false;
        _awaitingAssistantReply = false;
        _clearLiveAssistantMessage();
      });
      _refreshThinkingState();
      showAppSnackBar(
        context,
        'Session stopped.',
        duration: const Duration(seconds: 2),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        "Failed to stop session: ${friendlyError(error)}",
      );
    }
  }

  Future<void> _renameSession() async {
    final current = (_session ?? widget.session).title;
    final controller = TextEditingController(text: current);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Session name'),
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = newName?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == current) {
      return;
    }
    try {
      final updated = await widget.api.renameSession(
        widget.host,
        sessionId: widget.session.id,
        name: trimmed,
      );
      if (!mounted) {
        return;
      }
      setState(() => _session = updated);
      SessionOverridesStore.instance.apply(widget.host.id, updated);
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, "Failed to rename: ${friendlyError(error)}");
    }
  }

  Future<void> _archiveSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive session?'),
        content: const Text(
          'Archived sessions are hidden from Recent. You can unarchive them from the host.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.api.archiveSession(widget.host, widget.session.id);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, "Failed to archive: ${friendlyError(error)}");
    }
  }

  Future<void> _toggleFavorite() async {
    await _favorites.toggleFavorite(widget.host, widget.session.id);
  }

  Future<void> _toggleMessagePin(SessionMessage message) async {
    if (!message.hasVisibleContent) {
      return;
    }
    final pinned = await _pinsStore.togglePin(
      widget.host,
      widget.session.id,
      message,
    );
    if (!mounted) return;
    HapticFeedback.selectionClick();
    showAppSnackBar(
      context,
      pinned ? 'Pinned message' : 'Unpinned message',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _unpinMessage(PinnedSessionMessage pin) async {
    await _pinsStore.unpin(widget.host, widget.session.id, pin.messageId);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    showAppSnackBar(
      context,
      'Unpinned message',
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _showPinnedMessage(PinnedSessionMessage pin) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => _PinnedMessageSheet(
        pin: pin,
        onUnpin: () {
          Navigator.of(sheetContext).pop();
          unawaited(_unpinMessage(pin));
        },
        onOpenFile: _openWorkspaceFile,
      ),
    );
  }

  Future<void> _respondAction(String decision) async {
    final action = _pendingAction;
    if (action == null) {
      return;
    }
    try {
      await widget.api.respondToAction(
        widget.host,
        actionId: action.id,
        decision: decision,
      );
      if (!mounted) {
        return;
      }
      HapticFeedback.selectionClick();
      setState(() {
        _pendingAction = null;
      });
      final label = switch (decision) {
        'approved' => 'Approved this step',
        'approvedForSession' => 'Approved for the rest of the session',
        'denied' => 'Declined',
        _ => 'Decision sent',
      };
      showAppSnackBar(context, label, duration: const Duration(seconds: 2));
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        "Failed to resolve action: ${friendlyError(error)}",
      );
    }
  }

  Future<void> _showGitSheet(
    SessionSummary session, {
    bool forceRefresh = false,
  }) async {
    if (forceRefresh || _gitStatus == null) {
      await _loadGitStatus();
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => _GitDetailsSheet(
        session: session,
        status: _gitStatus,
        loading: _gitStatusLoading,
        error: _gitStatusError,
        onRefresh: () {
          Navigator.of(sheetContext).pop();
          unawaited(_showGitSheet(session, forceRefresh: true));
        },
        onShowDiff: (kind) {
          Navigator.of(sheetContext).pop();
          unawaited(_showGitDiffSheet(kind));
        },
      ),
    );
  }

  Future<void> _showGitDiffSheet(String kind) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _GitDiffSheet(
        future: widget.api.fetchGitDiff(
          widget.host,
          widget.session.id,
          kind: kind,
        ),
      ),
    );
  }

  Future<void> _showSessionDetailsSheet(SessionSummary session) async {
    final colors = context.colors;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Session details',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              _DetailRow(label: 'Host', value: widget.host.label),
              _DetailRow(label: 'Working dir', value: session.cwd),
              _DetailRow(label: 'Status', value: _running ? 'Running' : 'Idle'),
              _DetailRow(label: 'Source', value: session.source),
              if (_gitHeaderLabel(session, _gitStatus) != null) ...[
                _DetailRow(
                  label: 'Git',
                  value: _gitHeaderLabel(session, _gitStatus)!,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      unawaited(_showGitSheet(session));
                    },
                    icon: const Icon(Icons.account_tree_outlined, size: 18),
                    label: const Text('Open Git details'),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              if (session.runtime != null) ...[
                const SizedBox(height: 14),
                _SessionRuntimeDetails(runtime: session.runtime!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSessionPolicySheet(SessionSummary session) async {
    await _policyStore.ensureLoaded();
    await _turnConfigStore.ensureLoaded();
    if (!mounted) return;
    final runtime = session.runtime;
    final isDesktop = widget.topPadding != null;
    final sheet = SessionControlsSheet(
      api: widget.api,
      host: widget.host,
      session: session,
      runtimeModel: runtime?.model,
      runtimeServiceTier: runtime?.serviceTier,
      runtimeReasoningEffort: runtime?.reasoningEffort,
      runtimeApproval: ApprovalPolicy.fromWire(runtime?.approvalPolicy),
      runtimeSandbox: SandboxMode.fromWire(runtime?.sandboxMode),
      runtimeNetworkAccess: runtime?.networkAccess,
      policyStore: _policyStore,
      turnConfigStore: _turnConfigStore,
    );
    if (isDesktop) {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (dialogContext) => Dialog(
          backgroundColor: context.colors.surface,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 48,
            vertical: 48,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
            child: sheet,
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => sheet,
    );
  }

  void _dismissKeyboard() {
    _restoreComposerFocusOnResume = false;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _openWorkspaceFile(String path) {
    final isDesktop = widget.topPadding != null;
    if (isDesktop) {
      showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.4),
        builder: (dialogContext) {
          final colors = context.colors;
          final mediaSize = MediaQuery.of(dialogContext).size;
          final maxWidth = (mediaSize.width * 0.8)
              .clamp(640.0, 1100.0)
              .toDouble();
          final maxHeight = (mediaSize.height * 0.85)
              .clamp(480.0, 860.0)
              .toDouble();
          return Dialog(
            backgroundColor: colors.surface,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 40,
              vertical: 40,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: maxHeight,
              ),
              child: _InlineFileViewer(
                host: widget.host,
                api: widget.api,
                path: path,
              ),
            ),
          );
        },
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FileViewerScreen(host: widget.host, api: widget.api, path: path),
      ),
    );
  }

  bool _hasPersistedLiveAssistant(Iterable<SessionMessage> messages) {
    final liveAssistant = _liveAssistantMessage;
    if (liveAssistant == null) {
      return false;
    }
    return messages.any(
      (message) => _matchesPersistedMessage(message, liveAssistant.toMessage()),
    );
  }

  _LiveAssistantMessageState _appendLiveAssistantDelta(
    _LiveAssistantMessageState? current,
    String delta,
  ) {
    if (current == null) {
      return _LiveAssistantMessageState(
        id: 'local-stream-${DateTime.now().microsecondsSinceEpoch}',
        text: delta,
        createdAt: DateTime.now(),
        seq: _nextTimelineSeq(),
        phase: 'commentary',
      );
    }
    return current.copyWith(text: '${current.text}$delta');
  }

  int _nextTimelineSeq() {
    var maxSeq = 0;
    for (final m in _messages) {
      if (m.seq > maxSeq) maxSeq = m.seq;
    }
    for (final m in _optimisticMessages) {
      if (m.seq > maxSeq) maxSeq = m.seq;
    }
    for (final a in _activities) {
      if (a.seq > maxSeq) maxSeq = a.seq;
    }
    final liveAssistant = _liveAssistantMessage;
    if (liveAssistant != null && liveAssistant.seq > maxSeq) {
      maxSeq = liveAssistant.seq;
    }
    return maxSeq + 1;
  }

  // With reverse:true, the bottom of the chat is offset 0 — instant & always
  // correct, no frame-wait dance needed. Only snaps if user is already near
  // the bottom so we don't steal their scroll position while they're reading.
  void _scrollToBottomFast({bool force = false}) {
    if (!_scrollController.hasClients) return;
    if (_scrollController.offset <= 0.5) return;
    if (!force && _scrollController.offset > 160) return;
    _scrollController.jumpTo(0);
  }

  Future<void> _scrollToBottom() async {
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scrollController.hasClients) return;
    if (_scrollController.offset > 0.5) {
      _scrollController.jumpTo(0);
    }
  }

  void _upsertOptimisticMessage(SessionMessage message) {
    final existingIndex = _optimisticMessages.indexWhere(
      (item) => item.id == message.id,
    );
    if (existingIndex == -1) {
      _optimisticMessages = [..._optimisticMessages, message];
      return;
    }
    final updated = [..._optimisticMessages];
    updated[existingIndex] = message;
    _optimisticMessages = updated;
  }

  List<SessionMessage> _reconcileOptimisticMessages(
    List<SessionMessage> persistedMessages,
  ) {
    return _optimisticMessages.where((optimistic) {
      return !persistedMessages.any(
        (persisted) => _matchesPersistedMessage(persisted, optimistic),
      );
    }).toList();
  }

  void _upsertActivity(SessionActivity activity) {
    final existingIndex = _activities.indexWhere(
      (item) => item.id == activity.id,
    );
    if (existingIndex == -1) {
      _activities = _sortActivities([..._activities, activity]);
      return;
    }
    final updated = [..._activities];
    updated[existingIndex] = activity;
    _activities = _sortActivities(updated);
  }

  List<SessionActivity> _sortActivities(List<SessionActivity> activities) {
    final sorted = [...activities];
    sorted.sort((left, right) {
      final bySeq = left.seq.compareTo(right.seq);
      if (bySeq != 0) return bySeq;
      return left.createdAt.compareTo(right.createdAt);
    });
    return sorted;
  }

  List<_TimelineEntry> _buildTimelineEntries() {
    final liveAssistant = _liveAssistantMessage;
    // Memoize: if message/activity/optimistic list identities are unchanged,
    // reuse the previous entries (skip the sort).
    if (identical(_entriesMessagesRef, _messages) &&
        identical(_entriesOptimisticRef, _optimisticMessages) &&
        identical(_entriesActivitiesRef, _activities) &&
        _entriesLiveAssistantId == liveAssistant?.id) {
      return _cachedEntries;
    }

    final entries =
        <_TimelineEntry>[
          ..._messages.map(_TimelineEntry.message),
          ..._optimisticMessages.map(_TimelineEntry.message),
          ..._activities.map(_TimelineEntry.activity),
          if (liveAssistant != null)
            _TimelineEntry.liveAssistant(liveAssistant),
        ]..sort((left, right) {
          final bySeq = left.seq.compareTo(right.seq);
          if (bySeq != 0) return bySeq;
          return left.createdAt.compareTo(right.createdAt);
        });

    _entriesMessagesRef = _messages;
    _entriesOptimisticRef = _optimisticMessages;
    _entriesActivitiesRef = _activities;
    _entriesLiveAssistantId = liveAssistant?.id;
    _cachedEntries = entries;
    // Notify pane-3 surfaces (search) that records should be rebuilt.
    // Scheduled post-frame so we don't call notifyListeners during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      _timelineRevision.value++;
    });
    return entries;
  }

  List<SearchRecord> _buildSearchRecords() {
    final entries = _buildTimelineEntries();
    final records = <SearchRecord>[];
    final session = _session ?? widget.session;
    for (final entry in entries) {
      if (entry.kind == _TimelineEntryKind.liveAssistant) continue;
      if (entry.kind == _TimelineEntryKind.message) {
        final message = entry.message!;
        records.add(
          SearchRecord(
            id: entry.keyId,
            kind: SearchRecordKind.message,
            createdAt: entry.createdAt,
            haystack: _messageSearchHaystack(message),
            title: _messageSearchTitle(message),
            message: message,
          ),
        );
      } else if (entry.kind == _TimelineEntryKind.activity) {
        final activity = entry.activity!;
        records.add(
          SearchRecord(
            id: entry.keyId,
            kind: SearchRecordKind.activity,
            createdAt: entry.createdAt,
            haystack: _activitySearchHaystack(activity),
            title: _activitySearchTitle(activity),
            activity: activity,
            sessionCwd: session.cwd,
          ),
        );
      }
    }
    return records;
  }

  String _messageSearchHaystack(SessionMessage message) {
    return [
      message.role,
      message.phase ?? '',
      message.text,
      for (final attachment in message.attachments) ...[
        attachment.type,
        attachment.url ?? '',
        attachment.path ?? '',
      ],
    ].join('\n').toLowerCase();
  }

  String _messageSearchTitle(SessionMessage message) {
    final role = message.role == 'user' ? 'You' : 'Assistant';
    final phase = (message.phase ?? '').trim();
    if (phase.isEmpty || phase == 'answer') return role;
    return '$role · ${phase.toUpperCase()}';
  }

  String _activitySearchHaystack(SessionActivity activity) {
    final output = activity.output ?? '';
    final tail = output.length > 800
        ? output.substring(output.length - 800)
        : output;
    final changesText = activity.changes
        .expand((c) => [c.path, c.movePath ?? ''])
        .join('\n');
    return [
      activity.type,
      activity.status,
      activity.command ?? '',
      activity.cwd ?? '',
      activity.query ?? '',
      activity.queries.join(' '),
      activity.targetUrl ?? '',
      activity.pattern ?? '',
      activity.savedPath ?? '',
      activity.terminalInput ?? '',
      changesText,
      tail,
    ].join('\n').toLowerCase();
  }

  String _activitySearchTitle(SessionActivity activity) {
    switch (activity.type) {
      case 'command':
        final cmd = (activity.command ?? '').trim();
        return cmd.isEmpty ? 'Command' : cmd;
      case 'file_change':
        if (activity.changes.length == 1) {
          return activity.changes.first.path;
        }
        return 'Edited ${activity.changes.length} files';
      case 'turn_diff':
        return 'Turn diff';
      case 'web_search':
        final q = (activity.query ?? '').trim();
        return q.isEmpty ? 'Web search' : 'Web: $q';
      case 'image_generation':
        return 'Generated image';
      default:
        return activity.type;
    }
  }

  bool _matchesPersistedMessage(
    SessionMessage persisted,
    SessionMessage optimistic,
  ) {
    return persisted.role == optimistic.role &&
        persisted.text.trim() == optimistic.text.trim() &&
        _sameMessageAttachments(
          persisted.attachments,
          optimistic.attachments,
        ) &&
        (persisted.createdAt.difference(optimistic.createdAt).inSeconds)
                .abs() <=
            90;
  }

  bool _sameMessageAttachments(
    List<SessionMessageAttachment> left,
    List<SessionMessageAttachment> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftItem = left[index];
      final rightItem = right[index];
      if (leftItem.type != rightItem.type ||
          leftItem.url != rightItem.url ||
          leftItem.path != rightItem.path) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final session = _session ?? widget.session;
    final colors = context.colors;
    final timelineEntries = _buildTimelineEntries();
    final visibleTimelineEntries = timelineEntries;
    final pinnedMessages = _pinsStore.pinsFor(widget.host, session.id);
    final isCompact = MediaQuery.of(context).size.width < 600;
    final pinnedActive = _isPinnedInspectorOpen(
      InspectorScope.maybeOf(context),
    );
    final showHistoryBanner =
        (_history?.isTruncated ?? false) && !_historyBannerDismissed;
    final bodyContent = Column(
      children: [
        if (!isCompact)
          ListenableBuilder(
            listenable: _favorites,
            builder: (context, _) {
              final favorite = _favorites.isFavorite(
                widget.host,
                session.id,
              );
              return _SessionHeader(
                host: widget.host,
                session: session,
                gitStatus: _gitStatus,
                running: _running,
                favorite: favorite,
                pinnedCount: pinnedMessages.length,
                pinnedActive: pinnedActive,
                onPinnedTap: _openPinnedPanel,
                onDetails: () => _showSessionDetailsSheet(session),
                onGitDetails: () => _showGitSheet(session),
              );
            },
          ),
        if (_pendingAction != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: _PendingActionCard(
              action: _pendingAction!,
              onRespond: _respondAction,
            ),
          ),
        Expanded(
          child: (_loading && timelineEntries.isEmpty)
              ? const MeshLoader()
              : Stack(
                  children: [
                    RefreshIndicator(
                      onRefresh: () => _loadSnapshot(scrollToBottom: false),
                      edgeOffset: 0,
                      displacement: 28,
                      child: SelectionArea(
                        child: ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount:
                              visibleTimelineEntries.length +
                              (showHistoryBanner ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (showHistoryBanner &&
                                index == visibleTimelineEntries.length) {
                              return Padding(
                                padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
                                child: _HistoryTruncationCard(
                                  history: _history!,
                                  loading: _loadingOlderHistory,
                                  onLoadOlderHistory: _loadOlderTranscript,
                                  onDismiss: () => setState(
                                    () => _historyBannerDismissed = true,
                                  ),
                                ),
                              );
                            }
                            final chronoIndex =
                                visibleTimelineEntries.length - index - 1;
                            final entry = visibleTimelineEntries[chronoIndex];
                            final prev = chronoIndex > 0
                                ? visibleTimelineEntries[chronoIndex - 1]
                                : null;
                            final showDay = prev == null ||
                                !_sameCalendarDay(
                                  prev.createdAt,
                                  entry.createdAt,
                                );
                            final child = KeyedSubtree(
                              key: ValueKey(entry.keyId),
                              child: switch (entry.kind) {
                                _TimelineEntryKind.message => _MessageBubble(
                                  host: widget.host,
                                  api: widget.api,
                                  message: entry.message!,
                                  pinned: _pinsStore.isPinned(
                                    widget.host,
                                    session.id,
                                    entry.message!.id,
                                  ),
                                  onTogglePin: () =>
                                      _toggleMessagePin(entry.message!),
                                  onOpenFile: _openWorkspaceFile,
                                ),
                                _TimelineEntryKind.activity => _ActivityCard(
                                  host: widget.host,
                                  api: widget.api,
                                  activity: entry.activity!,
                                  sessionCwd: session.cwd,
                                  defaultCollapsed:
                                      entry.activity!.type !=
                                      'image_generation',
                                  onOpenFile: _openWorkspaceFile,
                                ),
                                _TimelineEntryKind.liveAssistant =>
                                  _LiveAssistantBubble(
                                    host: widget.host,
                                    api: widget.api,
                                    message: _liveAssistantNotifier,
                                    onOpenFile: _openWorkspaceFile,
                                  ),
                              },
                            );
                            if (!showDay) return child;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _DaySeparator(
                                  label: _formatDaySeparator(entry.createdAt),
                                ),
                                child,
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    Positioned(
                        right: 16,
                        bottom: 12,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _showJumpToLatest,
                          builder: (context, show, _) {
                            return IgnorePointer(
                              ignoring: !show,
                              child: AnimatedOpacity(
                                opacity: show ? 1 : 0,
                                duration: const Duration(milliseconds: 160),
                                curve: Curves.easeOut,
                                child: _JumpToLatestPill(
                                  onTap: () {
                                    if (!_scrollController.hasClients) {
                                      return;
                                    }
                                    _scrollController.animateTo(
                                      0,
                                      duration: const Duration(
                                        milliseconds: 240,
                                      ),
                                      curve: Curves.easeOut,
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
        ),
        _ComposerStatusStrip(thinking: _thinkingNotifier),
        _Composer(
          controller: _composerController,
          focusNode: _composerFocusNode,
          attachments: _draftAttachments,
          skills: _draftSkillMentions,
          activeSkillQuery: _activeSkillQuery?.query,
          skillSuggestions: _skillSuggestions,
          loadingSkills: _loadingSkills,
          skillError: _skillsError,
          sending: _sending,
          onPickImages: _pickComposerImages,
          onRemoveAttachment: _removeDraftAttachment,
          onSelectSkill: _insertSkillMention,
          onRemoveSkill: _removeDraftSkillMention,
          onSend: _sendInput,
          onDismiss: _dismissKeyboard,
          submitOnEnter: widget.topPadding != null,
        ),
      ],
    );
    final layoutBody = bodyContent;
    final inspectorScope = InspectorScope.maybeOf(context);
    final searchOpenInInspector =
        inspectorScope != null && _isSearchInspectorOpen(inspectorScope);
    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        toolbarHeight: isCompact ? 52 : null,
        bottom: isCompact
            ? PreferredSize(
                preferredSize: const Size.fromHeight(30),
                child: _SessionAppBarSubtitle(
                  host: widget.host,
                  session: session,
                  gitStatus: _gitStatus,
                  running: _running,
                  pinnedCount: pinnedMessages.length,
                  pinnedActive: pinnedActive,
                  onPinnedTap: _openPinnedPanel,
                  onDetails: () => _showSessionDetailsSheet(session),
                  onGitDetails: () => _showGitSheet(session),
                ),
              )
            : null,
        title: Row(
          children: [
            if (_running) ...[const LivePulse(), const SizedBox(width: 10)],
            Expanded(
              child: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (_running)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: TextButton.icon(
                onPressed: _stopSession,
                icon: Icon(Icons.stop_circle_outlined, color: colors.danger),
                label: Text('Stop', style: TextStyle(color: colors.danger)),
              ),
            ),
          if (_gitHeaderLabel(session, _gitStatus) != null &&
              (_gitStatus?.dirty ?? false))
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: MeshIconButton(
                icon: Icons.account_tree_outlined,
                tooltip: 'Git details',
                color: colors.warning,
                onTap: () => _showGitSheet(session),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: MeshIconButton(
              icon: searchOpenInInspector
                  ? Icons.search_off_rounded
                  : Icons.search_rounded,
              tooltip: searchOpenInInspector ? 'Close search' : 'Search',
              color: searchOpenInInspector
                  ? colors.accent
                  : colors.textSecondary,
              onTap: _toggleSearchPanel,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ListenableBuilder(
              listenable: Listenable.merge([_policyStore, _turnConfigStore]),
              builder: (context, _) {
                final policy = _policyStore.policyFor(widget.host, session.id);
                final turnConfig = _turnConfigStore.configFor(
                  widget.host,
                  session.id,
                );
                final runtime = session.runtime;
                final runtimeLoosened = SessionPolicy.runtimeIsLoosened(
                  approvalPolicy: runtime?.approvalPolicy,
                  sandboxMode: runtime?.sandboxMode,
                  networkAccess: runtime?.networkAccess,
                );
                final customised =
                    !policy.isEmpty || !turnConfig.isEmpty || runtimeLoosened;
                return MeshIconButton(
                  icon: customised ? Icons.tune_rounded : Icons.tune_outlined,
                  tooltip: 'Session controls',
                  color: customised ? colors.accent : colors.textSecondary,
                  onTap: () => _showSessionPolicySheet(session),
                );
              },
            ),
          ),
          ListenableBuilder(
            listenable: _favorites,
            builder: (context, _) {
              final favorite = _favorites.isFavorite(widget.host, session.id);
              final gitAvailable =
                  _gitHeaderLabel(session, _gitStatus) != null;
              final gitDirty = _gitStatus?.dirty ?? false;
              // Hide the 'Git details' menu item when it's already a visible
              // icon (dirty state). Keep it hidden entirely if there is no
              // git info to show.
              final showGitInMenu = gitAvailable && !gitDirty;
              return PopupMenuButton<String>(
                tooltip: 'Session actions',
                icon: Icon(
                  Icons.more_vert_rounded,
                  color: colors.textPrimary,
                ),
                onSelected: (value) {
                  switch (value) {
                    case 'search':
                      _toggleSearchPanel();
                      break;
                    case 'favorite':
                      _toggleFavorite();
                      break;
                    case 'git':
                      _showGitSheet(session);
                      break;
                    case 'browse':
                      final isDesktop = widget.topPadding != null;
                      final scope = InspectorScope.maybeOf(context);
                      if (isDesktop && scope != null) {
                        scope.show(
                          buildInspectorWorkspaceBrowserSurface(
                            ownerKey: _inspectorOwnerKey(),
                            host: widget.host,
                            api: widget.api,
                            root: session.cwd,
                          ),
                        );
                      } else if (isDesktop) {
                        showWorkspaceBrowserDialog(
                          context,
                          host: widget.host,
                          api: widget.api,
                          root: session.cwd,
                        );
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => FileBrowserScreen(
                              host: widget.host,
                              api: widget.api,
                              root: session.cwd,
                            ),
                          ),
                        );
                      }
                      break;
                    case 'reload':
                      _loadSnapshot();
                      break;
                    case 'rename':
                      _renameSession();
                      break;
                    case 'archive':
                      _archiveSession();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem<String>(
                    value: 'favorite',
                    child: Row(
                      children: [
                        Icon(
                          favorite
                              ? Icons.star_rounded
                              : Icons.star_outline_rounded,
                          size: 18,
                          color: favorite ? colors.warning : null,
                        ),
                        const SizedBox(width: 10),
                        Text(favorite ? 'Remove favorite' : 'Add favorite'),
                      ],
                    ),
                  ),
                  if (showGitInMenu)
                    const PopupMenuItem<String>(
                      value: 'git',
                      child: Row(
                        children: [
                          Icon(Icons.account_tree_outlined, size: 18),
                          SizedBox(width: 10),
                          Text('Git details'),
                        ],
                      ),
                    ),
                  const PopupMenuItem<String>(
                    value: 'browse',
                    child: Row(
                      children: [
                        Icon(Icons.folder_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Browse files'),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'reload',
                    child: Row(
                      children: [
                        Icon(Icons.refresh_rounded, size: 18),
                        SizedBox(width: 10),
                        Text('Reload'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    value: 'rename',
                    child: Row(
                      children: [
                        Icon(Icons.drive_file_rename_outline, size: 18),
                        SizedBox(width: 10),
                        Text('Rename'),
                      ],
                    ),
                  ),
                  const PopupMenuItem<String>(
                    value: 'archive',
                    child: Row(
                      children: [
                        Icon(Icons.archive_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Archive'),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: widget.topPadding == null
          ? GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _dismissKeyboard,
              child: layoutBody,
            )
          : layoutBody,
    );
    if (widget.topPadding == null) {
      return scaffold;
    }
    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding!),
      child: scaffold,
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.host,
    required this.session,
    required this.gitStatus,
    required this.running,
    required this.favorite,
    required this.pinnedCount,
    required this.pinnedActive,
    required this.onPinnedTap,
    required this.onDetails,
    required this.onGitDetails,
  });

  final HostProfile host;
  final SessionSummary session;
  final SessionGitStatus? gitStatus;
  final bool running;
  final bool favorite;
  final int pinnedCount;
  final bool pinnedActive;
  final VoidCallback onPinnedTap;
  final VoidCallback onDetails;
  final VoidCallback onGitDetails;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: MeshCard(
        padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
        accentStrip: running ? colors.success : colors.accent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _HeaderStatusDot(
                        color: running ? colors.success : colors.textTertiary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        running ? 'running' : 'idle',
                        style: monoStyle(
                          color: running
                              ? colors.success
                              : colors.textSecondary,
                          fontSize: 10.5,
                        ),
                      ),
                      if (favorite) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.star_rounded,
                          size: 13,
                          color: colors.warning,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    session.cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                  if (_gitHeaderLabel(session, gitStatus) != null ||
                      pinnedCount > 0) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (_gitHeaderLabel(session, gitStatus) != null)
                          _GitSummaryPill(
                            label: _gitHeaderLabel(session, gitStatus)!,
                            dirty: gitStatus?.dirty ?? false,
                            onTap: onGitDetails,
                          ),
                        if (pinnedCount > 0)
                          _PinnedSummaryPill(
                            count: pinnedCount,
                            active: pinnedActive,
                            onTap: onPinnedTap,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDetails,
              icon: Icon(Icons.tune_rounded, size: 18, color: colors.accent),
              tooltip: 'Session details',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
          ],
        ),
      ),
    );
  }
}

String? _gitHeaderLabel(SessionSummary session, SessionGitStatus? status) {
  final branch = status?.branch ?? session.gitInfo?.branch;
  final shortSha = status?.shortSha ?? session.gitInfo?.shortSha;
  final label = (branch ?? shortSha ?? '').trim();
  if (label.isEmpty) {
    return null;
  }
  final changed = status?.changed ?? 0;
  if (changed > 0) {
    return '$label · $changed changed';
  }
  if ((status?.ahead ?? 0) > 0 || (status?.behind ?? 0) > 0) {
    final ahead = status!.ahead > 0 ? '↑${status.ahead}' : null;
    final behind = status.behind > 0 ? '↓${status.behind}' : null;
    return [label, ahead, behind].whereType<String>().join(' · ');
  }
  return label;
}

class _GitSummaryPill extends StatelessWidget {
  const _GitSummaryPill({
    required this.label,
    required this.dirty,
    required this.onTap,
  });

  final String label;
  final bool dirty;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MeshPill(
        label: label,
        icon: Icons.account_tree_outlined,
        tone: dirty ? MeshPillTone.warning : MeshPillTone.neutral,
        mono: true,
      ),
    );
  }
}

class _PinnedSummaryPill extends StatelessWidget {
  const _PinnedSummaryPill({
    required this.count,
    required this.active,
    required this.onTap,
  });

  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MeshPill(
        label: '$count pinned',
        icon: Icons.push_pin_rounded,
        tone: active ? MeshPillTone.accent : MeshPillTone.neutral,
        mono: true,
      ),
    );
  }
}

/// Compact single-line header used on mobile. Everything that isn't
/// immediately useful at a glance lives behind the tune button (session
/// details sheet) so the chat surface gets maximum vertical real estate.
class _JumpToLatestPill extends StatelessWidget {
  const _JumpToLatestPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.accent,
      shape: const StadiumBorder(),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_downward_rounded,
                size: 16,
                color: colors.userBubbleOn,
              ),
              const SizedBox(width: 6),
              Text(
                'Jump to latest',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.userBubbleOn,
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

class _SessionAppBarSubtitle extends StatelessWidget {
  const _SessionAppBarSubtitle({
    required this.host,
    required this.session,
    required this.gitStatus,
    required this.running,
    required this.pinnedCount,
    required this.pinnedActive,
    required this.onPinnedTap,
    required this.onDetails,
    required this.onGitDetails,
  });

  final HostProfile host;
  final SessionSummary session;
  final SessionGitStatus? gitStatus;
  final bool running;
  final int pinnedCount;
  final bool pinnedActive;
  final VoidCallback onPinnedTap;
  final VoidCallback onDetails;
  final VoidCallback onGitDetails;

  String _shortFolder(String cwd) {
    if (cwd.isEmpty) return '~';
    final trimmed = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
    final slash = trimmed.lastIndexOf('/');
    if (slash < 0 || slash == trimmed.length - 1) return trimmed;
    return trimmed.substring(slash + 1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final folder = _shortFolder(session.cwd);
    final gitLabel = _gitHeaderLabel(session, gitStatus);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDetails,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
          child: Row(
            children: [
              Icon(
                Icons.dns_rounded,
                size: 12,
                color: colors.textTertiary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '  ·  ',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.textTertiary,
                ),
              ),
              Flexible(
                child: Text(
                  folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (gitLabel != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onGitDetails,
                  child: MeshPill(
                    label: gitLabel,
                    icon: Icons.account_tree_outlined,
                    tone: (gitStatus?.dirty ?? false)
                        ? MeshPillTone.warning
                        : MeshPillTone.neutral,
                    mono: true,
                  ),
                ),
              ],
              if (pinnedCount > 0) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onPinnedTap,
                  child: MeshPill(
                    label: '$pinnedCount',
                    icon: Icons.push_pin_rounded,
                    tone: pinnedActive
                        ? MeshPillTone.accent
                        : MeshPillTone.neutral,
                    mono: true,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Icon(Icons.tune_rounded, size: 14, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderStatusDot extends StatelessWidget {
  const _HeaderStatusDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _GitDetailsSheet extends StatelessWidget {
  const _GitDetailsSheet({
    required this.session,
    required this.status,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onShowDiff,
  });

  final SessionSummary session;
  final SessionGitStatus? status;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;
  final ValueChanged<String> onShowDiff;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final gitInfo = session.gitInfo;
    final branch = status?.branch ?? gitInfo?.branch;
    final shortSha = status?.shortSha ?? gitInfo?.shortSha;
    final originUrl = status?.originUrl ?? gitInfo?.originUrl;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Git details',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: loading ? null : onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh git status',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (loading && status == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (status != null && !status!.isRepo)
              MeshEmptyState(
                icon: Icons.account_tree_outlined,
                title: 'No Git repo found',
                body:
                    'This session working directory is not inside a Git worktree.',
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MeshPill(
                    label: branch ?? 'detached',
                    icon: Icons.account_tree_outlined,
                    tone: MeshPillTone.accent,
                    mono: true,
                  ),
                  if (shortSha != null)
                    MeshPill(
                      label: shortSha,
                      icon: Icons.tag_rounded,
                      tone: MeshPillTone.neutral,
                      mono: true,
                    ),
                  if (status != null)
                    MeshPill(
                      label: status!.dirty
                          ? '${status!.changed} changed'
                          : 'clean',
                      icon: status!.dirty
                          ? Icons.warning_amber_rounded
                          : Icons.check_rounded,
                      tone: status!.dirty
                          ? MeshPillTone.warning
                          : MeshPillTone.success,
                      mono: true,
                    ),
                  if ((status?.ahead ?? 0) > 0)
                    MeshPill(
                      label: 'ahead ${status!.ahead}',
                      tone: MeshPillTone.info,
                      mono: true,
                    ),
                  if ((status?.behind ?? 0) > 0)
                    MeshPill(
                      label: 'behind ${status!.behind}',
                      tone: MeshPillTone.info,
                      mono: true,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              MeshCard(
                tone: MeshCardTone.muted,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(label: 'Working dir', value: session.cwd),
                    if (status?.repoRoot != null)
                      _DetailRow(label: 'Repo root', value: status!.repoRoot!),
                    if (status?.upstream != null)
                      _DetailRow(label: 'Upstream', value: status!.upstream!),
                    if (originUrl != null)
                      _DetailRow(label: 'Origin', value: originUrl),
                    if (error != null)
                      Text(
                        error!,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.warning),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => onShowDiff('working'),
                    icon: const Icon(Icons.difference_rounded, size: 18),
                    label: const Text('Working diff'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onShowDiff('staged'),
                    icon: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: const Text('Staged diff'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onShowDiff('remote'),
                    icon: const Icon(Icons.cloud_outlined, size: 18),
                    label: const Text('Remote diff'),
                  ),
                ],
              ),
              if (status != null && status!.files.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Changed files',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                MeshCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final file in status!.files.take(40))
                        _GitFileStatusRow(file: file),
                      if (status!.files.length > 40 || status!.filesTruncated)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            status!.filesTruncated
                                ? 'More files omitted by server cap.'
                                : '${status!.files.length - 40} more files omitted.',
                            style: monoStyle(
                              color: colors.textSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _GitFileStatusRow extends StatelessWidget {
  const _GitFileStatusRow({required this.file});

  final SessionGitFileStatus file;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final status = file.isUntracked
        ? '??'
        : '${file.indexStatus}${file.worktreeStatus}';
    final path = file.originalPath == null
        ? file.path
        : '${file.originalPath} -> ${file.path}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              status,
              style: monoStyle(
                color: file.isUntracked
                    ? colors.warning
                    : file.isStaged
                    ? colors.success
                    : colors.textSecondary,
                fontWeight: FontWeight.w800,
                fontSize: 11.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textPrimary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _GitDiffSheet extends StatelessWidget {
  const _GitDiffSheet({required this.future});

  final Future<SessionGitDiff> future;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.86,
      child: FutureBuilder<SessionGitDiff>(
        future: future,
        builder: (context, snapshot) {
          final title = snapshot.data == null
              ? 'Git diff'
              : _gitDiffTitle(snapshot.data!);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return MeshEmptyState(
                          icon: Icons.error_outline_rounded,
                          title: 'Could not load diff',
                          body: friendlyError(
                            snapshot.error ?? 'Unknown error',
                          ),
                        );
                      }
                      final diff = snapshot.data!;
                      if (diff.diff.trim().isEmpty) {
                        return MeshEmptyState(
                          icon: Icons.check_rounded,
                          title: 'No diff',
                          body: 'Git did not report changes for this view.',
                        );
                      }
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (diff.truncated)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: MeshPill(
                                  label:
                                      'Truncated after ${diff.maxChars} chars',
                                  icon: Icons.content_cut_rounded,
                                  tone: MeshPillTone.warning,
                                  mono: true,
                                ),
                              ),
                            if (diff.baseSha != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Text(
                                  'Base ${diff.baseSha}',
                                  style: monoStyle(
                                    color: colors.textSecondary,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            DiffView(diff: diff.diff),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String _gitDiffTitle(SessionGitDiff diff) {
  return switch (diff.kind) {
    'staged' => 'Staged diff',
    'unstaged' => 'Unstaged diff',
    'remote' => 'Remote diff',
    _ => 'Working diff',
  };
}

class _PinnedListSheet extends StatelessWidget {
  const _PinnedListSheet({
    required this.pinsBuilder,
    required this.refresh,
    required this.onOpen,
    required this.onUnpin,
    required this.onClose,
  });

  final List<PinnedSessionMessage> Function() pinsBuilder;
  final Listenable refresh;
  final ValueChanged<PinnedSessionMessage> onOpen;
  final ValueChanged<PinnedSessionMessage> onUnpin;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        color: colors.surfaceElevated,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.push_pin_rounded,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Pinned messages',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: ListenableBuilder(
                listenable: refresh,
                builder: (context, _) => PinnedListPanel(
                  pins: pinsBuilder(),
                  onOpen: onOpen,
                  onUnpin: onUnpin,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PinnedMessageSheet extends StatelessWidget {
  const _PinnedMessageSheet({
    required this.pin,
    required this.onUnpin,
    this.onOpenFile,
  });

  final PinnedSessionMessage pin;
  final VoidCallback onUnpin;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: colors.textPrimary, height: 1.45);
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.push_pin_rounded, size: 20, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pinned ${pin.roleLabel.toLowerCase()} message',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (pin.hasText)
                  _MessageCopyButton(
                    text: pin.text,
                    tone: colors.textSecondary,
                    accent: colors.accent,
                  ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: onUnpin,
                  icon: const Icon(Icons.push_pin_outlined, size: 17),
                  label: const Text('Unpin'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                MeshPill(
                  label: pin.roleLabel,
                  icon: pin.role == 'assistant'
                      ? Icons.smart_toy_outlined
                      : Icons.person_outline_rounded,
                ),
                MeshPill(
                  label: 'Pinned ${_formatPinnedTimestamp(pin.pinnedAt)}',
                  icon: Icons.schedule_rounded,
                ),
                if (pin.attachmentCount > 0)
                  MeshPill(
                    label:
                        '${pin.attachmentCount} attachment${pin.attachmentCount == 1 ? '' : 's'}',
                    icon: Icons.attachment_rounded,
                  ),
                if (pin.textTruncated)
                  const MeshPill(
                    label: 'Stored preview truncated',
                    icon: Icons.content_cut_rounded,
                    tone: MeshPillTone.warning,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: MeshCard(
                tone: MeshCardTone.muted,
                padding: const EdgeInsets.all(14),
                child: SingleChildScrollView(
                  child: pin.hasText
                      ? (pin.role == 'assistant'
                            ? _MarkdownMessageBody(
                                text: pin.text,
                                textColor: colors.textPrimary,
                                onOpenFile: onOpenFile,
                              )
                            : _LinkifiedSelectableText(
                                text: pin.text,
                                style: textStyle,
                                linkColor: colors.accent,
                              ))
                      : Text(
                          pin.preview,
                          style: textStyle?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatPinnedTimestamp(DateTime value) {
  if (value.millisecondsSinceEpoch <= 0) return 'earlier';
  final now = DateTime.now();
  final sameDay =
      value.year == now.year &&
      value.month == now.month &&
      value.day == now.day;
  final time = '${_twoDigits(value.hour)}:${_twoDigits(value.minute)}';
  if (sameDay) return 'today $time';
  return '${value.month}/${value.day} $time';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

class _PendingActionCard extends StatelessWidget {
  const _PendingActionCard({required this.action, required this.onRespond});

  final PendingAction action;
  final ValueChanged<String> onRespond;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mq = MediaQuery.of(context);
    // Cap the card at ~38% of available height so a verbose approval
    // payload (e.g. a long shell command or write-file preview) can never
    // push the composer off the screen on mobile. Internal scroll keeps
    // every button reachable.
    final maxHeight = mq.size.height * 0.38;
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: colors.warning.withValues(alpha: 0.5),
      accentStrip: colors.warning,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.shield_rounded, color: colors.warning, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Approval required',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.warning,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      action.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      action.detail,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (action.canApprove)
                  FilledButton.icon(
                    onPressed: () => onRespond('accept'),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Approve'),
                  ),
                if (action.canApproveForSession)
                  OutlinedButton.icon(
                    onPressed: () => onRespond('acceptForSession'),
                    icon: const Icon(Icons.all_inclusive_rounded, size: 18),
                    label: const Text('Approve for session'),
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
      ),
    );
  }
}

class _HistoryTruncationCard extends StatelessWidget {
  const _HistoryTruncationCard({
    required this.history,
    required this.loading,
    required this.onLoadOlderHistory,
    this.onDismiss,
  });

  final SessionLogHistorySummary history;
  final bool loading;
  final VoidCallback onLoadOlderHistory;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final hiddenMessages = (history.totalMessages - history.returnedMessages)
        .clamp(0, 1 << 30);
    final hiddenActivities =
        (history.totalActivities - history.returnedActivities).clamp(
          0,
          1 << 30,
        );

    final hiddenParts = <String>[];
    if (hiddenMessages > 0) {
      hiddenParts.add('$hiddenMessages older messages');
    }
    if (hiddenActivities > 0) {
      hiddenParts.add('$hiddenActivities older actions');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 14, color: colors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hiddenParts.isEmpty
                  ? '${history.returnedMessages} msgs · ${history.returnedActivities} actions loaded'
                  : '${hiddenParts.join(' · ')} hidden',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontSize: 11.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (loading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            InkWell(
              onTap: onLoadOlderHistory,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  'Load older',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ),
          if (onDismiss != null)
            InkResponse(
              radius: 18,
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: colors.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.attachments,
    required this.skills,
    required this.activeSkillQuery,
    required this.skillSuggestions,
    required this.loadingSkills,
    required this.skillError,
    required this.sending,
    required this.onPickImages,
    required this.onRemoveAttachment,
    required this.onSelectSkill,
    required this.onRemoveSkill,
    required this.onSend,
    required this.onDismiss,
    this.submitOnEnter = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<_ComposerImageAttachment> attachments;
  final List<_ComposerSkillMention> skills;
  final String? activeSkillQuery;
  final List<SkillSummary> skillSuggestions;
  final bool loadingSkills;
  final String? skillError;
  final bool sending;
  final VoidCallback onPickImages;
  final ValueChanged<String> onRemoveAttachment;
  final ValueChanged<SkillSummary> onSelectSkill;
  final ValueChanged<String> onRemoveSkill;
  final VoidCallback onSend;
  final VoidCallback onDismiss;
  final bool submitOnEnter;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isMacDesktop =
        submitOnEnter && defaultTargetPlatform == TargetPlatform.macOS;
    final enableDesktopSubmitShortcut = submitOnEnter;
    Widget field = TextField(
      controller: controller,
      focusNode: focusNode,
      minLines: 1,
      maxLines: 6,
      onTapOutside: isMacDesktop ? null : (_) => onDismiss(),
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: enableDesktopSubmitShortcut
            ? 'Message this session — Enter to send, Shift+Enter for newline'
            : 'Message this session',
        hintStyle: TextStyle(color: colors.textTertiary),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
    if (enableDesktopSubmitShortcut) {
      // Desktop affordance: bare Enter sends, Shift+Enter inserts a newline.
      // Wrapping the TextField with CallbackShortcuts at a higher priority
      // than its default newline handler.
      field = CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (!sending) onSend();
          },
          const SingleActivator(LogicalKeyboardKey.enter, shift: true): () {
            final selection = controller.selection;
            final text = controller.text;
            final start = selection.start < 0 ? text.length : selection.start;
            final end = selection.end < 0 ? text.length : selection.end;
            final before = text.substring(0, start);
            final after = text.substring(end);
            final next = '$before\n$after';
            controller.value = TextEditingValue(
              text: next,
              selection: TextSelection.collapsed(offset: start + 1),
            );
          },
        },
        child: field,
      );
    }
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        decoration: BoxDecoration(
          color: colors.canvas,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _ComposerAttachButton(
              enabled: !sending,
              onPressed: onPickImages,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colors.composerBackground,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: colors.border),
                ),
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (activeSkillQuery != null) ...[
                      _ComposerSkillSuggestionTray(
                        query: activeSkillQuery!,
                        suggestions: skillSuggestions,
                        loading: loadingSkills,
                        error: skillError,
                        onSelectSkill: onSelectSkill,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (skills.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: skills
                              .map(
                                (skill) => _ComposerSkillChip(
                                  mention: skill,
                                  onRemove: onRemoveSkill,
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (attachments.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: attachments
                              .map(
                                (attachment) => _ComposerAttachmentChip(
                                  attachment: attachment,
                                  onRemove: onRemoveAttachment,
                                ),
                              )
                              .toList(growable: false),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    field,
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _SendButton(
              sending: sending,
              controller: controller,
              hasAttachments: attachments.isNotEmpty,
              hasSkills: skills.isNotEmpty,
              onSend: onSend,
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerAttachButton extends StatelessWidget {
  const _ComposerAttachButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: 'Attach images',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: enabled ? onPressed : null,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.border),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.add_photo_alternate_outlined,
              color: enabled ? colors.accent : colors.textTertiary,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.sending,
    required this.controller,
    required this.hasAttachments,
    required this.hasSkills,
    required this.onSend,
  });

  final bool sending;
  final TextEditingController controller;
  final bool hasAttachments;
  final bool hasSkills;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final hasText = controller.text.trim().isNotEmpty;
        final canSend = !sending && (hasText || hasAttachments || hasSkills);
        final showActive = sending || canSend;
        final bgColor = sending
            ? colors.surfaceMuted
            : (canSend ? colors.accent : colors.surfaceMuted);
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: canSend ? onSend : null,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(18),
                boxShadow: showActive && canSend
                    ? [
                        BoxShadow(
                          color: colors.accent.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : const [],
              ),
              alignment: Alignment.center,
              child: sending
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.textSecondary,
                      ),
                    )
                  : Icon(
                      Icons.arrow_upward_rounded,
                      color: canSend
                          ? colors.accentOn
                          : colors.textTertiary,
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _ComposerAttachmentChip extends StatelessWidget {
  const _ComposerAttachmentChip({
    required this.attachment,
    required this.onRemove,
  });

  final _ComposerImageAttachment attachment;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              attachment.bytes,
              width: 36,
              height: 36,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatByteCount(attachment.byteLength),
                  style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => onRemove(attachment.id),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerSkillSuggestionTray extends StatelessWidget {
  const _ComposerSkillSuggestionTray({
    required this.query,
    required this.suggestions,
    required this.loading,
    required this.error,
    required this.onSelectSkill,
  });

  final String query;
  final List<SkillSummary> suggestions;
  final bool loading;
  final String? error;
  final ValueChanged<SkillSummary> onSelectSkill;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget child;
    if (loading) {
      child = const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.8),
          ),
        ),
      );
    } else if (suggestions.isEmpty) {
      final message = error == null || error!.trim().isEmpty
          ? 'No skills match "\$$query".'
          : 'Couldn\'t load skills: $error';
      child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.auto_awesome_outlined,
              size: 16,
              color: colors.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        ),
      );
    } else {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: suggestions
            .map(
              (skill) => InkWell(
                onTap: () => onSelectSkill(skill),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: colors.surfaceMuted,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: colors.border),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.auto_awesome_rounded,
                          size: 15,
                          color: colors.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              skill.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              skill.summaryDescription,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: colors.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        skill.mentionToken,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(growable: false),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _ComposerSkillChip extends StatelessWidget {
  const _ComposerSkillChip({required this.mention, required this.onRemove});

  final _ComposerSkillMention mention;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 15, color: colors.accent),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mention.skill.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  mention.tokenText,
                  style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () => onRemove(mention.skill.path),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerImageAttachment {
  const _ComposerImageAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.dataUrl,
  });

  final String id;
  final String name;
  final String mimeType;
  final Uint8List bytes;
  final String dataUrl;

  int get byteLength => bytes.length;
}

class _ComposerSkillMention {
  const _ComposerSkillMention({required this.skill, required this.tokenText});

  final SkillSummary skill;
  final String tokenText;

  @override
  bool operator ==(Object other) {
    return other is _ComposerSkillMention &&
        other.skill.path == skill.path &&
        other.tokenText == tokenText;
  }

  @override
  int get hashCode => Object.hash(skill.path, tokenText);
}

class _ActiveComposerSkillQuery {
  const _ActiveComposerSkillQuery({
    required this.start,
    required this.end,
    required this.query,
  });

  final int start;
  final int end;
  final String query;
}

class _PreparedDraftImage {
  const _PreparedDraftImage({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

class _LiveAssistantMessageState {
  const _LiveAssistantMessageState({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.seq,
    required this.phase,
    this.live = true,
  });

  final String id;
  final String text;
  final DateTime createdAt;
  final int seq;
  final String? phase;
  final bool live;

  _LiveAssistantMessageState copyWith({
    String? text,
    String? phase,
    bool? live,
  }) {
    return _LiveAssistantMessageState(
      id: id,
      text: text ?? this.text,
      createdAt: createdAt,
      seq: seq,
      phase: phase ?? this.phase,
      live: live ?? this.live,
    );
  }

  SessionMessage toMessage() => SessionMessage(
    id: id,
    role: 'assistant',
    text: text,
    attachments: const <SessionMessageAttachment>[],
    createdAt: createdAt,
    seq: seq,
    phase: phase,
  );
}

enum _TimelineEntryKind { message, activity, liveAssistant }

class _TimelineEntry {
  const _TimelineEntry._({
    required this.kind,
    required this.createdAt,
    required this.seq,
    required this.keyId,
    this.message,
    this.activity,
  });

  factory _TimelineEntry.message(SessionMessage message) => _TimelineEntry._(
    kind: _TimelineEntryKind.message,
    createdAt: message.createdAt,
    seq: message.seq,
    keyId: 'msg:${message.id}',
    message: message,
  );

  factory _TimelineEntry.activity(SessionActivity activity) => _TimelineEntry._(
    kind: _TimelineEntryKind.activity,
    createdAt: activity.createdAt,
    seq: activity.seq,
    keyId: 'act:${activity.id}',
    activity: activity,
  );

  factory _TimelineEntry.liveAssistant(_LiveAssistantMessageState message) =>
      _TimelineEntry._(
        kind: _TimelineEntryKind.liveAssistant,
        createdAt: message.createdAt,
        seq: message.seq,
        keyId: 'msg:${message.id}',
      );

  final _TimelineEntryKind kind;
  final DateTime createdAt;
  final int seq;
  final String keyId;
  final SessionMessage? message;
  final SessionActivity? activity;
}

class _LiveAssistantBubble extends StatelessWidget {
  const _LiveAssistantBubble({
    required this.host,
    required this.api,
    required this.message,
    this.onOpenFile,
  });

  final HostProfile host;
  final ApiClient api;
  final ValueListenable<_LiveAssistantMessageState?> message;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_LiveAssistantMessageState?>(
      valueListenable: message,
      builder: (context, liveMessage, _) {
        if (liveMessage == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _MessageBubble(
            host: host,
            api: api,
            message: liveMessage.toMessage(),
            live: liveMessage.live,
            onOpenFile: onOpenFile,
          ),
        );
      },
    );
  }
}

class _ComposerStatusStrip extends StatelessWidget {
  const _ComposerStatusStrip({required this.thinking});

  final ValueListenable<bool> thinking;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: thinking,
      builder: (context, show, _) {
        if (!show) {
          return const SizedBox.shrink();
        }
        final colors = context.colors;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const LivePulse(),
                  const SizedBox(width: 10),
                  Text(
                    'Working',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Waiting for assistant output…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
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
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.host,
    required this.api,
    required this.message,
    this.live = false,
    this.pinned = false,
    this.onTogglePin,
    this.onOpenFile,
  });

  final HostProfile host;
  final ApiClient api;
  final SessionMessage message;
  final bool live;
  final bool pinned;
  final VoidCallback? onTogglePin;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isUser = message.role == 'user';
    final isAssistant = message.role == 'assistant';
    final hasText = message.text.trim().isNotEmpty;
    final canPin = onTogglePin != null && message.hasVisibleContent;

    final bubbleColor = switch (message.role) {
      'user' => colors.userBubble,
      'assistant' => colors.assistantBubble,
      _ => colors.surfaceMuted,
    };
    final textColor = isUser ? colors.userBubbleOn : colors.textPrimary;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: live
                    ? colors.accent
                    : (isUser
                          ? colors.userBubble
                          : colors.assistantBubbleBorder),
                width: live ? 1.4 : 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.phase != null && isAssistant)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          if (live) ...[
                            const LivePulse(),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            message.phase == 'commentary'
                                ? 'COMMENTARY'
                                : 'ANSWER',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: colors.textTertiary,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.1,
                                ),
                          ),
                        ],
                      ),
                    ),
                  if (message.attachments.isNotEmpty) ...[
                    _MessageAttachmentsSection(
                      host: host,
                      api: api,
                      attachments: message.attachments,
                    ),
                    if (hasText) const SizedBox(height: 10),
                  ],
                  if (hasText)
                    if (isAssistant)
                      _MarkdownMessageBody(
                        text: message.text,
                        textColor: textColor,
                        onOpenFile: onOpenFile,
                      )
                    else
                      _LinkifiedSelectableText(
                        text: message.text,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          height: 1.45,
                        ),
                        linkColor: colors.accent,
                      ),
                  if (canPin || (!isUser && hasText) || hasText)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _formatMessageTime(message.createdAt),
                              style: Theme.of(
                                context,
                              ).textTheme.labelSmall?.copyWith(
                                color: isUser
                                    ? textColor.withValues(alpha: 0.62)
                                    : colors.textTertiary,
                                fontSize: 10.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            if (canPin)
                              _MessagePinButton(
                                pinned: pinned,
                                tone: isUser
                                    ? textColor.withValues(alpha: 0.72)
                                    : colors.textSecondary,
                                accent: colors.warning,
                                onTap: onTogglePin!,
                              ),
                            if (!isUser && hasText)
                              _MessageCopyButton(
                                text: message.text,
                                tone: colors.textSecondary,
                                accent: colors.accent,
                              ),
                          ],
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

class _MessageAttachmentsSection extends StatelessWidget {
  const _MessageAttachmentsSection({
    required this.host,
    required this.api,
    required this.attachments,
  });

  final HostProfile host;
  final ApiClient api;
  final List<SessionMessageAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = attachments.length == 1
            ? constraints.maxWidth
            : ((constraints.maxWidth - 8) / 2)
                  .clamp(120.0, constraints.maxWidth)
                  .toDouble();
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: attachments
              .map((attachment) {
                return SizedBox(
                  width: attachment.isLocalImage
                      ? constraints.maxWidth
                      : itemWidth,
                  child: _MessageAttachmentTile(
                    host: host,
                    api: api,
                    attachment: attachment,
                  ),
                );
              })
              .toList(growable: false),
        );
      },
    );
  }
}

class _MessageAttachmentTile extends StatelessWidget {
  const _MessageAttachmentTile({
    required this.host,
    required this.api,
    required this.attachment,
  });

  final HostProfile host;
  final ApiClient api;
  final SessionMessageAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage && attachment.url != null) {
      return _MessageImageAttachmentTile(url: attachment.url!);
    }
    if (attachment.isLocalImage && attachment.path != null) {
      return _LocalImageAttachmentTile(
        host: host,
        api: api,
        path: attachment.path!,
      );
    }
    return const SizedBox.shrink();
  }
}

class _MessageImageAttachmentTile extends StatefulWidget {
  const _MessageImageAttachmentTile({required this.url});

  final String url;

  @override
  State<_MessageImageAttachmentTile> createState() =>
      _MessageImageAttachmentTileState();
}

class _MessageImageAttachmentTileState
    extends State<_MessageImageAttachmentTile> {
  Uint8List? _dataUrlBytes;

  @override
  void initState() {
    super.initState();
    _decodeDataUrlIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _MessageImageAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _decodeDataUrlIfNeeded();
    }
  }

  void _decodeDataUrlIfNeeded() {
    if (!_isInlineImageDataUrl(widget.url)) {
      _dataUrlBytes = null;
      return;
    }
    _dataUrlBytes = _decodeInlineImageDataUrl(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final imageProvider = _imageProvider();
    final heroTag = _messageImageHeroTag(widget.url);
    final imageChild = imageProvider == null
        ? _AttachmentLoadError(colors: colors)
        : Hero(
            tag: heroTag,
            child: Image(
              image: imageProvider,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) =>
                  _AttachmentLoadError(colors: colors),
            ),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: imageProvider == null
                ? null
                : () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _FullscreenImageViewer(
                          imageProvider: imageProvider,
                          heroTag: heroTag,
                        ),
                      ),
                    );
                  },
            child: AspectRatio(aspectRatio: 1.35, child: imageChild),
          ),
        ),
      ),
    );
  }

  ImageProvider<Object>? _imageProvider() {
    if (_dataUrlBytes != null) {
      return MemoryImage(_dataUrlBytes!);
    }
    if (!_isInlineImageDataUrl(widget.url)) {
      return NetworkImage(widget.url);
    }
    return null;
  }
}

class _LocalImageAttachmentTile extends StatelessWidget {
  const _LocalImageAttachmentTile({
    required this.host,
    required this.api,
    required this.path,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final heroTag = _messageImageHeroTag('${host.id}:$path');
    final imageProvider = NetworkImage(
      api.fsBlobUri(host, path).toString(),
      headers: api.authHeaders(host),
    );
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _FullscreenImageViewer(
                    imageProvider: imageProvider,
                    heroTag: heroTag,
                  ),
                ),
              );
            },
            child: AspectRatio(
              aspectRatio: 1.35,
              child: Hero(
                tag: heroTag,
                child: Image(
                  image: imageProvider,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) =>
                      _LocalImageFallback(path: path, colors: colors),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalImageFallback extends StatelessWidget {
  const _LocalImageFallback({required this.path, required this.colors});

  final String path;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surfaceMuted,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(Icons.image_outlined, color: colors.accent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentLoadError extends StatelessWidget {
  const _AttachmentLoadError({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surfaceMuted,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: colors.textTertiary,
        size: 28,
      ),
    );
  }
}

class _FullscreenImageViewer extends StatelessWidget {
  const _FullscreenImageViewer({
    required this.imageProvider,
    required this.heroTag,
  });

  final ImageProvider<Object> imageProvider;
  final String heroTag;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Center(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Hero(
              tag: heroTag,
              child: Image(
                image: imageProvider,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 36,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageCopyButton extends StatefulWidget {
  const _MessageCopyButton({
    required this.text,
    required this.tone,
    required this.accent,
  });

  final String text;
  final Color tone;
  final Color accent;

  @override
  State<_MessageCopyButton> createState() => _MessageCopyButtonState();
}

class _MessageCopyButtonState extends State<_MessageCopyButton> {
  bool _copied = false;

  Future<void> _handle() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _copied ? widget.accent : widget.tone;
    return InkWell(
      onTap: _handle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 13,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? 'Copied' : 'Copy',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessagePinButton extends StatelessWidget {
  const _MessagePinButton({
    required this.pinned,
    required this.tone,
    required this.accent,
    required this.onTap,
  });

  final bool pinned;
  final Color tone;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = pinned ? accent : tone;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              size: 13,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              pinned ? 'Pinned' : 'Pin',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkdownMessageBody extends StatelessWidget {
  const _MarkdownMessageBody({
    required this.text,
    required this.textColor,
    this.onOpenFile,
  });

  final String text;
  final Color textColor;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    return MarkdownContent(
      text: text,
      textColor: textColor,
      onOpenFile: onOpenFile,
    );
  }
}

bool _isInlineImageDataUrl(String value) => value.startsWith('data:image/');

Uint8List? _decodeInlineImageDataUrl(String value) {
  try {
    return UriData.parse(value).contentAsBytes();
  } catch (_) {
    return null;
  }
}

String _messageImageHeroTag(String url) =>
    'session-image:${url.hashCode.toUnsigned(32)}';

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty ? path : parts.last;
}

String _formatByteCount(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _truncateMiddle(String value, int maxLength) {
  if (value.length <= maxLength || maxLength < 7) {
    return value;
  }
  final prefixLength = ((maxLength - 1) / 2).floor() - 1;
  final suffixLength = maxLength - prefixLength - 1;
  return '${value.substring(0, prefixLength)}…${value.substring(value.length - suffixLength)}';
}

Map<String, Object?> _compressDraftImagePayload(Map<String, Object?> payload) {
  final name = payload['name']! as String;
  final mimeType = payload['mimeType']! as String;
  final bytes = payload['bytes']! as Uint8List;

  if (mimeType == 'image/gif') {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final baked = img.bakeOrientation(decoded);
  final longestEdge = math.max(baked.width, baked.height);
  final isPng = mimeType == 'image/png';
  final shouldKeepOriginal =
      longestEdge <= 1800 &&
      bytes.length <= 900 * 1024 &&
      !mimeType.contains('bmp');
  if (shouldKeepOriginal) {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final resized = longestEdge > 1800
      ? img.copyResize(
          baked,
          width: baked.width >= baked.height ? 1800 : null,
          height: baked.height > baked.width ? 1800 : null,
          interpolation: img.Interpolation.cubic,
        )
      : baked;

  final outputMimeType = isPng ? 'image/png' : 'image/jpeg';
  final encoded = outputMimeType == 'image/png'
      ? Uint8List.fromList(img.encodePng(resized, level: 6))
      : Uint8List.fromList(img.encodeJpg(resized, quality: 84));

  final chosenBytes = encoded.length < bytes.length ? encoded : bytes;
  final chosenMimeType = identical(chosenBytes, encoded)
      ? outputMimeType
      : mimeType;

  return <String, Object?>{
    'name': name,
    'mimeType': chosenMimeType,
    'bytes': chosenBytes,
  };
}

class _LinkifiedSelectableText extends StatefulWidget {
  const _LinkifiedSelectableText({
    required this.text,
    required this.style,
    required this.linkColor,
  });

  final String text;
  final TextStyle? style;
  final Color linkColor;

  @override
  State<_LinkifiedSelectableText> createState() =>
      _LinkifiedSelectableTextState();
}

class _LinkifiedSelectableTextState extends State<_LinkifiedSelectableText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    final matches = _urlRegExp.allMatches(widget.text).toList();
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, m.start)));
      }
      var raw = m.group(0)!;
      // Trim common trailing punctuation that usually isn't part of the URL.
      final trimmed = raw.replaceAll(RegExp(r'[),.!?;:\]]+$'), '');
      final trailing = raw.substring(trimmed.length);
      raw = trimmed;
      final href = raw.startsWith('www.') ? 'https://$raw' : raw;
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _openLink(context, href);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: raw,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
      );
      if (trailing.isNotEmpty) {
        spans.add(TextSpan(text: trailing));
      }
      cursor = m.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return SelectableText.rich(TextSpan(style: widget.style, children: spans));
  }
}

Future<void> _openLink(BuildContext context, String href) async {
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    showAppSnackBar(context, 'Could not open link');
  }
}

final RegExp _urlRegExp = RegExp(
  r'(https?:\/\/[^\s<>]+|www\.[^\s<>]+)',
  caseSensitive: false,
);

class _ActivityCard extends StatefulWidget {
  const _ActivityCard({
    required this.host,
    required this.api,
    required this.activity,
    required this.sessionCwd,
    this.defaultCollapsed = true,
    this.onOpenFile,
  });

  final HostProfile host;
  final ApiClient api;
  final SessionActivity activity;
  final String sessionCwd;
  final bool defaultCollapsed;
  final void Function(String path)? onOpenFile;

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> {
  static const _collapsedLineLimit = 15;
  bool _outputExpanded = false;
  bool _diffExpanded = false;
  late bool _cardCollapsed = _resolveInitialCollapsed();
  bool _userOverrode = false;

  bool get _activityRunning {
    const terminal = {'completed', 'failed', 'declined'};
    return !terminal.contains(widget.activity.status);
  }

  bool _resolveInitialCollapsed() {
    if (widget.activity.type == 'image_generation') {
      return widget.defaultCollapsed;
    }
    if (_activityRunning) return false;
    return widget.defaultCollapsed;
  }

  @override
  void didUpdateWidget(covariant _ActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_userOverrode) return;
    if (widget.activity.type == 'image_generation') return;
    const terminal = {'completed', 'failed', 'declined'};
    final wasRunning = !terminal.contains(oldWidget.activity.status);
    final isRunning = _activityRunning;
    if (wasRunning && !isRunning && !_cardCollapsed) {
      setState(() => _cardCollapsed = true);
    } else if (!wasRunning && isRunning && _cardCollapsed) {
      setState(() => _cardCollapsed = false);
    }
  }

  void _openWorkspaceFile(String path) => widget.onOpenFile?.call(path);

  @override
  Widget build(BuildContext context) {
    final activity = widget.activity;
    final sessionCwd = widget.sessionCwd;
    final colors = context.colors;
    final title = switch (activity.type) {
      'command' =>
        (activity.command ?? '').trim().isEmpty ? 'Command' : activity.command!,
      'file_change' =>
        activity.changes.length == 1
            ? _relativeSessionPath(activity.changes.first.path, sessionCwd)
            : 'Edited ${activity.changes.length} files',
      'turn_diff' => 'Live turn diff',
      'web_search' => _webSearchTitle(activity),
      'image_generation' => 'Generated image',
      _ => 'Activity',
    };

    final subtitle = switch (activity.type) {
      'command' => _relativeSessionPath(activity.cwd ?? sessionCwd, sessionCwd),
      'file_change' => _activityFileSummary(activity.changes, sessionCwd),
      'turn_diff' => 'Aggregated patch snapshot for this turn',
      'web_search' => _webSearchSubtitle(activity),
      'image_generation' =>
        (activity.savedPath ?? '').isNotEmpty
            ? _relativeSessionPath(activity.savedPath!, sessionCwd)
            : 'Image generation output',
      _ => null,
    };

    final activityLabel = switch (activity.type) {
      'command' => 'COMMAND',
      'file_change' => 'FILE CHANGE',
      'turn_diff' => 'TURN DIFF',
      'web_search' => 'WEB SEARCH',
      'image_generation' => 'IMAGE',
      _ => 'ACTIVITY',
    };

    final activityIcon = switch (activity.type) {
      'command' => Icons.terminal_rounded,
      'file_change' => Icons.edit_note_rounded,
      'turn_diff' => Icons.difference_rounded,
      'web_search' => Icons.travel_explore_rounded,
      'image_generation' => Icons.image_rounded,
      _ => Icons.bolt_rounded,
    };

    final statusTone = switch (activity.status) {
      'completed' => MeshPillTone.success,
      'failed' => MeshPillTone.danger,
      'declined' => MeshPillTone.neutral,
      _ => MeshPillTone.accent,
    };
    final statusLabel = switch (activity.status) {
      'completed' => 'done',
      'failed' => 'failed',
      'declined' => 'declined',
      _ => 'running',
    };
    final statusIcon = switch (activity.status) {
      'completed' => Icons.check_rounded,
      'failed' => Icons.error_outline_rounded,
      'declined' => Icons.block_rounded,
      _ => Icons.bolt_rounded,
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: MeshCard(
            tone: MeshCardTone.surface,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () {
                    setState(() {
                      _cardCollapsed = !_cardCollapsed;
                      _userOverrode = true;
                    });
                  },
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: colors.accentMuted,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            activityIcon,
                            size: 18,
                            color: colors.accent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                activityLabel,
                                style: monoStyle(
                                  color: colors.accent,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ).copyWith(letterSpacing: 1.2),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                title,
                                maxLines: _cardCollapsed ? 1 : 3,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    (activity.isCommand
                                            ? monoStyle(
                                                color: colors.textPrimary,
                                                fontSize: 13,
                                              )
                                            : Theme.of(
                                                context,
                                              ).textTheme.titleSmall?.copyWith(
                                                fontWeight: FontWeight.w700,
                                              ))
                                        ?.copyWith(height: 1.35),
                              ),
                              if (!_cardCollapsed &&
                                  subtitle != null &&
                                  subtitle.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  subtitle,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: colors.textSecondary),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        MeshPill(
                          label: statusLabel,
                          tone: statusTone,
                          icon: statusIcon,
                          mono: true,
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          _cardCollapsed
                              ? Icons.unfold_more_rounded
                              : Icons.unfold_less_rounded,
                          size: 16,
                          color: colors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
                if (!_cardCollapsed) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (activity.turnId != null)
                        MeshPill(
                          label: 'turn ${_shortId(activity.turnId!)}',
                          mono: true,
                        ),
                      if (activity.isCommand && activity.exitCode != null)
                        MeshPill(
                          label: 'exit ${activity.exitCode}',
                          tone: activity.exitCode == 0
                              ? MeshPillTone.success
                              : MeshPillTone.danger,
                          mono: true,
                        ),
                      if (activity.isCommand && activity.durationMs != null)
                        MeshPill(
                          label: _formatDuration(activity.durationMs!),
                          mono: true,
                        ),
                      if (activity.isCommand &&
                          (activity.source ?? '').isNotEmpty)
                        MeshPill(
                          label: _commandSourceLabel(activity.source!),
                          mono: true,
                        ),
                      if (activity.isCommand &&
                          (activity.processId ?? '').isNotEmpty)
                        MeshPill(
                          label: 'pty ${activity.processId}',
                          mono: true,
                        ),
                      if (activity.isCommand &&
                          activity.terminalStatus == 'input')
                        const MeshPill(
                          label: 'stdin',
                          tone: MeshPillTone.info,
                          mono: true,
                        ),
                      if (activity.isCommand &&
                          activity.terminalStatus == 'waiting')
                        const MeshPill(
                          label: 'interactive',
                          tone: MeshPillTone.warning,
                          mono: true,
                        ),
                      if (activity.isCommand)
                        ...activity.commandActions.map(
                          (action) => MeshPill(label: action.label, mono: true),
                        ),
                      if (activity.isWebSearch)
                        MeshPill(
                          label: _webSearchKindLabel(activity),
                          tone: MeshPillTone.info,
                          mono: true,
                        ),
                      if (activity.isImageGeneration &&
                          (activity.savedPath ?? '').isNotEmpty)
                        const MeshPill(
                          label: 'saved image',
                          tone: MeshPillTone.info,
                          mono: true,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (activity.isCommand)
                    ..._buildCommandBody(context, activity)
                  else if (activity.isWebSearch) ...[
                    _buildWebSearchBody(context, activity),
                  ] else if (activity.isImageGeneration) ...[
                    _buildImageGenerationBody(context, activity),
                  ] else if (activity.isTurnDiff) ...[
                    if ((activity.diff ?? '').isNotEmpty)
                      _buildLazyDiff(
                        context,
                        label:
                            'Show turn diff (${_diffLineCount(activity.diff!)} lines)',
                        diff: activity.diff!,
                      )
                    else
                      _waitingText(context, 'Waiting for turn diff.'),
                  ] else if (activity.changes.isEmpty) ...[
                    _waitingText(context, 'Waiting for patch details.'),
                  ] else ...[
                    _buildLazyFileChanges(
                      context,
                      changes: activity.changes,
                      sessionCwd: sessionCwd,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildCommandBody(
    BuildContext context,
    SessionActivity activity,
  ) {
    final colors = context.colors;
    final widgets = <Widget>[];

    if ((activity.terminalInput ?? '').isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Sent to terminal',
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ).copyWith(letterSpacing: 0.8),
          ),
        ),
      );
      widgets.add(
        SyntaxCodeBlock(text: activity.terminalInput!, language: 'bash'),
      );
      widgets.add(const SizedBox(height: 12));
    }

    if ((activity.output ?? '').isNotEmpty) {
      final output = activity.output!;
      final lines = output.split('\n');
      final isLong = lines.length > _collapsedLineLimit;
      final displayText = isLong && !_outputExpanded
          ? lines.take(_collapsedLineLimit).join('\n')
          : output;
      widgets.add(SyntaxCodeBlock(text: displayText, language: 'bash'));
      if (isLong) {
        widgets.add(const SizedBox(height: 6));
        widgets.add(
          _ExpandToggle(
            expanded: _outputExpanded,
            hiddenCount: lines.length - _collapsedLineLimit,
            onToggle: () => setState(() => _outputExpanded = !_outputExpanded),
          ),
        );
      }
    } else if (activity.terminalStatus == 'waiting') {
      widgets.add(_waitingText(context, 'Interactive command is running.'));
    } else {
      widgets.add(_waitingText(context, 'Waiting for command output.'));
    }

    return widgets;
  }

  Widget _buildWebSearchBody(BuildContext context, SessionActivity activity) {
    final colors = context.colors;
    final rows = <Widget>[];
    final primaryQuery = (activity.query ?? '').trim();
    final queryList = activity.queries
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final targetUrl = (activity.targetUrl ?? '').trim();
    final pattern = (activity.pattern ?? '').trim();

    if (primaryQuery.isNotEmpty) {
      rows.add(_activityInfoBlock(context, 'Query', primaryQuery));
    }
    if (queryList.isNotEmpty) {
      rows.add(
        _activityInfoBlock(
          context,
          queryList.length > 1 ? 'Queries' : 'Query',
          queryList.join('\n'),
        ),
      );
    }
    if (targetUrl.isNotEmpty) {
      rows.add(
        _activityInfoBlock(
          context,
          pattern.isNotEmpty ? 'Page' : 'URL',
          targetUrl,
          linkify: true,
        ),
      );
    }
    if (pattern.isNotEmpty) {
      rows.add(_activityInfoBlock(context, 'Pattern', pattern));
    }

    if (rows.isEmpty) {
      return _waitingText(context, 'Waiting for search details.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...rows.expand((row) => [row, const SizedBox(height: 10)]),
        Text(
          _webSearchStatusCopy(activity),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  Widget _activityInfoBlock(
    BuildContext context,
    String label,
    String text, {
    bool linkify = false,
  }) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ).copyWith(letterSpacing: 0.8),
          ),
          const SizedBox(height: 6),
          linkify
              ? _LinkifiedSelectableText(
                  text: text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textPrimary,
                    height: 1.4,
                  ),
                  linkColor: colors.accent,
                )
              : SelectableText(
                  text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textPrimary,
                    height: 1.4,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildImageGenerationBody(
    BuildContext context,
    SessionActivity activity,
  ) {
    final colors = context.colors;
    final prompt = (activity.revisedPrompt ?? '').trim();
    final savedPath = (activity.savedPath ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (prompt.isNotEmpty) ...[
          Text(
            'Prompt used',
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ).copyWith(letterSpacing: 0.8),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.border),
            ),
            child: SelectableText(
              prompt,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textPrimary,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (savedPath.isNotEmpty) ...[
          _LocalImageAttachmentTile(
            host: widget.host,
            api: widget.api,
            path: savedPath,
          ),
          const SizedBox(height: 8),
          Text(
            savedPath,
            style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
          ),
        ] else if (activity.status == 'completed') ...[
          _waitingText(
            context,
            'Image completed, but no saved file was reported.',
          ),
        ] else ...[
          _waitingText(context, 'Generating image...'),
        ],
      ],
    );
  }

  String _webSearchTitle(SessionActivity activity) {
    final primaryQuery = (activity.query ?? '').trim();
    final targetUrl = (activity.targetUrl ?? '').trim();
    final pattern = (activity.pattern ?? '').trim();
    if (pattern.isNotEmpty && targetUrl.isNotEmpty) {
      return 'Find "$pattern" in ${_truncateMiddle(targetUrl, 44)}';
    }
    if (targetUrl.isNotEmpty) {
      return 'Open ${_truncateMiddle(targetUrl, 48)}';
    }
    if (primaryQuery.isNotEmpty) {
      return primaryQuery;
    }
    if (activity.queries.isNotEmpty) {
      return activity.queries.first;
    }
    return 'Web search';
  }

  String? _webSearchSubtitle(SessionActivity activity) {
    final queries = activity.queries
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (queries.length > 1) {
      return '${queries.length} related queries';
    }
    final targetUrl = (activity.targetUrl ?? '').trim();
    if (targetUrl.isNotEmpty) {
      return targetUrl;
    }
    final pattern = (activity.pattern ?? '').trim();
    if (pattern.isNotEmpty) {
      return 'Looking for "$pattern"';
    }
    return null;
  }

  String _webSearchKindLabel(SessionActivity activity) {
    final targetUrl = (activity.targetUrl ?? '').trim();
    final pattern = (activity.pattern ?? '').trim();
    if (pattern.isNotEmpty && targetUrl.isNotEmpty) {
      return 'find in page';
    }
    if (targetUrl.isNotEmpty) {
      return 'open page';
    }
    return 'search';
  }

  String _webSearchStatusCopy(SessionActivity activity) {
    if (activity.status == 'completed') {
      return switch (_webSearchKindLabel(activity)) {
        'find in page' => 'Finished searching within a page.',
        'open page' => 'Opened a web page for more detail.',
        _ => 'Finished web search.',
      };
    }
    return 'Web search is running.';
  }

  Widget _waitingText(BuildContext context, String text) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
      ),
    );
  }

  int _diffLineCount(String diff) {
    if (diff.isEmpty) return 0;
    return '\n'.allMatches(diff).length + 1;
  }

  Widget _buildLazyDiff(
    BuildContext context, {
    required String label,
    required String diff,
  }) {
    if (_diffExpanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DiffView(diff: diff),
          const SizedBox(height: 6),
          _DiffToggle(
            expanded: true,
            label: label,
            expandedLabel: 'Hide diff',
            onToggle: () => setState(() => _diffExpanded = false),
          ),
        ],
      );
    }
    return _DiffToggle(
      expanded: false,
      label: label,
      expandedLabel: 'Hide diff',
      onToggle: () => setState(() => _diffExpanded = true),
    );
  }

  Widget _buildLazyFileChanges(
    BuildContext context, {
    required List<SessionActivityChange> changes,
    required String sessionCwd,
  }) {
    final totalLines = changes.fold<int>(
      0,
      (sum, c) => sum + _diffLineCount(c.diff),
    );
    final label = changes.length == 1
        ? 'Show diff ($totalLines lines)'
        : 'Show ${changes.length} file diffs ($totalLines lines)';
    if (_diffExpanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final change in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: _FileChangeBlock(
                change: change,
                sessionCwd: sessionCwd,
                onOpen: _openWorkspaceFile,
              ),
            ),
          _DiffToggle(
            expanded: true,
            label: label,
            expandedLabel: 'Hide diffs',
            onToggle: () => setState(() => _diffExpanded = false),
          ),
        ],
      );
    }
    return _DiffToggle(
      expanded: false,
      label: label,
      expandedLabel: 'Hide diffs',
      onToggle: () => setState(() => _diffExpanded = true),
    );
  }
}

class _InlineFileViewer extends StatefulWidget {
  const _InlineFileViewer({
    required this.host,
    required this.api,
    required this.path,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;

  @override
  State<_InlineFileViewer> createState() => _InlineFileViewerState();
}

class _InlineFileViewerState extends State<_InlineFileViewer> {
  final GlobalKey<FileViewerPaneState> _paneKey =
      GlobalKey<FileViewerPaneState>();
  final ValueNotifier<int> _observable = ValueNotifier<int>(0);

  @override
  void dispose() {
    _observable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final languageId = languageForPath(widget.path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
          child: Row(
            children: [
              Icon(Icons.description_outlined, size: 18, color: colors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      baseName(widget.path),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (languageId != null) ...[
                          MeshPill(label: languageId, mono: true),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            widget.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(
                              color: colors.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              ListenableBuilder(
                listenable: _observable,
                builder: (context, _) =>
                    FileViewerActions(state: _paneKey.currentState),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.border),
        Expanded(
          child: FileViewerPane(
            key: _paneKey,
            host: widget.host,
            api: widget.api,
            path: widget.path,
            observable: _observable,
            dense: true,
          ),
        ),
      ],
    );
  }
}

class _DiffToggle extends StatelessWidget {
  const _DiffToggle({
    required this.expanded,
    required this.label,
    required this.expandedLabel,
    required this.onToggle,
  });

  final bool expanded;
  final String label;
  final String expandedLabel;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: onToggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                expanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                size: 16,
                color: colors.accent,
              ),
              const SizedBox(width: 6),
              Text(
                expanded ? expandedLabel : label,
                style: monoStyle(
                  color: colors.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpandToggle extends StatelessWidget {
  const _ExpandToggle({
    required this.expanded,
    required this.hiddenCount,
    required this.onToggle,
  });

  final bool expanded;
  final int hiddenCount;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.accentMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
              size: 16,
              color: colors.accent,
            ),
            const SizedBox(width: 6),
            Text(
              expanded ? 'Show less' : '+$hiddenCount lines',
              style: monoStyle(
                color: colors.accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileChangeBlock extends StatelessWidget {
  const _FileChangeBlock({
    required this.change,
    required this.sessionCwd,
    this.onOpen,
  });

  final SessionActivityChange change;
  final String sessionCwd;
  final void Function(String path)? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = switch (change.kind) {
      'added' || 'add' || 'create' => MeshPillTone.success,
      'deleted' || 'delete' || 'remove' => MeshPillTone.danger,
      'moved' || 'move' || 'rename' => MeshPillTone.info,
      _ => MeshPillTone.neutral,
    };
    final isDeleted = switch (change.kind) {
      'deleted' || 'delete' || 'remove' => true,
      _ => false,
    };
    final canOpen = onOpen != null && !isDeleted;
    final pathRow = Row(
      children: [
        Icon(Icons.description_outlined, size: 16, color: colors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _relativeSessionPath(change.path, sessionCwd),
            style:
                monoStyle(
                  color: canOpen ? colors.accent : colors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ).copyWith(
                  decoration: canOpen ? TextDecoration.underline : null,
                  decorationColor: canOpen ? colors.accent : null,
                ),
          ),
        ),
        const SizedBox(width: 8),
        MeshPill(label: change.kind, tone: tone, mono: true),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        canOpen
            ? InkWell(
                onTap: () => onOpen!(change.path),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: pathRow,
                ),
              )
            : pathRow,
        if ((change.movePath ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8, left: 24),
            child: Text(
              'Moved from ${_relativeSessionPath(change.movePath!, sessionCwd)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          )
        else
          const SizedBox(height: 8),
        DiffView(diff: change.diff),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ).copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _SessionRuntimeDetails extends StatelessWidget {
  const _SessionRuntimeDetails({required this.runtime});

  final SessionRuntimeSummary runtime;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final details = <({String label, String value})>[
      (label: 'Model', value: runtimeValue(runtime.model)),
      (label: 'Speed', value: runtimeServiceTierValue(runtime.serviceTier)),
      (label: 'Reasoning', value: runtimeValue(runtime.reasoningEffort)),
      (label: 'Approval', value: runtimeValue(runtime.approvalPolicy)),
      (label: 'Sandbox', value: runtimeValue(runtime.sandboxMode)),
      (label: 'Network', value: runtimeNetworkValue(runtime.networkAccess)),
    ];

    if ((runtime.personality ?? '').isNotEmpty) {
      details.add((label: 'Style', value: runtime.personality!));
    }
    if ((runtime.summaryMode ?? '').isNotEmpty) {
      details.add((label: 'Summary', value: runtime.summaryMode!));
    }

    return MeshCard(
      tone: MeshCardTone.muted,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RUNTIME',
            style: monoStyle(
              color: colors.accent,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ).copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: details
                .map(
                  (detail) => Container(
                    constraints: const BoxConstraints(
                      minWidth: 132,
                      maxWidth: 200,
                    ),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detail.label.toUpperCase(),
                          style: monoStyle(
                            color: colors.textSecondary,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                          ).copyWith(letterSpacing: 1.1),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          detail.value,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

String _relativeSessionPath(String fullPath, String sessionCwd) {
  if (fullPath.isEmpty) {
    return fullPath;
  }
  if (fullPath == sessionCwd) {
    return '.';
  }
  final prefix = '$sessionCwd/';
  if (fullPath.startsWith(prefix)) {
    return fullPath.substring(prefix.length);
  }
  return fullPath;
}

String _activityFileSummary(
  List<SessionActivityChange> changes,
  String sessionCwd,
) {
  if (changes.isEmpty) {
    return 'Waiting for patch details.';
  }

  final labels = changes
      .take(3)
      .map((change) => _relativeSessionPath(change.path, sessionCwd))
      .toList();
  final remainder = changes.length - labels.length;
  if (remainder > 0) {
    labels.add('+$remainder more');
  }
  return labels.join('  •  ');
}

String _formatDuration(int durationMs) {
  if (durationMs >= 1000) {
    final seconds = durationMs / 1000;
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}s';
  }
  return '${durationMs}ms';
}

String _commandSourceLabel(String source) {
  return switch (source) {
    'agent' => 'agent',
    'userShell' => 'shell',
    'unifiedExecStartup' => 'exec start',
    'unifiedExecInteraction' => 'exec input',
    _ => source,
  };
}

String _shortId(String value) {
  if (value.length <= 8) {
    return value;
  }
  return value.substring(value.length - 8);
}

class SessionControlsSheet extends StatefulWidget {
  const SessionControlsSheet({
    super.key,
    required this.api,
    required this.host,
    required this.session,
    required this.runtimeModel,
    required this.runtimeServiceTier,
    required this.runtimeReasoningEffort,
    required this.runtimeApproval,
    required this.runtimeSandbox,
    required this.runtimeNetworkAccess,
    required this.policyStore,
    required this.turnConfigStore,
  });

  final ApiClient api;
  final HostProfile host;
  final SessionSummary session;
  final String? runtimeModel;
  final String? runtimeServiceTier;
  final String? runtimeReasoningEffort;
  final ApprovalPolicy? runtimeApproval;
  final SandboxMode? runtimeSandbox;
  final bool? runtimeNetworkAccess;
  final SessionPolicyStore policyStore;
  final SessionTurnConfigStore turnConfigStore;

  @override
  State<SessionControlsSheet> createState() => _SessionControlsSheetState();
}

class _SessionControlsSheetState extends State<SessionControlsSheet> {
  late SessionPolicy _policy;
  late SessionTurnConfig _turnConfig;
  List<ModelCatalogEntry> _models = const <ModelCatalogEntry>[];
  bool _loadingModels = true;
  String? _modelsError;

  @override
  void initState() {
    super.initState();
    _policy = widget.policyStore.policyFor(widget.host, widget.session.id);
    _turnConfig = widget.turnConfigStore.configFor(
      widget.host,
      widget.session.id,
    );
    unawaited(_loadModels());
  }

  ApprovalPolicy get _effectiveApproval =>
      _policy.approval ?? widget.runtimeApproval ?? ApprovalPolicy.untrusted;

  SandboxMode get _effectiveSandbox =>
      _policy.sandbox ?? widget.runtimeSandbox ?? SandboxMode.workspaceWrite;

  bool get _effectiveNetworkOn {
    if (_effectiveSandbox == SandboxMode.dangerFullAccess) return true;
    return _policy.networkAccess ?? widget.runtimeNetworkAccess ?? false;
  }

  bool get _networkToggleDisabled =>
      _effectiveSandbox == SandboxMode.dangerFullAccess;

  bool get _isAutopilot =>
      _effectiveApproval == ApprovalPolicy.never &&
      _effectiveSandbox == SandboxMode.dangerFullAccess;

  String? get _effectiveModelValue {
    final local = _trimmedOrNull(_turnConfig.model);
    if (local != null) {
      return local;
    }
    final runtime = _trimmedOrNull(widget.runtimeModel);
    if (runtime != null) {
      return runtime;
    }
    return _defaultModelEntry?.model;
  }

  ModelCatalogEntry? get _defaultModelEntry {
    for (final model in _models) {
      if (model.isDefault) {
        return model;
      }
    }
    return _models.isEmpty ? null : _models.first;
  }

  ModelCatalogEntry? get _selectedModelEntry =>
      _findModelByName(_effectiveModelValue);

  bool get _selectedModelIsAuto => _selectedModelEntry?.isAutoModel ?? false;

  String get _effectiveModelLabel {
    final selected = _selectedModelEntry;
    if (selected != null) {
      return selected.displayName;
    }
    return _effectiveModelValue ?? 'Use Codex default';
  }

  String get _effectiveModelDescription {
    if (_loadingModels) {
      return 'Loading the available Codex models from this host.';
    }
    if (_modelsError != null) {
      return _modelsError!;
    }
    final selected = _selectedModelEntry;
    if (selected != null && selected.description.trim().isNotEmpty) {
      return selected.description.trim();
    }
    return 'Use the host default model for new turns.';
  }

  String? get _effectiveReasoningEffort {
    final selected = _selectedModelEntry;
    if (selected != null && selected.isAutoModel) {
      return selected.defaultReasoningEffort;
    }
    final local = _trimmedOrNull(_turnConfig.reasoningEffort);
    if (local != null) {
      return local;
    }
    final runtime = _trimmedOrNull(widget.runtimeReasoningEffort);
    if (runtime != null) {
      return runtime;
    }
    return selected?.defaultReasoningEffort;
  }

  List<ModelReasoningEffortOption> get _supportedReasoningOptions {
    final selected = _selectedModelEntry;
    if (selected != null && selected.supportedReasoningEfforts.isNotEmpty) {
      return selected.supportedReasoningEfforts;
    }
    final effective = _effectiveReasoningEffort;
    if (effective == null) {
      return const <ModelReasoningEffortOption>[];
    }
    return <ModelReasoningEffortOption>[
      ModelReasoningEffortOption(
        reasoningEffort: effective,
        description: 'Current thread reasoning effort.',
      ),
    ];
  }

  bool get _selectedModelSupportsFast {
    final selected = _selectedModelEntry;
    if (selected != null) {
      return selected.supportsFastMode;
    }
    return widget.runtimeServiceTier == 'fast';
  }

  bool get _effectiveFastMode {
    final override = _turnConfig.fastMode;
    if (override != null) {
      return override;
    }
    return widget.runtimeServiceTier == 'fast';
  }

  bool get _showFastSection =>
      _selectedModelSupportsFast || widget.runtimeServiceTier == 'fast';

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });

    try {
      final models = await widget.api.fetchModels(widget.host);
      models.sort(_compareModelEntries);
      if (!mounted) {
        return;
      }
      setState(() {
        _models = models;
        _loadingModels = false;
        _modelsError = models.isEmpty
            ? 'Codex did not return any models for this host.'
            : null;
      });
      _coerceTurnConfigForSelectedModel();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingModels = false;
        _modelsError = friendlyError(error);
      });
    }
  }

  void _coerceTurnConfigForSelectedModel() {
    final selected = _selectedModelEntry;
    if (selected == null) {
      return;
    }

    var next = _turnConfig;
    if (selected.isAutoModel && _trimmedOrNull(next.reasoningEffort) != null) {
      next = next.copyWith(reasoningEffort: null);
    } else if (!selected.isAutoModel) {
      final supported = selected.supportedReasoningEfforts
          .map((option) => option.reasoningEffort)
          .toSet();
      final reasoning = _trimmedOrNull(next.reasoningEffort);
      if (reasoning != null && !supported.contains(reasoning)) {
        next = next.copyWith(reasoningEffort: selected.defaultReasoningEffort);
      }
    }

    if (!selected.supportsFastMode && next.fastMode == true) {
      next = next.copyWith(fastMode: false);
    }

    if (!_sameTurnConfig(next, _turnConfig)) {
      setState(() => _turnConfig = next);
    }
  }

  Future<void> _chooseModel() async {
    if (_loadingModels) {
      return;
    }
    if (_models.isEmpty) {
      await _loadModels();
      if (!mounted || _models.isEmpty) {
        return;
      }
    }

    final selected = await showModalBottomSheet<ModelCatalogEntry>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ModelPickerSheet(
        models: _models,
        currentModel: _effectiveModelValue,
      ),
    );
    if (!mounted || selected == null) {
      return;
    }

    _applySelectedModel(selected);
  }

  void _applySelectedModel(ModelCatalogEntry selected) {
    final runtimeModel = _trimmedOrNull(widget.runtimeModel);
    final currentReasoning = _trimmedOrNull(_effectiveReasoningEffort);
    final supported = selected.supportedReasoningEfforts
        .map((option) => option.reasoningEffort)
        .toSet();

    String? nextReasoning;
    if (!selected.isAutoModel) {
      if (currentReasoning != null && supported.contains(currentReasoning)) {
        nextReasoning = currentReasoning;
      } else {
        nextReasoning = selected.defaultReasoningEffort;
      }
    }

    bool? nextFast = _turnConfig.fastMode;
    if (!selected.supportsFastMode && _effectiveFastMode) {
      nextFast = false;
    }

    final nextConfig = SessionTurnConfig(
      model: runtimeModel == selected.model ? null : selected.model,
      reasoningEffort: nextReasoning,
      fastMode: nextFast,
    );

    setState(() {
      _turnConfig = _normalisedTurnConfig(nextConfig, selectedModel: selected);
    });
  }

  Future<void> _save() async {
    final savedPolicy = _policy;
    final savedTurnConfig = _normalisedTurnConfig(_turnConfig);
    await widget.policyStore.setPolicy(
      widget.host,
      widget.session.id,
      savedPolicy,
    );
    await widget.turnConfigStore.setConfig(
      widget.host,
      widget.session.id,
      savedTurnConfig,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    showAppSnackBar(
      context,
      savedPolicy.isEmpty && savedTurnConfig.isEmpty
          ? 'Session will use default controls on your next fresh turn.'
          : 'Applied on your next fresh turn — Codex will remember it.',
    );
  }

  void _reset() {
    setState(() {
      _policy = SessionPolicy.factoryDefaults;
      _turnConfig = _factoryTurnConfig();
    });
  }

  void _applyAutopilot() {
    setState(() {
      _policy = _policy.copyWith(
        approval: ApprovalPolicy.never,
        sandbox: SandboxMode.dangerFullAccess,
        networkAccess: true,
      );
    });
  }

  SessionTurnConfig _factoryTurnConfig() {
    final defaultModel = _defaultModelEntry;
    if (defaultModel == null) {
      return const SessionTurnConfig(fastMode: false);
    }
    return SessionTurnConfig(
      model: defaultModel.model,
      reasoningEffort: defaultModel.isAutoModel
          ? null
          : defaultModel.defaultReasoningEffort,
      fastMode: false,
    );
  }

  SessionTurnConfig _normalisedTurnConfig(
    SessionTurnConfig config, {
    ModelCatalogEntry? selectedModel,
  }) {
    final resolvedModel = _trimmedOrNull(config.model);
    final model =
        selectedModel ?? _findModelByName(resolvedModel ?? widget.runtimeModel);
    var nextModel = resolvedModel;
    var nextReasoning = _trimmedOrNull(config.reasoningEffort);
    var nextFast = config.fastMode;

    final runtimeModel = _trimmedOrNull(widget.runtimeModel);
    final runtimeReasoning = _trimmedOrNull(widget.runtimeReasoningEffort);
    final runtimeFast = widget.runtimeServiceTier == 'fast';

    if (runtimeModel != null && nextModel == runtimeModel) {
      nextModel = null;
    }
    if (model != null && model.isAutoModel) {
      nextReasoning = null;
    }
    if (model != null && !model.supportsFastMode && nextFast == true) {
      nextFast = false;
    }
    if (nextModel == null &&
        runtimeReasoning != null &&
        nextReasoning == runtimeReasoning) {
      nextReasoning = null;
    }
    if (nextModel == null && nextFast != null && nextFast == runtimeFast) {
      nextFast = null;
    }

    return SessionTurnConfig(
      model: nextModel,
      reasoningEffort: nextReasoning,
      fastMode: nextFast,
    );
  }

  ModelCatalogEntry? _findModelByName(String? value) {
    final modelId = _trimmedOrNull(value);
    if (modelId == null) {
      return _defaultModelEntry;
    }
    for (final model in _models) {
      if (model.model == modelId) {
        return model;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final selectedModel = _selectedModelEntry;
    final effectiveReasoning = _effectiveReasoningEffort;
    String? reasoningDescription;
    for (final option in _supportedReasoningOptions) {
      if (option.reasoningEffort == effectiveReasoning) {
        reasoningDescription = option.description;
        break;
      }
    }

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.tune_rounded, color: colors.accent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Session controls',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Change how Codex handles the model, thinking effort, Fast mode, approvals, file access and network for this session. Applied on your next fresh turn. If Codex is already responding, these changes wait until the current turn finishes.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Model & thinking',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              _ModelSelectionCard(
                title: 'Model',
                value: _effectiveModelLabel,
                subtitle: _effectiveModelDescription,
                loading: _loadingModels,
                error: _modelsError,
                currentValue: _turnConfig.model != null
                    ? widget.runtimeModel
                    : null,
                badges: <String>[
                  if (selectedModel?.isAutoModel ?? false) 'auto',
                  if (selectedModel?.isDefault ?? false) 'default',
                  if (_turnConfig.model != null) 'next turn',
                ],
                onTap: _chooseModel,
                onRetry: () {
                  unawaited(_loadModels());
                },
              ),
              const SizedBox(height: 18),
              Text(
                'Reasoning effort',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              if (_loadingModels && _models.isEmpty)
                const LinearProgressIndicator(minHeight: 3)
              else if (_selectedModelIsAuto)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.border),
                  ),
                  child: Text(
                    'Auto models choose the thinking effort themselves. Codex will use ${_reasoningEffortLabel(effectiveReasoning ?? selectedModel?.defaultReasoningEffort ?? 'medium')}.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                )
              else if (_supportedReasoningOptions.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.border),
                  ),
                  child: Text(
                    'This model does not expose adjustable thinking effort in Codex.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                )
              else ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _supportedReasoningOptions.map((option) {
                    final isDefault =
                        selectedModel != null &&
                        option.reasoningEffort ==
                            selectedModel.defaultReasoningEffort;
                    final selected =
                        option.reasoningEffort == effectiveReasoning;
                    return _ReasoningChoiceChip(
                      label: _reasoningEffortLabel(option.reasoningEffort),
                      selected: selected,
                      isDefault: isDefault,
                      onTap: () {
                        setState(() {
                          _turnConfig = _normalisedTurnConfig(
                            _turnConfig.copyWith(
                              reasoningEffort: option.reasoningEffort,
                            ),
                          );
                        });
                      },
                    );
                  }).toList(),
                ),
                if (reasoningDescription != null &&
                    reasoningDescription.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    reasoningDescription.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
              if (_showFastSection) ...[
                const SizedBox(height: 18),
                Text(
                  'Speed',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.textSecondary,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 8),
                _FastModeTile(
                  value: _effectiveFastMode,
                  enabled: _selectedModelSupportsFast,
                  onChanged: (value) {
                    setState(() {
                      _turnConfig = _normalisedTurnConfig(
                        _turnConfig.copyWith(fastMode: value),
                      );
                    });
                  },
                ),
              ],
              const SizedBox(height: 18),
              _PolicyAutopilotCard(
                active: _isAutopilot,
                onTap: _applyAutopilot,
                colors: colors,
              ),
              const SizedBox(height: 22),
              Text(
                'Approval policy',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              for (final policy in ApprovalPolicy.values)
                _PolicyRadioTile<ApprovalPolicy>(
                  value: policy,
                  groupValue: _effectiveApproval,
                  title: policy.label,
                  subtitle: policy.description,
                  fromRuntime:
                      _policy.approval == null &&
                      widget.runtimeApproval == policy,
                  onSelected: (value) {
                    setState(() {
                      _policy = _policy.copyWith(approval: value);
                    });
                  },
                ),
              const SizedBox(height: 18),
              Text(
                'Sandbox',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              for (final sandbox in SandboxMode.values)
                _PolicyRadioTile<SandboxMode>(
                  value: sandbox,
                  groupValue: _effectiveSandbox,
                  title: sandbox.label,
                  subtitle: sandbox.description,
                  fromRuntime:
                      _policy.sandbox == null &&
                      widget.runtimeSandbox == sandbox,
                  danger: sandbox == SandboxMode.dangerFullAccess,
                  onSelected: (value) {
                    setState(() {
                      _policy = _policy.copyWith(sandbox: value);
                    });
                  },
                ),
              const SizedBox(height: 18),
              Text(
                'Network',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colors.textSecondary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              _PolicyNetworkTile(
                value: _effectiveNetworkOn,
                disabled: _networkToggleDisabled,
                subtitle: _networkToggleDisabled
                    ? 'Full access already grants network. Toggle locked.'
                    : (_effectiveSandbox == SandboxMode.workspaceWrite ||
                          _effectiveSandbox == SandboxMode.readOnly)
                    ? 'Allow outbound network for tools like gh, curl, pip. Off by default for read-only / workspace-write.'
                    : 'Allow outbound network.',
                onChanged: (value) {
                  setState(() {
                    _policy = _policy.copyWith(networkAccess: value);
                  });
                },
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Reset to defaults'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelSelectionCard extends StatelessWidget {
  const _ModelSelectionCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.loading,
    required this.error,
    required this.currentValue,
    required this.badges,
    required this.onTap,
    required this.onRetry,
  });

  final String title;
  final String value;
  final String subtitle;
  final bool loading;
  final String? error;
  final String? currentValue;
  final List<String> badges;
  final VoidCallback onTap;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: colors.textSecondary,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  value,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                ...badges.map((badge) => _InlineBadge(label: badge)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
            if ((currentValue ?? '').trim().isNotEmpty &&
                currentValue!.trim() != value.trim()) ...[
              const SizedBox(height: 8),
              Text(
                'Current thread: ${currentValue!.trim()}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry loading models'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasoningChoiceChip extends StatelessWidget {
  const _ReasoningChoiceChip({
    required this.label,
    required this.selected,
    required this.isDefault,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool isDefault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? colors.accentMuted.withValues(alpha: 0.55) : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? colors.accent : colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (isDefault) ...[
              const SizedBox(width: 8),
              const _InlineBadge(label: 'default'),
            ],
          ],
        ),
      ),
    );
  }
}

class _FastModeTile extends StatelessWidget {
  const _FastModeTile({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: value ? colors.accentMuted.withValues(alpha: 0.45) : null,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: value ? colors.accent : colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.bolt_rounded,
            size: 20,
            color: value ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fast mode',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled
                      ? 'Ask Codex for the fast service tier on your next fresh turn.'
                      : 'This model does not advertise Fast mode in Codex.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: enabled ? onChanged : null),
        ],
      ),
    );
  }
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({required this.models, required this.currentModel});

  final List<ModelCatalogEntry> models;
  final String? currentModel;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final TextEditingController _queryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_handleQueryChanged);
  }

  @override
  void dispose() {
    _queryController
      ..removeListener(_handleQueryChanged)
      ..dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final query = _queryController.text.trim().toLowerCase();
    final filtered = widget.models
        .where((model) {
          if (query.isEmpty) {
            return true;
          }
          final haystack = [
            model.displayName,
            model.model,
            model.description,
          ].join('\n').toLowerCase();
          return haystack.contains(query);
        })
        .toList(growable: false);

    return FractionallySizedBox(
      heightFactor: 0.82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose model',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Pick the model for your next fresh turn. Auto models stay simple; specific models let you adjust thinking effort.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _queryController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search models',
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No models match that search.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final model = filtered[index];
                        final isCurrent =
                            model.model == _trimmedOrNull(widget.currentModel);
                        return InkWell(
                          onTap: () => Navigator.of(context).pop(model),
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: colors.surfaceMuted,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isCurrent
                                    ? colors.accent
                                    : colors.border,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        model.displayName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ),
                                    if (isCurrent)
                                      const _InlineBadge(label: 'current'),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  model.model,
                                  style: monoStyle(
                                    color: colors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (model.isAutoModel)
                                      const _InlineBadge(label: 'auto'),
                                    if (model.isDefault)
                                      const _InlineBadge(label: 'default'),
                                    if (model.supportsFastMode)
                                      const _InlineBadge(label: 'fast'),
                                    ...model.supportedReasoningEfforts
                                        .take(3)
                                        .map(
                                          (option) => _InlineBadge(
                                            label: _reasoningEffortLabel(
                                              option.reasoningEffort,
                                            ),
                                          ),
                                        ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  model.description,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colors.textSecondary,
                                        height: 1.35,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineBadge extends StatelessWidget {
  const _InlineBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _PolicyAutopilotCard extends StatelessWidget {
  const _PolicyAutopilotCard({
    required this.active,
    required this.onTap,
    required this.colors,
  });

  final bool active;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final border = active ? colors.accent : colors.border;
    final bg = active ? colors.accentMuted : colors.surfaceMuted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome_rounded, color: colors.accent, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Autopilot — never ask again',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Approval = never · Sandbox = full access · Network = on. Codex runs without pausing for approvals and can hit the internet.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle_rounded, color: colors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}

class _PolicyNetworkTile extends StatelessWidget {
  const _PolicyNetworkTile({
    required this.value,
    required this.disabled,
    required this.subtitle,
    required this.onChanged,
  });

  final bool value;
  final bool disabled;
  final String subtitle;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: value ? colors.accentMuted.withValues(alpha: 0.45) : null,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: value ? colors.accent : colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            value ? Icons.public_rounded : Icons.public_off_rounded,
            size: 20,
            color: value ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Allow outbound network',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
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
          Switch(value: value, onChanged: disabled ? null : onChanged),
        ],
      ),
    );
  }
}

class _PolicyRadioTile<T> extends StatelessWidget {
  const _PolicyRadioTile({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.onSelected,
    this.fromRuntime = false,
    this.danger = false,
  });

  final T value;
  final T groupValue;
  final String title;
  final String subtitle;
  final bool fromRuntime;
  final bool danger;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = value == groupValue;
    final accent = danger ? colors.danger : colors.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => onSelected(value),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted.withValues(alpha: 0.55) : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? accent : colors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? accent : colors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
                                ),
                          ),
                        ),
                        if (fromRuntime)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surfaceMuted,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: colors.border),
                            ),
                            child: Text(
                              'current',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: colors.textSecondary,
                                    letterSpacing: 0.4,
                                  ),
                            ),
                          ),
                      ],
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
          ),
        ),
      ),
    );
  }
}

int _compareModelEntries(ModelCatalogEntry left, ModelCatalogEntry right) {
  final rank = _modelSortRank(left).compareTo(_modelSortRank(right));
  if (rank != 0) {
    return rank;
  }
  if (left.isDefault != right.isDefault) {
    return left.isDefault ? -1 : 1;
  }
  final leftName = '${left.displayName}\n${left.model}'.toLowerCase();
  final rightName = '${right.displayName}\n${right.model}'.toLowerCase();
  return leftName.compareTo(rightName);
}

int _modelSortRank(ModelCatalogEntry model) {
  if (!model.isAutoModel) {
    return 10;
  }
  return switch (model.model) {
    'codex-auto-fast' => 0,
    'codex-auto-balanced' => 1,
    'codex-auto-thorough' => 2,
    _ => 3,
  };
}

String _reasoningEffortLabel(String value) {
  return switch (value) {
    'none' => 'None',
    'minimal' => 'Minimal',
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' => 'Extra high',
    _ => value,
  };
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

bool _sameTurnConfig(SessionTurnConfig left, SessionTurnConfig right) {
  return left.model == right.model &&
      left.reasoningEffort == right.reasoningEffort &&
      left.fastMode == right.fastMode;
}

bool _sameCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatMessageTime(DateTime value) {
  final now = DateTime.now();
  final time =
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  if (_sameCalendarDay(value, now)) {
    return time;
  }
  final diffDays = now.difference(value).inDays;
  if (diffDays < 7 && diffDays >= 0) {
    return '${_weekdayShort(value.weekday)} · $time';
  }
  if (value.year == now.year) {
    return '${_monthShort(value.month)} ${value.day} · $time';
  }
  return '${_monthShort(value.month)} ${value.day} ${value.year}';
}

String _formatDaySeparator(DateTime value) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(value.year, value.month, value.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (value.year == now.year) {
    return '${_weekdayShort(value.weekday)}, ${_monthShort(value.month)} ${value.day}';
  }
  return '${_monthShort(value.month)} ${value.day}, ${value.year}';
}

String _weekdayShort(int weekday) {
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return names[(weekday - 1).clamp(0, 6)];
}

String _monthShort(int month) {
  const names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return names[(month - 1).clamp(0, 11)];
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Divider(color: colors.border, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.textTertiary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Expanded(child: Divider(color: colors.border, height: 1)),
        ],
      ),
    );
  }
}

