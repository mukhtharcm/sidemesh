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
