import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/io.dart';

import '../api_client.dart';
import '../models.dart';
import 'file_browser_screen.dart';
import '../session_favorites_store.dart';
import '../session_overrides_store.dart';
import '../session_policy_store.dart';
import '../session_read_store.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
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

  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;
  final SessionPolicyStore _policyStore = SessionPolicyStore.instance;
  final SessionReadStore _readStore = SessionReadStore.instance;
  final StringBuffer _assistantDeltaBuffer = StringBuffer();
  final Map<String, SessionActivity> _pendingActivityUpdates =
      <String, SessionActivity>{};

  // Live-streaming state is held in notifiers so that mid-stream deltas only
  // rebuild the tiny widgets that display them, not the whole Scaffold/list.
  final ValueNotifier<String> _liveAssistantNotifier = ValueNotifier<String>(
    '',
  );
  final ValueNotifier<bool> _thinkingNotifier = ValueNotifier<bool>(false);

  SessionSummary? _session;
  List<SessionMessage> _messages = const [];
  List<SessionMessage> _optimisticMessages = const [];
  List<SessionActivity> _activities = const [];
  SessionLogHistorySummary? _history;
  PendingAction? _pendingAction;
  int _messageLimit = _initialMessageLimit;
  int _activityLimit = _initialActivityLimit;
  bool _running = false;
  bool _loading = true;
  bool _loadingOlderHistory = false;
  bool _sending = false;
  bool _awaitingAssistantReply = false;
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _liveFlushTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;
  int? _lastEventSeq;
  // Incremented whenever a fresh snapshot is requested so in-flight responses
  // from older requests can be discarded.
  int _snapshotRequestId = 0;
  // Buffer live events that arrive while a snapshot is in flight so we can
  // replay them after the snapshot's setState runs — prevents a stale
  // snapshot from clobbering an already-delivered action_opened / activity.
  final List<LiveEvent> _pendingLiveEvents = <LiveEvent>[];
  bool _snapshotInFlight = false;

  // Memoized timeline entries so rebuilds that don't change list inputs skip
  // the list+sort work.
  List<SessionMessage>? _entriesMessagesRef;
  List<SessionMessage>? _entriesOptimisticRef;
  List<SessionActivity>? _entriesActivitiesRef;
  List<_TimelineEntry> _cachedEntries = const [];

  String get _liveAssistantText => _liveAssistantNotifier.value;
  // Surfaces a "↓ New" pill when the user has scrolled away from the
  // bottom of the transcript so they can jump back to the live area.
  final ValueNotifier<bool> _showJumpToLatest = ValueNotifier<bool>(false);

  // Tracks which old-snapshot history banners the user has dismissed
  // this session. Reset whenever a brand-new snapshot arrives so the
  // banner can reappear if the truncation window changes.
  bool _historyBannerDismissed = false;

  set _liveAssistantText(String value) => _liveAssistantNotifier.value = value;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _favorites.ensureLoaded();
    _policyStore.ensureLoaded();
    _readStore.ensureLoaded();
    _session = widget.session;
    _scrollController.addListener(_onTranscriptScroll);
    _markCurrentSessionSeen();
    _loadSnapshot();
    _connectLive();
  }

  void _markCurrentSessionSeen() {
    final session = _session ?? widget.session;
    _readStore.markSeen(widget.host, session.id, session.updatedAt);
  }

  @override
  void dispose() {
    _disposed = true;
    // Stamp the most recent session state as seen before we unmount so
    // anything that streamed in during the last turn counts as read on
    // the way out.
    _markCurrentSessionSeen();
    unawaited(_readStore.flush());
    WidgetsBinding.instance.removeObserver(this);
    _reconnectTimer?.cancel();
    _composerController.dispose();
    _scrollController.removeListener(_onTranscriptScroll);
    _scrollController.dispose();
    _subscription?.cancel();
    _liveFlushTimer?.cancel();
    _channel?.sink.close();
    _liveAssistantNotifier.dispose();
    _thinkingNotifier.dispose();
    _showJumpToLatest.dispose();
    super.dispose();
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
        _awaitingAssistantReply =
            log.session.isActive &&
            _liveAssistantText.isEmpty &&
            _pendingAction == null;
        if (!_running) {
          _liveAssistantText = '';
        }
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
        if (delta.session != null) {
          _session = delta.session!;
          _running = delta.session!.isActive;
        }
        if (delta.messages.isNotEmpty) {
          final byId = <String, SessionMessage>{
            for (final m in _messages) m.id: m,
          };
          for (final m in delta.messages) {
            byId[m.id] = m;
          }
          final merged = byId.values.toList()
            ..sort((a, b) {
              if (a.seq != b.seq) return a.seq.compareTo(b.seq);
              return a.createdAt.compareTo(b.createdAt);
            });
          _messages = merged;
          _optimisticMessages = _reconcileOptimisticMessages(merged);
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
        _pendingAction = delta.pendingAction ?? _pendingAction;
        if (delta.nextSeq > (_lastEventSeq ?? 0)) {
          _lastEventSeq = delta.nextSeq;
        }
      });
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
        _thinkingNotifier.value = _shouldShowThinking();
        _scrollToBottomFast();
      case 'turn_started':
        setState(() {
          _running = true;
          _awaitingAssistantReply =
              _liveAssistantText.isEmpty && _pendingAction == null;
        });
        _thinkingNotifier.value = _shouldShowThinking();
      case 'assistant_delta':
        final delta = event.delta;
        if (delta == null || delta.isEmpty) {
          return;
        }
        _assistantDeltaBuffer.write(delta);
        _scheduleLiveFlush();
      case 'turn_completed':
        _flushPendingLiveUpdates();
        final committedLive = _liveAssistantText;
        setState(() {
          _running = false;
          _awaitingAssistantReply = false;
          if (committedLive.isNotEmpty) {
            final turnId = event.turnId ?? 'turn';
            final nextSeq = _nextTimelineSeq();
            final finalMsg = SessionMessage(
              id: 'local-final-$turnId',
              role: 'assistant',
              text: committedLive,
              createdAt: DateTime.now(),
              seq: nextSeq,
              phase: 'final_answer',
            );
            _upsertOptimisticMessage(finalMsg);
            _liveAssistantText = '';
          }
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
        _thinkingNotifier.value = _shouldShowThinking();
      case 'action_resolved':
        setState(() {
          _pendingAction = null;
          _awaitingAssistantReply = _running && _liveAssistantText.isEmpty;
        });
        _thinkingNotifier.value = _shouldShowThinking();
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

    // Apply live delta without a full setState; the live bubble is wired to
    // _liveAssistantNotifier and will rebuild on its own.
    if (hasDelta) {
      _running = true;
      _awaitingAssistantReply = false;
      _liveAssistantText += delta;
      _thinkingNotifier.value = false;
    }

    if (activities.isNotEmpty) {
      setState(() {
        for (final activity in activities) {
          _upsertActivity(activity);
        }
      });
    }
    _scrollToBottomFast();
  }

  Future<void> _sendInput() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) {
      return;
    }

    final wasRunning = _running;
    final optimisticMessage = SessionMessage(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      role: 'user',
      text: text,
      createdAt: DateTime.now(),
      seq: _nextTimelineSeq(),
    );

    _composerController.clear();
    setState(() {
      _sending = true;
      _running = true;
      _awaitingAssistantReply = true;
      _liveAssistantText = '';
      _upsertOptimisticMessage(optimisticMessage);
    });
    _thinkingNotifier.value = _shouldShowThinking();
    _scrollToBottomFast(force: true);
    try {
      final policy = _policyStore.policyFor(widget.host, widget.session.id);
      await widget.api.sendInput(
        widget.host,
        sessionId: widget.session.id,
        text: text,
        clientMessageId: optimisticMessage.id,
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
      showAppSnackBar(context, "Failed to send: ${friendlyError(error)}");
      setState(() {
        _optimisticMessages = _optimisticMessages
            .where((message) => message.id != optimisticMessage.id)
            .toList();
        _running = wasRunning;
        _awaitingAssistantReply =
            wasRunning && _liveAssistantText.isEmpty && !stillHasPending;
      });
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
      });
      showAppSnackBar(context, 'Session stopped.',
          duration: const Duration(seconds: 2));
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
      showAppSnackBar(
        context,
        label,
        duration: const Duration(seconds: 2),
      );
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
    if (!mounted) return;
    final runtime = session.runtime;
    final isDesktop = widget.topPadding != null;
    final sheet = SessionPolicySheet(
      host: widget.host,
      session: session,
      runtimeApproval: ApprovalPolicy.fromWire(runtime?.approvalPolicy),
      runtimeSandbox: SandboxMode.fromWire(runtime?.sandboxMode),
      runtimeNetworkAccess: runtime?.networkAccess,
      store: _policyStore,
    );
    if (isDesktop) {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.black.withValues(alpha: 0.35),
        builder: (dialogContext) => Dialog(
          backgroundColor: context.colors.surface,
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
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
    FocusManager.instance.primaryFocus?.unfocus();
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
    // Memoize: if message/activity/optimistic list identities are unchanged,
    // reuse the previous entries (skip the sort).
    if (identical(_entriesMessagesRef, _messages) &&
        identical(_entriesOptimisticRef, _optimisticMessages) &&
        identical(_entriesActivitiesRef, _activities)) {
      return _cachedEntries;
    }

    final entries =
        <_TimelineEntry>[
          ..._messages.map(_TimelineEntry.message),
          ..._optimisticMessages.map(_TimelineEntry.message),
          ..._activities.map(_TimelineEntry.activity),
        ]..sort((left, right) {
          final bySeq = left.seq.compareTo(right.seq);
          if (bySeq != 0) return bySeq;
          return left.createdAt.compareTo(right.createdAt);
        });

    _entriesMessagesRef = _messages;
    _entriesOptimisticRef = _optimisticMessages;
    _entriesActivitiesRef = _activities;
    _cachedEntries = entries;
    return entries;
  }

  bool _matchesPersistedMessage(
    SessionMessage persisted,
    SessionMessage optimistic,
  ) {
    return persisted.role == optimistic.role &&
        persisted.text.trim() == optimistic.text.trim() &&
        (persisted.createdAt.difference(optimistic.createdAt).inSeconds)
                .abs() <=
            90;
  }

  @override
  Widget build(BuildContext context) {
    final session = _session ?? widget.session;
    final colors = context.colors;
    final timelineEntries = _buildTimelineEntries();
    final scaffold = Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
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
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ListenableBuilder(
              listenable: _policyStore,
              builder: (context, _) {
                final policy = _policyStore.policyFor(widget.host, session.id);
                final runtime = session.runtime;
                final runtimeLoosened = SessionPolicy.runtimeIsLoosened(
                  approvalPolicy: runtime?.approvalPolicy,
                  sandboxMode: runtime?.sandboxMode,
                  networkAccess: runtime?.networkAccess,
                );
                final customised = !policy.isEmpty || runtimeLoosened;
                return MeshIconButton(
                  icon: customised
                      ? Icons.tune_rounded
                      : Icons.tune_outlined,
                  tooltip: 'Approval & sandbox',
                  color: customised
                      ? colors.accent
                      : colors.textSecondary,
                  onTap: () => _showSessionPolicySheet(session),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: ListenableBuilder(
              listenable: _favorites,
              builder: (context, _) {
                final favorite = _favorites.isFavorite(widget.host, session.id);
                return MeshIconButton(
                  icon: favorite
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  tooltip: favorite ? 'Remove favorite' : 'Add favorite',
                  color: favorite ? colors.warning : colors.textSecondary,
                  onTap: _toggleFavorite,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: MeshIconButton(
              icon: Icons.folder_outlined,
              tooltip: 'Browse files',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => FileBrowserScreen(
                    host: widget.host,
                    api: widget.api,
                    root: session.cwd,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: MeshIconButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Reload',
              onTap: _loadSnapshot,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Session actions',
            icon: Icon(Icons.more_vert_rounded, color: colors.textPrimary),
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  _renameSession();
                  break;
                case 'archive':
                  _archiveSession();
                  break;
              }
            },
            itemBuilder: (context) => [
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
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _dismissKeyboard,
        child: Column(
          children: [
            ListenableBuilder(
              listenable: _favorites,
              builder: (context, _) {
                final isCompact = MediaQuery.of(context).size.width < 600;
                final favorite = _favorites.isFavorite(widget.host, session.id);
                if (isCompact) {
                  return _SessionHeaderStrip(
                    host: widget.host,
                    session: session,
                    running: _running,
                    favorite: favorite,
                    onDetails: () => _showSessionDetailsSheet(session),
                  );
                }
                return _SessionHeader(
                  host: widget.host,
                  session: session,
                  running: _running,
                  favorite: favorite,
                  onDetails: () => _showSessionDetailsSheet(session),
                );
              },
            ),
            if ((_history?.isTruncated ?? false) && !_historyBannerDismissed)
              Dismissible(
                key: ValueKey('history_banner_${session.id}'),
                direction: DismissDirection.horizontal,
                onDismissed: (_) {
                  setState(() => _historyBannerDismissed = true);
                },
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _HistoryTruncationCard(
                    history: _history!,
                    loading: _loadingOlderHistory,
                    onLoadOlderHistory: _loadOlderTranscript,
                  ),
                ),
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
                              padding:
                                  const EdgeInsets.fromLTRB(16, 6, 16, 12),
                              physics:
                                  const AlwaysScrollableScrollPhysics(),
                              itemCount: timelineEntries.length + 1,
                              itemBuilder: (context, index) {
                              if (index == 0) {
                                return KeyedSubtree(
                                  key: const ValueKey('__live_stream__'),
                                  child: _LiveStreamArea(
                                    liveText: _liveAssistantNotifier,
                                    thinking: _thinkingNotifier,
                                  ),
                                );
                              }
                              final entry = timelineEntries[timelineEntries
                                      .length -
                                  index];
                              return KeyedSubtree(
                                key: ValueKey(entry.keyId),
                                child: switch (entry.kind) {
                                  _TimelineEntryKind.message => _MessageBubble(
                                    message: entry.message!,
                                  ),
                                  _TimelineEntryKind.activity => _ActivityCard(
                                    activity: entry.activity!,
                                    sessionCwd: session.cwd,
                                    defaultCollapsed: widget.topPadding == null,
                                  ),
                                  _TimelineEntryKind.thinking =>
                                    const _ThinkingBubble(),
                                  _TimelineEntryKind.liveAssistant =>
                                    const SizedBox.shrink(),
                                },
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
            _Composer(
              controller: _composerController,
              sending: _sending,
              onSend: _sendInput,
              onDismiss: _dismissKeyboard,
              submitOnEnter: widget.topPadding != null,
            ),
          ],
        ),
      ),
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
    required this.running,
    required this.favorite,
    required this.onDetails,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool running;
  final bool favorite;
  final VoidCallback onDetails;

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
                    style: monoStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  if (_metaLine(session).isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      _metaLine(session),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(
                        color: colors.textTertiary,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDetails,
              icon: Icon(
                Icons.tune_rounded,
                size: 18,
                color: colors.accent,
              ),
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

  static String _metaLine(SessionSummary session) {
    final parts = <String>[session.source];
    final model = session.runtime?.model;
    if (model != null && model.isNotEmpty) parts.add(model);
    final approval = session.runtime?.approvalPolicy;
    if (approval != null && approval.isNotEmpty) {
      parts.add('approval $approval');
    }
    return parts.join(' · ');
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

class _SessionHeaderStrip extends StatelessWidget {
  const _SessionHeaderStrip({
    required this.host,
    required this.session,
    required this.running,
    required this.favorite,
    required this.onDetails,
  });

  final HostProfile host;
  final SessionSummary session;
  final bool running;
  final bool favorite;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
      child: InkWell(
        onTap: onDetails,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            children: [
              _HeaderStatusDot(
                color: running ? colors.success : colors.textTertiary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '  ·  ',
                style: monoStyle(
                  color: colors.textTertiary,
                  fontSize: 11.5,
                ),
              ),
              Flexible(
                flex: 2,
                child: Text(
                  session.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    color: colors.textTertiary,
                    fontSize: 11.5,
                  ),
                ),
              ),
              if (favorite) ...[
                const SizedBox(width: 6),
                Icon(Icons.star_rounded, size: 13, color: colors.warning),
              ],
              const SizedBox(width: 6),
              Icon(
                Icons.tune_rounded,
                size: 14,
                color: colors.accent,
              ),
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
  });

  final SessionLogHistorySummary history;
  final bool loading;
  final VoidCallback onLoadOlderHistory;

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
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
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
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onDismiss,
    this.submitOnEnter = false,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onDismiss;
  final bool submitOnEnter;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget field = TextField(
      controller: controller,
      minLines: 1,
      maxLines: 6,
      onTapOutside: (_) => onDismiss(),
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: submitOnEnter
            ? 'Message this session — Enter to send, Shift+Enter for newline'
            : 'Message this session',
        hintStyle: TextStyle(color: colors.textTertiary),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
    if (submitOnEnter) {
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
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: colors.composerBackground,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: colors.border),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                child: field,
              ),
            ),
            const SizedBox(width: 10),
            _SendButton(sending: sending, onSend: onSend),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.sending, required this.onSend});

  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: sending ? null : onSend,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: sending ? colors.surfaceMuted : colors.accent,
            borderRadius: BorderRadius.circular(18),
            boxShadow: sending
                ? const []
                : [
                    BoxShadow(
                      color: colors.accent.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
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
              : Icon(Icons.arrow_upward_rounded, color: colors.accentOn),
        ),
      ),
    );
  }
}

enum _TimelineEntryKind { message, activity, thinking, liveAssistant }

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

  final _TimelineEntryKind kind;
  final DateTime createdAt;
  final int seq;
  final String keyId;
  final SessionMessage? message;
  final SessionActivity? activity;
}

class _LiveStreamArea extends StatelessWidget {
  const _LiveStreamArea({required this.liveText, required this.thinking});

  final ValueListenable<String> liveText;
  final ValueListenable<bool> thinking;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: liveText,
      builder: (context, text, _) {
        if (text.isNotEmpty) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _MessageBubble(
              message: SessionMessage(
                id: 'live',
                role: 'assistant',
                text: text,
                createdAt: DateTime.now(),
                seq: 1 << 30,
                phase: 'commentary',
              ),
              live: true,
            ),
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: thinking,
          builder: (context, show, _) {
            if (!show) return const SizedBox.shrink();
            return const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: _ThinkingBubble(),
            );
          },
        );
      },
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LivePulse(),
              const SizedBox(width: 10),
              Text(
                'Thinking…',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.live = false});

  final SessionMessage message;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isUser = message.role == 'user';
    final isAssistant = message.role == 'assistant';

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
                  if (isAssistant)
                    _MarkdownMessageBody(
                      text: message.text,
                      textColor: textColor,
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
                  if (message.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Align(
                        alignment: isUser
                            ? Alignment.centerLeft
                            : Alignment.centerRight,
                        child: _MessageCopyButton(
                          text: message.text,
                          tone: isUser
                              ? colors.userBubbleOn.withValues(alpha: 0.75)
                              : colors.textSecondary,
                          accent: colors.accent,
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

class _MarkdownMessageBody extends StatelessWidget {
  const _MarkdownMessageBody({required this.text, required this.textColor});

  final String text;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final baseBody = theme.textTheme.bodyMedium?.copyWith(
      color: textColor,
      height: 1.5,
    );

    return GptMarkdown(
      text,
      style: baseBody,
      followLinkColor: false,
      onLinkTap: (href, title) {
        if (href.isEmpty) return;
        _openLink(context, href);
      },
      linkBuilder: (context, linkText, url, style) {
        return Text.rich(
          TextSpan(
            children: [linkText],
            style: (style).copyWith(
              color: colors.accent,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      },
      codeBuilder: (context, name, code, closed) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SyntaxCodeBlock(
            text: code.trimRight(),
            language: name.isEmpty ? null : name,
          ),
        );
      },
      highlightBuilder: (context, hlText, style) {
        return Text(
          hlText,
          style: monoStyle(
            color: colors.accent,
            fontSize: 12.5,
          ),
        );
      },
    );
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

// Matches http(s)://… and www.… URLs. Conservative trailing punctuation trim
// happens in _buildLinkSpans below.
final RegExp _urlRegExp = RegExp(
  r'(https?:\/\/[^\s<>]+|www\.[^\s<>]+)',
  caseSensitive: false,
);

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

    return SelectableText.rich(
      TextSpan(style: widget.style, children: spans),
    );
  }
}

class _ActivityCard extends StatefulWidget {
  const _ActivityCard({
    required this.activity,
    required this.sessionCwd,
    this.defaultCollapsed = false,
  });

  final SessionActivity activity;
  final String sessionCwd;
  final bool defaultCollapsed;

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> {
  static const _collapsedLineLimit = 15;
  bool _outputExpanded = false;
  bool _diffExpanded = false;
  late bool _cardCollapsed = widget.defaultCollapsed;

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
      _ => 'Activity',
    };

    final subtitle = switch (activity.type) {
      'command' => _relativeSessionPath(activity.cwd ?? sessionCwd, sessionCwd),
      'file_change' => _activityFileSummary(activity.changes, sessionCwd),
      'turn_diff' => 'Aggregated patch snapshot for this turn',
      _ => null,
    };

    final activityLabel = switch (activity.type) {
      'command' => 'COMMAND',
      'file_change' => 'FILE CHANGE',
      'turn_diff' => 'TURN DIFF',
      _ => 'ACTIVITY',
    };

    final activityIcon = switch (activity.type) {
      'command' => Icons.terminal_rounded,
      'file_change' => Icons.edit_note_rounded,
      'turn_diff' => Icons.difference_rounded,
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
                    setState(() => _cardCollapsed = !_cardCollapsed);
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
                      MeshPill(label: 'pty ${activity.processId}', mono: true),
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
                  ],
                ),
                const SizedBox(height: 12),
                if (activity.isCommand)
                  ..._buildCommandBody(context, activity)
                else if (activity.isTurnDiff) ...[
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
  const _FileChangeBlock({required this.change, required this.sessionCwd});

  final SessionActivityChange change;
  final String sessionCwd;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = switch (change.kind) {
      'added' || 'add' || 'create' => MeshPillTone.success,
      'deleted' || 'delete' || 'remove' => MeshPillTone.danger,
      'moved' || 'move' || 'rename' => MeshPillTone.info,
      _ => MeshPillTone.neutral,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.description_outlined,
              size: 16,
              color: colors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _relativeSessionPath(change.path, sessionCwd),
                style: monoStyle(
                  color: colors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            MeshPill(label: change.kind, tone: tone, mono: true),
          ],
        ),
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

class SessionPolicySheet extends StatefulWidget {
  const SessionPolicySheet({
    super.key,
    required this.host,
    required this.session,
    required this.runtimeApproval,
    required this.runtimeSandbox,
    required this.runtimeNetworkAccess,
    required this.store,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApprovalPolicy? runtimeApproval;
  final SandboxMode? runtimeSandbox;
  final bool? runtimeNetworkAccess;
  final SessionPolicyStore store;

  @override
  State<SessionPolicySheet> createState() => _SessionPolicySheetState();
}

class _SessionPolicySheetState extends State<SessionPolicySheet> {
  late SessionPolicy _policy;

  @override
  void initState() {
    super.initState();
    _policy = widget.store.policyFor(widget.host, widget.session.id);
  }

  ApprovalPolicy get _effectiveApproval =>
      _policy.approval ?? widget.runtimeApproval ?? ApprovalPolicy.untrusted;

  SandboxMode get _effectiveSandbox =>
      _policy.sandbox ?? widget.runtimeSandbox ?? SandboxMode.workspaceWrite;

  /// Whether outbound network is on for the effective sandbox.
  /// `danger-full-access` always has network regardless of the flag.
  bool get _effectiveNetworkOn {
    if (_effectiveSandbox == SandboxMode.dangerFullAccess) return true;
    return _policy.networkAccess ?? widget.runtimeNetworkAccess ?? false;
  }

  bool get _networkToggleDisabled =>
      _effectiveSandbox == SandboxMode.dangerFullAccess;

  bool get _isAutopilot =>
      _effectiveApproval == ApprovalPolicy.never &&
      _effectiveSandbox == SandboxMode.dangerFullAccess;

  Future<void> _save() async {
    await widget.store.setPolicy(widget.host, widget.session.id, _policy);
    if (!mounted) return;
    Navigator.of(context).pop();
    showAppSnackBar(
      context,
      _policy.isEmpty
          ? 'Session uses host defaults on the next message.'
          : 'Applied on your next message — Codex will remember it.',
    );
  }

  void _reset() {
    setState(() => _policy = SessionPolicy.factoryDefaults);
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

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
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
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Change how Codex handles approvals, file access and network for this session. Applied on your next message; Codex remembers it for the rest of the thread.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: colors.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 18),
              _PolicyAutopilotCard(
                active: _isAutopilot,
                onTap: _applyAutopilot,
                colors: colors,
              ),
              const SizedBox(height: 22),
              Text(
                'Approval policy',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: colors.textSecondary, letterSpacing: 0.4),
              ),
              const SizedBox(height: 8),
              for (final policy in ApprovalPolicy.values)
                _PolicyRadioTile<ApprovalPolicy>(
                  value: policy,
                  groupValue: _effectiveApproval,
                  title: policy.label,
                  subtitle: policy.description,
                  fromRuntime: _policy.approval == null &&
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
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: colors.textSecondary, letterSpacing: 0.4),
              ),
              const SizedBox(height: 8),
              for (final sandbox in SandboxMode.values)
                _PolicyRadioTile<SandboxMode>(
                  value: sandbox,
                  groupValue: _effectiveSandbox,
                  title: sandbox.label,
                  subtitle: sandbox.description,
                  fromRuntime: _policy.sandbox == null &&
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
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: colors.textSecondary, letterSpacing: 0.4),
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
                  if (!_policy.isEmpty ||
                      SessionPolicy.runtimeIsLoosened(
                        approvalPolicy: widget.runtimeApproval?.wire,
                        sandboxMode: widget.runtimeSandbox?.wire,
                        networkAccess: widget.runtimeNetworkAccess,
                      ))
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
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.textSecondary, height: 1.35),
                  ),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle_rounded,
                  color: colors.accent, size: 20),
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
          Switch(
            value: value,
            onChanged: disabled ? null : onChanged,
          ),
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
            border: Border.all(
              color: selected ? accent : colors.border,
            ),
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
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
                                ),
                          ),
                        ),
                        if (fromRuntime)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: colors.surfaceMuted,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: colors.border),
                            ),
                            child: Text(
                              'current',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
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
