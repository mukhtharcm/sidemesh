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
    this.autoResizeViewport = false,
    this.onOpenInWindow,
  });

  final HostProfile host;
  final ApiClient api;
  final HostBrowserPreviewInfo preview;
  final bool stopOnDispose;
  final bool autoResizeViewport;
  final VoidCallback? onOpenInWindow;

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
          autoResizeViewport: autoResizeViewport,
          onOpenInWindow: onOpenInWindow,
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
    this.autoResizeViewport = false,
    this.onBack,
    this.onMinimize,
    this.onOpenInWindow,
    this.onStopped,
  });

  final HostProfile host;
  final ApiClient api;
  final HostBrowserPreviewInfo preview;
  final bool stopOnDispose;
  final bool showHeader;
  final bool autoResizeViewport;
  final VoidCallback? onBack;
  final VoidCallback? onMinimize;
  final VoidCallback? onOpenInWindow;
  final void Function(HostBrowserPreviewInfo preview)? onStopped;

  @override
  State<BrowserPreviewPane> createState() => _BrowserPreviewPaneState();
}

class _BrowserPreviewPaneState extends State<BrowserPreviewPane>
    with WidgetsBindingObserver {
  static const _firstFrameTimeout = Duration(seconds: 18);
  static const _maxFirstFrameReconnects = 3;
  static const _maxAutoResizeWidth = 3840;
  static const _maxAutoResizeHeight = 2160;

  final _textController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _browserFocusNode = FocusNode(debugLabel: 'browser-preview-input');
  final _urlFocusNode = FocusNode();
  final _urlController = TextEditingController();
  final _networkSearchController = TextEditingController();
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _firstFrameTimer;
  Timer? _autoResizeTimer;
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
  bool _hasLivePreviewSnapshot = false;
  int _firstFrameReconnects = 0;
  bool _devToolsOpen = false;
  int _devToolsTabIndex = 0;
  bool _pageLoading = false;
  final List<_ConsoleEntry> _consoleEntries = [];
  final int _maxConsoleEntries = 256;
  int _consoleClearedSeqFloor = 0;
  final Map<String, _NetworkEntry> _networkEntries = <String, _NetworkEntry>{};
  final List<String> _networkEntryOrder = <String>[];
  final Map<String, _NetworkDetail> _networkDetails =
      <String, _NetworkDetail>{};
  final StreamController<_NetworkDetailUpdate> _networkDetailUpdates =
      StreamController<_NetworkDetailUpdate>.broadcast();
  final int _maxNetworkEntries = 300;
  String _networkFilter = 'All';
  String _networkSearchQuery = '';
  String _networkSort = 'Newest';
  int? _networkClearedStartedAtFloor;
  final Set<String> _networkClearedRequestIdsAtFloor = <String>{};
  bool _networkAvailable = true;
  String? _networkUnavailableMessage;
  _InspectorSnapshot? _inspectorSnapshot;
  bool _inspectorLoading = false;
  String? _inspectorError;
  bool _inspectorPickMode = false;
  _StorageSnapshot? _storageSnapshot;
  bool _storageLoading = false;
  String? _storageError;

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
    _networkSearchController.addListener(() {
      final value = _networkSearchController.text;
      if (value == _networkSearchQuery) return;
      if (!mounted) return;
      setState(() => _networkSearchQuery = value);
    });
    _connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    _inputFocusNode.dispose();
    _browserFocusNode.dispose();
    _urlFocusNode.dispose();
    _networkSearchController.dispose();
    _firstFrameTimer?.cancel();
    _autoResizeTimer?.cancel();
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

  void _scheduleAutoResize(Size size) {
    if (!widget.autoResizeViewport || !_hasLivePreviewSnapshot) {
      _autoResizeTimer?.cancel();
      return;
    }
    final width = size.width.round().clamp(240, _maxAutoResizeWidth);
    final height = size.height.round().clamp(240, _maxAutoResizeHeight);
    if (_preview.width == width && _preview.height == height) {
      return;
    }
    _autoResizeTimer?.cancel();
    _autoResizeTimer = Timer(const Duration(milliseconds: 160), () {
      if (!mounted) return;
      if (_preview.width == width && _preview.height == height) {
        return;
      }
      setState(() {
        _preview = _preview.copyWith(width: width, height: height);
        _frameWidth = width;
        _frameHeight = height;
      });
      _send({
        'type': 'resize',
        'width': width,
        'height': height,
      });
    });
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
          final browserContextChanged = preview.url != _preview.url;
          _preview = preview;
          _hasLivePreviewSnapshot = true;
          _frameWidth = preview.width;
          _frameHeight = preview.height;
          _urlController.text = preview.url;
          if (browserContextChanged) {
            _inspectorSnapshot = null;
            _inspectorLoading = false;
            _inspectorError = null;
            _inspectorPickMode = false;
            _storageSnapshot = null;
            _storageLoading = false;
            _storageError = null;
          }
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
    if (type == 'consoleSnapshot') {
      _handleConsoleSnapshot(frame);
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
    if (type == 'inspectorSnapshot') {
      _handleInspectorSnapshot(frame);
      return;
    }
    if (type == 'storageSnapshot') {
      _handleStorageSnapshot(frame);
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
    final entry = _ConsoleEntry.fromJson(frame);
    if (!_shouldIncludeConsoleEntry(entry)) return;
    setState(() {
      _consoleEntries.add(entry);
      if (_consoleEntries.length > _maxConsoleEntries) {
        _consoleEntries.removeAt(0);
      }
    });
  }

  void _handleConsoleSnapshot(Map<dynamic, dynamic> frame) {
    if (!mounted) return;
    final entries = frame['entries'];
    if (entries is! List) return;
    setState(() {
      _consoleEntries
        ..clear()
        ..addAll(
          entries
              .whereType<Map>()
              .map(_ConsoleEntry.fromJson)
              .where(_shouldIncludeConsoleEntry),
        );
      if (_consoleEntries.length > _maxConsoleEntries) {
        _consoleEntries.removeRange(
          0,
          _consoleEntries.length - _maxConsoleEntries,
        );
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

  void _handleStorageSnapshot(Map<dynamic, dynamic> frame) {
    if (!mounted) return;
    final rawSnapshot = frame['snapshot'];
    final error = frame['error']?.toString();
    if (rawSnapshot is Map) {
      setState(() {
        _storageSnapshot = _StorageSnapshot.fromJson(rawSnapshot);
        _storageLoading = false;
        _storageError = error;
      });
      return;
    }
    setState(() {
      _storageLoading = false;
      _storageError = error ?? 'Storage snapshot is unavailable.';
    });
  }

  void _handleInspectorSnapshot(Map<dynamic, dynamic> frame) {
    if (!mounted) return;
    final rawSnapshot = frame['snapshot'];
    final error = frame['error']?.toString();
    if (rawSnapshot is Map) {
      setState(() {
        _inspectorSnapshot = _InspectorSnapshot.fromJson(rawSnapshot);
        _inspectorLoading = false;
        _inspectorError = error;
        _inspectorPickMode = false;
      });
      return;
    }
    setState(() {
      _inspectorLoading = false;
      _inspectorError = error ?? 'Inspector snapshot is unavailable.';
      _inspectorPickMode = false;
    });
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
      requestBody: null,
      requestBodyError: null,
      bodyError: entry.resourceType == 'WebSocket' ? null : bodyError,
      finished: entry.finished,
      failed: entry.failed,
      servedFromCache: entry.servedFromCache,
      webSocketMessages: const <_NetworkWebSocketMessage>[],
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
    final filtered = _networkEntryOrder
        .map((requestId) => _networkEntries[requestId])
        .whereType<_NetworkEntry>()
        .where((entry) => _matchesNetworkFilter(entry, _networkFilter))
        .where((entry) => _matchesNetworkSearch(entry, _networkSearchQuery))
        .toList(growable: true);
    _sortNetworkEntries(filtered, _networkSort);
    return filtered;
  }

  bool _shouldIncludeConsoleEntry(_ConsoleEntry entry) {
    return entry.seq > _consoleClearedSeqFloor;
  }

  void _clearConsole() {
    if (_consoleEntries.isNotEmpty) {
      final latestSeq = _consoleEntries
          .map((entry) => entry.seq)
          .reduce((left, right) => left > right ? left : right);
      if (latestSeq > _consoleClearedSeqFloor) {
        _consoleClearedSeqFloor = latestSeq;
      }
    }
    setState(() {
      _consoleEntries.clear();
    });
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
    if (index == 2) {
      _requestStorageSnapshot(force: true);
      return;
    }
    if (index == 3) {
      _requestInspectorSnapshot(force: true);
    }
  }

  void _requestInspectorSnapshot({bool force = false}) {
    if (_inspectorLoading && !force) return;
    if (_inspectorSnapshot != null && !force) return;
    if (_channel == null) {
      setState(() {
        _inspectorLoading = false;
        _inspectorError =
            'Viewer is disconnected. Resume the stream to inspect the page.';
      });
      return;
    }
    final sent = _sendMessage({'type': 'inspectorSnapshotRequest'});
    if (!sent) {
      setState(() {
        _inspectorLoading = false;
        _inspectorError =
            'Viewer is disconnected. Resume the stream to inspect the page.';
      });
      return;
    }
    setState(() {
      _inspectorLoading = true;
      _inspectorError = null;
    });
  }

  void _requestStorageSnapshot({bool force = false}) {
    if (_storageLoading && !force) return;
    if (_storageSnapshot != null && !force) return;
    if (_channel == null) {
      setState(() {
        _storageLoading = false;
        _storageError =
            'Viewer is disconnected. Resume the stream to inspect storage.';
      });
      return;
    }
    final sent = _sendMessage({'type': 'storageRefreshRequest'});
    if (!sent) {
      setState(() {
        _storageLoading = false;
        _storageError =
            'Viewer is disconnected. Resume the stream to inspect storage.';
      });
      return;
    }
    setState(() {
      _storageLoading = true;
      _storageError = null;
    });
  }

  void _performStorageAction(Map<String, dynamic> message) {
    if (_channel == null) {
      setState(() {
        _storageLoading = false;
        _storageError =
            'Viewer is disconnected. Resume the stream to edit storage.';
      });
      return;
    }
    final sent = _sendMessage(message);
    if (!sent) {
      setState(() {
        _storageLoading = false;
        _storageError =
            'Viewer is disconnected. Resume the stream to edit storage.';
      });
      return;
    }
    setState(() {
      _storageLoading = true;
      _storageError = null;
    });
  }

  void _selectInspectorPath(List<int> path) {
    if (_channel == null) {
      setState(() {
        _inspectorLoading = false;
        _inspectorError =
            'Viewer is disconnected. Resume the stream to inspect the page.';
      });
      return;
    }
    final sent = _sendMessage({
      'type': 'inspectorSelectPath',
      'path': path,
    });
    if (!sent) {
      setState(() {
        _inspectorLoading = false;
        _inspectorError =
            'Viewer is disconnected. Resume the stream to inspect the page.';
      });
      return;
    }
    setState(() {
      _inspectorLoading = true;
      _inspectorError = null;
      _inspectorPickMode = false;
    });
  }

  void _inspectPreviewPoint(Offset point) {
    if (_channel == null) {
      setState(() {
        _inspectorLoading = false;
        _inspectorError =
            'Viewer is disconnected. Resume the stream to inspect the page.';
      });
      return;
    }
    final sent = _sendMessage({
      'type': 'inspectorInspectPoint',
      'x': point.dx,
      'y': point.dy,
    });
    if (!sent) {
      setState(() {
        _inspectorLoading = false;
        _inspectorError =
            'Viewer is disconnected. Resume the stream to inspect the page.';
      });
      return;
    }
    setState(() {
      _inspectorLoading = true;
      _inspectorError = null;
      _inspectorPickMode = false;
    });
  }

  void _toggleInspectorPickMode() {
    setState(() {
      _inspectorPickMode = !_inspectorPickMode;
      _inspectorError = null;
    });
  }

  Future<void> _showStorageEntryEditor(
    String area, {
    _StorageEntry? existing,
  }) async {
    final result = await showDialog<_StorageEntryDraft>(
      context: context,
      builder: (context) => _StorageEntryEditorDialog(
        title: existing == null
            ? 'Add ${_storageAreaLabel(area)} entry'
            : 'Edit ${_storageAreaLabel(area)} entry',
        initialKey: existing?.key ?? '',
        initialValue: existing?.value ?? '',
        keyEnabled: existing == null,
      ),
    );
    if (result == null) return;
    _performStorageAction({
      'type': 'storageSetEntry',
      'area': area,
      'key': result.key,
      'value': result.value,
    });
  }

  Future<void> _confirmDeleteStorageEntry(
    String area,
    _StorageEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${_storageAreaLabel(area)} entry?'),
        content: Text('Remove `${entry.key}` from ${_storageAreaLabel(area)}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _performStorageAction({
      'type': 'storageRemoveEntry',
      'area': area,
      'key': entry.key,
    });
  }

  Future<void> _confirmClearStorageArea(String area) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear ${_storageAreaLabel(area)}?'),
        content: Text(
          'This removes every entry from ${_storageAreaLabel(area)} for the current page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _performStorageAction({
      'type': 'storageClearEntries',
      'area': area,
    });
  }

  Future<void> _confirmDeleteCookie(_StorageCookie cookie) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete cookie?'),
        content: Text('Remove the `${cookie.name}` cookie from this page?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _performStorageAction({
      'type': 'storageDeleteCookie',
      'name': cookie.name,
      'domain': cookie.domain,
      'path': cookie.path,
    });
  }

  Future<void> _confirmClearCookies() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear cookies?'),
        content: const Text(
          'This removes every cookie currently visible for the page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _performStorageAction({'type': 'storageClearCookies'});
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
    if (_inspectorPickActive) return;
    final point = _mapPoint(details.localPosition, size);
    if (point == null) return;
    _send({'type': 'tapDown', 'x': point.dx, 'y': point.dy});
  }

  void _sendTapUp(TapUpDetails details, Size size) {
    final point = _mapPoint(details.localPosition, size);
    if (point == null) return;
    if (_inspectorPickActive) {
      _inspectPreviewPoint(point);
      return;
    }
    _send({'type': 'tapUp', 'x': point.dx, 'y': point.dy});
  }

  void _sendHover(PointerHoverEvent event, Size size) {
    if (_inspectorPickActive) return;
    final point = _mapPoint(event.localPosition, size);
    if (point == null) return;
    _send({'type': 'hover', 'x': point.dx, 'y': point.dy});
  }

  void _sendScroll(DragUpdateDetails details, Size size) {
    if (_inspectorPickActive) return;
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
    if (_inspectorPickActive) return;
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

  bool get _inspectorPickActive {
    return _devToolsOpen && _devToolsTabIndex == 3 && _inspectorPickMode;
  }

  Rect? _inspectorHighlightRect(Size size) {
    if (!_devToolsOpen || _devToolsTabIndex != 3) return null;
    final box = _inspectorSnapshot?.selectedNode?.box;
    if (box == null) return null;
    if (box.width <= 0 || box.height <= 0) return null;
    final imageRect = _containedImageRect(size);
    final scaleX = imageRect.width / _frameWidth;
    final scaleY = imageRect.height / _frameHeight;
    final mapped = Rect.fromLTWH(
      imageRect.left + (box.x * scaleX),
      imageRect.top + (box.y * scaleY),
      box.width * scaleX,
      box.height * scaleY,
    );
    final clipped = mapped.intersect(imageRect);
    if (clipped.width <= 0 || clipped.height <= 0) return null;
    return clipped;
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
          onOpenInWindow: widget.onOpenInWindow,
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
                      _scheduleAutoResize(size);
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
                              key: const ValueKey('browserPreviewCanvas'),
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (details) =>
                                  _sendTapDown(details, size),
                              onTapUp: (details) =>
                                  _sendTapUp(details, size),
                              onVerticalDragUpdate: (details) =>
                                  _sendScroll(details, size),
                              onHorizontalDragUpdate: (details) =>
                                  _sendScroll(details, size),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: _buildPreviewBody(colors),
                                  ),
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: _InspectorSelectionOverlay(
                                        highlightRect:
                                            _inspectorHighlightRect(size),
                                        pickMode: _inspectorPickActive,
                                        hasSelection:
                                            _inspectorSnapshot?.selectedNode !=
                                            null,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
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
            networkSearchController: _networkSearchController,
            networkSearchQuery: _networkSearchQuery,
            networkSort: _networkSort,
            inspectorSnapshot: _inspectorSnapshot,
            inspectorLoading: _inspectorLoading,
            inspectorError: _inspectorError,
            inspectorPickMode: _inspectorPickMode,
            storageSnapshot: _storageSnapshot,
            storageLoading: _storageLoading,
            storageError: _storageError,
            onNetworkFilterChanged: (value) =>
                setState(() => _networkFilter = value),
            onNetworkSearchChanged: (value) {
              if (_networkSearchController.text == value) return;
              _networkSearchController.value = TextEditingValue(
                text: value,
                selection: TextSelection.collapsed(offset: value.length),
              );
            },
            onNetworkSortChanged: (value) =>
                setState(() => _networkSort = value),
            onClearConsole: _clearConsole,
            onClearNetwork: _clearNetworkLog,
            onRefreshInspector: () => _requestInspectorSnapshot(force: true),
            onToggleInspectorPickMode: _toggleInspectorPickMode,
            onSelectInspectorPath: _selectInspectorPath,
            onRefreshStorage: () => _requestStorageSnapshot(force: true),
            onAddStorageEntry: (area) =>
                unawaited(_showStorageEntryEditor(area)),
            onEditStorageEntry: (area, entry) =>
                unawaited(_showStorageEntryEditor(area, existing: entry)),
            onDeleteStorageEntry: (area, entry) =>
                unawaited(_confirmDeleteStorageEntry(area, entry)),
            onClearStorageArea: (area) =>
                unawaited(_confirmClearStorageArea(area)),
            onDeleteCookie: (cookie) => unawaited(_confirmDeleteCookie(cookie)),
            onClearCookies: () => unawaited(_confirmClearCookies()),
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
    this.onOpenInWindow,
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
  final VoidCallback? onOpenInWindow;
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
              if (onOpenInWindow != null) ...[
                const SizedBox(width: 2),
                _ChromeButton(
                  icon: Icons.open_in_new_rounded,
                  tooltip: 'Open in new window',
                  color: colors.accent,
                  onTap: onOpenInWindow!,
                ),
              ],
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
    required this.networkSearchController,
    required this.networkSearchQuery,
    required this.networkSort,
    required this.inspectorSnapshot,
    required this.inspectorLoading,
    required this.inspectorError,
    required this.inspectorPickMode,
    required this.storageSnapshot,
    required this.storageLoading,
    required this.storageError,
    required this.onNetworkFilterChanged,
    required this.onNetworkSearchChanged,
    required this.onNetworkSortChanged,
    required this.onClearConsole,
    required this.onClearNetwork,
    required this.onRefreshInspector,
    required this.onToggleInspectorPickMode,
    required this.onSelectInspectorPath,
    required this.onRefreshStorage,
    required this.onAddStorageEntry,
    required this.onEditStorageEntry,
    required this.onDeleteStorageEntry,
    required this.onClearStorageArea,
    required this.onDeleteCookie,
    required this.onClearCookies,
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
  final TextEditingController networkSearchController;
  final String networkSearchQuery;
  final String networkSort;
  final _InspectorSnapshot? inspectorSnapshot;
  final bool inspectorLoading;
  final String? inspectorError;
  final bool inspectorPickMode;
  final _StorageSnapshot? storageSnapshot;
  final bool storageLoading;
  final String? storageError;
  final ValueChanged<String> onNetworkFilterChanged;
  final ValueChanged<String> onNetworkSearchChanged;
  final ValueChanged<String> onNetworkSortChanged;
  final VoidCallback onClearConsole;
  final VoidCallback onClearNetwork;
  final VoidCallback onRefreshInspector;
  final VoidCallback onToggleInspectorPickMode;
  final ValueChanged<List<int>> onSelectInspectorPath;
  final VoidCallback onRefreshStorage;
  final ValueChanged<String> onAddStorageEntry;
  final void Function(String area, _StorageEntry entry) onEditStorageEntry;
  final void Function(String area, _StorageEntry entry) onDeleteStorageEntry;
  final ValueChanged<String> onClearStorageArea;
  final ValueChanged<_StorageCookie> onDeleteCookie;
  final VoidCallback onClearCookies;
  final void Function(_NetworkEntry entry) onOpenNetworkDetail;
  final HostBrowserPreviewInfo preview;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final showingConsole = tabIndex == 0;
    final showingInspector = tabIndex == 3;
    final showingStorage = tabIndex == 2;
    return Container(
      height: 380,
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
                _DevTab(
                  label: 'Storage',
                  active: showingStorage,
                  onTap: () => onTabChanged(2),
                ),
                _DevTab(
                  label: 'Inspector',
                  active: showingInspector,
                  onTap: () => onTabChanged(3),
                ),
                const Spacer(),
                if (showingInspector)
                  IconButton(
                    key: const ValueKey('browserPreviewInspectorPickButton'),
                    icon: const Icon(Icons.ads_click_rounded, size: 18),
                    tooltip: inspectorPickMode
                        ? 'Cancel element pick'
                        : 'Pick element from page',
                    color: inspectorPickMode ? colors.accent : null,
                    onPressed: onToggleInspectorPickMode,
                    visualDensity: VisualDensity.compact,
                  ),
                if (showingStorage || showingInspector)
                  IconButton(
                    key: ValueKey(
                      showingStorage
                          ? 'browserPreviewStorageRefreshButton'
                          : 'browserPreviewInspectorRefreshButton',
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    tooltip: showingStorage
                        ? 'Refresh storage'
                        : 'Refresh inspector',
                    onPressed: showingStorage
                        ? onRefreshStorage
                        : onRefreshInspector,
                    visualDensity: VisualDensity.compact,
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    tooltip: showingConsole
                        ? 'Clear console'
                        : 'Clear network log',
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
                : showingStorage
                ? _StorageTab(
                    snapshot: storageSnapshot,
                    loading: storageLoading,
                    error: storageError,
                    onRefresh: onRefreshStorage,
                    onAddStorageEntry: onAddStorageEntry,
                    onEditStorageEntry: onEditStorageEntry,
                    onDeleteStorageEntry: onDeleteStorageEntry,
                    onClearStorageArea: onClearStorageArea,
                    onDeleteCookie: onDeleteCookie,
                    onClearCookies: onClearCookies,
                  )
                : showingInspector
                ? _InspectorTab(
                    snapshot: inspectorSnapshot,
                    loading: inspectorLoading,
                    error: inspectorError,
                    pickMode: inspectorPickMode,
                    onRefresh: onRefreshInspector,
                    onTogglePickMode: onToggleInspectorPickMode,
                    onSelectPath: onSelectInspectorPath,
                  )
                : _NetworkTab(
                    entries: networkEntries,
                    networkAvailable: networkAvailable,
                    networkUnavailableMessage: networkUnavailableMessage,
                    filter: networkFilter,
                    searchController: networkSearchController,
                    searchQuery: networkSearchQuery,
                    sort: networkSort,
                    onFilterChanged: onNetworkFilterChanged,
                    onSearchChanged: onNetworkSearchChanged,
                    onSortChanged: onNetworkSortChanged,
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
    final metadata = <String>[
      _formatConsoleTimestamp(entry.timestamp),
      if (entry.source != null && entry.source!.isNotEmpty) entry.source!,
      if (entry.url != null && entry.url!.isNotEmpty)
        '${entry.url}:${entry.lineNumber ?? 0}',
    ];
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
                if (metadata.isNotEmpty)
                  Text(
                    metadata.join(' · '),
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

class _InspectorSelectionOverlay extends StatelessWidget {
  const _InspectorSelectionOverlay({
    required this.highlightRect,
    required this.pickMode,
    required this.hasSelection,
  });

  final Rect? highlightRect;
  final bool pickMode;
  final bool hasSelection;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (highlightRect == null && !pickMode && !hasSelection) {
      return const SizedBox.shrink();
    }
    return Stack(
      children: [
        if (highlightRect != null)
          Positioned.fromRect(
            rect: highlightRect!,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: colors.accent, width: 2),
              ),
            ),
          ),
        if (pickMode)
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.74),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: colors.border),
              ),
              child: Text(
                'Tap the page preview to inspect an element',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _InspectorTab extends StatelessWidget {
  const _InspectorTab({
    required this.snapshot,
    required this.loading,
    required this.error,
    required this.pickMode,
    required this.onRefresh,
    required this.onTogglePickMode,
    required this.onSelectPath,
  });

  final _InspectorSnapshot? snapshot;
  final bool loading;
  final String? error;
  final bool pickMode;
  final VoidCallback onRefresh;
  final VoidCallback onTogglePickMode;
  final ValueChanged<List<int>> onSelectPath;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (loading && snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error ?? 'No inspector snapshot loaded yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Load inspector'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onTogglePickMode,
                    icon: const Icon(Icons.ads_click_rounded),
                    label: Text(
                      pickMode ? 'Cancel pick mode' : 'Pick from page',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final selectedNode = snapshot!.selectedNode;
    return ListView(
      key: const ValueKey('browserPreviewInspectorList'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StorageSummaryCard(
              label: 'Selected',
              value: selectedNode?.selector ?? 'None',
            ),
            _StorageSummaryCard(
              label: 'Path',
              value: _inspectorPathLabel(snapshot!.selectedPath),
            ),
            _StorageSummaryCard(
              label: 'Warnings',
              value: '${snapshot!.warnings.length}',
            ),
          ],
        ),
        if (pickMode) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.accent.withValues(alpha: 0.28)),
            ),
            child: Text(
              'Tap anywhere on the preview above to inspect an element.',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
              ),
            ),
          ),
        ],
        if (loading) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (error != null && error!.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.danger.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colors.danger.withValues(alpha: 0.24),
              ),
            ),
            child: Text(
              error!,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
              ),
            ),
          ),
        ],
        if (snapshot!.warnings.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final warning in snapshot!.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.28),
                  ),
                ),
                child: Text(
                  warning,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
        ],
        const SizedBox(height: 14),
        _StorageSection(
          title: 'Selection',
          child: selectedNode == null
              ? const _StorageEmpty(message: 'No element selected.')
              : _InspectorSelectedNodeCard(node: selectedNode),
        ),
        _StorageSection(
          title: 'DOM tree',
          child: snapshot!.treeRoot == null
              ? const _StorageEmpty(message: 'DOM tree is unavailable.')
              : _InspectorTreeNodeView(
                  node: snapshot!.treeRoot!,
                  depth: 0,
                  onSelectPath: onSelectPath,
                ),
        ),
        _StorageSection(
          title: 'Attributes',
          child: selectedNode == null || selectedNode.attributes.isEmpty
              ? const _StorageEmpty(message: 'No attributes for this node.')
              : _InspectorNameValueList(entries: selectedNode.attributes),
        ),
        _StorageSection(
          title: 'Computed styles',
          child: selectedNode == null || selectedNode.computedStyles.isEmpty
              ? const _StorageEmpty(
                  message: 'No computed styles were captured.',
                )
              : _InspectorNameValueList(entries: selectedNode.computedStyles),
        ),
        _StorageSection(
          title: 'Inline styles',
          child: selectedNode == null || selectedNode.inlineStyles.isEmpty
              ? const _StorageEmpty(message: 'No inline styles on this node.')
              : _InspectorNameValueList(entries: selectedNode.inlineStyles),
        ),
      ],
    );
  }
}

