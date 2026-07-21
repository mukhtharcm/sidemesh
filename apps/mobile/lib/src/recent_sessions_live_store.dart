import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'host_status_store.dart';
import 'host_reconnect_scheduler.dart';
import 'models.dart';
import 'session_local_store.dart';

@immutable
class RemoteSessionEntry {
  const RemoteSessionEntry({required this.host, required this.session});

  final HostProfile host;
  final SessionSummary session;
}

@immutable
class _PendingRecentMutation {
  const _PendingRecentMutation.upsert(this.session)
    : sessionId = null,
      isRemoval = false;

  const _PendingRecentMutation.remove(this.sessionId)
    : session = null,
      isRemoval = true;

  final SessionSummary? session;
  final String? sessionId;
  final bool isRemoval;
}

/// Cache-first recent sessions store with one lightweight live socket per host.
///
/// HTTP remains the reconciliation path for reconnects and compatibility with
/// older servers, while the websocket path keeps the list fresh between polls.
class RecentSessionsStore extends ChangeNotifier {
  static const int _maxSessionsPerHost = 40;

  RecentSessionsStore({
    Duration pollInterval = const Duration(seconds: 90),
    Duration initialHttpFallbackDelay = const Duration(milliseconds: 1600),
  }) : this._(pollInterval, initialHttpFallbackDelay);

  RecentSessionsStore._(this._pollInterval, this._initialHttpFallbackDelay);

  final Duration _pollInterval;
  final Duration _initialHttpFallbackDelay;

  ApiClient? _api;
  List<HostProfile> _hosts = const [];
  List<RemoteSessionEntry> _entries = const [];
  final Map<String, HostProfile> _hostsById = {};
  final Map<String, Map<String, SessionSummary>> _sessionsByHostId = {};
  final Map<String, int> _hostFreshnessById = {};
  final Map<String, _RecentHostLiveConnection> _liveConnections = {};
  final Set<String> _confirmedHostIds = <String>{};
  final Set<String> _liveHostIds = <String>{};
  Set<String> _pendingHostIds = <String>{};
  List<String> _failedHostLabels = const [];
  bool _hasLoadedOnce = false;
  bool _disposed = false;
  int _loadGen = 0;
  Timer? _pollTimer;
  Timer? _initialHttpFallbackTimer;

  List<RemoteSessionEntry> get entries => _entries;
  Set<String> get pendingHostIds => Set.unmodifiable(_pendingHostIds);
  Set<String> get confirmedHostIds => Set.unmodifiable(_confirmedHostIds);
  List<String> get failedHostLabels => _failedHostLabels;
  bool get hasLoadedOnce => _hasLoadedOnce;
  bool get isLoading => _pendingHostIds.isNotEmpty;

  void configure({required List<HostProfile> hosts, required ApiClient api}) {
    if (_disposed) return;
    _api = api;
    final enabledHosts = hosts
        .where((host) => host.enabled)
        .toList(growable: false);
    final newSignatures = enabledHosts.map(_hostSignature).toSet();
    final oldSignatures = _hosts.map(_hostSignature).toSet();
    final hostsChanged =
        newSignatures.length != oldSignatures.length ||
        !newSignatures.containsAll(oldSignatures);

    _hosts = List.unmodifiable(enabledHosts);
    _hostsById
      ..clear()
      ..addEntries(_hosts.map((host) => MapEntry(host.id, host)));
    _removeEntriesForMissingHosts();
    _syncLiveConnections(hosts: _hosts, api: api);
    _syncPollTimer();

    if (_hosts.isEmpty) {
      _entries = const [];
      _sessionsByHostId.clear();
      _hostFreshnessById.clear();
      _confirmedHostIds.clear();
      _liveHostIds.clear();
      _pendingHostIds = <String>{};
      _failedHostLabels = const [];
      _hasLoadedOnce = true;
      notifyListeners();
      return;
    }

    if (hostsChanged || !_hasLoadedOnce) {
      unawaited(_hydrateCachedHosts(_hosts));
      _scheduleInitialHttpFallback();
    }
  }

