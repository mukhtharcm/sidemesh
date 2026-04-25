import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  const disabledHost = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://macbook.local:8787',
    token: 'secret',
    enabled: false,
  );

  test('ApiClient rejects HTTP calls for disabled hosts before networking', () {
    final api = ApiClient();

    expect(api.fetchNode(disabledHost), throwsStateError);
    expect(api.fetchSessions(disabledHost), throwsA(isA<StateError>()));
  });

  test('ApiClient rejects websocket and blob helpers for disabled hosts', () {
    final api = ApiClient();

    expect(() => api.openLive(disabledHost, 'session-1'), throwsStateError);
    expect(() => api.openActionsLive(disabledHost), throwsStateError);
    expect(() => api.openFsLive(disabledHost), throwsStateError);
    expect(
      () => api.fsBlobUri(disabledHost, '/tmp/file.txt'),
      throwsStateError,
    );
    expect(() => api.authHeaders(disabledHost), throwsStateError);
  });
}
