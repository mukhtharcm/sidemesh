import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../api_client.dart';
import '../models.dart';
import '../terminal_input_filter.dart';
import '../terminal_key_models.dart';
import '../terminal_modifier_state.dart';
import '../terminal_soft_input_transform.dart';
import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
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
              _terminalLocationLabel(widget.host.label, widget.cwd),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors.textSecondary),
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
  late final xterm.TerminalController _terminalController;
  final FocusNode _focusNode = FocusNode();
  final GlobalKey<xterm.TerminalViewState> _terminalViewKey =
      GlobalKey<xterm.TerminalViewState>();
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
  TerminalModifierState _modifierState = const TerminalModifierState();
  bool _skipNextSoftInputTransform = false;

  @override
  void initState() {
    super.initState();
    _terminalController = xterm.TerminalController();
    _terminalController.addListener(_handleTerminalSelectionChanged);
    _terminal = xterm.Terminal(
      maxLines: 5000,
      onOutput: _sendInput,
      onResize: _handleResize,
    );
    _terminal.write('Starting terminal...\r\n');
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
    _terminal.write('\r\nStarting terminal...\r\n');
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
    _terminalController.removeListener(_handleTerminalSelectionChanged);
    _terminalController.dispose();
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
      _terminal.write('\r\nCould not start terminal: $message\r\n');
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
      _error = 'Connection lost. Reconnecting...';
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
        _terminal.write('\r\nTerminal stopped.\r\n');
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
        final message = frame['message']?.toString() ?? 'Something went wrong';
        setState(() => _error = message);
        _terminal.write('\r\nSomething went wrong: $message\r\n');
        return;
    }
  }

  void _sendInput(String data) {
    if (data.isEmpty || _terminalInfo?.isRunning != true) return;
    var input = _terminal.isUsingAltBuffer
        ? data
        : stripGeneratedTerminalResponses(data);
    if (input.isEmpty) return;
    if (_skipNextSoftInputTransform) {
      _skipNextSoftInputTransform = false;
    } else {
      final transformed = transformTerminalSoftInput(
        input: input,
        modifiers: _modifierState,
      );
      input = transformed.output;
      if (transformed.modifiersConsumed && mounted) {
        setState(() {
          _modifierState = transformed.nextModifierState;
        });
      }
    }
    if (input.isEmpty) return;
    _sendChannelInput(input);
  }

  void _onKeyBarAction(TerminalKeyAction action) {
    if (_terminalInfo?.isRunning != true) return;
    if (action.key != null) {
      _skipNextSoftInputTransform = true;
      _terminal.keyInput(
        action.key!,
        ctrl: action.ctrl,
        alt: action.alt,
        shift: action.shift,
      );
    } else if (action.rawText != null && action.rawText!.isNotEmpty) {
      if (action.hasModifiers) {
        final transformed = transformTerminalSoftInput(
          input: action.rawText!,
          modifiers: TerminalModifierState(
            ctrl: action.ctrl,
            alt: action.alt,
            shift: action.shift,
          ),
        );
        if (transformed.output.isNotEmpty) {
          _sendChannelInput(transformed.output);
        }
      } else {
        _skipNextSoftInputTransform = true;
        _terminal.textInput(action.rawText!);
      }
    }
  }

  void _setModifierState(TerminalModifierState state) {
    if (_modifierState == state) return;
    setState(() => _modifierState = state);
  }

  void _handleTerminalSelectionChanged() {
    if (_terminalController.selection != null) {
      _terminalViewKey.currentState?.closeKeyboard();
    }
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _copySelection() async {
    final selection = _terminalController.selection?.normalized;
    if (selection == null) return;
    final text = _terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    HapticFeedback.selectionClick();
    showAppSnackBar(context, 'Copied selection');
    _terminalController.clearSelection();
  }

  void _selectAll() {
    final viewHeight = _terminal.viewHeight;
    if (viewHeight <= 0) return;
    _terminalController.setSelection(
      _terminal.buffer.createAnchor(0, _terminal.buffer.height - viewHeight),
      _terminal.buffer.createAnchor(_terminal.viewWidth, _terminal.buffer.height - 1),
      mode: xterm.SelectionMode.line,
    );
  }

  void _updateSelectionHandle(_TerminalSelectionHandleSide side, Offset globalPosition) {
    final selection = _terminalController.selection?.normalized;
    final viewState = _terminalViewKey.currentState;
    if (selection == null || viewState == null) return;
    final render = viewState.renderTerminal;
    final local = render.globalToLocal(globalPosition);
    final cell = render.getCellOffset(local);
    final nextStart = side == _TerminalSelectionHandleSide.start
        ? cell
        : selection.begin;
    final nextEnd = side == _TerminalSelectionHandleSide.end
        ? xterm.CellOffset(cell.x + 1, cell.y)
        : selection.end;
    _terminalController.setSelection(
      _terminal.buffer.createAnchorFromOffset(nextStart),
      _terminal.buffer.createAnchorFromOffset(nextEnd),
      mode: xterm.SelectionMode.line,
    );
  }

  void _sendChannelInput(String input) {
    final channel = _channel;
    if (channel == null || input.isEmpty) return;
    channel.sink.add(jsonEncode({'type': 'input', 'data': input}));
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
    _terminal.write(
      '\r\nThis terminal moved to another device. Reconnecting...\r\n',
    );
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
    _terminal.write('\r\nStarting a new terminal...\r\n');
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
                    color: colors.canvas.withValues(alpha: 0.08),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  xterm.TerminalView(
                    _terminal,
                    key: _terminalViewKey,
                    controller: _terminalController,
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
                  _TerminalSelectionOverlay(
                    terminal: _terminal,
                    controller: _terminalController,
                    terminalViewState: _terminalViewKey.currentState,
                    compact: widget.compact,
                    onCopy: _copySelection,
                    onSelectAll: _selectAll,
                    onClearSelection: _terminalController.clearSelection,
                    onHandleDragUpdate: _updateSelectionHandle,
                  ),
                ],
              ),
            ),
          ),
        ),
        TerminalKeyBar(
          compact: widget.compact,
          modifierState: _modifierState,
          onModifierStateChanged: _setModifierState,
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
  Color terminalColor(Color color) =>
      readableTerminalColorOn(colors, preferred: color);

  return xterm.TerminalTheme(
    cursor: visibleUiColorOn(
      colors,
      background: colors.codeBackground,
      preferred: colors.accent,
    ),
    selection: colors.accentMuted.withValues(alpha: 0.7),
    foreground: colors.codeForeground,
    background: colors.codeBackground,
    black: colors.textTertiary,
    red: terminalColor(colors.danger),
    green: terminalColor(colors.success),
    yellow: terminalColor(colors.warning),
    blue: terminalColor(colors.accent),
    magenta: terminalColor(colors.info),
    cyan: terminalColor(colors.info),
    white: colors.codeForeground,
    brightBlack: terminalColor(colors.textSecondary),
    brightRed: terminalColor(_brightTerminalColor(colors.danger)),
    brightGreen: terminalColor(_brightTerminalColor(colors.success)),
    brightYellow: terminalColor(_brightTerminalColor(colors.warning)),
    brightBlue: terminalColor(_brightTerminalColor(colors.accent)),
    brightMagenta: terminalColor(_brightTerminalColor(colors.info)),
    brightCyan: terminalColor(_brightTerminalColor(colors.info)),
    brightWhite: colors.textPrimary,
    searchHitBackground: colors.warningMuted,
    searchHitBackgroundCurrent: colors.accentMuted,
    searchHitForeground: colors.textPrimary,
  );
}