  Future<void> refresh({bool showLoading = true}) async {
    _initialHttpFallbackTimer?.cancel();
    _initialHttpFallbackTimer = null;
    final api = _api;
    if (_disposed || api == null) return;
    final hosts = _hosts;
    final gen = ++_loadGen;

    if (hosts.isEmpty) {
      _entries = const [];
      _sessionsByHostId.clear();
      _hostFreshnessById.clear();
      _confirmedHostIds.clear();
      _liveHostIds.clear();
      _pendingHostIds = <String>{};
      _failedHostLabels = const [];
      _hasLoadedOnce = true;
      notifyListeners();
      return;
    }

    final failures = showLoading ? <String>[] : _failedHostLabels.toList();
    if (showLoading) {
      _pendingHostIds = hosts.map((host) => host.id).toSet();
      _failedHostLabels = const [];
      for (final host in hosts) {
        HostStatusStore.instance.markProbing(host.id);
      }
      notifyListeners();
    }

    await Future.wait(
      hosts.map((host) async {
        try {
          final sessions = await api.fetchSessions(host, limit: 40);
          if (_disposed || gen != _loadGen) return;
          HostStatusStore.instance.markOnline(host.id);
          _markHostFresh(host.id);
          _confirmedHostIds.add(host.id);
          _replaceHostSessions(host, sessions);
          _failedHostLabels = _failedHostLabels
              .where((label) => label != host.label)
              .toList(growable: false);
          _hasLoadedOnce = true;
          _publishEntries();
          unawaited(SessionLocalStore.instance.upsertSessions(host, sessions));
        } catch (error) {
          if (_disposed || gen != _loadGen) return;
          HostStatusStore.instance.markOffline(
            host.id,
            error: friendlyError(error),
          );
          _confirmedHostIds.remove(host.id);
          if (showLoading) {
            failures.add(host.label);
          }
        } finally {
          if (!_disposed && gen == _loadGen) {
            if (showLoading) {
              _pendingHostIds = {..._pendingHostIds}..remove(host.id);
              _failedHostLabels = List.unmodifiable(failures);
              notifyListeners();
            } else {
              notifyListeners();
            }
          }
        }
      }),
      eagerError: false,
    );
  }

  void _scheduleInitialHttpFallback() {
    _initialHttpFallbackTimer?.cancel();
    if (_hosts.isEmpty) {
      return;
    }
    _pendingHostIds = _hosts.map((host) => host.id).toSet();
    _failedHostLabels = const [];
    for (final host in _hosts) {
      HostStatusStore.instance.markProbing(host.id);
    }
    notifyListeners();
    _initialHttpFallbackTimer = Timer(_initialHttpFallbackDelay, () {
      _initialHttpFallbackTimer = null;
      if (_disposed || _pendingHostIds.isEmpty) {
        return;
      }
      unawaited(refresh());
    });
  }

  Future<void> _hydrateCachedHosts(List<HostProfile> hosts) async {
    await Future.wait(
      hosts.map((host) async {
        final freshnessAtStart = _hostFreshnessById[host.id] ?? 0;
        try {
          final cached = await SessionLocalStore.instance.getRecentSessions(
            host,
          );
          final current = _hostsById[host.id];
          if (_disposed ||
              cached.isEmpty ||
              current == null ||
              _hostSignature(current) != _hostSignature(host) ||
              (_hostFreshnessById[host.id] ?? 0) != freshnessAtStart ||
              _confirmedHostIds.contains(host.id)) {
            return;
          }
          _replaceHostSessions(host, cached);
          _publishEntries();
          notifyListeners();
        } catch (_) {
          // Cache is an optimization only.
        }
      }),
      eagerError: false,
    );
  }

  void _syncPollTimer() {
    final needsPolling = _hosts.any(
      (host) => host.enabled && !_liveHostIds.contains(host.id),
    );
    if (!needsPolling) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer ??= Timer.periodic(_pollInterval, (_) {
      unawaited(refresh(showLoading: false));
    });
  }

  void _syncLiveConnections({
    required List<HostProfile> hosts,
    required ApiClient api,
  }) {
    final activeIds = hosts
        .where((host) => host.enabled)
        .map((host) => host.id)
        .toSet();
    for (final id in _liveConnections.keys.toList(growable: false)) {
      if (activeIds.contains(id)) continue;
      _liveConnections.remove(id)?.dispose();
      _confirmedHostIds.remove(id);
      _liveHostIds.remove(id);
    }

    for (final host in hosts) {
      if (!host.enabled) {
        continue;
      }
      final existing = _liveConnections[host.id];
      if (existing != null && existing.matches(host)) {
        continue;
      }
      existing?.dispose();
      _confirmedHostIds.remove(host.id);
      _liveHostIds.remove(host.id);
      _liveConnections[host.id] = _RecentHostLiveConnection(
        host: host,
        api: api,
        onOnline: _handleLiveOnline,
        onOffline: _handleLiveOffline,
        onSnapshot: _handleLiveSnapshot,
        onUpsert: _handleLiveUpsert,
        onRemove: _handleLiveRemove,
      )..connect();
    }
  }

  void _handleLiveOnline(HostProfile host) {
    HostStatusStore.instance.markOnline(host.id);
  }

  void _handleLiveOffline(HostProfile host, Object? error) {
    if (_disposed) return;
    _liveHostIds.remove(host.id);
    _syncPollTimer();
    if (_confirmedHostIds.remove(host.id)) {
      notifyListeners();
    }
  }

