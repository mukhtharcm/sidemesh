import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'api_client.dart';
import 'host_store.dart';
import 'models.dart';
import 'session_send_outbox_store.dart';

/// Foreground-only retry worker for queued session sends.
///
/// This is intentionally not an OS background worker. It only runs while the
/// app process is alive/resumed, giving us better retry behavior when users
/// navigate away from a chat without adding background execution complexity.
class SessionSendOutboxWorker with WidgetsBindingObserver {
  SessionSendOutboxWorker._();

  static final SessionSendOutboxWorker instance = SessionSendOutboxWorker._();

  static const _startupSweepDelay = Duration(seconds: 2);
  static const _errorRetryInterval = Duration(seconds: 30);
  static const _maxSendsPerPass = 3;
  static const _hostDisabledMessage =
      'Host is disabled. Enable it before retrying.';
  static const _hostChangedMessage =
      'This host changed since the message was queued. Review it before retrying.';
  static const _hostMissingMessage =
      'The original host is no longer available. Discard or recreate the message.';

  final SessionSendOutboxStore _outbox = SessionSendOutboxStore.instance;
  final ApiClient _api = ApiClient();
  final HostStore _hostStore = HostStore();

  Timer? _timer;
  bool _started = false;
  bool _running = false;
  AppLifecycleState? _lifecycleState;

  void start() {
    if (_started || kIsWeb) {
      return;
    }
    _started = true;
    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _outbox.addListener(poke);
    _schedule(_startupSweepDelay);
  }

  void stop() {
    if (!_started) {
      return;
    }
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _outbox.removeListener(poke);
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _schedule(Duration.zero);
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void poke() {
    if (!_started) {
      return;
    }
    _schedule(Duration.zero);
  }

  void _schedule(Duration delay) {
    if (!_started || _lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(runOnce()));
  }

  Future<void> runOnce() async {
    if (_running || !_started || _lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _running = true;
    try {
      final pending = await _duePendingSends();
      if (pending.isEmpty) {
        await _scheduleNextPass();
        return;
      }

      final hosts = await _hostLookup();
      for (final send in pending.take(_maxSendsPerPass)) {
        if (!_isForeground) {
          break;
        }
        final resolution = _resolveHost(send, hosts);
        if (resolution.blockMessage != null) {
          await _markBlocked(send, resolution.blockMessage!);
          continue;
        }
        await _attemptSend(resolution.host!, send);
      }
      await _scheduleNextPass();
    } catch (error) {
      debugPrint('Foreground send outbox retry failed: $error');
      _schedule(_errorRetryInterval);
    } finally {
      _running = false;
    }
  }

  Future<List<PendingSessionSend>> _duePendingSends() async {
    final now = DateTime.now();
    final all = await _outbox.loadAll();
    final due = all
        .where((send) => !send.blocked && !send.nextAttemptAt.isAfter(now))
        .toList(growable: false);
    due.sort(_comparePending);
    return due;
  }

  Future<void> _scheduleNextPass() async {
    final all = await _outbox.loadAll();
    final retryable = all
        .where((send) => !send.blocked)
        .toList(growable: false);
    if (retryable.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    retryable.sort(_comparePending);
    final next = retryable.first.nextAttemptAt;
    final now = DateTime.now();
    _schedule(next.isAfter(now) ? next.difference(now) : Duration.zero);
  }

  Future<_OutboxHostLookup> _hostLookup() async {
    final hosts = await _hostStore.loadHosts();
    return _OutboxHostLookup(
      exactByKey: <String, HostProfile>{
        for (final host in hosts)
          if (host.enabled)
            _hostKey(host.id, SessionSendOutboxStore.hostFingerprint(host)):
                host,
      },
      byId: <String, HostProfile>{for (final host in hosts) host.id: host},
    );
  }

  Future<void> _attemptSend(HostProfile host, PendingSessionSend send) async {
    if (!_isForeground) {
      return;
    }
    if (!await _outbox.contains(send)) {
      return;
    }
    try {
      await _api.sendInput(
        host,
        sessionId: send.sessionId,
        text: send.text,
        input: send.inputItems,
        clientMessageId: send.clientMessageId,
        model: send.model,
        mode: send.mode,
        reasoningEffort: send.reasoningEffort,
        fastMode: send.fastMode,
        approvalPolicy: send.approvalPolicy,
        sandboxMode: send.sandboxMode,
        networkAccess: send.networkAccess,
        accessMode: send.accessMode,
      );
      await _outbox.remove(send);
    } catch (error) {
      final message = friendlyError(error);
      await _outbox.replaceIfPresent(
        send,
        isRetryableSendError(error)
            ? _deferredSend(send, message, retryCount: send.retryCount + 1)
            : _blockedSend(send, message),
      );
    }
  }

  Future<void> _markBlocked(PendingSessionSend send, String message) async {
    await _outbox.replaceIfPresent(send, _blockedSend(send, message));
  }

  PendingSessionSend _deferredSend(
    PendingSessionSend send,
    String message, {
    required int retryCount,
  }) {
    final now = DateTime.now();
    return send.copyWith(
      updatedAt: now,
      nextAttemptAt: now.add(_backoff(retryCount)),
      retryCount: retryCount,
      lastError: message,
      blocked: false,
    );
  }

  PendingSessionSend _blockedSend(PendingSessionSend send, String message) {
    return send.copyWith(
      updatedAt: DateTime.now(),
      retryCount: send.retryCount + 1,
      lastError: message,
      blocked: true,
    );
  }

  Duration _backoff(int retryCount) {
    const steps = <Duration>[
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 45),
      Duration(minutes: 2),
      Duration(minutes: 5),
    ];
    final index = retryCount.clamp(0, steps.length - 1).toInt();
    return steps[index];
  }

  int _comparePending(PendingSessionSend left, PendingSessionSend right) {
    final nextAttemptCompare = left.nextAttemptAt.compareTo(
      right.nextAttemptAt,
    );
    if (nextAttemptCompare != 0) {
      return nextAttemptCompare;
    }
    return left.createdAt.compareTo(right.createdAt);
  }

  String _hostKey(String hostId, String hostFingerprint) {
    return '$hostId:$hostFingerprint';
  }

  _ResolvedPendingHost _resolveHost(
    PendingSessionSend send,
    _OutboxHostLookup lookup,
  ) {
    final exact =
        lookup.exactByKey[_hostKey(send.hostId, send.hostFingerprint)];
    if (exact != null) {
      return _ResolvedPendingHost(host: exact);
    }
    final current = lookup.byId[send.hostId];
    if (current == null) {
      return const _ResolvedPendingHost(blockMessage: _hostMissingMessage);
    }
    if (!current.enabled) {
      return const _ResolvedPendingHost(blockMessage: _hostDisabledMessage);
    }
    return const _ResolvedPendingHost(blockMessage: _hostChangedMessage);
  }

  bool get _isForeground =>
      _started && _lifecycleState == AppLifecycleState.resumed;
}

class _OutboxHostLookup {
  const _OutboxHostLookup({required this.exactByKey, required this.byId});

  final Map<String, HostProfile> exactByKey;
  final Map<String, HostProfile> byId;
}

class _ResolvedPendingHost {
  const _ResolvedPendingHost({this.host, this.blockMessage});

  final HostProfile? host;
  final String? blockMessage;
}
