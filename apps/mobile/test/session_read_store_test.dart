import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_read_store.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  SessionSummary buildSession({required DateTime updatedAt}) {
    return SessionSummary(
      id: 'session-1',
      title: 'Debug session',
      preview: 'preview',
      cwd: '/tmp/project',
      createdAt: updatedAt.subtract(const Duration(minutes: 5)),
      updatedAt: updatedAt,
      source: 'cli',
      provider: null,
      status: 'idle',
      runtime: null,
      gitInfo: null,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SessionReadStore.instance.resetForTest();
    await SessionReadStore.instance.ensureLoaded();
  });

  test('markUnread forces a session back into unread state until seen again', () async {
    final store = SessionReadStore.instance;
    final session = buildSession(
      updatedAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );

    store.markSeen(host, session.id, session.updatedAt);
    expect(store.isUnread(host, session), isFalse);

    store.markUnread(host, session.id);
    expect(store.isUnread(host, session), isTrue);

    store.markSeen(host, session.id, session.updatedAt);
    expect(store.isUnread(host, session), isFalse);
  });
}
