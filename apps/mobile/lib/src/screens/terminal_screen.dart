import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart' as xterm;

import '../api_client.dart';
import '../models.dart';
import '../terminal_key_models.dart';
import '../terminal_modifier_state.dart';
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
  late GhosttyTerminalController _controller;
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
  TerminalModifierState _modifierState = TerminalModifierState.none;

  @override
  void initState() {
    super.initState();
    _controller = _buildController();
    _controller.appendDebugOutput('Starting terminal...\r\n');
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
    _resetController(banner: '\r\nStarting terminal...\r\n');
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
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  GhosttyTerminalController _buildController() {
    return GhosttyTerminalController(
      maxLines: 5000,
      maxScrollback: 5000,
      preferPty: false,
    );
  }

  void _resetController({String? banner}) {
    _controller.dispose();
    _controller = _buildController();
    final terminal = _terminalInfo;
    if (terminal != null) {
      _attachControllerTransport(terminal);
    }
    if (banner != null && banner.isNotEmpty) {
      _controller.appendDebugOutput(banner);
    }
  }

  void _attachControllerTransport(HostTerminalInfo terminal) {
    _controller.attachExternalTransport(
      writeBytes: _writeTerminalBytes,
      onResize: _handleGhosttyResize,
      launch: GhosttyTerminalShellLaunch(
        label: terminal.title.isNotEmpty ? terminal.title : 'Remote terminal',
        shell: terminal.shell,
      ),
    );
    _controller.setSessionRunning(terminal.isRunning);
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
            cols: _cols ?? _controller.cols,
            rows: _rows ?? _controller.rows,
            replaceExisting: replaceExisting,
          );
      if (!mounted) return;
      setState(() {
        _terminalInfo = terminal;
        _starting = false;
      });
      _attachControllerTransport(terminal);
      _connectLive();
    } catch (error) {
      if (!mounted) return;
      final message = friendlyError(error);
      setState(() {
        _starting = false;
        _error = message;
      });
      _controller.appendDebugOutput(
        '\r\nCould not start terminal: $message\r\n',
      );
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
          _controller.appendOutputBytes(utf8.encode(data));
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
        _controller.setSessionRunning(false);
        _controller.appendDebugOutput('\r\nTerminal stopped.\r\n');
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
        _controller.appendDebugOutput('\r\nSomething went wrong: $message\r\n');
        return;
    }
  }

  bool _writeTerminalBytes(List<int> bytes) {
    if (bytes.isEmpty || _terminalInfo?.isRunning != true) return false;
    final channel = _channel;
    if (channel == null) return false;
    channel.sink.add(
      jsonEncode({
        'type': 'input',
        'data': utf8.decode(bytes, allowMalformed: true),
      }),
    );
    return true;
  }

  void _onKeyBarAction(TerminalKeyAction action) {
    if (_terminalInfo?.isRunning != true) return;
    if (action.rawText != null && action.rawText!.isNotEmpty) {
      _controller.write(action.rawText!);
      return;
    }
    final key = action.key;
    if (key == null) {
      return;
    }
    final rawText = _plainTextForTerminalKey(key);
    if (!action.hasModifiers && rawText != null) {
      _controller.write(rawText);
      return;
    }
    final ghosttyKey = _ghosttyKeyForTerminalKey(key);
    if (ghosttyKey != null) {
      _controller.sendKey(
        key: ghosttyKey,
        mods: _ghosttyModsForAction(action),
        utf8Text: rawText ?? '',
        unshiftedCodepoint: rawText == null || rawText.isEmpty
            ? 0
            : rawText.runes.first,
      );
    }
  }

  void _setModifierState(TerminalModifierState state) {
    if (_modifierState == state || !mounted) {
      return;
    }
    setState(() => _modifierState = state);
  }

  void _clearModifiers() {
    if (!_modifierState.hasModifiers) {
      return;
    }
    _setModifierState(TerminalModifierState.none);
  }

  Uri? _selectionLinkUri(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null) {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'mailto') {
      return uri.path.isEmpty ? null : uri;
    }
    if ((scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty) {
      return uri;
    }
    return null;
  }

  Future<void> _openTerminalUri(Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showAppSnackBar(context, 'Could not open link');
    }
  }

  List<ContextMenuButtonItem> _selectionContextMenuButtonItems(
    GhosttyTerminalSelectionContextMenuDetails details,
  ) {
    final uri = _selectionLinkUri(details.selectedText);
    if (uri == null) {
      return details.defaultButtonItems;
    }
    return <ContextMenuButtonItem>[
      ContextMenuButtonItem(
        label: 'Open link',
        onPressed: () {
          details.hideToolbar();
          unawaited(_openTerminalUri(uri));
        },
      ),
      ...details.defaultButtonItems,
    ];
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
    _attachControllerTransport(replacement);
    _controller.appendDebugOutput(
      '\r\nThis terminal moved to another device. Reconnecting...\r\n',
    );
    _connectLive();
  }

  void _handleGhosttyResize(
    int cols,
    int rows,
    int cellWidthPx,
    int cellHeightPx,
  ) {
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
    _resetController(banner: '\r\nStarting a new terminal...\r\n');
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
              child: GhosttyTerminalView(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                showHeader: false,
                backgroundColor: colors.codeBackground,
                foregroundColor: colors.codeForeground,
                chromeColor: colors.surfaceElevated,
                fontSize: widget.compact ? 12 : 13,
                lineHeight: 1.22,
                fontFamily: 'JetBrainsMono',
                fontFamilyFallback: const ['SpaceGrotesk'],
                padding: EdgeInsets.all(widget.compact ? 10 : 12),
                selectionColor: colors.accentMuted.withValues(alpha: 0.7),
                hyperlinkColor: colors.accent,
                scrollbarThumbColor: colors.textTertiary.withValues(alpha: 0.6),
                scrollbarTrackColor: colors.canvas.withValues(alpha: 0.14),
                copyOptions: const GhosttyTerminalCopyOptions(
                  joinWrappedLines: true,
                ),
                selectionContextMenuButtonItemsBuilder:
                    _selectionContextMenuButtonItems,
                onOpenHyperlink: (uri) async {
                  final target = Uri.tryParse(uri);
                  if (target == null) {
                    return;
                  }
                  await _openTerminalUri(target);
                },
              ),
            ),
          ),
        ),
        GhosttyTerminalSoftInputBridge(
          focusNode: _focusNode,
          controller: _controller,
          modifiers: GhosttyTerminalSoftInputModifiers(
            ctrl: _modifierState.ctrl,
            alt: _modifierState.alt,
            shift: _modifierState.shift,
          ),
          onModifiersConsumed: _clearModifiers,
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

GhosttyKey? _ghosttyKeyForTerminalKey(xterm.TerminalKey key) {
  switch (key) {
    case xterm.TerminalKey.keyA:
      return GhosttyKey.GHOSTTY_KEY_A;
    case xterm.TerminalKey.keyB:
      return GhosttyKey.GHOSTTY_KEY_B;
    case xterm.TerminalKey.keyC:
      return GhosttyKey.GHOSTTY_KEY_C;
    case xterm.TerminalKey.keyD:
      return GhosttyKey.GHOSTTY_KEY_D;
    case xterm.TerminalKey.keyE:
      return GhosttyKey.GHOSTTY_KEY_E;
    case xterm.TerminalKey.keyF:
      return GhosttyKey.GHOSTTY_KEY_F;
    case xterm.TerminalKey.keyG:
      return GhosttyKey.GHOSTTY_KEY_G;
    case xterm.TerminalKey.keyH:
      return GhosttyKey.GHOSTTY_KEY_H;
    case xterm.TerminalKey.keyI:
      return GhosttyKey.GHOSTTY_KEY_I;
    case xterm.TerminalKey.keyJ:
      return GhosttyKey.GHOSTTY_KEY_J;
    case xterm.TerminalKey.keyK:
      return GhosttyKey.GHOSTTY_KEY_K;
    case xterm.TerminalKey.keyL:
      return GhosttyKey.GHOSTTY_KEY_L;
    case xterm.TerminalKey.keyM:
      return GhosttyKey.GHOSTTY_KEY_M;
    case xterm.TerminalKey.keyN:
      return GhosttyKey.GHOSTTY_KEY_N;
    case xterm.TerminalKey.keyO:
      return GhosttyKey.GHOSTTY_KEY_O;
    case xterm.TerminalKey.keyP:
      return GhosttyKey.GHOSTTY_KEY_P;
    case xterm.TerminalKey.keyQ:
      return GhosttyKey.GHOSTTY_KEY_Q;
    case xterm.TerminalKey.keyR:
      return GhosttyKey.GHOSTTY_KEY_R;
    case xterm.TerminalKey.keyS:
      return GhosttyKey.GHOSTTY_KEY_S;
    case xterm.TerminalKey.keyT:
      return GhosttyKey.GHOSTTY_KEY_T;
    case xterm.TerminalKey.keyU:
      return GhosttyKey.GHOSTTY_KEY_U;
    case xterm.TerminalKey.keyV:
      return GhosttyKey.GHOSTTY_KEY_V;
    case xterm.TerminalKey.keyW:
      return GhosttyKey.GHOSTTY_KEY_W;
    case xterm.TerminalKey.keyX:
      return GhosttyKey.GHOSTTY_KEY_X;
    case xterm.TerminalKey.keyY:
      return GhosttyKey.GHOSTTY_KEY_Y;
    case xterm.TerminalKey.keyZ:
      return GhosttyKey.GHOSTTY_KEY_Z;
    case xterm.TerminalKey.digit0:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_0;
    case xterm.TerminalKey.digit1:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_1;
    case xterm.TerminalKey.digit2:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_2;
    case xterm.TerminalKey.digit3:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_3;
    case xterm.TerminalKey.digit4:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_4;
    case xterm.TerminalKey.digit5:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_5;
    case xterm.TerminalKey.digit6:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_6;
    case xterm.TerminalKey.digit7:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_7;
    case xterm.TerminalKey.digit8:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_8;
    case xterm.TerminalKey.digit9:
      return GhosttyKey.GHOSTTY_KEY_DIGIT_9;
    case xterm.TerminalKey.enter:
      return GhosttyKey.GHOSTTY_KEY_ENTER;
    case xterm.TerminalKey.escape:
      return GhosttyKey.GHOSTTY_KEY_ESCAPE;
    case xterm.TerminalKey.backspace:
      return GhosttyKey.GHOSTTY_KEY_BACKSPACE;
    case xterm.TerminalKey.tab:
      return GhosttyKey.GHOSTTY_KEY_TAB;
    case xterm.TerminalKey.space:
      return GhosttyKey.GHOSTTY_KEY_SPACE;
    case xterm.TerminalKey.minus:
      return GhosttyKey.GHOSTTY_KEY_MINUS;
    case xterm.TerminalKey.equal:
      return GhosttyKey.GHOSTTY_KEY_EQUAL;
    case xterm.TerminalKey.bracketLeft:
      return GhosttyKey.GHOSTTY_KEY_BRACKET_LEFT;
    case xterm.TerminalKey.bracketRight:
      return GhosttyKey.GHOSTTY_KEY_BRACKET_RIGHT;
    case xterm.TerminalKey.backslash:
      return GhosttyKey.GHOSTTY_KEY_BACKSLASH;
    case xterm.TerminalKey.semicolon:
      return GhosttyKey.GHOSTTY_KEY_SEMICOLON;
    case xterm.TerminalKey.quote:
      return GhosttyKey.GHOSTTY_KEY_QUOTE;
    case xterm.TerminalKey.backquote:
      return GhosttyKey.GHOSTTY_KEY_BACKQUOTE;
    case xterm.TerminalKey.comma:
      return GhosttyKey.GHOSTTY_KEY_COMMA;
    case xterm.TerminalKey.period:
      return GhosttyKey.GHOSTTY_KEY_PERIOD;
    case xterm.TerminalKey.slash:
      return GhosttyKey.GHOSTTY_KEY_SLASH;
    case xterm.TerminalKey.insert:
      return GhosttyKey.GHOSTTY_KEY_INSERT;
    case xterm.TerminalKey.home:
      return GhosttyKey.GHOSTTY_KEY_HOME;
    case xterm.TerminalKey.pageUp:
      return GhosttyKey.GHOSTTY_KEY_PAGE_UP;
    case xterm.TerminalKey.delete:
      return GhosttyKey.GHOSTTY_KEY_DELETE;
    case xterm.TerminalKey.end:
      return GhosttyKey.GHOSTTY_KEY_END;
    case xterm.TerminalKey.pageDown:
      return GhosttyKey.GHOSTTY_KEY_PAGE_DOWN;
    case xterm.TerminalKey.arrowRight:
      return GhosttyKey.GHOSTTY_KEY_ARROW_RIGHT;
    case xterm.TerminalKey.arrowLeft:
      return GhosttyKey.GHOSTTY_KEY_ARROW_LEFT;
    case xterm.TerminalKey.arrowDown:
      return GhosttyKey.GHOSTTY_KEY_ARROW_DOWN;
    case xterm.TerminalKey.arrowUp:
      return GhosttyKey.GHOSTTY_KEY_ARROW_UP;
    case xterm.TerminalKey.f1:
      return GhosttyKey.GHOSTTY_KEY_F1;
    case xterm.TerminalKey.f2:
      return GhosttyKey.GHOSTTY_KEY_F2;
    case xterm.TerminalKey.f3:
      return GhosttyKey.GHOSTTY_KEY_F3;
    case xterm.TerminalKey.f4:
      return GhosttyKey.GHOSTTY_KEY_F4;
    case xterm.TerminalKey.f5:
      return GhosttyKey.GHOSTTY_KEY_F5;
    case xterm.TerminalKey.f6:
      return GhosttyKey.GHOSTTY_KEY_F6;
    case xterm.TerminalKey.f7:
      return GhosttyKey.GHOSTTY_KEY_F7;
    case xterm.TerminalKey.f8:
      return GhosttyKey.GHOSTTY_KEY_F8;
    case xterm.TerminalKey.f9:
      return GhosttyKey.GHOSTTY_KEY_F9;
    case xterm.TerminalKey.f10:
      return GhosttyKey.GHOSTTY_KEY_F10;
    case xterm.TerminalKey.f11:
      return GhosttyKey.GHOSTTY_KEY_F11;
    case xterm.TerminalKey.f12:
      return GhosttyKey.GHOSTTY_KEY_F12;
    default:
      return null;
  }
}

String? _plainTextForTerminalKey(xterm.TerminalKey key) {
  switch (key) {
    case xterm.TerminalKey.keyA:
      return 'a';
    case xterm.TerminalKey.keyB:
      return 'b';
    case xterm.TerminalKey.keyC:
      return 'c';
    case xterm.TerminalKey.keyD:
      return 'd';
    case xterm.TerminalKey.keyE:
      return 'e';
    case xterm.TerminalKey.keyF:
      return 'f';
    case xterm.TerminalKey.keyG:
      return 'g';
    case xterm.TerminalKey.keyH:
      return 'h';
    case xterm.TerminalKey.keyI:
      return 'i';
    case xterm.TerminalKey.keyJ:
      return 'j';
    case xterm.TerminalKey.keyK:
      return 'k';
    case xterm.TerminalKey.keyL:
      return 'l';
    case xterm.TerminalKey.keyM:
      return 'm';
    case xterm.TerminalKey.keyN:
      return 'n';
    case xterm.TerminalKey.keyO:
      return 'o';
    case xterm.TerminalKey.keyP:
      return 'p';
    case xterm.TerminalKey.keyQ:
      return 'q';
    case xterm.TerminalKey.keyR:
      return 'r';
    case xterm.TerminalKey.keyS:
      return 's';
    case xterm.TerminalKey.keyT:
      return 't';
    case xterm.TerminalKey.keyU:
      return 'u';
    case xterm.TerminalKey.keyV:
      return 'v';
    case xterm.TerminalKey.keyW:
      return 'w';
    case xterm.TerminalKey.keyX:
      return 'x';
    case xterm.TerminalKey.keyY:
      return 'y';
    case xterm.TerminalKey.keyZ:
      return 'z';
    case xterm.TerminalKey.digit0:
      return '0';
    case xterm.TerminalKey.digit1:
      return '1';
    case xterm.TerminalKey.digit2:
      return '2';
    case xterm.TerminalKey.digit3:
      return '3';
    case xterm.TerminalKey.digit4:
      return '4';
    case xterm.TerminalKey.digit5:
      return '5';
    case xterm.TerminalKey.digit6:
      return '6';
    case xterm.TerminalKey.digit7:
      return '7';
    case xterm.TerminalKey.digit8:
      return '8';
    case xterm.TerminalKey.digit9:
      return '9';
    case xterm.TerminalKey.space:
      return ' ';
    case xterm.TerminalKey.minus:
      return '-';
    case xterm.TerminalKey.equal:
      return '=';
    case xterm.TerminalKey.bracketLeft:
      return '[';
    case xterm.TerminalKey.bracketRight:
      return ']';
    case xterm.TerminalKey.backslash:
      return r'\';
    case xterm.TerminalKey.semicolon:
      return ';';
    case xterm.TerminalKey.quote:
      return "'";
    case xterm.TerminalKey.backquote:
      return '`';
    case xterm.TerminalKey.comma:
      return ',';
    case xterm.TerminalKey.period:
      return '.';
    case xterm.TerminalKey.slash:
      return '/';
    default:
      return null;
  }
}

int _ghosttyModsForAction(TerminalKeyAction action) {
  var mods = 0;
  if (action.ctrl) {
    mods |= GhosttyModsMask.ctrl;
  }
  if (action.alt) {
    mods |= GhosttyModsMask.alt;
  }
  if (action.shift) {
    mods |= GhosttyModsMask.shift;
  }
  return mods;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
