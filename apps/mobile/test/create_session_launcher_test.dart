import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/create_session_sheet.dart';

void main() {
  testWidgets('host launcher ignores disabled hosts', (tester) async {
    Future<CreateSessionLaunchResult?>? launch;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                launch = showCreateSessionHostLauncher(
                  context,
                  hosts: const [
                    HostProfile(
                      id: 'host-1',
                      label: 'Disabled MacBook',
                      baseUrl: 'http://macbook.local:8787',
                      token: 'secret',
                      enabled: false,
                    ),
                  ],
                  api: ApiClient(),
                );
              },
              child: const Text('launch'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('launch'));
    await tester.pump();

    expect(await launch, isNull);
  });
}
