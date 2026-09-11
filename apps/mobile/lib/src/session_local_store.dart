import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'models.dart';
import 'session_identity.dart';
import 'session_identity_store.dart';

class CachedSessionLog {
  const CachedSessionLog({required this.log, required this.cachedAt});

  final SessionLog log;
  final DateTime cachedAt;
}

/// Replaces [SessionCacheStore] and [SessionFavoritesStore] with an
/// SQLite-backed local store. Favorites are kept in-memory after first
/// load so [isFavorite] remains synchronous for UI sorting.
class SessionLocalStore extends ChangeNotifier {
  SessionLocalStore._();

  static final SessionLocalStore instance = SessionLocalStore._();

  bool _migrated = false;
  Future<void>? _migrationFuture;
  Future<void>? _operationQueue;
  int _pendingOperationCount = 0;
  Completer<void>? _idleCompleter;

  @visibleForTesting
  void resetMigrationState() {
    _migrated = false;
    _migrationFuture = null;
    _favoritesLoaded = false;
    _favoritesLoadFuture = null;
    _favoriteKeys.clear();
    _operationQueue = null;
    _pendingOperationCount = 0;
    _idleCompleter = null;
  }

  final Set<String> _favoriteKeys = <String>{};
  bool _favoritesLoaded = false;
  Future<void>? _favoritesLoadFuture;

  Future<void> _ensureMigrated() async {
    if (_migrated) return;
    await SessionIdentityStore.instance.ensureLoaded();
    final migrationFuture = _migrationFuture;
    if (migrationFuture != null) {
      await migrationFuture;
      return;
    }

    final future = _migrateFromSharedPreferences();
    _migrationFuture = future;
    try {
      await future;
      _migrated = true;
    } finally {
      if (identical(_migrationFuture, future)) {
        _migrationFuture = null;
      }
    }
  }

  String _favoriteKey(String hostId, String sessionId) =>
      '$hostId::${SessionIdentityStore.instance.canonical(hostId, sessionId)}';

