import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';

void main() {
  test('parses host server config snapshot payloads', () {
    final snapshot = HostServerConfigSnapshot.fromJson({
      'config': {
        'label': 'macbook',
        'recommendedMobileClientVersion': '1.5.0',
        'minimumMobileClientVersion': '1.3.0',
        'terminal': {'enabled': true, 'shell': '/bin/zsh', 'requirePty': false},
        'portForwarding': {'enabled': true, 'allowNonLoopbackTargets': false},
        'browserPreview': {
          'enabled': false,
          'chromePath': null,
          'maxPreviews': 8,
          'idleTtlMs': 3600000,
          'frameIntervalMs': 900,
          'quality': 55,
        },
      },
      'fields': {
        'label': {'source': 'file', 'writable': true, 'requiresRestart': false},
        'terminal.enabled': {
          'source': 'env',
          'writable': false,
          'requiresRestart': true,
        },
      },
      'restart': {
        'requiredForPendingChanges': true,
        'serviceManaged': false,
        'serviceName': null,
        'warning': 'manual restart may be required',
      },
    });

    expect(snapshot.config.label, 'macbook');
    expect(snapshot.config.recommendedMobileClientVersion, '1.5.0');
    expect(snapshot.config.terminal.enabled, isTrue);
    expect(snapshot.config.portForwarding.enabled, isTrue);
    expect(snapshot.config.browserPreview.maxPreviews, 8);
    expect(snapshot.fields['label']?.source, 'file');
    expect(snapshot.fields['terminal.enabled']?.writable, isFalse);
    expect(snapshot.restart.requiredForPendingChanges, isTrue);
    expect(snapshot.restart.warning, contains('manual restart'));
  });

  test('parses host server config update responses', () {
    final result = HostServerConfigUpdateResult.fromJson({
      'ok': true,
      'changed': ['label', 'terminal.enabled'],
      'appliedImmediately': ['label'],
      'config': {
        'label': 'renamed',
        'recommendedMobileClientVersion': null,
        'minimumMobileClientVersion': null,
        'terminal': {'enabled': true, 'shell': null, 'requirePty': true},
        'portForwarding': {'enabled': false, 'allowNonLoopbackTargets': false},
        'browserPreview': {
          'enabled': false,
          'chromePath': null,
          'maxPreviews': 8,
          'idleTtlMs': 3600000,
          'frameIntervalMs': 900,
          'quality': 55,
        },
      },
      'fields': {
        'label': {'source': 'file', 'writable': true, 'requiresRestart': false},
      },
      'restart': {
        'requiredForPendingChanges': true,
        'serviceManaged': true,
        'serviceName': 'sidemesh',
        'warning': null,
      },
    });

    expect(result.ok, isTrue);
    expect(result.changed, ['label', 'terminal.enabled']);
    expect(result.appliedImmediately, ['label']);
    expect(result.snapshot.config.label, 'renamed');
    expect(result.snapshot.config.terminal.requirePty, isTrue);
    expect(result.snapshot.restart.serviceManaged, isTrue);
    expect(result.snapshot.restart.serviceName, 'sidemesh');
  });
}
