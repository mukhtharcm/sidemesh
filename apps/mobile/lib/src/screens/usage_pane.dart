import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../usage_models.dart';
import '../usage_store.dart';
import '../widgets/mesh_widgets.dart';

class UsagePane extends StatefulWidget {
  const UsagePane({
    super.key,
    required this.hosts,
    required this.api,
    this.topPadding = 0,
    this.dense = false,
    this.active = true,
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final double topPadding;
  final bool dense;
  final bool active;

  @override
  State<UsagePane> createState() => _UsagePaneState();
}

class _UsagePaneState extends State<UsagePane> {
  late final UsageStore _store;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _store = UsageStore(api: widget.api);
    _store.configure(widget.hosts);
    _store.addListener(_handleStoreChanged);
    if (widget.active) {
      _startRefreshLoop(refreshNow: true);
    }
  }

  @override
  void didUpdateWidget(covariant UsagePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameHosts(oldWidget.hosts, widget.hosts)) {
      _store.configure(widget.hosts);
      if (widget.active) {
        unawaited(_store.refresh());
      }
    }
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _startRefreshLoop(refreshNow: true);
      } else {
        _stopRefreshLoop();
      }
    }
  }

  @override
  void dispose() {
    _stopRefreshLoop();
    _store.removeListener(_handleStoreChanged);
    _store.dispose();
    super.dispose();
  }

  void _handleStoreChanged() {
    if (mounted) setState(() {});
  }

  void _startRefreshLoop({required bool refreshNow}) {
    _stopRefreshLoop();
    if (refreshNow) {
      unawaited(_store.refresh());
    }
    _refreshTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      if (mounted && widget.active) unawaited(_store.refresh());
    });
  }

  void _stopRefreshLoop() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final enabledHosts = widget.hosts.where((host) => host.enabled).toList();
    if (enabledHosts.isEmpty) {
      return Container(
        color: colors.canvas,
        padding: EdgeInsets.only(top: widget.topPadding),
        child: const MeshEmptyState(
          icon: Icons.speed_rounded,
          title: 'No enabled hosts',
          body: 'Turn on a host to see limits and usage here.',
        ),
      );
    }

    final accounts = _store.accounts;
    final limits = accounts.where((account) => account.hasLimits).toList();
    final unsupported = accounts
        .where((account) => account.isUnsupported && !account.hasLimits)
        .toList();
    final other = accounts
        .where(
          (account) => !account.hasLimits && !account.isUnsupported,
        )
        .toList();

    return Container(
      color: colors.canvas,
      child: RefreshIndicator(
        onRefresh: _store.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            widget.dense ? 14 : 18,
            widget.topPadding + (widget.dense ? 12 : 18),
            widget.dense ? 14 : 18,
            24,
          ),
          children: [
            _UsageHeader(
              hostCount: enabledHosts.length,
              accountCount: accounts.length,
              loading: _store.loading,
              lastRefreshedAt: _store.lastRefreshedAt,
              onRefresh: () => unawaited(_store.refresh()),
            ),
            if (_store.failures.isNotEmpty) ...[
              const SizedBox(height: 12),
              _UsageFailureBanner(failures: _store.failures),
            ],
            if (_store.loading && _store.snapshots.isEmpty) ...[
              const SizedBox(height: 48),
              const MeshLoader(),
            ] else if (accounts.isEmpty) ...[
              const SizedBox(height: 36),
              const MeshEmptyState.compact(
                icon: Icons.speed_rounded,
                title: 'No usage observations yet',
                body: 'Pull to refresh or check that your hosts are online and up to date.',
              ),
            ] else ...[
              if (limits.isNotEmpty) ...[
                const SizedBox(height: 16),
                _SectionLabel(
                  title: 'Reported limits',
                  subtitle: 'Quota windows that hosts can confirm right now.',
                ),
                const SizedBox(height: 10),
                ...limits.map(
                  (account) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _UsageAccountCard(account: account),
                  ),
                ),
              ],
              if (other.isNotEmpty) ...[
                const SizedBox(height: 10),
                _SectionLabel(
                  title: 'Observed activity',
                  subtitle: 'Usage telemetry that is helpful, but not authoritative.',
                ),
                const SizedBox(height: 10),
                ...other.map(
                  (account) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _UsageAccountCard(account: account),
                  ),
                ),
              ],
              if (unsupported.isNotEmpty) ...[
                const SizedBox(height: 10),
                _SectionLabel(
                  title: 'Not reported',
                  subtitle: 'Providers that do not expose usage through Sidemesh yet.',
                ),
                const SizedBox(height: 10),
                ...unsupported.map(
                  (account) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _UnsupportedUsageCard(account: account),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  bool _sameHosts(List<HostProfile> left, List<HostProfile> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i += 1) {
      if (left[i].id != right[i].id ||
          left[i].enabled != right[i].enabled ||
          left[i].baseUrl != right[i].baseUrl ||
          left[i].token != right[i].token) {
        return false;
      }
    }
    return true;
  }
}

class _UsageHeader extends StatelessWidget {
  const _UsageHeader({
    required this.hostCount,
    required this.accountCount,
    required this.loading,
    required this.lastRefreshedAt,
    required this.onRefresh,
  });

  final int hostCount;
  final int accountCount;
  final bool loading;
  final DateTime? lastRefreshedAt;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Limits and usage',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: AppWeights.title,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                lastRefreshedAt == null
                    ? 'Checking ${hostCount == 1 ? "1 enabled host" : "$hostCount enabled hosts"}.'
                    : 'Updated ${_relativeAge(lastRefreshedAt!)} ago from ${hostCount == 1 ? "1 host" : "$hostCount hosts"}${accountCount > 0 ? " across $accountCount accounts" : ""}.',
                style: TextStyle(color: colors.textSecondary),
              ),
            ],
          ),
        ),
        MeshIconButton(
          icon: loading ? Icons.hourglass_top_rounded : Icons.refresh_rounded,
          tooltip: 'Refresh usage',
          onTap: onRefresh,
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: AppWeights.title,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(color: colors.textSecondary)),
      ],
    );
  }
}

