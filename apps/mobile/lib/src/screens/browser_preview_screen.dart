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
import '../relative_time_ticker.dart';

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

  /// When false, leaving the route only detaches this viewer. The daemon-side
  /// browser remains alive so the user can return from chat without reloading.
  final bool stopOnDispose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        title: const Text('Stream pixels'),
      ),
      body: BrowserPreviewPane(
        host: host,
        api: api,
        preview: preview,
        stopOnDispose: stopOnDispose,
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
    _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _inputFocusNode.dispose();
    _browserFocusNode.dispose();
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
          // Capture errors are often transient. Keep showing the last good
          // frame instead of blanking the preview while the daemon recovers.
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
    }
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
        'Could not stop remote browser: ${friendlyError(error)}',
      );
    }
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _channel?.sink.add(jsonEncode(payload));
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, 'Could not send input: ${friendlyError(error)}');
    }
  }

  void _sendText() {
    final text = _textController.text;
    if (text.isEmpty) return;
    _sendTextPayload(text);
    _textController.clear();
  }

  void _sendTextPayload(String text) {
    _send({'type': 'text', 'text': text});
  }

  void _sendKey(String key) {
    _send({'type': 'key', 'key': key});
  }

  void _sendNavigation(String action) {
    _send({'type': 'navigation', 'action': action});
  }

  void _sendResize(int width, int height) {
    _send({'type': 'resize', 'width': width, 'height': height});
  }

  Future<void> _showViewportSheet() async {
    final selected = await showModalBottomSheet<_ViewportPreset>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: context.colors.surface,
      builder: (context) => _ViewportResizeSheet(
        currentWidth: _frameWidth,
        currentHeight: _frameHeight,
        fitSize: _lastPreviewBoxSize,
      ),
    );
    if (selected == null || !mounted) return;
    _sendResize(selected.width, selected.height);
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
          _PreviewHeader(
            hostId: widget.host.id,
            preview: _preview,
            connected: _error == null && _status == null,
            streamPaused: _clientPaused,
            inputRailOpen: _inputRailOpen,
            onBack: widget.onBack,
            onMinimize: widget.onMinimize,
            onToggleInput: _toggleInputRail,
            onPause: () => _pauseStream(manual: true),
            onResume: _resumeStream,
            onStop: () => unawaited(_stopRemoteBrowser()),
          ),
        _BrowserControlStrip(
          preview: _preview,
          streamPaused: _clientPaused,
          onBack: () => _sendNavigation('back'),
          onForward: () => _sendNavigation('forward'),
          onReload: () => _sendNavigation('reload'),
          onResize: () => unawaited(_showViewportSheet()),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              widget.showHeader ? 10 : 12,
              widget.showHeader ? 0 : 12,
              widget.showHeader ? 10 : 12,
              10,
            ),
            child: MeshCard(
              tone: MeshCardTone.elevated,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
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
                              child: Container(
                                color: const Color(0xFF07090D),
                                alignment: Alignment.center,
                                child: _buildPreviewBody(colors),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  if (_clientPaused)
                    Positioned.fill(
                      child: _PausedPreviewOverlay(
                        manualPause: _manualPause,
                        onResume: _resumeStream,
                      ),
                    ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: _PreviewFloatingControls(
                      inputRailOpen: _inputRailOpen,
                      onToggleInput: _toggleInputRail,
                    ),
                  ),
                ],
              ),
            ),
          ),
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

class _BrowserControlStrip extends StatelessWidget {
  const _BrowserControlStrip({
    required this.preview,
    required this.streamPaused,
    required this.onBack,
    required this.onForward,
    required this.onReload,
    required this.onResize,
  });

