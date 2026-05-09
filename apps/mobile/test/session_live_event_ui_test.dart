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

  testWidgets('session screen keeps only the latest plan update per session', (
    tester,
  ) async {
    final session = _session('latest-plan-only');
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('latest-plan-only'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit(_planUpdatedEvent(
      session.id,
      turnId: 'turn-1',
      explanation: 'Initial plan.',
      plan: const [
        {'step': 'Inspect the bug', 'status': 'completed'},
      ],
    ));
    api.emit(_planUpdatedEvent(
      session.id,
      turnId: 'turn-2',
      explanation: 'Revised plan.',
      plan: const [
        {'step': 'Ship the fix', 'status': 'in_progress'},
      ],
    ));
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsOneWidget);
    expect(find.text('Inspect the bug'), findsNothing);
    expect(find.text('Ship the fix'), findsOneWidget);
    expect(find.text('Revised plan.'), findsOneWidget);
  });

  testWidgets('session screen keeps one plan update after reopening', (
    tester,
  ) async {
    final session = _session('plan-reopen');
    final latestPlanUpdate = LiveEvent.fromJson(
      _planUpdatedEvent(
        session.id,
        turnId: 'turn-1',
        explanation: 'Keep the latest plan visible.',
        plan: const [
          {'step': 'Render from snapshot', 'status': 'completed'},
          {'step': 'Avoid duplicates on reopen', 'status': 'in_progress'},
        ],
        seq: 3,
      ),
    );
    final initialApi = _RichEventFakeApi(latestPlanUpdate: latestPlanUpdate);
    addTearDown(initialApi.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('plan-reopen'),
        session: session,
        api: initialApi,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsOneWidget);
    expect(find.text('Avoid duplicates on reopen'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester);

    final reopenedApi = _RichEventFakeApi(latestPlanUpdate: latestPlanUpdate);
    addTearDown(reopenedApi.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('plan-reopen'),
        session: session,
        api: reopenedApi,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsOneWidget);
    expect(find.text('Avoid duplicates on reopen'), findsOneWidget);
  });

  testWidgets('session screen restores a missed plan update from delta replay', (
    tester,
  ) async {
    final session = _session('plan-delta-replay');
    final api = _RichEventFakeApi(
      messages: [
        _assistantMessage(
          id: 'seed-message',
          text: 'Existing transcript item.',
          content: const [TextBlock('Existing transcript item.')],
        ),
      ],
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 1,
        nextSeq: 3,
        messages: const [],
        activities: const [],
        latestPlanUpdate: LiveEvent.fromJson(
          _planUpdatedEvent(
            session.id,
            turnId: 'turn-2',
            explanation: 'Recovered from /events.',
            plan: const [
              {'step': 'Catch up missed plan state', 'status': 'in_progress'},
            ],
            seq: 2,
          ),
        ),
        pendingAction: null,
        session: null,
      ),
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('plan-delta-replay'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Catch up missed plan state'), findsNothing);

    api.emit({
      'type': 'hello',
      'sessionId': session.id,
      'nextSeq': 3,
    });
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsOneWidget);
    expect(find.text('Catch up missed plan state'), findsOneWidget);
    expect(find.text('Recovered from /events.'), findsOneWidget);
  });

  testWidgets('completed assistant message keeps collapsed reasoning visible', (
    tester,
  ) async {
    final session = _session('reasoning-collapse');
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('reasoning-collapse'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({
      'type': 'reasoning_delta',
      'sessionId': session.id,
      'delta': 'Step one.',
      'summary': false,
    });
    await _pumpFrames(tester);

    expect(find.text('Step one.'), findsOneWidget);

    api.emit({
      'type': 'assistant_message_completed',
      'sessionId': session.id,
      'messageItem': {
        'id': 'msg-1',
        'role': 'assistant',
        'text': 'Final answer.',
        'attachments': [],
        'createdAt': DateTime(2026, 1, 1, 12, 1).millisecondsSinceEpoch,
        'seq': 1,
        'phase': 'answer',
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Step one.'), findsNothing);
    expect(find.text('Final answer.'), findsOneWidget);
    expect(find.text('Reasoning'), findsOneWidget);

    final reasoningLabel = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((widget) => widget.text.toPlainText() == 'Reasoning');
    expect(
      (reasoningLabel.text as TextSpan).style?.color,
      ThemeVariant.codexAmber.light.textPrimary,
    );

    await tester.tap(find.text('Reasoning'));
    await _pumpFrames(tester);

    expect(find.text('Step one.'), findsOneWidget);
  });

  testWidgets('persisted assistant reasoning starts collapsed and expands as text', (
    tester,
  ) async {
    final session = _session('persisted-reasoning');
    final api = _RichEventFakeApi(
      messages: [
        _assistantMessage(
          id: 'answer-with-reasoning',
          text: 'Visible answer.',
          content: const [
            ThinkingBlock(
              '**Troubleshooting merge issues**\n\n'
              'New reasoning should render as selectable text.',
            ),
            TextBlock('Visible answer.'),
          ],
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('persisted-reasoning'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Visible answer.'), findsOneWidget);
    expect(find.text('Reasoning'), findsOneWidget);
    expect(find.textContaining('Troubleshooting'), findsNothing);

    await tester.tap(find.text('Reasoning'));
    await _pumpFrames(tester);

    expect(find.textContaining('Troubleshooting'), findsOneWidget);
    expect(
      find.textContaining('New reasoning should render as selectable text.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'session screen surfaces preview, terminal, and file actions from activities',
    (tester) async {
      final session = _session('activity-actions');
      final api = _RichEventFakeApi(
        sessionSummary: session,
        nodeInfo: _nodeInfo(
          hostWorkspaceCapabilities: const {
            'filesystem': true,
            'gitStatus': false,
            'gitDiff': false,
            'browserPreview': true,
            'terminal': true,
          },
        ),
        activities: [
          _commandActivity(
            id: 'cmd-preview',
            seq: 2,
            command: 'npm run dev',
            cwd: '/repo/apps/web',
            output: 'Local: http://localhost:3000',
          ),
          _fileChangeActivity(
            id: 'file-change',
            seq: 1,
            path: '/repo/apps/web/src/main.dart',
          ),
        ],
      );
      addTearDown(api.dispose);

      await _pumpApp(
        tester,
        SessionScreen(
          host: _host('activity-actions'),
          session: session,
          api: api,
          desktopMode: true,
        ),
        size: const Size(1180, 900),
      );
      await _pumpFrames(tester);

      await tester.tap(find.text('npm run dev'));
      await _pumpFrames(tester);
      await tester.tap(find.text('apps/web/src/main.dart'));
      await _pumpFrames(tester);

      expect(find.text('Preview :3000'), findsOneWidget);
      expect(find.text('Open terminal'), findsOneWidget);
      expect(find.text('Browse files'), findsOneWidget);
      expect(find.text('Open file'), findsOneWidget);
    },
  );

  testWidgets('mobile running session shows stop pill and stops after confirmation', (
    tester,
  ) async {
    final session = _session('mobile-stop');
    final api = _RichEventFakeApi(sessionSummary: session);
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('mobile-stop'),
        session: session,
        api: api,
        desktopMode: false,
      ),
      size: const Size(430, 900),
    );
    await _pumpFrames(tester);

    api.emit({
      'type': 'thread_status_changed',
      'sessionId': session.id,
      'status': 'running',
    });
    await _pumpFrames(tester);

    expect(find.text('Stop agent'), findsOneWidget);

    await tester.tap(find.text('Stop agent'));
    await _pumpFrames(tester);

    expect(find.text('Stop session?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Stop'));
    await _pumpFrames(tester);

    expect(api.stopSessionCalls, 1);
    expect(find.text('Stop agent'), findsNothing);
    expect(find.text('Session stopped.'), findsOneWidget);
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

SessionSummary _session(String id, {String status = 'idle'}) {
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
    status: status,
    runtime: null,
    gitInfo: null,
  );
}

SessionMessage _assistantMessage({
  required String id,
  required String text,
  required List<ContentBlock> content,
}) {
  final now = DateTime(2026, 1, 1, 12);
  return SessionMessage(
    id: id,
    role: 'assistant',
    text: text,
    content: content,
    attachments: const [],
    createdAt: now,
    seq: 1,
    phase: 'final_answer',
  );
}

SessionActivity _commandActivity({
  required String id,
  required int seq,
  required String command,
  required String cwd,
  required String output,
}) {
  final now = DateTime(2026, 1, 1, 12).add(Duration(minutes: seq));
  return SessionActivity(
    id: id,
    type: 'command',
    createdAt: now,
    seq: seq,
    status: 'completed',
    turnId: 'turn-$seq',
    command: command,
    cwd: cwd,
    output: output,
    exitCode: 0,
    durationMs: 1200,
    source: 'agent',
    processId: 'pty-$seq',
    commandActions: const [],
    terminalStatus: null,
    terminalInput: null,
    toolName: null,
    toolTitle: null,
    toolArgs: null,
    toolResult: null,
    toolError: null,
    toolSemantic: null,
    changes: const [],
    diff: null,
    query: null,
    queries: const [],
    targetUrl: null,
    pattern: null,
    revisedPrompt: null,
    savedPath: null,
  );
}

SessionActivity _fileChangeActivity({
  required String id,
  required int seq,
  required String path,
}) {
  final now = DateTime(2026, 1, 1, 12).add(Duration(minutes: seq));
  return SessionActivity(
    id: id,
    type: 'file_change',
    createdAt: now,
    seq: seq,
    status: 'completed',
    turnId: 'turn-$seq',
    command: null,
    cwd: '/repo',
    output: null,
    exitCode: null,
    durationMs: null,
    source: null,
    processId: null,
    commandActions: const [],
    terminalStatus: null,
    terminalInput: null,
    toolName: null,
    toolTitle: null,
    toolArgs: null,
    toolResult: null,
    toolError: null,
    toolSemantic: null,
    changes: [
      SessionActivityChange(
        path: path,
        kind: 'modified',
        diff: '@@ -1 +1 @@\n-old\n+new',
      ),
    ],
    diff: null,
    query: null,
    queries: const [],
    targetUrl: null,
    pattern: null,
    revisedPrompt: null,
    savedPath: null,
  );
}

NodeInfo _nodeInfo({
  Map<String, Object?> hostWorkspaceCapabilities = const {
    'filesystem': false,
    'gitStatus': false,
    'gitDiff': false,
  },
}) => NodeInfo.fromJson({
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
  'hostCapabilities': {'workspace': hostWorkspaceCapabilities},
  'supportedProviders': const [],
});

class _RichEventFakeApi extends ApiClient {
  _RichEventFakeApi({
    this.messages = const [],
    this.activities = const [],
    this.latestPlanUpdate,
    this.eventsDelta,
    this.nodeInfo,
    this.sessionSummary,
  });

  final _ControllableWebSocketChannel _channel = _ControllableWebSocketChannel();
  List<SessionMessage> messages;
  final List<SessionActivity> activities;
  final LiveEvent? latestPlanUpdate;
  final SessionEventsDelta? eventsDelta;
  final NodeInfo? nodeInfo;
  final SessionSummary? sessionSummary;
  int stopSessionCalls = 0;

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => nodeInfo ?? _nodeInfo();

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async => SessionLog(
    session: sessionSummary ?? _session(sessionId),
    messages: messages,
    activities: activities,
    pendingAction: null,
    history: SessionLogHistorySummary(
      isTruncated: false,
      totalMessages: messages.length,
      returnedMessages: messages.length,
      totalActivities: activities.length,
      returnedActivities: activities.length,
    ),
    latestPlanUpdate: latestPlanUpdate,
  );

  @override
  Future<SessionEventsDelta> fetchEvents(
    HostProfile host,
    String sessionId, {
    required int since,
  }) async => eventsDelta ??
      SessionEventsDelta(
        sessionId: sessionId,
        since: since,
        nextSeq: since,
        messages: const [],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: null,
      );

  @override
  Future<SkillCatalog> fetchSkills(
    HostProfile host, {
    required String cwd,
    bool forceReload = false,
    String? agentProvider,
  }) async => SkillCatalog(cwd: cwd, skills: const [], errors: const []);

  @override
  Future<void> stopSession(HostProfile host, String sessionId) async {
    stopSessionCalls += 1;
  }

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

Map<String, Object?> _planUpdatedEvent(
  String sessionId, {
  required String turnId,
  required String explanation,
  required List<Map<String, Object?>> plan,
  int? seq,
}) {
  final event = <String, Object?>{
    'type': 'plan_updated',
    'sessionId': sessionId,
    'turnId': turnId,
    'explanation': explanation,
    'plan': plan,
  };
  if (seq case final value?) {
    event['seq'] = value;
  }
  return event;
}