class _InspectorSelectedNodeCard extends StatelessWidget {
  const _InspectorSelectedNodeCard({required this.node});

  final _InspectorSelectedNode node;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final box = node.box;
    final metadata = <String>[
      _inspectorPathLabel(node.path),
      '${node.childElementCount} ${node.childElementCount == 1 ? 'child' : 'children'}',
      if (box != null)
        '${box.width.toStringAsFixed(0)} × ${box.height.toStringAsFixed(0)} at ${box.x.toStringAsFixed(0)}, ${box.y.toStringAsFixed(0)}',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            node.selector,
            style: monoStyle(
              color: colors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            metadata.join(' · '),
            style: TextStyle(
              color: colors.textTertiary,
              fontSize: 10,
            ),
          ),
          if (node.textPreview != null && node.textPreview!.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              node.textPreview!,
              style: monoStyle(
                color: colors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InspectorTreeNodeView extends StatelessWidget {
  const _InspectorTreeNodeView({
    required this.node,
    required this.depth,
    required this.onSelectPath,
  });

  final _InspectorNode node;
  final int depth;
  final ValueChanged<List<int>> onSelectPath;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: depth * 14.0, bottom: 8),
          child: InkWell(
            key: ValueKey(
              'browserPreviewInspectorNode-${_inspectorPathKey(node.path)}',
            ),
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSelectPath(node.path),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: node.isSelected
                    ? colors.accent.withValues(alpha: 0.12)
                    : colors.canvas,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: node.isSelected ? colors.accent : colors.border,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          node.selector,
                          style: monoStyle(
                            color: colors.textPrimary,
                            fontSize: 11,
                            fontWeight: node.isSelected
                                ? FontWeight.w800
                                : FontWeight.w700,
                          ),
                        ),
                      ),
                      if (node.isSelected)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colors.accent.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Selected',
                            style: TextStyle(
                              color: colors.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _inspectorPathLabel(node.path),
                    style: TextStyle(
                      color: colors.textTertiary,
                      fontSize: 10,
                    ),
                  ),
                  if (node.textPreview != null && node.textPreview!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      node.textPreview!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        for (final child in node.children)
          _InspectorTreeNodeView(
            node: child,
            depth: depth + 1,
            onSelectPath: onSelectPath,
          ),
        if (node.truncatedChildren)
          Padding(
            padding: EdgeInsets.only(left: (depth + 1) * 14.0, bottom: 8),
            child: Text(
              'More children are present but not shown in this snapshot.',
              style: TextStyle(
                color: colors.textTertiary,
                fontSize: 10,
              ),
            ),
          ),
      ],
    );
  }
}

