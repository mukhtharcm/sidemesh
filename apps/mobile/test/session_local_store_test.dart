import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/session_identity.dart';
import 'package:sidemesh_mobile/src/session_identity_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_path_provider.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
  );

  setUpAll(() async {
    await configureTestDatabaseFactory();
  });

  tearDownAll(() async {
    await SidemeshDb.close();
  });

  setUp(() async {
    SessionLocalStore.instance.resetMigrationState();
    SessionIdentityStore.instance.resetForTest();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // Wipe DB before each test
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
    await db.delete('session_logs');
    await db.delete('session_outbox');
    await db.delete('client_migrations');
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

  test('explicit deletion clears the selected session log and favorite', () async {
    final store = SessionLocalStore.instance;
    await store.saveSessionLog(host, _log('deleted'));
    await store.saveSessionLog(host, _log('kept'));
    await store.setFavorite(host, 'deleted', favorite: true);
    await store.deleteSession(host, 'deleted', deleteLog: true);
    expect(await store.loadSessionLog(host, 'deleted'), isNull);
    expect(await store.loadSessionLog(host, 'kept'), isNotNull);
    expect(store.isFavorite(host, 'deleted'), isFalse);
  });

  test('recent and favorite cache retain provider instance identity', () async {
    final store = SessionLocalStore.instance;
    final session = _summary('work:czE', updatedAt: DateTime.now()).copyWith(
      provider: 'copilot', providerId: 'work', canonicalSessionId: 'work:czE',
    );
    await store.upsertSessions(host, [session]);
    expect((await store.getRecentSessions(host)).single.providerReference, 'work');
    await store.setFavorite(host, session.id, favorite: true);
    await store.updateGhost(host, session);
    final favorite = (await store.getFavoriteSessions(host)).single;
    expect(favorite.providerId, 'work');
    expect(favorite.canonicalSessionId, session.id);
  });

  test('ownership adoption merges aliases and preserves favorites and cache across restart', () async {
    final store = SessionLocalStore.instance;
    final raw = _summary('native-id', updatedAt: DateTime.now(), title: 'Latest');
    final canonicalId = SessionAliases.wrap('work', raw.id);
    final legacyId = SessionAliases.wrap('copilot', raw.id);
    await store.upsertSessions(host, [raw, raw.copyWith(id: legacyId, title: 'Older',
      updatedAt: raw.updatedAt.subtract(const Duration(days: 1)))]);
    await store.setFavorite(host, legacyId, favorite: true);
    await store.saveSessionLog(host, _log(raw.id));
    final db = await SidemeshDb.instance;
    final before = await db.query('session_logs');
    const aliases = SessionAliases(rawProviderId: 'work', kinds: {'work': 'copilot', 'other': 'copilot'},
      aliases: {'work': 'work', 'other': 'other', 'copilot': 'work'});
    await db.execute("CREATE TRIGGER reject_alias BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT, 'fixture failure'); END");
    await expectLater(store.adoptSessionAliases(host, aliases), throwsA(isA<Exception>()));
    expect(SessionIdentityStore.instance.forHost(host.id), isNull);
    expect(await db.query('session_logs'), before);
    expect(await db.query('sessions'), hasLength(2));
    await db.execute('DROP TRIGGER reject_alias');
    await store.adoptSessionAliases(host, aliases);
    final recents = await store.getRecentSessions(host);
    expect(recents, hasLength(1));
    expect(recents.single.id, canonicalId);
    expect(recents.single.title, 'Latest');
    expect(recents.single.providerId, 'work');
    expect(store.isFavorite(host, raw.id), isTrue);
    expect(store.isFavorite(host, canonicalId), isTrue);
    expect((await store.loadSessionLog(host, legacyId))!.log.session.id, canonicalId);
    await store.upsertSessions(host, [raw]);
    expect((await db.query('sessions')).single['session_id'], canonicalId);
    await store.saveSessionLog(host, _log(legacyId));
    expect((await db.query('session_logs')).single['session_id'], canonicalId);
    await SidemeshDb.close();
    store.resetMigrationState();
    SessionIdentityStore.instance.resetForTest();
    await store.ensureLoaded();
    expect(store.isFavorite(host, raw.id), isTrue);
    expect((await store.getSession(host, legacyId))!.id, canonicalId);
    expect((await store.loadSessionLog(host, raw.id))!.log.session.id, canonicalId);
    await store.setFavorite(host, legacyId, favorite: false);
    expect(store.isFavorite(host, canonicalId), isFalse);
    await expectLater(store.adoptSessionAliases(host, const SessionAliases(
      rawProviderId: 'other', kinds: {'work': 'copilot', 'other': 'copilot'},
      aliases: {'work': 'work', 'other': 'other', 'copilot': 'other'},
    )), throwsStateError);
    expect(SessionIdentityStore.instance.canonical(host.id, raw.id), canonicalId);
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

  test('getRecentSessions hides sub-agent rows', () async {
    final store = SessionLocalStore.instance;
    final session = _summary(
      'session-child',
      updatedAt: DateTime.now(),
      isSubAgent: true,
      subAgent: const SessionSubAgentInfo(
        parentSessionId: 'session-parent',
        sourceKind: 'thread_spawn',
        agentRole: 'explorer',
        agentNickname: 'scout',
        depth: 1,
      ),
    );

    await store.upsertSessions(host, [session]);
    final recents = await store.getRecentSessions(host);

    expect(recents, isEmpty);
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

  test('favorite queries hide sub-agent ghosts', () async {
    final store = SessionLocalStore.instance;
    await store.toggleFavorite(host, 'session-child');

    final session = _summary(
      'session-child',
      updatedAt: DateTime.now(),
      isSubAgent: true,
      subAgent: const SessionSubAgentInfo(
        parentSessionId: 'session-parent',
        sourceKind: 'child_session',
        agentName: 'explore',
        agentDisplayName: 'Explore',
      ),
    );

    await store.updateGhost(host, session);
    final favorites = await store.getFavoriteSessions(host);

    expect(favorites, isEmpty);
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

  test(
    'ensureLoaded notifies listeners when persisted favorites are restored',
    () async {
      final store = SessionLocalStore.instance;
      final session = _summary('s1', updatedAt: DateTime.now());
      await store.upsertSessions(host, [session]);
      await store.toggleFavorite(host, 's1');

      store.resetMigrationState();
      var notifications = 0;
      void listener() {
        notifications += 1;
      }

      store.addListener(listener);
      addTearDown(() => store.removeListener(listener));

      await store.ensureLoaded();

      expect(store.isFavorite(host, 's1'), true);
      expect(notifications, 1);
    },
  );

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
          '[{"id":"old-s1","title":"Old","preview":"p","cwd":"/","createdAt":1700000000000,"updatedAt":1700000000000,"source":"sub-agent","provider":null,"status":"complete","runtime":null,"gitInfo":null,"isSubAgent":true,"subAgent":{"parentSessionId":"old-parent","sourceKind":"thread_spawn","agentRole":"explorer"}}]',
      'sidemesh_session_favorites_v1': ['host-1::old-fav'],
    });

    SessionLocalStore.instance.resetMigrationState();
    final store = SessionLocalStore.instance;
    final recents = await store.getRecentSessions(host);
    expect(recents, isEmpty);

    final favorites = await store.getFavoriteSessions(host);
    expect(favorites.length, 1);
    expect(favorites.first.id, 'old-fav');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('sidemesh_session_favorites_v1'), ['host-1::old-fav']);
    final db = await SidemeshDb.instance;
    expect(await db.query('client_migrations'), hasLength(1));
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
  test('schema upgrade retains sessions and creates durable client storage', () async {
    final store = SessionLocalStore.instance;
    await store.upsertSessions(host, [_summary('kept')]);
    final db = await SidemeshDb.instance;
    await db.execute('DROP TABLE session_logs');
    await db.execute('DROP TABLE session_outbox');
    await db.execute('DROP TABLE client_migrations');
    await db.execute('ALTER TABLE sessions DROP COLUMN provider_id');
    await db.execute('ALTER TABLE sessions DROP COLUMN canonical_session_id');
    await db.execute('PRAGMA user_version = 2');
    await SidemeshDb.close();
    store.resetMigrationState();
    expect((await store.getRecentSessions(host)).single.id, 'kept');
    final upgraded = await SidemeshDb.instance;
    expect((await upgraded.rawQuery('PRAGMA user_version')).single['user_version'], 4);
    expect(await upgraded.query('session_outbox'), isEmpty);
    await store.saveSessionLog(host, _log('kept'));
    expect(await store.loadSessionLog(host, 'kept'), isNotNull);
  });

  test('transactional import preserves favorite recents, logs, and original preferences', () async {
    final store = SessionLocalStore.instance;
    const colonHost = HostProfile(id: 'host:one', label: 'Host', baseUrl: 'http://localhost', token: 'test');
    final log = _log('session:one');
    final now = DateTime.now().millisecondsSinceEpoch;
    final original = jsonEncode({'cachedAt': now, 'log': log.toJson()});
    SharedPreferences.setMockInitialValues({
      'sidemesh_cached_recent_sessions_v1:host:one': jsonEncode([log.session.toJson()]),
      'sidemesh_session_favorites_v1': ['host:one::session:one'],
      'sidemesh_cached_session_log_v1:host:one:session:one': original,
    });
    final db = await SidemeshDb.instance;
    await db.execute("CREATE TRIGGER reject_log_import BEFORE INSERT ON session_logs BEGIN SELECT RAISE(ABORT, 'fixture failure'); END");
    await expectLater(store.ensureLoaded(), throwsA(isA<Exception>()));
    expect(await db.query('sessions'), isEmpty);
    expect(await db.query('client_migrations'), isEmpty);
    await db.execute('DROP TRIGGER reject_log_import');
    await store.ensureLoaded();
    expect(store.isFavorite(colonHost, log.session.id), isTrue);
    expect((await store.getRecentSessions(colonHost)).single.title, log.session.title);
    expect((await store.loadSessionLog(colonHost, log.session.id))!.log.messages.single.text, 'hello');
    expect((await SharedPreferences.getInstance()).getString('sidemesh_cached_session_log_v1:host:one:session:one'), original);
    await SidemeshDb.close();
    store.resetMigrationState();
    expect((await store.loadSessionLog(colonHost, log.session.id))!.log.session.id, log.session.id);
    await store.clearAll();
    store.resetMigrationState();
    expect(await store.loadSessionLog(colonHost, log.session.id), isNull);
    expect(await store.getFavoriteSessions(colonHost), isEmpty);
  });

  test('cached drafts survive serialization and corrupt or expired cache rows are replaced', () async {
    final store = SessionLocalStore.instance;
    final log = SessionLog(
      session: _summary('draft'), messages: const [], activities: const [],
      pendingAction: null, history: null, revision: 9,
      liveAssistantText: 'working', liveAssistantReasoning: 'thinking',
    );
    await store.saveSessionLog(host, log);
    final cached = (await store.loadSessionLog(host, 'draft'))!.log;
    expect(cached.liveAssistantText, 'working');
    expect(cached.liveAssistantReasoning, 'thinking');
    expect(cached.revision, 9);
    final db = await SidemeshDb.instance;
    await db.update('session_logs', {'payload': '{'});
    expect(await store.loadSessionLog(host, 'draft'), isNull);
    expect(await db.query('session_logs'), isEmpty);
    await store.saveSessionLog(host, log);
    await db.update('session_logs', {'cached_at': DateTime.now().subtract(const Duration(days: 15)).millisecondsSinceEpoch});
    expect(await store.loadSessionLog(host, 'draft'), isNull);
    await store.saveSessionLog(host, log);
    await store.clearHost(host);
    expect(await store.loadSessionLog(host, 'draft'), isNull);
  });

  test('log cache keeps the 20 most recently used rows', () async {
    final store = SessionLocalStore.instance;
    for (var i = 0; i < 20; i += 1) {
      await store.saveSessionLog(host, _log('session-$i'));
    }
    final db = await SidemeshDb.instance;
    await db.update('session_logs', {'last_used_at': 0});
    await store.loadSessionLog(host, 'session-0');
    await store.saveSessionLog(host, _log('session-new'));
    expect(await db.query('session_logs'), hasLength(20));
    expect(await store.loadSessionLog(host, 'session-0'), isNotNull);
    expect(await store.loadSessionLog(host, 'session-1'), isNull);
  });

}

SessionSummary _summary(
  String id, {
  String title = 'Session',
  DateTime? updatedAt,
  bool isSubAgent = false,
  SessionSubAgentInfo? subAgent,
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
    isSubAgent: isSubAgent,
    subAgent: subAgent,
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
