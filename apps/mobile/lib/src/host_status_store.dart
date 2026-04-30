import 'package:flutter/foundation.dart';

enum HostReachability { unknown, probing, online, offline }

@immutable
class HostStatus {
  const HostStatus({
    required this.reachability,
    this.lastChangedAt,
    this.lastOnlineAt,
    this.lastEventAt,
    this.lastError,
  });

  final HostReachability reachability;
  final DateTime? lastChangedAt;
  final DateTime? lastOnlineAt;
  final DateTime? lastEventAt;
  final String? lastError;

  static const unknown = HostStatus(reachability: HostReachability.unknown);

  HostStatus copyWith({
    HostReachability? reachability,
    DateTime? lastChangedAt,
    DateTime? lastOnlineAt,
    DateTime? lastEventAt,
    String? lastError,
    bool clearError = false,
  }) {
    return HostStatus(
      reachability: reachability ?? this.reachability,
      lastChangedAt: lastChangedAt ?? this.lastChangedAt,
      lastOnlineAt: lastOnlineAt ?? this.lastOnlineAt,
      lastEventAt: lastEventAt ?? this.lastEventAt,
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
      lastChangedAt: DateTime.now(),
    );
    notifyListeners();
  }

  void markOnline(String hostId) {
    final current = statusFor(hostId);
    final now = DateTime.now();
    _byHostId[hostId] = HostStatus(
      reachability: HostReachability.online,
      lastChangedAt: now,
      lastOnlineAt: now,
      lastEventAt: current.lastEventAt,
    );
    if (current.reachability != HostReachability.online ||
        current.lastError != null) {
      notifyListeners();
    }
  }

  void markEvent(String hostId) {
    final current = statusFor(hostId);
    final now = DateTime.now();
    _byHostId[hostId] = HostStatus(
      reachability: HostReachability.online,
      lastChangedAt: current.reachability == HostReachability.online
          ? current.lastChangedAt
          : now,
      lastOnlineAt: now,
      lastEventAt: now,
    );
    if (current.reachability != HostReachability.online ||
        current.lastError != null) {
      notifyListeners();
    }
  }

  void markOffline(String hostId, {String? error}) {
    final current = statusFor(hostId);
    _byHostId[hostId] = HostStatus(
      reachability: HostReachability.offline,
      lastChangedAt: DateTime.now(),
      lastOnlineAt: current.lastOnlineAt,
      lastEventAt: current.lastEventAt,
      lastError: error,
    );
    if (current.reachability != HostReachability.offline ||
        current.lastError != error) {
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
