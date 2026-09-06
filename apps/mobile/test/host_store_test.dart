import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/host_store.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('macOS fresh storage never reads or deletes legacy tokens', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({
      'sidemesh_hosts_v1': '[{"id":"old","token":"legacy"}]',
      'sidemesh_hosts_v2': '[{"id":"old","label":"Old","baseUrl":"https://example.com"}]',
    });
    final secure = _InMemorySecureStorage();
    final store = HostStore(secure: secure);
    expect(await store.loadHosts(), isEmpty);
    expect(secure.calls, isEmpty);
    await store.saveHosts(const [
      HostProfile(id: 'new', label: 'New', baseUrl: 'https://example.com', token: 'new-token'),
    ]);
    final reopened = await HostStore(secure: secure).loadHosts();
    expect(reopened.single.token, 'new-token');
    await store.saveHosts(const []);
    expect(await HostStore(secure: secure).loadHosts(), isEmpty);
    expect(secure.calls, everyElement(endsWith(':sidemesh_host_tokens_v1')));
    expect(secure.values, isEmpty);
  }, skip: !const bool.fromEnvironment('SIDEMESH_MACOS_USE_DATA_PROTECTION_KEYCHAIN'));

  test('HostStore persists disabled state while retaining token', () async {
    final store = HostStore(secure: _InMemorySecureStorage());
    await store.saveHosts(const [
      HostProfile(
        id: 'host-1',
        label: 'MacBook',
        baseUrl: 'http://macbook.local:8787',
        token: 'secret',
        enabled: false,
      ),
    ]);

    final hosts = await store.loadHosts();

    expect(hosts, hasLength(1));
    expect(hosts.single.enabled, isFalse);
    expect(hosts.single.token, 'secret');
  });
}

class _InMemorySecureStorage extends FlutterSecureStorage {
  _InMemorySecureStorage([Map<String, String>? initialValues])
    : values = initialValues == null
          ? <String, String>{}
          : Map<String, String>.from(initialValues);

  final Map<String, String> values;
  final List<String> calls = [];

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add('read:$key');
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add('write:$key');
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    calls.add('delete:$key');
    values.remove(key);
  }
}
