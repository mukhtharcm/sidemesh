import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/app_directories.dart';

void main() {
  test('buildMacosScopedDirectoryPath scopes under Library root folder', () {
    expect(
      buildMacosScopedDirectoryPath(
        homePath: '/Users/tester',
        rootFolderName: 'Application Support',
        bundleId: 'com.example.app',
      ),
      '/Users/tester/Library/Application Support/com.example.app',
    );
  });

  test('buildMacosScopedDirectoryPath falls back to default bundle id', () {
    expect(
      buildMacosScopedDirectoryPath(
        homePath: '/Users/tester',
        rootFolderName: 'Caches',
        bundleId: '   ',
      ),
      '/Users/tester/Library/Caches/com.sidemesh.sidemeshMobile',
    );
  });

  test('buildMacosScopedDirectoryPath rejects empty home paths', () {
    expect(
      () => buildMacosScopedDirectoryPath(
        homePath: '   ',
        rootFolderName: 'Caches',
      ),
      throwsArgumentError,
    );
  });
}
