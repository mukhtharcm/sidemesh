import 'models.dart';

class HostUsageSnapshot {
  const HostUsageSnapshot({
    required this.host,
    required this.generatedAt,
    required this.hostLabel,
    required this.hostname,
    required this.observations,
  });

  final HostProfile host;
  final DateTime generatedAt;
  final String hostLabel;
  final String hostname;
  final List<UsageObservation> observations;

  factory HostUsageSnapshot.fromJson(
    HostProfile host,
    Map<String, dynamic> json,
  ) {
    final hostJson = json['host'] is Map<String, dynamic>
        ? json['host'] as Map<String, dynamic>
        : const <String, dynamic>{};
    return HostUsageSnapshot(
      host: host,
      generatedAt: _dateValue(json['generatedAt']),
      hostLabel: _stringOrNull(hostJson['label']) ?? host.label,
      hostname: _stringOrNull(hostJson['hostname']) ?? '',
      observations: (json['observations'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map(
            (item) => UsageObservation.fromJson(
              Map<String, dynamic>.from(item),
              fallbackHost: host,
            ),
          )
          .toList(),
    );
  }
}

class UsageObservation {
  const UsageObservation({
    required this.id,
    required this.hostId,
    required this.hostLabel,
    required this.observedAt,
    required this.provider,
    required this.subject,
    required this.windows,
    required this.health,
    required this.source,
    this.expiresAt,
    this.account,
    this.credits,
    this.totals,
    this.message,
  });

  final String id;
  final String hostId;
  final String hostLabel;
  final DateTime observedAt;
  final DateTime? expiresAt;
  final UsageProviderRef provider;
  final UsageAccountRef? account;
  final UsageSubjectRef subject;
  final List<UsageWindow> windows;
  final UsageCredits? credits;
  final UsageTotals? totals;
  final String health;
  final UsageSourceRef source;
  final String? message;

  bool get isAuthoritativeLimit => windows.isNotEmpty || credits != null;
  bool get isUnsupported => health == 'unsupported';
  bool get isError => health == 'error' || health == 'unauthorized';

  factory UsageObservation.fromJson(
    Map<String, dynamic> json, {
    required HostProfile fallbackHost,
  }) {
    return UsageObservation(
      id: _stringOrNull(json['id']) ?? 'usage',
      hostId: fallbackHost.id,
      hostLabel: _stringOrNull(json['hostLabel']) ?? fallbackHost.label,
      observedAt: _dateValue(json['observedAt']),
      expiresAt: _dateOrNull(json['expiresAt']),
      provider: UsageProviderRef.fromJson(json['provider']),
      account: json['account'] is Map
          ? UsageAccountRef.fromJson(json['account'])
          : null,
      subject: UsageSubjectRef.fromJson(json['subject']),
      windows: (json['windows'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((item) => UsageWindow.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      credits: json['credits'] is Map
          ? UsageCredits.fromJson(json['credits'])
          : null,
      totals: json['totals'] is Map ? UsageTotals.fromJson(json['totals']) : null,
      health: _stringOrNull(json['health']) ?? 'unknown',
      source: UsageSourceRef.fromJson(json['source']),
      message: _stringOrNull(json['message']),
    );
  }
}

class UsageProviderRef {
  const UsageProviderRef({
    required this.kind,
    required this.displayName,
    this.upstreamKind,
    this.upstreamDisplayName,
  });

  final String kind;
  final String displayName;
  final String? upstreamKind;
  final String? upstreamDisplayName;

  factory UsageProviderRef.fromJson(Object? json) {
    if (json is! Map) {
      return const UsageProviderRef(kind: 'unknown', displayName: 'Unknown');
    }
    return UsageProviderRef(
      kind: _stringOrNull(json['kind']) ?? 'unknown',
      displayName: _stringOrNull(json['displayName']) ?? 'Unknown',
      upstreamKind: _stringOrNull(json['upstreamKind']),
      upstreamDisplayName: _stringOrNull(json['upstreamDisplayName']),
    );
  }
}

class UsageAccountRef {
  const UsageAccountRef({
    this.displayLabel,
    this.accountIdHash,
    this.emailHash,
    this.organizationIdHash,
    this.planType,
    this.loginMethod,
  });

  final String? displayLabel;
  final String? accountIdHash;
  final String? emailHash;
  final String? organizationIdHash;
  final String? planType;
  final String? loginMethod;

  factory UsageAccountRef.fromJson(Object? json) {
    if (json is! Map) return const UsageAccountRef();
    return UsageAccountRef(
      displayLabel: _stringOrNull(json['displayLabel']),
      accountIdHash: _stringOrNull(json['accountIdHash']),
      emailHash: _stringOrNull(json['emailHash']),
      organizationIdHash: _stringOrNull(json['organizationIdHash']),
      planType: _stringOrNull(json['planType']),
      loginMethod: _stringOrNull(json['loginMethod']),
    );
  }
}

class UsageSubjectRef {
  const UsageSubjectRef({
    required this.kind,
    required this.displayName,
    this.stableKeyHash,
  });

  final String kind;
  final String displayName;
  final String? stableKeyHash;

  factory UsageSubjectRef.fromJson(Object? json) {
    if (json is! Map) {
      return const UsageSubjectRef(kind: 'unknown', displayName: 'Unknown');
    }
    return UsageSubjectRef(
      kind: _stringOrNull(json['kind']) ?? 'unknown',
      displayName: _stringOrNull(json['displayName']) ?? 'Unknown',
      stableKeyHash: _stringOrNull(json['stableKeyHash']),
    );
  }
}

class UsageWindow {
  const UsageWindow({
    required this.id,
    required this.label,
    this.usedPercent,
    this.remainingPercent,
    this.windowMinutes,
    this.resetsAt,
    this.resetDescription,
  });

  final String id;
  final String label;
  final double? usedPercent;
  final double? remainingPercent;
  final int? windowMinutes;
  final DateTime? resetsAt;
  final String? resetDescription;

  factory UsageWindow.fromJson(Map<String, dynamic> json) => UsageWindow(
    id: _stringOrNull(json['id']) ?? 'window',
    label: _stringOrNull(json['label']) ?? 'Window',
    usedPercent: _doubleOrNull(json['usedPercent']),
    remainingPercent: _doubleOrNull(json['remainingPercent']),
    windowMinutes: _intOrNull(json['windowMinutes']),
    resetsAt: _dateOrNull(json['resetsAt']),
    resetDescription: _stringOrNull(json['resetDescription']),
  );
}

class UsageCredits {
  const UsageCredits({
    this.balance,
    this.balanceLabel,
    this.unlimited,
    this.hasCredits,
  });

  final double? balance;
  final String? balanceLabel;
  final bool? unlimited;
  final bool? hasCredits;

  factory UsageCredits.fromJson(Object? json) {
    if (json is! Map) return const UsageCredits();
    return UsageCredits(
      balance: _doubleOrNull(json['balance']),
      balanceLabel: _stringOrNull(json['balanceLabel']),
      unlimited: json['unlimited'] is bool ? json['unlimited'] as bool : null,
      hasCredits: json['hasCredits'] is bool ? json['hasCredits'] as bool : null,
    );
  }
}

class UsageTotals {
  const UsageTotals({
    this.inputTokens,
    this.outputTokens,
    this.reasoningTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.totalTokens,
    this.cost,
  });

  final int? inputTokens;
  final int? outputTokens;
  final int? reasoningTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final int? totalTokens;
  final double? cost;

  factory UsageTotals.fromJson(Object? json) {
    if (json is! Map) return const UsageTotals();
    return UsageTotals(
      inputTokens: _intOrNull(json['inputTokens']),
      outputTokens: _intOrNull(json['outputTokens']),
      reasoningTokens: _intOrNull(json['reasoningTokens']),
      cacheReadTokens: _intOrNull(json['cacheReadTokens']),
      cacheWriteTokens: _intOrNull(json['cacheWriteTokens']),
      totalTokens: _intOrNull(json['totalTokens']),
      cost: _doubleOrNull(json['cost']),
    );
  }
}

class UsageSourceRef {
  const UsageSourceRef({
    required this.id,
    required this.label,
    required this.kind,
    this.priority,
  });

  final String id;
  final String label;
  final String kind;
  final int? priority;

  factory UsageSourceRef.fromJson(Object? json) {
    if (json is! Map) {
      return const UsageSourceRef(
        id: 'unknown',
        label: 'Unknown',
        kind: 'unknown',
      );
    }
    return UsageSourceRef(
      id: _stringOrNull(json['id']) ?? 'unknown',
      label: _stringOrNull(json['label']) ?? 'Unknown',
      kind: _stringOrNull(json['kind']) ?? 'unknown',
      priority: _intOrNull(json['priority']),
    );
  }
}

class ReconciledUsageAccount {
  const ReconciledUsageAccount({
    required this.key,
    required this.provider,
    required this.subject,
    required this.observations,
    required this.windows,
    required this.hostLabels,
    required this.latestHostLabel,
    required this.latestObservedAt,
    this.account,
    this.credits,
    this.message,
  });

  final String key;
  final UsageProviderRef provider;
  final UsageSubjectRef subject;
  final UsageAccountRef? account;
  final List<UsageObservation> observations;
  final List<ReconciledUsageWindow> windows;
  final UsageCredits? credits;
  final List<String> hostLabels;
  final String latestHostLabel;
  final DateTime latestObservedAt;
  final String? message;

  bool get hasLimits => windows.isNotEmpty || credits != null;
  bool get isUnsupported => observations.every((item) => item.isUnsupported);
  bool get isError => observations.first.isError;
  String get displayName => account?.displayLabel ?? subject.displayName;
  String? get planType => account?.planType;
}

class ReconciledUsageWindow {
  const ReconciledUsageWindow({
    required this.window,
    required this.hostLabel,
    required this.observedAt,
  });

  final UsageWindow window;
  final String hostLabel;
  final DateTime observedAt;
}

class UsageReconciler {
  const UsageReconciler._();

  static List<ReconciledUsageAccount> reconcile(
    List<HostUsageSnapshot> snapshots,
  ) {
    final grouped = <String, List<UsageObservation>>{};
    for (final snapshot in snapshots) {
      for (final observation in snapshot.observations) {
        final key = _reconciliationKey(observation);
        grouped.putIfAbsent(key, () => <UsageObservation>[]).add(observation);
      }
    }

    final accounts = grouped.entries.map((entry) {
      final observations = [...entry.value]
        ..sort((left, right) => right.observedAt.compareTo(left.observedAt));
      final latest = observations.first;
      final windowsById = <String, ReconciledUsageWindow>{};
      for (final observation in observations) {
        for (final window in observation.windows) {
          windowsById.putIfAbsent(
            window.id,
            () => ReconciledUsageWindow(
              window: window,
              hostLabel: observation.hostLabel,
              observedAt: observation.observedAt,
            ),
          );
        }
      }
      final hostLabels = <String>[];
      for (final observation in observations) {
        if (!hostLabels.contains(observation.hostLabel)) {
          hostLabels.add(observation.hostLabel);
        }
      }
      return ReconciledUsageAccount(
        key: entry.key,
        provider: latest.provider,
        subject: latest.subject,
        account: latest.account,
        observations: observations,
        windows: windowsById.values.toList(),
        credits: latest.credits,
        hostLabels: hostLabels,
        latestHostLabel: latest.hostLabel,
        latestObservedAt: latest.observedAt,
        message: latest.message,
      );
    }).toList();

    accounts.sort((left, right) {
      if (left.hasLimits != right.hasLimits) return left.hasLimits ? -1 : 1;
      if (left.isUnsupported != right.isUnsupported) {
        return left.isUnsupported ? 1 : -1;
      }
      return right.latestObservedAt.compareTo(left.latestObservedAt);
    });
    return accounts;
  }

  static String _reconciliationKey(UsageObservation observation) {
    final stable = observation.subject.stableKeyHash;
    if (stable != null && stable.isNotEmpty) {
      return '${observation.provider.kind}:${observation.subject.kind}:$stable';
    }
    return '${observation.provider.kind}:${observation.hostId}:${observation.source.id}:${observation.id}';
  }
}

String? _stringOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.round();
  if (value is String) return int.tryParse(value);
  return null;
}

double? _doubleOrNull(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

DateTime _dateValue(Object? value) =>
    _dateOrNull(value) ?? DateTime.fromMillisecondsSinceEpoch(0);

DateTime? _dateOrNull(Object? value) {
  final raw = _intOrNull(value);
  if (raw == null || raw <= 0) return null;
  final millis = raw < 10000000000 ? raw * 1000 : raw;
  return DateTime.fromMillisecondsSinceEpoch(millis);
}
