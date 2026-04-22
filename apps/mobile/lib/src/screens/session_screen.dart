import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:web_socket_channel/io.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_runtime.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.host,
    required this.session,
    required this.api,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();

  SessionSummary? _session;
  List<SessionMessage> _messages = const [];
  List<SessionMessage> _optimisticMessages = const [];
  List<SessionActivity> _activities = const [];
  PendingAction? _pendingAction;
  bool _running = false;
  bool _loading = true;
  bool _sending = false;
  bool _awaitingAssistantReply = false;
  String _liveAssistantText = '';
  IOWebSocketChannel? _channel;
  StreamSubscription? _subscription;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    _loadSnapshot();
    _connectLive();
  }

  @override
  void dispose() {
    _composerController.dispose();
    _scrollController.dispose();
    _subscription?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  Future<void> _loadSnapshot() async {
    try {
      final log = await widget.api.fetchLog(widget.host, widget.session.id);
      final status = await widget.api.fetchStatus(
        widget.host,
        widget.session.id,
      );
      if (!mounted) {
        return;
      }
      final pendingAction = status.pendingAction ?? log.pendingAction;
      setState(() {
        _session = log.session;
        _messages = log.messages;
        _optimisticMessages = _reconcileOptimisticMessages(log.messages);
        _activities = _sortActivities(log.activities);
        _pendingAction = pendingAction;
        _running = status.isRunning;
        _loading = false;
        _awaitingAssistantReply =
            status.isRunning &&
            _liveAssistantText.isEmpty &&
            pendingAction == null;
        if (!_running) {
          _liveAssistantText = '';
        }
      });
      await _scrollToBottom();
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
        unawaited(_scrollToBottom(animated: true));
      case 'turn_started':
        setState(() {
          _running = true;
          _awaitingAssistantReply =
              _liveAssistantText.isEmpty && _pendingAction == null;
        });
      case 'assistant_delta':
        setState(() {
          _running = true;
          _awaitingAssistantReply = false;
          _liveAssistantText += event.delta ?? '';
        });
        unawaited(_scrollToBottom(animated: true));
      case 'turn_completed':
        setState(() {
          _running = false;
          _awaitingAssistantReply = false;
        });
        unawaited(_loadSnapshot());
      case 'activity_updated':
        final activity = event.activity;
        if (activity == null) {
          return;
        }
        setState(() {
          _upsertActivity(activity);
        });
        unawaited(_scrollToBottom(animated: true));
      case 'action_opened':
        setState(() {
          _pendingAction = event.action;
          _awaitingAssistantReply = false;
        });
      case 'action_resolved':
        setState(() {
          _pendingAction = null;
          _awaitingAssistantReply = _running && _liveAssistantText.isEmpty;
        });
      case 'hello':
      case 'error':
        break;
    }
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
    );

    _composerController.clear();
    setState(() {
      _sending = true;
      _running = true;
      _awaitingAssistantReply = true;
      _liveAssistantText = '';
      _upsertOptimisticMessage(optimisticMessage);
    });
    unawaited(_scrollToBottom(animated: true));

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
    try {
      await widget.api.stopSession(widget.host, widget.session.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _running = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to stop session: $error')));
    }
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
      setState(() {
        _pendingAction = null;
      });
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
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Session details',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              _SheetDetailRow(label: 'Host', value: widget.host.label),
              _SheetDetailRow(label: 'Working dir', value: session.cwd),
              _SheetDetailRow(
                label: 'Status',
                value: _running ? 'Running' : 'Idle',
              ),
              _SheetDetailRow(label: 'Source', value: session.source),
              if (session.runtime != null) ...[
                const SizedBox(height: 12),
                _SessionRuntimeDetails(runtime: session.runtime!),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _scrollToBottom({bool animated = false}) async {
    for (var attempt = 0; attempt < 3; attempt += 1) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scrollController.hasClients) {
        continue;
      }

      final targetOffset = _scrollController.position.maxScrollExtent;
      final distance = (_scrollController.offset - targetOffset).abs();
      if (distance < 1) {
        return;
      }

      if (animated && attempt == 2) {
        await _scrollController.animateTo(
          targetOffset,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(targetOffset);
      }
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
    sorted.sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return sorted;
  }

  List<_TimelineEntry> _buildTimelineEntries(
    List<SessionMessage> messages,
    List<SessionActivity> activities,
  ) {
    final entries = <_TimelineEntry>[
      ...messages.map(_TimelineEntry.message),
      ...activities.map(_TimelineEntry.activity),
    ]..sort((left, right) => left.createdAt.compareTo(right.createdAt));

    if (_running &&
        _awaitingAssistantReply &&
        _liveAssistantText.isEmpty &&
        _pendingAction == null) {
      entries.add(_TimelineEntry.thinking(DateTime.now()));
    }

    if (_liveAssistantText.isNotEmpty) {
      entries.add(_TimelineEntry.liveAssistant(DateTime.now()));
    }

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
    final visibleMessages = [..._messages, ..._optimisticMessages]
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    final timelineEntries = _buildTimelineEntries(
      visibleMessages,
      _sortActivities(_activities),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(session.title),
        actions: [
          if (_running)
            TextButton.icon(
              onPressed: _stopSession,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop'),
            ),
          IconButton(
            tooltip: 'Reload',
            onPressed: _loadSnapshot,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.host.label,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () => _showSessionDetailsSheet(session),
                            icon: const Icon(Icons.tune, size: 18),
                            label: const Text('Details'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.cwd,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _StatusPill(
                            label: _running ? 'Running' : 'Idle',
                            color: _running
                                ? const Color(0xFFD7F2D3)
                                : const Color(0xFFE7E1D8),
                          ),
                          _StatusPill(
                            label: session.source,
                            color: const Color(0xFFEBC8A1),
                          ),
                          if ((session.runtime?.model ?? '').isNotEmpty)
                            _StatusPill(
                              label: session.runtime!.model!,
                              color: const Color(0xFFF4E6CF),
                            ),
                          if ((session.runtime?.approvalPolicy ?? '')
                              .isNotEmpty)
                            _StatusPill(
                              label: session.runtime!.approvalPolicy!,
                              color: const Color(0xFFF6E6C5),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_pendingAction != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Card(
                      color: const Color(0xFFFFE2C7),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _pendingAction!.title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 8),
                            Text(_pendingAction!.detail),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (_pendingAction!.canApprove)
                                  FilledButton(
                                    onPressed: () => _respondAction('accept'),
                                    child: const Text('Approve'),
                                  ),
                                if (_pendingAction!.canApproveForSession)
                                  FilledButton.tonal(
                                    onPressed: () =>
                                        _respondAction('acceptForSession'),
                                    child: const Text('Approve for session'),
                                  ),
                                if (_pendingAction!.canDecline)
                                  OutlinedButton(
                                    onPressed: () => _respondAction('decline'),
                                    child: const Text('Decline'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: timelineEntries.length,
                    itemBuilder: (context, index) =>
                        switch (timelineEntries[index].kind) {
                          _TimelineEntryKind.message => _MessageBubble(
                            message: timelineEntries[index].message!,
                          ),
                          _TimelineEntryKind.activity => _ActivityCard(
                            activity: timelineEntries[index].activity!,
                            sessionCwd: session.cwd,
                          ),
                          _TimelineEntryKind.thinking =>
                            const _ThinkingBubble(),
                          _TimelineEntryKind.liveAssistant => _MessageBubble(
                            message: SessionMessage(
                              id: 'live',
                              role: 'assistant',
                              text: _liveAssistantText,
                              createdAt: DateTime.now(),
                              phase: 'commentary',
                            ),
                            live: true,
                          ),
                        },
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _composerController,
                            minLines: 1,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              hintText: 'Message this session',
                              filled: true,
                              fillColor: Color(0xFFFFFBF5),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(20),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: _sending ? null : _sendInput,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(56, 56),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                          ),
                          child: _sending
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

enum _TimelineEntryKind { message, activity, thinking, liveAssistant }

class _TimelineEntry {
  const _TimelineEntry._({
    required this.kind,
    required this.createdAt,
    this.message,
    this.activity,
  });

  factory _TimelineEntry.message(SessionMessage message) => _TimelineEntry._(
    kind: _TimelineEntryKind.message,
    createdAt: message.createdAt,
    message: message,
  );

  factory _TimelineEntry.activity(SessionActivity activity) => _TimelineEntry._(
    kind: _TimelineEntryKind.activity,
    createdAt: activity.createdAt,
    activity: activity,
  );

  factory _TimelineEntry.thinking(DateTime createdAt) =>
      _TimelineEntry._(kind: _TimelineEntryKind.thinking, createdAt: createdAt);

  factory _TimelineEntry.liveAssistant(DateTime createdAt) => _TimelineEntry._(
    kind: _TimelineEntryKind.liveAssistant,
    createdAt: createdAt,
  );

  final _TimelineEntryKind kind;
  final DateTime createdAt;
  final SessionMessage? message;
  final SessionActivity? activity;
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) {
    return _MessageBubble(
      message: SessionMessage(
        id: 'thinking',
        role: 'assistant',
        text: 'Thinking...',
        createdAt: DateTime.now(),
        phase: 'commentary',
      ),
      live: true,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, this.live = false});

  final SessionMessage message;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isAssistant = message.role == 'assistant';
    final bubbleColor = switch (message.role) {
      'user' => const Color(0xFF221C15),
      'assistant' => live ? const Color(0xFFFFEBCD) : const Color(0xFFFFFBF5),
      _ => const Color(0xFFE7E1D8),
    };
    final textColor = isUser ? Colors.white : const Color(0xFF221C15);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(22),
              border: live
                  ? Border.all(color: const Color(0xFFCA6B1F), width: 1.2)
                  : null,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.phase != null && message.role == 'assistant')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        message.phase == 'commentary' ? 'Commentary' : 'Answer',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: textColor.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (isAssistant)
                    _MarkdownMessageBody(
                      text: message.text,
                      textColor: textColor,
                      codeBackgroundColor: live
                          ? const Color(0xFFF6D8A8)
                          : const Color(0xFFF2E3CB),
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
    );
  }
}

class _MarkdownMessageBody extends StatelessWidget {
  const _MarkdownMessageBody({
    required this.text,
    required this.textColor,
    required this.codeBackgroundColor,
  });

  final String text;
  final Color textColor;
  final Color codeBackgroundColor;

  @override
  Widget build(BuildContext context) {
    final baseBody = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: textColor, height: 1.45);

    final styleSheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: baseBody,
      h1: Theme.of(context).textTheme.headlineSmall?.copyWith(color: textColor),
      h2: Theme.of(context).textTheme.titleLarge?.copyWith(color: textColor),
      h3: Theme.of(context).textTheme.titleMedium?.copyWith(color: textColor),
      listBullet: baseBody,
      blockquote: baseBody,
      code: GoogleFonts.ibmPlexMono(color: textColor, fontSize: 13),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: codeBackgroundColor,
        borderRadius: BorderRadius.circular(14),
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: textColor.withValues(alpha: 0.25), width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: textColor.withValues(alpha: 0.18)),
        ),
      ),
    );

    return MarkdownBody(
      data: text,
      selectable: true,
      shrinkWrap: true,
      softLineBreak: true,
      styleSheet: styleSheet,
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity, required this.sessionCwd});

  final SessionActivity activity;
  final String sessionCwd;

  @override
  Widget build(BuildContext context) {
    final title = switch (activity.type) {
      'command' =>
        (activity.command ?? '').trim().isEmpty ? 'Command' : activity.command!,
      'file_change' =>
        activity.changes.length == 1
            ? _relativeSessionPath(activity.changes.first.path, sessionCwd)
            : 'Edited ${activity.changes.length} files',
      _ => 'Activity',
    };

    final subtitle = switch (activity.type) {
      'command' => _relativeSessionPath(activity.cwd ?? sessionCwd, sessionCwd),
      'file_change' => _activityFileSummary(activity.changes, sessionCwd),
      _ => null,
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFFFF4E7),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE7D3B8)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Icon(
                          activity.isCommand
                              ? Icons.terminal_rounded
                              : Icons.description_outlined,
                          size: 18,
                          color: const Color(0xFF8E4A15),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              activity.isCommand ? 'Command' : 'File change',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: const Color(0xFF8E4A15),
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.2,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            if (subtitle != null && subtitle.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                subtitle,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: const Color(0xFF6D5B49)),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      _ActivityStatusPill(status: activity.status),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (activity.turnId != null)
                        _InfoTag(label: 'turn ${_shortId(activity.turnId!)}'),
                      if (activity.exitCode != null)
                        _InfoTag(label: 'exit ${activity.exitCode}'),
                      if (activity.durationMs != null)
                        _InfoTag(label: _formatDuration(activity.durationMs!)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (activity.isCommand) ...[
                    if ((activity.output ?? '').isNotEmpty)
                      _CodeBlock(text: activity.output!)
                    else
                      Text(
                        'Waiting for command output.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF6D5B49),
                        ),
                      ),
                  ] else if (activity.changes.isEmpty) ...[
                    Text(
                      'Waiting for patch details.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF6D5B49),
                      ),
                    ),
                  ] else ...[
                    ...activity.changes.map(
                      (change) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _relativeSessionPath(
                                      change.path,
                                      sessionCwd,
                                    ),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _InfoTag(label: change.kind),
                              ],
                            ),
                            if ((change.movePath ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 6,
                                  bottom: 8,
                                ),
                                child: Text(
                                  'Moved from ${_relativeSessionPath(change.movePath!, sessionCwd)}',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: const Color(0xFF6D5B49),
                                      ),
                                ),
                              )
                            else
                              const SizedBox(height: 8),
                            _CodeBlock(text: change.diff),
                          ],
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
}

