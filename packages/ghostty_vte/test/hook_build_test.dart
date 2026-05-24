import 'package:code_assets/code_assets.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as build_hook;

void main() {
  group('preferSourceBuildFromEnvironment', () {
    test('treats truthy override values as source-build requests', () {
      expect(
        build_hook.preferSourceBuildFromEnvironment(
          const <String, String>{'GHOSTTY_VTE_PREFER_SOURCE': '1'},
        ),
        isTrue,
      );
    });

    test('accepts mixed-case truthy text', () {
      expect(
        build_hook.preferSourceBuildFromEnvironment(
          const <String, String>{'GHOSTTY_VTE_PREFER_SOURCE': 'TrUe'},
        ),
        isTrue,
      );
    });

    test('defaults to downloaded prebuilts when unset', () {
      expect(
        build_hook.preferSourceBuildFromEnvironment(const <String, String>{}),
        isFalse,
      );
    });

    test('treats falsey override values as disabled', () {
      expect(
        build_hook.preferSourceBuildFromEnvironment(
          const <String, String>{'GHOSTTY_VTE_PREFER_SOURCE': 'false'},
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