  Future<void> adoptSessionAliases(HostProfile host, SessionAliases aliases) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final identities = SessionIdentityStore.instance;
      final previous = identities.forHost(host.id);
      if (jsonEncode(previous?.toJson()) == jsonEncode(aliases.toJson())) return;
      if (previous != null && (previous.rawProviderId != aliases.rawProviderId ||
          previous.aliases.entries.any((entry) => aliases.aliases[entry.key] != entry.value) ||
          previous.kinds.entries.any((entry) => aliases.kinds[entry.key] != entry.value))) {
        throw StateError('Host session ownership changed. Remove and pair this host again.');
      }
      final db = await SidemeshDb.instance;
      await db.transaction((txn) async {
        final rows = await txn.query('sessions', where: 'host_id = ?', whereArgs: [host.id],
          orderBy: 'updated_at DESC, cached_at DESC');
        final merged = <String, Map<String, Object?>>{};
        for (final row in rows) {
          final resolved = aliases.resolve(row['session_id'] as String);
          final id = resolved?.sessionId ?? row['session_id'] as String;
          final existing = merged[id];
          if (existing == null) {
            merged[id] = {...row, 'session_id': id,
              if (resolved != null) ...{
                'canonical_session_id': id, 'provider_id': resolved.providerId,
                'provider': aliases.kinds[resolved.providerId],
              },
            };
          } else {
            if (row['is_favorite'] == 1) existing['is_favorite'] = 1;
            if (row['source'] == 'recent') existing['source'] = 'recent';
          }
        }
        await txn.delete('sessions', where: 'host_id = ?', whereArgs: [host.id]);
        for (final row in merged.values) {
          await txn.insert('sessions', row);
        }
        final logs = await txn.query('session_logs', where: 'host_id = ?', whereArgs: [host.id],
          orderBy: 'cached_at DESC');
        final seen = <String>{};
        for (final row in logs) {
          final oldId = row['session_id'] as String;
          final resolved = aliases.resolve(oldId);
          if (resolved == null) continue;
          final id = resolved.sessionId;
          if (seen.contains(id)) {
            if (oldId != id) {
              await txn.delete('session_logs',
                where: 'host_id = ? AND session_id = ?', whereArgs: [host.id, oldId]);
            }
            continue;
          }
          Map<String, dynamic> payload;
          try {
            payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
            final session = payload['session'] as Map<String, dynamic>;
            if (session['id'] != oldId) continue;
            payload['session'] = {...session, 'id': id, 'canonicalSessionId': id,
              'providerId': resolved.providerId, 'provider': aliases.kinds[resolved.providerId]};
          } catch (_) {
            continue;
          }
          seen.add(id);
          if (oldId != id) {
            await txn.delete('session_logs',
              where: 'host_id = ? AND session_id = ?', whereArgs: [host.id, oldId]);
          }
          await txn.insert('session_logs', {...row, 'session_id': id, 'payload': jsonEncode(payload)},
            conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
      await identities.save(host.id, aliases);
      _favoriteKeys.removeWhere((key) => key.startsWith('${host.id}::'));
      final favorites = await db.query('sessions', columns: ['session_id'],
        where: 'host_id = ? AND is_favorite = 1', whereArgs: [host.id]);
      for (final row in favorites) {
        _favoriteKeys.add(_favoriteKey(host.id, row['session_id'] as String));
      }
      notifyListeners();
    });
  }

  SessionSummary _canonicalSession(String hostId, SessionSummary session) {
    final resolved = SessionIdentityStore.instance.forHost(hostId)?.resolve(session.id);
    return resolved == null ? session : session.copyWith(
      id: resolved.sessionId, canonicalSessionId: resolved.sessionId, providerId: resolved.providerId,
    );
  }

  Future<T> _trackOperation<T>(Future<T> Function() action) {
    _pendingOperationCount += 1;
    _idleCompleter ??= Completer<void>();
    final previous = _operationQueue;
    final queued = previous == null
        ? Future<T>.sync(action)
        : previous.catchError((error) {}).then<T>((_) => action());
    _operationQueue = queued.then<void>((_) {}, onError: (error, stackTrace) {});
    return queued.whenComplete(() {
      _pendingOperationCount -= 1;
      if (_pendingOperationCount == 0) {
        _operationQueue = null;
        _idleCompleter?.complete();
        _idleCompleter = null;
      }
    });
  }

  @visibleForTesting
  Future<void> waitForIdle() async {
    final completer = _idleCompleter;
    if (_pendingOperationCount == 0 || completer == null) {
      return;
    }
    await completer.future;
  }

  Future<void> ensureLoaded() {
    return _trackOperation(() async {
      await _ensureFavoritesLoaded();
    });
  }

  Future<void> _ensureFavoritesLoaded() async {
    if (_favoritesLoaded) return;
    final favoritesLoadFuture = _favoritesLoadFuture;
    if (favoritesLoadFuture != null) {
      await favoritesLoadFuture;
      return;
    }

    final future = () async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      final rows = await db.rawQuery(
        'SELECT host_id, session_id FROM sessions WHERE is_favorite = 1',
      );
      _favoriteKeys.clear();
      for (final row in rows) {
        final hostId = row['host_id'] as String;
        final sessionId = row['session_id'] as String;
        _favoriteKeys.add(_favoriteKey(hostId, sessionId));
      }
      _favoritesLoaded = true;
      notifyListeners();
    }();
    _favoritesLoadFuture = future;
    try {
      await future;
    } finally {
      if (identical(_favoritesLoadFuture, future)) {
        _favoritesLoadFuture = null;
      }
    }
  }

  // ─── Favorites (sync read, async write) ───

  bool isFavorite(HostProfile host, String sessionId) {
    return _favoriteKeys.contains(_favoriteKey(host.id, sessionId));
  }

