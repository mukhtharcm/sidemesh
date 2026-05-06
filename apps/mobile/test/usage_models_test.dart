import 'package:flutter_test/flutter_test.dart';
import 'package:sidemesh_mobile/src/models.dart';
import 'package:sidemesh_mobile/src/usage_models.dart';

void main() {
  test('UsageReconciler merges matching account observations across hosts', () {
    final hostA = const HostProfile(
      id: 'host-a',
      label: 'laptop',
      baseUrl: 'http://a',
      token: 'a',
    );
    final hostB = const HostProfile(
      id: 'host-b',
      label: 'desktop',
      baseUrl: 'http://b',
      token: 'b',
    );

    final accounts = UsageReconciler.reconcile([
      HostUsageSnapshot.fromJson(hostA, {
        'generatedAt': 2000,
        'host': {'label': 'laptop'},
        'observations': [
          _observationJson(
            hostLabel: 'laptop',
            observedAt: 1000,
            stableKeyHash: 'account-key',
            usedPercent: 20,
          ),
        ],
      }),
      HostUsageSnapshot.fromJson(hostB, {
        'generatedAt': 4000,
        'host': {'label': 'desktop'},
        'observations': [
          _observationJson(
            hostLabel: 'desktop',
            observedAt: 3000,
            stableKeyHash: 'account-key',
            usedPercent: 40,
          ),
        ],
      }),
    ]);

    expect(accounts, hasLength(1));
    expect(accounts.single.hostLabels, ['desktop', 'laptop']);
    expect(accounts.single.latestHostLabel, 'desktop');
    expect(accounts.single.windows.single.window.usedPercent, 40);
    expect(accounts.single.windows.single.hostLabel, 'desktop');
  });

  test('UsageReconciler does not merge unstable subjects across hosts', () {
    final hostA = const HostProfile(
      id: 'host-a',
      label: 'laptop',
      baseUrl: 'http://a',
      token: 'a',
    );
    final hostB = const HostProfile(
      id: 'host-b',
      label: 'desktop',
      baseUrl: 'http://b',
      token: 'b',
    );

    final accounts = UsageReconciler.reconcile([
      HostUsageSnapshot.fromJson(hostA, {
        'generatedAt': 2000,
        'host': {'label': 'laptop'},
        'observations': [
          _observationJson(hostLabel: 'same-label', observedAt: 1000),
        ],
      }),
      HostUsageSnapshot.fromJson(hostB, {
        'generatedAt': 4000,
        'host': {'label': 'same-label'},
        'observations': [
          _observationJson(hostLabel: 'same-label', observedAt: 3000),
        ],
      }),
    ]);

    expect(accounts, hasLength(2));
  });
}

Map<String, dynamic> _observationJson({
  required String hostLabel,
  required int observedAt,
  String? stableKeyHash,
  int usedPercent = 20,
}) => {
  'id': 'codex:account',
  'hostId': 'server-local-id',
  'hostLabel': hostLabel,
  'observedAt': observedAt,
  'provider': {'kind': 'codex', 'displayName': 'Codex'},
  'account': {'displayLabel': 'm***@example.com', 'planType': 'pro'},
  'subject': {
    'kind': stableKeyHash == null ? 'unknown' : 'account',
    'displayName': 'm***@example.com',
    'stableKeyHash': stableKeyHash,
  },
  'windows': [
    {
      'id': 'primary',
      'label': 'Primary',
      'usedPercent': usedPercent,
      'remainingPercent': 100 - usedPercent,
      'windowMinutes': 300,
      'resetsAt': 6000,
    },
  ],
  'health': 'ok',
  'source': {
    'id': 'codex.accountRateLimits',
    'label': 'Codex account limits',
    'kind': 'providerRpc',
  },
};
