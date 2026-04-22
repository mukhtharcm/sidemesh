import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class SessionFavoritesStore extends ChangeNotifier {
  SessionFavoritesStore._();

  static final SessionFavoritesStore instance = SessionFavoritesStore._();
  static const _prefsKey = 'sidemesh_session_favorites_v1';

  final Set<String> _favoriteKeys = <String>{};
  bool _loaded = false;
  Future<void>? _loadFuture;

  Future<void> ensureLoaded() {
    if (_loaded) {
      return Future.value();
    }
    return _loadFuture ??= _load();
  }

  bool isFavorite(HostProfile host, String sessionId) {
    return _favoriteKeys.contains(_keyFor(host.id, sessionId));
  }

  Future<bool> toggleFavorite(HostProfile host, String sessionId) async {
    await ensureLoaded();
    final key = _keyFor(host.id, sessionId);
    final added = !_favoriteKeys.remove(key);
    if (added) {
      _favoriteKeys.add(key);
    }
    await _persist();
    notifyListeners();
    return added;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? const <String>[];
    _favoriteKeys
      ..clear()
      ..addAll(stored.where((entry) => entry.isNotEmpty));
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final sortedKeys = _favoriteKeys.toList()..sort();
    await prefs.setStringList(_prefsKey, sortedKeys);
  }

  String _keyFor(String hostId, String sessionId) => '$hostId::$sessionId';
}
