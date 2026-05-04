import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide Uint8List;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import '../host_reconnect_scheduler.dart';
import '../host_status_store.dart';

class BrowserPreviewScreen extends StatelessWidget {
  const BrowserPreviewScreen({
    super.key,
    required this.host,
    required this.api,
    required this.preview,
    this.stopOnDispose = false,
  });

  final HostProfile host;
  final ApiClient api;
  final HostBrowserPreviewInfo preview;
  final bool stopOnDispose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        bottom: false,
        child: BrowserPreviewPane(
          host: host,
          api: api,
          preview: preview,
          stopOnDispose: stopOnDispose,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}

class BrowserPreviewPane extends StatefulWidget {
  const BrowserPreviewPane({
    super.key,
    required this.host,
    required this.api,
    required this.preview,
    this.stopOnDispose = false,
    this.showHeader = true,
    this.onBack,
    this.onMinimize,
    this.onStopped,
  });

  final HostProfile host;
  final ApiClient api;
  final HostBrowserPreviewInfo preview;
  final bool stopOnDispose;
  final bool showHeader;
  final VoidCallback? onBack;
  final VoidCallback? onMinimize;
  final void Function(HostBrowserPreviewInfo preview)? onStopped;

  @override
  State<BrowserPreviewPane> createState() => _BrowserPreviewPaneState();
}

class _BrowserPreviewPaneState extends State<BrowserPreviewPane>
    with WidgetsBindingObserver {
  static const _firstFrameTimeout = Duration(seconds: 18);
  static const _maxFirstFrameReconnects = 3;

  final _textController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _browserFocusNode = FocusNode(debugLabel: 'browser-preview-input');
  final _urlFocusNode = FocusNode();
  final _urlController = TextEditingController();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _firstFrameTimer;
  late HostBrowserPreviewInfo _preview;
  late final String _reconnectSlotId;
  Uint8List? _frameBytes;
  int _frameWidth = 390;
  int _frameHeight = 844;
  Size? _lastPreviewBoxSize;
  String? _status = 'Connecting to remote browser...';
  String? _error;
  bool _inputRailConfigured = false;
  bool _inputRailOpen = false;
  bool _clientPaused = false;
  bool _manualPause = false;
  bool _remoteClosed = false;
  int _firstFrameReconnects = 0;
  bool _devToolsOpen = false;
  int _devToolsTabIndex = 0;
  bool _pageLoading = false;
  final List<_ConsoleEntry> _consoleEntries = [];
  final int _maxConsoleEntries = 200;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reconnectSlotId = 'browser-preview-live:${widget.preview.id}';
    HostReconnectScheduler.instance.registerSlot(
      widget.host.id,
      _reconnectSlotId,
      ReconnectPriority.visibleSupport,
      _connect,
    );
    _preview = widget.preview;
    _frameWidth = _preview.width;
    _frameHeight = _preview.height;
    _urlController.text = _preview.url;
    _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _inputFocusNode.dispose();
    _browserFocusNode.dispose();
    _urlFocusNode.dispose();
    _firstFrameTimer?.cancel();
    HostReconnectScheduler.instance.unregisterSlot(
      widget.host.id,
      _reconnectSlotId,
    );
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    if (widget.stopOnDispose) {
      unawaited(widget.api.stopBrowserPreview(widget.host, widget.preview.id));
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inputRailConfigured) return;
    _inputRailConfigured = true;
    _inputRailOpen = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_clientPaused && !_manualPause) {
        _resumeStream();
      }
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _pauseStream(manual: false);
    }
  }

  void _connect() {
    _firstFrameTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    final channel = widget.api.openBrowserPreviewLive(
      widget.host,
      widget.preview.id,
    );
    _channel = channel;
    if (mounted) {
      setState(() {
        _status = _frameBytes == null
            ? 'Connecting to remote browser...'
            : 'Reconnecting stream...';
        _error = null;
      });
    }
    _subscription = channel.stream.listen(
      _handleFrame,
      onError: (error) {
        if (!identical(_channel, channel)) return;
        if (!mounted || _clientPaused) return;
        _firstFrameTimer?.cancel();
        _scheduleStreamReconnect(friendlyError(error));
      },
      onDone: () {
        if (!identical(_channel, channel)) return;
        if (!mounted || _clientPaused) return;
        _firstFrameTimer?.cancel();
        if (_remoteClosed) {
          setState(() {
            _status = 'Remote browser stopped.';
          });
          return;
        }
        _scheduleStreamReconnect('Viewer connection closed.');
      },
      cancelOnError: true,
    );
  }

  void _pauseStream({required bool manual}) {
    if (_clientPaused) return;
    _clientPaused = true;
    _manualPause = manual;
    _firstFrameTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    _subscription = null;
    _channel = null;
    if (!mounted) return;
    setState(() {
      _status = manual
          ? 'Stream paused. The remote browser is still running.'
          : 'Stream paused while the app is in the background.';
    });
  }

  void _resumeStream() {
    if (!_clientPaused) return;
    _clientPaused = false;
    _manualPause = false;
    _remoteClosed = false;
    _connect();
  }

  void _handleFrame(dynamic payload) {
    if (payload is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final frame = decoded;
    final type = frame['type'];
    if (type == 'hello' || type == 'ready' || type == 'preview') {
      final preview = _previewFromMessage(frame);
      if (!mounted) return;
      setState(() {
        if (preview != null) {
          _preview = preview;
          _frameWidth = preview.width;
          _frameHeight = preview.height;
          _urlController.text = preview.url;
        }
        if (type != 'preview') {
          _status = 'Waiting for first frame...';
        }
        _error = null;
      });
      _scheduleFirstFrameWatchdog();
      return;
    }
    if (type == 'frame') {
      final data = frame['data'];
      if (data is! String || data.isEmpty) return;
      final Uint8List bytes;
      try {
        bytes = base64Decode(data);
      } catch (_) {
        return;
      }
      if (!mounted) return;
      _firstFrameTimer?.cancel();
      _firstFrameReconnects = 0;
      HostReconnectScheduler.instance.markConnected(
        widget.host.id,
        _reconnectSlotId,
      );
      HostStatusStore.instance.markEvent(widget.host.id);
      setState(() {
        _frameBytes = bytes;
        _frameWidth = _intValue(frame['width'], _frameWidth);
        _frameHeight = _intValue(frame['height'], _frameHeight);
        _status = null;
        _error = null;
      });
      return;
    }
    if (type == 'error') {
      if (!mounted) return;
      _firstFrameTimer?.cancel();
      final message = frame['message']?.toString() ?? 'Remote browser error';
      setState(() {
        if (_frameBytes == null) {
          _error = message;
          _status = null;
        } else {
          _error = null;
          _status = message;
        }
      });
      return;
    }
    if (type == 'closed') {
      _remoteClosed = true;
      _firstFrameTimer?.cancel();
      final preview = _previewFromMessage(frame);
      if (!mounted) return;
      if (preview != null) {
        _preview = preview;
        widget.onStopped?.call(preview);
      }
      setState(() {
        _status = 'Remote browser stopped.';
        _error = null;
      });
      return;
    }
    if (type == 'console' || type == 'exception' || type == 'log') {
      _handleConsole(frame);
      return;
    }
    if (type == 'loading') {
      final state = frame['state'];
      if (!mounted) return;
      setState(() {
        _pageLoading = state == 'started';
      });
      return;
    }
    if (type == 'navError') {
      if (!mounted) return;
      final url = frame['url']?.toString() ?? '';
      final error = frame['error']?.toString() ?? '';
      setState(() {
        _status = 'Failed to load $url: $error';
      });
      return;
    }
  }

  void _handleConsole(Map<dynamic, dynamic> frame) {
    if (!mounted) return;
    final args = frame['args'];
    var text = frame['text']?.toString() ?? '';
    if (text.isEmpty && args is List) {
      text = args.map((a) {
        if (a is Map && a.containsKey('value')) {
          final v = a['value'];
          return v?.toString() ?? '';
        }
        return a?.toString() ?? '';
      }).join(' ');
    }
    final entry = _ConsoleEntry(
      type: frame['type']?.toString() ?? 'log',
      level: frame['level']?.toString() ?? 'log',
      text: text,
      url: frame['url']?.toString(),
      lineNumber: frame['lineNumber'] is int ? frame['lineNumber'] as int : null,
      columnNumber: frame['columnNumber'] is int ? frame['columnNumber'] as int : null,
      timestamp: frame['timestamp'] is int ? frame['timestamp'] as int : DateTime.now().millisecondsSinceEpoch,
    );
    setState(() {
      _consoleEntries.add(entry);
      if (_consoleEntries.length > _maxConsoleEntries) {
        _consoleEntries.removeAt(0);
      }
    });
  }

  void _scheduleFirstFrameWatchdog() {
    _firstFrameTimer?.cancel();
    if (!mounted || _clientPaused || _frameBytes != null) return;
    _firstFrameTimer = Timer(_firstFrameTimeout, () {
      if (!mounted || _clientPaused || _frameBytes != null) return;
      if (_firstFrameReconnects < _maxFirstFrameReconnects) {
        _firstFrameReconnects += 1;
        setState(() {
          _status =
              'Still waiting for frames. Reconnecting viewer ($_firstFrameReconnects/$_maxFirstFrameReconnects)...';
          _error = null;
        });
        _connect();
        return;
      }
      setState(() {
        _status = null;
        _error =
            'No browser frames arrived. The remote browser may be stuck or overloaded.';
      });
    });
  }

  void _retryPreviewStream() {
    _firstFrameReconnects = 0;
    _frameBytes = null;
    _clientPaused = false;
    _manualPause = false;
    _remoteClosed = false;
    _connect();
  }

  void _scheduleStreamReconnect(String reason) {
    if (!mounted || _clientPaused || _remoteClosed) return;
    HostReconnectScheduler.instance.markDisconnected(
      widget.host.id,
      _reconnectSlotId,
    );
  }

  HostBrowserPreviewInfo? _previewFromMessage(Map<dynamic, dynamic> decoded) {
    final preview = decoded['preview'];
    if (preview is! Map) return null;
    return HostBrowserPreviewInfo.fromJson(preview.cast<String, dynamic>());
  }

  Future<void> _stopRemoteBrowser() async {
    try {
      final stopped = await widget.api.stopBrowserPreview(
        widget.host,
        _preview.id,
      );
      if (!mounted) return;
      widget.onStopped?.call(stopped);
      if (widget.onStopped == null) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not stop browser preview: ${friendlyError(error)}',
      );
    }
  }

  Future<void> _showViewportSheet() async {
    final size = _lastPreviewBoxSize;
    final result = await showModalBottomSheet<_ViewportPreset>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ViewportResizeSheet(
        currentWidth: _preview.width,
        currentHeight: _preview.height,
        fitSize: size,
      ),
    );
    if (result == null || !mounted) return;
    _send({
      'type': 'resize',
      'width': result.width,
      'height': result.height,
    });
  }

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(jsonEncode(message));
    } catch (_) {
      // noop
    }
  }

  void _sendNavigation(String action) {
    _send({'type': 'navigation', 'action': action});
  }

  void _sendKey(String key) {
    _send({'type': 'key', 'key': key});
  }

  void _sendTextPayload(String text) {
    _send({'type': 'text', 'text': text});
  }

  void _sendText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _sendTextPayload(text);
    _textController.clear();
  }

  void _toggleInputRail() {
    if (!_inputRailOpen) {
      _openInputRail();
      return;
    }
    if (!_inputFocusNode.hasFocus) {
      _focusInputRail();
      return;
    }
    _closeInputRail();
  }

  void _openInputRail() {
    setState(() => _inputRailOpen = true);
    _focusInputRail();
  }

  void _closeInputRail() {
    setState(() => _inputRailOpen = false);
    _inputFocusNode.unfocus();
    _browserFocusNode.requestFocus();
  }

  void _focusInputRail() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocusNode.requestFocus();
    });
  }

  void _toggleDevTools() {
    setState(() => _devToolsOpen = !_devToolsOpen);
  }

  void _setDevToolsTab(int index) {
    setState(() => _devToolsTabIndex = index);
  }

  KeyEventResult _handleHardwareKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final hardware = HardwareKeyboard.instance;
    final hasShortcutModifier =
        hardware.isMetaPressed ||
        hardware.isControlPressed ||
        hardware.isAltPressed;
    if (hasShortcutModifier) return KeyEventResult.ignored;

    final specialKey = _browserSpecialKey(event.logicalKey);
    if (specialKey != null) {
      _sendKey(specialKey);
      return KeyEventResult.handled;
    }

    final character = event.character;
    if (character == null ||
        character.isEmpty ||
        character.codeUnits.any((unit) => unit < 32)) {
      return KeyEventResult.ignored;
    }
    _sendTextPayload(character);
    return KeyEventResult.handled;
  }

  String? _browserSpecialKey(LogicalKeyboardKey key) {
    return switch (key) {
      LogicalKeyboardKey.escape => 'Escape',
      LogicalKeyboardKey.tab => 'Tab',
      LogicalKeyboardKey.enter => 'Enter',
      LogicalKeyboardKey.numpadEnter => 'Enter',
      LogicalKeyboardKey.backspace => 'Backspace',
      LogicalKeyboardKey.arrowLeft => 'ArrowLeft',
      LogicalKeyboardKey.arrowUp => 'ArrowUp',
      LogicalKeyboardKey.arrowDown => 'ArrowDown',
      LogicalKeyboardKey.arrowRight => 'ArrowRight',
      _ => null,
    };
  }

  void _sendTap(TapUpDetails details, Size size) {
    _browserFocusNode.requestFocus();
    final point = _mapPoint(details.localPosition, size);
    if (point == null) return;
    _send({'type': 'tap', 'x': point.dx, 'y': point.dy});
  }

  void _sendScroll(DragUpdateDetails details, Size size) {
    final point = _mapPoint(details.localPosition, size);
    if (point == null) return;
    _send({
      'type': 'scroll',
      'x': point.dx,
      'y': point.dy,
      'deltaY': -details.delta.dy * 3,
      'deltaX': -details.delta.dx * 3,
    });
  }

  void _sendNavigate() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    _send({'type': 'navigate', 'url': url});
    _urlFocusNode.unfocus();
  }

  Offset? _mapPoint(Offset localPosition, Size size) {
    final imageRect = _containedImageRect(size);
    if (!imageRect.contains(localPosition)) return null;
    return Offset(
      ((localPosition.dx - imageRect.left) / imageRect.width).clamp(0, 1),
      ((localPosition.dy - imageRect.top) / imageRect.height).clamp(0, 1),
    );
  }

  Rect _containedImageRect(Size size) {
    final frameAspect = _frameWidth / _frameHeight;
    final boxAspect = size.width / size.height;
    if (boxAspect > frameAspect) {
      final width = size.height * frameAspect;
      final left = (size.width - width) / 2;
      return Rect.fromLTWH(left, 0, width, size.height);
    }
    final height = size.width / frameAspect;
    final top = (size.height - height) / 2;
    return Rect.fromLTWH(0, top, size.width, height);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final desktopLike = MediaQuery.sizeOf(context).shortestSide >= 700;
    return Column(
      children: [
        if (widget.showHeader)
          _BrowserChromeBar(
            preview: _preview,
            urlController: _urlController,
            urlFocusNode: _urlFocusNode,
            pageLoading: _pageLoading,
            streamPaused: _clientPaused,
            devToolsOpen: _devToolsOpen,
            onBack: widget.onBack,
            onMinimize: widget.onMinimize,
            onNavigate: _sendNavigate,
            onReload: () => _sendNavigation('reload'),
            onBackNavigation: () => _sendNavigation('back'),
            onForwardNavigation: () => _sendNavigation('forward'),
            onTogglePause: () => _clientPaused ? _resumeStream() : _pauseStream(manual: true),
            onToggleDevTools: _toggleDevTools,
            onStop: () => unawaited(_stopRemoteBrowser()),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: const Color(0xFF07090D),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      _lastPreviewBoxSize = size;
                      return Focus(
                        focusNode: _browserFocusNode,
                        autofocus: desktopLike,
                        onKeyEvent: _handleHardwareKey,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) => _sendTap(details, size),
                          onVerticalDragUpdate: (details) =>
                              _sendScroll(details, size),
                          onHorizontalDragUpdate: (details) =>
                              _sendScroll(details, size),
                          child: _buildPreviewBody(colors),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (_pageLoading && _frameBytes != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    color: colors.accent,
                  ),
                ),
              if (_clientPaused)
                Positioned.fill(
                  child: _PausedPreviewOverlay(
                    manualPause: _manualPause,
                    onResume: _resumeStream,
                  ),
                ),
            ],
          ),
        ),
        _BrowserBottomToolbar(
          preview: _preview,
          streamPaused: _clientPaused,
          inputRailOpen: _inputRailOpen,
          devToolsOpen: _devToolsOpen,
          onBack: () => _sendNavigation('back'),
          onForward: () => _sendNavigation('forward'),
          onReload: () => _sendNavigation('reload'),
          onResize: () => unawaited(_showViewportSheet()),
          onHome: () => _send({'type': 'navigate', 'url': _preview.url}),
          onFocusUrl: () => _urlFocusNode.requestFocus(),
          onToggleInput: _toggleInputRail,
          onToggleDevTools: _toggleDevTools,
          onTogglePause: () => _clientPaused ? _resumeStream() : _pauseStream(manual: true),
        ),
        if (_inputRailOpen)
          _InputRail(
            controller: _textController,
            focusNode: _inputFocusNode,
            onSendText: _sendText,
            onKey: _sendKey,
            onFocusInput: _focusInputRail,
            onClose: _closeInputRail,
            showSpecialKeys: !desktopLike,
          ),
        if (_devToolsOpen)
          _DevToolsPanel(
            tabIndex: _devToolsTabIndex,
            onTabChanged: _setDevToolsTab,
            consoleEntries: _consoleEntries,
            onClearConsole: () => setState(() => _consoleEntries.clear()),
            preview: _preview,
          ),
      ],
    );
  }

  Widget _buildPreviewBody(AppColors colors) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.danger),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _retryPreviewStream,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Reconnect viewer'),
            ),
          ],
        ),
      );
    }
    final bytes = _frameBytes;
    if (bytes == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _status ?? 'Starting remote browser...',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ],
      );
    }
    return Image.memory(
      bytes,
      gaplessPlayback: true,
      fit: BoxFit.contain,
      width: double.infinity,
      height: double.infinity,
    );
  }
}

