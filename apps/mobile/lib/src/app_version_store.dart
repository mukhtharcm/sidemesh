import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

@immutable
class AppVersionInfo {
  const AppVersionInfo({
    required this.version,
    required this.buildNumber,
    required this.packageName,
    required this.loaded,
  });

  const AppVersionInfo.unknown()
    : version = '',
      buildNumber = '',
      packageName = '',
      loaded = false;

  final String version;
  final String buildNumber;
  final String packageName;
  final bool loaded;

  bool get hasVersion => version.isNotEmpty;

  String get comparableVersion {
    if (version.isEmpty) return '';
    if (buildNumber.isEmpty) return version;
    return '$version+$buildNumber';
  }

  String get displayVersion {
    if (version.isEmpty) return 'Unknown version';
    final releaseLabel = version.startsWith(RegExp('[vV]'))
        ? version
        : 'v$version';
    if (buildNumber.isEmpty) return releaseLabel;
    return '$releaseLabel ($buildNumber)';
  }
}

typedef AppVersionLoader = Future<AppVersionInfo> Function();

class AppVersionStore extends ChangeNotifier {
  AppVersionStore._({AppVersionLoader? loader})
    : _loader = loader ?? _loadFromPlatform;

  @visibleForTesting
  AppVersionStore.forTesting({required AppVersionLoader loader})
    : _loader = loader;

  static AppVersionStore instance = AppVersionStore._();

  final AppVersionLoader _loader;
  AppVersionInfo _info = const AppVersionInfo.unknown();
  Future<void>? _loadFuture;

  AppVersionInfo get info => _info;

  Future<void> ensureLoaded() {
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      _info = await _loader();
    } catch (_) {
      _info = const AppVersionInfo.unknown();
    }
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _info = const AppVersionInfo.unknown();
    _loadFuture = null;
  }

  static Future<AppVersionInfo> _loadFromPlatform() async {
    final package = await PackageInfo.fromPlatform();
    return AppVersionInfo(
      version: package.version.trim(),
      buildNumber: package.buildNumber.trim(),
      packageName: package.packageName.trim(),
      loaded: true,
    );
  }
}
