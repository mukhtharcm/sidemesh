import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  test('HostProfile defaults enabled to true for old JSON', () {
    final host = HostProfile.fromJson({
      'id': 'host-1',
      'label': 'MacBook',
      'baseUrl': 'http://macbook.local:8787',
      'token': 'token',
    });

    expect(host.enabled, isTrue);
  });

  test('HostProfile preserves explicit disabled state', () {
    final host = HostProfile.fromJson({
      'id': 'host-1',
      'label': 'MacBook',
      'baseUrl': 'http://macbook.local:8787',
      'token': 'token',
      'enabled': false,
    });

    expect(host.enabled, isFalse);
    expect(host.toJson()['enabled'], isFalse);
    expect(host.toJson(), isNot(contains('token')));
    expect(host.toJson(includeToken: true)['token'], 'token');
    expect(host.copyWith(enabled: true).enabled, isTrue);
  });
}
