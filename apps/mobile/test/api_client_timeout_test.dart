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

  test('ApiClient applies its default timeout to write requests', () async {
    final api = ApiClient(
      defaultWriteTimeout: const Duration(milliseconds: 10),
      client: MockClient((request) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      api.writeFile(host, path: '/repo/notes.txt', contents: ''),
      throwsA(
        isA<ApiTimeoutException>()
            .having((error) => error.operation, 'operation', 'write file')
            .having(
              (error) => error.timeout,
              'timeout',
              const Duration(milliseconds: 10),
            ),
      ),
    );
  });
}
