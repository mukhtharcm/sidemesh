import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';
import 'models.dart';

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

  @visibleForTesting
  void resetMigrationState() {
    _migrated = false;
    _migrationFuture = null;
    _favoritesLoaded = false;
    _favoritesLoadFuture = null;
    _favoriteKeys.clear();
  }

  final Set<String> _favoriteKeys = <String>{};
  bool _favoritesLoaded = false;
  Future<void>? _favoritesLoadFuture;

  Future<void> _ensureMigrated() async {
    if (_migrated) return;
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

  String _favoriteKey(String hostId, String sessionId) => '$hostId::$sessionId';

  Future<void> ensureLoaded() async {
    await _ensureFavoritesLoaded();
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

  Future<bool> toggleFavorite(HostProfile host, String sessionId) async {
    await _ensureFavoritesLoaded();
    final key = _favoriteKey(host.id, sessionId);
    final current = _favoriteKeys.contains(key);
    final next = !current;
    if (next) {
      _favoriteKeys.add(key);
    } else {
      _favoriteKeys.remove(key);
    }
    await _persistFavoriteFlag(host, sessionId, favorite: next);
    notifyListeners();
    return next;
  }

  Future<void> setFavorite(
    HostProfile host,
    String sessionId, {
    required bool favorite,
  }) async {
    await _ensureFavoritesLoaded();
    final key = _favoriteKey(host.id, sessionId);
    final current = _favoriteKeys.contains(key);
    if (current == favorite) return;
    if (favorite) {
      _favoriteKeys.add(key);
    } else {
      _favoriteKeys.remove(key);
    }
    await _persistFavoriteFlag(host, sessionId, favorite: favorite);
    notifyListeners();
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
          created_at, updated_at, is_favorite, source, cached_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 'favorite', ?)
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

  Future<List<SessionSummary>> getFavoriteSessions(HostProfile host) async {
    await _ensureFavoritesLoaded();
    final db = await SidemeshDb.instance;
    final rows = await db.rawQuery(
      'SELECT * FROM sessions WHERE host_id = ? AND is_favorite = 1 ORDER BY updated_at DESC',
      [host.id],
    );
    return rows.map(_rowToSession).toList(growable: false);
  }

  /// Returns ghost metadata for favorited sessions that are not in the recent list.
  Future<List<SessionSummary>> ghostsForHost(HostProfile host) async {
    await _ensureFavoritesLoaded();
    final db = await SidemeshDb.instance;
    final rows = await db.rawQuery(
      """
        SELECT * FROM sessions
        WHERE host_id = ? AND is_favorite = 1 AND source = 'favorite'
        ORDER BY updated_at DESC
      """,
      [host.id],
    );
    return rows.map(_rowToSession).toList(growable: false);
  }

  /// Updates ghost metadata for a session when we receive fresh server data.
  Future<void> updateGhost(HostProfile host, SessionSummary session) async {
    await _ensureFavoritesLoaded();
    if (!isFavorite(host, session.id)) return;
    final db = await SidemeshDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.rawInsert(
      '''
      INSERT INTO sessions (
        host_id, session_id, title, preview, cwd, provider, status,
        created_at, updated_at, runtime_json, git_info_json,
        is_favorite, source, cached_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'favorite', ?)
      ON CONFLICT(host_id, session_id) DO UPDATE SET
        title = excluded.title,
        preview = excluded.preview,
        cwd = excluded.cwd,
        provider = excluded.provider,
        status = excluded.status,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at,
        runtime_json = excluded.runtime_json,
        git_info_json = excluded.git_info_json,
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
        session.status,
        session.createdAt.millisecondsSinceEpoch,
        session.updatedAt.millisecondsSinceEpoch,
        session.runtime != null ? jsonEncode(session.runtime!.toJson()) : null,
        session.gitInfo != null ? jsonEncode(session.gitInfo!.toJson()) : null,
        now,
      ],
    );
  }

  // ─── Session cache (SQLite) ───

  Future<void> upsertSessions(
    HostProfile host,
    List<SessionSummary> sessions, {
    String source = 'recent',
  }) async {
    await _ensureMigrated();
    final db = await SidemeshDb.instance;
    final batch = db.batch();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final s in sessions) {
      batch.execute(
        '''
        INSERT INTO sessions (
          host_id, session_id, title, preview, cwd, provider, status,
          created_at, updated_at, runtime_json, git_info_json,
          is_favorite, source, cached_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(host_id, session_id) DO UPDATE SET
          title = excluded.title,
          preview = excluded.preview,
          cwd = excluded.cwd,
          provider = excluded.provider,
          status = excluded.status,
          created_at = excluded.created_at,
          updated_at = excluded.updated_at,
          runtime_json = excluded.runtime_json,
          git_info_json = excluded.git_info_json,
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
          s.status,
          s.createdAt.millisecondsSinceEpoch,
          s.updatedAt.millisecondsSinceEpoch,
          s.runtime != null ? jsonEncode(s.runtime!.toJson()) : null,
          s.gitInfo != null ? jsonEncode(s.gitInfo!.toJson()) : null,
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
  }

  Future<List<SessionSummary>> getRecentSessions(
    HostProfile host, {
    int limit = 40,
  }) async {
    await _ensureMigrated();
    final db = await SidemeshDb.instance;
    final rows = await db.rawQuery(
      "SELECT * FROM sessions WHERE host_id = ? AND source = 'recent' ORDER BY updated_at DESC LIMIT ?",
      [host.id, limit],
    );
    return rows.map(_rowToSession).toList(growable: false);
  }

  Future<SessionSummary?> getSession(HostProfile host, String sessionId) async {
    await _ensureMigrated();
    final db = await SidemeshDb.instance;
    final rows = await db.rawQuery(
      'SELECT * FROM sessions WHERE host_id = ? AND session_id = ?',
      [host.id, sessionId],
    );
    if (rows.isEmpty) return null;
    return _rowToSession(rows.first);
  }

  Future<void> clearHost(HostProfile host) async {
    await _ensureMigrated();
    final db = await SidemeshDb.instance;
    await db.delete('sessions', where: 'host_id = ?', whereArgs: [host.id]);
    _favoriteKeys.removeWhere((key) => key.startsWith('${host.id}::'));
  }

  Future<void> pruneOldSessions(HostProfile host, Duration ttl) async {
    await _ensureMigrated();
    final db = await SidemeshDb.instance;
    final cutoff = DateTime.now().subtract(ttl).millisecondsSinceEpoch;
    await db.delete(
      'sessions',
      where: 'host_id = ? AND is_favorite = 0 AND updated_at < ?',
      whereArgs: [host.id, cutoff],
    );
  }

  Future<void> deleteSession(HostProfile host, String sessionId) async {
    await _ensureMigrated();
    final db = await SidemeshDb.instance;
    await db.delete(
      'sessions',
      where: 'host_id = ? AND session_id = ?',
      whereArgs: [host.id, sessionId],
    );
    _favoriteKeys.remove(_favoriteKey(host.id, sessionId));
  }

  SessionSummary _rowToSession(Map<String, Object?> row) {
    final runtimeJson = row['runtime_json'] as String?;
    final gitInfoJson = row['git_info_json'] as String?;
    return SessionSummary(
      id: row['session_id'] as String,
      title: row['title'] as String,
      preview: row['preview'] as String,
      cwd: row['cwd'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      source: row['source'] as String,
      provider: row['provider'] as String?,
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
    );
  }

  // ─── Session log cache (SharedPreferences — small data, best-effort) ───

  static const _logPrefix = 'sidemesh_cached_session_log_v1';
  static const _logIndexKey = 'sidemesh_cached_session_log_index_v1';
  static const _maxSessionLogCacheChars = 2 * 1024 * 1024;
  static const _maxSessionLogEntries = 20;
  static const _sessionLogTtl = Duration(days: 14);

  Future<CachedSessionLog?> loadSessionLog(
    HostProfile host,
    String sessionId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _logKey(host, sessionId);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final cachedAtMs = decoded['cachedAt'];
      final logJson = decoded['log'];
      if (cachedAtMs is! int || logJson is! Map<String, dynamic>) return null;
      final cachedAt = DateTime.fromMillisecondsSinceEpoch(cachedAtMs);
      if (DateTime.now().difference(cachedAt) > _sessionLogTtl) {
        await prefs.remove(key);
        await _removeLogIndexEntry(prefs, key);
        return null;
      }
      final log = SessionLog.fromJson(logJson);
      await _touchLogIndex(prefs, key);
      return CachedSessionLog(log: log, cachedAt: cachedAt);
    } catch (_) {
      await prefs.remove(key);
      await _removeLogIndexEntry(prefs, key);
      return null;
    }
  }

  Future<void> saveSessionLog(HostProfile host, SessionLog log) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode({
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
      'log': log.toJson(),
    });
    final key = _logKey(host, log.session.id);
    if (encoded.length > _maxSessionLogCacheChars) {
      await prefs.remove(key);
      await _removeLogIndexEntry(prefs, key);
      return;
    }
    await prefs.setString(key, encoded);
    final now = DateTime.now();
    await _updateLogIndex(prefs, key, cachedAt: now, lastUsedAt: now);
  }

  Future<void> clearHostLogs(HostProfile host) async {
    final prefs = await SharedPreferences.getInstance();
    final logPrefix = '$_logPrefix:${host.id}';
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (key.startsWith('$logPrefix:')) {
        await prefs.remove(key);
      }
    }
    final index = await _loadLogIndex(prefs);
    final filtered = index
        .where((entry) => !entry.key.startsWith('$logPrefix:'))
        .toList(growable: false);
    await _saveLogIndex(prefs, filtered);
  }

  Future<void> clearAll() async {
    await _ensureMigrated();
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
    _favoriteKeys.clear();
    await clearAllLogs();
  }

  Future<void> clearAllLogs() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (key.startsWith('$_logPrefix:')) {
        await prefs.remove(key);
      }
    }
    await prefs.remove(_logIndexKey);
  }

  String _logKey(HostProfile host, String sessionId) =>
      '$_logPrefix:${host.id}:$sessionId';

  // ─── Log index helpers ───

  Future<List<_LogCacheIndexEntry>> _loadLogIndex(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(_logIndexKey);
    if (raw == null || raw.isEmpty) return const <_LogCacheIndexEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return const <_LogCacheIndexEntry>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(_LogCacheIndexEntry.fromJson)
          .where((entry) => entry.key.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      await prefs.remove(_logIndexKey);
      return const <_LogCacheIndexEntry>[];
    }
  }

  Future<void> _saveLogIndex(
    SharedPreferences prefs,
    List<_LogCacheIndexEntry> entries,
  ) async {
    if (entries.isEmpty) {
      await prefs.remove(_logIndexKey);
      return;
    }
    await prefs.setString(
      _logIndexKey,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }

  Future<void> _touchLogIndex(SharedPreferences prefs, String key) async {
    final index = await _loadLogIndex(prefs);
    final now = DateTime.now();
    final updated = index
        .map(
          (entry) => entry.key == key ? entry.copyWith(lastUsedAt: now) : entry,
        )
        .toList(growable: false);
    await _pruneLogCache(prefs, updated);
  }

  Future<void> _updateLogIndex(
    SharedPreferences prefs,
    String key, {
    required DateTime cachedAt,
    required DateTime lastUsedAt,
  }) async {
    final index = await _loadLogIndex(prefs);
    final updated = [
      ...index.where((entry) => entry.key != key),
      _LogCacheIndexEntry(key: key, cachedAt: cachedAt, lastUsedAt: lastUsedAt),
    ];
    await _pruneLogCache(prefs, updated);
  }

  Future<void> _removeLogIndexEntry(SharedPreferences prefs, String key) async {
    final index = await _loadLogIndex(prefs);
    final updated = index
        .where((entry) => entry.key != key)
        .toList(growable: false);
    await _saveLogIndex(prefs, updated);
  }

  Future<void> _pruneLogCache(
    SharedPreferences prefs,
    List<_LogCacheIndexEntry> index,
  ) async {
    final now = DateTime.now();
    final valid = <_LogCacheIndexEntry>[];
    for (final entry in index) {
      if (now.difference(entry.cachedAt) > _sessionLogTtl) {
        await prefs.remove(entry.key);
      } else {
        valid.add(entry);
      }
    }
    valid.sort((left, right) => right.lastUsedAt.compareTo(left.lastUsedAt));

    final kept = valid.take(_maxSessionLogEntries).toList(growable: false);
    final keptKeys = kept.map((entry) => entry.key).toSet();
    for (final entry in valid.skip(_maxSessionLogEntries)) {
      await prefs.remove(entry.key);
    }
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (key.startsWith('$_logPrefix:') && !keptKeys.contains(key)) {
        await prefs.remove(key);
      }
    }
    await _saveLogIndex(prefs, kept);
  }

  // ─── Migration from SharedPreferences ───

  Future<void> _migrateFromSharedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('sidemesh_sqflite_migrated_v1') == true) return;

    // 1. Migrate session cache
    final oldCache = SessionCacheStoreInternal();
    final hosts = await oldCache._loadHostIds();
    for (final hostId in hosts) {
      final cached = await oldCache._loadRecentSessionsForHost(hostId);
      if (cached.isEmpty) continue;
      final db = await SidemeshDb.instance;
      final now = DateTime.now().millisecondsSinceEpoch;
      final batch = db.batch();
      for (final s in cached) {
        batch.execute(
          '''
          INSERT INTO sessions (
            host_id, session_id, title, preview, cwd, provider, status,
            created_at, updated_at, runtime_json, git_info_json,
            is_favorite, source, cached_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'recent', ?)
          ON CONFLICT(host_id, session_id) DO UPDATE SET
            title = excluded.title,
            preview = excluded.preview,
            cwd = excluded.cwd,
            provider = excluded.provider,
            status = excluded.status,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            runtime_json = excluded.runtime_json,
            git_info_json = excluded.git_info_json,
            source = excluded.source,
            cached_at = excluded.cached_at
        ''',
          [
            hostId,
            s.id,
            s.title,
            s.preview,
            s.cwd,
            s.provider,
            s.status,
            s.createdAt.millisecondsSinceEpoch,
            s.updatedAt.millisecondsSinceEpoch,
            s.runtime != null ? jsonEncode(s.runtime!.toJson()) : null,
            s.gitInfo != null ? jsonEncode(s.gitInfo!.toJson()) : null,
            now,
          ],
        );
      }
      await batch.commit(noResult: true);
    }

    // 2. Migrate favorites
    final oldFavorites = SessionFavoritesStoreInternal();
    await oldFavorites._load();
    final db = await SidemeshDb.instance;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final key in oldFavorites._favoriteKeys) {
      final parts = key.split('::');
      if (parts.length != 2) continue;
      final hostId = parts[0];
      final sessionId = parts[1];
      await db.rawInsert(
        '''
        INSERT OR IGNORE INTO sessions (
          host_id, session_id, title, preview, cwd, status,
          created_at, updated_at, is_favorite, source, cached_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 'favorite', ?)
      ''',
        [hostId, sessionId, 'Unknown', '', '', 'unknown', 0, 0, now],
      );
    }

    // 3. Flip migration flag
    await prefs.setBool('sidemesh_sqflite_migrated_v1', true);

    // 4. Best-effort cleanup of old prefs keys
    await prefs.remove('sidemesh_session_favorites_v1');
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (key.startsWith('sidemesh_cached_recent_sessions_v1:')) {
        await prefs.remove(key);
      }
    }
  }
}