  void _handleLiveSnapshot(HostProfile host, List<SessionSummary> sessions) {
    if (_disposed || !_hostsById.containsKey(host.id)) return;
    _markHostFreshFromLive(host);
    _hasLoadedOnce = true;
    _replaceHostSessions(host, sessions);
    _publishEntries();
    notifyListeners();
    unawaited(SessionLocalStore.instance.upsertSessions(host, sessions));
  }

  void _handleLiveUpsert(HostProfile host, SessionSummary session) {
    if (_disposed || !_hostsById.containsKey(host.id)) return;
    _markHostFreshFromLive(host);
    final next = Map<String, SessionSummary>.from(
      _sessionsByHostId[host.id] ?? const <String, SessionSummary>{},
    );
    next[session.id] = session;
    _sessionsByHostId[host.id] = _toBoundedSessionMap(next.values);
    _hasLoadedOnce = true;
    _publishEntries();
    notifyListeners();
    _persistHostCache(host);
    unawaited(SessionLocalStore.instance.updateGhost(host, session));
  }

  void _handleLiveRemove(HostProfile host, String sessionId) {
    if (_disposed || !_hostsById.containsKey(host.id)) return;
    _markHostFreshFromLive(host);
    final existing = _sessionsByHostId[host.id];
    if (existing == null || !existing.containsKey(sessionId)) {
      notifyListeners();
      return;
    }
    final next = Map<String, SessionSummary>.from(existing)..remove(sessionId);
    _sessionsByHostId[host.id] = next;
    _hasLoadedOnce = true;
    _publishEntries();
    notifyListeners();
    _persistHostCache(host);
  }

  void _markHostFreshFromLive(HostProfile host) {
    _markHostFresh(host.id);
    _confirmedHostIds.add(host.id);
    _liveHostIds.add(host.id);
    _pendingHostIds = {..._pendingHostIds}..remove(host.id);
    if (_pendingHostIds.isEmpty) {
      _initialHttpFallbackTimer?.cancel();
      _initialHttpFallbackTimer = null;
    }
    _failedHostLabels = _failedHostLabels
        .where((label) => label != host.label)
        .toList(growable: false);
    _syncPollTimer();
  }

  void _replaceHostSessions(HostProfile host, List<SessionSummary> sessions) {
    _sessionsByHostId[host.id] = _toBoundedSessionMap(sessions);
  }

  void _publishEntries() {
    final flattened = <RemoteSessionEntry>[];
    for (final host in _hosts) {
      final sessions = _sessionsByHostId[host.id];
      if (sessions == null) continue;
      for (final session in _sortedSessionWindow(sessions.values)) {
        flattened.add(RemoteSessionEntry(host: host, session: session));
      }
    }
    _entries = List.unmodifiable(flattened);
  }

  void _persistHostCache(HostProfile host) {
    final sessions = _sessionsByHostId[host.id];
    if (sessions == null) {
      unawaited(SessionLocalStore.instance.upsertSessions(host, const []));
      return;
    }
    unawaited(
      SessionLocalStore.instance.upsertSessions(
        host,
        _sortedSessionWindow(sessions.values),
      ),
    );
  }

  void _removeEntriesForMissingHosts() {
    final activeIds = _hostsById.keys.toSet();
    for (final id in _sessionsByHostId.keys.toList(growable: false)) {
      if (activeIds.contains(id)) continue;
      _sessionsByHostId.remove(id);
      _hostFreshnessById.remove(id);
      _confirmedHostIds.remove(id);
      _liveHostIds.remove(id);
    }
    _publishEntries();
  }

  void _markHostFresh(String hostId) {
    _hostFreshnessById[hostId] = (_hostFreshnessById[hostId] ?? 0) + 1;
  }

  String _hostSignature(HostProfile host) =>
      '${host.id}\u001f${host.baseUrl}\u001f${host.token}\u001f${host.enabled ? 1 : 0}';

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _pollTimer?.cancel();
    _initialHttpFallbackTimer?.cancel();
    for (final connection in _liveConnections.values) {
      connection.dispose();
    }
    _liveConnections.clear();
    _liveHostIds.clear();
    super.dispose();
  }

  Map<String, SessionSummary> _toBoundedSessionMap(
    Iterable<SessionSummary> sessions,
  ) {
    return {
      for (final session in _sortedSessionWindow(sessions)) session.id: session,
    };
  }

  List<SessionSummary> _sortedSessionWindow(Iterable<SessionSummary> sessions) {
    final sorted = sessions.toList(growable: false)
      ..sort((left, right) {
        final updatedCompare = right.updatedAt.compareTo(left.updatedAt);
        if (updatedCompare != 0) {
          return updatedCompare;
        }
        return left.id.compareTo(right.id);
      });
    return sorted.take(_maxSessionsPerHost).toList(growable: false);
  }
}

