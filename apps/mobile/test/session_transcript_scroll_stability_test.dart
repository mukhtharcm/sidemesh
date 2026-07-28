import 'dart:async';
import 'dart:convert';

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
    'completion and snapshot reconciliation keep the reader anchored',
    (tester) async {
      final session = _session('reader-anchor', status: 'running');
      final initialMessages = _transcriptMessages(36);
      final api = _ScrollFakeApi(
        session: session,
        messages: initialMessages,
      );
      addTearDown(api.dispose);

      await _pumpSession(tester, session: session, api: api);
      final position = _transcriptPosition(tester);
      position.jumpTo(900);
      await tester.pump();

      final anchor = _visibleTranscriptAnchor(tester);
      final anchorY = tester.getTopLeft(find.text(anchor)).dy;
      expect(find.text('See latest').hitTestable(), findsOneWidget);

      api.emit({
        'type': 'assistant_delta',
        'sessionId': session.id,
        'itemId': 'final-answer',
        'delta':
            'I am checking the final details. '
            'This progress update deliberately occupies several lines so a '
            'reader would notice any uncorrected transcript movement. '
            'The visible paragraph above must stay exactly where it is.',
        'seq': 37,
      });
      await _pumpLiveUpdate(tester);

      expect(
        tester.getTopLeft(find.text(anchor)).dy,
        closeTo(anchorY, 1),
      );
      expect(find.text('See latest').hitTestable(), findsOneWidget);

      final finalMessage = SessionMessage(
        id: 'final-answer',
        role: 'assistant',
        text:
            'The answer is ready. The completed row replaces the live row '
            'without moving the transcript passage being read.',
        content: const [
          TextBlock(
            'The answer is ready. The completed row replaces the live row '
            'without moving the transcript passage being read.',
          ),
        ],
        attachments: const [],
        createdAt: DateTime(2026, 1, 1, 13),
        seq: 38,
        phase: 'final_answer',
      );
      api.messages = [...initialMessages, finalMessage];
      api.emit({
        'type': 'assistant_message_completed',
        'sessionId': session.id,
        'messageItem': finalMessage.toJson(),
        'seq': 38,
      });
      api.emit({
        'type': 'turn_completed',
        'sessionId': session.id,
        'seq': 39,
      });
      await _pumpLiveUpdate(tester);

      expect(find.text('Answer ready').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(anchor)).dy,
        closeTo(anchorY, 1),
      );

      // turn_completed performs a delayed authoritative snapshot reload.
      await tester.pump(const Duration(milliseconds: 1300));
      await _pumpLiveUpdate(tester);

      expect(find.text('Answer ready').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(anchor)).dy,
        closeTo(anchorY, 1),
      );

      await tester.tap(find.text('Answer ready').hitTestable());
      expect(position.pixels, closeTo(0, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(position.pixels, closeTo(0, 1));
      expect(find.text('Answer ready'), findsNothing);
      expect(find.text('See latest').hitTestable(), findsNothing);
    },
  );

  testWidgets(
    'turn completion without a message event still announces the answer',
    (tester) async {
      final session = _session('turn-completed-fallback', status: 'running');
      final api = _ScrollFakeApi(
        session: session,
        messages: _transcriptMessages(36),
      );
      addTearDown(api.dispose);

      await _pumpSession(tester, session: session, api: api);
      final position = _transcriptPosition(tester);
      position.jumpTo(900);
      await tester.pump();

      final anchor = _visibleTranscriptAnchor(tester);
      final anchorY = tester.getTopLeft(find.text(anchor)).dy;

      api.emit({
        'type': 'assistant_delta',
        'sessionId': session.id,
        'itemId': 'fallback-answer',
        'delta':
            'A complete response delivered only through the live stream.',
        'seq': 37,
      });
      await _pumpLiveUpdate(tester);

      api.emit({
        'type': 'turn_completed',
        'sessionId': session.id,
        'seq': 38,
      });
      await _pumpLiveUpdate(tester);

      expect(find.text('Answer ready').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text(anchor)).dy,
        closeTo(anchorY, 1),
      );

      await tester.pump(const Duration(milliseconds: 1300));
      await _pumpLiveUpdate(tester);
    },
  );

  testWidgets('a later turn replaces the stale answer-ready affordance', (
    tester,
  ) async {
    final session = _session('answer-ready-next-turn', status: 'running');
    final api = _ScrollFakeApi(
      session: session,
      messages: _transcriptMessages(36),
    );
    addTearDown(api.dispose);

    await _pumpSession(tester, session: session, api: api);
    _transcriptPosition(tester).jumpTo(900);
    await tester.pump();

    api.emit({
      'type': 'assistant_delta',
      'sessionId': session.id,
      'itemId': 'previous-answer',
      'delta': 'The previous answer.',
      'seq': 37,
    });
    await _pumpLiveUpdate(tester);
    api.emit({
      'type': 'assistant_message_completed',
      'sessionId': session.id,
      'messageItem': {
        'id': 'previous-answer',
        'role': 'assistant',
        'text': 'The previous answer.',
        'attachments': const [],
        'createdAt': DateTime(2026, 1, 1, 13).millisecondsSinceEpoch,
        'seq': 37,
        'phase': 'final_answer',
      },
      'seq': 38,
    });
    await _pumpLiveUpdate(tester);

    expect(find.text('Answer ready').hitTestable(), findsOneWidget);

    api.emit({
      'type': 'turn_started',
      'sessionId': session.id,
      'seq': 39,
    });
    await _pumpLiveUpdate(tester);

    expect(find.text('Answer ready'), findsNothing);
    expect(find.text('See latest').hitTestable(), findsOneWidget);
  });

  testWidgets('the first answer text promotes a reasoning-first row identity', (
    tester,
  ) async {
    final session = _session('reasoning-row-identity', status: 'running');
    final api = _ScrollFakeApi(session: session);
    addTearDown(api.dispose);

    await _pumpSession(tester, session: session, api: api);
    api.emit({
      'type': 'reasoning_delta',
      'sessionId': session.id,
      'itemId': 'reasoning-fragment',
      'delta': 'Reasoning before answer text.',
      'seq': 1,
    });
    await _pumpLiveUpdate(tester);

    expect(
      find.byKey(const ValueKey('msg:reasoning-fragment')),
      findsOneWidget,
    );

    api.emit({
      'type': 'assistant_delta',
      'sessionId': session.id,
      'itemId': 'assistant-answer',
      'delta': 'Now writing the answer.',
      'seq': 2,
    });
    await _pumpLiveUpdate(tester);

    expect(
      find.byKey(const ValueKey('msg:assistant-answer')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('msg:reasoning-fragment')),
      findsNothing,
    );
  });

  testWidgets('nearby live updates continue following the latest response', (
    tester,
  ) async {
    final session = _session('near-latest', status: 'running');
    final api = _ScrollFakeApi(
      session: session,
      messages: _transcriptMessages(24),
    );
    addTearDown(api.dispose);

    await _pumpSession(tester, session: session, api: api);
    final position = _transcriptPosition(tester);
    position.jumpTo(80);
    await tester.pump();

    expect(find.text('See latest').hitTestable(), findsNothing);

    api.emit({
      'type': 'assistant_delta',
      'sessionId': session.id,
      'delta': 'A live response that should remain followed.',
      'seq': 25,
    });
    await _pumpLiveUpdate(tester);

    expect(position.pixels, closeTo(0, 1));
    expect(find.text('See latest').hitTestable(), findsNothing);
  });

  testWidgets('a recent near-bottom drag is not pulled back to latest', (
    tester,
  ) async {
    final session = _session('recent-near-bottom-drag', status: 'running');
    final api = _ScrollFakeApi(
      session: session,
      messages: _transcriptMessages(24),
    );
    addTearDown(api.dispose);

    await _pumpSession(tester, session: session, api: api);
    final position = _transcriptPosition(tester);
    final drag = position.drag(
      DragStartDetails(globalPosition: const Offset(100, 300)),
      () {},
    );
    drag.update(
      DragUpdateDetails(
        globalPosition: const Offset(100, 410),
        delta: const Offset(0, 110),
        primaryDelta: 110,
      ),
    );
    drag.end(DragEndDetails(primaryVelocity: 0));
    await tester.pump();

    expect(position.pixels, greaterThan(40));
    expect(position.pixels, lessThan(160));

    api.emit({
      'type': 'assistant_delta',
      'sessionId': session.id,
      'itemId': 'near-bottom-update',
      'delta': 'This update must not undo the reader’s fresh drag.',
      'seq': 25,
    });
    await _pumpLiveUpdate(tester);

    expect(position.pixels, greaterThan(40));
  });

  testWidgets('a live layout update does not cancel an active reader drag', (
    tester,
  ) async {
    final session = _session('active-reader-drag', status: 'running');
    final api = _ScrollFakeApi(
      session: session,
      messages: _transcriptMessages(36),
    );
    addTearDown(api.dispose);

    await _pumpSession(tester, session: session, api: api);
    final position = _transcriptPosition(tester);
    position.jumpTo(900);
    await tester.pump();

    api.emit({
      'type': 'assistant_delta',
      'sessionId': session.id,
      'itemId': 'drag-update',
      'delta':
          'A live update arrives while the reader is actively moving the '
          'transcript.',
      'seq': 37,
    });
    await tester.pump();

    final drag = position.drag(
      DragStartDetails(globalPosition: const Offset(100, 300)),
      () {},
    );
    final beforeFirstMove = position.pixels;
    drag.update(
      DragUpdateDetails(
        globalPosition: const Offset(100, 210),
        delta: const Offset(0, -90),
        primaryDelta: -90,
      ),
    );
    await tester.pump();
    expect((position.pixels - beforeFirstMove).abs(), greaterThan(30));

    await tester.pump(const Duration(milliseconds: 60));
    final beforeSecondMove = position.pixels;
    drag.update(
      DragUpdateDetails(
        globalPosition: const Offset(100, 120),
        delta: const Offset(0, -90),
        primaryDelta: -90,
      ),
    );
    await tester.pump();

    expect((position.pixels - beforeSecondMove).abs(), greaterThan(30));
    drag.end(DragEndDetails(primaryVelocity: 0));
    await tester.pump();
  });

  testWidgets('visible working notes do not collapse when the answer arrives', (
    tester,
  ) async {
    final session = _session('reasoning-stays-open', status: 'running');
    final api = _ScrollFakeApi(session: session);
    addTearDown(api.dispose);

    await _pumpSession(tester, session: session, api: api);
    api.emit({
      'type': 'reasoning_delta',
      'sessionId': session.id,
      'itemId': 'reasoned-answer',
      'delta': 'A working note the reader has started reading.',
      'seq': 1,
    });
    await _pumpLiveUpdate(tester);

    expect(
      find.text('A working note the reader has started reading.'),
      findsOneWidget,
    );

    api.emit({
      'type': 'assistant_message_completed',
      'sessionId': session.id,
      'messageItem': {
        'id': 'reasoned-answer',
        'role': 'assistant',
        'text': 'Final answer.',
        'attachments': const [],
        'createdAt': DateTime(2026, 1, 1, 13).millisecondsSinceEpoch,
        'seq': 2,
        'phase': 'final_answer',
      },
      'seq': 2,
    });
    await _pumpLiveUpdate(tester);

    expect(find.text('Final answer.'), findsOneWidget);
    expect(
      find.text('A working note the reader has started reading.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'a manually collapsed working note stays collapsed on completion',
    (tester) async {
      final session = _session('reasoning-user-collapse', status: 'running');
      final api = _ScrollFakeApi(session: session);
      addTearDown(api.dispose);

      await _pumpSession(tester, session: session, api: api);
      api.emit({
        'type': 'reasoning_delta',
        'sessionId': session.id,
        'itemId': 'collapsed-reasoning-answer',
        'delta': 'A working note the reader chose to hide.',
        'seq': 1,
      });
      await _pumpLiveUpdate(tester);

      expect(
        find.text('A working note the reader chose to hide.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Working'));
      await tester.pump();
      expect(
        find.text('A working note the reader chose to hide.'),
        findsNothing,
      );

      api.emit({
        'type': 'assistant_message_completed',
        'sessionId': session.id,
        'messageItem': {
          'id': 'collapsed-reasoning-answer',
          'role': 'assistant',
          'text': 'Final answer.',
          'attachments': const [],
          'createdAt': DateTime(2026, 1, 1, 13).millisecondsSinceEpoch,
          'seq': 2,
          'phase': 'final_answer',
        },
        'seq': 2,
      });
      await _pumpLiveUpdate(tester);

      expect(find.text('Final answer.'), findsOneWidget);
      expect(
        find.text('A working note the reader chose to hide.'),
        findsNothing,
      );
      expect(find.text('Working notes'), findsOneWidget);
    },
  );
}

Future<void> _pumpSession(
  WidgetTester tester, {
  required SessionSummary session,
  required _ScrollFakeApi api,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(390, 844);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final palette = ThemeVariant.codexAmber;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(palette.light),
      darkTheme: buildDarkTheme(palette.dark),
      home: Scaffold(
        body: SessionScreen(
          host: _host(session.id),
          session: session,
          api: api,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _pumpLiveUpdate(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump();
}

ScrollPosition _transcriptPosition(WidgetTester tester) {
  final list = tester.widget<ListView>(
    find.byWidgetPredicate((widget) => widget is ListView && widget.reverse),
  );
  return list.controller!.position;
}

String _visibleTranscriptAnchor(WidgetTester tester) {
  for (var index = 0; index < 36; index++) {
    final label = 'Transcript marker $index';
    final finder = find.text(label);
    if (finder.evaluate().isEmpty) {
      continue;
    }
    final rect = tester.getRect(finder);
    if (rect.top > 140 && rect.bottom < 620) {
      return label;
    }
  }
  throw TestFailure('No fully visible transcript marker was available.');
}

List<SessionMessage> _transcriptMessages(int count) {
  return List<SessionMessage>.generate(count, (index) {
    final text = 'Transcript marker $index';
    return SessionMessage(
      id: 'message-$index',
      role: index.isEven ? 'user' : 'assistant',
      text: text,
      content: [TextBlock(text)],
      attachments: const [],
      createdAt: DateTime(2026, 1, 1, 12).add(Duration(minutes: index)),
      seq: index + 1,
      phase: index.isEven ? null : 'final_answer',
    );
  });
}

HostProfile _host(String id) => HostProfile(
  id: 'scroll-host-$id',
  label: 'Fake Host',
  baseUrl: 'http://127.0.0.1:4099',
  token: 'test-token',
);

SessionSummary _session(String id, {String status = 'idle'}) {
  final now = DateTime(2026, 1, 1, 12);
  return SessionSummary(
    id: id,
    title: 'Scroll test session',
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

class _ScrollFakeApi extends ApiClient {
  _ScrollFakeApi({required this.session, this.messages = const []});

  final SessionSummary session;
  List<SessionMessage> messages;
  final _channel = _ControllableWebSocketChannel();

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => _nodeInfo();

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async {
    return SessionLog(
      session: session,
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
  }

  @override
  Future<SessionStatus> fetchStatus(HostProfile host, String sessionId) async {
    return SessionStatus(
      sessionId: sessionId,
      status: session.status,
      isRunning: session.isActive,
      activeTurnId: session.isActive ? 'turn-1' : null,
      pendingAction: null,
    );
  }

  @override
  Future<SessionEventsDelta> fetchEvents(
    HostProfile host,
    String sessionId, {
    required int since,
    int? baseUpdatedAt,
  }) async {
    return SessionEventsDelta(
      sessionId: sessionId,
      since: since,
      nextSeq: since,
      messages: const [],
      activities: const [],
      latestPlanUpdate: null,
      pendingAction: null,
      session: null,
    );
  }

  @override
  Future<SkillCatalog> fetchSkills(
    HostProfile host, {
    required String cwd,
    bool forceReload = false,
    String? agentProvider,
  }) async {
    return SkillCatalog(cwd: cwd, skills: const [], errors: const []);
  }

  @override
  WebSocketChannel openLive(HostProfile host, String sessionId) => _channel;

  void emit(Map<String, Object?> event) {
    _channel.emit(jsonEncode(event));
  }

  void dispose() => _channel.dispose();
}

NodeInfo _nodeInfo() => NodeInfo.fromJson({
  'label': 'fake-profile',
  'hostname': 'localhost',
  'platform': 'android',
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
    'configuration': {'models': false, 'profiles': false, 'skills': false},
    'runtimeControls': {
      'model': false,
      'approvalPolicy': false,
      'sandboxMode': false,
      'networkAccess': false,
    },
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
    'configuration': {'models': false, 'profiles': false, 'skills': false},
    'runtimeControls': {
      'model': false,
      'approvalPolicy': false,
      'sandboxMode': false,
      'networkAccess': false,
    },
  },
  'hostCapabilities': {
    'workspace': {
      'filesystem': false,
      'gitStatus': false,
      'gitDiff': false,
      'browserPreview': false,
      'terminal': false,
    },
  },
  'supportedProviders': const [],
});

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
