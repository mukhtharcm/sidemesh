import 'dart:io';

import 'package:ghostty_vte/src/hook/dynamic_library.dart';
import 'package:test/test.dart';

void main() {
  group('dynamicLibraryNameForPlatform', () {
    test('uses Mach-O dylib names for iOS artifacts', () {
      expect(
        dynamicLibraryNameForPlatform('ios-arm64', 'ghostty-vt'),
        'libghostty-vt.dylib',
      );
      expect(
        dynamicLibraryNameForPlatform('ios-sim-arm64', 'ghostty-vt'),
        'libghostty-vt.dylib',
      );
      expect(
        dynamicLibraryNameForPlatform('ios-sim-x64', 'ghostty-vt'),
        'libghostty-vt.dylib',
      );
    });
  });

  group('selectDynamicLibraryEntity', () {
    test(
      'prefers versioned Linux shared objects over static archives',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'ghostty_vte_dynamic_library',
        );
        addTearDown(() => dir.deleteSync(recursive: true));

        final staticArchive = File('${dir.path}/libghostty-vt.a')
          ..writeAsBytesSync(_archiveHeader);
        final sharedObject = File('${dir.path}/libghostty-vt.so.0.1.0')
          ..writeAsBytesSync(_elfHeader);

        final selected = selectDynamicLibraryEntity([
          staticArchive,
          sharedObject,
        ], canonicalName: 'libghostty-vt.so');

        expect(selected?.path, sharedObject.path);
      },
    );

    test('prefers exact DLL matches on Windows', () async {
      final dir = await Directory.systemTemp.createTemp(
        'ghostty_vte_dynamic_library',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      final importLib = File('${dir.path}/ghostty-vt.lib')
        ..writeAsBytesSync(_archiveHeader);
      final dll = File('${dir.path}/ghostty-vt.dll')
        ..writeAsBytesSync(_peHeader);

      final selected = selectDynamicLibraryEntity([
        importLib,
        dll,
      ], canonicalName: 'ghostty-vt.dll');

      expect(selected?.path, dll.path);
    });
  });

  group('ensureDynamicLibraryFile', () {
    test('accepts ELF shared objects', () async {
      final dir = await Directory.systemTemp.createTemp(
        'ghostty_vte_dynamic_library',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      final so = File('${dir.path}/libghostty-vt.so')
        ..writeAsBytesSync(_elfHeader);

      expect(
        () => ensureDynamicLibraryFile(
          so,
          canonicalName: 'libghostty-vt.so',
          sourceDescription: 'test fixture',
        ),
        returnsNormally,
      );
    });

    test('rejects ar archives renamed as shared objects', () async {
      final dir = await Directory.systemTemp.createTemp(
        'ghostty_vte_dynamic_library',
      );
      addTearDown(() => dir.deleteSync(recursive: true));

      final so = File('${dir.path}/libghostty-vt.so')
        ..writeAsBytesSync(_archiveHeader);

      expect(
        () => ensureDynamicLibraryFile(
          so,
          canonicalName: 'libghostty-vt.so',
          sourceDescription: 'test fixture',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

const _elfHeader = <int>[0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00];
const _peHeader = <int>[0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00];
const _archiveHeader = <int>[0x21, 0x3C, 0x61, 0x72, 0x63, 0x68, 0x3E, 0x0A];
