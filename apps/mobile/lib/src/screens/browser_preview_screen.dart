import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
  final Map<String, _NetworkEntry> _networkEntries = <String, _NetworkEntry>{};
  final List<String> _networkEntryOrder = <String>[];
  final Map<String, _NetworkDetail> _networkDetails =
      <String, _NetworkDetail>{};
  final StreamController<_NetworkDetailUpdate> _networkDetailUpdates =
      StreamController<_NetworkDetailUpdate>.broadcast();
  final int _maxNetworkEntries = 300;
  String _networkFilter = 'All';
  int? _networkClearedStartedAtFloor;
  final Set<String> _networkClearedRequestIdsAtFloor = <String>{};
  bool _networkAvailable = true;
  String? _networkUnavailableMessage;

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
    unawaited(_networkDetailUpdates.close());
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
        _networkAvailable = true;
        _networkUnavailableMessage = null;
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
    if (type == 'networkStatus') {
      final available = frame['available'] != false;
      final message = frame['message']?.toString().trim();
      if (!mounted) return;
      setState(() {
        _networkAvailable = available;
        _networkUnavailableMessage = available
            ? null
            : ((message != null && message.isNotEmpty)
                  ? message
                  : 'Network inspection is unavailable on this browser.');
      });
      return;
    }
    if (type == 'networkSnapshot') {
      _handleNetworkSnapshot(frame);
      return;
    }
    if (type == 'network') {
      _handleNetworkEvent(frame);
      return;
    }
    if (type == 'networkDetail') {
      _handleNetworkDetail(frame);
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

  void _handleNetworkSnapshot(Map<dynamic, dynamic> frame) {
    if (!mounted) return;
    final entries = frame['entries'];
    if (entries is! List) return;
    setState(() {
      _networkEntries.clear();
      _networkEntryOrder.clear();
      _networkDetails.clear();
      for (final item in entries) {
        if (item is! Map) continue;
        final parsed = _NetworkEntry.fromJson(item);
        if (!_shouldIncludeNetworkEntry(parsed)) continue;
        _upsertNetworkEntry(parsed);
      }
    });
  }

  void _handleNetworkEvent(Map<dynamic, dynamic> frame) {
    if (!mounted) return;
    final rawEntry = frame['entry'];
    if (rawEntry is! Map) return;
    final entry = _NetworkEntry.fromJson(rawEntry);
    if (!_shouldIncludeNetworkEntry(entry)) return;
    setState(() {
      _upsertNetworkEntry(entry);
    });
  }

  void _handleNetworkDetail(Map<dynamic, dynamic> frame) {
    final requestId = frame['requestId']?.toString() ?? '';
    if (requestId.isEmpty) return;
    final rawDetail = frame['detail'];
    final error = frame['error']?.toString();
    if (rawDetail is! Map) {
      final entry = _networkEntries[requestId];
      if (entry != null) {
        final fallbackDetail = _networkDetailFromEntry(entry, bodyError: error);
        _networkDetails[requestId] = fallbackDetail;
        _networkDetailUpdates.add(
          _NetworkDetailUpdate(
            requestId: requestId,
            detail: fallbackDetail,
            error: error,
          ),
        );
        return;
      }
      _networkDetailUpdates.add(
        _NetworkDetailUpdate(requestId: requestId, error: error),
      );
      return;
    }
    final detail = _NetworkDetail.fromJson(rawDetail);
    _networkDetails[requestId] = detail;
    _networkDetailUpdates.add(
      _NetworkDetailUpdate(requestId: requestId, detail: detail, error: error),
    );
  }

  _NetworkDetail _networkDetailFromEntry(
    _NetworkEntry entry, {
    String? bodyError,
  }) {
    return _NetworkDetail(
      requestId: entry.requestId,
      method: entry.method,
      url: entry.url,
      resourceType: entry.resourceType,
      requestHeaders: const <String, String>{},
      responseHeaders: const <String, String>{},
      startedAt: entry.startedAt,
      status: entry.status,
      mimeType: entry.mimeType,
      encodedDataLength: entry.encodedDataLength,
      durationMs: entry.durationMs,
      errorText: entry.errorText,
      bodyError: bodyError,
      finished: entry.finished,
      failed: entry.failed,
      servedFromCache: entry.servedFromCache,
    );
  }

  void _upsertNetworkEntry(_NetworkEntry entry) {
    final existing = _networkEntries[entry.requestId];
    _networkEntries[entry.requestId] = existing == null
        ? entry
        : existing.merge(entry);
    if (!_networkEntryOrder.contains(entry.requestId)) {
      _networkEntryOrder.add(entry.requestId);
    }
    while (_networkEntryOrder.length > _maxNetworkEntries) {
      final removedRequestId = _networkEntryOrder.removeAt(0);
      _networkEntries.remove(removedRequestId);
      _networkDetails.remove(removedRequestId);
    }
  }

  List<_NetworkEntry> get _filteredNetworkEntries {
    final ordered = _networkEntryOrder
        .map((requestId) => _networkEntries[requestId])
        .whereType<_NetworkEntry>()
        .toList(growable: false);
    if (_networkFilter == 'All') return ordered;
    return ordered
        .where((entry) => _matchesNetworkFilter(entry, _networkFilter))
        .toList(growable: false);
  }

  bool _shouldIncludeNetworkEntry(_NetworkEntry entry) {
    final floor = _networkClearedStartedAtFloor;
    if (floor == null) return true;
    if (entry.startedAt > floor) return true;
    if (entry.startedAt < floor) return false;
    return !_networkClearedRequestIdsAtFloor.contains(entry.requestId);
  }

  void _clearNetworkLog() {
    var latestStartedAt = _networkClearedStartedAtFloor;
    final requestIdsAtFloor = <String>{};
    for (final entry in _networkEntries.values) {
      if (latestStartedAt == null || entry.startedAt > latestStartedAt) {
        latestStartedAt = entry.startedAt;
        requestIdsAtFloor
          ..clear()
          ..add(entry.requestId);
        continue;
      }
      if (entry.startedAt == latestStartedAt) {
        requestIdsAtFloor.add(entry.requestId);
      }
    }
    setState(() {
      if (latestStartedAt == null) {
        _networkClearedStartedAtFloor = null;
        _networkClearedRequestIdsAtFloor.clear();
      } else if (_networkClearedStartedAtFloor == latestStartedAt) {
        _networkClearedRequestIdsAtFloor.addAll(requestIdsAtFloor);
      } else {
        _networkClearedStartedAtFloor = latestStartedAt;
        _networkClearedRequestIdsAtFloor
          ..clear()
          ..addAll(requestIdsAtFloor);
      }
      _networkEntries.clear();
      _networkEntryOrder.clear();
      _networkDetails.clear();
    });
  }

  void _showNetworkDetail(_NetworkEntry entry) {
    const disconnectedDetailMessage =
        'Viewer is disconnected. Resume the stream to inspect request details.';
    final cachedDetail = _networkDetails[entry.requestId];
    final shouldRequestDetail =
        _channel != null &&
        (cachedDetail == null ||
            (cachedDetail.body == null &&
                cachedDetail.bodyError != null &&
                entry.finished &&
                !entry.failed));
    final detailNotifier = ValueNotifier<_NetworkDetail?>(
      cachedDetail ??
          (_channel == null
              ? _networkDetailFromEntry(
                  entry,
                  bodyError: disconnectedDetailMessage,
                )
              : null),
    );
    final subscription = _networkDetailUpdates.stream
        .where((update) => update.requestId == entry.requestId)
        .listen((update) {
          if (update.detail != null) {
            detailNotifier.value = update.detail;
            return;
          }
          if (update.error != null && detailNotifier.value == null) {
            detailNotifier.value = _networkDetailFromEntry(
              entry,
              bodyError: update.error,
            );
          }
        });
    if (shouldRequestDetail &&
        !_sendMessage({
          'type': 'networkDetailRequest',
          'requestId': entry.requestId,
        }) &&
        detailNotifier.value == null) {
      detailNotifier.value = _networkDetailFromEntry(
        entry,
        bodyError: disconnectedDetailMessage,
      );
    }
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _NetworkDetailSheet(
          entry: entry,
          detailListenable: detailNotifier,
        ),
      ).whenComplete(() async {
        await subscription.cancel();
        detailNotifier.dispose();
      }),
    );
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
    final channel = _channel;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _subscription = null;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close());
    }
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop remote browser?'),
        content: const Text(
          'This shuts down the remote Chromium instance. You can start a new preview from the Ports screen any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
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
    // Optimistically update local state so the chip and interaction-rect
    // snap to the new dimensions immediately, before the server's `preview`
    // message round-trips back.
    setState(() {
      _preview = _preview.copyWith(
        width: result.width,
        height: result.height,
      );
      _frameWidth = result.width;
      _frameHeight = result.height;
    });
    _send({
      'type': 'resize',
      'width': result.width,
      'height': result.height,
    });
  }

  bool _sendMessage(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return false;
    try {
      channel.sink.add(jsonEncode(message));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _send(Map<String, dynamic> message) {
    _sendMessage(message);
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

  void _sendTapDown(TapDownDetails details, Size size) {
    _browserFocusNode.requestFocus();
    final point = _mapPoint(details.localPosition, size);
    if (point == null) return;
    _send({'type': 'tapDown', 'x': point.dx, 'y': point.dy});
  }

  void _sendTapUp(TapUpDetails details, Size size) {
    final point = _mapPoint(details.localPosition, size);
    if (point == null) return;
    _send({'type': 'tapUp', 'x': point.dx, 'y': point.dy});
  }

  void _sendHover(PointerHoverEvent event, Size size) {
    final point = _mapPoint(event.localPosition, size);
    if (point == null) return;
    _send({'type': 'hover', 'x': point.dx, 'y': point.dy});
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

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is! PointerScrollEvent) return;
    final point = _mapPoint(event.localPosition, size);
    if (point == null) return;
    _send({
      'type': 'scroll',
      'x': point.dx,
      'y': point.dy,
      'deltaY': event.scrollDelta.dy,
      'deltaX': event.scrollDelta.dx,
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
    final reconnecting =
        _frameBytes != null && _status != null && !_clientPaused;
    return Column(
      children: [
        _BrowserChromeBar(
          preview: _preview,
          urlController: _urlController,
          urlFocusNode: _urlFocusNode,
          pageLoading: _pageLoading,
          desktopLike: desktopLike,
          streamPaused: _clientPaused,
          devToolsOpen: _devToolsOpen,
          inputRailOpen: _inputRailOpen,
          onBack: widget.onBack,
          onMinimize: widget.onMinimize,
          onNavigate: _sendNavigate,
          onBackNavigation: () => _sendNavigation('back'),
          onForwardNavigation: () => _sendNavigation('forward'),
          onReload: () => _sendNavigation('reload'),
          onResize: () => unawaited(_showViewportSheet()),
          onToggleInput: _toggleInputRail,
          onToggleDevTools: _toggleDevTools,
          onTogglePause: () => _clientPaused
              ? _resumeStream()
              : _pauseStream(manual: true),
          onStop: widget.showHeader
              ? () => unawaited(_stopRemoteBrowser())
              : null,
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  color: colors.canvas,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      _lastPreviewBoxSize = size;
                      return Focus(
                        focusNode: _browserFocusNode,
                        autofocus: desktopLike,
                        onKeyEvent: _handleHardwareKey,
                        child: MouseRegion(
                          onHover: desktopLike
                              ? (event) => _sendHover(event, size)
                              : null,
                          child: Listener(
                            onPointerSignal: (event) =>
                                _handlePointerSignal(event, size),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (details) =>
                                  _sendTapDown(details, size),
                              onTapUp: (details) =>
                                  _sendTapUp(details, size),
                              onVerticalDragUpdate: (details) =>
                                  _sendScroll(details, size),
                              onHorizontalDragUpdate: (details) =>
                                  _sendScroll(details, size),
                              child: _buildPreviewBody(colors),
                            ),
                          ),
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
              if (reconnecting)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _ReconnectingChip(message: _status!),
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
        if (!desktopLike)
          _BrowserBottomToolbar(
            preview: _preview,
            streamPaused: _clientPaused,
            inputRailOpen: _inputRailOpen,
            devToolsOpen: _devToolsOpen,
            onBack: () => _sendNavigation('back'),
            onForward: () => _sendNavigation('forward'),
            onReload: () => _sendNavigation('reload'),
            onHome: () => _send({'type': 'navigate', 'url': _preview.url}),
            onResize: () => unawaited(_showViewportSheet()),
            onToggleInput: _toggleInputRail,
            onToggleDevTools: _toggleDevTools,
            onTogglePause: () => _clientPaused
                ? _resumeStream()
                : _pauseStream(manual: true),
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
            networkEntries: _filteredNetworkEntries,
            networkAvailable: _networkAvailable,
            networkUnavailableMessage: _networkUnavailableMessage,
            networkFilter: _networkFilter,
            onNetworkFilterChanged: (value) =>
                setState(() => _networkFilter = value),
            onClearConsole: () => setState(() => _consoleEntries.clear()),
            onClearNetwork: _clearNetworkLog,
            onOpenNetworkDetail: _showNetworkDetail,
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
    required this.desktopLike,
    required this.streamPaused,
    required this.devToolsOpen,
    required this.inputRailOpen,
    this.onBack,
    this.onMinimize,
    required this.onNavigate,
    required this.onBackNavigation,
    required this.onForwardNavigation,
    required this.onReload,
    required this.onResize,
    required this.onToggleInput,
    required this.onToggleDevTools,
    required this.onTogglePause,
    this.onStop,
  });

  final HostBrowserPreviewInfo preview;
  final TextEditingController urlController;
  final FocusNode urlFocusNode;
  final bool pageLoading;
  final bool desktopLike;
  final bool streamPaused;
  final bool devToolsOpen;
  final bool inputRailOpen;
  final VoidCallback? onBack;
  final VoidCallback? onMinimize;
  final VoidCallback onNavigate;
  final VoidCallback onBackNavigation;
  final VoidCallback onForwardNavigation;
  final VoidCallback onReload;
  final VoidCallback onResize;
  final VoidCallback onToggleInput;
  final VoidCallback onToggleDevTools;
  final VoidCallback onTogglePause;
  final VoidCallback? onStop;

  bool get _isHttps {
    final url = urlController.text.trim().toLowerCase();
    if (url.startsWith('https://')) return true;
    if (url.isEmpty && preview.scheme == 'https') return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
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
                icon: Icons.close_rounded,
                tooltip: 'Close preview',
                onTap: onBack!,
              ),
              const SizedBox(width: 4),
            ],
            if (desktopLike) ...[
              _ChromeButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onTap: onBackNavigation,
              ),
              const SizedBox(width: 2),
              _ChromeButton(
                icon: Icons.arrow_forward_rounded,
                tooltip: 'Forward',
                onTap: onForwardNavigation,
              ),
              const SizedBox(width: 2),
              _ChromeButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Reload',
                onTap: onReload,
              ),
              const SizedBox(width: 6),
            ],
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
                      Tooltip(
                        message: _isHttps
                            ? 'Connection is secure (HTTPS)'
                            : 'Connection is not secure (HTTP)',
                        child: Icon(
                          _isHttps
                              ? Icons.lock_rounded
                              : Icons.info_outline_rounded,
                          size: 14,
                          color: _isHttps
                              ? colors.textTertiary
                              : colors.warning,
                        ),
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
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.url,
                        onSubmitted: (_) => onNavigate(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (desktopLike) ...[
              _ViewportChip(
                width: preview.width,
                height: preview.height,
                onTap: onResize,
              ),
              const SizedBox(width: 6),
              _ChromeButton(
                icon: inputRailOpen
                    ? Icons.keyboard_hide_rounded
                    : Icons.keyboard_alt_rounded,
                tooltip: inputRailOpen ? 'Hide keyboard' : 'Keyboard',
                color: inputRailOpen ? colors.accent : null,
                onTap: onToggleInput,
              ),
              const SizedBox(width: 2),
              _ChromeButton(
                icon: devToolsOpen
                    ? Icons.construction_rounded
                    : Icons.construction_outlined,
                tooltip: devToolsOpen ? 'Hide DevTools' : 'DevTools',
                color: devToolsOpen ? colors.accent : null,
                onTap: onToggleDevTools,
              ),
              const SizedBox(width: 2),
              _ChromeButton(
                icon: streamPaused
                    ? Icons.play_circle_outline_rounded
                    : Icons.pause_circle_outline_rounded,
                tooltip: streamPaused ? 'Resume stream' : 'Pause stream',
                color: streamPaused ? colors.success : null,
                onTap: onTogglePause,
              ),
              const SizedBox(width: 4),
            ],
            if (onMinimize != null) ...[
              _ChromeButton(
                icon: Icons.keyboard_arrow_down_rounded,
                tooltip: 'Minimize',
                onTap: onMinimize!,
              ),
              const SizedBox(width: 2),
            ],
            if (onStop != null)
              _ChromeButton(
                icon: Icons.stop_circle_rounded,
                tooltip: 'Stop remote browser',
                color: colors.danger,
                onTap: onStop!,
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
    required this.onHome,
    required this.onResize,
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
  final VoidCallback onHome;
  final VoidCallback onResize;
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
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _ChromeButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onTap: onBack,
              ),
              const SizedBox(width: 4),
              _ChromeButton(
                icon: Icons.arrow_forward_rounded,
                tooltip: 'Forward',
                onTap: onForward,
              ),
              const SizedBox(width: 4),
              _ChromeButton(
                icon: Icons.refresh_rounded,
                tooltip: 'Reload',
                onTap: onReload,
              ),
              const SizedBox(width: 4),
              _ChromeButton(
                icon: Icons.home_rounded,
                tooltip: 'Home',
                onTap: onHome,
              ),
              const SizedBox(width: 8),
              _ViewportChip(
                width: preview.width,
                height: preview.height,
                onTap: onResize,
              ),
              const SizedBox(width: 6),
              _ChromeButton(
                icon: inputRailOpen
                    ? Icons.keyboard_hide_rounded
                    : Icons.keyboard_alt_rounded,
                tooltip: inputRailOpen ? 'Hide keyboard' : 'Keyboard',
                color: inputRailOpen ? colors.accent : null,
                onTap: onToggleInput,
              ),
              const SizedBox(width: 4),
              _ChromeButton(
                icon: devToolsOpen
                    ? Icons.construction_rounded
                    : Icons.construction_outlined,
                tooltip: 'DevTools',
                color: devToolsOpen ? colors.accent : null,
                onTap: onToggleDevTools,
              ),
              const SizedBox(width: 4),
              _ChromeButton(
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
      ),
    );
  }
}

class _DevToolsPanel extends StatelessWidget {
  const _DevToolsPanel({
    required this.tabIndex,
    required this.onTabChanged,
    required this.consoleEntries,
    required this.networkEntries,
    required this.networkAvailable,
    required this.networkUnavailableMessage,
    required this.networkFilter,
    required this.onNetworkFilterChanged,
    required this.onClearConsole,
    required this.onClearNetwork,
    required this.onOpenNetworkDetail,
    required this.preview,
  });

  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final List<_ConsoleEntry> consoleEntries;
  final List<_NetworkEntry> networkEntries;
  final bool networkAvailable;
  final String? networkUnavailableMessage;
  final String networkFilter;
  final ValueChanged<String> onNetworkFilterChanged;
  final VoidCallback onClearConsole;
  final VoidCallback onClearNetwork;
  final void Function(_NetworkEntry entry) onOpenNetworkDetail;
  final HostBrowserPreviewInfo preview;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final showingConsole = tabIndex == 0;
    return Container(
      height: 320,
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
                  active: showingConsole,
                  onTap: () => onTabChanged(0),
                ),
                _DevTab(
                  label: 'Network',
                  active: tabIndex == 1,
                  onTap: () => onTabChanged(1),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Storage · Inspector later',
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  tooltip: showingConsole ? 'Clear console' : 'Clear network log',
                  onPressed: showingConsole ? onClearConsole : onClearNetwork,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            child: showingConsole
                ? _ConsoleTab(
                    entries: consoleEntries,
                    preview: preview,
                  )
                : _NetworkTab(
                    entries: networkEntries,
                    networkAvailable: networkAvailable,
                    networkUnavailableMessage: networkUnavailableMessage,
                    filter: networkFilter,
                    onFilterChanged: onNetworkFilterChanged,
                    onOpenDetail: onOpenNetworkDetail,
                  ),
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

class _NetworkTab extends StatelessWidget {
  const _NetworkTab({
    required this.entries,
    required this.networkAvailable,
    required this.networkUnavailableMessage,
    required this.filter,
    required this.onFilterChanged,
    required this.onOpenDetail,
  });

  final List<_NetworkEntry> entries;
  final bool networkAvailable;
  final String? networkUnavailableMessage;
  final String filter;
  final ValueChanged<String> onFilterChanged;
  final void Function(_NetworkEntry entry) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final option in _networkFilterOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text(option),
                      selected: filter == option,
                      onSelected: (_) => onFilterChanged(option),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: !networkAvailable
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      networkUnavailableMessage ??
                          'Network inspection is unavailable on this browser.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ),
                )
              : entries.isEmpty
              ? Center(
                  child: Text(
                    'No network requests yet.',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return _NetworkRow(
                      entry: entry,
                      onTap: () => onOpenDetail(entry),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({
    required this.entry,
    required this.onTap,
  });

  final _NetworkEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusColor = _networkStatusColor(colors, entry);
    final statusLabel = _networkStatusLabel(entry);
    final subtitleParts = <String>[
      _networkResourceTypeLabel(entry.resourceType),
      if (entry.servedFromCache) 'cache',
      if (entry.encodedDataLength != null)
        _formatNetworkBytes(entry.encodedDataLength!),
      if (entry.durationMs != null) '${entry.durationMs} ms',
      if (entry.failed && entry.errorText != null) entry.errorText!,
    ];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 5),
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.canvas,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: colors.border),
                        ),
                        child: Text(
                          entry.method,
                          style: monoStyle(
                            color: colors.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _networkDisplayName(entry.url),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _networkDisplayLocation(entry.url),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitleParts.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              statusLabel,
              style: monoStyle(
                color: statusColor,
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

class _NetworkDetailSheet extends StatelessWidget {
  const _NetworkDetailSheet({
    required this.entry,
    required this.detailListenable,
  });

  final _NetworkEntry entry;
  final ValueListenable<_NetworkDetail?> detailListenable;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: ValueListenableBuilder<_NetworkDetail?>(
            valueListenable: detailListenable,
            builder: (context, detail, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _networkDisplayName(entry.url),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: AppWeights.title,
                              ),
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          entry.url,
                          style: monoStyle(
                            color: colors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _NetworkMetaChip(label: entry.method),
                            _NetworkMetaChip(
                              label: _networkStatusLabel(detail ?? entry),
                            ),
                            _NetworkMetaChip(
                              label: _networkResourceTypeLabel(
                                detail?.resourceType ?? entry.resourceType,
                              ),
                            ),
                            if ((detail?.mimeType ?? entry.mimeType) != null)
                              _NetworkMetaChip(
                                label: detail?.mimeType ?? entry.mimeType!,
                              ),
                            if ((detail?.encodedDataLength ??
                                    entry.encodedDataLength) !=
                                null)
                              _NetworkMetaChip(
                                label: _formatNetworkBytes(
                                  detail?.encodedDataLength ??
                                      entry.encodedDataLength!,
                                ),
                              ),
                            if ((detail?.durationMs ?? entry.durationMs) != null)
                              _NetworkMetaChip(
                                label:
                                    '${detail?.durationMs ?? entry.durationMs} ms',
                              ),
                            if ((detail?.servedFromCache ??
                                    entry.servedFromCache))
                              const _NetworkMetaChip(label: 'cache'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: colors.border),
                  Expanded(
                    child: detail == null
                        ? const Center(child: CircularProgressIndicator())
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                            children: [
                              if (detail.errorText != null &&
                                  detail.errorText!.isNotEmpty)
                                _NetworkSection(
                                  title: 'Request error',
                                  child: SelectableText(
                                    detail.errorText!,
                                    style: TextStyle(color: colors.danger),
                                  ),
                                ),
                              if (detail.requestHeaders.isNotEmpty)
                                _NetworkSection(
                                  title: 'Request headers',
                                  child: _HeaderList(
                                    headers: detail.requestHeaders,
                                  ),
                                ),
                              if (detail.responseHeaders.isNotEmpty)
                                _NetworkSection(
                                  title: 'Response headers',
                                  child: _HeaderList(
                                    headers: detail.responseHeaders,
                                  ),
                                ),
                              _NetworkSection(
                                title: 'Response body',
                                child: _NetworkBodyView(detail: detail),
                              ),
                            ],
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NetworkMetaChip extends StatelessWidget {
  const _NetworkMetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: monoStyle(
          color: colors.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _NetworkSection extends StatelessWidget {
  const _NetworkSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colors.textPrimary,
              fontWeight: AppWeights.title,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _HeaderList extends StatelessWidget {
  const _HeaderList({required this.headers});

  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: headers.entries.map((entry) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: SelectableText(
                  entry.key,
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: SelectableText(
                  entry.value,
                  style: monoStyle(
                    color: colors.textPrimary,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(growable: false),
    );
  }
}

class _NetworkBodyView extends StatelessWidget {
  const _NetworkBodyView({required this.detail});

  final _NetworkDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (detail.bodyError != null && detail.bodyError!.isNotEmpty) {
      return SelectableText(
        detail.bodyError!,
        style: TextStyle(color: colors.textSecondary),
      );
    }
    final body = detail.body;
    if (body == null) {
      return Text(
        'No response body captured for this request.',
        style: TextStyle(color: colors.textSecondary),
      );
    }
    final mimeType = detail.mimeType ?? '';
    if (detail.bodyBase64Encoded && mimeType.startsWith('image/')) {
      try {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(base64Decode(body)),
        );
      } catch (_) {
        return Text(
          'Could not decode the image response body.',
          style: TextStyle(color: colors.textSecondary),
        );
      }
    }
    if (detail.bodyBase64Encoded) {
      return SelectableText(
        'Binary response body (${_formatNetworkBytes(body.length)} encoded characters)',
        style: TextStyle(color: colors.textSecondary),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: SelectableText(
        _prettyNetworkBody(body, mimeType),
        style: monoStyle(
          color: colors.textPrimary,
          fontSize: 11,
        ),
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

abstract interface class _NetworkSummaryLike {
  String get method;
  String get url;
  String get resourceType;
  String? get mimeType;
  int? get status;
  int? get encodedDataLength;
  int? get durationMs;
  String? get errorText;
  bool get failed;
  bool get finished;
  bool get servedFromCache;
}

class _NetworkEntry implements _NetworkSummaryLike {
  const _NetworkEntry({
    required this.requestId,
    required this.method,
    required this.url,
    required this.resourceType,
    required this.startedAt,
    this.status,
    this.mimeType,
    this.encodedDataLength,
    this.durationMs,
    this.errorText,
    this.finished = false,
    this.failed = false,
    this.servedFromCache = false,
  });

  factory _NetworkEntry.fromJson(Map<dynamic, dynamic> json) => _NetworkEntry(
    requestId: json['requestId']?.toString() ?? '',
    method: json['method']?.toString() ?? 'GET',
    url: json['url']?.toString() ?? '',
    resourceType: json['resourceType']?.toString() ?? 'Other',
    startedAt: _intValue(
      json['startedAt'],
      DateTime.now().millisecondsSinceEpoch,
    ),
    status: _intOrNull(json['status']),
    mimeType: json['mimeType']?.toString(),
    encodedDataLength: _intOrNull(json['encodedDataLength']),
    durationMs: _intOrNull(json['durationMs']),
    errorText: json['errorText']?.toString(),
    finished: json['finished'] == true,
    failed: json['failed'] == true,
    servedFromCache: json['servedFromCache'] == true,
  );

  final String requestId;
  @override
  final String method;
  @override
  final String url;
  @override
  final String resourceType;
  final int startedAt;
  @override
  final int? status;
  @override
  final String? mimeType;
  @override
  final int? encodedDataLength;
  @override
  final int? durationMs;
  @override
  final String? errorText;
  @override
  final bool finished;
  @override
  final bool failed;
  @override
  final bool servedFromCache;

  _NetworkEntry merge(_NetworkEntry other) {
    return _NetworkEntry(
      requestId: requestId,
      method: other.method.isEmpty ? method : other.method,
      url: other.url.isEmpty ? url : other.url,
      resourceType: other.resourceType.isEmpty ? resourceType : other.resourceType,
      startedAt: other.startedAt,
      status: other.status ?? status,
      mimeType: other.mimeType ?? mimeType,
      encodedDataLength: other.encodedDataLength ?? encodedDataLength,
      durationMs: other.durationMs ?? durationMs,
      errorText: other.errorText ?? errorText,
      finished: other.finished || finished,
      failed: other.failed || failed,
      servedFromCache: other.servedFromCache || servedFromCache,
    );
  }
}

class _NetworkDetail implements _NetworkSummaryLike {
  const _NetworkDetail({
    required this.requestId,
    required this.method,
    required this.url,
    required this.resourceType,
    required this.requestHeaders,
    required this.responseHeaders,
    required this.startedAt,
    this.status,
    this.statusText,
    this.mimeType,
    this.encodedDataLength,
    this.durationMs,
    this.errorText,
    this.body,
    this.bodyBase64Encoded = false,
    this.bodyError,
    this.finished = false,
    this.failed = false,
    this.servedFromCache = false,
  });

  factory _NetworkDetail.fromJson(Map<dynamic, dynamic> json) => _NetworkDetail(
    requestId: json['requestId']?.toString() ?? '',
    method: json['method']?.toString() ?? 'GET',
    url: json['url']?.toString() ?? '',
    resourceType: json['resourceType']?.toString() ?? 'Other',
    requestHeaders: _stringMap(json['requestHeaders']),
    responseHeaders: _stringMap(json['responseHeaders']),
    startedAt: _intValue(
      json['startedAt'],
      DateTime.now().millisecondsSinceEpoch,
    ),
    status: _intOrNull(json['status']),
    statusText: json['statusText']?.toString(),
    mimeType: json['mimeType']?.toString(),
    encodedDataLength: _intOrNull(json['encodedDataLength']),
    durationMs: _intOrNull(json['durationMs']),
    errorText: json['errorText']?.toString(),
    body: json['body']?.toString(),
    bodyBase64Encoded: json['bodyBase64Encoded'] == true,
    bodyError: json['bodyError']?.toString(),
    finished: json['finished'] == true,
    failed: json['failed'] == true,
    servedFromCache: json['servedFromCache'] == true,
  );

  final String requestId;
  @override
  final String method;
  @override
  final String url;
  @override
  final String resourceType;
  final Map<String, String> requestHeaders;
  final Map<String, String> responseHeaders;
  final int startedAt;
  @override
  final int? status;
  final String? statusText;
  @override
  final String? mimeType;
  @override
  final int? encodedDataLength;
  @override
  final int? durationMs;
  @override
  final String? errorText;
  final String? body;
  final bool bodyBase64Encoded;
  final String? bodyError;
  @override
  final bool finished;
  @override
  final bool failed;
  @override
  final bool servedFromCache;
}

class _NetworkDetailUpdate {
  const _NetworkDetailUpdate({
    required this.requestId,
    this.detail,
    this.error,
  });

  final String requestId;
  final _NetworkDetail? detail;
  final String? error;
}

const List<String> _networkFilterOptions = <String>[
  'All',
  'XHR',
  'JS',
  'CSS',
  'Img',
  'Media',
  'Other',
];

bool _matchesNetworkFilter(_NetworkEntry entry, String filter) {
  switch (filter) {
    case 'XHR':
      return entry.resourceType == 'XHR' ||
          entry.resourceType == 'Fetch' ||
          entry.resourceType == 'Preflight';
    case 'JS':
      return entry.resourceType == 'Script';
    case 'CSS':
      return entry.resourceType == 'Stylesheet';
    case 'Img':
      return entry.resourceType == 'Image';
    case 'Media':
      return entry.resourceType == 'Media' || entry.resourceType == 'Font';
    case 'Other':
      return !<String>{
        'XHR',
        'Fetch',
        'Preflight',
        'Script',
        'Stylesheet',
        'Image',
        'Media',
        'Font',
      }.contains(entry.resourceType);
    case 'All':
    default:
      return true;
  }
}

String _networkResourceTypeLabel(String type) {
  switch (type) {
    case 'Stylesheet':
      return 'CSS';
    case 'Script':
      return 'JS';
    case 'Image':
      return 'Img';
    case 'Document':
      return 'Doc';
    case 'WebSocket':
      return 'WS';
    default:
      return type.isEmpty ? 'Other' : type;
  }
}

String _networkDisplayName(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
      return uri.pathSegments.last;
    }
    if (uri.host.isNotEmpty) return uri.host;
  } catch (_) {
    // Ignore parse failures and fall back to the raw URL.
  }
  return url;
}

String _networkDisplayLocation(String url) {
  try {
    final uri = Uri.parse(url);
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '${uri.scheme}://${uri.host}$port$path';
  } catch (_) {
    return url;
  }
}

Color _networkStatusColor(AppColors colors, _NetworkSummaryLike entry) {
  if (entry.failed) return colors.danger;
  final status = entry.status;
  if (status == null) return colors.textTertiary;
  if (status >= 500) return colors.danger;
  if (status >= 400) return colors.warning;
  if (status >= 300) return colors.accent;
  if (status >= 200) return colors.success;
  return colors.textSecondary;
}

String _networkStatusLabel(_NetworkSummaryLike entry) {
  if (entry.failed) return 'ERR';
  if (entry.status != null) return '${entry.status}';
  return entry.finished ? 'done' : '...';
}

String _formatNetworkBytes(int bytes) {
  final normalizedBytes = bytes < 0 ? 0 : bytes;
  if (normalizedBytes < 1024) return '$normalizedBytes B';
  if (normalizedBytes < 1024 * 1024) {
    return '${(normalizedBytes / 1024).toStringAsFixed(normalizedBytes < 10 * 1024 ? 1 : 0)} KB';
  }
  return '${(normalizedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _prettyNetworkBody(String body, String mimeType) {
  if (mimeType.contains('json')) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
    } catch (_) {
      return body;
    }
  }
  return body;
}

Map<String, String> _stringMap(Object? value) {
  if (value is! Map) return const <String, String>{};
  return value.map(
    (key, entryValue) => MapEntry(key.toString(), entryValue.toString()),
  );
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return null;
}

class _ReconnectingChip extends StatelessWidget {
  const _ReconnectingChip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.accent,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
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
          color: colors.accent.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colors.accent.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.aspect_ratio_rounded, size: 14, color: colors.accent),
            const SizedBox(width: 6),
            Text(
              '$width x $height',
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
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 12, 18, 18 + keyboardInset),
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
