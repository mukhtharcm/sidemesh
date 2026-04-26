import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_send_outbox_store.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'persists and removes pending sends for the matching host/session',
    () async {
      final store = SessionSendOutboxStore.instance;
      final pending = _pendingSend(host, sessionId: 'session-1');

      expect(await store.upsert(pending), isTrue);

      final loaded = await store.loadForSession(host, 'session-1');
      expect(loaded, hasLength(1));
      expect(loaded.single.clientMessageId, 'local-1');

      await store.remove(loaded.single);
      expect(await store.loadForSession(host, 'session-1'), isEmpty);
    },
  );

  test('rejects oversized payloads instead of bloating preferences', () async {
    final store = SessionSendOutboxStore.instance;
    final oversized = _pendingSend(
      host,
      sessionId: 'session-1',
      inputItems: [
        SessionInputItem.image('data:image/png;base64,${'a' * (220 * 1024)}'),
      ],
    );

    expect(await store.upsert(oversized), isFalse);
    expect(await store.loadForSession(host, 'session-1'), isEmpty);
  });

  test('serializes concurrent writes so entries are not lost', () async {
    final store = SessionSendOutboxStore.instance;

    await Future.wait(
      List.generate(
        5,
        (index) => store.upsert(
          _pendingSend(
            host,
            sessionId: 'session-1',
            clientMessageId: 'local-$index',
          ),
        ),
      ),
    );

    expect(await store.loadForSession(host, 'session-1'), hasLength(5));
  });

  test('clearAll removes entries checked by stale workers', () async {
    final store = SessionSendOutboxStore.instance;
    final pending = _pendingSend(host, sessionId: 'session-1');

    expect(await store.upsert(pending), isTrue);
    expect(await store.contains(pending), isTrue);

    await store.clearAll();

    expect(await store.contains(pending), isFalse);
    expect(await store.loadAll(), isEmpty);
  });

  test('replaceIfPresent does not resurrect entries after clearAll', () async {
    final store = SessionSendOutboxStore.instance;
    final pending = _pendingSend(host, sessionId: 'session-1');

    expect(await store.upsert(pending), isTrue);

    await store.clearAll();

    final replaced = await store.replaceIfPresent(
      pending,
      pending.copyWith(lastError: 'still failing'),
    );

    expect(replaced, isFalse);
    expect(await store.loadAll(), isEmpty);
  });

  test('replaceIfPresent updates the matching entry while present', () async {
    final store = SessionSendOutboxStore.instance;
    final pending = _pendingSend(host, sessionId: 'session-1');

    expect(await store.upsert(pending), isTrue);

    final replaced = await store.replaceIfPresent(
      pending,
      pending.copyWith(lastError: 'offline', retryCount: 1),
    );

    final loaded = await store.loadAll();
    expect(replaced, isTrue);
    expect(loaded, hasLength(1));
    expect(loaded.single.lastError, 'offline');
    expect(loaded.single.retryCount, 1);
  });

  test('replaceIfPresent rejects oversized replacements', () async {
    final store = SessionSendOutboxStore.instance;
    final pending = _pendingSend(host, sessionId: 'session-1');

    expect(await store.upsert(pending), isTrue);

    final replaced = await store.replaceIfPresent(
      pending,
      pending.copyWith(lastError: 'e' * (220 * 1024)),
    );

    final loaded = await store.loadAll();
    expect(replaced, isFalse);
    expect(loaded, hasLength(1));
    expect(loaded.single.lastError, isNull);
  });
}

PendingSessionSend _pendingSend(
  HostProfile host, {
  required String sessionId,
  String clientMessageId = 'local-1',
  List<SessionInputItem> inputItems = const [SessionInputItem.text('hello')],
}) {
  final now = DateTime.now();
  return PendingSessionSend(
    hostId: host.id,
    hostFingerprint: SessionSendOutboxStore.hostFingerprint(host),
    sessionId: sessionId,
    clientMessageId: clientMessageId,
    text: 'hello',
    inputItems: inputItems,
    message: SessionMessage(
      id: clientMessageId,
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
  );
}
