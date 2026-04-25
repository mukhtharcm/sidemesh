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
    final store = HostStore();
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
