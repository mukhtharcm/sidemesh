import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:web_socket_channel/io.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_favorites_store.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
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

class _SessionScreenState extends State<SessionScreen> {
  static const _initialMessageLimit = 120;
  static const _initialActivityLimit = 80;
  static const _messagePageSize = 120;
  static const _activityPageSize = 80;
  static const _liveUpdateFlushInterval = Duration(milliseconds: 48);

  final _composerController = TextEditingController();
  final _scrollController = ScrollController();
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;
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

  // Memoized timeline entries so rebuilds that don't change list inputs skip
  // the list+sort work.
  List<SessionMessage>? _entriesMessagesRef;
  List<SessionMessage>? _entriesOptimisticRef;
  List<SessionActivity>? _entriesActivitiesRef;
  List<_TimelineEntry> _cachedEntries = const [];

  String get _liveAssistantText => _liveAssistantNotifier.value;
  set _liveAssistantText(String value) => _liveAssistantNotifier.value = value;

  @override
  void initState() {
    super.initState();
    _favorites.ensureLoaded();
    _session = widget.session;
    _loadSnapshot();
    _connectLive();
  }

  @override
  void dispose() {
    _composerController.dispose();
    _scrollController.dispose();
    _subscription?.cancel();
    _liveFlushTimer?.cancel();
    _channel?.sink.close();
    _liveAssistantNotifier.dispose();
    _thinkingNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadSnapshot({
    int? messageLimit,
    int? activityLimit,
    bool scrollToBottom = true,
  }) async {
    final resolvedMessageLimit = messageLimit ?? _messageLimit;
    final resolvedActivityLimit = activityLimit ?? _activityLimit;
    try {
      final log = await widget.api.fetchLog(
        widget.host,
        widget.session.id,
        messageLimit: resolvedMessageLimit,
        activityLimit: resolvedActivityLimit,
      );
      if (!mounted) {
        return;
      }
      final pendingAction = log.pendingAction;
      setState(() {
        _session = log.session;
        _messages = log.messages;
        _optimisticMessages = _reconcileOptimisticMessages(log.messages);
        _activities = _sortActivities(log.activities);
        _history = log.history;
        _messageLimit = resolvedMessageLimit;
        _activityLimit = resolvedActivityLimit;
        _pendingAction = pendingAction;
        _running = log.session.isActive;
        _loading = false;
        _awaitingAssistantReply =
            log.session.isActive &&
            _liveAssistantText.isEmpty &&
            pendingAction == null;
        if (!_running) {
          _liveAssistantText = '';
        }
      });
      if (scrollToBottom) {
        await _scrollToBottom();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load session: $error')));
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
    try {
      _channel = widget.api.openLive(widget.host, widget.session.id);
      _subscription = _channel!.stream.listen((raw) {
        final decoded = jsonDecode(raw as String) as Map<String, dynamic>;
        final event = LiveEvent.fromJson(decoded);
        _handleEvent(event);
      }, onError: (_) {});
    } catch (_) {
      _channel = null;
    }
  }

  void _handleEvent(LiveEvent event) {
    if (!mounted || event.sessionId != widget.session.id) {
      return;
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
        // Background reconcile; do not block UI.
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          if (!mounted) return;
          unawaited(
            _loadSnapshot(
              messageLimit: _messageLimit,
              activityLimit: _activityLimit,
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
      await widget.api.sendInput(
        widget.host,
        sessionId: widget.session.id,
        text: text,
        clientMessageId: optimisticMessage.id,
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send input: $error')));
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Session stopped.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to stop session: $error')));
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
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to rename: $error')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to archive: $error')));
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(label),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resolve action: $error')),
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
              builder: (context, _) => _SessionHeader(
                host: widget.host,
                session: session,
                running: _running,
                favorite: _favorites.isFavorite(widget.host, session.id),
                onDetails: () => _showSessionDetailsSheet(session),
              ),
            ),
            if ((_history?.isTruncated ?? false))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _HistoryTruncationCard(
                  history: _history!,
                  loading: _loadingOlderHistory,
                  onLoadOlderHistory: _loadOlderTranscript,
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
                  : ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                      itemCount: timelineEntries.length,
                      itemBuilder: (context, index) {
                        // Reverse the mapping: index 0 (bottom) shows the
                        // newest entry.
                        final entry =
                            timelineEntries[timelineEntries.length - 1 - index];
                        return KeyedSubtree(
                          key: ValueKey(entry.keyId),
                          child: switch (entry.kind) {
                            _TimelineEntryKind.message => _MessageBubble(
                              message: entry.message!,
                            ),
                            _TimelineEntryKind.activity => _ActivityCard(
                              activity: entry.activity!,
                              sessionCwd: session.cwd,
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
            _LiveStreamArea(
              liveText: _liveAssistantNotifier,
              thinking: _thinkingNotifier,
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
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: colors.warning.withValues(alpha: 0.5),
      accentStrip: colors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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
          Text(
            action.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            action.detail,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
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
    final shownParts = <String>[
      '${history.returnedMessages}/${history.totalMessages} messages',
      '${history.returnedActivities}/${history.totalActivities} actions',
    ];

    return MeshCard(
      tone: MeshCardTone.muted,
      borderColor: colors.info.withValues(alpha: 0.35),
      accentStrip: colors.info,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.speed_rounded, color: colors.info, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recent history loaded',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  hiddenParts.isEmpty
                      ? 'Loaded ${shownParts.join(' and ')}.'
                      : 'Loaded ${shownParts.join(' and ')}. Hidden for speed: ${hiddenParts.join(' and ')}.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            onPressed: loading ? null : onLoadOlderHistory,
            child: loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Load older'),
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
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
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: message.text.trim().isEmpty
                ? null
                : () => _copyMessage(context, message.text),
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
                      SelectableText(
                        message.text,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          height: 1.45,
                        ),
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

  void _copyMessage(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Message copied'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

class _MarkdownMessageBody extends StatefulWidget {
  const _MarkdownMessageBody({required this.text, required this.textColor});

  final String text;
  final Color textColor;

  @override
  State<_MarkdownMessageBody> createState() => _MarkdownMessageBodyState();
}

class _MarkdownMessageBodyState extends State<_MarkdownMessageBody> {
  MarkdownStyleSheet? _cached;
  Object? _cacheKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final key = Object.hash(
      theme.brightness,
      widget.textColor.toARGB32(),
      colors.codeBackground.toARGB32(),
      colors.codeBorder.toARGB32(),
      colors.accent.toARGB32(),
      colors.border.toARGB32(),
      colors.textSecondary.toARGB32(),
    );

    if (_cached == null || _cacheKey != key) {
      final baseBody = theme.textTheme.bodyMedium?.copyWith(
        color: widget.textColor,
        height: 1.5,
      );
      _cached = MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: baseBody,
        h1: theme.textTheme.headlineSmall?.copyWith(color: widget.textColor),
        h2: theme.textTheme.titleLarge?.copyWith(color: widget.textColor),
        h3: theme.textTheme.titleMedium?.copyWith(color: widget.textColor),
        listBullet: baseBody,
        blockquote: baseBody?.copyWith(color: colors.textSecondary),
        code: monoStyle(
          color: widget.textColor,
          fontSize: 12.5,
        ).copyWith(backgroundColor: colors.codeBackground),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: colors.codeBackground,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.codeBorder),
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.accent, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.border)),
        ),
        a: TextStyle(
          color: colors.accent,
          decoration: TextDecoration.underline,
        ),
      );
      _cacheKey = key;
    }

    return MarkdownBody(
      data: widget.text,
      selectable: true,
      shrinkWrap: true,
      softLineBreak: true,
      styleSheet: _cached!,
    );
  }
}

class _ActivityCard extends StatefulWidget {
  const _ActivityCard({required this.activity, required this.sessionCwd});

  final SessionActivity activity;
  final String sessionCwd;

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> {
  static const _collapsedLineLimit = 15;
  bool _outputExpanded = false;

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
                Row(
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
                      child: Icon(activityIcon, size: 18, color: colors.accent),
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
                            maxLines: 3,
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
                          if (subtitle != null && subtitle.isNotEmpty) ...[
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
                  ],
                ),
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
                    DiffView(diff: activity.diff!)
                  else
                    _waitingText(context, 'Waiting for turn diff.'),
                ] else if (activity.changes.isEmpty) ...[
                  _waitingText(context, 'Waiting for patch details.'),
                ] else ...[
                  ...activity.changes.map(
                    (change) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _FileChangeBlock(
                        change: change,
                        sessionCwd: sessionCwd,
                      ),
                    ),
                  ),
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
