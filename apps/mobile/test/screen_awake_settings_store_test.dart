import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/screen_awake_settings_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads disabled by default', () async {
    final store = ScreenAwakeSettingsStore.forTesting();

    await store.ensureLoaded();

    expect(store.keepScreenAwakeWhileAgentRuns, isFalse);
  });

  test('persists keep-screen-awake preference', () async {
    final store = ScreenAwakeSettingsStore.forTesting();
    await store.ensureLoaded();

    await store.setKeepScreenAwakeWhileAgentRuns(true);

    final restored = ScreenAwakeSettingsStore.forTesting();
    await restored.ensureLoaded();

    expect(restored.keepScreenAwakeWhileAgentRuns, isTrue);

    await restored.setKeepScreenAwakeWhileAgentRuns(false);

    final disabled = ScreenAwakeSettingsStore.forTesting();
    await disabled.ensureLoaded();
    expect(disabled.keepScreenAwakeWhileAgentRuns, isFalse);
  });
}
