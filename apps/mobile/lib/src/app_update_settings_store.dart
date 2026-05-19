import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const int _minimumUpdateCheckIntervalSeconds = 3600;
const int _defaultUpdateCheckIntervalSeconds = 86400;

@immutable
class AppUpdateCheckIntervalOption {
  const AppUpdateCheckIntervalOption({
    required this.seconds,
    required this.label,
    required this.detail,
  });

  static const daily = AppUpdateCheckIntervalOption(
    seconds: 86400,
    label: 'Daily',
    detail: 'Checks once per day.',
  );
  static const weekly = AppUpdateCheckIntervalOption(
    seconds: 604800,
    label: 'Weekly',
    detail: 'Checks once per week.',
  );
  static const monthly = AppUpdateCheckIntervalOption(
    seconds: 2629800,
    label: 'Monthly',
    detail: 'Checks about once per month.',
  );

  static const List<AppUpdateCheckIntervalOption> values = [
    daily,
    weekly,
    monthly,
  ];

  final int seconds;
  final String label;
  final String detail;

  static AppUpdateCheckIntervalOption? matchingSeconds(int seconds) {
    for (final option in values) {
      if (option.seconds == seconds) return option;
    }
    return null;
  }
}

@immutable
class AppUpdateSettings {
  const AppUpdateSettings({
    required this.supported,
    required this.loaded,
    required this.automaticallyChecksForUpdates,
    required this.updateCheckIntervalSeconds,
    required this.canCheckForUpdates,
  });

  const AppUpdateSettings.uninitialized()
    : supported = false,
      loaded = false,
      automaticallyChecksForUpdates = false,
      updateCheckIntervalSeconds = _defaultUpdateCheckIntervalSeconds,
      canCheckForUpdates = false;

  const AppUpdateSettings.unsupported()
    : supported = false,
      loaded = true,
      automaticallyChecksForUpdates = false,
      updateCheckIntervalSeconds = _defaultUpdateCheckIntervalSeconds,
      canCheckForUpdates = false;

  final bool supported;
  final bool loaded;
  final bool automaticallyChecksForUpdates;
  final int updateCheckIntervalSeconds;
  final bool canCheckForUpdates;

  int get normalizedUpdateCheckIntervalSeconds {
    final seconds = updateCheckIntervalSeconds;
    if (seconds < _minimumUpdateCheckIntervalSeconds) {
      return _minimumUpdateCheckIntervalSeconds;
    }
    return seconds;
  }

  AppUpdateCheckIntervalOption? get selectedIntervalOption {
    return AppUpdateCheckIntervalOption.matchingSeconds(
      normalizedUpdateCheckIntervalSeconds,
    );
  }

  String get intervalLabel {
    final option = selectedIntervalOption;
    if (option != null) return option.label;
    final duration = Duration(seconds: normalizedUpdateCheckIntervalSeconds);
    if (duration.inDays >= 30) {
      final months = (duration.inDays / 30).round();
      return months == 1 ? 'Every month' : 'Every $months months';
    }
    if (duration.inDays >= 1) {
      final days = duration.inDays;
      return days == 1 ? 'Every day' : 'Every $days days';
    }
    final hours = duration.inHours.clamp(1, 9999);
    return hours == 1 ? 'Every hour' : 'Every $hours hours';
  }
}

abstract class AppUpdateSettingsService {
  Future<AppUpdateSettings> fetchSettings();
  Future<AppUpdateSettings> setAutomaticallyChecksForUpdates(bool value);
  Future<AppUpdateSettings> setUpdateCheckIntervalSeconds(int seconds);
  Future<void> checkForUpdates();
}

