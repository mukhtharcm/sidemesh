import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('desktop session focuses the composer after opening', (
    tester,
  ) async {
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('desktop-composer-focus'),
        session: _session('desktop-composer-focus'),
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(_composerTextField(tester).focusNode?.hasFocus, isTrue);
  });

  testWidgets('mobile session does not autofocus the composer', (tester) async {
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('mobile-composer-focus'),
        session: _session('mobile-composer-focus'),
        api: api,
      ),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    expect(_composerTextField(tester).focusNode?.hasFocus, isFalse);
  });

  testWidgets('desktop session does not steal focus from another text field', (
    tester,
  ) async {
    final api = _RichEventFakeApi();
    final externalFocus = FocusNode(debugLabel: 'external-search');
    addTearDown(api.dispose);
    addTearDown(externalFocus.dispose);

    await _pumpApp(
      tester,
      Column(
        children: [
          TextField(focusNode: externalFocus),
          Expanded(
            child: SessionScreen(
              host: _host('desktop-composer-external-focus'),
              session: _session('desktop-composer-external-focus'),
              api: api,
              desktopMode: true,
            ),
          ),
        ],
      ),
      size: const Size(1180, 900),
    );
    externalFocus.requestFocus();
    await _pumpFrames(tester);

    expect(externalFocus.hasFocus, isTrue);
    expect(_composerTextField(tester).focusNode?.hasFocus, isFalse);
  });

  testWidgets('desktop session does not autofocus while approval is pending', (
    tester,
  ) async {
    final session = _session('desktop-composer-pending-focus');
    final api = _RichEventFakeApi(pendingAction: _pendingAction(session.id));
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('desktop-composer-pending-focus'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Review command'), findsOneWidget);
    expect(_composerTextField(tester).focusNode?.hasFocus, isFalse);
  });

  testWidgets('desktop send restores composer focus', (tester) async {
    final api = _RichEventFakeApi();
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('desktop-composer-send-focus'),
        session: _session('desktop-composer-send-focus'),
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    final composer = _composerTextFieldFinder();
    await tester.enterText(composer, 'ship it');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpFrames(tester);

    expect(api.sendInputCalls, 1);
    expect(api.lastInputText, 'ship it');
    expect(_composerTextField(tester).focusNode?.hasFocus, isTrue);
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

      api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 3});
      await _pumpFrames(tester);

      expect(find.text('Plan update'), findsOneWidget);
      expect(find.text('Catch up missed plan state'), findsNothing);
      expect(find.text('Recovered from /events.'), findsOneWidget);

      await _expandPlanCard(tester);

      expect(find.text('Catch up missed plan state'), findsOneWidget);
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
      SessionScreen(host: host, session: session, api: api, desktopMode: true),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Cached transcript item.'), findsOneWidget);
    expect(
      find.text('Cached transcript · waiting for latest host snapshot'),
      findsNothing,
    );
  });

  testWidgets(
    'delta replay clears stale pending actions when the server has none',
    (tester) async {
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

      api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 3});
      await _pumpFrames(tester);

      expect(find.text('Approve file edit'), findsNothing);
    },
  );

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

    await _tapDesktopReload(tester);
    await _pumpFrames(tester);

    expect(find.text('Approve file edit'), findsNothing);
  });

  testWidgets(
    'snapshot reload preserves action opened while fetch is in flight',
    (tester) async {
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
      await _tapDesktopReload(tester);

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
    },
  );

  testWidgets(
    'cached activity details refresh from delta replay without manual reload',
    (tester) async {
      final host = _host('cached-activity-delta');
      final session = _session('cached-activity-delta');
      final api = _RichEventFakeApi(
        sessionSummary: session,
        activities: [
          _fileChangeActivity(id: 'file-1', seq: 1, path: '/repo/after.txt'),
        ],
        eventsDelta: SessionEventsDelta(
          sessionId: session.id,
          since: 1,
          nextSeq: 2,
          messages: const [],
          activities: [
            _fileChangeActivity(id: 'file-1', seq: 1, path: '/repo/after.txt'),
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
            _fileChangeActivity(id: 'file-1', seq: 1, path: '/repo/before.txt'),
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
    },
  );

  testWidgets('turn completion snapshot keeps locally seen command rows', (
    tester,
  ) async {
    final session = _session('turn-complete-command-preserve');
    final command = _commandActivity(
      id: 'live-command',
      seq: 1,
      command: 'npm test',
      cwd: '/repo',
      output: 'ok',
    );
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [
        _plainToolActivity(id: 'live-command', seq: 1, toolName: 'run_command'),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('turn-complete-command-preserve'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    api.emit({
      'type': 'activity_updated',
      'sessionId': session.id,
      'seq': 1,
      'activity': command.toJson(),
    });
    await _pumpFrames(tester);

    expect(find.text('npm test'), findsOneWidget);

    api.emit({'type': 'turn_completed', 'sessionId': session.id, 'seq': 2});
    await tester.pump(const Duration(milliseconds: 1300));
    await _pumpFrames(tester);

    expect(find.text('npm test'), findsOneWidget);
  });

  testWidgets('snapshot reload preserves locally seen command rows', (
    tester,
  ) async {
    final host = _host('cached-command-preserve');
    final session = _session('cached-command-preserve');
    final cachedCommand = _commandActivity(
      id: 'cached-command',
      seq: 10,
      command: 'npm test',
      cwd: '/repo',
      output: 'ok',
    );
    final freshFile = _fileChangeActivity(
      id: 'fresh-file',
      seq: 11,
      path: '/repo/fresh-from-snapshot.txt',
    );
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [freshFile],
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 10,
        nextSeq: 10,
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
        messages: const [],
        activities: [cachedCommand],
        pendingAction: null,
        history: const SessionLogHistorySummary(
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
      SessionScreen(host: host, session: session, api: api, desktopMode: true),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('npm test'), findsOneWidget);
    expect(find.text('fresh-from-snapshot.txt'), findsOneWidget);
  });

  testWidgets(
    'delta replay refreshes cached history metadata without manual reload',
    (tester) async {
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
    },
  );

  testWidgets('stale delta fallback reloads the full snapshot automatically', (
    tester,
  ) async {
    final host = _host('stale-delta-fallback');
    final session = _session('stale-delta-fallback');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      eventsError: StateError('stale_snapshot'),
      activities: [
        _fileChangeActivity(id: 'file-1', seq: 1, path: '/repo/fresh.txt'),
      ],
    );
    addTearDown(api.dispose);

    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: const [],
        activities: [
          _fileChangeActivity(id: 'file-1', seq: 1, path: '/repo/stale.txt'),
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
      SessionScreen(host: host, session: session, api: api, desktopMode: true),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('fresh.txt'), findsOneWidget);
    expect(find.text('stale.txt'), findsNothing);
  });

  testWidgets(
    'cached session verifies snapshot even when delta has no transcript rows',
    (tester) async {
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
    },
  );

  testWidgets(
    'hello gap keeps cached transcript stale until snapshot verifies',
    (tester) async {
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
    },
  );

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
    expect(find.text('Working notes'), findsOneWidget);

    final reasoningLabel = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((widget) => widget.text.toPlainText() == 'Working notes');
    expect(
      (reasoningLabel.text as TextSpan).style?.color,
      ThemeVariant.codexAmber.light.textSecondary,
    );

    await tester.tap(find.text('Working notes'));
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
      expect(find.text('Working notes'), findsOneWidget);
      expect(find.textContaining('Troubleshooting'), findsNothing);

      await tester.tap(find.text('Working notes'));
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
            command: "/bin/bash -lc 'npm run dev'",
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

      expect(find.text('Edited 1 file'), findsOneWidget);
      expect(find.text('FILE CHANGE'), findsNothing);
      expect(find.text('ran '), findsOneWidget);
      expect(find.text('npm run dev'), findsOneWidget);
      expect(find.textContaining('/bin/bash'), findsNothing);
      expect(find.text('done'), findsNothing);

      await tester.tap(find.text('npm run dev'));
      await _pumpFrames(tester);
      await tester.tap(find.text('apps/web/src/main.dart'));
      await _pumpFrames(tester);

      expect(find.text('Browser localhost:3000'), findsOneWidget);
      expect(find.text('Open terminal'), findsOneWidget);
      expect(find.text('Browse files'), findsOneWidget);
      expect(find.text('Open file'), findsOneWidget);
    },
  );

  testWidgets('session screen renders legacy command tool activities', (
    tester,
  ) async {
    final session = _session('legacy-command-tool');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [
        _legacyCommandToolActivity(
          id: 'legacy-tool-command',
          seq: 1,
          command: 'npm test',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('legacy-command-tool'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('ran '), findsOneWidget);
    expect(find.text('npm test'), findsOneWidget);
    expect(find.text('run_command'), findsNothing);
    expect(find.text('Tool execution'), findsNothing);
  });

  testWidgets('session screen renders shell-wrapped command rows', (
    tester,
  ) async {
    final session = _session('shell-command-row');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [
        for (var i = 0; i < 24; i += 1)
          _fileChangeActivity(
            id: 'file-change-$i',
            seq: i + 1,
            path: '/repo/apps/mobile/lib/file_$i.dart',
          ),
        _commandActivity(
          id: 'sed-command',
          seq: 80,
          command:
              "/bin/bash -lc \"sed -n '1,80p' apps/mobile/lib/src/screens/session_screen.dart\"",
          cwd: '/repo',
          output: 'class SessionScreen extends StatefulWidget',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('shell-command-row'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('viewed '), findsOneWidget);
    expect(find.text('"session_screen.dart lines 1-80"'), findsOneWidget);
    expect(
      find.text(
        "sed -n '1,80p' apps/mobile/lib/src/screens/session_screen.dart",
      ),
      findsNothing,
    );
    expect(find.textContaining('/bin/bash'), findsNothing);

    await tester.tap(find.text('"session_screen.dart lines 1-80"'));
    await _pumpFrames(tester);

    expect(find.text('Raw command'), findsOneWidget);
    expect(
      find.text(
        "sed -n '1,80p' apps/mobile/lib/src/screens/session_screen.dart",
      ),
      findsOneWidget,
    );
  });

  testWidgets('session screen renders search commands as readable activity', (
    tester,
  ) async {
    final session = _session('search-command-row');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [
        _commandActivity(
          id: 'rg-command',
          seq: 1,
          command:
              "/bin/bash -lc 'rg -n \"parseCommandFunctionCall\" src/codex-history.ts'",
          cwd: '/repo',
          output: 'src/codex-history.ts:12:function parseCommandFunctionCall',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('search-command-row'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('searched '), findsOneWidget);
    expect(
      find.text('for "parseCommandFunctionCall" in codex-history.ts'),
      findsOneWidget,
    );
    expect(
      find.text('rg -n "parseCommandFunctionCall" src/codex-history.ts'),
      findsNothing,
    );
    expect(find.textContaining('/bin/bash'), findsNothing);
  });

  testWidgets('session screen orders command rows by timestamp before seq', (
    tester,
  ) async {
    final session = _session('command-row-ordering');
    final baseTime = DateTime(2026, 1, 1, 12);
    final api = _RichEventFakeApi(
      sessionSummary: session,
      messages: [
        _assistantMessage(
          id: 'after-command',
          text: 'After command',
          content: const [TextBlock('After command')],
          seq: 12,
          createdAt: baseTime.add(const Duration(minutes: 2)),
        ),
      ],
      activities: [
        _commandActivity(
          id: 'live-command-high-seq',
          seq: 60000,
          command: "/bin/bash -lc 'npm test'",
          cwd: '/repo',
          output: 'ok',
          createdAt: baseTime.add(const Duration(minutes: 1)),
        ),
        _fileChangeActivity(
          id: 'later-file-change',
          seq: 13,
          path: '/repo/apps/mobile/lib/later.dart',
          createdAt: baseTime.add(const Duration(minutes: 3)),
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('command-row-ordering'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    final commandY = tester.getTopLeft(find.text('npm test')).dy;
    final messageY = tester.getTopLeft(find.text('After command')).dy;
    final fileY = tester.getTopLeft(find.text('Edited 1 file')).dy;

    expect(commandY, lessThan(messageY));
    expect(messageY, lessThan(fileY));
  });

  testWidgets('session screen avoids internal turn diff copy', (tester) async {
    final session = _session('turn-diff-copy');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [
        _turnDiffActivity(
          id: 'turn-diff-1',
          seq: 1,
          diff: '@@ -1 +1 @@\n-old\n+new',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('turn-diff-copy'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('live diff · 3 lines'), findsOneWidget);
    expect(find.text('View patch (3 lines)'), findsOneWidget);
    expect(find.textContaining('turn diff'), findsNothing);
  });

  testWidgets('session screen groups adjacent file changes by turn', (
    tester,
  ) async {
    final session = _session('grouped-file-changes');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      activities: [
        _fileChangeActivity(
          id: 'file-change-a',
          seq: 1,
          path: '/repo/apps/mobile/lib/a.dart',
          turnId: 'turn-file-group',
        ),
        _fileChangeActivity(
          id: 'file-change-b',
          seq: 2,
          path: '/repo/apps/mobile/lib/b.dart',
          turnId: 'turn-file-group',
        ),
        _fileChangeActivity(
          id: 'file-change-a-later',
          seq: 3,
          path: '/repo/apps/mobile/lib/a.dart',
          turnId: 'turn-file-group',
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(
        host: _host('grouped-file-changes'),
        session: session,
        api: api,
        desktopMode: true,
      ),
      size: const Size(1180, 900),
    );
    await _pumpFrames(tester);

    expect(find.text('Edited 2 files'), findsOneWidget);
    expect(find.text('FILE CHANGE'), findsNothing);

    await tester.tap(find.text('Edited 2 files'));
    await _pumpFrames(tester);

    expect(find.text('apps/mobile/lib/a.dart'), findsOneWidget);
    expect(find.text('apps/mobile/lib/b.dart'), findsOneWidget);
  });

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

      expect(find.text('Stop agent'), findsWidgets);

      await tester.tap(find.text('Stop agent').first);
      await _pumpFrames(tester);

      expect(find.text('Stop the agent?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Stop agent'));
      await _pumpFrames(tester);

      expect(api.stopSessionCalls, 1);
      expect(find.text('Stop agent'), findsNothing);
      expect(find.text('Agent stopped.'), findsOneWidget);
    },
  );

  testWidgets('loads one older cursor page without replacing newer rows', (
    tester,
  ) async {
    final session = _session('cursor-pagination');
    final current = _assistantMessage(
      id: 'message-current',
      text: 'Newest current text',
      content: const [TextBlock('Newest current text')],
      seq: 2,
    );
    final api = _RichEventFakeApi(
      pagedLogBuilder: (beforeCursor) {
        if (beforeCursor == null) {
          return SessionLog(
            session: session,
            messages: [current],
            activities: const [],
            pendingAction: null,
            history: const SessionLogHistorySummary(
              isTruncated: true,
              totalMessages: 2,
              returnedMessages: 1,
              totalActivities: 0,
              returnedActivities: 0,
            ),
            nextSeq: 9,
            page: const SessionLogPageInfo(
              beforeCursor: 'cursor-before-current',
              hasMoreBefore: true,
            ),
          );
        }
        return SessionLog(
          session: session,
          messages: [
            _assistantMessage(
              id: 'message-old',
              text: 'Older page text',
              content: const [TextBlock('Older page text')],
              seq: 1,
            ),
            _assistantMessage(
              id: 'message-current',
              text: 'Stale overlapping text',
              content: const [TextBlock('Stale overlapping text')],
              seq: 2,
            ),
          ],
          activities: const [],
          pendingAction: null,
          history: const SessionLogHistorySummary(
            isTruncated: false,
            totalMessages: 2,
            returnedMessages: 1,
            totalActivities: 0,
            returnedActivities: 0,
          ),
          nextSeq: 9,
          page: const SessionLogPageInfo(
            beforeCursor: 'cursor-before-old',
            hasMoreBefore: false,
          ),
        );
      },
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    expect(api.requestedEntryLimits, [200]);
    expect(api.requestedBeforeCursors, [null]);
    expect(find.text('Newest current text'), findsOneWidget);
    expect(find.text('Load older'), findsOneWidget);

    await tester.tap(find.text('Load older'));
    await _pumpFrames(tester);

    expect(api.requestedBeforeCursors, [null, 'cursor-before-current']);
    expect(find.text('Older page text'), findsOneWidget);
    expect(find.text('Newest current text'), findsOneWidget);
    expect(find.text('Stale overlapping text'), findsNothing);
    expect(find.text('Load older'), findsNothing);
  });

  testWidgets('legacy hosts drop entryLimit when expanding history', (
    tester,
  ) async {
    final session = _session('legacy-history-expansion');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      messages: [
        _assistantMessage(
          id: 'legacy-head',
          text: 'Legacy head',
          content: const [TextBlock('Legacy head')],
        ),
      ],
      sessionLogHistory: const SessionLogHistorySummary(
        isTruncated: true,
        totalMessages: 300,
        returnedMessages: 1,
        totalActivities: 0,
        returnedActivities: 0,
      ),
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('Load older'));
    await _pumpFrames(tester);

    expect(api.requestedEntryLimits, [200, null]);
  });

  testWidgets('routine head refresh preserves loaded cursor history', (
    tester,
  ) async {
    final session = _session('cursor-head-refresh');
    var headFetchCount = 0;
    final api = _RichEventFakeApi(
      pagedLogBuilder: (beforeCursor) {
        if (beforeCursor == null) {
          headFetchCount += 1;
          final newest = headFetchCount == 1
              ? _assistantMessage(
                  id: 'message-current',
                  text: 'Current head text',
                  content: const [TextBlock('Current head text')],
                  seq: 3,
                )
              : _assistantMessage(
                  id: 'message-new-head',
                  text: 'Refreshed head text',
                  content: const [TextBlock('Refreshed head text')],
                  seq: 4,
                );
          return SessionLog(
            session: session,
            messages: [newest],
            activities: const [],
            pendingAction: null,
            history: const SessionLogHistorySummary(
              isTruncated: true,
              totalMessages: 4,
              returnedMessages: 1,
              totalActivities: 0,
              returnedActivities: 0,
            ),
            nextSeq: 5,
            page: SessionLogPageInfo(
              beforeCursor: headFetchCount == 1
                  ? 'cursor-before-current'
                  : 'cursor-before-refreshed-head',
              hasMoreBefore: true,
            ),
          );
        }
        if (beforeCursor == 'cursor-before-current') {
          return SessionLog(
            session: session,
            messages: [
              _assistantMessage(
                id: 'message-old',
                text: 'Preserved older text',
                content: const [TextBlock('Preserved older text')],
                seq: 2,
              ),
            ],
            activities: const [],
            pendingAction: null,
            history: const SessionLogHistorySummary(
              isTruncated: true,
              totalMessages: 4,
              returnedMessages: 1,
              totalActivities: 0,
              returnedActivities: 0,
            ),
            nextSeq: 5,
            page: const SessionLogPageInfo(
              beforeCursor: 'cursor-before-old',
              hasMoreBefore: true,
            ),
          );
        }
        return SessionLog(
          session: session,
          messages: [
            _assistantMessage(
              id: 'message-oldest',
              text: 'Oldest page text',
              content: const [TextBlock('Oldest page text')],
              seq: 1,
            ),
          ],
          activities: const [],
          pendingAction: null,
          history: const SessionLogHistorySummary(
            isTruncated: false,
            totalMessages: 4,
            returnedMessages: 1,
            totalActivities: 0,
            returnedActivities: 0,
          ),
          nextSeq: 5,
          page: const SessionLogPageInfo(
            beforeCursor: 'cursor-before-oldest',
            hasMoreBefore: false,
          ),
        );
      },
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Load older'));
    await _pumpFrames(tester);
    expect(find.text('Preserved older text'), findsOneWidget);

    api.emit({
      'type': 'activity_updated',
      'sessionId': session.id,
      'seq': 50,
      'activity': _commandActivity(
        id: 'high-replay-cursor',
        seq: 50,
        command: 'echo live',
        cwd: '/repo',
        output: 'live',
      ).toJson(),
    });
    api.emit({'type': 'turn_completed', 'sessionId': session.id, 'seq': 51});
    await tester.pump(const Duration(milliseconds: 1300));
    await _pumpFrames(tester);

    expect(find.text('Refreshed head text'), findsOneWidget);
    expect(find.text('Preserved older text'), findsOneWidget);
    await tester.tap(find.text('Load older'));
    await _pumpFrames(tester);

    expect(api.requestedBeforeCursors, [
      null,
      'cursor-before-current',
      null,
      'cursor-before-old',
    ]);
    expect(find.text('Oldest page text'), findsOneWidget);
  });

  testWidgets('failed stale-cursor recovery keeps a retry path', (
    tester,
  ) async {
    final session = _session('stale-cursor-retry');
    var headCalls = 0;
    var failRecoveryHead = true;
    final api = _RichEventFakeApi(
      pagedLogBuilder: (beforeCursor) {
        if (beforeCursor != null) {
          throw const ApiException(410, 'stale transcript cursor');
        }
        headCalls += 1;
        if (headCalls > 1 && failRecoveryHead) {
          failRecoveryHead = false;
          throw StateError('replacement head unavailable');
        }
        final refreshed = headCalls > 1;
        return SessionLog(
          session: session,
          messages: [
            _assistantMessage(
              id: refreshed ? 'fresh-head' : 'initial-head',
              text: refreshed ? 'Fresh replacement head' : 'Initial head',
              content: [
                TextBlock(
                  refreshed ? 'Fresh replacement head' : 'Initial head',
                ),
              ],
              seq: refreshed ? 3 : 2,
            ),
          ],
          activities: const [],
          pendingAction: null,
          history: const SessionLogHistorySummary(
            isTruncated: true,
            totalMessages: 3,
            returnedMessages: 1,
            totalActivities: 0,
            returnedActivities: 0,
          ),
          nextSeq: 4,
          page: SessionLogPageInfo(
            beforeCursor: refreshed ? 'fresh-cursor' : 'stale-cursor',
            hasMoreBefore: true,
          ),
        );
      },
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Load older'));
    await _pumpFrames(tester);

    expect(find.text('Initial head'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await _pumpFrames(tester);

    expect(find.text('Fresh replacement head'), findsOneWidget);
    expect(api.requestedBeforeCursors, [null, 'stale-cursor', null, null]);
    expect(find.text('Load older'), findsOneWidget);
  });

  testWidgets('snapshot nextSeq converts to an inclusive delta cursor', (
    tester,
  ) async {
    final host = _host('exclusive-next-seq');
    final session = _session('exclusive-next-seq');
    final api = _RichEventFakeApi(
      sessionSummary: session,
      sessionLogNextSeq: 5,
      messages: [
        _assistantMessage(
          id: 'message-seq-4',
          text: 'Sequence four',
          content: const [TextBlock('Sequence four')],
          seq: 4,
        ),
      ],
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 4,
        nextSeq: 6,
        messages: const [],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: null,
      ),
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: host, session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 5});
    await _pumpFrames(tester);
    expect(api.fetchEventsCalls, 0);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 6});
    await _pumpFrames(tester);
    expect(api.requestedEventSince, [4]);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 7});
    await _pumpFrames(tester);
    expect(api.requestedEventSince, [4]);
  });

  testWidgets('authoritative head can reset a cached replay sequence epoch', (
    tester,
  ) async {
    final host = _host('sequence-epoch-reset');
    final session = _session('sequence-epoch-reset');
    final headReady = Completer<void>();
    final api = _RichEventFakeApi(
      sessionSummary: session,
      sessionLogNextSeq: 5,
      fetchLogBlocker: headReady.future,
      messages: [
        _assistantMessage(
          id: 'fresh-sequence-four',
          text: 'Fresh sequence four',
          content: const [TextBlock('Fresh sequence four')],
          seq: 4,
        ),
      ],
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 4,
        nextSeq: 5,
        messages: const [],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: null,
      ),
    );
    addTearDown(api.dispose);
    await SessionLocalStore.instance.saveSessionLog(
      host,
      SessionLog(
        session: session,
        messages: [
          _assistantMessage(
            id: 'cached-high-sequence',
            text: 'Cached old epoch',
            content: const [TextBlock('Cached old epoch')],
            seq: 99,
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
        nextSeq: 100,
      ),
    );

    await _pumpApp(
      tester,
      SessionScreen(host: host, session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);
    headReady.complete();
    await _pumpFrames(tester);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 6});
    await _pumpFrames(tester);

    expect(api.requestedEventSince, [4]);
  });

  testWidgets('head replay watermark catches up pre-head live activities', (
    tester,
  ) async {
    final session = _session('pre-head-live-activity');
    final recovered = _commandActivity(
      id: 'pre-head-command',
      seq: 0,
      command: 'echo recovered',
      cwd: '/repo',
      output: 'done',
    );
    final api = _RichEventFakeApi(
      sessionSummary: session,
      sessionLogNextSeq: 10,
      sessionLogReplayNextSeq: 11,
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 9,
        nextSeq: 10,
        messages: const [],
        activities: [recovered],
        latestPlanUpdate: null,
        pendingAction: null,
        session: null,
      ),
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    expect(api.requestedEventSince, [9]);
    expect(find.text('echo recovered'), findsOneWidget);
  });

  testWidgets('drains every replay page from the page-local cursor', (
    tester,
  ) async {
    final session = _session('paged-delta-drain');
    final firstPageReady = Completer<void>();
    final first = _commandActivity(
      id: 'shared-delta-activity',
      seq: 10,
      command: 'echo stale-page-one',
      cwd: '/repo',
      output: 'one',
    );
    final second = _commandActivity(
      id: 'delta-page-two',
      seq: 11,
      command: 'echo page-two',
      cwd: '/repo',
      output: 'two',
    );
    final api = _RichEventFakeApi(
      sessionSummary: session,
      sessionLogNextSeq: 10,
      sessionLogReplayNextSeq: 12,
      fetchEventsBlockers: [firstPageReady.future],
      eventsDeltas: [
        SessionEventsDelta(
          sessionId: session.id,
          since: 9,
          nextSeq: 10,
          hasMore: true,
          messages: const [],
          activities: [first],
          latestPlanUpdate: null,
          pendingAction: null,
          session: null,
        ),
        SessionEventsDelta(
          sessionId: session.id,
          since: 10,
          nextSeq: 11,
          messages: const [],
          activities: [second],
          latestPlanUpdate: null,
          pendingAction: null,
          session: null,
        ),
      ],
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);
    expect(api.requestedEventSince, [9]);

    api.emit({
      'type': 'activity_updated',
      'sessionId': session.id,
      'seq': 50,
      'activity': _commandActivity(
        id: 'shared-delta-activity',
        seq: 50,
        command: 'echo newest-live-state',
        cwd: '/repo',
        output: 'live',
      ).toJson(),
    });
    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 12});
    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 12});
    firstPageReady.complete();
    await _pumpFrames(tester);

    expect(api.requestedEventSince, [9, 10]);
    expect(find.text('echo stale-page-one'), findsNothing);
    expect(find.text('echo page-two'), findsOneWidget);
    expect(find.text('echo newest-live-state'), findsOneWidget);
  });

  testWidgets('large replay gaps fall back to a bounded head', (
    tester,
  ) async {
    final session = _session('long-paged-delta-drain');
    var headCount = 0;
    final deltas = List<SessionEventsDelta>.generate(33, (index) {
      final seq = 10 + index;
      return SessionEventsDelta(
        sessionId: session.id,
        since: seq - 1,
        nextSeq: seq,
        hasMore: index < 32,
        messages: const [],
        activities: [
          _commandActivity(
            id: 'long-drain-$index',
            seq: seq,
            command: 'echo long-drain-$index',
            cwd: '/repo',
            output: '$index',
          ),
        ],
        latestPlanUpdate: null,
        pendingAction: null,
        session: null,
      );
    });
    final api = _RichEventFakeApi(
      sessionSummary: session,
      eventsDeltas: deltas,
      pagedLogBuilder: (_) {
        headCount += 1;
        final initial = headCount == 1;
        return SessionLog(
          session: session,
          messages: initial
              ? const []
              : [
                  _assistantMessage(
                    id: 'latest-bounded-head',
                    text: 'Latest bounded head',
                    content: const [TextBlock('Latest bounded head')],
                    seq: 42,
                  ),
                ],
          activities: const [],
          pendingAction: null,
          history: const SessionLogHistorySummary(
            isTruncated: true,
            totalMessages: 10000,
            returnedMessages: 1,
            totalActivities: 0,
            returnedActivities: 0,
          ),
          nextSeq: initial ? 10 : 43,
          replayNextSeq: initial ? 43 : null,
          page: const SessionLogPageInfo(
            beforeCursor: 'bounded-head-cursor',
            hasMoreBefore: true,
          ),
        );
      },
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);

    expect(api.fetchEventsCalls, 10);
    expect(api.fetchLogCalls, 2);
    expect(api.requestedEventSince.first, 9);
    expect(api.requestedEventSince.last, 18);
    expect(find.text('Latest bounded head'), findsOneWidget);
    expect(find.text('echo long-drain-9'), findsNothing);
  });

  testWidgets('stale hello after buffered head events does not reload head', (
    tester,
  ) async {
    final session = _session('stale-post-head-watermark');
    final headReady = Completer<void>();
    final api = _RichEventFakeApi(
      sessionSummary: session,
      sessionLogNextSeq: 10,
      fetchLogBlocker: headReady.future,
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);
    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 20});
    api.emit({
      'type': 'activity_updated',
      'sessionId': session.id,
      'seq': 50,
      'activity': _commandActivity(
        id: 'buffered-high-sequence',
        seq: 50,
        command: 'echo buffered-high',
        cwd: '/repo',
        output: 'buffered',
      ).toJson(),
    });
    headReady.complete();
    await _pumpFrames(tester);

    expect(api.fetchLogCalls, 1);
    expect(find.text('echo buffered-high'), findsOneWidget);
  });

  testWidgets('lower hello during delta drain resets the sequence epoch', (
    tester,
  ) async {
    final session = _session('delta-sequence-epoch-reset');
    final deltaReady = Completer<void>();
    var headCount = 0;
    final api = _RichEventFakeApi(
      sessionSummary: session,
      fetchEventsBlockers: [deltaReady.future],
      eventsDelta: SessionEventsDelta(
        sessionId: session.id,
        since: 99,
        nextSeq: 99,
        messages: const [],
        activities: const [],
        latestPlanUpdate: null,
        pendingAction: null,
        session: null,
      ),
      pagedLogBuilder: (_) {
        headCount += 1;
        final initial = headCount == 1;
        final text = initial ? 'Old sequence epoch' : 'New sequence epoch';
        return SessionLog(
          session: session,
          messages: [
            _assistantMessage(
              id: initial ? 'old-epoch' : 'new-epoch',
              text: text,
              content: [TextBlock(text)],
              seq: initial ? 99 : 4,
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
          nextSeq: initial ? 100 : 5,
          replayNextSeq: initial ? 101 : null,
          page: const SessionLogPageInfo(
            beforeCursor: null,
            hasMoreBefore: false,
          ),
        );
      },
    );
    addTearDown(api.dispose);

    await _pumpApp(
      tester,
      SessionScreen(host: _host(session.id), session: session, api: api),
      size: const Size(390, 844),
    );
    await _pumpFrames(tester);
    expect(api.requestedEventSince, [99]);

    api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 5});
    deltaReady.complete();
    await _pumpFrames(tester);

    expect(api.fetchLogCalls, 2);
    expect(find.text('New sequence epoch'), findsOneWidget);
    expect(find.text('Old sequence epoch'), findsNothing);
  });

  testWidgets(
    'failed head replays live events then catches up a coalesced hello gap',
    (tester) async {
      final session = _session('failed-head-live-replay');
      final api = _RichEventFakeApi(sessionSummary: session);
      addTearDown(api.dispose);

      await _pumpApp(
        tester,
        SessionScreen(
          host: _host(session.id),
          session: session,
          api: api,
          desktopMode: true,
        ),
        size: const Size(1180, 900),
      );
      await _pumpFrames(tester);

      final headReady = Completer<void>();
      api.fetchLogBlocker = headReady.future;
      api.fetchLogError = StateError('head failed');
      api.emit({'type': 'turn_completed', 'sessionId': session.id, 'seq': 2});
      await tester.pump(const Duration(milliseconds: 1300));
      expect(api.fetchLogCalls, 2);

      api.emit({'type': 'hello', 'sessionId': session.id, 'nextSeq': 20});
      api.emit({
        'type': 'activity_updated',
        'sessionId': session.id,
        'seq': 3,
        'activity': _commandActivity(
          id: 'buffered-command',
          seq: 3,
          command: 'echo buffered',
          cwd: '/repo',
          output: 'buffered output',
        ).toJson(),
      });
      await _pumpFrames(tester);
      expect(api.fetchEventsCalls, 0);
      expect(find.text('echo buffered'), findsNothing);

      headReady.complete();
      await _pumpFrames(tester);

      expect(find.text('echo buffered'), findsOneWidget);
      expect(api.requestedEventSince, [3]);
    },
  );
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
}

TextField _composerTextField(WidgetTester tester) {
  final finder = _composerTextFieldFinder();
  expect(finder, findsOneWidget);
  return tester.widget<TextField>(finder);
}

Finder _composerTextFieldFinder() {
  return find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.decoration?.hintText?.startsWith('Reply here') == true,
  );
}

Future<void> _tapDesktopReload(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Session actions'));
  await _pumpFrames(tester);
  await tester.tap(find.text('Reload'));
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

PendingAction _pendingAction(String sessionId) {
  return PendingAction(
    id: 'pending-$sessionId',
    sessionId: sessionId,
    kind: 'command',
    title: 'Review command',
    detail: 'The agent needs approval before continuing.',
    requestedAt: DateTime(2026, 1, 1, 12),
    canApprove: true,
    canApproveForSession: true,
    canDecline: true,
  );
}

SessionMessage _assistantMessage({
  required String id,
  required String text,
  required List<ContentBlock> content,
  int seq = 1,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime(2026, 1, 1, 12);
  return SessionMessage(
    id: id,
    role: 'assistant',
    text: text,
    content: content,
    attachments: const [],
    createdAt: now,
    seq: seq,
    phase: 'final_answer',
  );
}

SessionActivity _commandActivity({
  required String id,
  required int seq,
  required String command,
  required String cwd,
  required String output,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime(2026, 1, 1, 12).add(Duration(minutes: seq));
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
  String? turnId,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime(2026, 1, 1, 12).add(Duration(minutes: seq));
  return SessionActivity(
    id: id,
    type: 'file_change',
    createdAt: now,
    seq: seq,
    status: 'completed',
    turnId: turnId ?? 'turn-$seq',
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

SessionActivity _legacyCommandToolActivity({
  required String id,
  required int seq,
  required String command,
}) {
  final now = DateTime(2026, 1, 1, 12).add(Duration(minutes: seq));
  return SessionActivity(
    id: id,
    type: 'tool',
    createdAt: now,
    seq: seq,
    status: 'completed',
    turnId: 'turn-$seq',
    command: null,
    cwd: null,
    output: null,
    exitCode: null,
    durationMs: null,
    source: null,
    processId: null,
    commandActions: const [],
    terminalStatus: null,
    terminalInput: null,
    toolName: 'run_command',
    toolTitle: null,
    toolArgs: null,
    toolResult: null,
    toolError: null,
    toolSemantic: SessionToolSemantic(
      category: 'command',
      action: 'invoke',
      targets: [SessionToolSemanticTarget(type: 'command', command: command)],
    ),
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

SessionActivity _plainToolActivity({
  required String id,
  required int seq,
  required String toolName,
}) {
  final now = DateTime(2026, 1, 1, 12).add(Duration(minutes: seq));
  return SessionActivity(
    id: id,
    type: 'tool',
    createdAt: now,
    seq: seq,
    status: 'completed',
    turnId: 'turn-$seq',
    command: null,
    cwd: null,
    output: null,
    exitCode: null,
    durationMs: null,
    source: null,
    processId: null,
    commandActions: const [],
    terminalStatus: null,
    terminalInput: null,
    toolName: toolName,
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

SessionActivity _turnDiffActivity({
  required String id,
  required int seq,
  required String diff,
}) {
  final now = DateTime(2026, 1, 1, 12).add(Duration(minutes: seq));
  return SessionActivity(
    id: id,
    type: 'turn_diff',
    createdAt: now,
    seq: seq,
    status: 'in_progress',
    turnId: 'turn-$seq',
    command: null,
    cwd: null,
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
    changes: const [],
    diff: diff,
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
  'hostCapabilities': {'workspace': hostWorkspaceCapabilities},
  'supportedProviders': const [],
});

class _RichEventFakeApi extends ApiClient {
  _RichEventFakeApi({
    this.messages = const [],
    this.activities = const [],
    this.sessionLogHistory,
    this.latestPlanUpdate,
    this.eventsDelta,
    this.eventsDeltas,
    this.eventsError,
    this.fetchEventsBlockers = const [],
    this.fetchLogBlocker,
    this.nodeInfo,
    this.sessionSummary,
    this.sessionStatus,
    this.pendingAction,
    this.pagedLogBuilder,
    this.sessionLogNextSeq,
    this.sessionLogReplayNextSeq,
  });

  final _ControllableWebSocketChannel _channel =
      _ControllableWebSocketChannel();
  List<SessionMessage> messages;
  final List<SessionActivity> activities;
  final SessionLogHistorySummary? sessionLogHistory;
  final LiveEvent? latestPlanUpdate;
  final SessionEventsDelta? eventsDelta;
  final List<SessionEventsDelta>? eventsDeltas;
  final Object? eventsError;
  final List<Future<void>> fetchEventsBlockers;
  Future<void>? fetchLogBlocker;
  final NodeInfo? nodeInfo;
  final SessionSummary? sessionSummary;
  final SessionStatus? sessionStatus;
  final PendingAction? pendingAction;
  SessionLog Function(String? beforeCursor)? pagedLogBuilder;
  final int? sessionLogNextSeq;
  final int? sessionLogReplayNextSeq;
  Object? fetchLogError;
  final List<String?> requestedBeforeCursors = <String?>[];
  final List<int?> requestedEntryLimits = <int?>[];
  final List<int> requestedEventSince = <int>[];
  int fetchLogCalls = 0;
  int fetchEventsCalls = 0;
  int stopSessionCalls = 0;
  int sendInputCalls = 0;
  String? lastInputText;

  @override
  Future<NodeInfo> fetchNode(HostProfile host) async => nodeInfo ?? _nodeInfo();

  @override
  Future<SessionLog> fetchLog(
    HostProfile host,
    String sessionId, {
    int? messageLimit,
    int? activityLimit,
    int? entryLimit,
    String? beforeCursor,
  }) async {
    fetchLogCalls += 1;
    requestedBeforeCursors.add(beforeCursor);
    requestedEntryLimits.add(entryLimit);
    final blocker = fetchLogBlocker;
    if (blocker != null) {
      await blocker;
    }
    final logError = fetchLogError;
    if (logError != null) {
      throw logError;
    }
    final builder = pagedLogBuilder;
    if (builder != null) {
      return builder(beforeCursor);
    }
    return SessionLog(
      session: sessionSummary ?? _session(sessionId),
      messages: messages,
      activities: activities,
      pendingAction: pendingAction,
      history:
          sessionLogHistory ??
          SessionLogHistorySummary(
            isTruncated: false,
            totalMessages: messages.length,
            returnedMessages: messages.length,
            totalActivities: activities.length,
            returnedActivities: activities.length,
          ),
      nextSeq: sessionLogNextSeq,
      replayNextSeq: sessionLogReplayNextSeq,
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
    final callIndex = fetchEventsCalls;
    fetchEventsCalls += 1;
    requestedEventSince.add(since);
    if (callIndex < fetchEventsBlockers.length) {
      await fetchEventsBlockers[callIndex];
    }
    if (eventsError != null) {
      throw eventsError!;
    }
    final queuedDeltas = eventsDeltas;
    if (queuedDeltas != null && callIndex < queuedDeltas.length) {
      return queuedDeltas[callIndex];
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
  Future<void> sendInput(
    HostProfile host, {
    required String sessionId,
    String text = '',
    List<SessionInputItem>? input,
    String? clientMessageId,
    String? model,
    String? mode,
    String? reasoningEffort,
    bool? fastMode,
    String? approvalPolicy,
    String? sandboxMode,
    bool? networkAccess,
  }) async {
    sendInputCalls += 1;
    lastInputText = text;
  }

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
