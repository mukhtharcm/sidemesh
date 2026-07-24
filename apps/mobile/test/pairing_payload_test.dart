import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/pairing.dart';

void main() {
  test('parses sidemesh QR pairing URL', () {
    final payload = PairingPayload.tryParse(
      'sidemesh://pair?v=1&label=MacBook&baseUrl=http%3A%2F%2F100.80.1.2%3A8899&token=test-token',
    );

    expect(payload, isNotNull);
    expect(payload!.label, 'MacBook');
    expect(payload.baseUrl, 'http://100.80.1.2:8899');
    expect(payload.token, 'test-token');
    expect(payload.addresses, ['http://100.80.1.2:8899']);
  });

  test('parses sidemesh pair json output', () {
    final payload = PairingPayload.tryParse('''
{
  "label": "VPS",
  "token": "secret",
  "preferredAddress": { "url": "http://100.90.1.3:8899" }
}
''');

    expect(payload, isNotNull);
    expect(payload!.label, 'VPS');
    expect(payload.baseUrl, 'http://100.90.1.3:8899');
    expect(payload.token, 'secret');
  });

  test('keeps all unique QR addresses in preferred-first order', () {
    final payload = PairingPayload.tryParse(
      'sidemesh://pair?v=2&label=Mac&baseUrl=http%3A%2F%2F192.168.1.2%3A8787'
      '&address=http%3A%2F%2F127.0.0.1%3A8787'
      '&address=http%3A%2F%2F%5Bfd7a%3A115c%3Aa1e0%3A%3A1%5D%3A8787'
      '&token=test-token',
    );

    expect(payload, isNotNull);
    expect(payload!.addresses, [
      'http://192.168.1.2:8787',
      'http://127.0.0.1:8787',
      'http://[fd7a:115c:a1e0::1]:8787',
    ]);
  });

  test('rejects non-sidemesh payloads', () {
    expect(PairingPayload.tryParse('https://example.com'), isNull);
    expect(
      PairingPayload.tryParse(
        'sidemesh://pair?label=Mac&baseUrl=file:///tmp&token=t',
      ),
      isNull,
    );
  });
}
