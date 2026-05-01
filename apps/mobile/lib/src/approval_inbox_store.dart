import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'approval_action_seen_store.dart';
import 'host_status_store.dart';
import 'host_reconnect_scheduler.dart';
import 'live_activity_service.dart';
import 'local_notification_service.dart';
import 'models.dart';

/// Lightweight DTO used to group a [PendingAction] with the host it came
/// from, so consumers don't have to keep the mapping themselves.
@immutable
class PendingActionEntry {
  const PendingActionEntry({required this.host, required this.action});

  final HostProfile host;
  final PendingAction action;
}

/// Process-wide store that tracks pending approvals for every known host.
///
/// Foreground updates come from one lightweight WebSocket per host. Polling is
/// still kept as a slower reconciliation path for reconnects, old servers, and
/// mobile suspension.
class ApprovalInboxStore extends ChangeNotifier {
  ApprovalInboxStore._();
  static final ApprovalInboxStore instance = ApprovalInboxStore._();

  static const Duration _pollInterval = Duration(seconds: 90);

  ApiClient? _api;
  List<HostProfile> _hosts = const [];
  List<PendingActionEntry> _entries = const [];
  final Map<String, PendingActionEntry> _entriesByKey = {};
  final Map<String, _ApprovalHostLiveConnection> _liveConnections = {};
  final Set<String> _liveSnapshotHostIds = <String>{};
  Set<String> _seenActionKeys = <String>{};
  final Set<String> _notifiedActionKeys = <String>{};
  Set<String> _pendingHostIds = <String>{};
  List<String> _failedHostLabels = const [];
  bool? _seenStoreInitializedBaseline;
  bool _hasLoadedOnce = false;
  int _loadGen = 0;
  Timer? _pollTimer;

  List<PendingActionEntry> get entries => _entries;
  int get count => _entries.length;
  bool get isLoading => _pendingHostIds.isNotEmpty;
  bool get hasLoadedOnce => _hasLoadedOnce;
  int get pendingHostsRemaining => _pendingHostIds.length;
  int get totalHosts => _hosts.length;
  List<String> get failedHostLabels => _failedHostLabels;

  /// Update the host list / api client. Safe to call repeatedly; starts or
  /// stops per-host live sockets as needed and keeps the reconcile timer armed.
  void configure({required List<HostProfile> hosts, required ApiClient api}) {
    _api = api;
    final newSignatures = hosts.map(_hostSignature).toSet();
    final oldSignatures = _hosts.map(_hostSignature).toSet();
    final hostsChanged =
        newSignatures.length != oldSignatures.length ||
        !newSignatures.containsAll(oldSignatures);
    _hosts = List.unmodifiable(hosts);
    _syncLiveConnections(hosts: _hosts, api: api);
    if (_hosts.isEmpty) {
      _stopTimer();
    } else {
      _ensureTimer();
    }
    if (hostsChanged || !_hasLoadedOnce) {
      unawaited(refresh());
    }
  }

  void _ensureTimer() {
    _pollTimer ??= Timer.periodic(_pollInterval, (_) {
      unawaited(refresh());
    });
  }

  void _stopTimer() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    final hosts = _hosts;
    final gen = ++_loadGen;

    if (hosts.isEmpty) {
      _entries = const [];
      _entriesByKey.clear();
      _liveSnapshotHostIds.clear();
      _seenActionKeys = <String>{};
      _notifiedActionKeys.clear();
      _pendingHostIds = <String>{};
      _failedHostLabels = const [];
      _hasLoadedOnce = true;
      await ApprovalActionSeenStore.instance.replace(<String>{});
      unawaited(LiveActivityService.instance.endPendingApprovals());
      notifyListeners();
      return;
    }

    _pendingHostIds = hosts.map((h) => h.id).toSet();
    _failedHostLabels = const [];
    notifyListeners();
    for (final host in hosts) {
      HostStatusStore.instance.markProbing(host.id);
    }

