import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'screen_awake_settings_store.dart';

abstract interface class ScreenAwakeBinding {
  Future<void> setEnabled(bool enabled);
}

class WakelockScreenAwakeBinding implements ScreenAwakeBinding {
  const WakelockScreenAwakeBinding();

  @override
  Future<void> setEnabled(bool enabled) {
    return WakelockPlus.toggle(enable: enabled);
  }
}

class ScreenAwakeController with WidgetsBindingObserver {
  ScreenAwakeController({
    ScreenAwakeSettingsStore? settingsStore,
    ScreenAwakeBinding? binding,
  }) : _settingsStore = settingsStore ?? ScreenAwakeSettingsStore.instance,
       _binding = binding ?? const WakelockScreenAwakeBinding();

  static final ScreenAwakeController instance = ScreenAwakeController();

  final ScreenAwakeSettingsStore _settingsStore;
  final ScreenAwakeBinding _binding;
  final Map<String, bool> _activeSources = <String, bool>{};

  bool _started = false;
  bool _foreground = true;
  bool _applied = false;
  bool _applying = false;
  Future<void>? _applyFuture;

  bool get _hasActiveSource => _activeSources.values.any((active) => active);

  bool get _shouldKeepAwake =>
      _started &&
      _foreground &&
      _settingsStore.keepScreenAwakeWhileAgentRuns &&
      _hasActiveSource;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _foreground = _isForeground(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    _settingsStore.addListener(_scheduleApply);
    await _settingsStore.ensureLoaded();
    _scheduleApply();
  }

  Future<void> stop() async {
    if (!_started && !_applied) return;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _settingsStore.removeListener(_scheduleApply);
    }
    _started = false;
    _activeSources.clear();
    _scheduleApply();
    await waitForIdle();
  }

  void setSourceActive(String key, bool active) {
    if (_activeSources[key] == active) return;
    _activeSources[key] = active;
    _scheduleApply();
  }

  void clearSource(String key) {
    if (!_activeSources.containsKey(key)) return;
    _activeSources.remove(key);
    _scheduleApply();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = _isForeground(state);
    _scheduleApply();
  }

  void _scheduleApply() {
    if (_applying) return;
    _applying = true;
    _applyFuture = _applyLoop();
  }

  Future<void> _applyLoop() async {
    try {
      while (true) {
        final desired = _shouldKeepAwake;
        if (desired == _applied) return;
        try {
          await _binding.setEnabled(desired);
          _applied = desired;
        } catch (error, stackTrace) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: error,
              stack: stackTrace,
              library: 'sidemesh screen awake',
              context: ErrorDescription('updating the platform wake lock'),
            ),
          );
          return;
        }
      }
    } finally {
      _applying = false;
    }
  }

  bool _isForeground(AppLifecycleState? state) {
    return state == null || state == AppLifecycleState.resumed;
  }

  @visibleForTesting
  bool get isApplied => _applied;

  @visibleForTesting
  int get sourceCount => _activeSources.length;

  @visibleForTesting
  Future<void> waitForIdle() => _applyFuture ?? Future<void>.value();
}