class _RecentHostLiveConnection {
  static const _reconnectSlotId = 'recent-sessions-live';

  _RecentHostLiveConnection({
    required this.host,
    required this.api,
    required this.onOnline,
    required this.onOffline,
    required this.onSnapshot,
    required this.onUpsert,
    required this.onRemove,
  }) {
    HostReconnectScheduler.instance.registerSlot(
      host.id,
      _reconnectSlotId,
      ReconnectPriority.backgroundSocket,
      connect,
    );
  }

  final HostProfile host;
  final ApiClient api;
  final void Function(HostProfile host) onOnline;
  final void Function(HostProfile host, Object? error) onOffline;
  final void Function(HostProfile host, List<SessionSummary> sessions)
  onSnapshot;
  final void Function(HostProfile host, SessionSummary session) onUpsert;
  final void Function(HostProfile host, String sessionId) onRemove;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;
  bool _receivedSnapshot = false;
  final List<_PendingRecentMutation> _pendingMutations =
      <_PendingRecentMutation>[];

  bool matches(HostProfile next) =>
      host.id == next.id &&
      host.baseUrl == next.baseUrl &&
      host.token == next.token;

  void connect() {
    if (_disposed || !host.enabled) return;
    _receivedSnapshot = false;
    _pendingMutations.clear();
    try {
      final channel = api.openSessionsLive(host);
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onError: (Object error) => _scheduleReconnectIfCurrent(channel, error),
        onDone: () => _scheduleReconnectIfCurrent(channel, null),
      );
      unawaited(
        channel.ready
            .then((_) {
              if (_disposed || !identical(_channel, channel)) return;
              HostReconnectScheduler.instance.markConnected(
                host.id,
                _reconnectSlotId,
              );
            })
            .catchError((Object error) {
              if (_disposed || !identical(_channel, channel) || !host.enabled) {
                return null;
              }
              _scheduleReconnect(error);
              return null;
            }),
      );
    } catch (error) {
      if (!host.enabled) return;
      _scheduleReconnect(error);
    }
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final event = RecentSessionsLiveEvent.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );
      if (event.type == 'hello') {
        onOnline(host);
        return;
      }
      if (event.type == 'snapshot') {
        onOnline(host);
        _receivedSnapshot = true;
        onSnapshot(host, event.sessions ?? const <SessionSummary>[]);
        _flushPendingMutations();
        return;
      }
      if (event.type == 'upsert') {
        onOnline(host);
        final session = event.session;
        if (session == null) {
          return;
        }
        if (!_receivedSnapshot) {
          _pendingMutations.add(_PendingRecentMutation.upsert(session));
          return;
        }
        onUpsert(host, session);
        return;
      }
      if (event.type == 'remove') {
        onOnline(host);
        final sessionId = event.sessionId;
        if (sessionId == null || sessionId.isEmpty) {
          return;
        }
        if (!_receivedSnapshot) {
          _pendingMutations.add(_PendingRecentMutation.remove(sessionId));
          return;
        }
        onRemove(host, sessionId);
        return;
      }
      if (event.type == 'error') {
        onOffline(host, event.message);
      }
    } catch (error) {
      debugPrint('Ignored malformed recent sessions live event: $error');
    }
  }

  void _flushPendingMutations() {
    if (_pendingMutations.isEmpty) {
      return;
    }
    final pending = List<_PendingRecentMutation>.from(_pendingMutations);
    _pendingMutations.clear();
    for (final mutation in pending) {
      if (mutation.isRemoval) {
        final sessionId = mutation.sessionId;
        if (sessionId != null && sessionId.isNotEmpty) {
          onRemove(host, sessionId);
        }
        continue;
      }
      final session = mutation.session;
      if (session != null) {
        onUpsert(host, session);
      }
    }
  }

  void _scheduleReconnect(Object? error) {
    if (_disposed || !host.enabled) return;
    final channel = _channel;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    _subscription = null;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close());
    }
    onOffline(host, error);
    HostReconnectScheduler.instance.markDisconnected(host.id, _reconnectSlotId);
  }

  void _scheduleReconnectIfCurrent(WebSocketChannel channel, Object? error) {
    if (!identical(_channel, channel)) {
      return;
    }
    _scheduleReconnect(error);
  }

  void dispose() {
    _disposed = true;
    HostReconnectScheduler.instance.unregisterSlot(host.id, _reconnectSlotId);
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    final sink = _channel?.sink;
    if (sink != null) {
      unawaited(sink.close());
    }
  }
}