class _ActivityStatusPill extends StatelessWidget {
  const _ActivityStatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _activityStatusColor(status),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _activityStatusLabel(status),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: const Color(0xFF221C15),
        ),
      ),
    );
  }
}

class _InfoTag extends StatelessWidget {
  const _InfoTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5E6D1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: const Color(0xFF6D5B49),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E3),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            text,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 12.5,
              height: 1.45,
              color: const Color(0xFF221C15),
            ),
          ),
        ),
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

String _activityStatusLabel(String status) {
  return switch (status) {
    'completed' => 'Done',
    'failed' => 'Failed',
    'declined' => 'Declined',
    _ => 'Running',
  };
}

Color _activityStatusColor(String status) {
  return switch (status) {
    'completed' => const Color(0xFFD7F2D3),
    'failed' => const Color(0xFFFFD3CC),
    'declined' => const Color(0xFFE7E1D8),
    _ => const Color(0xFFFFE2C7),
  };
}

String _formatDuration(int durationMs) {
  if (durationMs >= 1000) {
    final seconds = durationMs / 1000;
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}s';
  }
  return '${durationMs}ms';
}

String _shortId(String value) {
  if (value.length <= 8) {
    return value;
  }
  return value.substring(value.length - 8);
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label),
    );
  }
}

class _SheetDetailRow extends StatelessWidget {
  const _SheetDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: const Color(0xFF7A6246),
              fontWeight: FontWeight.w700,
            ),
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

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4E7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Session details',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: details
                  .map(
                    (detail) => _SessionDetailTile(
                      label: detail.label,
                      value: detail.value,
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionDetailTile extends StatelessWidget {
  const _SessionDetailTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 132, maxWidth: 180),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: const Color(0xFF7A6246),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: const Color(0xFF221C15),
            ),
          ),
        ],
      ),
    );
  }
}
