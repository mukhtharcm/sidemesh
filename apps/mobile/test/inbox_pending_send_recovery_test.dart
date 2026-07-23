import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/home_screen.dart';
import 'package:sidemesh_mobile/src/session_send_outbox_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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
