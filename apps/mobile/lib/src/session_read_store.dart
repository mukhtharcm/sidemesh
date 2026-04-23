import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Tracks when the user last "saw" each session on this device.
///
/// v1 is per-device: a SharedPreferences-backed map of
/// `${hostId}:${sessionId}` → unix epoch millis of the session's
/// `updatedAt` that was most recently in view. Unread == session's
/// current `updatedAt` is newer than the recorded seen timestamp.
///
/// We deliberately store as a single map under one key, and debounce
/// writes: read-state changes are noisy (every new streamed message
/// while a chat is open bumps it) and we don't want to hit disk on
/// every frame.
class SessionReadStore extends ChangeNotifier {
  SessionReadStore._();

  static final SessionReadStore instance = SessionReadStore._();

  static const _prefsKey = 'sidemesh_session_read_state_v1';
  static const _installEpochKey = 'sidemesh_session_read_install_epoch_v1';
  static const _writeDebounce = Duration(milliseconds: 400);

  final Map<String, int> _seenAtMs = <String, int>{};
  SharedPreferences? _prefs;
  Future<void>? _loadFuture;
  Timer? _flushTimer;
  bool _dirty = false;
  int _installEpochMs = 0;

  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    var epoch = prefs.getInt(_installEpochKey);
    if (epoch == null) {
      // First launch with unread tracking enabled. Treat everything
      // already known as read so we don't light up months-old sessions.
      epoch = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt(_installEpochKey, epoch);
    }
    _installEpochMs = epoch;
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        decoded.forEach((key, value) {
          if (value is int) {
            _seenAtMs[key] = value;
          } else if (value is num) {
            _seenAtMs[key] = value.toInt();
          }
        });
      }
    } catch (_) {
      // Corrupted state — treat every session as unread. No crash.
    }
  }

  String _keyFor(HostProfile host, String sessionId) =>
      '${host.id}:$sessionId';

  /// Returns the last-seen timestamp for a session, or null if the user
  /// has never opened it on this device.
  DateTime? lastSeen(HostProfile host, String sessionId) {
    final ms = _seenAtMs[_keyFor(host, sessionId)];
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// True when the session has activity newer than the last time the
  /// user saw it. Sessions whose activity predates when this device
  /// started tracking read-state are treated as already read, so we
  /// don't light up every old session the first time the feature runs.
  bool isUnread(HostProfile host, SessionSummary session) {
    final activityMs = session.updatedAt.millisecondsSinceEpoch;
    final seen = _seenAtMs[_keyFor(host, session.id)];
    if (seen != null) {
      return activityMs > seen;
    }
    return activityMs > _installEpochMs;
  }

  /// Mark the session as seen up to [at]. No-op when we already recorded
  /// an equal or newer timestamp (so stale background polls don't regress
  /// freshly-opened sessions).
  void markSeen(HostProfile host, String sessionId, DateTime at) {
    final key = _keyFor(host, sessionId);
    final ms = at.millisecondsSinceEpoch;
    final existing = _seenAtMs[key];
    if (existing != null && existing >= ms) return;
    _seenAtMs[key] = ms;
    _dirty = true;
    notifyListeners();
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_writeDebounce, _flush);
  }

  Future<void> _flush() async {
    if (!_dirty) return;
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    _dirty = false;
    await prefs.setString(_prefsKey, jsonEncode(_seenAtMs));
  }

  /// Force a synchronous flush — call before the app backgrounds / closes
  /// to avoid losing the final bump.
  Future<void> flush() async {
    _flushTimer?.cancel();
    await _flush();
  }
}
