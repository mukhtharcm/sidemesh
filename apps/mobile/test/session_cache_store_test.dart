import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_cache_store.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );
  const otherHost = HostProfile(
    id: 'host-2',
    label: 'Linux box',
    baseUrl: 'http://linux.local:8787',
    token: 'secret',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('clearAll removes cached recent sessions and logs only', () async {
    final store = SessionCacheStore.instance;
    final prefs = await SharedPreferences.getInstance();
    final session = _summary('session-1');
    final otherSession = _summary('session-2');

    await store.saveRecentSessions(host, [session]);
    await store.saveSessionLog(host, _log(session));
    await store.saveRecentSessions(otherHost, [otherSession]);
    await prefs.setString('unrelated-key', 'keep');

    expect(await store.loadRecentSessions(host), hasLength(1));
    expect(await store.loadSessionLog(host, session.id), isNotNull);
    expect(await store.loadRecentSessions(otherHost), hasLength(1));

    await store.clearAll();

    expect(await store.loadRecentSessions(host), isEmpty);
    expect(await store.loadSessionLog(host, session.id), isNull);
    expect(await store.loadRecentSessions(otherHost), isEmpty);
    expect(prefs.getString('unrelated-key'), 'keep');
  });
}

SessionSummary _summary(String id) {
  final now = DateTime.now();
  return SessionSummary(
    id: id,
    title: 'Session $id',
    preview: 'hello',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'codex',
    status: 'complete',
    runtime: null,
    gitInfo: null,
  );
}

SessionLog _log(SessionSummary session) {
  final now = DateTime.now();
  return SessionLog(
    session: session,
    messages: [
      SessionMessage(
        id: 'message-1',
        role: 'assistant',
        text: 'hello',
        attachments: const <SessionMessageAttachment>[],
        createdAt: now,
        seq: 1,
      ),
    ],
    activities: const [],
    pendingAction: null,
    history: null,
  );
}
