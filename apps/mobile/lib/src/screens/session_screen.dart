import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
  final SessionFavoritesStore _favorites = SessionFavoritesStore.instance;

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
    _channel?.sink.close();
    super.dispose();
  }

  Future<void> _loadSnapshot() async {
    try {
      final log = await widget.api.fetchLog(widget.host, widget.session.id);
      if (!mounted) {
        return;
      }
      final pendingAction = log.pendingAction;
      setState(() {
        _session = log.session;
        _messages = log.messages;
        _optimisticMessages = _reconcileOptimisticMessages(log.messages);
        _activities = _sortActivities(log.activities);
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
    final colors = context.colors;
    final visibleMessages = [..._messages, ..._optimisticMessages]
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    final timelineEntries = _buildTimelineEntries(
      visibleMessages,
      _sortActivities(_activities),
    );
    return Scaffold(
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
      body: _loading
          ? const MeshLoader()
          : GestureDetector(
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
                  if (_pendingAction != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: _PendingActionCard(
                        action: _pendingAction!,
                        onRespond: _respondAction,
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      controller: _scrollController,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                      itemCount: timelineEntries.length,
                      itemBuilder: (context, index) {
                        final entry = timelineEntries[index];
                        return switch (entry.kind) {
                          _TimelineEntryKind.message => _MessageBubble(
                            message: entry.message!,
                          ),
                          _TimelineEntryKind.activity => _ActivityCard(
                            activity: entry.activity!,
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
                        };
                      },
                    ),
                  ),
                  _Composer(
                    controller: _composerController,
                    sending: _sending,
                    onSend: _sendInput,
                    onDismiss: _dismissKeyboard,
                  ),
                ],
              ),
            ),
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
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: MeshCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        accentStrip: running ? colors.success : colors.accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    host.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onDetails,
                  icon: Icon(
                    Icons.tune_rounded,
                    size: 16,
                    color: colors.accent,
                  ),
                  label: Text(
                    'Details',
                    style: TextStyle(color: colors.accent),
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              session.cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                MeshPill(
                  label: running ? 'running' : 'idle',
                  tone: running ? MeshPillTone.success : MeshPillTone.neutral,
                  icon: running ? Icons.bolt_rounded : Icons.pause_rounded,
                  mono: true,
                ),
                if (favorite)
                  const MeshPill(
                    label: 'favorite',
                    tone: MeshPillTone.warning,
                    icon: Icons.star_rounded,
                    mono: true,
                  ),
                MeshPill(
                  label: session.source,
                  tone: MeshPillTone.accent,
                  mono: true,
                ),
                if ((session.runtime?.model ?? '').isNotEmpty)
                  MeshPill(
                    label: session.runtime!.model!,
                    tone: MeshPillTone.info,
                    mono: true,
                  ),
                if ((session.runtime?.approvalPolicy ?? '').isNotEmpty)
                  MeshPill(
                    label: 'approval ${session.runtime!.approvalPolicy!}',
                    tone: MeshPillTone.warning,
                    mono: true,
                  ),
              ],
            ),
          ],
        ),
      ),
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onDismiss,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 6,
                  onTapOutside: (_) => onDismiss(),
                  style: Theme.of(context).textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: 'Message this session',
                    hintStyle: TextStyle(color: colors.textTertiary),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
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
  const _MarkdownMessageBody({required this.text, required this.textColor});

  final String text;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final baseBody = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: textColor, height: 1.5);

    final styleSheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: baseBody,
      h1: Theme.of(context).textTheme.headlineSmall?.copyWith(color: textColor),
      h2: Theme.of(context).textTheme.titleLarge?.copyWith(color: textColor),
      h3: Theme.of(context).textTheme.titleMedium?.copyWith(color: textColor),
      listBullet: baseBody,
      blockquote: baseBody?.copyWith(color: colors.textSecondary),
      code: monoStyle(
        color: textColor,
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
      a: TextStyle(color: colors.accent, decoration: TextDecoration.underline),
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