class _InspectorNameValueList extends StatelessWidget {
  const _InspectorNameValueList({required this.entries});

  final List<_InspectorNameValue> entries;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: entries.map((entry) {
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.name,
                style: monoStyle(
                  color: colors.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                entry.value,
                style: monoStyle(
                  color: colors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );
      }).toList(growable: false),
    );
  }
}

class _StorageTab extends StatelessWidget {
  const _StorageTab({
    required this.snapshot,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onAddStorageEntry,
    required this.onEditStorageEntry,
    required this.onDeleteStorageEntry,
    required this.onClearStorageArea,
    required this.onDeleteCookie,
    required this.onClearCookies,
  });

  final _StorageSnapshot? snapshot;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;
  final ValueChanged<String> onAddStorageEntry;
  final void Function(String area, _StorageEntry entry) onEditStorageEntry;
  final void Function(String area, _StorageEntry entry) onDeleteStorageEntry;
  final ValueChanged<String> onClearStorageArea;
  final ValueChanged<_StorageCookie> onDeleteCookie;
  final VoidCallback onClearCookies;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (loading && snapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error ?? 'No storage snapshot loaded yet.',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Load storage'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('browserPreviewStorageList'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StorageSummaryCard(
              label: 'Origin',
              value: snapshot!.origin ?? 'Unknown',
            ),
            _StorageSummaryCard(
              label: 'Cookies',
              value: '${snapshot!.cookies.length}',
            ),
            _StorageSummaryCard(
              label: 'localStorage',
              value: '${snapshot!.localStorage.length}',
            ),
            _StorageSummaryCard(
              label: 'IndexedDB',
              value: '${snapshot!.indexedDbDatabases.length}',
            ),
            _StorageSummaryCard(
              label: 'sessionStorage',
              value: '${snapshot!.sessionStorage.length}',
            ),
            _StorageSummaryCard(
              label: 'Quota',
              value: _storageQuotaLabel(snapshot!),
            ),
          ],
        ),
        if (loading) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (error != null && error!.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.danger.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colors.danger.withValues(alpha: 0.24),
              ),
            ),
            child: Text(
              error!,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 11,
              ),
            ),
          ),
        ],
        if (snapshot!.warnings.isNotEmpty) ...[
          const SizedBox(height: 14),
          for (final warning in snapshot!.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.28),
                  ),
                ),
                child: Text(
                  warning,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
        ],
        if (snapshot!.usageBreakdown.isNotEmpty) ...[
          const SizedBox(height: 14),
          _StorageSection(
            title: 'Usage breakdown',
            child: Column(
              children: snapshot!.usageBreakdown.map((entry) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _storageUsageTypeLabel(entry.storageType),
                          style: TextStyle(
                            color: colors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      Text(
                        _formatNetworkBytes(entry.usage),
                        style: monoStyle(
                          color: colors.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(growable: false),
            ),
          ),
        ],
        _StorageSection(
          title: 'IndexedDB',
          child: snapshot!.indexedDbDatabases.isEmpty
              ? _StorageEmpty(message: 'No IndexedDB databases found.')
              : Column(
                  children: snapshot!.indexedDbDatabases.map((database) {
                    return _IndexedDbDatabaseCard(database: database);
                  }).toList(growable: false),
                ),
        ),
        const SizedBox(height: 14),
        _StorageSection(
          title: 'Cookies',
          actions: [
            _StorageSectionButton(
              icon: Icons.delete_sweep_outlined,
              tooltip: 'Clear cookies',
              buttonKey: const ValueKey('browserPreviewStorageClear-cookies'),
              onTap: snapshot!.cookies.isEmpty ? null : onClearCookies,
            ),
          ],
          child: snapshot!.cookies.isEmpty
              ? _StorageEmpty(message: 'No cookies found for this page.')
              : Column(
                  children: snapshot!.cookies.map((cookie) {
                    return _StorageCookieRow(
                      cookie: cookie,
                      onDelete: () => onDeleteCookie(cookie),
                    );
                  }).toList(growable: false),
                ),
        ),
        _StorageSection(
          title: 'localStorage',
          actions: [
            _StorageSectionButton(
              icon: Icons.add_rounded,
              tooltip: 'Add localStorage entry',
              buttonKey: const ValueKey('browserPreviewStorageAdd-localStorage'),
              onTap: () => onAddStorageEntry('localStorage'),
            ),
            _StorageSectionButton(
              icon: Icons.delete_sweep_outlined,
              tooltip: 'Clear localStorage',
              buttonKey: const ValueKey(
                'browserPreviewStorageClear-localStorage',
              ),
              onTap: snapshot!.localStorage.isEmpty
                  ? null
                  : () => onClearStorageArea('localStorage'),
            ),
          ],
          child: snapshot!.localStorage.isEmpty
              ? _StorageEmpty(message: 'No localStorage entries found.')
              : Column(
                  children: snapshot!.localStorage.map((entry) {
                    return _StorageEntryRow(
                      entry: entry,
                      onEdit: () => onEditStorageEntry('localStorage', entry),
                      onDelete: () =>
                          onDeleteStorageEntry('localStorage', entry),
                    );
                  }).toList(growable: false),
                ),
        ),
        _StorageSection(
          title: 'sessionStorage',
          actions: [
            _StorageSectionButton(
              icon: Icons.add_rounded,
              tooltip: 'Add sessionStorage entry',
              buttonKey: const ValueKey(
                'browserPreviewStorageAdd-sessionStorage',
              ),
              onTap: () => onAddStorageEntry('sessionStorage'),
            ),
            _StorageSectionButton(
              icon: Icons.delete_sweep_outlined,
              tooltip: 'Clear sessionStorage',
              buttonKey: const ValueKey(
                'browserPreviewStorageClear-sessionStorage',
              ),
              onTap: snapshot!.sessionStorage.isEmpty
                  ? null
                  : () => onClearStorageArea('sessionStorage'),
            ),
          ],
          child: snapshot!.sessionStorage.isEmpty
              ? _StorageEmpty(message: 'No sessionStorage entries found.')
              : Column(
                  children: snapshot!.sessionStorage.map((entry) {
                    return _StorageEntryRow(
                      entry: entry,
                      onEdit: () => onEditStorageEntry('sessionStorage', entry),
                      onDelete: () =>
                          onDeleteStorageEntry('sessionStorage', entry),
                    );
                  }).toList(growable: false),
                ),
        ),
      ],
    );
  }
}

