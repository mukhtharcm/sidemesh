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
  static const _maxRecentSessionsPerHost = 40;
  static const _maxSessionLogCacheChars = 2 * 1024 * 1024;

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
      return CachedSessionLog(
        log: SessionLog.fromJson(logJson),
        cachedAt: DateTime.fromMillisecondsSinceEpoch(cachedAtMs),
      );
    } catch (_) {
      await prefs.remove(key);
      return null;
    }
  }

  Future<void> saveSessionLog(HostProfile host, SessionLog log) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode({
      'cachedAt': DateTime.now().millisecondsSinceEpoch,
      'log': log.toJson(),
    });
    if (encoded.length > _maxSessionLogCacheChars) {
      return;
    }
    await prefs.setString(_logKey(host, log.session.id), encoded);
  }

  String _recentKey(HostProfile host) => '$_recentPrefix:${host.id}';

  String _logKey(HostProfile host, String sessionId) =>
      '$_logPrefix:${host.id}:$sessionId';
}
