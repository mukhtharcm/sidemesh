import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'models.dart';
import 'usage_models.dart';

class UsageHostFailure {
  const UsageHostFailure({required this.host, required this.message});

  final HostProfile host;
  final String message;
}

class UsageStore extends ChangeNotifier {
  UsageStore({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;
  List<HostProfile> _hosts = const [];
  List<HostUsageSnapshot> _snapshots = const [];
  List<UsageHostFailure> _failures = const [];
  bool _loading = false;
  DateTime? _lastRefreshedAt;
  Future<void>? _refreshFuture;
  bool _refreshAfterCurrent = false;
  int _revision = 0;

  List<HostUsageSnapshot> get snapshots => _snapshots;
  List<UsageHostFailure> get failures => _failures;
  bool get loading => _loading;
  DateTime? get lastRefreshedAt => _lastRefreshedAt;

  List<ReconciledUsageAccount> get accounts =>
      UsageReconciler.reconcile(_snapshots);

  void configure(List<HostProfile> hosts) {
    final enabled = hosts.where((host) => host.enabled).toList(growable: false);
    if (_sameHosts(_hosts, enabled)) return;
    _hosts = enabled;
    _revision += 1;
    if (_refreshFuture != null) {
      _refreshAfterCurrent = true;
    }
    _snapshots = _snapshots
        .where((snapshot) => enabled.any((host) => host.id == snapshot.host.id))
        .toList(growable: false);
    _failures = _failures
        .where((failure) => enabled.any((host) => host.id == failure.host.id))
        .toList(growable: false);
    notifyListeners();
  }

  Future<void> refresh() {
    final existing = _refreshFuture;
    if (existing != null) return existing;
    final revision = _revision;
    final future = _refresh(revision);
    _refreshFuture = future;
    return future.whenComplete(() {
      _refreshFuture = null;
      if (_refreshAfterCurrent) {
        _refreshAfterCurrent = false;
        unawaited(refresh());
      }
    });
  }

  Future<void> _refresh(int revision) async {
    final hosts = _hosts;
    if (hosts.isEmpty) {
      _snapshots = const [];
      _failures = const [];
      _lastRefreshedAt = DateTime.now();
      notifyListeners();
      return;
    }

    _loading = true;
    notifyListeners();

    final results = await Future.wait(
      hosts.map((host) => _fetchHost(host)),
    );
    final snapshots = <HostUsageSnapshot>[];
    final failures = <UsageHostFailure>[];
    for (final result in results) {
      final snapshot = result.snapshot;
      if (snapshot != null) snapshots.add(snapshot);
      final failure = result.failure;
      if (failure != null) failures.add(failure);
    }

    if (revision != _revision) {
      return;
    }

    _snapshots = snapshots;
    _failures = failures;
    _lastRefreshedAt = DateTime.now();
    _loading = false;
    notifyListeners();
  }

  Future<_UsageHostFetchResult> _fetchHost(HostProfile host) async {
    try {
      final snapshot = await _api.fetchUsage(host);
      return _UsageHostFetchResult(snapshot: snapshot);
    } catch (error) {
      return _UsageHostFetchResult(
        failure: UsageHostFailure(host: host, message: error.toString()),
      );
    }
  }

  bool _sameHosts(List<HostProfile> left, List<HostProfile> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i += 1) {
      final a = left[i];
      final b = right[i];
      if (a.id != b.id || a.baseUrl != b.baseUrl || a.token != b.token) {
        return false;
      }
    }
    return true;
  }
}

class _UsageHostFetchResult {
  const _UsageHostFetchResult({this.snapshot, this.failure});

  final HostUsageSnapshot? snapshot;
  final UsageHostFailure? failure;
}