class _BrowserChromeBar extends StatelessWidget {
  const _BrowserChromeBar({
    required this.preview,
    required this.urlController,
    required this.urlFocusNode,
    required this.pageLoading,
    required this.streamPaused,
    required this.devToolsOpen,
    this.onBack,
    this.onMinimize,
    required this.onNavigate,
    required this.onReload,
    required this.onBackNavigation,
    required this.onForwardNavigation,
    required this.onTogglePause,
    required this.onToggleDevTools,
    required this.onStop,
  });

  final HostBrowserPreviewInfo preview;
  final TextEditingController urlController;
  final FocusNode urlFocusNode;
  final bool pageLoading;
  final bool streamPaused;
  final bool devToolsOpen;
  final VoidCallback? onBack;
  final VoidCallback? onMinimize;
  final VoidCallback onNavigate;
  final VoidCallback onReload;
  final VoidCallback onBackNavigation;
  final VoidCallback onForwardNavigation;
  final VoidCallback onTogglePause;
  final VoidCallback onToggleDevTools;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.border),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            if (onBack != null) ...[
              _ChromeButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back to ports',
                onTap: onBack!,
              ),
              const SizedBox(width: 4),
            ],
            _ChromeButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back',
              onTap: onBackNavigation,
            ),
            const SizedBox(width: 4),
            _ChromeButton(
              icon: Icons.arrow_forward_rounded,
              tooltip: 'Forward',
              onTap: onForwardNavigation,
            ),
            const SizedBox(width: 4),
            _ChromeButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Reload',
              onTap: onReload,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: colors.canvas,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: [
                    if (pageLoading)
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
                        Icons.lock_rounded,
                        size: 14,
                        color: colors.textTertiary,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: urlController,
                        focusNode: urlFocusNode,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: preview.url,
                          hintStyle: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 13,
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) => onNavigate(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ChromeButton(
              icon: devToolsOpen
                  ? Icons.construction_rounded
                  : Icons.construction_outlined,
              tooltip: 'DevTools',
              color: devToolsOpen ? colors.accent : colors.textSecondary,
              onTap: onToggleDevTools,
            ),
            const SizedBox(width: 4),
            _ChromeButton(
              icon: streamPaused
                  ? Icons.play_circle_outline_rounded
                  : Icons.pause_circle_outline_rounded,
              tooltip: streamPaused ? 'Resume' : 'Pause',
              color: streamPaused ? colors.success : colors.textSecondary,
              onTap: onTogglePause,
            ),
            const SizedBox(width: 4),
            if (onMinimize != null) ...[
              _ChromeButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: 'Minimize',
                onTap: onMinimize!,
              ),
              const SizedBox(width: 4),
            ],
            _ChromeButton(
              icon: Icons.stop_circle_rounded,
              tooltip: 'Stop',
              color: colors.danger,
              onTap: onStop,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChromeButton extends StatelessWidget {
  const _ChromeButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 18,
              color: color ?? colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserBottomToolbar extends StatelessWidget {
  const _BrowserBottomToolbar({
    required this.preview,
    required this.streamPaused,
    required this.inputRailOpen,
    required this.devToolsOpen,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onResize,
    required this.onHome,
    required this.onFocusUrl,
    required this.onToggleInput,
    required this.onToggleDevTools,
    required this.onTogglePause,
  });

  final HostBrowserPreviewInfo preview;
  final bool streamPaused;
  final bool inputRailOpen;
  final bool devToolsOpen;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onResize;
  final VoidCallback onHome;
  final VoidCallback onFocusUrl;
  final VoidCallback onToggleInput;
  final VoidCallback onToggleDevTools;
  final VoidCallback onTogglePause;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.border),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _ToolbarButton(
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back',
              onTap: onBack,
            ),
            const SizedBox(width: 4),
            _ToolbarButton(
              icon: Icons.arrow_forward_rounded,
              tooltip: 'Forward',
              onTap: onForward,
            ),
            const SizedBox(width: 4),
            _ToolbarButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Reload',
              onTap: onReload,
            ),
            const SizedBox(width: 4),
            _ToolbarButton(
              icon: Icons.home_rounded,
              tooltip: 'Home',
              onTap: onHome,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: onFocusUrl,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: colors.canvas,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.border),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    preview.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            _ViewportChip(
              width: preview.width,
              height: preview.height,
              onTap: onResize,
            ),
            const SizedBox(width: 6),
            _ToolbarButton(
              icon: devToolsOpen
                  ? Icons.construction_rounded
                  : Icons.construction_outlined,
              tooltip: 'DevTools',
              color: devToolsOpen ? colors.accent : null,
              onTap: onToggleDevTools,
            ),
            const SizedBox(width: 4),
            _ToolbarButton(
              icon: inputRailOpen
                  ? Icons.keyboard_hide_rounded
                  : Icons.keyboard_alt_rounded,
              tooltip: inputRailOpen ? 'Hide keyboard' : 'Keyboard',
              color: inputRailOpen ? colors.accent : null,
              onTap: onToggleInput,
            ),
            const SizedBox(width: 4),
            _ToolbarButton(
              icon: streamPaused
                  ? Icons.play_circle_outline_rounded
                  : Icons.pause_circle_outline_rounded,
              tooltip: streamPaused ? 'Resume' : 'Pause',
              color: streamPaused ? colors.success : null,
              onTap: onTogglePause,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 20,
              color: color ?? colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _DevToolsPanel extends StatelessWidget {
  const _DevToolsPanel({
    required this.tabIndex,
    required this.onTabChanged,
    required this.consoleEntries,
    required this.onClearConsole,
    required this.preview,
  });

  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final List<_ConsoleEntry> consoleEntries;
  final VoidCallback onClearConsole;
  final HostBrowserPreviewInfo preview;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 280,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.border),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 40,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.border),
              ),
            ),
            child: Row(
              children: [
                _DevTab(
                  label: 'Console',
                  active: tabIndex == 0,
                  onTap: () => onTabChanged(0),
                ),
                _DevTab(
                  label: 'Network',
                  active: tabIndex == 1,
                  onTap: () => onTabChanged(1),
                ),
                _DevTab(
                  label: 'Storage',
                  active: tabIndex == 2,
                  onTap: () => onTabChanged(2),
                ),
                _DevTab(
                  label: 'Inspector',
                  active: tabIndex == 3,
                  onTap: () => onTabChanged(3),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  tooltip: 'Clear',
                  onPressed: onClearConsole,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            child: switch (tabIndex) {
              0 => _ConsoleTab(
                entries: consoleEntries,
                preview: preview,
              ),
              _ => Center(
                child: Text(
                  'Coming soon',
                  style: TextStyle(color: colors.textSecondary),
                ),
              ),
            },
          ),
        ],
      ),
    );
  }
}

