import 'models.dart';
import 'session_send_outbox_store.dart';

enum PendingSendDisplayState { queued, retrying, blocked }

enum PendingSendIssueKind {
  none,
  hostDisabled,
  hostMissing,
  hostChanged,
  unauthorized,
  timeout,
  unreachable,
  server,
  rateLimited,
  unknown,
}

class PendingSendAnalysis {
  const PendingSendAnalysis({
    required this.send,
    required this.host,
    required this.state,
    required this.issue,
    required this.fingerprintMatches,
  });

  final PendingSessionSend send;
  final HostProfile? host;
  final PendingSendDisplayState state;
  final PendingSendIssueKind issue;
  final bool fingerprintMatches;

  bool get canEnableHost => host != null && !host!.enabled;

  bool get canFixHost =>
      host != null && issue == PendingSendIssueKind.unauthorized;

  bool get canUseCurrentHost =>
      host != null && issue == PendingSendIssueKind.hostChanged;

  bool get canRetryNow =>
      issue != PendingSendIssueKind.hostDisabled &&
      issue != PendingSendIssueKind.hostMissing &&
      issue != PendingSendIssueKind.hostChanged &&
      issue != PendingSendIssueKind.unauthorized;

  bool get canOpenSession =>
      host != null &&
      host!.enabled &&
      fingerprintMatches &&
      issue != PendingSendIssueKind.unauthorized;

  bool get needsAttention =>
      state == PendingSendDisplayState.blocked ||
      issue == PendingSendIssueKind.hostDisabled ||
      issue == PendingSendIssueKind.hostMissing ||
      issue == PendingSendIssueKind.hostChanged ||
      issue == PendingSendIssueKind.unauthorized;

  String get hostLabel => host?.label ?? 'Unknown host';
}

String pendingSendRecoveryMessage(PendingSendAnalysis analysis) {
  return switch (analysis.issue) {
    PendingSendIssueKind.hostDisabled =>
      'Host is disabled. Enable it before retrying.',
    PendingSendIssueKind.hostMissing =>
      'The original host is gone. Discard or recreate the message.',
    PendingSendIssueKind.hostChanged =>
      'This host changed since the message was queued. Review its config first.',
    PendingSendIssueKind.unauthorized =>
      'Host token is invalid. Fix the host credentials, then retry.',
    PendingSendIssueKind.timeout => 'The host is taking too long to respond.',
    PendingSendIssueKind.unreachable => "Couldn't reach the host.",
    PendingSendIssueKind.server =>
      'The host reported a temporary server error.',
    PendingSendIssueKind.rateLimited => 'The host is rate limited right now.',
    PendingSendIssueKind.unknown =>
      analysis.send.lastError ??
          'This message needs attention before retrying.',
    PendingSendIssueKind.none =>
      analysis.send.lastError ?? 'Waiting to retry automatically.',
  };
}

String pendingSendStateLabel(PendingSendDisplayState state) {
  return switch (state) {
    PendingSendDisplayState.queued => 'queued',
    PendingSendDisplayState.retrying => 'retrying',
    PendingSendDisplayState.blocked => 'blocked',
  };
}

PendingSendAnalysis analyzePendingSend(
  PendingSessionSend send, {
  required List<HostProfile> hosts,
  bool retrying = false,
}) {
  HostProfile? exactHost;
  HostProfile? sameIdHost;
  for (final host in hosts) {
    if (host.id != send.hostId) {
      continue;
    }
    sameIdHost = host;
    if (SessionSendOutboxStore.hostFingerprint(host) == send.hostFingerprint) {
      exactHost = host;
      break;
    }
  }

  final resolvedHost = exactHost ?? sameIdHost;
  final fingerprintMatches = exactHost != null;
  final issue = _inferIssue(
    send,
    host: resolvedHost,
    fingerprintMatches: fingerprintMatches,
  );
  final state = switch ((retrying, send.blocked, issue)) {
    (true, _, _) => PendingSendDisplayState.retrying,
    (_, true, _) => PendingSendDisplayState.blocked,
    (_, _, PendingSendIssueKind.hostDisabled) =>
      PendingSendDisplayState.blocked,
    (_, _, PendingSendIssueKind.hostMissing) => PendingSendDisplayState.blocked,
    (_, _, PendingSendIssueKind.hostChanged) => PendingSendDisplayState.blocked,
    (_, _, PendingSendIssueKind.unauthorized) =>
      PendingSendDisplayState.blocked,
    _ => PendingSendDisplayState.queued,
  };
  return PendingSendAnalysis(
    send: send,
    host: resolvedHost,
    state: state,
    issue: issue,
    fingerprintMatches: fingerprintMatches,
  );
}

PendingSendIssueKind _inferIssue(
  PendingSessionSend send, {
  required HostProfile? host,
  required bool fingerprintMatches,
}) {
  if (host == null) {
    return PendingSendIssueKind.hostMissing;
  }
  if (!fingerprintMatches) {
    return PendingSendIssueKind.hostChanged;
  }
  if (!host.enabled) {
    return PendingSendIssueKind.hostDisabled;
  }
  final message = (send.lastError ?? '').toLowerCase();
  if (message.isEmpty) {
    return PendingSendIssueKind.none;
  }
  if (message.contains('not authorized') ||
      message.contains('check the host token') ||
      message.contains('401') ||
      message.contains('403')) {
    return PendingSendIssueKind.unauthorized;
  }
  if (message.contains('timed out') || message.contains('too long')) {
    return PendingSendIssueKind.timeout;
  }
  if (message.contains("couldn't reach the host") ||
      message.contains('connection refused') ||
      message.contains('failed host lookup')) {
    return PendingSendIssueKind.unreachable;
  }
  if (message.contains('429') || message.contains('rate limit')) {
    return PendingSendIssueKind.rateLimited;
  }
  if (message.contains('server error') ||
      message.contains('500') ||
      message.contains('502') ||
      message.contains('503')) {
    return PendingSendIssueKind.server;
  }
  return send.blocked
      ? PendingSendIssueKind.unknown
      : PendingSendIssueKind.none;
}
