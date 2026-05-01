import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Priority for reconnect slots. Higher priority = reconnect sooner.
enum ReconnectPriority {
  /// The visible foreground session — reconnect immediately.
  foregroundSession,

  /// Visible support sockets (terminal, browser preview) — slight delay.
  visibleSupport,

  /// Background sockets (Recent, Inbox, FS) — longer delay.
  backgroundSocket,
}

/// State exposed for retry-countdown UI.
@immutable
class HostRetryState {
  const HostRetryState({
    required this.hostId,
    required this.isConnected,
    required this.nextRetryAt,
    required this.attemptCount,
  });

  final String hostId;
  final bool isConnected;
  final DateTime? nextRetryAt;
  final int attemptCount;

  /// Null when connected. Positive duration when waiting to retry.
  Duration? get remaining {
    if (isConnected || nextRetryAt == null) return null;
    final remaining = nextRetryAt!.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  @override
  String toString() =>
      'HostRetryState(hostId: $hostId, isConnected: $isConnected, '
      'attemptCount: $attemptCount, remaining: $remaining)';
}

/// A single slot registered by a widget or store.
class _ReconnectSlot {
  _ReconnectSlot({
    required this.id,
    required this.priority,
    required this.onReconnect,
    this.isConnected = true,
    this.attemptCount = 0,
  });

  final String id;
  final ReconnectPriority priority;
  final VoidCallback onReconnect;
  bool isConnected;
  int attemptCount;
}

/// Per-host internal state.
class _HostRetryController {
  _HostRetryController({required this.hostId});

  final String hostId;
  final Map<String, _ReconnectSlot> slots = {};
  Timer? timer;
  DateTime? nextRetryAt;

  void dispose() {
    timer?.cancel();
    timer = null;
    slots.clear();
  }
}

/// Centralized per-host reconnect scheduler.
///
/// Instead of every pane (session, terminal, browser, Recent, Inbox, FS)
/// running its own independent reconnect timer, they all register a slot
/// here. The scheduler computes one delay per host based on the highest
/// priority registered slot, adds jitter, and fires all callbacks when
/// the timer expires.
///
/// Each slot tracks its own connected/disconnected state. This prevents a
/// healthy Recent/Inbox socket from hiding a broken foreground session socket.
class HostReconnectScheduler {
  HostReconnectScheduler._();
  static final HostReconnectScheduler instance = HostReconnectScheduler._();

  // Coverage-friendly override for the random source.
  static Random? _randomOverride;

  /// Exposed for tests only.
  static void setRandomOverride(Random? random) {
    _randomOverride = random;
  }

  final Map<String, _HostRetryController> _controllers = {};
  final _stateControllers = <String, StreamController<HostRetryState>>{};

  Random get _random => _randomOverride ?? Random();

  /// Register a reconnect slot for [hostId].
  ///
  /// [slotId] must be unique per host (e.g. "session-live", "terminal-live").
  /// [priority] determines how quickly this host reconnects after failure.
  /// [onReconnect] is called when the scheduler decides it's time.
  void registerSlot(
    String hostId,
    String slotId,
    ReconnectPriority priority,
    VoidCallback onReconnect,
  ) {
    final controller = _controllers.putIfAbsent(
      hostId,
      () => _HostRetryController(hostId: hostId),
    );
    final existing = controller.slots[slotId];
    controller.slots[slotId] = _ReconnectSlot(
      id: slotId,
      priority: priority,
      onReconnect: onReconnect,
      isConnected: existing?.isConnected ?? true,
      attemptCount: existing?.attemptCount ?? 0,
    );
  }

  /// Unregister a slot. If this was the last slot for the host, cleanup.
  void unregisterSlot(String hostId, String slotId) {
    final controller = _controllers[hostId];
    if (controller == null) return;
    controller.slots.remove(slotId);
    if (controller.slots.isEmpty) {
      controller.dispose();
      _controllers.remove(hostId);
    }
  }

  /// Call when a connection succeeds.
  ///
  /// When [slotId] is provided, only that slot is marked healthy. Omitting
  /// [slotId] keeps the old whole-host behavior for compatibility.
  void markConnected(String hostId, [String? slotId]) {
    final controller = _controllers[hostId];
    if (controller == null) return;

    final slots = _slotsFor(controller, slotId);
    for (final slot in slots) {
      slot.isConnected = true;
      slot.attemptCount = 0;
    }

    if (_disconnectedSlots(controller).isEmpty) {
      controller.timer?.cancel();
      controller.timer = null;
      controller.nextRetryAt = null;
    }
    _emit(hostId, controller);
  }

  /// Call when a slot loses its connection.
  /// If no retry is already pending, schedules one.
  void markDisconnected(String hostId, [String? slotId]) {
    final controller = _controllers[hostId];
    if (controller == null) return;
    if (controller.slots.isEmpty) return;

    final slots = _slotsFor(controller, slotId);
    var changed = false;
    for (final slot in slots) {
      if (!slot.isConnected) continue;
      slot.isConnected = false;
      slot.attemptCount += 1;
      changed = true;
    }

    if (_disconnectedSlots(controller).isEmpty) return;
    _scheduleRetry(controller, allowEarlierReschedule: changed);
  }