class _DevTab extends StatelessWidget {
  const _DevTab({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? colors.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: active ? colors.accent : colors.textSecondary,
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _ConsoleTab extends StatelessWidget {
  const _ConsoleTab({
    required this.entries,
    required this.preview,
  });

  final List<_ConsoleEntry> entries;
  final HostBrowserPreviewInfo preview;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'No console output yet.',
          style: TextStyle(color: colors.textSecondary),
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[entries.length - 1 - index];
        return _ConsoleRow(entry: entry, colors: colors);
      },
    );
  }
}

class _ConsoleRow extends StatelessWidget {
  const _ConsoleRow({
    required this.entry,
    required this.colors,
  });

  final _ConsoleEntry entry;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final levelColor = switch (entry.level) {
      'error' => colors.danger,
      'warning' => Colors.orange,
      'info' => colors.accent,
      'debug' => colors.textTertiary,
      _ => colors.textPrimary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 4, right: 8),
            decoration: BoxDecoration(
              color: levelColor,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.text,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
                if (entry.url != null && entry.url!.isNotEmpty)
                  Text(
                    '${entry.url}:${entry.lineNumber ?? 0}',
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsoleEntry {
  const _ConsoleEntry({
    required this.type,
    required this.level,
    required this.text,
    this.url,
    this.lineNumber,
    this.columnNumber,
    required this.timestamp,
  });

  final String type;
  final String level;
  final String text;
  final String? url;
  final int? lineNumber;
  final int? columnNumber;
  final int timestamp;
}

class _PausedPreviewOverlay extends StatelessWidget {
  const _PausedPreviewOverlay({
    required this.manualPause,
    required this.onResume,
  });

  final bool manualPause;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.42)),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: MeshCard(
            tone: MeshCardTone.surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.pause_circle_filled_rounded,
                  size: 34,
                  color: colors.textSecondary,
                ),
                const SizedBox(height: 10),
                Text(
                  manualPause ? 'Viewer paused' : 'Viewer is sleeping',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  manualPause
                      ? 'The remote browser is still running. Resume when you want fresh frames again.'
                      : 'Sidemesh paused the stream while the app was backgrounded. Resume to reconnect.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.textSecondary, height: 1.35),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: onResume,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Resume stream'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InputRail extends StatelessWidget {
  const _InputRail({
    required this.controller,
    required this.focusNode,
    required this.onSendText,
    required this.onKey,
    required this.onFocusInput,
    required this.onClose,
    required this.showSpecialKeys,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSendText;
  final void Function(String key) onKey;
  final VoidCallback onFocusInput;
  final VoidCallback onClose;
  final bool showSpecialKeys;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: MeshCard(
          tone: MeshCardTone.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.keyboard_alt_rounded,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      showSpecialKeys ? 'Page input' : 'Keyboard relay',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onFocusInput,
                    icon: const Icon(Icons.keyboard_rounded, size: 17),
                    label: const Text('Focus'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Hide keyboard',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (showSpecialKeys)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _KeyButton(label: 'Esc', onTap: () => onKey('Escape')),
                      _KeyButton(label: 'Tab', onTap: () => onKey('Tab')),
                      _KeyButton(label: 'Enter', onTap: () => onKey('Enter')),
                      _KeyButton(label: '⌫', onTap: () => onKey('Backspace')),
                      _KeyButton(label: '←', onTap: () => onKey('ArrowLeft')),
                      _KeyButton(label: '↑', onTap: () => onKey('ArrowUp')),
                      _KeyButton(label: '↓', onTap: () => onKey('ArrowDown')),
                      _KeyButton(label: '→', onTap: () => onKey('ArrowRight')),
                    ],
                  ),
                )
              else
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Desktop mode: click the preview and type normally. Use this box for paste-heavy input.',
                    style: TextStyle(color: colors.textSecondary, height: 1.35),
                  ),
                ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        hintText: 'Type text for the remote page',
                      ),
                      onTap: onFocusInput,
                      onSubmitted: (_) => onSendText(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: onSendText,
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.accent,
                    ),
                    child: const Text('Send'),
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

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: OutlinedButton(onPressed: onTap, child: Text(label)),
    );
  }
}

