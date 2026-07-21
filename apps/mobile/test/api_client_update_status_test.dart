import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  const host = HostProfile(
    id: 'host-1',
    label: 'Build host',
    baseUrl: 'http://127.0.0.1:4242',
    token: 'secret-token',
  );

  test(
    'update API returns and refreshes persistent operation status',
    () async {
      final client = ApiClient(
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer secret-token');
          if (request.method == 'POST' &&
              request.url.path == '/api/admin/update') {
            expect(jsonDecode(request.body), {'channel': 'bleeding-edge'});
            return http.Response(
              jsonEncode({
                'ok': true,
                'update': _operationJson(state: 'queued', phase: 'queued'),
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path == '/api/admin/update-status') {
            return http.Response(
              jsonEncode({
                'ok': true,
                'update': _operationJson(
                  state: 'failed',
                  phase: 'completed',
                  restored: true,
                  error: 'candidate health check failed',
                ),
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
      );

      final queued = await client.updateDaemon(
        host,
        updateChannel: 'bleeding-edge',
      );
      expect(queued?.id, 'update-1');
      expect(queued?.isInProgress, isTrue);
      expect(queued?.shortTargetCommitSha, 'bbbbbbb');

      final failed = await client.fetchUpdateStatus(host);
      expect(failed?.isFailed, isTrue);
      expect(failed?.restored, isTrue);
      expect(failed?.error, 'candidate health check failed');
    },
  );

  test('update API remains compatible with old responses', () async {
    final client = ApiClient(
      client: MockClient(
        (_) async => http.Response('{"ok":true,"message":"updating"}', 200),
      ),
    );

    expect(await client.updateDaemon(host), isNull);
  });
}

Map<String, dynamic> _operationJson({
  required String state,
  required String phase,
  bool restored = false,
  String? error,
}) => {
  'version': 1,
  'id': 'update-1',
  'state': state,
  'phase': phase,
  'channel': 'bleeding-edge',
  'startedAt': 1000,
  'updatedAt': 2000,
  'finishedAt': state == 'failed' ? 2000 : null,
  'previousVersion': '0.2.2',
  'previousCommitSha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'targetVersion': null,
  'targetCommitSha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'installedVersion': restored ? '0.2.2' : null,
  'installedCommitSha': restored
      ? 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      : null,
  'restored': restored,
  'error': error,
  'logPath': '/tmp/update.log',
};