  /// Stream of retry-state changes for UI countdowns.
  Stream<HostRetryState> retryStateFor(String hostId) {
    return _stateControllers
        .putIfAbsent(hostId, () => StreamController<HostRetryState>.broadcast())
        .stream;
  }

  void _scheduleRetry(
    _HostRetryController controller, {
    required bool allowEarlierReschedule,
  }) {
    final delay = _computeDelay(controller);
    final jittered = _applyJitter(delay);
    final nextRetryAt = DateTime.now().add(jittered);

    if (controller.timer != null) {
      if (!allowEarlierReschedule ||
          controller.nextRetryAt == null ||
          !nextRetryAt.isBefore(controller.nextRetryAt!)) {
        _emit(controller.hostId, controller);
        return;
      }
      controller.timer?.cancel();
      controller.timer = null;
    }

    controller.nextRetryAt = nextRetryAt;
    _emit(controller.hostId, controller);

    controller.timer = Timer(jittered, () {
      controller.timer = null;
      controller.nextRetryAt = null;
      final slots = List<_ReconnectSlot>.from(_disconnectedSlots(controller));
      for (final slot in slots) {
        if (controller.slots[slot.id] == slot && !slot.isConnected) {
          slot.onReconnect();
        }
      }
      _emit(controller.hostId, controller);
    });
  }

  Duration _computeDelay(_HostRetryController controller) {
    final priority = _highestPriority(controller);
    final attempt = _maxDisconnectedAttempt(controller);

    switch (priority) {
      case ReconnectPriority.foregroundSession:
        return _delayForAttempt(attempt, [
          const Duration(milliseconds: 0),
          const Duration(milliseconds: 500),
          const Duration(seconds: 1),
          const Duration(seconds: 2),
          const Duration(seconds: 4),
          const Duration(seconds: 8),
        ]);
      case ReconnectPriority.visibleSupport:
        return _delayForAttempt(attempt, [
          const Duration(milliseconds: 500),
          const Duration(seconds: 1),
          const Duration(seconds: 2),
          const Duration(seconds: 4),
          const Duration(seconds: 8),
          const Duration(seconds: 15),
        ]);
      case ReconnectPriority.backgroundSocket:
        return _delayForAttempt(attempt, [
          const Duration(seconds: 2),
          const Duration(seconds: 4),
          const Duration(seconds: 8),
          const Duration(seconds: 15),
          const Duration(seconds: 30),
          const Duration(seconds: 30),
        ]);
    }
  }

  Duration _delayForAttempt(int attempt, List<Duration> table) {
    final index = (attempt - 1).clamp(0, table.length - 1);
    return table[index];
  }

  Duration _applyJitter(Duration base) {
    // ±30% jitter, but keep at least 100ms for very short delays
    final jitterFactor = 0.7 + (_random.nextDouble() * 0.6);
    final ms = (base.inMilliseconds * jitterFactor).round();
    return Duration(milliseconds: ms.clamp(100, 30000));
  }

  ReconnectPriority _highestPriority(_HostRetryController controller) {
    ReconnectPriority? best;
    for (final slot in _disconnectedSlots(controller)) {
      if (best == null || slot.priority.index < best.index) {
        best = slot.priority;
      }
    }
    return best ?? ReconnectPriority.backgroundSocket;
  }

  void _emit(String hostId, _HostRetryController controller) {
    final streamController = _stateControllers[hostId];
    if (streamController == null || streamController.isClosed) return;
    streamController.add(
      HostRetryState(
        hostId: hostId,
        isConnected: _disconnectedSlots(controller).isEmpty,
        nextRetryAt: controller.nextRetryAt,
        attemptCount: _maxDisconnectedAttempt(controller),
      ),
    );
  }

  Iterable<_ReconnectSlot> _disconnectedSlots(
    _HostRetryController controller,
  ) => controller.slots.values.where((slot) => !slot.isConnected);

  Iterable<_ReconnectSlot> _slotsFor(
    _HostRetryController controller,
    String? slotId,
  ) {
    if (slotId == null) return controller.slots.values;
    final slot = controller.slots[slotId];
    return slot == null ? const <_ReconnectSlot>[] : <_ReconnectSlot>[slot];
  }

  int _maxDisconnectedAttempt(_HostRetryController controller) {
    var attempt = 0;
    for (final slot in _disconnectedSlots(controller)) {
      attempt = max(attempt, slot.attemptCount);
    }
    return attempt;
  }

  /// Dispose everything. Useful in tests.
  void reset() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    for (final sc in _stateControllers.values) {
      sc.close();
    }
    _stateControllers.clear();
  }
}