// ─── Internal helpers for migration (read old SharedPreferences shapes) ───

class SessionCacheStoreInternal {
  static const _recentPrefix = 'sidemesh_cached_recent_sessions_v1';

  Future<List<String>> _loadHostIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = <String>{};
    for (final key in prefs.getKeys()) {
      if (key.startsWith('$_recentPrefix:')) {
        final parts = key.split(':');
        if (parts.length >= 2) {
          ids.add(parts[1]);
        }
      }
    }
    return ids.toList();
  }

  Future<List<SessionSummary>> _loadRecentSessionsForHost(String hostId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_recentPrefix:$hostId');
    if (raw == null || raw.isEmpty) return const <SessionSummary>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) return const <SessionSummary>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(SessionSummary.fromJson)
          .toList(growable: false);
    } catch (_) {
      return const <SessionSummary>[];
    }
  }
}

class SessionFavoritesStoreInternal {
  static const _prefsKey = 'sidemesh_session_favorites_v1';

  final Set<String> _favoriteKeys = <String>{};

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? const <String>[];
    _favoriteKeys
      ..clear()
      ..addAll(stored.where((entry) => entry.isNotEmpty));
  }
}

class _LogCacheIndexEntry {
  const _LogCacheIndexEntry({
    required this.key,
    required this.cachedAt,
    required this.lastUsedAt,
  });

  final String key;
  final DateTime cachedAt;
  final DateTime lastUsedAt;

  _LogCacheIndexEntry copyWith({DateTime? lastUsedAt}) => _LogCacheIndexEntry(
    key: key,
    cachedAt: cachedAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );

  factory _LogCacheIndexEntry.fromJson(Map<String, dynamic> json) =>
      _LogCacheIndexEntry(
        key: json['key'] as String? ?? '',
        cachedAt: _dateFromJson(json['cachedAt']),
        lastUsedAt: _dateFromJson(json['lastUsedAt']),
      );

  Map<String, dynamic> toJson() => {
    'key': key,
    'cachedAt': cachedAt.millisecondsSinceEpoch,
    'lastUsedAt': lastUsedAt.millisecondsSinceEpoch,
  };
}

DateTime _dateFromJson(Object? value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
