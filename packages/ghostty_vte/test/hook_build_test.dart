import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as build_hook;

void main() {
  group('isPubCachePackagePath', () {
    test('recognizes Unix pub cache paths', () {
      expect(
        build_hook.isPubCachePackagePath(
          '/home/me/.pub-cache/hosted/pub.dev/ghostty_vte-0.1.2',
        ),
        isTrue,
      );
    });

    test('recognizes Windows Pub Cache paths', () {
      expect(
        build_hook.isPubCachePackagePath(
          r'C:\Users\me\AppData\Local\Pub\Cache\hosted\pub.dev\ghostty_vte-0.1.2',
        ),
        isTrue,
      );
    });

    test('does not classify local checkouts as pub cache paths', () {
      expect(
        build_hook.isPubCachePackagePath('/work/dart_terminal/pkgs/vte'),
        isFalse,
      );
    });

    test('does not treat hosted pub.dev segments as a cache by itself', () {
      expect(
        build_hook.isPubCachePackagePath(
          '/work/fixtures/hosted/pub.dev/ghostty_vte',
        ),
        isFalse,
      );
    });
  });

  group('platformLabelForBuildHook', () {
    test('labels iOS device and simulator targets distinctly', () {
      expect(
        build_hook.platformLabelForBuildHook(
          OS.iOS,
          Architecture.arm64,
          iOSSdk: IOSSdk.iPhoneOS,
        ),
        'ios-arm64',
      );
      expect(
        build_hook.platformLabelForBuildHook(OS.iOS, Architecture.arm64),
        'ios-arm64',
      );
      expect(
        build_hook.platformLabelForBuildHook(
          OS.iOS,
          Architecture.arm64,
          iOSSdk: IOSSdk.iPhoneSimulator,
        ),
        'ios-sim-arm64',
      );
      expect(
        build_hook.platformLabelForBuildHook(OS.iOS, Architecture.x64),
        'ios-sim-x64',
      );
    });
  });

  group('zigTargetForBuildHook', () {
    test('maps iOS device and simulator targets to Zig triples', () {
      expect(
        build_hook.zigTargetForBuildHook(
          OS.iOS,
          Architecture.arm64,
          iOSSdk: IOSSdk.iPhoneOS,
        ),
        'aarch64-ios',
      );
      expect(
        build_hook.zigTargetForBuildHook(
          OS.iOS,
          Architecture.arm64,
          iOSSdk: IOSSdk.iPhoneSimulator,
        ),
        'aarch64-ios-simulator',
      );
      expect(
        build_hook.zigTargetForBuildHook(OS.iOS, Architecture.x64),
        'x86_64-ios-simulator',
      );
    });
  });
}
