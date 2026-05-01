import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'fs_models.dart';
import 'host_reconnect_scheduler.dart';
import 'models.dart';

/// Reference-counted per-host WebSocket to `/api/fs/live`. Consumers call
/// [subscribe] to get a handle, use it to [watch]/[unwatch] paths and listen
/// to a broadcast stream, and call [release] in `dispose()`.
class WorkspaceLiveStore {
  WorkspaceLiveStore._();
  static final WorkspaceLiveStore instance = WorkspaceLiveStore._();

  final Map<String, _LiveSession> _sessions = {};

  WorkspaceLiveHandle subscribe(
    HostProfile host,
    ApiClient api, {
    String? agentProvider,
    String? sessionId,
  }) {
    final key = _sessionKey(host.id, sessionId: sessionId);
    var session = _sessions[key];
    if (session == null) {
      session = _LiveSession(
        key: key,
        host: host,
        api: api,
        sessionId: sessionId,
      );
      _sessions[key] = session;
      session._connect();
    }
    session._refs++;
    return WorkspaceLiveHandle._(session);
  }

  void release(WorkspaceLiveHandle handle) {
    final session = handle._session;
    session._refs--;
    if (session._refs <= 0) {
      _sessions.remove(session.key);
      session._dispose();
    }
  }

  String _sessionKey(String hostId, {String? sessionId}) =>
      [hostId, sessionId ?? ''].join('|');
}

class WorkspaceLiveHandle {
  WorkspaceLiveHandle._(this._session);
  final _LiveSession _session;

  Stream<FsChangeEvent> get stream => _session.stream;

  Future<void> watch(String path) => _session.watch(path);

  Future<void> unwatch(String path) => _session.unwatch(path);
}

class _LiveSession {
  _LiveSession({
    required this.key,
    required this.host,
    required this.api,
    this.sessionId,
  }) : _reconnectSlotId = 'workspace-fs-live:$key' {
    HostReconnectScheduler.instance.registerSlot(
      host.id,
      _reconnectSlotId,
      ReconnectPriority.backgroundSocket,
      _connect,
    );
  }

  final String key;
  final HostProfile host;
  final ApiClient api;
  final String? sessionId;
  final String _reconnectSlotId;

  int _refs = 0;
  WebSocketChannel? _channel;
  final _controller = StreamController<FsChangeEvent>.broadcast();
  final Map<String, Completer<String>> _pendingSubs = {};
  final Map<String, String> _pathToWatchId = {};
  int _nextId = 1;
  bool _disposed = false;

  Stream<FsChangeEvent> get stream => _controller.stream;

  void _connect() {
    if (_disposed || !host.enabled) return;
    try {
      _channel = api.openFsLive(host, sessionId: sessionId);
    } catch (_) {
      if (!host.enabled) return;
      _scheduleReconnect();
      return;
    }
    _channel!.stream.listen(
      _handleMessage,
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
    );
    HostReconnectScheduler.instance.markConnected(host.id, _reconnectSlotId);
    // Re-subscribe previously tracked paths after reconnect.
    final previous = List<String>.from(_pathToWatchId.keys);
    _pathToWatchId.clear();
    for (final path in previous) {
      watch(path).catchError((_) {});
    }
  }

  void _scheduleReconnect() {
    if (_disposed || !host.enabled) return;
    _channel = null;
    HostReconnectScheduler.instance.markDisconnected(host.id, _reconnectSlotId);
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = _decode(raw);
      final type = decoded['type'];
      if (type == 'subscribed') {
        final id = decoded['id']?.toString();
        final watchId = decoded['watchId']?.toString();
        if (id != null && watchId != null) {
          _pendingSubs.remove(id)?.complete(watchId);
        }
      } else if (type == 'error') {
        final id = decoded['id']?.toString();
        if (id != null) {
          _pendingSubs
              .remove(id)
              ?.completeError(
                StateError(decoded['message']?.toString() ?? 'subscribe error'),
              );
        }
      } else if (type == 'fs_changed') {
        final changed =
            (decoded['changedPaths'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        _controller.add(
          FsChangeEvent(
            watchId: decoded['watchId']?.toString() ?? '',
            path: decoded['path']?.toString() ?? '',
            changedPaths: changed,
          ),
        );
      }
    } catch (_) {
      // Ignore malformed frames.
    }
  }

  Future<void> watch(String path) async {
    if (_pathToWatchId.containsKey(path)) return;
    final channel = _channel;
    if (channel == null) return;
    final id = 'sub-${_nextId++}';
    final completer = Completer<String>();
    _pendingSubs[id] = completer;
    channel.sink.add(jsonEncode({'type': 'subscribe', 'id': id, 'path': path}));
    try {
      final watchId = await completer.future.timeout(
        const Duration(seconds: 10),
      );
      _pathToWatchId[path] = watchId;
    } catch (_) {
      _pendingSubs.remove(id);
      rethrow;
    }
  }

  Future<void> unwatch(String path) async {
    final watchId = _pathToWatchId.remove(path);
    final channel = _channel;
    if (watchId == null || channel == null) return;
    channel.sink.add(jsonEncode({'type': 'unsubscribe', 'watchId': watchId}));
  }

  Map<String, dynamic> _decode(String raw) =>
      (jsonDecode(raw) as Map).cast<String, dynamic>();

  void _dispose() {
    _disposed = true;
    HostReconnectScheduler.instance.unregisterSlot(host.id, _reconnectSlotId);
    _channel?.sink.close();
    _controller.close();
  }
}
