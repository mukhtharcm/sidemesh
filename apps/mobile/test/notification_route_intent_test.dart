import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/local_notification_service.dart';

void main() {
  test('parses a local approval notification', () {
    final intent = NotificationRouteIntent.fromPayload(
      jsonEncode({
        'type': 'approval',
        'hostId': 'host-1',
        'sessionId': 'session-1',
        'actionId': 'action-1',
      }),
    );

    expect(intent?.type, 'approval');
    expect(intent?.actionId, 'action-1');
  });

  test('parses remote completion and failure notifications', () {
    for (final type in ['turn_completed', 'turn_failed']) {
      final intent = NotificationRouteIntent.fromJson({
        'type': type,
        'hostId': 'host-1',
        'sessionId': 'session-1',
      });
      expect(intent?.type, type);
      expect(intent?.hostId, 'host-1');
      expect(intent?.sessionId, 'session-1');
      expect(intent?.actionId, isEmpty);
    }
  });

  test('requires an action id for approval and input notifications', () {
    expect(
      NotificationRouteIntent.fromJson({
        'type': 'input_required',
        'hostId': 'host-1',
        'sessionId': 'session-1',
      }),
      isNull,
    );
  });
}