  Future<bool> toggleFavorite(HostProfile host, String sessionId) {
    return _trackOperation(() async {
      await _ensureFavoritesLoaded();
      sessionId = SessionIdentityStore.instance.canonical(host.id, sessionId);
      final key = _favoriteKey(host.id, sessionId);
      final current = _favoriteKeys.contains(key);
      final next = !current;
      await _persistFavoriteFlag(host, sessionId, favorite: next);
      if (next) {
        _favoriteKeys.add(key);
      } else {
        _favoriteKeys.remove(key);
      }
      notifyListeners();
      return next;
    });
  }

  Future<void> setFavorite(
    HostProfile host,
    String sessionId, {
    required bool favorite,
  }) {
    return _trackOperation(() async {
      await _ensureFavoritesLoaded();
      sessionId = SessionIdentityStore.instance.canonical(host.id, sessionId);
      final key = _favoriteKey(host.id, sessionId);
      final current = _favoriteKeys.contains(key);
      if (current == favorite) return;
      await _persistFavoriteFlag(host, sessionId, favorite: favorite);
      if (favorite) {
        _favoriteKeys.add(key);
      } else {
        _favoriteKeys.remove(key);
      }
      notifyListeners();
    });
  }

  Future<void> _persistFavoriteFlag(
    HostProfile host,
    String sessionId, {
    required bool favorite,
  }) async {
    final db = await SidemeshDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (favorite) {
      await db.rawInsert(
        '''
        INSERT INTO sessions (
          host_id, session_id, title, preview, cwd, status,
          created_at, updated_at, is_sub_agent, sub_agent_json,
          is_favorite, source, cached_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, 1, 'favorite', ?)
        ON CONFLICT(host_id, session_id) DO UPDATE SET
          is_favorite = 1
      ''',
        [host.id, sessionId, 'Unknown', '', '', 'unknown', 0, 0, now],
      );
      return;
    }
    await db.update(
      'sessions',
      {'is_favorite': 0},
      where: 'host_id = ? AND session_id = ?',
      whereArgs: [host.id, sessionId],
    );
    await db.delete(
      'sessions',
      where: "host_id = ? AND session_id = ? AND source = 'favorite'",
      whereArgs: [host.id, sessionId],
    );
  }

  Future<List<SessionSummary>> getFavoriteSessions(HostProfile host) {
    return _trackOperation(() async {
      await _ensureFavoritesLoaded();
      final db = await SidemeshDb.instance;
      final rows = await db.rawQuery(
        'SELECT * FROM sessions WHERE host_id = ? AND is_favorite = 1 AND is_sub_agent = 0 ORDER BY updated_at DESC',
        [host.id],
      );
      return rows.map(_rowToSession).toList(growable: false);
    });
  }

  /// Returns ghost metadata for favorited sessions that are not in the recent list.
  Future<List<SessionSummary>> ghostsForHost(HostProfile host) {
    return _trackOperation(() async {
      await _ensureFavoritesLoaded();
      final db = await SidemeshDb.instance;
      final rows = await db.rawQuery(
        """
          SELECT * FROM sessions
          WHERE host_id = ? AND is_favorite = 1 AND source = 'favorite'
            AND is_sub_agent = 0
          ORDER BY updated_at DESC
        """,
        [host.id],
      );
      return rows.map(_rowToSession).toList(growable: false);
    });
  }

