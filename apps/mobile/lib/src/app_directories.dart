import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String _defaultMacosBundleId = 'com.sidemesh.sidemeshMobile';
const List<String> _macosHomeEnvKeys = <String>['HOME', 'CFFIXED_USER_HOME'];

Future<Directory> getSidemeshApplicationSupportDirectory() async {
  if (!Platform.isMacOS) {
    return getApplicationSupportDirectory();
  }
  return _getMacosScopedDirectory(rootFolderName: 'Application Support');
}

Future<Directory> getSidemeshApplicationCacheDirectory() async {
  if (!Platform.isMacOS) {
    return getApplicationCacheDirectory();
  }
  return _getMacosScopedDirectory(rootFolderName: 'Caches');
}

@visibleForTesting
String normalizeMacosBundleId(String? bundleId) {
  final normalized = bundleId?.trim() ?? '';
  return normalized.isEmpty ? _defaultMacosBundleId : normalized;
}

@visibleForTesting
String buildMacosScopedDirectoryPath({
  required String homePath,
  required String rootFolderName,
  String? bundleId,
}) {
  final normalizedHomePath = homePath.trim();
  if (normalizedHomePath.isEmpty) {
    throw ArgumentError.value(
      homePath,
      'homePath',
      'Expected a non-empty macOS home directory path.',
    );
  }
  return p.posix.join(
    normalizedHomePath,
    'Library',
    rootFolderName,
    normalizeMacosBundleId(bundleId),
  );
}

Future<Directory> _getMacosScopedDirectory({
  required String rootFolderName,
}) async {
  final homePath = _macosHomeDirectoryPath();
  if (homePath == null) {
    throw StateError(
      'Unable to resolve the macOS home directory from HOME or CFFIXED_USER_HOME.',
    );
  }
  final bundleId = await _loadMacosBundleId();
  final directory = Directory(
    buildMacosScopedDirectoryPath(
      homePath: homePath,
      rootFolderName: rootFolderName,
      bundleId: bundleId,
    ),
  );
  if (!await directory.exists()) {
    await directory.create(recursive: true);
  }
  return directory;
}

String? _macosHomeDirectoryPath() {
  for (final key in _macosHomeEnvKeys) {
    final value = Platform.environment[key]?.trim();
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

Future<String?> _loadMacosBundleId() async {
  try {
    final packageInfo = await PackageInfo.fromPlatform();
    final packageName = packageInfo.packageName.trim();
    return packageName.isEmpty ? null : packageName;
  } catch (_) {
    return null;
  }
}
