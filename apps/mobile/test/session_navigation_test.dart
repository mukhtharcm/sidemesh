import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/widgets/app_composer.dart';
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

  testWidgets('failed initial load disables composer and retry restores the empty state', (tester) async {
    final api = _NavigationFakeApi(_nodeInfo())..failLoad = true;
    addTearDown(api.dispose);
    await _pumpApp(tester, SessionScreen(
      host: const HostProfile(id: 'failed-load', label: 'Machine', baseUrl: 'http://127.0.0.1:4099', token: 'test-token'),
      session: _session('failed-load', 'Session'), api: api));
    await _pumpFrames(tester);
    expect(find.text('Could not load this session'), findsOneWidget);
    expect(tester.widget<AppComposer>(find.byType(AppComposer)).enabled, isFalse);
    api.failLoad = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
    await _pumpFrames(tester);
    expect(find.text('Could not load this session'), findsNothing);
    expect(find.text('What would you like to work on?'), findsOneWidget);
    expect(tester.widget<AppComposer>(find.byType(AppComposer)).enabled, isTrue);
  });

  testWidgets('back chevron returns to the session list without a drawer', (tester) async {
    await _pumpApp(tester, const _SessionNavigationHarness());
    await _pumpFrames(tester);
    await tester.tap(find.text('Open Session A'));
    await _pumpFrames(tester);
    expect(find.text('Session A'), findsOneWidget);
    expect(find.byType(Drawer), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Session A'), findsNothing);
  });

  testWidgets('iOS edge swipe returns at a normal gesture distance', (tester) async {
    await _pumpApp(tester, const _SessionNavigationHarness(), platform: TargetPlatform.iOS);
    await _pumpFrames(tester);
    await tester.tap(find.text('Open Session A'));
    await _pumpFrames(tester);
    await tester.pumpAndSettle();
    await tester.flingFrom(const Offset(1, 400), const Offset(200, 0), 800);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Session A'), findsNothing);
  });

  testWidgets('system back returns to the session list', (tester) async {
    await _pumpApp(tester, const _SessionNavigationHarness());
    await _pumpFrames(tester);
    await tester.tap(find.text('Open Session A'));
    await _pumpFrames(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Session A'), findsNothing);
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpApp(WidgetTester tester, Widget child, {TargetPlatform? platform}) async {
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
      theme: buildLightTheme(palette.light).copyWith(platform: platform),
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
  bool failLoad = false;
  final _IdleWebSocketChannel _channel = _IdleWebSocketChannel();

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => node;

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async {
    if (failLoad) throw Exception("Unavailable");
    return SessionLog(
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
  }

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
