import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_path_provider.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  setUpAll(() {
    configureTestDatabaseFactory();
  });

  tearDownAll(() async {
    await SidemeshDb.close();
  });

  setUp(() async {
    SessionLocalStore.instance.resetMigrationState();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Wipe DB before each test
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
  });

  test('upsert and getRecentSessions', () async {
    final store = SessionLocalStore.instance;
    final s1 = _summary(
      's1',
      updatedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      title: 'First',
    );
    final s2 = _summary('s2', updatedAt: DateTime.now(), title: 'Second');

    await store.upsertSessions(host, [s1, s2]);
    final recents = await store.getRecentSessions(host);

    expect(recents.length, 2);
    expect(recents.first.id, 's2'); // sorted by updated_at DESC
    expect(recents.last.id, 's1');
  });

  test('first-load database work is safe under concurrent callers', () async {
    final store = SessionLocalStore.instance;
    final session = _summary(
      'race-1',
      updatedAt: DateTime.now(),
      title: 'Race',
    );

    await Future.wait([
      store.ensureLoaded(),
      store.getRecentSessions(host),
      store.getFavoriteSessions(host),
      store.upsertSessions(host, [session]),
    ]);

    final recents = await store.getRecentSessions(host);
    expect(recents.length, 1);
    expect(recents.single.id, 'race-1');
  });

  test('getRecentSessions respects limit', () async {
    final store = SessionLocalStore.instance;
    final sessions = List.generate(
      50,
      (i) =>
          _summary("s$i", updatedAt: DateTime.now().add(Duration(seconds: i))),
    );

    await store.upsertSessions(host, sessions);
    final recents = await store.getRecentSessions(host, limit: 10);

    expect(recents.length, 10);
  });

  test('upsert updates existing row', () async {
    final store = SessionLocalStore.instance;
    final s1 = _summary(
      's1',
      updatedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      title: 'Original',
    );
    await store.upsertSessions(host, [s1]);

    final updated = s1.copyWith(title: 'Updated');
    await store.upsertSessions(host, [updated]);
    final recents = await store.getRecentSessions(host);

    expect(recents.first.title, 'Updated');
  });

  test('upsertSessions replaces stale recent rows', () async {
    final store = SessionLocalStore.instance;
    final first = _summary('s1', updatedAt: DateTime.now(), title: 'First');
    final second = _summary(
      's2',
      updatedAt: DateTime.now().add(const Duration(seconds: 1)),
      title: 'Second',
    );

    await store.upsertSessions(host, [first, second]);
    await store.upsertSessions(host, [second]);

    final recents = await store.getRecentSessions(host);
    expect(recents.map((session) => session.id), ['s2']);
  });

  test('favorites survive when a session drops out of recents', () async {
    final store = SessionLocalStore.instance;
    final favorite = _summary('favorite', updatedAt: DateTime.now());
    final recent = _summary(
      'recent',
      updatedAt: DateTime.now().add(const Duration(seconds: 1)),
    );

    await store.upsertSessions(host, [favorite, recent]);
    await store.toggleFavorite(host, 'favorite');
    await store.upsertSessions(host, [recent]);

    final recents = await store.getRecentSessions(host);
    final favorites = await store.getFavoriteSessions(host);
    final ghosts = await store.ghostsForHost(host);

    expect(recents.map((session) => session.id), ['recent']);
    expect(favorites.map((session) => session.id), contains('favorite'));
    expect(ghosts.map((session) => session.id), ['favorite']);
  });

  test('toggleFavorite and isFavorite', () async {
    final store = SessionLocalStore.instance;
    final s1 = _summary(
      's1',
      updatedAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await store.upsertSessions(host, [s1]);

    expect(store.isFavorite(host, 's1'), false);

    final added = await store.toggleFavorite(host, 's1');
    expect(added, true);
    expect(store.isFavorite(host, 's1'), true);

    final removed = await store.toggleFavorite(host, 's1');
    expect(removed, false);
    expect(store.isFavorite(host, 's1'), false);
  });

  test('getFavoriteSessions returns only favorites', () async {
    final store = SessionLocalStore.instance;
    final s1 = _summary(
      's1',
      updatedAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final s2 = _summary('s2', updatedAt: DateTime.now());
    await store.upsertSessions(host, [s1, s2]);

    await store.toggleFavorite(host, 's1');
    final favorites = await store.getFavoriteSessions(host);

    expect(favorites.length, 1);
    expect(favorites.first.id, 's1');
  });

  test('removing a favorite persists to the local store', () async {
    final store = SessionLocalStore.instance;
    final session = _summary('s1', updatedAt: DateTime.now());
    await store.upsertSessions(host, [session]);

    await store.toggleFavorite(host, 's1');
    await store.toggleFavorite(host, 's1');

    final favorites = await store.getFavoriteSessions(host);
    expect(favorites, isEmpty);
  });

  test('ghost favorite survives without recent', () async {
    final store = SessionLocalStore.instance;
    await store.toggleFavorite(host, 'ghost-1');

    final favorites = await store.getFavoriteSessions(host);
    expect(favorites.length, 1);
    expect(favorites.first.id, 'ghost-1');
    expect(favorites.first.title, 'Unknown');
  });

  test('clearHost removes all rows for host', () async {
    final store = SessionLocalStore.instance;
    await store.upsertSessions(host, [
      _summary(
        's1',
        updatedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    ]);
    await store.toggleFavorite(host, 's1');

    await store.clearHost(host);
    final recents = await store.getRecentSessions(host);
    final favorites = await store.getFavoriteSessions(host);

    expect(recents, isEmpty);
    expect(favorites, isEmpty);
  });

  test('pruneOldSessions removes stale non-favorites', () async {
    final store = SessionLocalStore.instance;
    final fresh = _summary('fresh', updatedAt: DateTime.now());
    final stale = _summary(
      'stale',
      updatedAt: DateTime.now().subtract(const Duration(days: 30)),
    );
    await store.upsertSessions(host, [fresh, stale]);

    await store.pruneOldSessions(host, const Duration(days: 7));
    final recents = await store.getRecentSessions(host);

    expect(recents.length, 1);
    expect(recents.first.id, 'fresh');
  });

  test('pruneOldSessions preserves stale favorites', () async {
    final store = SessionLocalStore.instance;
    final stale = _summary(
      'stale',
      updatedAt: DateTime.now().subtract(const Duration(days: 30)),
    );
    await store.upsertSessions(host, [stale]);
    await store.toggleFavorite(host, 'stale');

    await store.pruneOldSessions(host, const Duration(days: 7));
    final favorites = await store.getFavoriteSessions(host);

    expect(favorites.length, 1);
    expect(favorites.first.id, 'stale');
  });

  test('getSession returns matching row or null', () async {
    final store = SessionLocalStore.instance;
    final s1 = _summary(
      's1',
      updatedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      title: 'Target',
    );
    await store.upsertSessions(host, [s1]);

    final found = await store.getSession(host, 's1');
    expect(found?.title, 'Target');

    final missing = await store.getSession(host, 'missing');
    expect(missing, isNull);
  });

  test('migration from old SharedPreferences', () async {
    SharedPreferences.setMockInitialValues({
      'sidemesh_cached_recent_sessions_v1:host-1':
          '[{"id":"old-s1","title":"Old","preview":"p","cwd":"/","createdAt":1700000000000,"updatedAt":1700000000000,"source":"codex","provider":null,"status":"complete","runtime":null,"gitInfo":null}]',
      'sidemesh_session_favorites_v1': ['host-1::old-fav'],
    });

    SessionLocalStore.instance.resetMigrationState();
    final store = SessionLocalStore.instance;
    final recents = await store.getRecentSessions(host);
    expect(recents.length, 1);
    expect(recents.first.id, 'old-s1');

    final favorites = await store.getFavoriteSessions(host);
    expect(favorites.length, 1);
    expect(favorites.first.id, 'old-fav');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('sidemesh_sqflite_migrated_v1'), true);
  });

  test('clearAll wipes sessions and logs', () async {
    final store = SessionLocalStore.instance;
    await store.upsertSessions(host, [
      _summary(
        's1',
        updatedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      ),
    ]);
    await store.saveSessionLog(host, _log('s1'));

    await store.clearAll();
    final recents = await store.getRecentSessions(host);
    final cachedLog = await store.loadSessionLog(host, 's1');

    expect(recents, isEmpty);
    expect(cachedLog, isNull);
  });
}

SessionSummary _summary(
  String id, {
  String title = 'Session',
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.now();
  return SessionSummary(
    id: id,
    title: title,
    preview: 'hello',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'codex',
    provider: null,
    status: 'complete',
    runtime: null,
    gitInfo: null,
  );
}

SessionLog _log(String sessionId) {
  final now = DateTime.now();
  return SessionLog(
    session: _summary(sessionId),
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