  /// Updates ghost metadata for a session when we receive fresh server data.
  Future<void> updateGhost(HostProfile host, SessionSummary session) {
    return _trackOperation(() async {
      await _ensureFavoritesLoaded();
      session = _canonicalSession(host.id, session);
      if (!isFavorite(host, session.id)) return;
      final db = await SidemeshDb.instance;
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.rawInsert(
      '''
      INSERT INTO sessions (
        host_id, session_id, title, preview, cwd, provider, provider_id, canonical_session_id, status,
        created_at, updated_at, runtime_json, git_info_json,
        is_sub_agent, sub_agent_json,
        is_favorite, source, cached_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'favorite', ?)
      ON CONFLICT(host_id, session_id) DO UPDATE SET
        title = excluded.title,
        preview = excluded.preview,
        cwd = excluded.cwd,
        provider = excluded.provider,
        provider_id = excluded.provider_id,
        canonical_session_id = excluded.canonical_session_id,
        status = excluded.status,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at,
        runtime_json = excluded.runtime_json,
        git_info_json = excluded.git_info_json,
        is_sub_agent = excluded.is_sub_agent,
        sub_agent_json = excluded.sub_agent_json,
        source = excluded.source,
        cached_at = excluded.cached_at
    ''',
      [
        host.id,
        session.id,
        session.title,
        session.preview,
        session.cwd,
        session.provider,
        session.providerId,
        session.canonicalSessionId,
        session.status,
        session.createdAt.millisecondsSinceEpoch,
        session.updatedAt.millisecondsSinceEpoch,
        session.runtime != null ? jsonEncode(session.runtime!.toJson()) : null,
        session.gitInfo != null ? jsonEncode(session.gitInfo!.toJson()) : null,
        session.isSubAgent ? 1 : 0,
        _encodeSubAgentInfo(session.subAgent),
        now,
      ],
    );
    });
  }

  // ─── Session cache (SQLite) ───

