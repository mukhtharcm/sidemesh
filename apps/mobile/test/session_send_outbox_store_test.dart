import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_send_outbox_store.dart';

import 'test_path_provider.dart';

void main() {
  setUpAll(configureTestDatabaseFactory);
  tearDownAll(SidemeshDb.close);
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = await SidemeshDb.instance;
    await db.delete('session_outbox');
    await db.delete('client_migrations');
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
      expect(loaded.single.accessMode, 'guarded');

      await store.remove(loaded.single);
      expect(await store.loadForSession(host, 'session-1'), isEmpty);
    },
  );

  test('rejects oversized payloads without changing saved messages', () async {
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
  test('imports old pending messages once and keeps them after database reopen', () async {
    final store = SessionSendOutboxStore.instance;
    final entry = _pendingSend(host, sessionId: 'session:with:colons');
    final json = entry.toJson();
    json['createdAt'] = DateTime.now().subtract(const Duration(days: 90)).millisecondsSinceEpoch;
    final original = jsonEncode([json]);
    SharedPreferences.setMockInitialValues({'sidemesh_pending_session_sends_v1': original});
    expect((await store.loadAll()).single.createdAt, isNot(entry.createdAt));
    await SidemeshDb.close();
    expect((await store.loadForSession(host, entry.sessionId)).single.clientMessageId, entry.clientMessageId);
    expect((await SharedPreferences.getInstance()).getString('sidemesh_pending_session_sends_v1'), original);
    await store.remove(entry);
    await SidemeshDb.close();
    expect(await store.loadAll(), isEmpty);
  });

  test('failed legacy import rolls back and keeps its source for retry', () async {
    final store = SessionSendOutboxStore.instance;
    final entry = _pendingSend(host, sessionId: 'session-1');
    final original = jsonEncode([entry.toJson(), {'inputItems': []}]);
    SharedPreferences.setMockInitialValues({'sidemesh_pending_session_sends_v1': original});
    await expectLater(store.loadAll(), throwsFormatException);
    final db = await SidemeshDb.instance;
    expect(await db.query('session_outbox'), isEmpty);
    expect(await db.query('client_migrations'), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sidemesh_pending_session_sends_v1'), original);
    await prefs.setString('sidemesh_pending_session_sends_v1', jsonEncode([entry.toJson()]));
    expect(await store.loadAll(), hasLength(1));
    await store.clearAll();
    expect(await store.loadAll(), isEmpty);
  });

  test('full outbox rejects another entry without evicting pending messages', () async {
    final store = SessionSendOutboxStore.instance;
    for (var i = 0; i < 20; i += 1) {
      expect(await store.upsert(_pendingSend(host, sessionId: 'session-$i')), isTrue);
    }
    expect(await store.upsert(_pendingSend(host, sessionId: 'overflow')), isFalse);
    expect(await store.loadAll(), hasLength(20));
    expect(await store.contains(_pendingSend(host, sessionId: 'session-0')), isTrue);
    expect(await store.upsert(_pendingSend(host, sessionId: 'session-0').copyWith(lastError: 'offline')), isTrue);
  });

  test('byte limit and identity collision leave existing rows unchanged', () async {
    final store = SessionSendOutboxStore.instance;
    final large = _pendingSend(host, sessionId: 'large', inputItems: [SessionInputItem.text('a' * (170 * 1024))]);
    final second = _pendingSend(host, sessionId: 'second', inputItems: large.inputItems);
    final third = _pendingSend(host, sessionId: 'third', inputItems: large.inputItems);
    expect(await store.upsert(large), isTrue);
    expect(await store.upsert(second), isTrue);
    expect(await store.upsert(third), isTrue);
    expect(await store.upsert(_pendingSend(host, sessionId: 'overflow', inputItems: [SessionInputItem.text('b' * 4096)])), isFalse);
    expect(await store.replaceIfPresent(large, second), isFalse);
    expect(await store.contains(large), isTrue);
    expect(await store.loadAll(), hasLength(3));
  });

  test('column identities distinguish colon-delimited message keys', () async {
    final store = SessionSendOutboxStore.instance;
    final first = _pendingSend(host, sessionId: 'session:part', clientMessageId: 'message');
    final second = _pendingSend(host, sessionId: 'session', clientMessageId: 'part:message');
    expect(first.key, isNot(second.key));
    expect(await store.upsert(first), isTrue);
    expect(await store.upsert(second), isTrue);
    await store.remove(first);
    expect(await store.contains(second), isTrue);
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
    accessMode: 'guarded',
  );
}
