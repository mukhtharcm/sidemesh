import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'MacBook',
    baseUrl: 'http://localhost:8787',
    token: 'secret',
  );

  test(
    'ApiClient scopes skills, profiles, and modes requests by agent provider',
    () async {
      final requests = <Uri>[];
      final api = ApiClient(
        client: MockClient((request) async {
          requests.add(request.url);
          if (request.url.path == '/api/skills') {
            return http.Response(
              '{"cwd":"/repo","skills":[],"errors":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path == '/api/profiles') {
            return http.Response(
              '{"defaultProfile":null,"profiles":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.url.path == '/api/modes') {
            return http.Response(
              '{"defaultMode":null,"modes":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          throw StateError('Unexpected path ${request.url.path}');
        }),
      );

      await api.fetchSkills(
        host,
        cwd: '/repo',
        forceReload: true,
        agentProvider: 'copilot',
      );
      await api.fetchProfiles(host, cwd: '/repo', agentProvider: 'copilot');
      await api.fetchModes(host, cwd: '/repo', agentProvider: 'copilot');

      expect(requests, hasLength(3));
      expect(
        requests.first.queryParameters,
        containsPair('agentProvider', 'copilot'),
      );
      expect(requests.first.queryParameters, containsPair('cwd', '/repo'));
      expect(
        requests.first.queryParameters,
        containsPair('forceReload', 'true'),
      );
      expect(
        requests[1].queryParameters,
        containsPair('agentProvider', 'copilot'),
      );
      expect(requests[1].queryParameters, containsPair('cwd', '/repo'));
      expect(
        requests.last.queryParameters,
        containsPair('agentProvider', 'copilot'),
      );
      expect(requests.last.queryParameters, containsPair('cwd', '/repo'));
    },
  );

  test('ApiClient keeps filesystem helpers host-scoped', () async {
    final requests = <Uri>[];
    final api = ApiClient(
      client: MockClient((request) async {
        requests.add(request.url);
        switch (request.url.path) {
          case '/api/fs/list':
            return http.Response(
              '{"path":"/repo","entries":[]}',
              200,
              headers: {'content-type': 'application/json'},
            );
          case '/api/fs/read':
            return http.Response(
              '{"path":"/repo/README.md","size":0,"binary":false,"truncated":false,"modifiedAtMs":0,"mimeHint":"text/markdown","encoding":"utf8","contents":""}',
              200,
              headers: {'content-type': 'application/json'},
            );
          case '/api/fs/blob':
            return http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200);
          default:
            throw StateError('Unexpected path ${request.url.path}');
        }
      }),
    );

    await api.listDirectory(host, '/repo', agentProvider: 'codex');
    await api.readFile(host, '/repo/README.md', agentProvider: 'codex');
    final blobUri = api.fsBlobUri(
      host,
      '/repo/image.png',
      agentProvider: 'codex',
    );
    final blobBytes = await api.fetchFsBlob(
      host,
      '/repo/image.png',
      agentProvider: 'codex',
    );

    expect(blobUri.queryParameters.containsKey('agentProvider'), isFalse);
    expect(blobBytes, [1, 2, 3]);
    expect(requests, hasLength(3));
    for (final uri in requests) {
      expect(uri.queryParameters.containsKey('agentProvider'), isFalse);
    }
  });

  test('ApiClient sends file search sessionId and limit in the JSON body', () async {
    late Map<String, dynamic> body;
    final api = ApiClient(
      client: MockClient((request) async {
        expect(request.url.path, '/api/fs/search');
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          '{"files":[]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await api.searchFiles(host, query: 'server', sessionId: 'session-1', limit: 25);

    expect(body['query'], 'server');
    expect(body['sessionId'], 'session-1');
    expect(body['limit'], 25);
    expect(body.containsKey('sessionId?'), isFalse);
    expect(body.containsKey('limit?'), isFalse);
  });

  test('ApiClient sends browser preview targetUrl when provided', () async {
    late Map<String, dynamic> body;
    final api = ApiClient(
      client: MockClient((request) async {
        expect(request.url.path, '/api/browser-previews');
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'id': 'preview-1',
            'label': 'tenant.localhost:5173',
            'url': 'http://tenant.localhost:5173/app',
            'targetHost': 'tenant.localhost',
            'targetPort': 5173,
            'scheme': 'http',
            'cwd': null,
            'sessionId': 'session-1',
            'profileMode': 'sidemesh',
            'status': 'running',
            'width': 390,
            'height': 844,
            'clients': 0,
            'createdAt': 1,
            'updatedAt': 1,
            'lastClientAt': null,
            'lastFrameAt': null,
            'lastError': null,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    await api.createBrowserPreview(
      host,
      targetPort: 5173,
      targetHost: 'tenant.localhost',
      targetUrl: ' http://tenant.localhost:5173/app ',
      sessionId: 'session-1',
      profileMode: 'sidemesh',
    );

    expect(body['targetHost'], 'tenant.localhost');
    expect(body['targetPort'], 5173);
    expect(body['targetUrl'], 'http://tenant.localhost:5173/app');
    expect(body['sessionId'], 'session-1');
  });
}