  Future<void> upsertSessions(
    HostProfile host,
    List<SessionSummary> sessions, {
    String source = 'recent',
  }) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      sessions = sessions.map((session) => _canonicalSession(host.id, session)).toList();
      final batch = db.batch();
      final now = DateTime.now().millisecondsSinceEpoch;
    for (final s in sessions) {
      batch.execute(
        '''
        INSERT INTO sessions (
          host_id, session_id, title, preview, cwd, provider, provider_id, canonical_session_id, status,
          created_at, updated_at, runtime_json, git_info_json,
          is_sub_agent, sub_agent_json,
          is_favorite, source, cached_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(host_id, session_id) DO UPDATE SET
          title = excluded.title,
          preview = excluded.preview,
          cwd = excluded.cwd,
          provider = excluded.provider,
          provider_id = excluded.provider_id,
          canonical_session_id = excluded.canonical_session_id,
          status = excluded.status,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at,
          runtime_json = excluded.runtime_json,
          git_info_json = excluded.git_info_json,
          is_sub_agent = excluded.is_sub_agent,
          sub_agent_json = excluded.sub_agent_json,
          source = excluded.source,
          cached_at = excluded.cached_at
      ''',
        [
          host.id,
          s.id,
          s.title,
          s.preview,
          s.cwd,
          s.provider,
          s.providerId,
          s.canonicalSessionId,
          s.status,
          s.createdAt.millisecondsSinceEpoch,
          s.updatedAt.millisecondsSinceEpoch,
          s.runtime != null ? jsonEncode(s.runtime!.toJson()) : null,
          s.gitInfo != null ? jsonEncode(s.gitInfo!.toJson()) : null,
          s.isSubAgent ? 1 : 0,
          _encodeSubAgentInfo(s.subAgent),
          0,
          source,
          now,
        ],
      );
    }
    if (source == 'recent') {
      final sessionIds = sessions
          .map((session) => session.id)
          .toSet()
          .toList(growable: false);
      if (sessionIds.isEmpty) {
        batch.execute(
          '''
          UPDATE sessions
          SET source = 'favorite', cached_at = ?
          WHERE host_id = ? AND source = 'recent' AND is_favorite = 1
        ''',
          [now, host.id],
        );
        batch.delete(
          'sessions',
          where: "host_id = ? AND source = 'recent' AND is_favorite = 0",
          whereArgs: [host.id],
        );
      } else {
        final placeholders = List.filled(sessionIds.length, '?').join(', ');
        batch.execute(
          '''
          UPDATE sessions
          SET source = 'favorite', cached_at = ?
          WHERE host_id = ? AND source = 'recent' AND is_favorite = 1
            AND session_id NOT IN ($placeholders)
        ''',
          [now, host.id, ...sessionIds],
        );
        batch.delete(
          'sessions',
          where:
              "host_id = ? AND source = 'recent' AND is_favorite = 0 "
              "AND session_id NOT IN ($placeholders)",
          whereArgs: [host.id, ...sessionIds],
        );
      }
    }
    await batch.commit(noResult: true);
    });
  }

  Future<List<SessionSummary>> getRecentSessions(
    HostProfile host, {
    int limit = 40,
  }) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      final rows = await db.rawQuery(
        "SELECT * FROM sessions WHERE host_id = ? AND source = 'recent' AND is_sub_agent = 0 ORDER BY updated_at DESC LIMIT ?",
        [host.id, limit],
      );
      return rows.map(_rowToSession).toList(growable: false);
    });
  }

  Future<SessionSummary?> getSession(HostProfile host, String sessionId) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      sessionId = SessionIdentityStore.instance.canonical(host.id, sessionId);
      final rows = await db.rawQuery(
        'SELECT * FROM sessions WHERE host_id = ? AND session_id = ?',
        [host.id, sessionId],
      );
      if (rows.isEmpty) return null;
      return _rowToSession(rows.first);
    });
  }

  Future<void> clearHost(HostProfile host) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      await db.transaction((txn) async {
        await txn.delete('sessions', where: 'host_id = ?', whereArgs: [host.id]);
        await txn.delete('session_logs', where: 'host_id = ?', whereArgs: [host.id]);
      });
      _favoriteKeys.removeWhere((key) => key.startsWith('${host.id}::'));
      await SessionIdentityStore.instance.save(host.id, null);
    });
  }

  Future<void> pruneOldSessions(HostProfile host, Duration ttl) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      final cutoff = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
      await db.delete(
        'sessions',
        where: 'host_id = ? AND is_favorite = 0 AND updated_at < ?',
        whereArgs: [host.id, cutoff],
      );
    });
  }

  Future<void> deleteSession(HostProfile host, String sessionId) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      sessionId = SessionIdentityStore.instance.canonical(host.id, sessionId);
      await db.delete(
        'sessions',
        where: 'host_id = ? AND session_id = ?',
        whereArgs: [host.id, sessionId],
      );
      _favoriteKeys.remove(_favoriteKey(host.id, sessionId));
    });
  }

  SessionSummary _rowToSession(Map<String, Object?> row) {
    final runtimeJson = row['runtime_json'] as String?;
    final gitInfoJson = row['git_info_json'] as String?;
    final subAgentJson = row['sub_agent_json'] as String?;
    final isSubAgent = ((row['is_sub_agent'] as int?) ?? 0) != 0;
    return SessionSummary(
      id: row['session_id'] as String,
      title: row['title'] as String,
      preview: row['preview'] as String,
      cwd: row['cwd'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      source: row['source'] as String,
      provider: row['provider'] as String?,
      providerId: row['provider_id'] as String?,
      canonicalSessionId: row['canonical_session_id'] as String?,
      status: row['status'] as String,
      runtime: runtimeJson != null
          ? SessionRuntimeSummary.fromJson(
              jsonDecode(runtimeJson) as Map<String, dynamic>,
            )
          : null,
      gitInfo: gitInfoJson != null
          ? GitInfoSummary.fromJson(
              jsonDecode(gitInfoJson) as Map<String, dynamic>,
            )
          : null,
      isSubAgent: isSubAgent || subAgentJson != null,
      subAgent: _decodeSubAgentInfo(subAgentJson),
    );
  }

  // ─── Session log cache ───

  static const _logPrefix = 'sidemesh_cached_session_log_v1';
  static const _maxSessionLogCacheChars = 2 * 1024 * 1024;
  static const _maxSessionLogEntries = 20;
  static const _sessionLogTtl = Duration(days: 14);

  Future<CachedSessionLog?> loadSessionLog(
    HostProfile host,
    String sessionId,
  ) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      sessionId = SessionIdentityStore.instance.canonical(host.id, sessionId);
      final rows = await db.query('session_logs',
        where: 'host_id = ? AND session_id = ?', whereArgs: [host.id, sessionId]);
      if (rows.isEmpty) return null;
      final row = rows.single;
      CachedSessionLog? cached;
      try {
        final cachedAt = DateTime.fromMillisecondsSinceEpoch(row['cached_at'] as int);
        if (DateTime.now().difference(cachedAt) <= _sessionLogTtl) {
          final log = SessionLog.fromJson(jsonDecode(row['payload'] as String) as Map<String, dynamic>);
          if (log.session.id == sessionId) cached = CachedSessionLog(log: log, cachedAt: cachedAt);
        }
      } catch (_) {
        // A cache can be replaced by the next complete server snapshot.
      }
      if (cached == null) {
        await db.delete('session_logs',
          where: 'host_id = ? AND session_id = ?', whereArgs: [host.id, sessionId]);
      } else {
        await db.update('session_logs', {'last_used_at': DateTime.now().millisecondsSinceEpoch},
          where: 'host_id = ? AND session_id = ?', whereArgs: [host.id, sessionId]);
      }
      return cached;
    });
  }

  Future<void> saveSessionLog(HostProfile host, SessionLog log) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      final payload = log.toJson();
      final session = _canonicalSession(host.id, log.session);
      payload['session'] = session.toJson();
      final encoded = jsonEncode(payload);
      if (encoded.length > _maxSessionLogCacheChars) {
        await db.delete('session_logs', where: 'host_id = ? AND session_id = ?',
          whereArgs: [host.id, session.id]);
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.transaction((txn) async {
        await txn.insert('session_logs', {
          'host_id': host.id, 'session_id': session.id,
          'cached_at': now, 'last_used_at': now, 'payload': encoded,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await _pruneLogCache(txn);
      });
    });
  }

  Future<void> clearHostLogs(HostProfile host) {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      await db.delete('session_logs', where: 'host_id = ?', whereArgs: [host.id]);
    });
  }

  Future<void> clearAll() {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      await db.transaction((txn) async {
        await txn.delete('sessions');
        await txn.delete('session_logs');
      });
      _favoriteKeys.clear();
      notifyListeners();
    });
  }

  Future<void> clearAllLogs() {
    return _trackOperation(() async {
      await _ensureMigrated();
      final db = await SidemeshDb.instance;
      await db.delete('session_logs');
    });
  }

  Future<void> _pruneLogCache(DatabaseExecutor db) async {
    await db.delete('session_logs', where: 'cached_at < ?',
      whereArgs: [DateTime.now().subtract(_sessionLogTtl).millisecondsSinceEpoch]);
    await db.execute(
      'DELETE FROM session_logs WHERE rowid NOT IN '
      '(SELECT rowid FROM session_logs ORDER BY last_used_at DESC, rowid DESC LIMIT ?)',
      [_maxSessionLogEntries],
    );
  }

  // ─── Transactional import; preferences remain as the original backup ───

  Future<void> _migrateFromSharedPreferences() async {
    final db = await SidemeshDb.instance;
    final prefs = await SharedPreferences.getInstance();
    const migration = 'session-cache-prefs-v1';
    await db.transaction((txn) async {
      if ((await txn.query('client_migrations',
        where: 'name = ?', whereArgs: [migration])).isNotEmpty) {
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (prefs.getBool('sidemesh_sqflite_migrated_v1') != true) {
        const recentPrefix = 'sidemesh_cached_recent_sessions_v1:';
        for (final key in prefs.getKeys().where((key) => key.startsWith(recentPrefix))) {
          final hostId = key.substring(recentPrefix.length);
          if (hostId.isEmpty) continue;
          List<SessionSummary> sessions;
          try {
            sessions = (jsonDecode(prefs.getString(key)!) as List)
                .map((item) => SessionSummary.fromJson(item as Map<String, dynamic>)).toList();
          } catch (_) {
            continue;
          }
          for (final original in sessions) {
            final session = _canonicalSession(hostId, original);
            if (session.id.isEmpty) continue;
            await txn.insert('sessions', {
              'host_id': hostId, 'session_id': session.id,
              'title': session.title, 'preview': session.preview, 'cwd': session.cwd,
              'provider': session.provider, 'provider_id': session.providerId,
              'canonical_session_id': session.canonicalSessionId, 'status': session.status,
              'created_at': session.createdAt.millisecondsSinceEpoch,
              'updated_at': session.updatedAt.millisecondsSinceEpoch,
              'runtime_json': session.runtime == null ? null : jsonEncode(session.runtime!.toJson()),
              'git_info_json': session.gitInfo == null ? null : jsonEncode(session.gitInfo!.toJson()),
              'is_sub_agent': session.isSubAgent ? 1 : 0,
              'sub_agent_json': _encodeSubAgentInfo(session.subAgent),
              'source': 'recent', 'cached_at': now,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
        for (final key in prefs.getStringList('sidemesh_session_favorites_v1') ?? const <String>[]) {
          final separator = key.indexOf('::');
          if (separator <= 0 || separator + 2 >= key.length) continue;
          await txn.rawInsert(
            "INSERT INTO sessions (host_id, session_id, title, preview, cwd, status, "
            "created_at, updated_at, is_favorite, source, cached_at) "
            "VALUES (?, ?, 'Unknown', '', '', 'unknown', 0, 0, 1, 'favorite', ?) "
            "ON CONFLICT(host_id, session_id) DO UPDATE SET is_favorite = 1",
            [key.substring(0, separator), SessionIdentityStore.instance.canonical(key.substring(0, separator), key.substring(separator + 2)), now],
          );
        }
      }
      final lastUsed = <String, int>{};
      try {
        final index = jsonDecode(prefs.getString('sidemesh_cached_session_log_index_v1') ?? '[]') as List;
        for (final item in index.whereType<Map<String, dynamic>>()) {
          if (item['key'] is String && item['lastUsedAt'] is int) {
            lastUsed[item['key'] as String] = item['lastUsedAt'] as int;
          }
        }
      } catch (_) {
        // Cache timestamps also provide a valid order if the old index is corrupt.
      }
      for (final key in prefs.getKeys().where((key) => key.startsWith('$_logPrefix:'))) {
        Map<String, Object?> row;
        try {
          final decoded = jsonDecode(prefs.getString(key)!) as Map<String, dynamic>;
          final log = SessionLog.fromJson(decoded['log'] as Map<String, dynamic>);
          final cachedAt = decoded['cachedAt'] as int;
          final suffix = ':${log.session.id}';
          if (log.session.id.isEmpty || !key.endsWith(suffix)) continue;
          final hostId = key.substring(_logPrefix.length + 1, key.length - suffix.length);
          final session = _canonicalSession(hostId, log.session);
          final encoded = jsonEncode({...log.toJson(), 'session': session.toJson()});
          if (hostId.isEmpty || encoded.length > _maxSessionLogCacheChars) continue;
          row = {
            'host_id': hostId, 'session_id': session.id, 'cached_at': cachedAt,
            'last_used_at': lastUsed[key] ?? cachedAt, 'payload': encoded,
          };
        } catch (_) {
          continue;
        }
        await txn.insert('session_logs', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await _pruneLogCache(txn);
      await txn.insert('client_migrations', {'name': migration});
    });
  }
}

String? _encodeSubAgentInfo(SessionSubAgentInfo? subAgent) {
  if (subAgent == null) {
    return null;
  }
  return jsonEncode(subAgent.toJson());
}

SessionSubAgentInfo? _decodeSubAgentInfo(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    return SessionSubAgentInfo.fromJson(decoded.cast<String, dynamic>());
  } catch (_) {
    return null;
  }
}
