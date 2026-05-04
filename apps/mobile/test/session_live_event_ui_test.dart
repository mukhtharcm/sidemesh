import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sidemesh_mobile/src/api_client.dart';
import 'package:sidemesh_mobile/src/db.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/screens/session_screen.dart';
import 'package:sidemesh_mobile/src/session_local_store.dart';
import 'package:sidemesh_mobile/src/theme/app_palettes.dart';
import 'package:sidemesh_mobile/src/theme/app_theme.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:stream_channel/stream_channel.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationDocumentsPath() async => '/tmp/sidemesh_test';
  @override
  Future<String?> getApplicationSupportPath() async => '/tmp/sidemesh_test';
  @override
  Future<String?> getTemporaryPath() async => '/tmp/sidemesh_test';
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    PathProviderPlatform.instance = _FakePathProvider();
  });

  setUp(() async {
    SessionLocalStore.instance.resetMigrationState();
    final db = await SidemeshDb.instance;
    await db.delete('sessions');
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('session screen renders warning, plan, queue, and retry live events', (
    tester,
  ) async {
    final session = _session('rich-live-session');
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('rich-live'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({
      'type': 'provider_warning',
      'sessionId': session.id,
      'level': 'warning',
      'code': 'warn-1',
      'message': 'Heads up from the fake provider',
      'source': 'fake/runtime',
    });
    api.emit({
      'type': 'plan_updated',
      'sessionId': session.id,
      'turnId': 'turn-1',
      'explanation': 'Follow the rollout plan.',
      'plan': [
        {'step': 'Review docs', 'status': 'completed'},
        {'step': 'Ship the change', 'status': 'in_progress'},
      ],
    });
    api.emit({
      'type': 'queue_updated',
      'sessionId': session.id,
      'steeringCount': 1,
      'followUpCount': 2,
      'steeringPreview': ['Keep it provider-neutral'],
      'followUpPreview': ['Add tests', 'Run analyze'],
    });
    api.emit({
      'type': 'auto_retry_updated',
      'sessionId': session.id,
      'phase': 'started',
      'attempt': 2,
      'maxAttempts': 3,
      'delayMs': 1500,
      'errorMessage': 'Overloaded',
    });
    await _pumpFrames(tester);

    expect(find.text('Heads up from the fake provider'), findsOneWidget);
    expect(find.text('Ship the change'), findsOneWidget);
    expect(find.text('Queue · 1 steering · 2 follow-up'), findsOneWidget);
    expect(find.text('Retry 2 / 3 in 1.5s'), findsOneWidget);
    expect(find.textContaining('Keep it provider-neutral'), findsOneWidget);
    expect(find.textContaining('Overloaded'), findsOneWidget);
  });

  testWidgets('reasoning text stays readable on light palettes', (tester) async {
    final session = _session('reasoning-contrast');
    final api = _RichEventFakeApi(
      messages: [
        SessionMessage(
          id: 'msg-reasoning',
          role: 'assistant',
          text: '',
          content: const [ThinkingBlock('Audit the reasoning renderer.')],
          attachments: const [],
          createdAt: DateTime(2026, 1, 1, 12, 1),
          seq: 1,
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('reasoning-contrast'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
      palette: ThemeVariant.tokyoNight,
    );
    await _pumpFrames(tester);

    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.text('Audit the reasoning renderer.'), findsOneWidget);

    final reasoningText = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere(
          (widget) =>
              widget.text.toPlainText() == 'Audit the reasoning renderer.',
        );
    final color = (reasoningText.text as TextSpan).style?.color;
    expect(color, ThemeVariant.tokyoNight.light.textPrimary);
  });
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
  required Size size,
  ThemeVariant palette = ThemeVariant.codexAmber,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      home: Scaffold(body: child),
    ),
  );
}

HostProfile _host(String id) => HostProfile(
  id: 'session-live-$id',
  label: 'Fake Host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

SessionSummary _session(String id) {
  final now = DateTime(2026, 1, 1, 12);
  return SessionSummary(
    id: id,
    title: 'Fake session',
    preview: '',
    cwd: '/repo',
    createdAt: now,
    updatedAt: now,
    source: 'fake',
    provider: null,
    status: 'idle',
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
    'sessions': {
      'create': true,
      'history': true,
      'interrupt': true,
      'archive': true,
    },
    'input': {
      'text': true,
      'imageUrl': false,
      'localImage': false,
      'skills': false,
    },
    'configuration': {
      'models': false,
      'profiles': false,
      'skills': false,
    },
    'runtimeControls': {
      'model': false,
      'approvalPolicy': false,
      'sandboxMode': false,
      'networkAccess': false,
    },
    'workspace': {'remoteGitDiff': false},
  },
  'defaultProviderCapabilities': {
    'sessions': {
      'create': true,
      'history': true,
      'interrupt': true,
      'archive': true,
    },
    'input': {
      'text': true,
      'imageUrl': false,
      'localImage': false,
      'skills': false,
    },
    'configuration': {
      'models': false,
      'profiles': false,
      'skills': false,
    },
    'runtimeControls': {
      'model': false,
      'approvalPolicy': false,
      'sandboxMode': false,
      'networkAccess': false,
    },
    'workspace': {'remoteGitDiff': false},
  },
  'hostCapabilities': {
    'workspace': {'filesystem': false, 'gitStatus': false, 'gitDiff': false},
  },
  'supportedProviders': const [],
});

class _RichEventFakeApi extends ApiClient {
  _RichEventFakeApi({this.messages = const []});

  final _ControllableWebSocketChannel _channel = _ControllableWebSocketChannel();
  final List<SessionMessage> messages;

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => _nodeInfo();

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async => SessionLog(
    session: _session(sessionId),
    messages: messages,
    activities: const [],
    pendingAction: null,
    history: SessionLogHistorySummary(
      isTruncated: false,
      totalMessages: messages.length,
      returnedMessages: messages.length,
      totalActivities: 0,
      returnedActivities: 0,
    ),
  );

  @override
  Future<SkillCatalog> fetchSkills(
    HostProfile host, {
    required String cwd,
    bool forceReload = false,
    String? agentProvider,
  }) async => SkillCatalog(cwd: cwd, skills: const [], errors: const []);

  @override
  WebSocketChannel openLive(HostProfile host, String sessionId) => _channel;

  void emit(Map<String, Object?> event) {
    _channel.emit(jsonEncode(event));
  }

  void dispose() => _channel.dispose();
}

class _ControllableWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _outgoing = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _TestWebSocketSink(_outgoing.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready async {}

  void emit(String raw) {
    _incoming.add(raw);
  }

  void dispose() {
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
  }
}

class _TestWebSocketSink implements WebSocketSink {
  _TestWebSocketSink(this._delegate);

  final StreamSink<dynamic> _delegate;

  @override
  Future<void> addStream(Stream<dynamic> stream) => _delegate.addStream(stream);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _delegate.addError(error, stackTrace);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _delegate.close();

  @override
  Future<void> get done => _delegate.done;

  @override
  void add(dynamic data) => _delegate.add(data);
}