class _StorageSummaryCard extends StatelessWidget {
  const _StorageSummaryCard({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: colors.textTertiary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: monoStyle(
              color: colors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageSection extends StatelessWidget {
  const _StorageSection({
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: AppWeights.title,
                  ),
                ),
              ),
              if (actions.isNotEmpty) ...actions,
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _StorageSectionButton extends StatelessWidget {
  const _StorageSectionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.buttonKey,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: buttonKey,
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
    );
  }
}

class _StorageEmpty extends StatelessWidget {
  const _StorageEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Text(
      message,
      style: TextStyle(color: colors.textSecondary),
    );
  }
}

class _IndexedDbDatabaseCard extends StatelessWidget {
  const _IndexedDbDatabaseCard({required this.database});

  final _IndexedDbDatabase database;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final storeCount = database.objectStores.length;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            database.name,
            style: monoStyle(
              color: colors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Version ${database.version ?? '?'} · $storeCount ${storeCount == 1 ? 'object store' : 'object stores'}',
            style: TextStyle(
              color: colors.textTertiary,
              fontSize: 10,
            ),
          ),
          if (database.objectStores.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final store in database.objectStores)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      store.name,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (store.keyPath != null &&
                            store.keyPath!.trim().isNotEmpty)
                          'key ${store.keyPath}',
                        if (store.autoIncrement) 'autoIncrement',
                      ].join(' · '),
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                    if (store.indexes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      for (final index in store.indexes)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            [
                              'Index ${index.name}',
                              if (index.keyPath != null &&
                                  index.keyPath!.trim().isNotEmpty)
                                index.keyPath!,
                              if (index.unique) 'unique',
                              if (index.multiEntry) 'multiEntry',
                            ].join(' · '),
                            style: TextStyle(
                              color: colors.textTertiary,
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _StorageCookieRow extends StatelessWidget {
  const _StorageCookieRow({
    required this.cookie,
    required this.onDelete,
  });

  final _StorageCookie cookie;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final metadata = <String>[
      cookie.domain,
      cookie.path,
      if (cookie.httpOnly) 'HttpOnly',
      if (cookie.secure) 'Secure',
      if (cookie.sameSite != null && cookie.sameSite!.isNotEmpty)
        cookie.sameSite!,
      cookie.session ? 'Session' : _storageCookieExpiryLabel(cookie.expires),
    ];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  cookie.name,
                  style: monoStyle(
                    color: colors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                tooltip: 'Delete cookie',
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            cookie.value,
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            metadata.join(' · '),
            style: TextStyle(
              color: colors.textTertiary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageEntryRow extends StatelessWidget {
  const _StorageEntryRow({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  final _StorageEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  entry.key,
                  style: monoStyle(
                    color: colors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 18),
                tooltip: 'Edit storage entry',
                onPressed: onEdit,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                tooltip: 'Delete storage entry',
                onPressed: onDelete,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            entry.value,
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageEntryEditorDialog extends StatefulWidget {
  const _StorageEntryEditorDialog({
    required this.title,
    required this.initialKey,
    required this.initialValue,
    required this.keyEnabled,
  });

  final String title;
  final String initialKey;
  final String initialValue;
  final bool keyEnabled;

  @override
  State<_StorageEntryEditorDialog> createState() =>
      _StorageEntryEditorDialogState();
}

class _StorageEntryEditorDialogState extends State<_StorageEntryEditorDialog> {
  late final TextEditingController _keyController;
  late final TextEditingController _valueController;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: widget.initialKey);
    _valueController = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  void _submit() {
    final key = _keyController.text.trim();
    if (key.isEmpty) return;
    Navigator.of(context).pop(
      _StorageEntryDraft(
        key: key,
        value: _valueController.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _keyController,
              autofocus: true,
              readOnly: !widget.keyEnabled,
              decoration: const InputDecoration(
                labelText: 'Key',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _valueController,
              maxLines: 4,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: 'Value',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _NetworkTab extends StatelessWidget {
  const _NetworkTab({
    required this.entries,
    required this.networkAvailable,
    required this.networkUnavailableMessage,
    required this.filter,
    required this.searchController,
    required this.searchQuery,
    required this.sort,
    required this.onFilterChanged,
    required this.onSearchChanged,
    required this.onSortChanged,
    required this.onOpenDetail,
  });

  final List<_NetworkEntry> entries;
  final bool networkAvailable;
  final String? networkUnavailableMessage;
  final String filter;
  final TextEditingController searchController;
  final String searchQuery;
  final String sort;
  final ValueChanged<String> onFilterChanged;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSortChanged;
  final void Function(_NetworkEntry entry) onOpenDetail;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: searchController,
                      onChanged: onSearchChanged,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search requests',
                        prefixIcon: const Icon(Icons.search_rounded, size: 18),
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colors.border),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: sort,
                        onChanged: (value) {
                          if (value != null) onSortChanged(value);
                        },
                        items: _networkSortOptions
                            .map(
                              (option) => DropdownMenuItem<String>(
                                value: option,
                                child: Text(option),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
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
            ],
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
                    searchQuery.trim().isEmpty
                        ? 'No network requests yet.'
                        : 'No requests match your search.',
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
      if (entry.webSocketMessageCount > 0)
        '${entry.webSocketMessageCount} ${entry.webSocketMessageCount == 1 ? 'msg' : 'msgs'}',
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
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                _networkDisplayName(entry.url),
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: colors.textPrimary,
                                      fontWeight: AppWeights.title,
                                    ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _NetworkDetailActionsButton(
                              entry: entry,
                              detail: detail,
                            ),
                          ],
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
                              if (_networkShouldShowRequestBody(detail))
                                _NetworkSection(
                                  title: 'Request body',
                                  child: _NetworkPayloadView(
                                    body: detail.requestBody,
                                    bodyError: detail.requestBodyError,
                                    mimeType: _networkRequestMimeType(detail),
                                    bodyBase64Encoded: false,
                                    emptyMessage:
                                        'No request body captured for this request.',
                                  ),
                                ),
                              if (detail.responseHeaders.isNotEmpty)
                                _NetworkSection(
                                  title: 'Response headers',
                                  child: _HeaderList(
                                    headers: detail.responseHeaders,
                                  ),
                                ),
                              if (_networkShouldShowWebSocketMessages(detail))
                                _NetworkSection(
                                  title: 'Messages',
                                  child: _NetworkWebSocketMessagesView(
                                    messages: detail.webSocketMessages,
                                  ),
                                ),
                              if (_networkShouldShowResponseBody(detail))
                                _NetworkSection(
                                  title: 'Response body',
                                  child: _NetworkPayloadView(
                                    body: detail.body,
                                    bodyError: detail.bodyError,
                                    mimeType: detail.mimeType ?? '',
                                    bodyBase64Encoded: detail.bodyBase64Encoded,
                                    emptyMessage:
                                        'No response body captured for this request.',
                                  ),
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

class _NetworkDetailActionsButton extends StatelessWidget {
  const _NetworkDetailActionsButton({required this.entry, required this.detail});

  final _NetworkEntry entry;
  final _NetworkDetail? detail;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_NetworkCopyAction>(
      tooltip: 'Copy request details',
      icon: const Icon(Icons.copy_all_rounded, size: 18),
      onSelected: (action) => _copyNetworkDetailAction(
        context,
        action,
        entry,
        detail,
      ),
      itemBuilder: (context) {
        final items = <PopupMenuEntry<_NetworkCopyAction>>[
          const PopupMenuItem<_NetworkCopyAction>(
            value: _NetworkCopyAction.url,
            child: Text('Copy URL'),
          ),
          const PopupMenuItem<_NetworkCopyAction>(
            value: _NetworkCopyAction.requestHeaders,
            child: Text('Copy request headers'),
          ),
          const PopupMenuItem<_NetworkCopyAction>(
            value: _NetworkCopyAction.responseHeaders,
            child: Text('Copy response headers'),
          ),
        ];
        if (detail?.requestBody != null) {
          items.add(
            const PopupMenuItem<_NetworkCopyAction>(
              value: _NetworkCopyAction.requestBody,
              child: Text('Copy request body'),
            ),
          );
        }
        if (detail?.body != null) {
          items.add(
            const PopupMenuItem<_NetworkCopyAction>(
              value: _NetworkCopyAction.responseBody,
              child: Text('Copy response body'),
            ),
          );
        }
        if (detail != null) {
          items.add(
            const PopupMenuItem<_NetworkCopyAction>(
              value: _NetworkCopyAction.curl,
              child: Text('Copy as cURL'),
            ),
          );
        }
        return items;
      },
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

class _NetworkPayloadView extends StatelessWidget {
  const _NetworkPayloadView({
    required this.body,
    required this.bodyError,
    required this.mimeType,
    required this.bodyBase64Encoded,
    required this.emptyMessage,
  });

  final String? body;
  final String? bodyError;
  final String mimeType;
  final bool bodyBase64Encoded;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (bodyError != null && bodyError!.isNotEmpty) {
      return SelectableText(
        bodyError!,
        style: TextStyle(color: colors.textSecondary),
      );
    }
    if (body == null) {
      return Text(
        emptyMessage,
        style: TextStyle(color: colors.textSecondary),
      );
    }
    if (bodyBase64Encoded && mimeType.startsWith('image/')) {
      try {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.memory(base64Decode(body!)),
        );
      } catch (_) {
        return Text(
          'Could not decode the image response body.',
          style: TextStyle(color: colors.textSecondary),
        );
      }
    }
    if (bodyBase64Encoded) {
      return SelectableText(
        'Binary payload (${_formatNetworkBytes(body!.length)} encoded characters)',
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
        _prettyNetworkBody(body!, mimeType),
        style: monoStyle(
          color: colors.textPrimary,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _NetworkWebSocketMessagesView extends StatelessWidget {
  const _NetworkWebSocketMessagesView({required this.messages});

  final List<_NetworkWebSocketMessage> messages;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (messages.isEmpty) {
      return Text(
        'No WebSocket messages captured yet.',
        style: TextStyle(color: colors.textSecondary),
      );
    }
    return Column(
      children: messages.map((message) {
        final directionColor = switch (message.direction) {
          'sent' => colors.accent,
          'received' => colors.success,
          'error' => colors.danger,
          _ => colors.textSecondary,
        };
        final directionLabel = switch (message.direction) {
          'sent' => 'Sent',
          'received' => 'Recv',
          'error' => 'Err',
          _ => message.direction,
        };
        final payloadText = _webSocketMessagePayloadText(message);
        final meta = <String>[
          directionLabel,
          _formatConsoleTimestamp(message.timestamp),
          if (message.opcode != null) 'opcode ${message.opcode}',
        ];
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: directionColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      directionLabel,
                      style: monoStyle(
                        color: directionColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      meta.join(' · '),
                      style: TextStyle(
                        color: colors.textTertiary,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                payloadText,
                style: monoStyle(
                  color: message.direction == 'error'
                      ? colors.danger
                      : colors.textPrimary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );
      }).toList(growable: false),
    );
  }
}

class _ConsoleEntry {
  const _ConsoleEntry({
    required this.seq,
    required this.type,
    required this.level,
    required this.text,
    this.source,
    this.url,
    this.lineNumber,
    this.columnNumber,
    required this.timestamp,
  });

  factory _ConsoleEntry.fromJson(Map<dynamic, dynamic> json) => _ConsoleEntry(
    seq: _intValue(json['seq'], 0),
    type: json['type']?.toString() ?? 'log',
    level: json['level']?.toString() ?? 'log',
    text: json['text']?.toString() ?? '',
    source: json['source']?.toString(),
    url: json['url']?.toString(),
    lineNumber: _intOrNull(json['lineNumber']),
    columnNumber: _intOrNull(json['columnNumber']),
    timestamp: _intValue(
      json['timestamp'],
      DateTime.now().millisecondsSinceEpoch,
    ),
  );

  final int seq;
  final String type;
  final String level;
  final String text;
  final String? source;
  final String? url;
  final int? lineNumber;
  final int? columnNumber;
  final int timestamp;
}

class _InspectorSnapshot {
  const _InspectorSnapshot({
    required this.url,
    required this.refreshedAt,
    required this.selectedPath,
    required this.treeRoot,
    required this.selectedNode,
    required this.warnings,
  });

  factory _InspectorSnapshot.fromJson(Map<dynamic, dynamic> json) =>
      _InspectorSnapshot(
        url: json['url']?.toString() ?? '',
        refreshedAt: _intValue(
          json['refreshedAt'],
          DateTime.now().millisecondsSinceEpoch,
        ),
        selectedPath: _inspectorPathList(json['selectedPath']),
        treeRoot: _inspectorNodeOrNull(json['treeRoot']),
        selectedNode: _inspectorSelectedNodeOrNull(json['selectedNode']),
        warnings: _stringList(json['warnings']),
      );

  final String url;
  final int refreshedAt;
  final List<int> selectedPath;
  final _InspectorNode? treeRoot;
  final _InspectorSelectedNode? selectedNode;
  final List<String> warnings;
}

class _InspectorNode {
  const _InspectorNode({
    required this.path,
    required this.nodeName,
    required this.selector,
    required this.textPreview,
    required this.childElementCount,
    required this.isSelected,
    required this.truncatedChildren,
    required this.children,
  });

  factory _InspectorNode.fromJson(Map<dynamic, dynamic> json) => _InspectorNode(
    path: _inspectorPathList(json['path']),
    nodeName: json['nodeName']?.toString() ?? 'node',
    selector: json['selector']?.toString() ?? 'node',
    textPreview: json['textPreview']?.toString(),
    childElementCount: _intValue(json['childElementCount'], 0),
    isSelected: json['isSelected'] == true,
    truncatedChildren: json['truncatedChildren'] == true,
    children: _inspectorNodeList(json['children']),
  );

  final List<int> path;
  final String nodeName;
  final String selector;
  final String? textPreview;
  final int childElementCount;
  final bool isSelected;
  final bool truncatedChildren;
  final List<_InspectorNode> children;
}

class _InspectorSelectedNode {
  const _InspectorSelectedNode({
    required this.path,
    required this.nodeName,
    required this.selector,
    required this.textPreview,
    required this.childElementCount,
    required this.isSelected,
    required this.truncatedChildren,
    required this.children,
    required this.attributes,
    required this.computedStyles,
    required this.inlineStyles,
    required this.box,
  });

  factory _InspectorSelectedNode.fromJson(Map<dynamic, dynamic> json) =>
      _InspectorSelectedNode(
        path: _inspectorPathList(json['path']),
        nodeName: json['nodeName']?.toString() ?? 'node',
        selector: json['selector']?.toString() ?? 'node',
        textPreview: json['textPreview']?.toString(),
        childElementCount: _intValue(json['childElementCount'], 0),
        isSelected: json['isSelected'] == true,
        truncatedChildren: json['truncatedChildren'] == true,
        children: _inspectorNodeList(json['children']),
        attributes: _inspectorNameValueList(json['attributes']),
        computedStyles: _inspectorNameValueList(json['computedStyles']),
        inlineStyles: _inspectorNameValueList(json['inlineStyles']),
        box: _inspectorBoxOrNull(json['box']),
      );

  final List<int> path;
  final String nodeName;
  final String selector;
  final String? textPreview;
  final int childElementCount;
  final bool isSelected;
  final bool truncatedChildren;
  final List<_InspectorNode> children;
  final List<_InspectorNameValue> attributes;
  final List<_InspectorNameValue> computedStyles;
  final List<_InspectorNameValue> inlineStyles;
  final _InspectorBox? box;
}

class _InspectorNameValue {
  const _InspectorNameValue({
    required this.name,
    required this.value,
  });

  factory _InspectorNameValue.fromJson(Map<dynamic, dynamic> json) =>
      _InspectorNameValue(
        name: json['name']?.toString() ?? '',
        value: json['value']?.toString() ?? '',
      );

  final String name;
  final String value;
}

class _InspectorBox {
  const _InspectorBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory _InspectorBox.fromJson(Map<dynamic, dynamic> json) => _InspectorBox(
    x: _doubleValue(json['x'], 0),
    y: _doubleValue(json['y'], 0),
    width: _doubleValue(json['width'], 0),
    height: _doubleValue(json['height'], 0),
  );

  final double x;
  final double y;
  final double width;
  final double height;
}

class _StorageSnapshot {
  const _StorageSnapshot({
    required this.url,
    required this.origin,
    required this.refreshedAt,
    required this.cookies,
    required this.indexedDbDatabases,
    required this.localStorage,
    required this.sessionStorage,
    required this.usage,
    required this.quota,
    required this.usageBreakdown,
    required this.warnings,
  });

  factory _StorageSnapshot.fromJson(Map<dynamic, dynamic> json) =>
      _StorageSnapshot(
        url: json['url']?.toString() ?? '',
        origin: json['origin']?.toString(),
        refreshedAt: _intValue(
          json['refreshedAt'],
          DateTime.now().millisecondsSinceEpoch,
        ),
        cookies: _storageCookieList(json['cookies']),
        indexedDbDatabases: _indexedDbDatabaseList(json['indexedDbDatabases']),
        localStorage: _storageEntryList(json['localStorage']),
        sessionStorage: _storageEntryList(json['sessionStorage']),
        usage: _intOrNull(json['usage']),
        quota: _intOrNull(json['quota']),
        usageBreakdown: _storageUsageList(json['usageBreakdown']),
        warnings: _stringList(json['warnings']),
      );

  final String url;
  final String? origin;
  final int refreshedAt;
  final List<_StorageCookie> cookies;
  final List<_IndexedDbDatabase> indexedDbDatabases;
  final List<_StorageEntry> localStorage;
  final List<_StorageEntry> sessionStorage;
  final int? usage;
  final int? quota;
  final List<_StorageUsage> usageBreakdown;
  final List<String> warnings;
}

class _StorageCookie {
  const _StorageCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expires,
    required this.size,
    required this.httpOnly,
    required this.secure,
    required this.session,
    required this.sameSite,
  });

  factory _StorageCookie.fromJson(Map<dynamic, dynamic> json) => _StorageCookie(
    name: json['name']?.toString() ?? '',
    value: json['value']?.toString() ?? '',
    domain: json['domain']?.toString() ?? '',
    path: json['path']?.toString() ?? '/',
    expires: _intOrNull(json['expires']),
    size: _intOrNull(json['size']),
    httpOnly: json['httpOnly'] == true,
    secure: json['secure'] == true,
    session: json['session'] == true,
    sameSite: json['sameSite']?.toString(),
  );

  final String name;
  final String value;
  final String domain;
  final String path;
  final int? expires;
  final int? size;
  final bool httpOnly;
  final bool secure;
  final bool session;
  final String? sameSite;
}

class _StorageEntry {
  const _StorageEntry({
    required this.key,
    required this.value,
  });

  factory _StorageEntry.fromJson(Map<dynamic, dynamic> json) => _StorageEntry(
    key: json['key']?.toString() ?? '',
    value: json['value']?.toString() ?? '',
  );

  final String key;
  final String value;
}

class _StorageUsage {
  const _StorageUsage({
    required this.storageType,
    required this.usage,
  });

  factory _StorageUsage.fromJson(Map<dynamic, dynamic> json) => _StorageUsage(
    storageType: json['storageType']?.toString() ?? '',
    usage: _intValue(json['usage'], 0),
  );

  final String storageType;
  final int usage;
}

class _IndexedDbDatabase {
  const _IndexedDbDatabase({
    required this.name,
    required this.version,
    required this.objectStores,
  });

  factory _IndexedDbDatabase.fromJson(Map<dynamic, dynamic> json) =>
      _IndexedDbDatabase(
        name: json['name']?.toString() ?? '',
        version: _intOrNull(json['version']),
        objectStores: _indexedDbObjectStoreList(json['objectStores']),
      );

  final String name;
  final int? version;
  final List<_IndexedDbObjectStore> objectStores;
}

class _IndexedDbObjectStore {
  const _IndexedDbObjectStore({
    required this.name,
    required this.keyPath,
    required this.autoIncrement,
    required this.indexes,
  });

  factory _IndexedDbObjectStore.fromJson(Map<dynamic, dynamic> json) =>
      _IndexedDbObjectStore(
        name: json['name']?.toString() ?? '',
        keyPath: json['keyPath']?.toString(),
        autoIncrement: json['autoIncrement'] == true,
        indexes: _indexedDbIndexList(json['indexes']),
      );

  final String name;
  final String? keyPath;
  final bool autoIncrement;
  final List<_IndexedDbIndex> indexes;
}

class _IndexedDbIndex {
  const _IndexedDbIndex({
    required this.name,
    required this.keyPath,
    required this.unique,
    required this.multiEntry,
  });

  factory _IndexedDbIndex.fromJson(Map<dynamic, dynamic> json) =>
      _IndexedDbIndex(
        name: json['name']?.toString() ?? '',
        keyPath: json['keyPath']?.toString(),
        unique: json['unique'] == true,
        multiEntry: json['multiEntry'] == true,
      );

  final String name;
  final String? keyPath;
  final bool unique;
  final bool multiEntry;
}

class _StorageEntryDraft {
  const _StorageEntryDraft({
    required this.key,
    required this.value,
  });

  final String key;
  final String value;
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

class _NetworkWebSocketMessage {
  const _NetworkWebSocketMessage({
    required this.direction,
    required this.timestamp,
    this.opcode,
    this.payload,
    this.base64Encoded = false,
    this.error,
  });

  factory _NetworkWebSocketMessage.fromJson(Map<dynamic, dynamic> json) =>
      _NetworkWebSocketMessage(
        direction: json['direction']?.toString() ?? 'received',
        timestamp: _intValue(
          json['timestamp'],
          DateTime.now().millisecondsSinceEpoch,
        ),
        opcode: _intOrNull(json['opcode']),
        payload: json['payload']?.toString(),
        base64Encoded: json['base64Encoded'] == true,
        error: json['error']?.toString(),
      );

  final String direction;
  final int timestamp;
  final int? opcode;
  final String? payload;
  final bool base64Encoded;
  final String? error;
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
    this.webSocketMessageCount = 0,
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
    webSocketMessageCount: _intValue(json['webSocketMessageCount'], 0),
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
  final int webSocketMessageCount;

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
      webSocketMessageCount: other.webSocketMessageCount > webSocketMessageCount
          ? other.webSocketMessageCount
          : webSocketMessageCount,
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
    this.requestBody,
    this.requestBodyError,
    this.body,
    this.bodyBase64Encoded = false,
    this.bodyError,
    this.finished = false,
    this.failed = false,
    this.servedFromCache = false,
    this.webSocketMessages = const <_NetworkWebSocketMessage>[],
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
    requestBody: json['requestBody']?.toString(),
    requestBodyError: json['requestBodyError']?.toString(),
    body: json['body']?.toString(),
    bodyBase64Encoded: json['bodyBase64Encoded'] == true,
    bodyError: json['bodyError']?.toString(),
    finished: json['finished'] == true,
    failed: json['failed'] == true,
    servedFromCache: json['servedFromCache'] == true,
    webSocketMessages: _webSocketMessageList(json['webSocketMessages']),
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
  final String? requestBody;
  final String? requestBodyError;
  final String? body;
  final bool bodyBase64Encoded;
  final String? bodyError;
  @override
  final bool finished;
  @override
  final bool failed;
  @override
  final bool servedFromCache;
  final List<_NetworkWebSocketMessage> webSocketMessages;
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
  'WS',
  'Other',
];

const List<String> _networkSortOptions = <String>[
  'Newest',
  'Oldest',
  'Slowest',
  'Largest',
  'Status',
];

enum _NetworkCopyAction {
  url,
  requestHeaders,
  responseHeaders,
  requestBody,
  responseBody,
  curl,
}

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
    case 'WS':
      return entry.resourceType == 'WebSocket';
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
        'WebSocket',
      }.contains(entry.resourceType);
    case 'All':
    default:
      return true;
  }
}

bool _matchesNetworkSearch(_NetworkEntry entry, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;
  final haystack = [
    entry.method,
    entry.url,
    entry.resourceType,
    entry.mimeType ?? '',
    if (entry.status != null) '${entry.status}',
    entry.errorText ?? '',
  ].join(' ').toLowerCase();
  return normalizedQuery
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .every(haystack.contains);
}

void _sortNetworkEntries(List<_NetworkEntry> entries, String sort) {
  int compareNullableIntDesc(int? left, int? right) {
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return right.compareTo(left);
  }

  entries.sort((left, right) {
    switch (sort) {
      case 'Oldest':
        return left.startedAt.compareTo(right.startedAt);
      case 'Slowest':
        final durationOrder = compareNullableIntDesc(
          left.durationMs,
          right.durationMs,
        );
        if (durationOrder != 0) return durationOrder;
        return right.startedAt.compareTo(left.startedAt);
      case 'Largest':
        final sizeOrder = compareNullableIntDesc(
          left.encodedDataLength,
          right.encodedDataLength,
        );
        if (sizeOrder != 0) return sizeOrder;
        return right.startedAt.compareTo(left.startedAt);
      case 'Status':
        final statusOrder = compareNullableIntDesc(left.status, right.status);
        if (statusOrder != 0) return statusOrder;
        return right.startedAt.compareTo(left.startedAt);
      case 'Newest':
      default:
        return right.startedAt.compareTo(left.startedAt);
    }
  });
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
  if (mimeType.contains('x-www-form-urlencoded')) {
    try {
      final parts = Uri.splitQueryString(body);
      return parts.entries.map((entry) => '${entry.key}=${entry.value}').join('\n');
    } catch (_) {
      return body;
    }
  }
  return body;
}

bool _networkShouldShowRequestBody(_NetworkDetail detail) {
  if (detail.resourceType == 'WebSocket') return false;
  if (detail.requestBody != null) return true;
  if (detail.requestBodyError != null && detail.requestBodyError!.isNotEmpty) {
    return true;
  }
  return _networkMethodUsuallyHasBody(detail.method);
}

bool _networkShouldShowResponseBody(_NetworkDetail detail) {
  return detail.resourceType != 'WebSocket';
}

bool _networkShouldShowWebSocketMessages(_NetworkDetail detail) {
  return detail.resourceType == 'WebSocket';
}

bool _networkMethodUsuallyHasBody(String method) {
  switch (method.trim().toUpperCase()) {
    case 'POST':
    case 'PUT':
    case 'PATCH':
    case 'DELETE':
      return true;
    default:
      return false;
  }
}

String _networkRequestMimeType(_NetworkDetail detail) {
  return _networkHeaderValue(detail.requestHeaders, 'content-type') ?? '';
}

String? _networkHeaderValue(Map<String, String> headers, String name) {
  final target = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == target) {
      return entry.value;
    }
  }
  return null;
}

String _networkHeadersText(Map<String, String> headers) {
  return headers.entries
      .map((entry) => '${entry.key}: ${entry.value}')
      .join('\n');
}

List<_NetworkWebSocketMessage> _webSocketMessageList(Object? value) {
  if (value is! List) return const <_NetworkWebSocketMessage>[];
  return value
      .whereType<Map>()
      .map(_NetworkWebSocketMessage.fromJson)
      .toList(growable: false);
}

List<_StorageCookie> _storageCookieList(Object? value) {
  if (value is! List) return const <_StorageCookie>[];
  return value
      .whereType<Map>()
      .map(_StorageCookie.fromJson)
      .toList(growable: false);
}

List<int> _inspectorPathList(Object? value) {
  if (value is! List) return const <int>[];
  return value
      .map(_intOrNull)
      .whereType<int>()
      .where((item) => item >= 0)
      .toList(growable: false);
}

_InspectorNode? _inspectorNodeOrNull(Object? value) {
  if (value is! Map) return null;
  return _InspectorNode.fromJson(value);
}

_InspectorSelectedNode? _inspectorSelectedNodeOrNull(Object? value) {
  if (value is! Map) return null;
  return _InspectorSelectedNode.fromJson(value);
}

_InspectorBox? _inspectorBoxOrNull(Object? value) {
  if (value is! Map) return null;
  return _InspectorBox.fromJson(value);
}

List<_InspectorNode> _inspectorNodeList(Object? value) {
  if (value is! List) return const <_InspectorNode>[];
  return value
      .whereType<Map>()
      .map(_InspectorNode.fromJson)
      .toList(growable: false);
}

List<_InspectorNameValue> _inspectorNameValueList(Object? value) {
  if (value is! List) return const <_InspectorNameValue>[];
  return value
      .whereType<Map>()
      .map(_InspectorNameValue.fromJson)
      .toList(growable: false);
}

List<_IndexedDbDatabase> _indexedDbDatabaseList(Object? value) {
  if (value is! List) return const <_IndexedDbDatabase>[];
  return value
      .whereType<Map>()
      .map(_IndexedDbDatabase.fromJson)
      .toList(growable: false);
}

List<_IndexedDbObjectStore> _indexedDbObjectStoreList(Object? value) {
  if (value is! List) return const <_IndexedDbObjectStore>[];
  return value
      .whereType<Map>()
      .map(_IndexedDbObjectStore.fromJson)
      .toList(growable: false);
}

List<_IndexedDbIndex> _indexedDbIndexList(Object? value) {
  if (value is! List) return const <_IndexedDbIndex>[];
  return value
      .whereType<Map>()
      .map(_IndexedDbIndex.fromJson)
      .toList(growable: false);
}

List<_StorageEntry> _storageEntryList(Object? value) {
  if (value is! List) return const <_StorageEntry>[];
  return value
      .whereType<Map>()
      .map(_StorageEntry.fromJson)
      .toList(growable: false);
}

List<_StorageUsage> _storageUsageList(Object? value) {
  if (value is! List) return const <_StorageUsage>[];
  return value
      .whereType<Map>()
      .map(_StorageUsage.fromJson)
      .toList(growable: false);
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.map((item) => item?.toString() ?? '').toList(growable: false);
}

String _webSocketMessagePayloadText(_NetworkWebSocketMessage message) {
  if (message.error != null && message.error!.isNotEmpty) {
    return message.error!;
  }
  if (message.payload == null || message.payload!.isEmpty) {
    return 'No payload captured.';
  }
  if (message.base64Encoded) {
    return 'Binary frame (${message.payload!.length} encoded chars)';
  }
  return message.payload!;
}

String _formatConsoleTimestamp(int timestamp) {
  final time = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final hh = time.hour.toString().padLeft(2, '0');
  final mm = time.minute.toString().padLeft(2, '0');
  final ss = time.second.toString().padLeft(2, '0');
  return '$hh:$mm:$ss';
}

String _storageQuotaLabel(_StorageSnapshot snapshot) {
  if (snapshot.usage == null || snapshot.quota == null || snapshot.quota == 0) {
    return 'Unavailable';
  }
  final percent = ((snapshot.usage! / snapshot.quota!) * 100).clamp(0, 100);
  return '${_formatNetworkBytes(snapshot.usage!)} / ${_formatNetworkBytes(snapshot.quota!)} (${percent.toStringAsFixed(percent >= 10 ? 0 : 1)}%)';
}

String _storageAreaLabel(String area) {
  switch (area) {
    case 'localStorage':
      return 'localStorage';
    case 'sessionStorage':
      return 'sessionStorage';
    default:
      return 'storage';
  }
}

String _storageUsageTypeLabel(String type) {
  switch (type) {
    case 'local_storage':
      return 'localStorage';
    case 'cache_storage':
      return 'Cache Storage';
    case 'service_workers':
      return 'Service Workers';
    default:
      return type.replaceAll('_', ' ');
  }
}

String _storageCookieExpiryLabel(int? expiresSeconds) {
  if (expiresSeconds == null) return 'Session';
  final time = DateTime.fromMillisecondsSinceEpoch(
    expiresSeconds * 1000,
    isUtc: true,
  );
  return 'Exp ${time.toIso8601String()}';
}

String _networkCurlCommand(_NetworkEntry entry, _NetworkDetail detail) {
  final buffer = StringBuffer('curl');
  if (entry.method.toUpperCase() != 'GET') {
    buffer.write(' -X ${_shellQuote(entry.method)}');
  }
  for (final header in detail.requestHeaders.entries) {
    buffer.write(' -H ${_shellQuote('${header.key}: ${header.value}')}');
  }
  if (detail.requestBody != null && detail.requestBody!.isNotEmpty) {
    buffer.write(' --data-raw ${_shellQuote(detail.requestBody!)}');
  }
  buffer.write(' ${_shellQuote(entry.url)}');
  return buffer.toString();
}

String _shellQuote(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

Future<void> _copyNetworkDetailAction(
  BuildContext context,
  _NetworkCopyAction action,
  _NetworkEntry entry,
  _NetworkDetail? detail,
) async {
  final text = switch (action) {
    _NetworkCopyAction.url => entry.url,
    _NetworkCopyAction.requestHeaders =>
      _networkHeadersText(detail?.requestHeaders ?? const <String, String>{}),
    _NetworkCopyAction.responseHeaders =>
      _networkHeadersText(detail?.responseHeaders ?? const <String, String>{}),
    _NetworkCopyAction.requestBody => detail?.requestBody ?? '',
    _NetworkCopyAction.responseBody => detail?.body ?? '',
    _NetworkCopyAction.curl when detail != null => _networkCurlCommand(entry, detail),
    _ => '',
  };
  if (text.isEmpty) {
    showAppSnackBar(context, 'Nothing to copy yet.');
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  final label = switch (action) {
    _NetworkCopyAction.url => 'URL',
    _NetworkCopyAction.requestHeaders => 'Request headers',
    _NetworkCopyAction.responseHeaders => 'Response headers',
    _NetworkCopyAction.requestBody => 'Request body',
    _NetworkCopyAction.responseBody => 'Response body',
    _NetworkCopyAction.curl => 'cURL command',
  };
  showAppSnackBar(context, '$label copied.');
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

double _doubleValue(Object? value, double fallback) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return fallback;
}

String _inspectorPathLabel(List<int> path) {
  if (path.isEmpty) return 'root';
  return path.map((item) => item.toString()).join(' > ');
}

String _inspectorPathKey(List<int> path) {
  if (path.isEmpty) return 'root';
  return path.join('-');
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
