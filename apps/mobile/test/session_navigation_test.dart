import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/session_screen.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'test_path_provider.dart';

void main() {
  setUpAll(() async {
    await configureTestDatabaseFactory();
  });

  setUp(() async {
    SessionLocalStore.instance.resetMigrationState();
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'switching sessions from the mobile drawer replaces the current route',
    (tester) async {
      await _pumpApp(tester, const _SessionNavigationHarness());
      await _pumpFrames(tester);

      await tester.tap(find.text('Open Session A'));
      await _pumpFrames(tester);
      expect(find.text('Session A'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.menu_rounded).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Session B').hitTestable());
      await _pumpFrames(tester);

      expect(find.text('Session B'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Session A'), findsNothing);
      expect(find.text('Session B'), findsNothing);
    },
  );

  testWidgets(
    'drawer Sessions action returns to home instead of the previous session',
    (tester) async {
      await _pumpApp(tester, const _SessionNavigationHarness());
      await _pumpFrames(tester);

      await tester.tap(find.text('Open Session A'));
      await _pumpFrames(tester);
      expect(find.text('Session A'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.menu_rounded).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Session B').hitTestable());
      await _pumpFrames(tester);
      expect(find.text('Session B'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.menu_rounded).hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Sessions').hitTestable());
      await tester.pumpAndSettle();

      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Session A'), findsNothing);
      expect(find.text('Session B'), findsNothing);
    },
  );
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpApp(WidgetTester tester, Widget child) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(430, 932);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      home: child,
    ),
  );
}

class _SessionNavigationHarness extends StatefulWidget {
  const _SessionNavigationHarness();

  @override
  State<_SessionNavigationHarness> createState() =>
      _SessionNavigationHarnessState();
}

class _SessionNavigationHarnessState extends State<_SessionNavigationHarness> {
  final HostProfile _host = HostProfile(
    id: 'session-nav-host',
    label: 'Fake Host',
    baseUrl: 'http://127.0.0.1:4099',
    token: 'test-token',
  );
  late final SessionSummary _sessionA = _session('session-a', 'Session A');
  late final SessionSummary _sessionB = _session('session-b', 'Session B');
  late final _NavigationFakeApi _api = _NavigationFakeApi(_nodeInfo());

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  Route<void> _buildSessionRoute(SessionSummary session) {
    return MaterialPageRoute<void>(
      builder: (context) => SessionScreen(
        host: _host,
        session: session,
        api: _api,
        onReturnToSessionList: () =>
            Navigator.of(context).popUntil((route) => route.isFirst),
        sessionDrawer: (ctx) => ListView(
          children: [
            ListTile(
              title: const Text('Session B'),
              onTap: () {
                Navigator.of(ctx).pop();
                unawaited(_openSession(_sessionB, replaceCurrentRoute: true));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSession(
    SessionSummary session, {
    bool replaceCurrentRoute = false,
  }) async {
    final navigator = Navigator.of(context);
    final route = _buildSessionRoute(session);
    if (replaceCurrentRoute) {
      await navigator.pushReplacement<void, void>(route);
    } else {
      await navigator.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Home'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => unawaited(_openSession(_sessionA)),
              child: const Text('Open Session A'),
            ),
          ],
        ),
      ),
    );
  }
}

SessionSummary _session(String id, String title) {
  final now = DateTime(2026, 1, 1, 12);
  return SessionSummary(
    id: id,
    title: title,
    preview: '',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'fake',
    provider: 'fake',
    status: 'loaded',
    runtime: null,
    gitInfo: null,
  );
}

NodeInfo _nodeInfo() => NodeInfo.fromJson({
  'label': 'fake-profile',
  'hostname': 'localhost',
  'platform': 'darwin',
  'codexVersion': 'fake-provider 1.0.0',
  'provider': 'fake',
  'providerName': 'Fake Test Provider',
  'providerVersion': 'fake-provider 1.0.0',
  'providerConfig': {'kind': 'fake', 'command': 'builtin'},
  'providerCapabilities': {
    'sessions': {'history': true},
  },
  'defaultProviderCapabilities': {
    'sessions': {'history': true},
  },
  'hostCapabilities': {
    'workspace': {'filesystem': false, 'gitStatus': false, 'gitDiff': false},
  },
  'supportedProviders': const [],
});

class _NavigationFakeApi extends ApiClient {
  _NavigationFakeApi(this.node);

  final NodeInfo node;
  final _IdleWebSocketChannel _channel = _IdleWebSocketChannel();

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => node;

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async => SessionLog(
    session: _session(sessionId, sessionId == 'session-a' ? 'Session A' : 'Session B'),
    messages: const [],
    activities: const [],
    pendingAction: null,
    history: const SessionLogHistorySummary(
      isTruncated: false,
      totalMessages: 0,
      returnedMessages: 0,
      totalActivities: 0,
      returnedActivities: 0,
    ),
  );

  @override
  WebSocketChannel openLive(HostProfile host, String sessionId) => _channel;

  void dispose() => _channel.dispose();
}

class _IdleWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _IdleWebSocketSink(_outgoing.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  void dispose() {
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
  }
}

class _IdleWebSocketSink implements WebSocketSink {
  _IdleWebSocketSink(this._delegate);

  final StreamSink<dynamic> _delegate;

  @override
  Future<void> addStream(Stream<dynamic> stream) => _delegate.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _delegate.close();

  @override
  Future<void> get done => _delegate.done;

  @override
  void add(dynamic data) => _delegate.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);
}