  final HostBrowserPreviewInfo preview;
  final bool streamPaused;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onReload;
  final VoidCallback onResize;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.border.withValues(alpha: 0.72)),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              _BrowserBarButton(
                icon: Icons.arrow_back_rounded,
                label: 'Back',
                onTap: streamPaused ? null : onBack,
              ),
              _BrowserBarButton(
                icon: Icons.arrow_forward_rounded,
                label: 'Forward',
                onTap: streamPaused ? null : onForward,
              ),
              _BrowserBarButton(
                icon: Icons.refresh_rounded,
                label: 'Reload',
                onTap: streamPaused ? null : onReload,
              ),
              Container(
                width: 1,
                height: 24,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: colors.border.withValues(alpha: 0.72),
              ),
              _ViewportChip(
                width: preview.width,
                height: preview.height,
                onTap: streamPaused ? null : onResize,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrowserBarButton extends StatelessWidget {
  const _BrowserBarButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 140),
            opacity: enabled ? 1 : 0.42,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: enabled
                    ? colors.canvas.withValues(alpha: 0.74)
                    : colors.canvas.withValues(alpha: 0.36),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colors.border.withValues(alpha: enabled ? 0.72 : 0.38),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17, color: colors.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                      fontWeight: AppWeights.title,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: 0.11),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colors.accent.withValues(alpha: 0.34)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.aspect_ratio_rounded, size: 16, color: colors.accent),
            const SizedBox(width: 7),
            Text(
              '$width x $height',
              style: monoStyle(
                color: colors.accent,
                fontSize: 12,
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

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({
    required this.hostId,
    required this.preview,
    required this.connected,
    required this.streamPaused,
    required this.inputRailOpen,
    required this.onToggleInput,
    required this.onPause,
    required this.onResume,
    required this.onStop,
    this.onBack,
    this.onMinimize,
  });

  final String hostId;
  final HostBrowserPreviewInfo preview;
  final bool connected;
  final bool streamPaused;
  final bool inputRailOpen;
  final VoidCallback onToggleInput;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;
  final VoidCallback? onBack;
  final VoidCallback? onMinimize;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      child: MeshCard(
        tone: MeshCardTone.surface,
        child: Row(
          children: [
            if (onBack != null) ...[
              MeshIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back to ports',
                onTap: onBack!,
              ),
              const SizedBox(width: 8),
            ],
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
              ),
              child: Icon(
                Icons.screenshot_monitor_rounded,
                color: colors.accent,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          HostStatusStore.instance,
                          RelativeTimeTicker.instance,
                        ]),
                        builder: (context, _) {
                          final status = HostStatusStore.instance.statusFor(
                            hostId,
                          );
                          final pill = _browserPreviewPill(status);
                          return MeshPill(
                            label: streamPaused
                                ? 'paused'
                                : connected
                                ? (pill.label ?? 'live')
                                : preview.status,
                            tone: streamPaused
                                ? MeshPillTone.warning
                                : connected
                                ? (pill.tone ?? MeshPillTone.success)
                                : MeshPillTone.neutral,
                            mono: true,
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    preview.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            MeshIconButton(
              icon: streamPaused
                  ? Icons.play_circle_outline_rounded
                  : Icons.pause_circle_outline_rounded,
              tooltip: streamPaused ? 'Resume stream' : 'Pause stream',
              color: streamPaused ? colors.success : colors.textSecondary,
              onTap: streamPaused ? onResume : onPause,
            ),
            const SizedBox(width: 6),
            MeshIconButton(
              icon: inputRailOpen
                  ? Icons.keyboard_hide_rounded
                  : Icons.keyboard_alt_rounded,
              tooltip: inputRailOpen ? 'Hide keyboard' : 'Open keyboard',
              color: inputRailOpen ? colors.accent : colors.textSecondary,
              onTap: onToggleInput,
            ),
            const SizedBox(width: 6),
            if (onMinimize != null) ...[
              MeshIconButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: 'Minimize preview',
                color: colors.textSecondary,
                onTap: onMinimize!,
              ),
              const SizedBox(width: 6),
            ],
            MeshIconButton(
              icon: Icons.stop_circle_rounded,
              tooltip: 'Stop remote browser',
              color: colors.danger,
              onTap: onStop,
            ),
          ],
        ),
      ),
    );
  }

  _BrowserPill _browserPreviewPill(HostStatus status) {
    if (status.reachability == HostReachability.offline) {
      final last = status.lastEventAt ?? status.lastOnlineAt;
      if (last != null) {
        final elapsed = DateTime.now().difference(last);
        if (elapsed.inHours >= 1) {
          return const _BrowserPill(
            label: 'Reconnecting',
            tone: MeshPillTone.warning,
          );
        }
        String ago;
        if (elapsed.inMinutes < 1) {
          ago = '${elapsed.inSeconds}s ago';
        } else {
          ago = '${elapsed.inMinutes}m ago';
        }
        return _BrowserPill(
          label: 'Last frame $ago',
          tone: MeshPillTone.warning,
        );
      }
      return const _BrowserPill(
        label: 'Reconnecting',
        tone: MeshPillTone.warning,
      );
    }
    if (status.reachability == HostReachability.probing) {
      return const _BrowserPill(
        label: 'Reconnecting',
        tone: MeshPillTone.warning,
      );
    }
    return const _BrowserPill();
  }
}

@immutable
class _BrowserPill {
  const _BrowserPill({this.label, this.tone});
  final String? label;
  final MeshPillTone? tone;
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

class _PreviewFloatingControls extends StatelessWidget {
  const _PreviewFloatingControls({
    required this.inputRailOpen,
    required this.onToggleInput,
  });

  final bool inputRailOpen;
  final VoidCallback onToggleInput;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (inputRailOpen) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.canvas.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border.withValues(alpha: 0.9)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: TextButton.icon(
          onPressed: onToggleInput,
          icon: const Icon(Icons.keyboard_alt_rounded, size: 18),
          label: const Text('Keyboard'),
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

int _intValue(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.round();
  return fallback;
}
