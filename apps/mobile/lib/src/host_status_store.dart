import 'package:flutter/foundation.dart';

enum HostReachability { unknown, probing, online, offline }

@immutable
class HostStatus {
  const HostStatus({
    required this.reachability,
    this.lastChangedAt,
    this.lastError,
  });

  final HostReachability reachability;
  final DateTime? lastChangedAt;
  final String? lastError;

  static const unknown = HostStatus(reachability: HostReachability.unknown);

  HostStatus copyWith({
    HostReachability? reachability,
    DateTime? lastChangedAt,
    String? lastError,
    bool clearError = false,
  }) {
    return HostStatus(
      reachability: reachability ?? this.reachability,
      lastChangedAt: lastChangedAt ?? this.lastChangedAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

/// Process-wide store for per-host reachability.
///
/// Panes that talk to hosts (Recent, Inbox, session fetches) report success
/// or failure here so that every surface displaying a host — the Hosts tab,
/// session cards, header strips — can show a consistent online/offline
/// indicator without re-probing.
class HostStatusStore extends ChangeNotifier {
  HostStatusStore._();
  static final HostStatusStore instance = HostStatusStore._();

  final Map<String, HostStatus> _byHostId = <String, HostStatus>{};

  HostStatus statusFor(String hostId) {
    return _byHostId[hostId] ?? HostStatus.unknown;
  }

  void markProbing(String hostId) {
    final current = statusFor(hostId);
    if (current.reachability == HostReachability.probing) return;
    _byHostId[hostId] = current.copyWith(
      reachability: HostReachability.probing,
    );
    notifyListeners();
  }

  void markOnline(String hostId) {
    final previous = statusFor(hostId).reachability;
    _byHostId[hostId] = HostStatus(
      reachability: HostReachability.online,
      lastChangedAt: DateTime.now(),
    );
    if (previous != HostReachability.online) {
      notifyListeners();
    }
  }

  void markOffline(String hostId, {String? error}) {
    final previous = statusFor(hostId).reachability;
    _byHostId[hostId] = HostStatus(
      reachability: HostReachability.offline,
      lastChangedAt: DateTime.now(),
      lastError: error,
    );
    if (previous != HostReachability.offline) {
      notifyListeners();
    }
  }

  void clear(String hostId) {
    final removed = _byHostId.remove(hostId);
    if (removed != null) {
      notifyListeners();
    }
  }
}
