import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/pairing.dart';
import 'package:sidemesh_mobile/src/pairing_probe.dart';

void main() {
  test('selects the first advertised address reachable from this device', () async {
    final api = _PairingProbeApi({'http://lan:8787', 'http://tailnet:8787'});
    const payload = PairingPayload(
      label: 'Devbox',
      baseUrl: 'http://hostname:8787',
      token: 'secret',
      addresses: [
        'http://hostname:8787',
        'http://tailnet:8787',
        'http://lan:8787',
      ],
    );

    final result = await probePairingAddresses(api, payload);

    expect(result?.baseUrl, 'http://tailnet:8787');
    expect(api.attempted, payload.addresses);
  });

  test('returns null when no advertised address is reachable', () async {
    final result = await probePairingAddresses(
      _PairingProbeApi(const {}),
      const PairingPayload(
        label: 'Devbox',
        baseUrl: 'http://hostname:8787',
        token: 'secret',
        addresses: ['http://hostname:8787'],
      ),
    );

    expect(result, isNull);
  });
}

class _PairingProbeApi extends ApiClient {
  _PairingProbeApi(this.reachable);

  final Set<String> reachable;
  final List<String> attempted = [];

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async {
    attempted.add(host.baseUrl);
    if (!reachable.contains(host.baseUrl)) {
      throw StateError('unreachable');
    }
    return NodeInfo.fromJson({
      'label': 'Devbox',
      'hostname': 'devbox',
      'platform': 'linux',
      'provider': 'fake',
      'providerName': 'Fake',
      'providerVersion': '1',
    });
  }
}
