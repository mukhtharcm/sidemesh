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
import '../widgets/terminal_keybar.dart';
import '../host_reconnect_scheduler.dart';
import '../host_status_store.dart';

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
  TerminalPaneAppBarControls _appBarControls =
      const TerminalPaneAppBarControls();

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
        actions: [
          if (_appBarControls.showRestart)
            IconButton(
              tooltip: 'Start a new terminal',
              onPressed: _appBarControls.onRestart,
              icon: const Icon(Icons.restart_alt_rounded),
            )
          else if (_appBarControls.showStop)
            IconButton(
              tooltip: 'Stop terminal',
              onPressed: _appBarControls.stopping
                  ? null
                  : _appBarControls.onStop,
              icon: _appBarControls.stopping
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.danger,
                      ),
                    )
                  : Icon(Icons.stop_circle_rounded, color: colors.danger),
            ),
        ],
      ),
      body: TerminalPane(
        host: widget.host,
        api: widget.api,
        cwd: widget.cwd,
        sessionId: widget.sessionId,
        title: widget.title,
        reuseExisting: true,
        onAppBarControlsChanged: (controls) {
          if (_appBarControls == controls) return;
          setState(() => _appBarControls = controls);
        },
      ),
    );
  }
}

class TerminalPaneAppBarControls {
  const TerminalPaneAppBarControls({
    this.showStop = false,
    this.showRestart = false,
    this.stopping = false,
    this.onStop,
    this.onRestart,
  });

  final bool showStop;
  final bool showRestart;
  final bool stopping;
  final VoidCallback? onStop;
  final VoidCallback? onRestart;

  @override
  bool operator ==(Object other) {
    return other is TerminalPaneAppBarControls &&
        other.showStop == showStop &&
        other.showRestart == showRestart &&
        other.stopping == stopping;
  }