Color _brightTerminalColor(Color color) =>
    Color.lerp(color, const Color(0xFFD8D8D8), 0.18)!;

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
                  ? 'Connected, limited controls'
                  : 'Connected'
            : 'Stopped');
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
                  _terminalSummaryLabel(terminal!),
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
              tooltip: 'Start a new terminal',
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
    if (elapsed.inMinutes < 1) return 'updated ${elapsed.inSeconds}s ago';
    if (elapsed.inHours < 1) return 'updated ${elapsed.inMinutes}m ago';
    return 'updated ${elapsed.inHours}h ago';
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

String _terminalLocationLabel(String hostLabel, String cwd) {
  final trimmed = cwd.trim();
  if (trimmed.isEmpty) return hostLabel;
  final folder = _basename(trimmed);
  if (folder.isEmpty) return '$hostLabel · $trimmed';
  return '$hostLabel · $folder';
}

String _terminalSummaryLabel(HostTerminalInfo terminal) {
  final folder = _basename(terminal.cwd);
  if (folder.isNotEmpty) return folder;
  final trimmed = terminal.cwd.trim();
  if (trimmed.isNotEmpty) return trimmed;
  final title = terminal.title.trim();
  if (title.isNotEmpty) return title;
  return 'Shell';
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

enum _TerminalSelectionHandleSide { start, end }

class _TerminalSelectionOverlay extends StatelessWidget {
  const _TerminalSelectionOverlay({
    required this.terminal,
    required this.controller,
    required this.terminalViewState,
    required this.compact,
    required this.onCopy,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onHandleDragUpdate,
  });

  final xterm.Terminal terminal;
  final xterm.TerminalController controller;
  final xterm.TerminalViewState? terminalViewState;
  final bool compact;
  final Future<void> Function() onCopy;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final void Function(_TerminalSelectionHandleSide side, Offset globalPosition)
  onHandleDragUpdate;

  @override
  Widget build(BuildContext context) {
    final viewState = terminalViewState;
    final selection = controller.selection?.normalized;
    if (viewState == null || selection == null) {
      return const SizedBox.shrink();
    }

    final render = viewState.renderTerminal;
    final cellSize = render.cellSize;
    final startOffset = render.getOffset(selection.begin);
    final endOffset = render.getOffset(selection.end);
    final handleY = cellSize.height;
    final handleRadius = compact ? 8.0 : 9.0;
    final toolbar = AdaptiveTextSelectionToolbar.buttonItems(
      anchors: TextSelectionToolbarAnchors(
        primaryAnchor: _primaryToolbarAnchor(
          cellSize: cellSize,
          startOffset: startOffset,
          endOffset: endOffset,
        ),
        secondaryAnchor: _secondaryToolbarAnchor(
          cellSize: cellSize,
          startOffset: startOffset,
          endOffset: endOffset,
        ),
      ),
      buttonItems: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () => onCopy(),
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: onSelectAll,
        ),
        ContextMenuButtonItem(
          label: 'Done',
          onPressed: onClearSelection,
        ),
      ],
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        toolbar,
        Positioned(
          left: startOffset.dx - handleRadius,
          top: startOffset.dy + handleY - handleRadius,
          child: _TerminalSelectionHandle(
            side: _TerminalSelectionHandleSide.start,
            radius: handleRadius,
            onDragUpdate: onHandleDragUpdate,
          ),
        ),
        Positioned(
          left: endOffset.dx - handleRadius,
          top: endOffset.dy + handleY - handleRadius,
          child: _TerminalSelectionHandle(
            side: _TerminalSelectionHandleSide.end,
            radius: handleRadius,
            onDragUpdate: onHandleDragUpdate,
          ),
        ),
      ],
    );
  }

  Offset _primaryToolbarAnchor({
    required Size cellSize,
    required Offset startOffset,
    required Offset endOffset,
  }) {
    return Offset(
      (startOffset.dx + endOffset.dx) / 2,
      startOffset.dy - 8,
    );
  }

  Offset _secondaryToolbarAnchor({
    required Size cellSize,
    required Offset startOffset,
    required Offset endOffset,
  }) {
    return Offset(
      (startOffset.dx + endOffset.dx) / 2,
      startOffset.dy + cellSize.height + 12,
    );
  }
}

class _TerminalSelectionHandle extends StatelessWidget {
  const _TerminalSelectionHandle({
    required this.side,
    required this.radius,
    required this.onDragUpdate,
  });

  final _TerminalSelectionHandleSide side;
  final double radius;
  final void Function(_TerminalSelectionHandleSide side, Offset globalPosition)
  onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final size = radius * 2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) => onDragUpdate(side, details.globalPosition),
      child: SizedBox(
        width: size + 16,
        height: size + 16,
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: colors.accent,
              shape: BoxShape.circle,
              border: Border.all(color: colors.canvas, width: 2),
              boxShadow: [
                BoxShadow(
                  color: colors.canvas.withValues(alpha: 0.16),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
