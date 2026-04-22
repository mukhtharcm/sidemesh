import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:web_socket_channel/io.dart';

import '../api_client.dart';
import '../models.dart';

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
  PendingAction? _pendingAction;
  bool _running = false;
  bool _loading = true;
  bool _sending = false;
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
      setState(() {
        _session = log.session;
        _messages = log.messages;
        _pendingAction = status.pendingAction ?? log.pendingAction;
        _running = status.isRunning;
        _loading = false;
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
      case 'turn_started':
        setState(() {
          _running = true;
          _liveAssistantText = '';
        });
      case 'assistant_delta':
        setState(() {
          _running = true;
          _liveAssistantText += event.delta ?? '';
        });
        unawaited(_scrollToBottom(animated: true));
      case 'turn_completed':
        setState(() {
          _running = false;
        });
        unawaited(_loadSnapshot());
      case 'action_opened':
        setState(() {
          _pendingAction = event.action;
        });
      case 'action_resolved':
        setState(() {
          _pendingAction = null;
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

    setState(() {
      _sending = true;
    });
    try {
      await widget.api.sendInput(
        widget.host,
        sessionId: widget.session.id,
        text: text,
      );
      if (!mounted) {
        return;
      }
      _composerController.clear();
      setState(() {
        _running = true;
        _liveAssistantText = '';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to send input: $error')));
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

  @override
  Widget build(BuildContext context) {
    final session = _session ?? widget.session;
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
                      Text(
                        widget.host.label,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.cwd,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
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
                  child: ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      ..._messages.map(
                        (message) => _MessageBubble(message: message),
                      ),
                      if (_liveAssistantText.isNotEmpty)
                        _MessageBubble(
                          message: SessionMessage(
                            id: 'live',
                            role: 'assistant',
                            text: _liveAssistantText,
                            createdAt: DateTime.now(),
                            phase: 'commentary',
                          ),
                          live: true,
                        ),
                    ],
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
