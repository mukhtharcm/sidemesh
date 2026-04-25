import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    expect(api.fetchFsBlob(disabledHost, '/tmp/file.png'), throwsStateError);
    expect(
      () => api.fsBlobUri(disabledHost, '/tmp/file.txt'),
      throwsStateError,
    );
    expect(() => api.authHeaders(disabledHost), throwsStateError);
  });

  test('ApiClient fetches image blob bytes', () async {
    final api = ApiClient(
      client: MockClient((request) async {
        expect(request.url.path, '/api/fs/blob');
        expect(request.url.queryParameters['path'], '/tmp/image.png');
        expect(request.headers['authorization'], 'Bearer secret');
        return http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200);
      }),
    );

    final bytes = await api.fetchFsBlob(
      const HostProfile(
        id: 'host-1',
        label: 'MacBook',
        baseUrl: 'http://macbook.local:8787',
        token: 'secret',
      ),
      '/tmp/image.png',
    );

    expect(bytes, [1, 2, 3]);
  });
}
