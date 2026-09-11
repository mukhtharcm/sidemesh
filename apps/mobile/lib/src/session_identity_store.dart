import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_identity.dart';

/// Saved host ownership also applies while a host is offline.
class SessionIdentityStore {
  SessionIdentityStore._();
  static final instance = SessionIdentityStore._();
  static const _prefsKey = 'sidemesh_session_aliases_v1';
  final Map<String, SessionAliases> _hosts = {};
  Future<void>? _loading;
  bool _loaded = false;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load().then((_) { _loaded = true; });
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final values = jsonDecode(raw);
      if (values is! Map<String, dynamic>) return;
      for (final entry in values.entries) {
        final aliases = SessionAliases.fromJson(entry.value);
        if (aliases != null) _hosts[entry.key] = aliases;
      }
    } on FormatException {
      // The next node response restores ownership metadata.
    }
  }

  SessionAliases? forHost(String hostId) => _hosts[hostId];

  String canonical(String hostId, String sessionId) =>
      _hosts[hostId]?.resolve(sessionId)?.sessionId ?? sessionId;

  List<String> references(String hostId, String sessionId) =>
      _hosts[hostId]?.references(sessionId) ?? [sessionId];

  /// Consolidate aliases before edits, including a later explicit removal.
  String preferenceKey<T>(String hostId, String sessionId, Map<String, T> values,
      {T Function(T, T)? merge}) {
    final candidates = references(hostId, sessionId).map((id) => '$hostId:$id').toList();
    T? value;
    for (final key in candidates) {
      final previous = values.remove(key);
      if (previous != null) value = value == null ? previous : merge?.call(value, previous) ?? value;
    }
    if (value != null) values[candidates.first] = value;
    return candidates.first;
  }

  Future<void> save(String hostId, SessionAliases? aliases) async {
    await ensureLoaded();
    final next = {..._hosts};
    if (aliases == null) {
      next.remove(hostId);
    } else {
      next[hostId] = aliases;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_prefsKey, jsonEncode(next.map((key, value) => MapEntry(key, value.toJson()))))) {
      throw StateError('Could not save session ownership.');
    }
    _hosts.clear();
    _hosts.addAll(next);
  }

  @visibleForTesting
  void resetForTest() {
    _hosts.clear();
    _loading = null;
    _loaded = false;
  }
}