    final collected = <PendingActionEntry>[];
    final failures = <String>[];
    final successfulHostIds = <String>{};
    await Future.wait(
      hosts.map((host) async {
        try {
          final actions = await api.fetchPendingActions(host);
          if (gen != _loadGen) return;
          HostStatusStore.instance.markOnline(host.id);
          successfulHostIds.add(host.id);
          collected.addAll(
            actions.map((a) => PendingActionEntry(host: host, action: a)),
          );
        } catch (error) {
          if (gen != _loadGen) return;
          HostStatusStore.instance.markOffline(
            host.id,
            error: error.toString(),
          );
          failures.add(host.label);
        } finally {
          if (gen == _loadGen) {
            _pendingHostIds = {..._pendingHostIds}..remove(host.id);
            notifyListeners();
          }
        }
      }),
    );
    if (gen != _loadGen) return;
    _replaceSuccessfulHostEntries(successfulHostIds, collected);
    await _notifyForNewActions(collected);
    await _persistCurrentActionKeys();
    _failedHostLabels = List.unmodifiable(failures);
    _hasLoadedOnce = true;
    _publishEntries();
  }

  /// Optimistically drop an entry from the local view (e.g. after the user
  /// approves/declines). The next poll will reconcile with the server.
  void removeEntry(String actionId) {
    final keys = _entriesByKey.entries
        .where((entry) => entry.value.action.id == actionId)
        .map((entry) => entry.key)
        .toList(growable: false);
    if (keys.isEmpty) return;
    for (final key in keys) {
      _entriesByKey.remove(key);
    }
    unawaited(_persistCurrentActionKeys());
    _publishEntries();
  }

  void _syncLiveConnections({
    required List<HostProfile> hosts,
    required ApiClient api,
  }) {
    final activeIds = hosts.map((host) => host.id).toSet();
    for (final id in _liveConnections.keys.toList(growable: false)) {
      if (activeIds.contains(id)) continue;
      _liveConnections.remove(id)?.dispose();
      _liveSnapshotHostIds.remove(id);
      _removeEntriesForHost(id);
    }

    for (final host in hosts) {
      final existing = _liveConnections[host.id];
      if (existing != null && existing.matches(host)) {
        continue;
      }
      existing?.dispose();
      _liveSnapshotHostIds.remove(host.id);
      final connection = _ApprovalHostLiveConnection(
        host: host,
        api: api,
        onOnline: _handleLiveOnline,
        onOffline: _handleLiveOffline,
        onSnapshot: _handleLiveSnapshot,
        onActionOpened: _handleLiveActionOpened,
        onActionResolved: _handleLiveActionResolved,
      );
      _liveConnections[host.id] = connection;
      connection.connect();
    }
  }

  void _handleLiveOnline(HostProfile host) {
    HostStatusStore.instance.markOnline(host.id);
  }

  void _handleLiveOffline(HostProfile host, Object? error) {
    // Polling owns host reachability. Live approval sockets are an optional
    // fast path, so old servers or transient socket drops should not make an
    // otherwise healthy host look offline.
  }

  void _handleLiveSnapshot(HostProfile host, List<PendingAction> actions) {
    final isInitialHostSnapshot = _liveSnapshotHostIds.add(host.id);
    unawaited(
      _applyHostSnapshot(
        host,
        actions,
        allowCurrentSessionNotification: !isInitialHostSnapshot,
      ),
    );
  }

  void _handleLiveActionOpened(HostProfile host, PendingAction action) {
    unawaited(_upsertLiveAction(host, action));
  }

  void _handleLiveActionResolved(HostProfile host, String actionId) {
    final removed = _entriesByKey.remove(_actionKeyFor(host.id, actionId));
    if (removed == null) return;
    unawaited(_persistCurrentActionKeys());
    _publishEntries();
  }

  Future<void> _applyHostSnapshot(
    HostProfile host,
    List<PendingAction> actions, {
    required bool allowCurrentSessionNotification,
  }) async {
    final entries = actions
        .map((action) => PendingActionEntry(host: host, action: action))
        .toList(growable: false);
    _replaceSuccessfulHostEntries({host.id}, entries);
    await _notifyForNewActions(
      entries,
      allowCurrentSessionNotification: allowCurrentSessionNotification,
    );
    await _persistCurrentActionKeys();
    _failedHostLabels = _failedHostLabels
        .where((label) => label != host.label)
        .toList(growable: false);
    _hasLoadedOnce = true;
    _publishEntries();
  }

  Future<void> _upsertLiveAction(HostProfile host, PendingAction action) async {
    final entry = PendingActionEntry(host: host, action: action);
    final key = _actionKey(entry);
    final existed = _entriesByKey.containsKey(key);
    _entriesByKey[key] = entry;
    if (!existed) {
      await _notifyForNewActions([entry]);
    }
    await _persistCurrentActionKeys();
    _hasLoadedOnce = true;
    _publishEntries();
  }

  void _replaceSuccessfulHostEntries(
    Set<String> successfulHostIds,
    List<PendingActionEntry> entries,
  ) {
    for (final hostId in successfulHostIds) {
      _removeEntriesForHost(hostId);
    }
    for (final entry in entries) {
      _entriesByKey[_actionKey(entry)] = entry;
    }
  }

  void _removeEntriesForHost(String hostId) {
    final prefix = '$hostId:';
    for (final key in _entriesByKey.keys.toList(growable: false)) {
      if (key.startsWith(prefix)) {
        _entriesByKey.remove(key);
      }
    }
  }

  void _publishEntries() {
    final sorted = _entriesByKey.values.toList(growable: false)
      ..sort((a, b) => b.action.requestedAt.compareTo(a.action.requestedAt));
    _entries = List.unmodifiable(sorted);
    _syncLiveActivity(_entries);
    notifyListeners();
  }

  void _syncLiveActivity(List<PendingActionEntry> entries) {
    if (entries.isEmpty) {
      unawaited(LiveActivityService.instance.endPendingApprovals());
      return;
    }
    final newest = entries.first;
    unawaited(
      LiveActivityService.instance.syncPendingApprovals(
        count: entries.length,
        hostLabel: newest.host.label,
        title: newest.action.title,
        sessionTitle: newest.action.sessionTitle ?? '',
      ),
    );
  }

  Future<void> _notifyForNewActions(
    List<PendingActionEntry> entries, {
    bool allowCurrentSessionNotification = true,
  }) async {
    if (entries.isEmpty) return;
    final seenSnapshot = await ApprovalActionSeenStore.instance.load();
    _seenStoreInitializedBaseline ??= seenSnapshot.initialized;
    final shouldNotify =
        (allowCurrentSessionNotification && _hasLoadedOnce) ||
        _seenStoreInitializedBaseline!;
    if (!shouldNotify) return;
    final seenKeys = <String>{
      ...seenSnapshot.keys,
      ..._seenActionKeys,
      ..._notifiedActionKeys,
    };
    for (final entry in entries) {
      final key = _actionKey(entry);
      if (seenKeys.contains(key)) continue;
      seenKeys.add(key);
      _notifiedActionKeys.add(key);
      unawaited(
        LocalNotificationService.instance.showPendingApproval(
          host: entry.host,
          action: entry.action,
        ),
      );
    }
  }

  Future<void> _persistCurrentActionKeys() async {
    _seenActionKeys = _entriesByKey.keys.toSet();
    await ApprovalActionSeenStore.instance.replace(_seenActionKeys);
  }

  String _actionKey(PendingActionEntry entry) {
    return _actionKeyFor(entry.host.id, entry.action.id);
  }

  String _actionKeyFor(String hostId, String actionId) {
    return '$hostId:$actionId';
  }

  String _hostSignature(HostProfile host) {
    return '${host.id}|${host.label}|${host.baseUrl}|${host.token}';
  }
}