  @override
  int get hashCode => Object.hash(showStop, showRestart, stopping);
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
    this.onAppBarControlsChanged,
  });

  final HostProfile host;
  final ApiClient api;
  final String cwd;
  final String? sessionId;
  final String? title;
  final bool reuseExisting;
  final bool compact;
  final ValueChanged<TerminalPaneAppBarControls>? onAppBarControlsChanged;

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
  TerminalPaneAppBarControls _lastAppBarControls =
      const TerminalPaneAppBarControls();
  TerminalModifierState _modifierState = const TerminalModifierState();
  bool _skipNextSoftInputTransform = false;
  Offset? _contextMenuAnchor;
  Offset? _selectionLongPressOrigin;

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
      _contextMenuAnchor = null;
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

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      showAppSnackBar(context, 'Clipboard is empty');
      return;
    }
    _terminal.paste(text);
    if (!mounted) return;
    HapticFeedback.selectionClick();
    setState(() {
      _contextMenuAnchor = null;
      _selectionLongPressOrigin = null;
    });
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

  void _beginTerminalContextMenuSelection(Offset localPosition) {
    final viewState = _terminalViewKey.currentState;
    if (viewState == null) return;
    viewState.closeKeyboard();
    final render = viewState.renderTerminal;
    final wordBoundary = _terminal.buffer.getWordBoundary(
      render.getCellOffset(localPosition),
    );
    setState(() {
      _selectionLongPressOrigin = localPosition;
      _contextMenuAnchor = wordBoundary == null ? localPosition : null;
    });
    if (wordBoundary != null) {
      render.selectWord(localPosition);
    }
  }

  void _updateTerminalContextSelection(Offset localPosition) {
    final origin = _selectionLongPressOrigin;
    final viewState = _terminalViewKey.currentState;
    if (origin == null || viewState == null) return;
    final render = viewState.renderTerminal;
    if (_terminalController.selection != null) {
      render.selectWord(origin, localPosition);
    } else {
      setState(() => _contextMenuAnchor = localPosition);
    }
  }

  void _clearContextMenuAnchor() {
    if (_contextMenuAnchor == null && _selectionLongPressOrigin == null) return;
    setState(() {
      _contextMenuAnchor = null;
      _selectionLongPressOrigin = null;
    });
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
    final appBarControls = _currentAppBarControls(terminal);
    if (_lastAppBarControls != appBarControls) {
      _lastAppBarControls = appBarControls;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onAppBarControlsChanged?.call(appBarControls);
      });
    }
    return Column(
      children: [
        _TerminalNoticeBanner(
          starting: _starting,
          connecting: _connecting,
          error: _error,
          terminal: terminal,
        ),
        Expanded(
          child: Container(
            color: colors.codeBackground,
            child: Container(
              margin: EdgeInsets.fromLTRB(
                widget.compact ? 4 : 6,
                widget.compact ? 2 : 4,
                widget.compact ? 4 : 6,
                widget.compact ? 4 : 6,
              ),
              decoration: BoxDecoration(
                color: colors.codeBackground,
                border: Border.all(color: colors.codeBorder),
                borderRadius: BorderRadius.circular(widget.compact ? 10 : 12),
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
                  Positioned.fill(
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) {
                        if (_contextMenuAnchor != null) {
                          _clearContextMenuAnchor();
                        }
                      },
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onLongPressStart: (details) =>
                            _beginTerminalContextMenuSelection(
                              details.localPosition,
                            ),
                        onLongPressMoveUpdate: (details) =>
                            _updateTerminalContextSelection(
                              details.localPosition,
                            ),
                      ),
                    ),
                  ),
                  _TerminalSelectionOverlay(
                    terminal: _terminal,
                    controller: _terminalController,
                    terminalViewState: _terminalViewKey.currentState,
                    compact: widget.compact,
                    contextMenuAnchor: _contextMenuAnchor,
                    onCopy: _copySelection,
                    onPaste: _pasteClipboard,
                    onSelectAll: _selectAll,
                    onClearSelection: () {
                      _terminalController.clearSelection();
                      _clearContextMenuAnchor();
                    },
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

  TerminalPaneAppBarControls _currentAppBarControls(
    HostTerminalInfo? terminal,
  ) {
    final running = terminal?.isRunning == true;
    final canRestart =
        !running &&
        !_starting &&
        !_connecting &&
        (terminal != null || _error != null);
    return TerminalPaneAppBarControls(
      showStop: running,
      showRestart: canRestart,
      stopping: _stopping,
      onStop: _stopTerminal,
      onRestart: _restartTerminal,
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

class _TerminalNoticeBanner extends StatelessWidget {
  const _TerminalNoticeBanner({
    required this.starting,
    required this.connecting,
    required this.error,
    required this.terminal,
  });

  final bool starting;
  final bool connecting;
  final String? error;
  final HostTerminalInfo? terminal;

  @override
  Widget build(BuildContext context) {
    final state = _bannerState(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 140),
      child: state == null
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey(state.label),
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: state.background,
                    border: Border.all(color: state.border),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (state.spinner)
                          SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.8,
                              color: state.foreground,
                            ),
                          )
                        else
                          Icon(
                            state.icon,
                            size: 12,
                            color: state.foreground,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          state.label,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: state.foreground,
                                fontWeight: AppWeights.emphasis,
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

  _TerminalBannerState? _bannerState(BuildContext context) {
    final colors = context.colors;
    final running = terminal?.isRunning == true;
    final limitedBackend = terminal?.backend == 'pipe';
    if (error != null && error!.trim().isNotEmpty) {
      return _TerminalBannerState(
        icon: Icons.error_outline_rounded,
        label: error!,
        background: colors.dangerMuted,
        border: colors.danger.withValues(alpha: 0.25),
        foreground: colors.danger,
      );
    }
    if (starting) {
      return _TerminalBannerState(
        icon: Icons.sync_rounded,
        label: 'Starting terminal',
        background: colors.surfaceElevated,
        border: colors.border,
        foreground: colors.textSecondary,
        spinner: true,
      );
    }
    if (connecting) {
      return _TerminalBannerState(
        icon: Icons.sync_rounded,
        label: 'Reconnecting…',
        background: colors.surfaceElevated,
        border: colors.border,
        foreground: colors.textSecondary,
        spinner: true,
      );
    }
    if (!running && terminal != null) {
      return _TerminalBannerState(
        icon: Icons.stop_circle_outlined,
        label: 'Terminal stopped',
        background: colors.surfaceElevated,
        border: colors.border,
        foreground: colors.textSecondary,
      );
    }
    if (limitedBackend) {
      return _TerminalBannerState(
        icon: Icons.info_outline_rounded,
        label: 'Limited terminal access',
        background: colors.infoMuted,
        border: colors.info.withValues(alpha: 0.24),
        foreground: colors.info,
      );
    }
    return null;
  }
}

class _TerminalBannerState {
  const _TerminalBannerState({
    required this.icon,
    required this.label,
    required this.background,
    required this.border,
    required this.foreground,
    this.spinner = false,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color border;
  final Color foreground;
  final bool spinner;
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
    required this.contextMenuAnchor,
    required this.onCopy,
    required this.onPaste,
    required this.onSelectAll,
    required this.onClearSelection,
    required this.onHandleDragUpdate,
  });

  final xterm.Terminal terminal;
  final xterm.TerminalController controller;
  final xterm.TerminalViewState? terminalViewState;
  final bool compact;
  final Offset? contextMenuAnchor;
  final Future<void> Function() onCopy;
  final Future<void> Function() onPaste;
  final VoidCallback onSelectAll;
  final VoidCallback onClearSelection;
  final void Function(_TerminalSelectionHandleSide side, Offset globalPosition)
  onHandleDragUpdate;

  @override
  Widget build(BuildContext context) {
    final viewState = terminalViewState;
    if (viewState == null) {
      return const SizedBox.shrink();
    }

    final selection = controller.selection?.normalized;
    final render = viewState.renderTerminal;
    if (selection == null) {
      final anchor = contextMenuAnchor;
      if (anchor == null) {
        return const SizedBox.shrink();
      }
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: TextSelectionToolbarAnchors(
          primaryAnchor: anchor,
          secondaryAnchor: anchor,
        ),
        buttonItems: [
          ContextMenuButtonItem(
            type: ContextMenuButtonType.paste,
            onPressed: () => onPaste(),
          ),
          ContextMenuButtonItem(
            type: ContextMenuButtonType.selectAll,
            onPressed: onSelectAll,
          ),
        ],
      );
    }

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
          type: ContextMenuButtonType.paste,
          onPressed: () => onPaste(),
        ),
        ContextMenuButtonItem(
          type: ContextMenuButtonType.selectAll,
          onPressed: onSelectAll,
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
