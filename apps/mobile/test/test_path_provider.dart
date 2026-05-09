import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final Directory _testSupportDirectory = Directory(
  '${Directory.systemTemp.path}/sidemesh_test_$pid',
);

class TestPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() => _path();

  @override
  Future<String?> getApplicationSupportPath() => _path();

  @override
  Future<String?> getTemporaryPath() => _path();

  Future<String> _path() async {
    await _testSupportDirectory.create(recursive: true);
    return _testSupportDirectory.path;
  }
}

Future<void> configureTestDatabaseFactory() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  await _testSupportDirectory.create(recursive: true);
  await databaseFactory.setDatabasesPath(_testSupportDirectory.path);
  PathProviderPlatform.instance = TestPathProvider();
}
