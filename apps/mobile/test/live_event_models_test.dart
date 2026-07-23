import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  test('LiveEvent parses rich runtime envelope payloads', () {
    final warning = LiveEvent.fromJson({
      'type': 'provider_warning',
      'sessionId': 'session-1',
      'level': 'warning',
      'code': 'warn-1',
      'message': 'Heads up',
      'source': 'fake/runtime',
    });
    expect(warning.level, 'warning');
    expect(warning.code, 'warn-1');
    expect(warning.message, 'Heads up');
    expect(warning.source, 'fake/runtime');

    final threadStatus = LiveEvent.fromJson({
      'type': 'thread_status_changed',
      'sessionId': 'session-1',
      'status': 'waiting_for_approval',
      'pendingActionKind': 'command',
      'message': 'Waiting for approval',
    });
    expect(threadStatus.status, 'waiting_for_approval');
    expect(threadStatus.pendingActionKind, 'command');

    final plan = LiveEvent.fromJson({
      'type': 'plan_updated',
      'sessionId': 'session-1',
      'turnId': 'turn-1',
      'explanation': 'Follow the rollout plan.',
      'plan': [
        {'step': 'Review docs', 'status': 'completed'},
        {'step': 'Ship the change', 'status': 'in_progress'},
      ],
    });
    expect(plan.turnId, 'turn-1');
    expect(plan.explanation, 'Follow the rollout plan.');
    expect(plan.plan, hasLength(2));
    expect(plan.plan!.first.step, 'Review docs');
    expect(plan.plan!.last.status, 'in_progress');

    final reasoning = LiveEvent.fromJson({
      'type': 'reasoning_delta',
      'sessionId': 'session-1',
      'turnId': 'turn-1',
      'itemId': 'item-1',
      'reasoningId': 'reason-1',
      'delta': 'Thinking...',
      'summary': true,
    });
    expect(reasoning.reasoningId, 'reason-1');
    expect(reasoning.delta, 'Thinking...');
    expect(reasoning.summary, isTrue);

    final queue = LiveEvent.fromJson({
      'type': 'queue_updated',
      'sessionId': 'session-1',
      'steeringCount': 1,
      'followUpCount': 2,
      'steeringPreview': ['Keep it neutral'],
      'followUpPreview': ['Add tests', 'Run analyze'],
    });
    expect(queue.steeringCount, 1);
    expect(queue.followUpCount, 2);
    expect(queue.steeringPreview, ['Keep it neutral']);
    expect(queue.followUpPreview, ['Add tests', 'Run analyze']);

    final retry = LiveEvent.fromJson({
      'type': 'auto_retry_updated',
      'sessionId': 'session-1',
      'phase': 'started',
      'attempt': 2,
      'maxAttempts': 3,
      'delayMs': 1500,
      'errorMessage': 'Overloaded',
    });
    expect(retry.phase, 'started');
    expect(retry.attempt, 2);
    expect(retry.maxAttempts, 3);
    expect(retry.delayMs, 1500);
    expect(retry.errorMessage, 'Overloaded');
  });

  test('LiveEvent stays compatible with unknown event types and extra keys', () {
    final event = LiveEvent.fromJson({
      'type': 'custom.provider_thing',
      'sessionId': 'session-1',
      'unexpected': {'nested': true},
      'plan': [
        {'step': 'Still parseable', 'status': 'pending'},
        {'missing': 'fields'},
      ],
      'steeringPreview': ['alpha', 2, null],
    });

    expect(event.type, 'custom.provider_thing');
    expect(event.sessionId, 'session-1');
    expect(event.plan, hasLength(1));
    expect(event.plan!.single.step, 'Still parseable');
    expect(event.steeringPreview, ['alpha']);
  });

  test('SessionMessage preserves content blocks', () {
    final msg = SessionMessage(
      id: 'msg-1',
      role: 'assistant',
      text: 'Hello',
      content: const [
        ThinkingBlock('Step one. Step two.'),
        TextBlock('Hello'),
      ],
      attachments: const [],
      createdAt: DateTime(2026, 1, 1),
      seq: 1,
      actor: const SessionActorInfo(
        kind: 'subagent',
        providerKind: 'copilot',
        agentId: 'subagent-1',
        agentDisplayName: 'Research Agent',
        parentToolCallId: 'task-1',
      ),
    );
    expect(msg.content.length, 2);
    expect((msg.content.first as ThinkingBlock).thinking, 'Step one. Step two.');

    final json = msg.toJson();
    expect(json['content'], hasLength(2));

    final parsed = SessionMessage.fromJson(json);
    expect(parsed.content.length, 2);
    expect((parsed.content.first as ThinkingBlock).thinking, 'Step one. Step two.');
    expect(parsed.actor?.kind, 'subagent');
    expect(parsed.actor?.agentDisplayName, 'Research Agent');
    expect(parsed.actor?.parentToolCallId, 'task-1');
  });

  test('SessionMessage derives content from text when absent in fromJson', () {
    final msg = SessionMessage(
      id: 'msg-1',
      role: 'assistant',
      text: 'Hello',
      attachments: const [],
      createdAt: DateTime(2026, 1, 1),
      seq: 1,
    );
    expect(msg.content, isEmpty);

    final parsed = SessionMessage.fromJson({
      'id': 'msg-1',
      'role': 'assistant',
      'text': 'Hello',
      'attachments': [],
      'createdAt': 0,
      'seq': 1,
    });
    expect(parsed.content, hasLength(1));
    expect((parsed.content.single as TextBlock).text, 'Hello');
  });

  test('SessionLog round-trips latest plan update payloads', () {
    final latestPlanUpdate = LiveEvent.fromJson({
      'type': 'plan_updated',
      'sessionId': 'session-1',
      'turnId': 'turn-1',
      'explanation': 'Use the latest daemon snapshot.',
      'plan': [
        {'step': 'Store the plan', 'status': 'completed'},
        {'step': 'Restore the plan', 'status': 'in_progress'},
      ],
      'seq': 7,
    });
    final log = SessionLog(
      session: SessionSummary(
        id: 'session-1',
        title: 'Session',
        preview: '',
        cwd: '/repo',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1, 0, 1),
        source: 'fake',
        provider: null,
        status: 'idle',
        runtime: null,
        gitInfo: null,
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
      latestPlanUpdate: latestPlanUpdate,
    );

    final parsed = SessionLog.fromJson(log.toJson());
    expect(parsed.latestPlanUpdate?.type, 'plan_updated');
    expect(parsed.latestPlanUpdate?.seq, 7);
    expect(parsed.latestPlanUpdate?.plan, hasLength(2));
    expect(parsed.latestPlanUpdate?.plan?.last.step, 'Restore the plan');

    final clearLog = SessionLog.fromJson({
      ...log.toJson(),
      'latestPlanUpdate': {
        'type': 'plan_updated',
        'sessionId': 'session-1',
        'seq': 8,
        'plan': [],
      },
    });
    expect(clearLog.latestPlanUpdate?.type, 'plan_updated');
    expect(clearLog.latestPlanUpdate?.seq, 8);
    expect(clearLog.latestPlanUpdate?.plan, isEmpty);
  });

  test('SessionActivity and LiveEvent preserve Copilot actor metadata', () {
    final activity = SessionActivity.fromJson({
      'id': 'subagent-1',
      'type': 'tool',
      'createdAt': DateTime(2026, 4, 28).millisecondsSinceEpoch,
      'seq': 7,
      'status': 'completed',
      'toolName': 'research-agent',
      'title': 'Research Agent',
      'actor': {
        'kind': 'subagent',
        'providerKind': 'copilot',
        'agentId': 'subagent-1',
        'agentDisplayName': 'Research Agent',
        'parentToolCallId': 'task-1',
        'model': 'claude-haiku-4.5',
      },
      'subAgentRun': {
        'parentToolCallId': 'task-1',
        'durationMs': 3400,
        'totalTokens': 561272,
        'totalToolCalls': 41,
      },
    });
    expect(activity.actor?.kind, 'subagent');
    expect(activity.actor?.agentDisplayName, 'Research Agent');
    expect(activity.subAgentRun?.durationMs, 3400);
    expect(activity.subAgentRun?.totalTokens, 561272);
    expect(activity.subAgentRun?.totalToolCalls, 41);

    final liveEvent = LiveEvent.fromJson({
      'type': 'assistant_delta',
      'sessionId': 'session-1',
      'itemId': 'message-1',
      'delta': 'Researching...',
      'actor': {
        'kind': 'subagent',
        'providerKind': 'copilot',
        'agentId': 'subagent-1',
        'agentDisplayName': 'Research Agent',
      },
    });
    expect(liveEvent.actor?.kind, 'subagent');
    expect(liveEvent.actor?.agentDisplayName, 'Research Agent');
  });

  test('Session status models treat waiting states as active', () {
    final summary = SessionSummary(
      id: 'session-1',
      title: 'Session',
      preview: '',
      cwd: '/repo',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1, 0, 1),
      source: 'fake',
      provider: null,
      status: 'waiting_for_approval',
      runtime: null,
      gitInfo: null,
    );
    expect(summary.isActive, isTrue);

    final status = SessionStatus.fromJson({
      'sessionId': 'session-1',
      'status': 'waiting_for_approval',
      'isRunning': true,
      'activeTurnId': 'turn-1',
      'pendingAction': null,
    });
    expect(status.status, 'waiting_for_approval');
    expect(status.isRunning, isTrue);
  });

  test('SessionSummary parses structured sub-agent lineage', () {
    final summary = SessionSummary.fromJson({
      'id': 'session-child',
      'title': 'Delegated explorer',
      'preview': 'Delegated explorer',
      'cwd': '/repo',
      'createdAt': 1,
      'updatedAt': 2,
      'source': 'sub-agent',
      'status': 'idle',
      'runtime': null,
      'gitInfo': null,
      'subAgent': {
        'parentSessionId': 'session-parent',
        'sourceKind': 'thread_spawn',
        'agentRole': 'explorer',
        'agentNickname': 'scout',
        'depth': 1,
      },
    });

    expect(summary.isSubAgent, isTrue);
    expect(summary.subAgent?.parentSessionId, 'session-parent');
    expect(summary.subAgent?.sourceKind, 'thread_spawn');
    expect(summary.subAgent?.label, 'explorer');
    expect(summary.toJson()['subAgent'], {
      'parentSessionId': 'session-parent',
      'sourceKind': 'thread_spawn',
      'agentName': null,
      'agentDisplayName': null,
      'agentRole': 'explorer',
      'agentNickname': 'scout',
      'depth': 1,
    });
  });

  test('SessionSummary.copyWith preserves legacy sub-agent badges', () {
    final legacySummary = SessionSummary(
      id: 'session-child',
      title: 'Delegated explorer',
      preview: 'Delegated explorer',
      cwd: '/repo',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
      source: 'sub-agent',
      provider: null,
      status: 'idle',
      runtime: null,
      gitInfo: null,
      isSubAgent: true,
    );

    final updated = legacySummary.copyWith(status: 'running');

    expect(updated.isSubAgent, isTrue);
    expect(updated.subAgent, isNull);
  });
}