class MethodChannelAppUpdateSettingsService
    implements AppUpdateSettingsService {
  MethodChannelAppUpdateSettingsService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'dev.sidemesh/updater';
  final MethodChannel _channel;

  bool get _platformSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<AppUpdateSettings> fetchSettings() async {
    if (!_platformSupported) return const AppUpdateSettings.unsupported();
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'getState',
    );
    return _settingsFromMap(response);
  }

  @override
  Future<AppUpdateSettings> setAutomaticallyChecksForUpdates(bool value) async {
    if (!_platformSupported) {
      throw PlatformException(
        code: 'unsupported',
        message: 'In-app updates are only available on macOS.',
      );
    }
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'setAutomaticallyChecksForUpdates',
      <String, Object>{'enabled': value},
    );
    return _settingsFromMap(response);
  }

  @override
  Future<AppUpdateSettings> setUpdateCheckIntervalSeconds(int seconds) async {
    if (!_platformSupported) {
      throw PlatformException(
        code: 'unsupported',
        message: 'In-app updates are only available on macOS.',
      );
    }
    final normalizedSeconds = seconds < _minimumUpdateCheckIntervalSeconds
        ? _minimumUpdateCheckIntervalSeconds
        : seconds;
    final response = await _channel.invokeMapMethod<Object?, Object?>(
      'setUpdateCheckIntervalSeconds',
      <String, Object>{'seconds': normalizedSeconds},
    );
    return _settingsFromMap(response);
  }

  @override
  Future<void> checkForUpdates() async {
    if (!_platformSupported) {
      throw PlatformException(
        code: 'unsupported',
        message: 'In-app updates are only available on macOS.',
      );
    }
    await _channel.invokeMethod<void>('checkForUpdates');
  }

  AppUpdateSettings _settingsFromMap(Map<Object?, Object?>? data) {
    if (data == null) return const AppUpdateSettings.unsupported();
    return AppUpdateSettings(
      supported: _boolValue(data['supported']),
      loaded: true,
      automaticallyChecksForUpdates: _boolValue(
        data['automaticallyChecksForUpdates'],
      ),
      updateCheckIntervalSeconds: _intValue(data['updateCheckIntervalSeconds']),
      canCheckForUpdates: _boolValue(data['canCheckForUpdates']),
    );
  }

  bool _boolValue(Object? value) => value == true;

  int _intValue(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) {
      return int.tryParse(value) ?? _defaultUpdateCheckIntervalSeconds;
    }
    return _defaultUpdateCheckIntervalSeconds;
  }
}

class AppUpdateSettingsStore extends ChangeNotifier {
  AppUpdateSettingsStore._({AppUpdateSettingsService? service})
    : _service = service ?? MethodChannelAppUpdateSettingsService();

  @visibleForTesting
  AppUpdateSettingsStore.forTesting({required AppUpdateSettingsService service})
    : _service = service;

  static final AppUpdateSettingsStore instance = AppUpdateSettingsStore._();

  final AppUpdateSettingsService _service;

  AppUpdateSettings _settings = const AppUpdateSettings.uninitialized();
  Future<void>? _loadFuture;
  bool _loading = false;
  bool _saving = false;
  bool _checking = false;

  AppUpdateSettings get settings => _settings;
  bool get loading => _loading;
  bool get saving => _saving;
  bool get checking => _checking;

  Future<void> ensureLoaded() {
    if (_settings.loaded) return Future.value();
    return _loadFuture ??= refresh();
  }

  Future<void> refresh() async {
    _loading = true;
    notifyListeners();
    try {
      _settings = await _service.fetchSettings();
    } catch (_) {
      _loadFuture = null;
      rethrow;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> setAutomaticallyChecksForUpdates(bool value) async {
    await ensureLoaded();
    if (_saving) return;
    _saving = true;
    notifyListeners();
    try {
      _settings = await _service.setAutomaticallyChecksForUpdates(value);
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> setUpdateCheckIntervalSeconds(int seconds) async {
    await ensureLoaded();
    if (_saving) return;
    _saving = true;
    notifyListeners();
    try {
      _settings = await _service.setUpdateCheckIntervalSeconds(seconds);
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  Future<void> checkForUpdates() async {
    await ensureLoaded();
    if (_checking) return;
    _checking = true;
    notifyListeners();
    try {
      await _service.checkForUpdates();
      _settings = await _service.fetchSettings();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  void resetForTest() {
    _settings = const AppUpdateSettings.uninitialized();
    _loadFuture = null;
    _loading = false;
    _saving = false;
    _checking = false;
  }
}