class _ViewportChip extends StatelessWidget {
  const _ViewportChip({
    required this.width,
    required this.height,
    required this.onTap,
  });

  final int width;
  final int height;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colors.accent.withValues(alpha: 0.34)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.aspect_ratio_rounded, size: 14, color: colors.accent),
            const SizedBox(width: 6),
            Text(
              '\$width x \$height',
              style: monoStyle(
                color: colors.accent,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewportPreset {
  const _ViewportPreset(this.label, this.width, this.height, this.description);

  final String label;
  final int width;
  final int height;
  final String description;
}

class _ViewportResizeSheet extends StatefulWidget {
  const _ViewportResizeSheet({
    required this.currentWidth,
    required this.currentHeight,
    required this.fitSize,
  });

  final int currentWidth;
  final int currentHeight;
  final Size? fitSize;

  @override
  State<_ViewportResizeSheet> createState() => _ViewportResizeSheetState();
}

class _ViewportResizeSheetState extends State<_ViewportResizeSheet> {
  late final TextEditingController _widthController;
  late final TextEditingController _heightController;

  @override
  void initState() {
    super.initState();
    _widthController = TextEditingController(
      text: widget.currentWidth.toString(),
    );
    _heightController = TextEditingController(
      text: widget.currentHeight.toString(),
    );
  }

  @override
  void dispose() {
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final presets = <_ViewportPreset>[
      const _ViewportPreset('Phone', 390, 844, 'Mobile portrait'),
      const _ViewportPreset('Phone wide', 844, 390, 'Mobile landscape'),
      const _ViewportPreset('Tablet', 820, 1180, 'Tablet portrait'),
      const _ViewportPreset('Desktop', 1440, 900, 'Laptop browser'),
      if (widget.fitSize != null)
        _ViewportPreset(
          'Fit pane',
          widget.fitSize!.width.clamp(320, 1920).round(),
          widget.fitSize!.height.clamp(320, 1440).round(),
          'Match this Sidemesh pane',
        ),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 0, 18, 18 + keyboardInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Resize browser viewport',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.textPrimary,
                fontWeight: AppWeights.title,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'This changes the remote Chromium viewport, not just the local image scale.',
              style: TextStyle(color: colors.textSecondary, height: 1.35),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in presets)
                  _ViewportPresetButton(
                    preset: preset,
                    selected:
                        preset.width == widget.currentWidth &&
                        preset.height == widget.currentHeight,
                    onTap: () => Navigator.of(context).pop(preset),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _widthController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Width'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _heightController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Height'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submitCustom,
                icon: const Icon(Icons.aspect_ratio_rounded),
                label: const Text('Apply custom viewport'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _submitCustom() {
    final width = int.tryParse(_widthController.text);
    final height = int.tryParse(_heightController.text);
    if (width == null || height == null) return;
    Navigator.of(context).pop(
      _ViewportPreset(
        'Custom',
        width.clamp(320, 3840).toInt(),
        height.clamp(320, 2160).toInt(),
        'Custom viewport',
      ),
    );
  }
}

class _ViewportPresetButton extends StatelessWidget {
  const _ViewportPresetButton({
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final _ViewportPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      borderRadius: AppShapes.input,
      onTap: onTap,
      child: Container(
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? colors.accent.withValues(alpha: 0.14)
              : colors.canvas.withValues(alpha: 0.72),
          borderRadius: AppShapes.input,
          border: Border.all(
            color: selected
                ? colors.accent.withValues(alpha: 0.52)
                : colors.border.withValues(alpha: 0.82),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              preset.label,
              style: TextStyle(
                color: selected ? colors.accent : colors.textPrimary,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${preset.width} x ${preset.height}',
              style: monoStyle(
                color: colors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              preset.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colors.textSecondary, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

int _intValue(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.round();
  return fallback;
}
