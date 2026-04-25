import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class CachedSessionLog {
  const CachedSessionLog({required this.log, required this.cachedAt});

  final SessionLog log;
  final DateTime cachedAt;
}

/// Small read-through cache for high-traffic session screens.
///
/// This is deliberately boring SharedPreferences storage for the first
/// reliability slice: enough to paint useful state immediately, without
/// committing the app to a full sync database before the data model settles.
class SessionCacheStore {
  SessionCacheStore._();

  static final SessionCacheStore instance = SessionCacheStore._();

  static const _recentPrefix = 'sidemesh_cached_recent_sessions_v1';
  static const _logPrefix = 'sidemesh_cached_session_log_v1';
  static const _logIndexKey = 'sidemesh_cached_session_log_index_v1';
  static const _maxRecentSessionsPerHost = 40;
  static const _maxSessionLogCacheChars = 2 * 1024 * 1024;
  static const _maxSessionLogEntries = 20;
  static const _sessionLogTtl = Duration(days: 14);

  Future<List<SessionSummary>> loadRecentSessions(HostProfile host) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recentKey(host));
    if (raw == null || raw.isEmpty) {
      return const <SessionSummary>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return const <SessionSummary>[];
      }
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(SessionSummary.fromJson)
          .toList(growable: false);
    } catch (_) {
      await prefs.remove(_recentKey(host));
      return const <SessionSummary>[];
    }
  }

  Future<void> saveRecentSessions(
    HostProfile host,
    List<SessionSummary> sessions,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = sessions
        .take(_maxRecentSessionsPerHost)
        .map((session) => session.toJson())
        .toList(growable: false);
    await prefs.setString(_recentKey(host), jsonEncode(payload));
  }

  Future<CachedSessionLog?> loadSessionLog(
    HostProfile host,
    String sessionId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _logKey(host, sessionId);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final cachedAtMs = decoded['cachedAt'];
      final logJson = decoded['log'];
      if (cachedAtMs is! int || logJson is! Map<String, dynamic>) {
        return null;
      }
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

  Future<void> clearHost(HostProfile host) async {
    await clearHostId(host.id);
  }

  Future<void> clearHostId(String hostId) async {
    final prefs = await SharedPreferences.getInstance();
    final recentPrefix = '$_recentPrefix:$hostId';
    final logPrefix = '$_logPrefix:$hostId';
    for (final key in prefs.getKeys().toList(growable: false)) {
      if (key == recentPrefix ||
          key.startsWith('$recentPrefix:') ||
          key.startsWith('$logPrefix:')) {
        await prefs.remove(key);
      }
    }
    final index = await _loadLogIndex(prefs);
    final filtered = index
        .where((entry) => !entry.key.startsWith('$logPrefix:'))
        .toList(growable: false);
    await _saveLogIndex(prefs, filtered);
  }

  String _recentKey(HostProfile host) =>
      '$_recentPrefix:${host.id}:${_hostFingerprint(host)}';

  String _logKey(HostProfile host, String sessionId) =>
      '$_logPrefix:${host.id}:${_hostFingerprint(host)}:$sessionId';

  String _hostFingerprint(HostProfile host) {
    final endpoint = _normalizedBaseUrl(host.baseUrl);
    return _stableHash('$endpoint\n${host.token}');
  }

  String _normalizedBaseUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      return trimmed;
    }
    final scheme = uri.scheme.isEmpty ? 'http' : uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path == '/'
        ? ''
        : uri.path.replaceFirst(RegExp(r'/$'), '');
    return '$scheme://$host$port$path';
  }

  String _stableHash(String input) {
    var fnv = 0x811c9dc5;
    var djb = 5381;
    for (final codeUnit in input.codeUnits) {
      fnv ^= codeUnit;
      fnv = (fnv * 0x01000193) & 0xffffffff;
      djb = (((djb << 5) + djb) ^ codeUnit) & 0xffffffff;
    }
    return '${fnv.toRadixString(16).padLeft(8, '0')}${djb.toRadixString(16).padLeft(8, '0')}';
  }

  Future<List<_LogCacheIndexEntry>> _loadLogIndex(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(_logIndexKey);
    if (raw == null || raw.isEmpty) {
      return const <_LogCacheIndexEntry>[];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List<dynamic>) {
        return const <_LogCacheIndexEntry>[];
      }
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
