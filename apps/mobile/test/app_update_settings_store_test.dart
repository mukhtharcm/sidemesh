import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/app_update_settings_store.dart';

void main() {
  group('AppUpdateSettingsStore', () {
    test('loads updater settings once', () async {
      final service = _FakeAppUpdateSettingsService(
        initial: const AppUpdateSettings(
          automaticallyChecksForUpdates: true,
          updateCheckIntervalSeconds: 86400,
          canCheckForUpdates: true,
        ),
      );
      final store = AppUpdateSettingsStore.forTesting(service: service);

      await store.ensureLoaded();
      await store.ensureLoaded();

      expect(service.fetchCount, 1);
      expect(store.settings.supported, isTrue);
      expect(
        store.settings.selectedIntervalOption,
        AppUpdateCheckIntervalOption.daily,
      );
    });

    test('updates automatic check toggle through the service', () async {
      final service = _FakeAppUpdateSettingsService(
        initial: const AppUpdateSettings(
          automaticallyChecksForUpdates: true,
          updateCheckIntervalSeconds: 86400,
          canCheckForUpdates: true,
        ),
      );
      final store = AppUpdateSettingsStore.forTesting(service: service);

      await store.ensureLoaded();
      await store.setAutomaticallyChecksForUpdates(false);

      expect(store.settings.automaticallyChecksForUpdates, isFalse);
      expect(service.lastAutomaticChecksValue, isFalse);
    });

    test('updates interval through the service', () async {
      final service = _FakeAppUpdateSettingsService(
        initial: const AppUpdateSettings(
          automaticallyChecksForUpdates: true,
          updateCheckIntervalSeconds: 86400,
          canCheckForUpdates: true,
        ),
      );
      final store = AppUpdateSettingsStore.forTesting(service: service);

      await store.ensureLoaded();
      await store.setUpdateCheckIntervalSeconds(
        AppUpdateCheckIntervalOption.weekly.seconds,
      );

      expect(
        store.settings.selectedIntervalOption,
        AppUpdateCheckIntervalOption.weekly,
      );
      expect(
        service.lastIntervalSeconds,
        AppUpdateCheckIntervalOption.weekly.seconds,
      );
    });

    test('manual check refreshes current updater state', () async {
      final service = _FakeAppUpdateSettingsService(
        initial: const AppUpdateSettings(
          automaticallyChecksForUpdates: true,
          updateCheckIntervalSeconds: 86400,
          canCheckForUpdates: true,
        ),
        afterCheck: const AppUpdateSettings(
          automaticallyChecksForUpdates: true,
          updateCheckIntervalSeconds: 604800,
          canCheckForUpdates: true,
        ),
      );
      final store = AppUpdateSettingsStore.forTesting(service: service);

      await store.ensureLoaded();
      await store.checkForUpdates();

      expect(service.checkForUpdatesCount, 1);
      expect(
        store.settings.selectedIntervalOption,
        AppUpdateCheckIntervalOption.weekly,
      );
    });

    test(
      'exposes a failed state and retries after an initial failure',
      () async {
        final service = _FakeAppUpdateSettingsService(
          initial: const AppUpdateSettings(
            automaticallyChecksForUpdates: true,
            updateCheckIntervalSeconds: 86400,
            canCheckForUpdates: true,
          ),
          failFirstFetch: true,
        );
        final store = AppUpdateSettingsStore.forTesting(service: service);

        await store.ensureLoaded();

        expect(store.settings.loaded, isTrue);
        expect(store.settings.loadFailed, isTrue);

        await store.refresh();

        expect(service.fetchCount, 2);
        expect(store.settings.supported, isTrue);
        expect(store.settings.loadFailed, isFalse);
      },
    );
  });
}

class _FakeAppUpdateSettingsService implements AppUpdateSettingsService {
  _FakeAppUpdateSettingsService({
    required AppUpdateSettings initial,
    AppUpdateSettings? afterCheck,
    bool failFirstFetch = false,
  }) : this._(initial, afterCheck, failFirstFetch);

  _FakeAppUpdateSettingsService._(
    this._current,
    this._afterCheck,
    this.failFirstFetch,
  );

  AppUpdateSettings _current;
  final AppUpdateSettings? _afterCheck;
  final bool failFirstFetch;
  int fetchCount = 0;
  int checkForUpdatesCount = 0;
  bool? lastAutomaticChecksValue;
  int? lastIntervalSeconds;

  @override
  Future<void> checkForUpdates() async {
    checkForUpdatesCount += 1;
    if (_afterCheck != null) {
      _current = _afterCheck;
    }
  }

  @override
  Future<AppUpdateSettings> fetchSettings() async {
    fetchCount += 1;
    if (failFirstFetch && fetchCount == 1) {
      throw StateError('transient failure');
    }
    return _current;
  }

  @override
  Future<AppUpdateSettings> setAutomaticallyChecksForUpdates(bool value) async {
    lastAutomaticChecksValue = value;
    _current = AppUpdateSettings(
      automaticallyChecksForUpdates: value,
      updateCheckIntervalSeconds: _current.updateCheckIntervalSeconds,
      canCheckForUpdates: _current.canCheckForUpdates,
    );
    return _current;
  }

  @override
  Future<AppUpdateSettings> setUpdateCheckIntervalSeconds(int seconds) async {
    lastIntervalSeconds = seconds;
    _current = AppUpdateSettings(
      automaticallyChecksForUpdates: _current.automaticallyChecksForUpdates,
      updateCheckIntervalSeconds: seconds,
      canCheckForUpdates: _current.canCheckForUpdates,
    );
    return _current;
  }
}
