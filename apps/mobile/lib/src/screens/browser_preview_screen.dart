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

class BrowserPreviewScreen extends StatefulWidget {
  const BrowserPreviewScreen({
    super.key,
    required this.host,
    required this.api,
    required this.preview,
    this.stopOnDispose = true,
  });

  final HostProfile host;
  final ApiClient api;
  final HostBrowserPreviewInfo preview;
  final bool stopOnDispose;

  @override
  State<BrowserPreviewScreen> createState() => _BrowserPreviewScreenState();
}

class _BrowserPreviewScreenState extends State<BrowserPreviewScreen> {
  final _textController = TextEditingController();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Uint8List? _frameBytes;
  int _frameWidth = 390;
  int _frameHeight = 844;
  String? _status = 'Connecting to remote browser...';
  String? _error;

  @override
  void initState() {
    super.initState();
    _frameWidth = widget.preview.width;
    _frameHeight = widget.preview.height;
    _connect();
  }

  @override
  void dispose() {
    _textController.dispose();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    if (widget.stopOnDispose) {
      unawaited(widget.api.stopBrowserPreview(widget.host, widget.preview.id));
    }
    super.dispose();
  }

  void _connect() {
    final channel = widget.api.openBrowserPreviewLive(
      widget.host,
      widget.preview.id,
    );
    _channel = channel;
    _subscription = channel.stream.listen(
      _handleFrame,
      onError: (error) {
        if (!mounted) return;
        setState(() {
          _error = friendlyError(error);
          _status = null;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _status = 'Remote browser stopped.';
        });
      },
      cancelOnError: true,
    );
  }

  void _handleFrame(dynamic payload) {
    if (payload is! String) return;
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return;
    final type = decoded['type'];
    if (type == 'hello' || type == 'ready') {
      if (!mounted) return;
      setState(() {
        _status = 'Waiting for first frame...';
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
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.preview.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              widget.preview.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textSecondary, fontSize: 11),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: MeshCard(
                tone: MeshCardTone.elevated,
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
                          color: Colors.black,
                          alignment: Alignment.center,
                          child: _buildPreviewBody(colors),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
          _InputRail(
            controller: _textController,
            onSendText: _sendText,
            onKey: _sendKey,
          ),
        ],
      ),
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
          Text(
            _status ?? 'Starting remote browser...',
            style: TextStyle(color: colors.textSecondary),
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

class _InputRail extends StatelessWidget {
  const _InputRail({
    required this.controller,
    required this.onSendText,
    required this.onKey,
  });

  final TextEditingController controller;
  final VoidCallback onSendText;
  final void Function(String key) onKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: MeshCard(
          tone: MeshCardTone.surface,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _KeyButton(label: 'Esc', onTap: () => onKey('Escape')),
                    _KeyButton(label: 'Tab', onTap: () => onKey('Tab')),
                    _KeyButton(label: 'Enter', onTap: () => onKey('Enter')),
                    _KeyButton(
                      label: '⌫',
                      onTap: () => onKey('Backspace'),
                    ),
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
      child: OutlinedButton(
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }
}

int _intValue(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.round();
  return fallback;
}
