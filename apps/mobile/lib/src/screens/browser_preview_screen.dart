import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';

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
    this.onStopped,
  });

  final HostProfile host;
  final ApiClient api;
  final HostBrowserPreviewInfo preview;
  final bool stopOnDispose;
  final bool showHeader;
  final VoidCallback? onBack;
  final void Function(HostBrowserPreviewInfo preview)? onStopped;

  @override
  State<BrowserPreviewPane> createState() => _BrowserPreviewPaneState();
}

class _BrowserPreviewPaneState extends State<BrowserPreviewPane>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _inputFocusNode = FocusNode();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  late HostBrowserPreviewInfo _preview;
  Uint8List? _frameBytes;
  int _frameWidth = 390;
  int _frameHeight = 844;
  String? _status = 'Connecting to remote browser...';
  String? _error;
  bool _inputRailConfigured = false;
  bool _inputRailOpen = false;
  bool _clientPaused = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _inputRailOpen = MediaQuery.sizeOf(context).shortestSide >= 700;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_clientPaused) {
        _clientPaused = false;
        _connect();
      }
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _pauseStream();
    }
  }

  void _connect() {
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
        if (!mounted || _clientPaused) return;
        setState(() {
          _error = friendlyError(error);
          _status = null;
        });
      },
      onDone: () {
        if (!mounted || _clientPaused) return;
        setState(() {
          _status = 'Remote browser stopped.';
        });
      },
      cancelOnError: true,
    );
  }

  void _pauseStream() {
    if (_clientPaused) return;
    _clientPaused = true;
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    _subscription = null;
    _channel = null;
    if (!mounted) return;
    setState(() {
      _status = 'Stream paused while the app is in the background.';
    });
  }

  void _handleFrame(dynamic payload) {
    if (payload is! String) return;
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return;
    final type = decoded['type'];
    if (type == 'hello' || type == 'ready' || type == 'preview') {
      final preview = _previewFromMessage(decoded);
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
      return;
    }
    if (type == 'frame') {
      final data = decoded['data'];
      if (data is! String || data.isEmpty) return;
      final bytes = base64Decode(data);
      if (!mounted) return;
      setState(() {
        _frameBytes = bytes;
        _frameWidth = _intValue(decoded['width'], _frameWidth);
        _frameHeight = _intValue(decoded['height'], _frameHeight);
        _status = null;
        _error = null;
      });
      return;
    }
    if (type == 'error') {
      if (!mounted) return;
      setState(() {
        _error = decoded['message']?.toString() ?? 'Remote browser error';
        _status = null;
      });
    }
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
    _send({'type': 'text', 'text': text});
    _textController.clear();
  }

  void _sendKey(String key) {
    _send({'type': 'key', 'key': key});
  }

  void _toggleInputRail() {
    final next = !_inputRailOpen;
    setState(() => _inputRailOpen = next);
    if (!next) {
      _inputFocusNode.unfocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocusNode.requestFocus();
    });
  }

  void _sendTap(TapUpDetails details, Size size) {
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
    return Column(
      children: [
        if (widget.showHeader)
          _PreviewHeader(
            preview: _preview,
            connected: _error == null && _status == null,
            inputRailOpen: _inputRailOpen,
            onBack: widget.onBack,
            onToggleInput: _toggleInputRail,
            onStop: () => unawaited(_stopRemoteBrowser()),
          ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              widget.showHeader ? 10 : 12,
              widget.showHeader ? 2 : 12,
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
                          return GestureDetector(
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
                          );
                        },
                      ),
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
            onClose: _toggleInputRail,
          ),
      ],
    );
  }

  Widget _buildPreviewBody(AppColors colors) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.danger),
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

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({
    required this.preview,
    required this.connected,
    required this.inputRailOpen,
    required this.onToggleInput,
    required this.onStop,
    this.onBack,
  });

  final HostBrowserPreviewInfo preview;
  final bool connected;
  final bool inputRailOpen;
  final VoidCallback onToggleInput;
  final VoidCallback onStop;
  final VoidCallback? onBack;

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
                      MeshPill(
                        label: connected ? 'live' : preview.status,
                        tone: connected
                            ? MeshPillTone.success
                            : MeshPillTone.neutral,
                        mono: true,
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
              icon: inputRailOpen
                  ? Icons.keyboard_hide_outlined
                  : Icons.keyboard_alt_outlined,
              tooltip: inputRailOpen ? 'Hide page input' : 'Show page input',
              color: inputRailOpen ? colors.accent : colors.textSecondary,
              onTap: onToggleInput,
            ),
            const SizedBox(width: 6),
            MeshIconButton(
              icon: Icons.stop_circle_outlined,
              tooltip: 'Stop remote browser',
              color: colors.danger,
              onTap: onStop,
            ),
          ],
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
          icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
          label: const Text('Input'),
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
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSendText;
  final void Function(String key) onKey;
  final VoidCallback onClose;

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
                    Icons.keyboard_alt_outlined,
                    size: 18,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Page input',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Hide keyboard',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 6),
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
