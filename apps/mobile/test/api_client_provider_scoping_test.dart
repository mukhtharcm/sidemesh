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

  test(
    'ApiClient sends unified transcript page parameters with legacy limits',
    () async {
      Uri? requested;
      final api = ApiClient(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(
            jsonEncode({
              'session': {
                'id': 'session-1',
                'title': 'Session',
                'preview': '',
                'cwd': '/repo',
                'createdAt': 0,
                'updatedAt': 0,
                'source': 'fake',
                'provider': null,
                'status': 'idle',
                'runtime': null,
                'gitInfo': null,
              },
              'messages': [],
              'activities': [],
              'pendingAction': null,
              'history': null,
              'nextSeq': 7,
              'page': {'beforeCursor': 'opaque cursor', 'hasMoreBefore': true},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final log = await api.fetchLog(
        host,
        'session-1',
        messageLimit: 120,
        activityLimit: 80,
        entryLimit: 200,
        beforeCursor: 'opaque cursor',
      );

      expect(requested?.path, '/api/sessions/session-1/log');
      expect(requested?.queryParameters, {
        'messageLimit': '120',
        'activityLimit': '80',
        'entryLimit': '200',
        'beforeCursor': 'opaque cursor',
      });
      expect(log.nextSeq, 7);
      expect(log.page?.beforeCursor, 'opaque cursor');
    },
  );

  test('ApiClient opts into paged event replay', () async {
    Uri? requested;
    final api = ApiClient(
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(
          jsonEncode({
            'sessionId': 'session-1',
            'since': 7,
            'nextSeq': 8,
            'hasMore': true,
            'messages': [],
            'activities': [],
            'latestPlanUpdate': null,
            'pendingAction': null,
            'session': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final delta = await api.fetchEvents(
      host,
      'session-1',
      since: 7,
      baseUpdatedAt: 123,
    );

    expect(requested?.path, '/api/sessions/session-1/events');
    expect(requested?.queryParameters, {
      'since': '7',
      'page': 'true',
      'baseUpdatedAt': '123',
    });
    expect(delta.hasMore, isTrue);
  });

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

  test(
    'ApiClient sends file search sessionId and limit in the JSON body',
    () async {
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

      await api.searchFiles(
        host,
        query: 'server',
        sessionId: 'session-1',
        limit: 25,
      );

      expect(body['query'], 'server');
      expect(body['sessionId'], 'session-1');
      expect(body['limit'], 25);
      expect(body.containsKey('sessionId?'), isFalse);
      expect(body.containsKey('limit?'), isFalse);
    },
  );

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
      reuseExisting: false,
    );

    expect(body['targetHost'], 'tenant.localhost');
    expect(body['targetPort'], 5173);
    expect(body['targetUrl'], 'http://tenant.localhost:5173/app');
    expect(body['sessionId'], 'session-1');
    expect(body['reuseExisting'], false);
  });

  test('ApiClient accepts an empty close-tab response', () async {
    late http.Request captured;
    final api = ApiClient(
      client: MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      }),
    );

    await api.stopBrowserPreview(host, 'tab-1');

    expect(captured.method, 'DELETE');
    expect(captured.url.path, '/api/browser-previews/tab-1');
    expect(captured.headers['content-type'], isNull);
    expect(captured.headers['authorization'], 'Bearer secret');
  });
}
