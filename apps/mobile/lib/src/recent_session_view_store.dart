import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RecentSessionGrouping { project, singleList }

class RecentSessionViewStore extends ChangeNotifier {
  RecentSessionViewStore._() : _prefsKey = _defaultPrefsKey;

  @visibleForTesting
  RecentSessionViewStore.forTesting({String prefsKey = _defaultPrefsKey})
    : this._withPrefsKey(prefsKey);

  RecentSessionViewStore._withPrefsKey(this._prefsKey);

  static final RecentSessionViewStore instance = RecentSessionViewStore._();

  static const _defaultPrefsKey = 'sidemesh_recent_session_grouping_v1';
  static const _legacyMobilePrefsKey = 'sidemesh.recent.viewMode';
  static const _legacyDesktopPrefsKey = 'sidemesh_recent_view_mode';

  final String _prefsKey;
  RecentSessionGrouping _grouping = RecentSessionGrouping.project;
  bool _loaded = false;
  Future<void>? _loadFuture;

  RecentSessionGrouping get grouping => _grouping;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  Future<void> setGrouping(RecentSessionGrouping grouping) async {
    await ensureLoaded();
    if (_grouping == grouping) return;
    _grouping = grouping;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, grouping.name);
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getString(_prefsKey);
      final legacy =
          prefs.getString(_legacyMobilePrefsKey) ??
          prefs.getString(_legacyDesktopPrefsKey);
      _grouping = switch (current ?? legacy) {
        'singleList' || 'flat' => RecentSessionGrouping.singleList,
        _ => RecentSessionGrouping.project,
      };
      if (current == null && legacy != null) {
        try {
          await prefs.setString(_prefsKey, _grouping.name);
        } catch (_) {}
      }
    } catch (_) {
      _grouping = RecentSessionGrouping.project;
    }
    _loaded = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _grouping = RecentSessionGrouping.project;
    _loaded = false;
    _loadFuture = null;
  }
}
