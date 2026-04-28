import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

@immutable
class SessionTurnConfig {
  const SessionTurnConfig({
    this.model,
    this.mode,
    this.reasoningEffort,
    this.fastMode,
  });

  final String? model;
  final String? mode;
  final String? reasoningEffort;

  /// `true` requests Fast mode, `false` clears it, `null` leaves the current
  /// thread setting untouched.
  final bool? fastMode;

  bool get isEmpty =>
      (model == null || model!.trim().isEmpty) &&
      (mode == null || mode!.trim().isEmpty) &&
      (reasoningEffort == null || reasoningEffort!.trim().isEmpty) &&
      fastMode == null;

  SessionTurnConfig copyWith({
    Object? model = _sentinel,
    Object? mode = _sentinel,
    Object? reasoningEffort = _sentinel,
    Object? fastMode = _sentinel,
  }) {
    return SessionTurnConfig(
      model: identical(model, _sentinel) ? this.model : model as String?,
      mode: identical(mode, _sentinel) ? this.mode : mode as String?,
      reasoningEffort: identical(reasoningEffort, _sentinel)
          ? this.reasoningEffort
          : reasoningEffort as String?,
      fastMode: identical(fastMode, _sentinel)
          ? this.fastMode
          : fastMode as bool?,
    );
  }

  Map<String, Object?> toJson() => {
    if ((model ?? '').trim().isNotEmpty) 'model': model,
    if ((mode ?? '').trim().isNotEmpty) 'mode': mode,
    if ((reasoningEffort ?? '').trim().isNotEmpty)
      'reasoningEffort': reasoningEffort,
    if (fastMode != null) 'fastMode': fastMode,
  };

  factory SessionTurnConfig.fromJson(Map<String, dynamic> json) =>
      SessionTurnConfig(
        model: json['model'] as String?,
        mode: json['mode'] as String?,
        reasoningEffort: json['reasoningEffort'] as String?,
        fastMode: json['fastMode'] as bool?,
      );

  static const _sentinel = Object();
}

class SessionTurnConfigStore extends ChangeNotifier {
  SessionTurnConfigStore._();

  static final SessionTurnConfigStore instance = SessionTurnConfigStore._();
  static const _prefsKey = 'sidemesh_session_turn_config_v1';

  final Map<String, SessionTurnConfig> _configs = <String, SessionTurnConfig>{};
  bool _loaded = false;
  Future<void>? _loadFuture;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  SessionTurnConfig configFor(HostProfile host, String sessionId) {
    return _configs[_keyFor(host.id, sessionId)] ?? const SessionTurnConfig();
  }

  Future<void> setConfig(
    HostProfile host,
    String sessionId,
    SessionTurnConfig config,
  ) async {
    await ensureLoaded();
    final key = _keyFor(host.id, sessionId);
    if (config.isEmpty) {
      _configs.remove(key);
    } else {
      _configs[key] = config;
    }
    await _persist();
    notifyListeners();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          decoded.forEach((key, value) {
            if (value is Map<String, dynamic>) {
              _configs[key] = SessionTurnConfig.fromJson(value);
            }
          });
        }
      } catch (_) {
        // Corrupt payload — ignore and start fresh.
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_configs.isEmpty) {
      await prefs.remove(_prefsKey);
      return;
    }
    final serialised = _configs.map(
      (key, value) => MapEntry(key, value.toJson()),
    );
    await prefs.setString(_prefsKey, jsonEncode(serialised));
  }

  String _keyFor(String hostId, String sessionId) => '$hostId:$sessionId';
}
