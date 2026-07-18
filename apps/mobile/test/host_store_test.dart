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

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

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
    values.remove(key);
  }
}
