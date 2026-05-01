import 'package:flutter_test/flutter_test.dart';

import 'package:sidemesh_mobile/src/models.dart';

void main() {
  test('PendingAction parses user-input payloads', () {
    final action = PendingAction.fromJson({
      'id': 'ask-1',
      'sessionId': 'session-1',
      'kind': 'user_input',
      'title': 'Agent question',
      'detail': 'Which environment?',
      'requestedAt': DateTime(2026, 4, 28).millisecondsSinceEpoch,
      'canApprove': false,
      'canApproveForSession': false,
      'canDecline': false,
      'state': 'recovered',
      'recoverable': true,
      'relatedActivityId': 'tool-ask-1',
      'userInput': {
        'question': 'Which environment?',
        'choices': ['staging', 'production'],
        'allowFreeform': false,
      },
    });

    expect(action.isUserInput, isTrue);
    expect(action.isRecovered, isTrue);
    expect(action.recoverable, isTrue);
    expect(action.relatedActivityId, 'tool-ask-1');
    expect(action.userInput?.choices, ['staging', 'production']);
  });

  test('PendingAction parses elicitation payloads', () {
    final action = PendingAction.fromJson({
      'id': 'form-1',
      'sessionId': 'session-1',
      'kind': 'elicitation',
      'title': 'Structured input requested',
      'detail': 'Choose deployment options',
      'requestedAt': DateTime(2026, 4, 28).millisecondsSinceEpoch,
      'canApprove': false,
      'canApproveForSession': false,
      'canDecline': true,
      'elicitation': {
        'mode': 'form',
        'message': 'Choose deployment options',
        'source': 'deploy',
        'fields': [
          {
            'key': 'region',
            'type': 'string',
            'title': 'Region',
            'required': true,
            'options': [
              {'value': 'us-east', 'label': 'US East'},
            ],
          },
          {
            'key': 'dryRun',
            'type': 'boolean',
            'title': 'Dry run',
            'required': false,
            'defaultValue': true,
          },
        ],
      },
    });

    expect(action.isElicitation, isTrue);
    expect(action.elicitation?.fields.length, 2);
    expect(action.elicitation?.fields.first.options?.first.value, 'us-east');
  });

  test('PendingActionResponseDraft encodes expected payloads', () {
    expect(
      PendingActionResponseDraft.userInput(
        answer: 'staging',
        wasFreeform: false,
      ).payload,
      {'answer': 'staging', 'wasFreeform': false},
    );
    expect(
      PendingActionResponseDraft.elicitation(
        action: 'accept',
        content: {'region': 'us-east'},
      ).payload,
      {
        'action': 'accept',
        'content': {'region': 'us-east'},
      },
    );
  });
}
