import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'host_status_store.dart';
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

/// Process-wide store that polls every known host for pending approvals
/// regardless of which tab the user is currently viewing. This lets the
/// inbox badge, sidebar pill, and Inbox pane stay in sync without each
/// surface having to own its own poller.
///
/// Consumers attach via [configure] with the current host list + API
/// client; the store kicks off an immediate load and keeps polling on a
/// short interval (15s by default). Reachability is mirrored into
/// [HostStatusStore] so the existing online/offline dots keep working.
class ApprovalInboxStore extends ChangeNotifier {
  ApprovalInboxStore._();
  static final ApprovalInboxStore instance = ApprovalInboxStore._();

  static const Duration _pollInterval = Duration(seconds: 15);

  ApiClient? _api;
  List<HostProfile> _hosts = const [];
  List<PendingActionEntry> _entries = const [];
  Set<String> _seenActionKeys = <String>{};
  Set<String> _pendingHostIds = <String>{};
  List<String> _failedHostLabels = const [];
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

  /// Update the host list / api client. Safe to call repeatedly; only kicks
  /// off a new load when the host set actually changes or we haven't loaded
  /// yet. Always (re-)arms the poll timer.
  void configure({required List<HostProfile> hosts, required ApiClient api}) {
    _api = api;
    final newIds = hosts.map((h) => h.id).toSet();
    final oldIds = _hosts.map((h) => h.id).toSet();
    final hostsChanged =
        newIds.length != oldIds.length || !newIds.containsAll(oldIds);
    _hosts = List.unmodifiable(hosts);
    _ensureTimer();
    if (hostsChanged || !_hasLoadedOnce) {
      unawaited(refresh());
    }
  }

  void _ensureTimer() {
    _pollTimer ??= Timer.periodic(_pollInterval, (_) {
      unawaited(refresh());
    });
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    final hosts = _hosts;
    final gen = ++_loadGen;

    if (hosts.isEmpty) {
      _entries = const [];
      _seenActionKeys = <String>{};
      _pendingHostIds = <String>{};
      _failedHostLabels = const [];
      _hasLoadedOnce = true;
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
    await Future.wait(
      hosts.map((host) async {
        try {
          final actions = await api.fetchPendingActions(host);
          if (gen != _loadGen) return;
          HostStatusStore.instance.markOnline(host.id);
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
    collected.sort(
      (a, b) => b.action.requestedAt.compareTo(a.action.requestedAt),
    );
    _syncLiveActivity(collected);
    _notifyForNewActions(collected);
    _entries = List.unmodifiable(collected);
    _seenActionKeys = collected.map(_actionKey).toSet();
    _failedHostLabels = List.unmodifiable(failures);
    _hasLoadedOnce = true;
    notifyListeners();
  }

  /// Optimistically drop an entry from the local view (e.g. after the user
  /// approves/declines). The next poll will reconcile with the server.
  void removeEntry(String actionId) {
    final next = _entries
        .where((e) => e.action.id != actionId)
        .toList(growable: false);
    if (next.length == _entries.length) return;
    _entries = List.unmodifiable(next);
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

  void _notifyForNewActions(List<PendingActionEntry> entries) {
    if (!_hasLoadedOnce) return;
    for (final entry in entries) {
      if (_seenActionKeys.contains(_actionKey(entry))) continue;
      unawaited(
        LocalNotificationService.instance.showPendingApproval(
          host: entry.host,
          action: entry.action,
        ),
      );
    }
  }

  String _actionKey(PendingActionEntry entry) {
    return '${entry.host.id}:${entry.action.id}';
  }
}
