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

  test('SessionMessage preserves reasoning field', () {
    final msg = SessionMessage(
      id: 'msg-1',
      role: 'assistant',
      text: 'Hello',
      attachments: const [],
      createdAt: DateTime(2026, 1, 1),
      seq: 1,
      reasoning: 'Step one. Step two.',
    );
    expect(msg.reasoning, 'Step one. Step two.');

    final json = msg.toJson();
    expect(json['reasoning'], 'Step one. Step two.');

    final parsed = SessionMessage.fromJson(json);
    expect(parsed.reasoning, 'Step one. Step two.');
  });

  test('SessionMessage defaults reasoning to empty string', () {
    final msg = SessionMessage(
      id: 'msg-1',
      role: 'assistant',
      text: 'Hello',
      attachments: const [],
      createdAt: DateTime(2026, 1, 1),
      seq: 1,
    );
    expect(msg.reasoning, '');

    final parsed = SessionMessage.fromJson({
      'id': 'msg-1',
      'role': 'assistant',
      'text': 'Hello',
      'attachments': [],
      'createdAt': 0,
      'seq': 1,
    });
    expect(parsed.reasoning, '');
  });
}
