import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';

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
  late final xterm.Terminal _terminal;
  final FocusNode _focusNode = FocusNode();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  HostTerminalInfo? _terminalInfo;
  bool _starting = true;
  bool _connecting = false;
  bool _stopping = false;
  String? _error;
  int _lastSeq = -1;
  int _reconnectAttempts = 0;
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
    unawaited(_startTerminal());
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
    _subscription?.cancel();
    _channel?.sink.close();
    _reconnectTimer?.cancel();
    _subscription = null;
    _channel = null;
    _terminalInfo = null;
    _lastSeq = -1;
    _reconnectAttempts = 0;
    _terminal.write('Opening Sidemesh terminal...\r\n');
    unawaited(_startTerminal());
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _startTerminal() async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final terminal =
          await _findReusableTerminal() ??
          await widget.api.createTerminal(
            widget.host,
            cwd: widget.cwd,
            sessionId: widget.sessionId,
            title: widget.title,
            cols: _terminal.viewWidth,
            rows: _terminal.viewHeight,
          );
      if (!mounted) return;
      setState(() {
        _terminalInfo = terminal;
        _starting = false;
      });
      _connectLive(resetAttempts: true);
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

  Future<HostTerminalInfo?> _findReusableTerminal() async {
    if (!widget.reuseExisting) return null;
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

  void _connectLive({bool resetAttempts = false}) {
    final terminal = _terminalInfo;
    if (!mounted || terminal == null || !terminal.isRunning || _connecting) {
      return;
    }
    if (resetAttempts) {
      _reconnectAttempts = 0;
    }
    _subscription?.cancel();
    _channel?.sink.close();
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
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _reconnectTimer?.cancel();
    _reconnectAttempts = (_reconnectAttempts + 1).clamp(1, 6);
    final delayMs = switch (_reconnectAttempts) {
      1 => 500,
      2 => 1000,
      3 => 2000,
      4 => 4000,
      5 => 8000,
      _ => 15000,
    };
    setState(() {
      _connecting = false;
      _error = 'Terminal disconnected. Reconnecting...';
    });
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (mounted) _connectLive();
    });
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
      case 'error':
        final message = frame['message']?.toString() ?? 'Terminal error';
        setState(() => _error = message);
        _terminal.write('\r\n[terminal error] $message\r\n');
        return;
    }
  }

  void _sendInput(String data) {
    if (data.isEmpty || _terminalInfo?.isRunning != true) return;
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode({'type': 'input', 'data': data}));
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
        _terminalInfo = updated;
        _stopping = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _stopping = false);
      showAppSnackBar(context, friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final terminal = _terminalInfo;
    return Column(
      children: [
        _TerminalStatusStrip(
          starting: _starting,
          connecting: _connecting,
          stopping: _stopping,
          error: _error,
          terminal: terminal,
          onStop: _stopTerminal,
        ),
        Expanded(
          child: Container(
            color: const Color(0xFF10120F),
            child: xterm.TerminalView(
              _terminal,
              focusNode: _focusNode,
              autofocus: true,
              keyboardType: TextInputType.text,
              deleteDetection: true,
              theme: const xterm.TerminalTheme(
                cursor: Color(0xFFE8D7A2),
                selection: Color(0x664D8A57),
                foreground: Color(0xFFEDE4C8),
                background: Color(0xFF10120F),
                black: Color(0xFF10120F),
                red: Color(0xFFE06C75),
                green: Color(0xFF7FB069),
                yellow: Color(0xFFE5C07B),
                blue: Color(0xFF61AFEF),
                magenta: Color(0xFFC678DD),
                cyan: Color(0xFF56B6C2),
                white: Color(0xFFEDE4C8),
                brightBlack: Color(0xFF5C6370),
                brightRed: Color(0xFFFF7B85),
                brightGreen: Color(0xFF98C379),
                brightYellow: Color(0xFFFFD580),
                brightBlue: Color(0xFF7DB7FF),
                brightMagenta: Color(0xFFD7A1F9),
                brightCyan: Color(0xFF70D6E0),
                brightWhite: Color(0xFFFFFFFF),
                searchHitBackground: Color(0xFFFFFF2B),
                searchHitBackgroundCurrent: Color(0xFF31FF26),
                searchHitForeground: Color(0xFF000000),
              ),
              textStyle: xterm.TerminalStyle(
                fontSize: widget.compact ? 12 : 13,
                height: 1.22,
              ),
              padding: EdgeInsets.all(widget.compact ? 8 : 10),
            ),
          ),
        ),
        _TerminalKeyBar(onInput: _sendInput, compact: widget.compact),
      ],
    );
  }
}

class _TerminalStatusStrip extends StatelessWidget {
  const _TerminalStatusStrip({
    required this.starting,
    required this.connecting,
    required this.stopping,
    required this.error,
    required this.terminal,
    required this.onStop,
  });

  final bool starting;
  final bool connecting;
  final bool stopping;
  final String? error;
  final HostTerminalInfo? terminal;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = terminal?.isRunning == true;
    final label =
        error ??
        (starting
            ? 'Starting terminal'
            : connecting
            ? 'Connecting'
            : running
            ? 'Live terminal'
            : 'Terminal stopped');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
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
              running ? Icons.bolt_rounded : Icons.stop_circle_outlined,
              size: 16,
              color: error == null
                  ? (running ? colors.success : colors.textSecondary)
                  : colors.danger,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: error == null ? colors.textSecondary : colors.danger,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (terminal != null)
            Text(
              '${terminal!.backend} ${terminal!.cols}x${terminal!.rows}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          if (running) ...[
            const SizedBox(width: 8),
            MeshIconButton(
              icon: Icons.stop_circle_outlined,
              tooltip: 'Stop terminal',
              color: colors.danger,
              onTap: stopping ? () {} : onStop,
            ),
          ],
        ],
      ),
    );
  }
}

class _TerminalKeyBar extends StatelessWidget {
  const _TerminalKeyBar({required this.onInput, required this.compact});

  final ValueChanged<String> onInput;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final keys = <_TerminalKey>[
      const _TerminalKey('Esc', '\x1b'),
      const _TerminalKey('Tab', '\t'),
      const _TerminalKey('Ctrl-C', '\x03'),
      const _TerminalKey('Ctrl-D', '\x04'),
      const _TerminalKey('↑', '\x1b[A'),
      const _TerminalKey('↓', '\x1b[B'),
      const _TerminalKey('←', '\x1b[D'),
      const _TerminalKey('→', '\x1b[C'),
    ];
    return SafeArea(
      top: false,
      child: Container(
        height: compact ? 46 : 52,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8,
          vertical: compact ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemBuilder: (context, index) {
            final key = keys[index];
            return OutlinedButton(
              onPressed: () => onInput(key.sequence),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.textPrimary,
                side: BorderSide(color: colors.border),
                padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 12),
              ),
              child: Text(key.label),
            );
          },
          separatorBuilder: (_, _) => SizedBox(width: compact ? 6 : 8),
          itemCount: keys.length,
        ),
      ),
    );
  }
}

class _TerminalKey {
  const _TerminalKey(this.label, this.sequence);

  final String label;
  final String sequence;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
