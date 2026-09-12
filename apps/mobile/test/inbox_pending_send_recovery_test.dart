import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/session_send_outbox_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';

import 'test_path_provider.dart';

void main() {
  setUpAll(configureTestDatabaseFactory);
  tearDownAll(SidemeshDb.close);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = await SidemeshDb.instance;
    await db.delete('session_outbox');
    await db.delete('client_migrations');
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('failed outbox import keeps its data and shows retry in $mode', (tester) async {
      const original = '[invalid';
      SharedPreferences.setMockInitialValues({'sidemesh_pending_session_sends_v1': original});
      final palette = ThemeVariant.codexAmber;
      await tester.pumpWidget(MaterialApp(
        theme: buildLightTheme(palette.light), darkTheme: buildDarkTheme(palette.dark), themeMode: mode,
        home: Scaffold(body: InboxPane(
          hosts: const [], allHosts: const [], api: ApiClient(),
          onOpenSession: (host, action) {}, onOpenPendingSession: (host, session, composerSeed) async {},
          onEditHost: (host) async {}, onToggleHostEnabled: (host) async {}, onInboxCountChanged: (count) {},
        )),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Cannot load queued messages. Saved messages are still in local storage.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect((await SharedPreferences.getInstance()).getString('sidemesh_pending_session_sends_v1'), original);
      expect(await (await SidemeshDb.instance).query('session_outbox'), isEmpty);
    });
  }

  testWidgets(
    'use current host rebinds a changed pending send without leaving a stale copy',
    (tester) async {
      final store = SessionSendOutboxStore.instance;
      const currentHost = HostProfile(
        id: 'host-1',
        label: 'MacBook',
        baseUrl: 'http://macbook.local:8787',
        token: 'new-token',
      );
      const staleHost = HostProfile(
        id: 'host-1',
        label: 'MacBook',
        baseUrl: 'http://macbook.local:8787',
        token: 'old-token',
      );

      await store.upsert(_pendingSend(staleHost));

      await tester.pumpWidget(
        MaterialApp(
          home: InboxPane(
            hosts: const [],
            allHosts: const [currentHost],
            api: ApiClient(),
            onOpenSession: (host, action) {},
            onOpenPendingSession: (host, session, composerSeed) async {},
            onEditHost: (host) async {},
            onToggleHostEnabled: (host) async {},
            onInboxCountChanged: (count) {},
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Use current host'), findsOneWidget);
      expect(find.text('Discard'), findsNothing);
      expect(find.byTooltip('More actions'), findsOneWidget);

      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Discard'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use current host'));
      await tester.pumpAndSettle();

      final loaded = await store.loadAll();
      expect(loaded, hasLength(1));
      expect(
        loaded.single.hostFingerprint,
        SessionSendOutboxStore.hostFingerprint(currentHost),
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    },
  );
}

PendingSessionSend _pendingSend(HostProfile host) {
  final now = DateTime.now();
  return PendingSessionSend(
    hostId: host.id,
    hostFingerprint: SessionSendOutboxStore.hostFingerprint(host),
    sessionId: 'session-1',
    clientMessageId: 'local-1',
    text: 'hello',
    inputItems: const [SessionInputItem.text('hello')],
    message: SessionMessage(
      id: 'local-1',
      role: 'user',
      text: 'hello',
      attachments: const <SessionMessageAttachment>[],
      createdAt: now,
      seq: 1,
    ),
    createdAt: now,
    updatedAt: now,
    nextAttemptAt: now,
    retryCount: 0,
  );
}
