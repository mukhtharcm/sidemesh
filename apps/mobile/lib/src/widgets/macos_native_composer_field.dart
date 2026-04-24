import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MacosNativeComposerField extends StatefulWidget {
  const MacosNativeComposerField({
    super.key,
    required this.controller,
    required this.onSend,
    required this.hintText,
    this.maxVisibleLines = 6,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final String hintText;
  final int maxVisibleLines;

  @override
  State<MacosNativeComposerField> createState() =>
      _MacosNativeComposerFieldState();
}

class _MacosNativeComposerFieldState extends State<MacosNativeComposerField> {
  static const _viewType = 'sidemesh/native-composer';
  static const _channelPrefix = 'sidemesh/native_composer/';
  static const _minHeight = 50.0;
  static const _maxHeight = 138.0;
  static const _verticalInset = 18.0;

  MethodChannel? _channel;
  bool _updatingControllerFromNative = false;
  TextEditingValue _lastSyncedValue = const TextEditingValue();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    _lastSyncedValue = _normalizedValue(widget.controller.value);
  }

  @override
  void didUpdateWidget(covariant MacosNativeComposerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) {
      return;
    }
    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
    _lastSyncedValue = _normalizedValue(widget.controller.value);
    _syncControllerToNative();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (_updatingControllerFromNative) {
      return;
    }
    _syncControllerToNative();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _handlePlatformViewCreated(int viewId) async {
    final channel = MethodChannel('$_channelPrefix$viewId');
    _channel = channel;
    channel.setMethodCallHandler(_handleMethodCall);
    _syncControllerToNative();
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'editingChanged':
        final map = Map<String, dynamic>.from(
          (call.arguments as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        );
        final nextValue = _valueFromChannel(map);
        if (_normalizedValue(widget.controller.value) == nextValue) {
          _lastSyncedValue = nextValue;
          if (mounted) {
            setState(() {});
          }
          return null;
        }
        _updatingControllerFromNative = true;
        widget.controller.value = nextValue;
        _updatingControllerFromNative = false;
        _lastSyncedValue = nextValue;
        if (mounted) {
          setState(() {});
        }
        return null;
      case 'submit':
        widget.onSend();
        return null;
      default:
        return null;
    }
  }

  void _syncControllerToNative() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    final nextValue = _normalizedValue(widget.controller.value);
    if (_lastSyncedValue == nextValue) {
      return;
    }
    _lastSyncedValue = nextValue;
    unawaited(
      channel.invokeMethod<void>('setEditingState', <String, dynamic>{
        'text': nextValue.text,
        'selectionStart': nextValue.selection.start,
        'selectionEnd': nextValue.selection.end,
      }),
    );
  }

  TextEditingValue _valueFromChannel(Map<String, dynamic> map) {
    final text = map['text'] as String? ?? '';
    final clampedLength = text.length;
    final rawStart = (map['selectionStart'] as num?)?.toInt() ?? clampedLength;
    final rawEnd = (map['selectionEnd'] as num?)?.toInt() ?? rawStart;
    final start = rawStart.clamp(0, clampedLength).toInt();
    final end = rawEnd.clamp(0, clampedLength).toInt();
    return TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    );
  }

  TextEditingValue _normalizedValue(TextEditingValue value) {
    final text = value.text;
    final length = text.length;
    final selection = value.selection;
    final start = selection.start < 0
        ? length
        : selection.start.clamp(0, length).toInt();
    final end = selection.end < 0
        ? start
        : selection.end.clamp(0, length).toInt();
    return TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    );
  }

  double _estimateHeight(BoxConstraints constraints, TextStyle style) {
    final width = constraints.maxWidth.isFinite
        ? math.max(0.0, constraints.maxWidth - 8)
        : 640.0;
    final painter = TextPainter(
      text: TextSpan(
        text: widget.controller.text.isEmpty ? ' ' : widget.controller.text,
        style: style,
      ),
      textDirection: Directionality.of(context),
      maxLines: widget.maxVisibleLines,
    )..layout(maxWidth: width);
    final lineCount = math.max(
      1,
      math.min(widget.maxVisibleLines, painter.computeLineMetrics().length),
    );
    final lineHeight = painter.preferredLineHeight;
    final nextHeight = lineCount * lineHeight + _verticalInset;
    return nextHeight.clamp(_minHeight, _maxHeight);
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = _estimateHeight(constraints, style);
        return SizedBox(
          height: height,
          child: AppKitView(
            key: const ValueKey('macos_native_composer_field'),
            viewType: _viewType,
            layoutDirection: Directionality.of(context),
            creationParams: <String, dynamic>{
              'text': widget.controller.text,
              'selectionStart': _normalizedValue(
                widget.controller.value,
              ).selection.start,
              'selectionEnd': _normalizedValue(
                widget.controller.value,
              ).selection.end,
              'placeholder': widget.hintText,
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _handlePlatformViewCreated,
          ),
        );
      },
    );
  }
}
