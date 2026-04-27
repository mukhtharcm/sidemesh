import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/screen_awake_controller.dart';
import 'package:sidemesh_mobile/src/screen_awake_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('does not enable wake lock while setting is disabled', () async {
    final store = ScreenAwakeSettingsStore.forTesting();
    final binding = _FakeScreenAwakeBinding();
    final controller = ScreenAwakeController(
      settingsStore: store,
      binding: binding,
    );
    addTearDown(controller.stop);

    await controller.start();
    controller.setSourceActive('session:a', true);
    await controller.waitForIdle();

    expect(binding.calls, isEmpty);
    expect(controller.isApplied, isFalse);
  });

  test('enables and disables wake lock from active sources', () async {
    final store = ScreenAwakeSettingsStore.forTesting();
    final binding = _FakeScreenAwakeBinding();
    final controller = ScreenAwakeController(
      settingsStore: store,
      binding: binding,
    );
    addTearDown(controller.stop);

    await controller.start();
    controller.setSourceActive('session:a', true);
    await store.setKeepScreenAwakeWhileAgentRuns(true);
    await controller.waitForIdle();

    expect(binding.calls, <bool>[true]);
    expect(controller.isApplied, isTrue);

    controller.clearSource('session:a');
    await controller.waitForIdle();

    expect(binding.calls, <bool>[true, false]);
    expect(controller.isApplied, isFalse);
  });

  test(
    'releases wake lock outside foreground and restores on resume',
    () async {
      final store = ScreenAwakeSettingsStore.forTesting();
      final binding = _FakeScreenAwakeBinding();
      final controller = ScreenAwakeController(
        settingsStore: store,
        binding: binding,
      );
      addTearDown(controller.stop);

      await store.setKeepScreenAwakeWhileAgentRuns(true);
      await controller.start();
      controller.setSourceActive('session:a', true);
      await controller.waitForIdle();

      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await controller.waitForIdle();
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await controller.waitForIdle();

      expect(binding.calls, <bool>[true, false, true]);
      expect(controller.isApplied, isTrue);
    },
  );

  test('stop clears sources and releases applied wake lock', () async {
    final store = ScreenAwakeSettingsStore.forTesting();
    final binding = _FakeScreenAwakeBinding();
    final controller = ScreenAwakeController(
      settingsStore: store,
      binding: binding,
    );

    await store.setKeepScreenAwakeWhileAgentRuns(true);
    await controller.start();
    controller.setSourceActive('session:a', true);
    await controller.waitForIdle();

    await controller.stop();

    expect(binding.calls, <bool>[true, false]);
    expect(controller.isApplied, isFalse);
    expect(controller.sourceCount, 0);
  });
}

class _FakeScreenAwakeBinding implements ScreenAwakeBinding {
  final List<bool> calls = <bool>[];

  @override
  Future<void> setEnabled(bool enabled) async {
    calls.add(enabled);
  }
}
