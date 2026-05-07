import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../api_client.dart';
import '../models.dart';
import '../terminal_input_filter.dart';
import '../terminal_key_models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/terminal_keybar.dart';
import '../host_reconnect_scheduler.dart';
import '../host_status_store.dart';
import '../relative_time_ticker.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    this.sessionId,
    this.title,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String? sessionId;
  final String? title;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title ?? 'Terminal'),
            Text(
              widget.cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.textSecondary,
                fontFamily: 'SpaceMono',
              ),
            ),
          ],
        ),
      ),
      body: TerminalPane(
        host: widget.host,
        api: widget.api,
        cwd: widget.cwd,
        sessionId: widget.sessionId,
        title: widget.title,
        reuseExisting: true,
      ),
    );
  }
}

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.host,
    required this.api,
    required this.cwd,
    this.sessionId,
    this.title,
    this.reuseExisting = true,
    this.compact = false,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String? sessionId;
  final String? title;
  final bool reuseExisting;
  final bool compact;

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  late final String _reconnectSlotId =
      'terminal-live:${identityHashCode(this)}';
  late final xterm.Terminal _terminal;
  final FocusNode _focusNode = FocusNode();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  HostTerminalInfo? _terminalInfo;
  bool _starting = true;
  bool _connecting = false;
  bool _stopping = false;
  String? _error;
  int _lastSeq = -1;
  int? _cols;
  int? _rows;

  @override
  void initState() {
    super.initState();
    _terminal = xterm.Terminal(
      maxLines: 5000,
      onOutput: _sendInput,
      onResize: _handleResize,
    );
    _terminal.write('Opening Sidemesh terminal...\r\n');
    HostReconnectScheduler.instance.registerSlot(
      widget.host.id,
      _reconnectSlotId,
      ReconnectPriority.visibleSupport,
      _connectLive,
    );
    unawaited(_startTerminal(reuseExisting: widget.reuseExisting));
  }

  @override
  void didUpdateWidget(covariant TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.id == widget.host.id &&
        oldWidget.host.baseUrl == widget.host.baseUrl &&
        oldWidget.host.token == widget.host.token &&
        oldWidget.cwd == widget.cwd &&
        oldWidget.sessionId == widget.sessionId) {
      return;
    }
    if (oldWidget.host.id != widget.host.id) {
      HostReconnectScheduler.instance.unregisterSlot(
        oldWidget.host.id,
        _reconnectSlotId,
      );
      HostReconnectScheduler.instance.registerSlot(
        widget.host.id,
        _reconnectSlotId,
        ReconnectPriority.visibleSupport,
        _connectLive,
      );
    }
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _subscription = null;
    _channel = null;
    _terminalInfo = null;
    _lastSeq = -1;
    _terminal.write('\r\nOpening Sidemesh terminal...\r\n');
    unawaited(_startTerminal(reuseExisting: widget.reuseExisting));
  }

  @override
  void dispose() {
    HostReconnectScheduler.instance.unregisterSlot(
      widget.host.id,
      _reconnectSlotId,
    );
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _startTerminal({
    required bool reuseExisting,
    bool replaceExisting = false,
  }) async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final terminal =
          await _findReusableTerminal(reuseExisting) ??
          await widget.api.createTerminal(
            widget.host,
            cwd: widget.cwd,
            sessionId: widget.sessionId,
            title: widget.title,
            cols: _terminal.viewWidth,
            rows: _terminal.viewHeight,
            replaceExisting: replaceExisting,
          );
      if (!mounted) return;
      setState(() {
        _terminalInfo = terminal;
        _starting = false;
      });
      _connectLive();
    } catch (error) {
      if (!mounted) return;
      final message = friendlyError(error);
      setState(() {
        _starting = false;
        _error = message;
      });
      _terminal.write('\r\n[terminal error] $message\r\n');
    }
  }

  Future<HostTerminalInfo?> _findReusableTerminal(bool enabled) async {
    if (!enabled) return null;
    final terminals = await widget.api.fetchTerminals(widget.host);
    for (final terminal in terminals) {
      if (!terminal.isRunning) continue;
      if (terminal.cwd != widget.cwd) continue;
      final sessionId = widget.sessionId;
      if (sessionId != null && sessionId.isNotEmpty) {
        if (terminal.sessionId == sessionId) return terminal;
        continue;
      }
      return terminal;
    }
    return null;
  }

  void _connectLive() {
    final terminal = _terminalInfo;
    if (!mounted || terminal == null || !terminal.isRunning || _connecting) {
      return;
    }
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    unawaited(_channel?.sink.close() ?? Future<void>.value());
    _subscription = null;
    _channel = null;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final channel = widget.api.openTerminalLive(
        widget.host,
        terminal.id,
        since: _lastSeq,
      );
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleRawFrame,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
        cancelOnError: false,
      );
      setState(() {
        _connecting = false;
      });
      HostReconnectScheduler.instance.markConnected(
        widget.host.id,
        _reconnectSlotId,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = friendlyError(error);
      });
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!mounted || _terminalInfo?.isRunning != true) return;
    final channel = _channel;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _subscription = null;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close());
    }
    setState(() {
      _connecting = false;
      _error = 'Terminal disconnected. Reconnecting...';
    });
    HostReconnectScheduler.instance.markDisconnected(
      widget.host.id,
      _reconnectSlotId,
    );
  }

  void _handleRawFrame(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> frame;
    try {
      frame = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }

    switch (frame['type']) {
      case 'hello':
        final terminal = frame['terminal'];
        if (terminal is Map) {
          setState(() {
            _terminalInfo = HostTerminalInfo.fromJson(
              terminal.cast<String, dynamic>(),
            );
            _connecting = false;
            _error = null;
          });
        }
        return;
      case 'output':
        final seq = _intOrNull(frame['seq']);
        if (seq != null && seq > _lastSeq) {
          _lastSeq = seq;
        }
        final data = frame['data'];
        if (data is String && data.isNotEmpty) {
          _terminal.write(data);
        }
        HostStatusStore.instance.markEvent(widget.host.id);
        return;
      case 'exit':
        final seq = _intOrNull(frame['seq']);
        if (seq != null && seq > _lastSeq) {
          _lastSeq = seq;
        }
        setState(() {
          final previous = _terminalInfo;
          if (previous != null) {
            _terminalInfo = HostTerminalInfo(
              id: previous.id,
              title: previous.title,
              cwd: previous.cwd,
              sessionId: previous.sessionId,
              status: 'exited',
              backend: previous.backend,
              shell: previous.shell,
              rows: previous.rows,
              cols: previous.cols,
              createdAt: previous.createdAt,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
              exitCode: _intOrNull(frame['exitCode']),
              signal: _intOrNull(frame['signal']),
              nextSeq: previous.nextSeq,
              clients: previous.clients,
            );
          }
        });
        _terminal.write('\r\n[terminal exited]\r\n');
        return;
      case 'replace':
        final seq = _intOrNull(frame['seq']);
        if (seq != null && seq > _lastSeq) {
          _lastSeq = seq;
        }
        final replacement = frame['replacement'];
        if (replacement is Map) {
          _adoptReplacementTerminal(
            HostTerminalInfo.fromJson(replacement.cast<String, dynamic>()),
          );
        }
        return;
      case 'error':
        final message = frame['message']?.toString() ?? 'Terminal error';
        setState(() => _error = message);
        _terminal.write('\r\n[terminal error] $message\r\n');
        return;
    }
  }

  void _sendInput(String data) {
    if (data.isEmpty || _terminalInfo?.isRunning != true) return;
    final input = _terminal.isUsingAltBuffer
        ? data
        : stripGeneratedTerminalResponses(data);
    if (input.isEmpty) return;
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode({'type': 'input', 'data': input}));
  }

  void _onKeyBarAction(TerminalKeyAction action) {
    if (_terminalInfo?.isRunning != true) return;
    if (action.key != null) {
      _terminal.keyInput(
        action.key!,
        ctrl: action.ctrl,
        alt: action.alt,
        shift: action.shift,
      );
    } else if (action.rawText != null && action.rawText!.isNotEmpty) {
      _terminal.textInput(action.rawText!);
    }
  }

  void _adoptReplacementTerminal(HostTerminalInfo replacement) {
    if (!mounted || replacement.id == _terminalInfo?.id) return;
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    _subscription = null;
    _channel = null;
    setState(() {
      _terminalInfo = replacement;
      _starting = false;
      _stopping = false;
      _connecting = false;
      _lastSeq = -1;
      _error = null;
    });
    _terminal.write('\r\n[terminal restarted from another device]\r\n');
    _connectLive();
  }

  void _handleResize(int cols, int rows, int pixelWidth, int pixelHeight) {
    if (_cols == cols && _rows == rows) return;
    _cols = cols;
    _rows = rows;
    final channel = _channel;
    if (channel != null) {
      channel.sink.add(
        jsonEncode({'type': 'resize', 'cols': cols, 'rows': rows}),
      );
    }
  }

  Future<void> _stopTerminal() async {
    final terminal = _terminalInfo;
    if (terminal == null || !terminal.isRunning || _stopping) return;
    setState(() => _stopping = true);
    try {
      final updated = await widget.api.killTerminal(widget.host, terminal.id);
      if (!mounted) return;
      setState(() {
        _terminalInfo = _stoppedTerminal(updated);
        _stopping = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _stopping = false);
      showAppSnackBar(context, friendlyError(error));
    }
  }

  Future<void> _restartTerminal() async {
    if (_starting) return;
    await _subscription?.cancel();
    await _channel?.sink.close();
    if (!mounted) return;
    setState(() {
      _subscription = null;
      _channel = null;
      _terminalInfo = null;
      _stopping = false;
      _connecting = false;
      _lastSeq = -1;
      _error = null;
    });
    _terminal.write('\r\nStarting a new Sidemesh terminal...\r\n');
    await _startTerminal(reuseExisting: false, replaceExisting: true);
  }

  @override
  Widget build(BuildContext context) {
    final terminal = _terminalInfo;
    final colors = context.colors;
    return Column(
      children: [
        _TerminalStatusStrip(
          hostId: widget.host.id,
          starting: _starting,
          connecting: _connecting,
          stopping: _stopping,
          error: _error,
          terminal: terminal,
          onStop: _stopTerminal,
          onRestart: _restartTerminal,
        ),
        Expanded(
          child: Container(
            color: colors.codeBackground,
            child: Container(
              margin: EdgeInsets.all(widget.compact ? 6 : 10),
              decoration: BoxDecoration(
                color: colors.codeBackground,
                border: Border.all(color: colors.codeBorder),
                borderRadius: BorderRadius.circular(widget.compact ? 12 : 16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: xterm.TerminalView(
                _terminal,
                focusNode: _focusNode,
                autofocus: true,
                keyboardType: TextInputType.text,
                deleteDetection: true,
                theme: _terminalTheme(colors),
                textStyle: xterm.TerminalStyle(
                  fontSize: widget.compact ? 12 : 13,
                  height: 1.22,
                ),
                padding: EdgeInsets.all(widget.compact ? 10 : 12),
              ),
            ),
          ),
        ),
        TerminalKeyBar(
          compact: widget.compact,
          onAction: _onKeyBarAction,
        ),
      ],
    );
  }
}

HostTerminalInfo _stoppedTerminal(HostTerminalInfo terminal) {
  if (!terminal.isRunning) return terminal;
  return HostTerminalInfo(
    id: terminal.id,
    title: terminal.title,
    cwd: terminal.cwd,
    sessionId: terminal.sessionId,
    status: 'exited',
    backend: terminal.backend,
    shell: terminal.shell,
    rows: terminal.rows,
    cols: terminal.cols,
    createdAt: terminal.createdAt,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    exitCode: terminal.exitCode,
    signal: terminal.signal,
    nextSeq: terminal.nextSeq,
    clients: terminal.clients,
  );
}

xterm.TerminalTheme _terminalTheme(AppColors colors) {
  return xterm.TerminalTheme(
    cursor: colors.accent,
    selection: colors.accentMuted.withValues(alpha: 0.7),
    foreground: colors.codeForeground,
    background: colors.codeBackground,
    black: colors.textTertiary,
    red: colors.danger,
    green: colors.success,
    yellow: colors.warning,
    blue: colors.accent,
    magenta: colors.info,
    cyan: colors.info,
    white: colors.codeForeground,
    brightBlack: colors.textSecondary,
    brightRed: _brightTerminalColor(colors.danger),
    brightGreen: _brightTerminalColor(colors.success),
    brightYellow: _brightTerminalColor(colors.warning),
    brightBlue: _brightTerminalColor(colors.accent),
    brightMagenta: _brightTerminalColor(colors.info),
    brightCyan: _brightTerminalColor(colors.info),
    brightWhite: colors.textPrimary,
    searchHitBackground: colors.warningMuted,
    searchHitBackgroundCurrent: colors.accentMuted,
    searchHitForeground: colors.textPrimary,
  );
}

Color _brightTerminalColor(Color color) =>
    Color.lerp(color, Colors.white, 0.2)!;

class _TerminalStatusStrip extends StatelessWidget {
  const _TerminalStatusStrip({
    required this.hostId,
    required this.starting,
    required this.connecting,
    required this.stopping,
    required this.error,
    required this.terminal,
    required this.onStop,
    required this.onRestart,
  });

  final String hostId;
  final bool starting;
  final bool connecting;
  final bool stopping;
  final String? error;
  final HostTerminalInfo? terminal;
  final VoidCallback onStop;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = terminal?.isRunning == true;
    final canRestart =
        !running &&
        !starting &&
        !connecting &&
        (terminal != null || error != null);
    final limitedBackend = terminal?.backend == 'pipe';
    final baseLabel =
        error ??
        (starting
            ? 'Starting terminal'
            : connecting
            ? 'Connecting'
            : running
            ? limitedBackend
                  ? 'Live terminal (limited fallback)'
                  : 'Live terminal'
            : 'Terminal stopped');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (starting || connecting)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            )
          else
            Icon(
              running ? Icons.bolt_rounded : Icons.stop_circle_rounded,
              size: 16,
              color: error == null
                  ? (running ? colors.success : colors.textSecondary)
                  : colors.danger,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge([
                HostStatusStore.instance,
                RelativeTimeTicker.seconds,
              ]),
              builder: (context, _) {
                final status = HostStatusStore.instance.statusFor(hostId);
                final freshness = _terminalFreshness(status);
                final label = freshness != null
                    ? '$baseLabel · $freshness'
                    : baseLabel;
                return Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: error == null ? colors.textSecondary : colors.danger,
                    fontWeight: AppWeights.emphasis,
                  ),
                );
              },
            ),
          ),
          if (terminal != null)
            Flexible(
              child: Tooltip(
                message: terminal!.cwd,
                child: Text(
                  '${terminal!.backend} ${terminal!.cols}x${terminal!.rows} · ${_basename(terminal!.cwd)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          if (running) ...[
            const SizedBox(width: 8),
            MeshIconButton(
              icon: Icons.stop_circle_rounded,
              tooltip: 'Stop terminal',
              color: colors.danger,
              onTap: stopping ? () {} : onStop,
            ),
          ] else if (canRestart) ...[
            const SizedBox(width: 8),
            MeshIconButton(
              icon: Icons.restart_alt_rounded,
              tooltip: 'Start new terminal',
              color: colors.accent,
              onTap: onRestart,
            ),
          ],
        ],
      ),
    );
  }

  String? _terminalFreshness(HostStatus status) {
    final last = status.lastEventAt ?? status.lastOnlineAt;
    if (last == null) return null;
    final elapsed = DateTime.now().difference(last);
    if (elapsed.inSeconds < 5) return null;
    if (elapsed.inMinutes < 1) return 'last output ${elapsed.inSeconds}s ago';
    if (elapsed.inHours < 1) return 'last output ${elapsed.inMinutes}m ago';
    return 'last output ${elapsed.inHours}h ago';
  }
}

String _basename(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  final withoutTrailingSlash = trimmed.replaceFirst(RegExp(r'/+$'), '');
  final index = withoutTrailingSlash.lastIndexOf('/');
  return index >= 0
      ? withoutTrailingSlash.substring(index + 1)
      : withoutTrailingSlash;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
