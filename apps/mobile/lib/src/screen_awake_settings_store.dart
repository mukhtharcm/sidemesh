import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ScreenAwakeSettingsStore extends ChangeNotifier {
  ScreenAwakeSettingsStore._() : _prefsKey = _defaultPrefsKey;

  @visibleForTesting
  ScreenAwakeSettingsStore.forTesting({
    String prefsKey = _defaultPrefsKey,
  }) : this._withPrefsKey(prefsKey);

  ScreenAwakeSettingsStore._withPrefsKey(this._prefsKey);

  static final ScreenAwakeSettingsStore instance = ScreenAwakeSettingsStore._();

  static const _defaultPrefsKey =
      'sidemesh_keep_screen_awake_while_agent_runs_v1';

  final String _prefsKey;
  bool _keepScreenAwakeWhileAgentRuns = false;
  bool _loaded = false;
  Future<void>? _loadFuture;

  bool get keepScreenAwakeWhileAgentRuns => _keepScreenAwakeWhileAgentRuns;

  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loadFuture ??= _load();
  }

  Future<void> setKeepScreenAwakeWhileAgentRuns(bool value) async {
    await ensureLoaded();
    if (_keepScreenAwakeWhileAgentRuns == value) return;
    _keepScreenAwakeWhileAgentRuns = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, value);
    notifyListeners();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _keepScreenAwakeWhileAgentRuns = prefs.getBool(_prefsKey) ?? false;
    _loaded = true;
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _keepScreenAwakeWhileAgentRuns = false;
    _loaded = false;
    _loadFuture = null;
  }
}
