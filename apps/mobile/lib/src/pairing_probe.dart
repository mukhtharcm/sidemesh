import 'api_client.dart';
import 'models.dart';
import 'pairing.dart';

class PairingProbeResult {
  const PairingProbeResult({required this.baseUrl, required this.node});

  final String baseUrl;
  final NodeInfo node;
}

Future<PairingProbeResult?> probePairingAddresses(
  ApiClient api,
  PairingPayload payload,
) async {
  final candidates = payload.addresses.isEmpty
      ? <String>[payload.baseUrl]
      : payload.addresses;
  final results = await Future.wait(
    candidates.map((baseUrl) async {
      try {
        final node = await api.fetchNode(
          HostProfile(
            id: 'pair-probe',
            label: payload.label,
            baseUrl: baseUrl,
            token: payload.token,
          ),
        );
        return PairingProbeResult(baseUrl: baseUrl, node: node);
      } catch (_) {
        return null;
      }
    }),
  );
  return results.whereType<PairingProbeResult>().firstOrNull;
}
