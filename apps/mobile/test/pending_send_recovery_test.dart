import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/pending_send_recovery.dart';
import 'package:sidemesh_mobile/src/session_send_outbox_store.dart';

void main() {
  const currentHost = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'new-token',
  );

  test('classifies changed hosts as needing current-host recovery', () {
    final staleHost = currentHost.copyWith(token: 'old-token');
    final analysis = analyzePendingSend(
      _pendingSend(staleHost),
      hosts: [currentHost],
    );

    expect(analysis.issue, PendingSendIssueKind.hostChanged);
    expect(analysis.canUseCurrentHost, isTrue);
    expect(analysis.canRetryNow, isFalse);
    expect(analysis.canOpenSession, isFalse);
  });

  test('classifies unauthorized sends as fixable but not retryable', () {
    final analysis = analyzePendingSend(
      _pendingSend(
        currentHost,
        lastError: 'Not authorized (401). Check the host token.',
        blocked: true,
      ),
      hosts: [currentHost],
    );

    expect(analysis.issue, PendingSendIssueKind.unauthorized);
    expect(analysis.canFixHost, isTrue);
    expect(analysis.canRetryNow, isFalse);
    expect(analysis.needsAttention, isTrue);
  });

  test('classifies disabled hosts as blocked and enableable', () {
    final disabledHost = currentHost.copyWith(enabled: false);
    final analysis = analyzePendingSend(
      _pendingSend(disabledHost, blocked: true),
      hosts: [disabledHost],
    );

    expect(analysis.issue, PendingSendIssueKind.hostDisabled);
    expect(analysis.canEnableHost, isTrue);
    expect(analysis.canRetryNow, isFalse);
    expect(analysis.state, PendingSendDisplayState.blocked);
  });
}

PendingSessionSend _pendingSend(
  HostProfile host, {
  String? lastError,
  bool blocked = false,
}) {
  final now = DateTime.now();
  return PendingSessionSend(
    hostId: host.id,
    hostFingerprint: SessionSendOutboxStore.hostFingerprint(host),
    sessionId: 'session-1',
    clientMessageId: 'local-1',
    text: 'hello',
    inputItems: const [SessionInputItem.text('hello')],
    message: SessionMessage(
      id: 'local-1',
      role: 'user',
      text: 'hello',
      attachments: const <SessionMessageAttachment>[],
      createdAt: now,
      seq: 1,
    ),
    createdAt: now,
    updatedAt: now,
    nextAttemptAt: now,
    retryCount: 0,
    lastError: lastError,
    blocked: blocked,
  );
}
