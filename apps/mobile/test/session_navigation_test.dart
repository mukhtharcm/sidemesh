import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/session_screen.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/session_pins_store.dart';
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
    await db.delete('session_logs');
    await db.delete('session_outbox');
    await db.delete('client_migrations');
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('Git details fit and refresh in place in $mode', (
      tester,
    ) async {
      final api = _NavigationFakeApi(_nodeInfo(git: true));
      addTearDown(api.dispose);
      await _pumpApp(
        tester,
        SessionScreen(
          host: HostProfile(
            id: 'git-test',
            label: 'Mac',
            baseUrl: 'http://localhost:4099',
            token: 'test',
          ),
          session: _session('session-a', 'Session A'),
          api: api,
          desktopMode: true,
        ),
        size: const Size(1180, 760),
        mode: mode,
      );
      await _pumpFrames(tester);
      await tester.tap(find.byTooltip('Workspace tools'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Git'));
      await tester.pumpAndSettle();
      expect(find.text('Git details'), findsOneWidget);
      expect(find.text('Working diff').hitTestable(), findsOneWidget);
      expect(find.text('Staged diff').hitTestable(), findsOneWidget);
      expect(find.text('1 changed'), findsOneWidget);
      expect(find.text('Repository'), findsNothing);
      expect(
        find
            .byType(SelectableText)
            .evaluate()
            .where((e) => (e.widget as SelectableText).data == '/repo'),
        hasLength(1),
      );
      final titleY = tester.getTopLeft(find.text('Git details')).dy;
      expect(titleY, lessThan(380));
      api.gitRefresh = Completer<SessionGitStatus>();
      await tester.tap(find.byTooltip('Refresh Git status'));
      await tester.pump();
      expect(find.text('Git details'), findsOneWidget);
      expect(find.text('1 changed'), findsOneWidget);
      api.gitRefresh!.complete(
        SessionGitStatus.fromJson({
          'isRepo': true,
          'cwd': '/repo',
          'repoRoot': '/repo',
          'branch': 'main',
          'dirty': false,
          'changed': 0,
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('No changes'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Git details')).dy, titleY);
      expect(find.byTooltip('Refresh Git status'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Git details'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('pin detail replaces the mobile list in $mode', (tester) async {
      final host = HostProfile(
        id: 'pin-$mode',
        label: 'Mac',
        baseUrl: 'http://localhost:4099',
        token: 'test',
      );
      final session = _session('pin-$mode', 'Pinned session');
      await SessionPinsStore.instance.pin(
        host,
        session.id,
        SessionMessage(
          id: 'pin-message',
          attachments: const [],
          role: 'user',
          text: 'Saved text',
          createdAt: DateTime.now(),
          seq: 1,
        ),
      );
      final api = _NavigationFakeApi(_nodeInfo());
      addTearDown(api.dispose);
      await _pumpApp(
        tester,
        SessionScreen(host: host, session: session, api: api),
        mode: mode,
      );
      await _pumpFrames(tester);
      await tester.tap(find.byTooltip('Session actions'));
      await tester.pumpAndSettle();
      expect(find.text('New session'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      await tester.tap(find.text('Workspace tools'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Pinned messages'));
      await tester.tap(find.text('Pinned messages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved text'));
      await tester.pumpAndSettle();
      expect(find.text('Pinned message'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byTooltip('Copy message').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Unpin message'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(SessionPinsStore.instance.pinsFor(host, session.id), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final directReturn in [true, false]) {
    testWidgets('mobile back returns home (callback: $directReturn)', (
      tester,
    ) async {
      await _pumpApp(
        tester,
        _SessionNavigationHarness(directReturn: directReturn),
      );
      await _pumpFrames(tester);
      await tester.tap(find.text('Open Session A'));
      await _pumpFrames(tester);
      expect(find.text('Session A'), findsOneWidget);
      expect(find.byType(Drawer), findsNothing);
      await tester.tap(find.byTooltip('Back to sessions'));
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Session A'), findsNothing);
    });
  }
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpApp(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(430, 932),
  ThemeMode mode = ThemeMode.light,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      themeMode: mode,
      home: child,
    ),
  );
}

class _SessionNavigationHarness extends StatefulWidget {
  const _SessionNavigationHarness({required this.directReturn});

  final bool directReturn;

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
        onReturnToSessionList: widget.directReturn
            ? () => Navigator.of(context).popUntil((route) => route.isFirst)
            : null,
      ),
    );
  }

  Future<void> _openSession(SessionSummary session) async {
    await Navigator.of(context).push(_buildSessionRoute(session));
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

NodeInfo _nodeInfo({bool git = false}) => NodeInfo.fromJson({
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
    'workspace': {'filesystem': false, 'gitStatus': git, 'gitDiff': git},
  },
  'supportedProviders': const [],
});

class _NavigationFakeApi extends ApiClient {
  _NavigationFakeApi(this.node);

  final NodeInfo node;
  final _IdleWebSocketChannel _channel = _IdleWebSocketChannel();

  Completer<SessionGitStatus>? gitRefresh;

  @override
  Future<SessionGitStatus> fetchGitStatus(
    HostProfile host,
    String sessionId,
  ) async =>
      gitRefresh?.future ??
      Future.value(
        SessionGitStatus.fromJson({
          'isRepo': true,
          'cwd': '/repo',
          'repoRoot': '/repo',
          'branch': 'main',
          'dirty': true,
          'changed': 1,
        }),
      );

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => node;

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async => SessionLog(
    session: _session(
      sessionId,
      sessionId == 'session-a' ? 'Session A' : 'Session B',
    ),
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
