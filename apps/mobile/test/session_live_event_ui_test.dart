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
    'session screen renders warning, plan, queue, and retry live events',
    (tester) async {
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
      expect(find.text('Plan update'), findsOneWidget);
      expect(find.text('Ship the change'), findsNothing);
      expect(find.text('Queue · 1 steering · 2 follow-up'), findsOneWidget);
      expect(find.text('Retry 2 / 3 in 1.5s'), findsOneWidget);
      expect(find.textContaining('Keep it provider-neutral'), findsOneWidget);
      expect(find.textContaining('Overloaded'), findsOneWidget);

      await _expandPlanCard(tester);

      expect(find.text('Ship the change'), findsOneWidget);
    },
  );

  testWidgets('appended session messages are persisted in cached logs', (
    tester,
  ) async {
    final host = _host('appended-message-cache');
    final session = _session('appended-message-cache');
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({
      'type': 'session_message_appended',
      'sessionId': session.id,
      'seq': 2,
      'messageItem': {
        'id': 'audit-1',
        'role': 'system',
        'text': 'User answered.',
        'content': [
          {'type': 'text', 'text': 'User answered.'},
        ],
        'attachments': [],
        'createdAt': DateTime(2026, 1, 1, 12, 1, 0, 900).millisecondsSinceEpoch,
        'seq': 2,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('User answered.'), findsOneWidget);
    final cached = await SessionLocalStore.instance.loadSessionLog(
      host,
      session.id,
    );
    expect(cached, isNotNull);
    expect(
      cached!.log.messages.map((message) => message.text),
      contains('User answered.'),
    );
    expect(cached.log.session.updatedAt, DateTime(2026, 1, 1, 12, 1));
    expect(cached.log.nextSeq, 3);
  });

  testWidgets('appended user messages update live running state', (
    tester,
  ) async {
    final session = _session('appended-user-running');
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('appended-user-running'),
        session: session,
        api: api,
        desktopMode: false,
      ),
      size: const Size(430, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Interrupt agent'), findsNothing);

    api.emit({
      'type': 'session_message_appended',
      'sessionId': session.id,
      'seq': 2,
      'messageItem': {
        'id': 'user-1',
        'role': 'user',
        'text': 'Deploy staging.',
        'content': [
          {'type': 'text', 'text': 'Deploy staging.'},
        ],
        'attachments': [],
        'createdAt': DateTime(2026, 1, 1, 12, 1).millisecondsSinceEpoch,
        'seq': 2,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Deploy staging.'), findsOneWidget);
    expect(find.text('Interrupt agent'), findsWidgets);
  });

  testWidgets('snapshot replay cursor prevents reconnect delta loops', (
    tester,
  ) async {
    final host = _host('snapshot-replay-cursor');
    final session = _session('snapshot-replay-cursor');
    final api = _RichEventFakeApi(
      logNextSeq: 9,
      messages: [
        _assistantMessage(
          id: 'snapshot-msg',
          text: 'Snapshot transcript item.',
          content: const [TextBlock('Snapshot transcript item.')],
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 9});
    await _pumpFrames(tester);

    expect(find.text('Snapshot transcript item.'), findsOneWidget);
    expect(api.fetchEventsCalls, 0);
    final cached = await SessionLocalStore.instance.loadSessionLog(
      host,
      session.id,
    );
    expect(cached?.log.nextSeq, 9);
  });

  testWidgets('fresh snapshot can lower replay cursor after daemon restart', (
    tester,
  ) async {
    final session = _session('snapshot-replay-reset');
    final api = _RichEventFakeApi(
      logNextSeq: 20,
      messages: [
        _assistantMessage(
          id: 'before-restart',
          text: 'Before restart.',
          content: const [TextBlock('Before restart.')],
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('snapshot-replay-reset'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 20});
    await _pumpFrames(tester);
    expect(api.fetchEventsCalls, 0);

    api.logNextSeq = 3;
    api.messages = [
      _assistantMessage(
        id: 'after-restart',
        text: 'After restart.',
        content: const [TextBlock('After restart.')],
      ),
    ];
    api.eventsError = Exception('stale cursor');
    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 25});
    await _pumpFrames(tester);
    await _pumpFrames(tester);

    expect(find.text('After restart.'), findsOneWidget);
    expect(api.fetchEventsCalls, 1);

    api.eventsError = null;
    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 4});
    await _pumpFrames(tester);

    expect(api.fetchEventsCalls, 2);
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

    api.emit(
      _planUpdatedEvent(
        session.id,
        turnId: 'turn-1',
        explanation: 'Initial plan.',
        plan: const [
          {'step': 'Inspect the bug', 'status': 'completed'},
        ],
      ),
    );
    api.emit(
      _planUpdatedEvent(
        session.id,
        turnId: 'turn-2',
        explanation: 'Revised plan.',
        plan: const [
          {'step': 'Ship the fix', 'status': 'in_progress'},
        ],
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsOneWidget);
    expect(find.text('Inspect the bug'), findsNothing);
    expect(find.text('Ship the fix'), findsNothing);
    expect(find.text('Revised plan.'), findsOneWidget);

    await _expandPlanCard(tester);

    expect(find.text('Inspect the bug'), findsNothing);
    expect(find.text('Ship the fix'), findsOneWidget);
  });

  testWidgets('session screen clears the plan card on an empty plan update', (
    tester,
  ) async {
    final session = _session('plan-clear-live');
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('plan-clear-live'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit(
      _planUpdatedEvent(
        session.id,
        turnId: 'turn-1',
        explanation: 'Temporary plan.',
        plan: const [
          {'step': 'Remove after provider delete', 'status': 'in_progress'},
        ],
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsOneWidget);
    expect(find.text('Remove after provider delete'), findsNothing);

    await _expandPlanCard(tester);

    expect(find.text('Remove after provider delete'), findsOneWidget);

    api.emit(
      _planUpdatedEvent(
        session.id,
        turnId: 'turn-1',
        explanation: '',
        plan: const [],
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsNothing);
    expect(find.text('Remove after provider delete'), findsNothing);
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
    expect(find.text('Avoid duplicates on reopen'), findsNothing);

    await _expandPlanCard(tester);

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
    expect(find.text('Avoid duplicates on reopen'), findsNothing);

    await _expandPlanCard(tester);

    expect(find.text('Avoid duplicates on reopen'), findsOneWidget);
  });

  testWidgets(
    'session screen restores a missed plan update from delta replay',
    (tester) async {
      final host = _host('plan-delta-replay');
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
          host: host,
          session: session,
          api: api,
          desktopMode: true,
        ),
        size: const Size(1180, 900),
      );
      await _pumpFrames(tester);

      expect(find.text('Catch up missed plan state'), findsNothing);

      api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 3});
      await _pumpFrames(tester);

      expect(find.text('Plan update'), findsOneWidget);
      expect(find.text('Catch up missed plan state'), findsNothing);
      expect(find.text('Recovered from /events.'), findsOneWidget);

      await _expandPlanCard(tester);

      expect(find.text('Catch up missed plan state'), findsOneWidget);
      final cached = await SessionLocalStore.instance.loadSessionLog(
        host,
        session.id,
      );
      expect(cached?.log.nextSeq, 3);
    },
  );

  testWidgets('session screen clears an existing plan from delta replay', (
    tester,
  ) async {
    final session = _session('plan-clear-delta-replay');
    final api = _RichEventFakeApi(
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 3,
        nextSeq: 5,
        messages: const [],
        activities: const [],
        latestPlanUpdate: LiveEvent.fromJson(
          _planUpdatedEvent(
            session.id,
            turnId: 'turn-1',
            explanation: '',
            plan: const [],
            seq: 4,
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
        host: _host('plan-clear-delta-replay'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit(
      _planUpdatedEvent(
        session.id,
        turnId: 'turn-1',
        explanation: 'Live stale plan.',
        plan: const [
          {'step': 'Clear stale visible plan', 'status': 'in_progress'},
        ],
        seq: 3,
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsOneWidget);
    expect(find.text('Clear stale visible plan'), findsNothing);

    await _expandPlanCard(tester);

    expect(find.text('Clear stale visible plan'), findsOneWidget);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 5});
    await _pumpFrames(tester);

    expect(find.text('Plan update'), findsNothing);
    expect(find.text('Clear stale visible plan'), findsNothing);
  });

  testWidgets('cached-transcript strip clears after delta sync succeeds', (
    tester,
  ) async {
    final host = _host('cached-strip-clear');
    final session = _session('cached-strip-clear', status: 'running');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      messages: [
        _assistantMessage(
          id: 'cached-msg',
          text: 'Cached transcript item.',
          content: const [TextBlock('Cached transcript item.')],
        ),
      ],
      sessionStatus: SessionStatus(
        sessionId: session.id,
        status: 'running',
        isRunning: true,
        activeTurnId: 'turn-1',
        pendingAction: null,
      ),
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 1,
        nextSeq: 1,
        messages: const [],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: session,
      ),
    );
    addTearDown(api.dispose);

    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: [
          _assistantMessage(
            id: 'cached-msg',
            text: 'Cached transcript item.',
            content: const [TextBlock('Cached transcript item.')],
          ),
        ],
        activities: const [],
        pendingAction: null,
        history: SessionLogHistorySummary(
          isTruncated: false,
          totalMessages: 1,
          returnedMessages: 1,
          totalActivities: 0,
          returnedActivities: 0,
        ),
      ),
    );

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Cached transcript item.'), findsOneWidget);
    expect(
      find.text('Cached transcript · waiting for latest host snapshot'),
      findsNothing,
    );
  });

  testWidgets('delta replay clears stale pending actions when the server has none', (
    tester,
  ) async {
    final session = _session('pending-action-delta-clear');
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
        latestPlanUpdate: null,
        pendingAction: null,
        session: _session(session.id, status: 'running'),
      ),
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('pending-action-delta-clear'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({
      'type': 'action_opened',
      'sessionId': session.id,
      'action': {
        'id': 'action-1',
        'sessionId': session.id,
        'kind': 'permissions',
        'title': 'Approve file edit',
        'detail': 'Need approval before continuing.',
        'requestedAt': DateTime(2026, 1, 1, 12, 1).millisecondsSinceEpoch,
        'canApprove': true,
        'canApproveForSession': true,
        'canDecline': true,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Approve file edit'), findsOneWidget);

    api.emit({
      'type': 'hello',
      'sessionId': session.id,
      'nextSeq': 3,
    });
    await _pumpFrames(tester);

    expect(find.text('Approve file edit'), findsNothing);
  });

  testWidgets('manual snapshot reload clears stale pending actions', (
    tester,
  ) async {
    final session = _session('pending-action-snapshot-clear');
    final api = _RichEventFakeApi(
      messages: [
        _assistantMessage(
          id: 'seed-message',
          text: 'Existing transcript item.',
          content: const [TextBlock('Existing transcript item.')],
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('pending-action-snapshot-clear'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({
      'type': 'action_opened',
      'sessionId': session.id,
      'action': {
        'id': 'action-1',
        'sessionId': session.id,
        'kind': 'permissions',
        'title': 'Approve file edit',
        'detail': 'Need approval before continuing.',
        'requestedAt': DateTime(2026, 1, 1, 12, 1).millisecondsSinceEpoch,
        'canApprove': true,
        'canApproveForSession': true,
        'canDecline': true,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Approve file edit'), findsOneWidget);

    await tester.tap(find.byTooltip('Reload session'));
    await _pumpFrames(tester);

    expect(find.text('Approve file edit'), findsNothing);
  });

  testWidgets('snapshot reload preserves action opened while fetch is in flight', (
    tester,
  ) async {
    final session = _session('pending-action-snapshot-buffered-open');
    final snapshotReady = Completer<void>();
    final api = _RichEventFakeApi(
      messages: [
        _assistantMessage(
          id: 'seed-message',
          text: 'Existing transcript item.',
          content: const [TextBlock('Existing transcript item.')],
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('pending-action-snapshot-buffered-open'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.fetchLogBlocker = snapshotReady.future;
    await tester.tap(find.byTooltip('Reload session'));
    await tester.pump();

    api.emit({
      'type': 'action_opened',
      'sessionId': session.id,
      'action': {
        'id': 'action-1',
        'sessionId': session.id,
        'kind': 'permissions',
        'title': 'Approve file edit',
        'detail': 'Need approval before continuing.',
        'requestedAt': DateTime(2026, 1, 1, 12, 1).millisecondsSinceEpoch,
        'canApprove': true,
        'canApproveForSession': true,
        'canDecline': true,
      },
    });
    await _pumpFrames(tester);

    expect(find.text('Approve file edit'), findsNothing);

    snapshotReady.complete();
    await _pumpFrames(tester);

    expect(find.text('Approve file edit'), findsOneWidget);
  });

  testWidgets('cached activity details refresh from delta replay without manual reload', (
    tester,
  ) async {
    final host = _host('cached-activity-delta');
    final session = _session('cached-activity-delta');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [
        _fileChangeActivity(
          id: 'file-1',
          seq: 1,
          path: '/repo/after.txt',
        ),
      ],
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 1,
        nextSeq: 2,
        messages: const [],
        activities: [
          _fileChangeActivity(
            id: 'file-1',
            seq: 1,
            path: '/repo/after.txt',
          ),
        ],
        latestPlanUpdate: null,
        pendingAction: null,
        session: session,
      ),
    );
    addTearDown(api.dispose);

    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: const [],
        activities: [
          _fileChangeActivity(
            id: 'file-1',
            seq: 1,
            path: '/repo/before.txt',
          ),
        ],
        pendingAction: null,
        history: SessionLogHistorySummary(
          isTruncated: false,
          totalMessages: 0,
          returnedMessages: 0,
          totalActivities: 1,
          returnedActivities: 1,
        ),
      ),
    );

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('after.txt'), findsOneWidget);
    expect(find.text('before.txt'), findsNothing);
  });

  testWidgets('delta replay refreshes cached history metadata without manual reload', (
    tester,
  ) async {
    final host = _host('cached-history-delta');
    final session = _session('cached-history-delta');
    final cachedMessage = _assistantMessage(
      id: 'msg-1',
      text: 'Cached message.',
      content: const [TextBlock('Cached message.')],
    );
    final deltaMessage = SessionMessage(
      id: 'msg-2',
      role: 'assistant',
      text: 'New delta message.',
      content: const [TextBlock('New delta message.')],
      attachments: const [],
      createdAt: DateTime(2026, 1, 1, 12, 2),
      seq: 2,
      phase: 'final_answer',
    );
    final api = _RichEventFakeApi(
      sessionSummary: session,
      messages: [cachedMessage, deltaMessage],
      sessionLogHistory: const SessionLogHistorySummary(
        isTruncated: true,
        totalMessages: 6,
        returnedMessages: 2,
        totalActivities: 0,
        returnedActivities: 0,
      ),
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 1,
        nextSeq: 2,
        messages: [deltaMessage],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: session,
      ),
    );
    addTearDown(api.dispose);

    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: [cachedMessage],
        activities: const [],
        pendingAction: null,
        history: const SessionLogHistorySummary(
          isTruncated: true,
          totalMessages: 5,
          returnedMessages: 1,
          totalActivities: 0,
          returnedActivities: 0,
        ),
      ),
    );

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    final cached = await SessionLocalStore.instance.loadSessionLog(
      host,
      session.id,
    );
    expect(cached, isNotNull);
    final history = cached!.log.history;
    expect(history, isNotNull);
    expect(history!.totalMessages, 6);
    expect(history.returnedMessages, 2);
    expect(history.isTruncated, isTrue);
  });

  testWidgets('stale delta fallback reloads the full snapshot automatically', (
    tester,
  ) async {
    final host = _host('stale-delta-fallback');
    final session = _session('stale-delta-fallback');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      eventsError: StateError('stale_snapshot'),
      activities: [
        _fileChangeActivity(
          id: 'file-1',
          seq: 1,
          path: '/repo/fresh.txt',
        ),
      ],
    );
    addTearDown(api.dispose);

    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: const [],
        activities: [
          _fileChangeActivity(
            id: 'file-1',
            seq: 1,
            path: '/repo/stale.txt',
          ),
        ],
        pendingAction: null,
        history: SessionLogHistorySummary(
          isTruncated: false,
          totalMessages: 0,
          returnedMessages: 0,
          totalActivities: 1,
          returnedActivities: 1,
        ),
      ),
    );

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('fresh.txt'), findsOneWidget);
    expect(find.text('stale.txt'), findsNothing);
  });

  testWidgets('cached session verifies snapshot even when delta has no transcript rows', (
    tester,
  ) async {
    final host = _host('cached-delta-empty-snapshot-verify');
    final session = _session('cached-delta-empty-snapshot-verify');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 1,
        nextSeq: 1,
        messages: const [],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: session,
      ),
      activities: [
        _fileChangeActivity(
          id: 'file-1',
          seq: 1,
          path: '/repo/fresh-from-snapshot.txt',
        ),
      ],
    );
    addTearDown(api.dispose);

    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: const [],
        activities: [
          _fileChangeActivity(
            id: 'file-1',
            seq: 1,
            path: '/repo/stale-from-cache.txt',
          ),
        ],
        pendingAction: null,
        history: SessionLogHistorySummary(
          isTruncated: false,
          totalMessages: 0,
          returnedMessages: 0,
          totalActivities: 1,
          returnedActivities: 1,
        ),
      ),
    );

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('fresh-from-snapshot.txt'), findsOneWidget);
    expect(find.text('stale-from-cache.txt'), findsNothing);
  });

  testWidgets('hello gap keeps cached transcript stale until snapshot verifies', (
    tester,
  ) async {
    final host = _host('cached-hello-gap-snapshot-verify');
    final session = _session('cached-hello-gap-snapshot-verify');
    final snapshotReady = Completer<void>();
    final api = _RichEventFakeApi(
      sessionSummary: session,
      fetchLogBlocker: snapshotReady.future,
      messages: [
        _assistantMessage(
          id: 'msg-1',
          text: 'Fresh snapshot item.',
          content: const [TextBlock('Fresh snapshot item.')],
        ),
      ],
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 1,
        nextSeq: 1,
        messages: const [],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: session,
      ),
    );
    addTearDown(api.dispose);

    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: [
          _assistantMessage(
            id: 'msg-1',
            text: 'Cached transcript item.',
            content: const [TextBlock('Cached transcript item.')],
          ),
        ],
        activities: const [],
        pendingAction: null,
        history: const SessionLogHistorySummary(
          isTruncated: false,
          totalMessages: 1,
          returnedMessages: 1,
          totalActivities: 0,
          returnedActivities: 0,
        ),
      ),
    );

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 3});
    await _pumpFrames(tester);

    expect(find.text('Cached transcript item.'), findsOneWidget);
    expect(find.text('Fresh snapshot item.'), findsNothing);
    expect(
      find.text('Cached transcript · syncing latest changes'),
      findsOneWidget,
    );

    snapshotReady.complete();
    await _pumpFrames(tester);

    expect(find.text('Fresh snapshot item.'), findsOneWidget);
    expect(find.text('Cached transcript item.'), findsNothing);
    expect(
      find.text('Cached transcript · waiting for latest host snapshot'),
      findsNothing,
    );
  });

  testWidgets('completed assistant message keeps collapsed reasoning visible', (
    tester,
  ) async {
    final host = _host('reasoning-collapse');
    final session = _session('reasoning-collapse');
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: host,
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
    final cached = await SessionLocalStore.instance.loadSessionLog(
      host,
      session.id,
    );
    final cachedMessage = cached!.log.messages.singleWhere(
      (message) => message.id == 'msg-1',
    );
    expect(cachedMessage.text, 'Final answer.');
    expect(cachedMessage.content.any((block) => block is ThinkingBlock), isTrue);

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

  testWidgets(
    'persisted assistant reasoning starts collapsed and expands as text',
    (tester) async {
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
    },
  );

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

  testWidgets(
    'mobile running session shows stop pill and stops after confirmation',
    (tester) async {
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

      expect(find.text('Interrupt agent'), findsWidgets);

      await tester.tap(find.text('Interrupt agent').first);
      await _pumpFrames(tester);

      expect(find.text('Interrupt agent?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Interrupt'));
      await _pumpFrames(tester);

      expect(api.stopSessionCalls, 1);
      expect(find.text('Interrupt agent'), findsNothing);
      expect(find.text('Agent interrupted.'), findsOneWidget);
    },
  );
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _expandPlanCard(WidgetTester tester) async {
  await tester.tap(find.text('Plan update'));
  await _pumpFrames(tester);
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
    'configuration': {'models': false, 'profiles': false, 'skills': false},
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
    'configuration': {'models': false, 'profiles': false, 'skills': false},
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
    this.sessionLogHistory,
    this.latestPlanUpdate,
    this.logNextSeq,
    this.eventsDelta,
    this.eventsError,
    this.fetchLogBlocker,
    this.nodeInfo,
    this.sessionSummary,
    this.sessionStatus,
  });

  final _ControllableWebSocketChannel _channel =
      _ControllableWebSocketChannel();
  List<SessionMessage> messages;
  final List<SessionActivity> activities;
  final SessionLogHistorySummary? sessionLogHistory;
  final LiveEvent? latestPlanUpdate;
  int? logNextSeq;
  final SessionEventsDelta? eventsDelta;
  Object? eventsError;
  Future<void>? fetchLogBlocker;
  final NodeInfo? nodeInfo;
  final SessionSummary? sessionSummary;
  final SessionStatus? sessionStatus;
  int stopSessionCalls = 0;
  int fetchEventsCalls = 0;

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => nodeInfo ?? _nodeInfo();

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
  }) async {
    final blocker = fetchLogBlocker;
    if (blocker != null) {
      await blocker;
    }
    return SessionLog(
      session: sessionSummary ?? _session(sessionId),
      messages: messages,
      activities: activities,
      pendingAction: null,
      history:
          sessionLogHistory ??
          SessionLogHistorySummary(
            isTruncated: false,
            totalMessages: messages.length,
            returnedMessages: messages.length,
            totalActivities: activities.length,
            returnedActivities: activities.length,
          ),
      nextSeq: logNextSeq,
      latestPlanUpdate: latestPlanUpdate,
    );
  }

  @override
  Future<SessionEventsDelta> fetchEvents(
    HostProfile host,
    String sessionId, {
    required int since,
    int? baseUpdatedAt,
  }) async {
    fetchEventsCalls += 1;
    if (eventsError != null) {
      throw eventsError!;
    }
    return eventsDelta ??
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
  }

  @override
  Future<SessionStatus> fetchStatus(HostProfile host, String sessionId) async {
    final summary = sessionSummary ?? _session(sessionId);
    return sessionStatus ??
        SessionStatus(
          sessionId: sessionId,
          status: summary.status,
          isRunning: summary.isActive,
          activeTurnId: summary.isActive ? 'turn-1' : null,
          pendingAction: null,
        );
  }

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