class _UsageAccountCard extends StatelessWidget {
  const _UsageAccountCard({required this.account});

  final ReconciledUsageAccount account;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = account.isError ? MeshCardTone.muted : MeshCardTone.surface;
    return MeshCard(
      tone: tone,
      borderColor: account.isError ? colors.danger.withValues(alpha: 0.45) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: AppWeights.title,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _subtitle(account),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              MeshPill(
                label: account.provider.displayName,
                tone: MeshPillTone.neutral,
              ),
            ],
          ),
          if (account.message != null) ...[
            const SizedBox(height: 12),
            Text(
              account.message!,
              style: TextStyle(color: colors.textSecondary, height: 1.35),
            ),
          ],
          if (account.windows.isNotEmpty) ...[
            const SizedBox(height: 14),
            ...account.windows.map(
              (window) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _UsageWindowRow(item: window),
              ),
            ),
          ],
          if (account.credits != null) ...[
            const SizedBox(height: 2),
            _CreditsRow(credits: account.credits!),
          ],
        ],
      ),
    );
  }

  String _subtitle(ReconciledUsageAccount account) {
    final parts = <String>[];
    final plan = account.planType;
    if (plan != null && plan.isNotEmpty) parts.add(plan);
    parts.add('latest from ${account.latestHostLabel}');
    parts.add('seen ${_relativeAge(account.latestObservedAt)} ago');
    if (account.hostLabels.length > 1) {
      parts.add('${account.hostLabels.length} hosts agree');
    }
    return parts.join(' · ');
  }
}

class _UsageWindowRow extends StatelessWidget {
  const _UsageWindowRow({required this.item});

  final ReconciledUsageWindow item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final window = item.window;
    final used = window.usedPercent;
    final progress = used == null
        ? null
        : (used / 100).clamp(0.0, 1.0).toDouble();
    final tone = _toneForPercent(used);
    final resetLabel = window.resetsAt == null
        ? 'reset unavailable'
        : 'resets in ${_relativeDuration(window.resetsAt!.difference(DateTime.now()))}';
    final duration = window.windowMinutes == null
        ? null
        : _windowDurationLabel(window.windowMinutes!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                window.label,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: AppWeights.emphasis,
                ),
              ),
            ),
            MeshPill(
              label: used == null ? 'unknown' : '${used.round()}% used',
              tone: tone,
              mono: true,
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 7,
            backgroundColor: colors.surfaceMuted,
            valueColor: AlwaysStoppedAnimation<Color>(_colorForTone(colors, tone)),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          [resetLabel, ?duration, 'from ${item.hostLabel}'].join(' · '),
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

class _CreditsRow extends StatelessWidget {
  const _CreditsRow({required this.credits});

  final UsageCredits credits;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = credits.unlimited == true
        ? 'Unlimited credits'
        : 'Credits ${credits.balanceLabel ?? credits.balance?.toStringAsFixed(2) ?? 'available'}';
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.account_balance_wallet_rounded, size: 17, color: colors.accent),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: TextStyle(color: colors.textPrimary))),
        ],
      ),
    );
  }
}

class _UnsupportedUsageCard extends StatelessWidget {
  const _UnsupportedUsageCard({required this.account});

  final ReconciledUsageAccount account;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.muted,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(Icons.visibility_off_rounded, color: colors.textTertiary, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${account.provider.displayName}: ${account.message ?? 'usage unavailable'}',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _UsageFailureBanner extends StatelessWidget {
  const _UsageFailureBanner({required this.failures});

  final List<UsageHostFailure> failures;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.muted,
      borderColor: colors.warning.withValues(alpha: 0.45),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              failures.length == 1
                  ? 'Could not load ${failures.first.host.label}. ${failures.first.message}'
                  : 'Could not load usage from ${failures.length} hosts.',
              style: TextStyle(color: colors.textSecondary, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

MeshPillTone _toneForPercent(double? used) {
  if (used == null) return MeshPillTone.neutral;
  if (used >= 90) return MeshPillTone.danger;
  if (used >= 75) return MeshPillTone.warning;
  return MeshPillTone.success;
}

Color _colorForTone(AppColors colors, MeshPillTone tone) {
  return switch (tone) {
    MeshPillTone.danger => colors.danger,
    MeshPillTone.warning => colors.warning,
    MeshPillTone.success => colors.success,
    MeshPillTone.info => colors.info,
    MeshPillTone.accent => colors.accent,
    MeshPillTone.neutral => colors.textTertiary,
  };
}

String _relativeAge(DateTime at) {
  final diff = DateTime.now().difference(at);
  return _relativeDuration(diff);
}

String _relativeDuration(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  if (safe.inMinutes < 1) return 'just now';
  if (safe.inHours < 1) return '${safe.inMinutes}m';
  if (safe.inDays < 2) return '${safe.inHours}h';
  return '${safe.inDays}d';
}

String _windowDurationLabel(int minutes) {
  if (minutes < 60) return '${minutes}m window';
  if (minutes < 60 * 48) return '${(minutes / 60).round()}h window';
  return '${(minutes / (60 * 24)).round()}d window';
}