class _ApprovalHostLiveConnection {
  _ApprovalHostLiveConnection({
    required this.host,
    required this.api,
    required this.onOnline,
    required this.onOffline,
    required this.onSnapshot,
    required this.onActionOpened,
    required this.onActionResolved,
  });

  final HostProfile host;
  final ApiClient api;
  final void Function(HostProfile host) onOnline;
  final void Function(HostProfile host, Object? error) onOffline;
  final void Function(HostProfile host, List<PendingAction> actions) onSnapshot;
  final void Function(HostProfile host, PendingAction action) onActionOpened;
  final void Function(HostProfile host, String actionId) onActionResolved;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;

  bool matches(HostProfile next) =>
      host.id == next.id &&
      host.baseUrl == next.baseUrl &&
      host.token == next.token;

  void connect() {
    if (_disposed || !host.enabled) return;
    try {
      _channel = api.openActionsLive(host);
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: (Object error) => _scheduleReconnect(error),
        onDone: () => _scheduleReconnect(null),
      );
      HostReconnectScheduler.instance.markConnected(host.id);
    } catch (error) {
      if (!host.enabled) return;
      _scheduleReconnect(error);
    }
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final decoded = (jsonDecode(raw) as Map).cast<String, dynamic>();
      switch (decoded['type']?.toString()) {
        case 'hello':
          onOnline(host);
        case 'snapshot':
          onOnline(host);
          final actions = (decoded['actions'] as List<dynamic>? ?? const [])
              .whereType<Map<dynamic, dynamic>>()
              .map(
                (item) => PendingAction.fromJson(item.cast<String, dynamic>()),
              )
              .toList(growable: false);
          onSnapshot(host, actions);
        case 'action_opened':
          onOnline(host);
          final action = decoded['action'];
          if (action is Map<dynamic, dynamic>) {
            onActionOpened(
              host,
              PendingAction.fromJson(action.cast<String, dynamic>()),
            );
          }
        case 'action_resolved':
          onOnline(host);
          final actionId = decoded['actionId']?.toString();
          if (actionId != null && actionId.isNotEmpty) {
            onActionResolved(host, actionId);
          }
        case 'error':
          onOffline(host, decoded['message']?.toString());
      }
    } catch (error) {
      debugPrint('Ignored malformed approval live event: $error');
    }
  }

  void _scheduleReconnect(Object? error) {
    if (_disposed || !host.enabled) return;
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    onOffline(host, error);
    HostReconnectScheduler.instance.markDisconnected(host.id);
  }


  void dispose() {
    _disposed = true;
    HostReconnectScheduler.instance.unregisterSlot(host.id, 'approval-inbox-live');
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    final sink = _channel?.sink;
    if (sink != null) {
      unawaited(sink.close());
    }
  }
}
