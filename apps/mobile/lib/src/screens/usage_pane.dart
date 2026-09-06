import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../usage_models.dart';
import '../usage_store.dart';
import '../widgets/app_primitives.dart';
import '../widgets/mesh_widgets.dart';
import '../theme/app_status_styles.dart';

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
          title: 'No machines turned on',
          body: 'Turn on a machine to see usage here.',
        ),
      );
    }

    final accounts = _store.accounts
        .where((account) => !account.isUnsupported || account.hasLimits)
        .toList();
    final limits = accounts.where((account) => account.hasLimits).toList();
    final other = accounts
        .where((account) => !account.hasLimits && !account.isUnsupported)
        .toList();

    return Container(
      color: colors.canvas,
      child: AppContentColumn(
        child: RefreshIndicator(
          onRefresh: _store.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              widget.dense ? AppSizes.desktopGutter : AppSizes.mobileGutter,
              widget.topPadding + AppSpacing.md,
              widget.dense ? AppSizes.desktopGutter : AppSizes.mobileGutter,
              AppSpacing.xl,
            ),
            children: [
              _UsageHeader(
                showTitle: widget.dense,
                hostCount: enabledHosts.length,
                accountCount: accounts.length,
                loading: _store.loading,
                lastRefreshedAt: _store.lastRefreshedAt,
                onRefresh: () => unawaited(_store.refresh()),
              ),
              if (_store.failures.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                _UsageFailureBanner(failures: _store.failures),
              ],
              if (_store.loading && _store.snapshots.isEmpty) ...[
                SizedBox(height: widget.dense ? 18 : 24),
                MeshLoader(label: 'Loading usage'),
              ] else if (accounts.isEmpty) ...[
                const SizedBox(height: 36),
                const MeshEmptyState.compact(
                  icon: Icons.speed_rounded,
                  title: 'No usage available',
                  body:
                      'Pull to refresh, or check that your machines are online.',
                ),
              ] else ...[
                if (limits.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  const AppSectionHeader(title: 'Limits'),
                  const SizedBox(height: AppSpacing.compact),
                  _UsageAccountCollection(
                    accounts: limits,
                    dense: widget.dense,
                  ),
                ],
                if (other.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.compact),
                  const AppSectionHeader(title: 'Recent usage'),
                  const SizedBox(height: AppSpacing.compact),
                  _UsageAccountCollection(accounts: other, dense: widget.dense),
                ],
              ],
            ],
          ),
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

class _UsageAccountCollection extends StatelessWidget {
  const _UsageAccountCollection({required this.accounts, required this.dense});

  final List<ReconciledUsageAccount> accounts;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useColumns = dense && constraints.maxWidth >= 720;
        if (!useColumns) {
          return Column(
            children: [
              for (var index = 0; index < accounts.length; index++) ...[
                _UsageAccountCard(account: accounts[index]),
                if (index < accounts.length - 1)
                  const SizedBox(height: AppSpacing.sm),
              ],
            ],
          );
        }
        const gap = AppSpacing.md;
        final width = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: accounts
              .map(
                (account) => SizedBox(
                  width: width,
                  child: _UsageAccountCard(account: account),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }
}

class _UsageHeader extends StatelessWidget {
  const _UsageHeader({
    required this.showTitle,
    required this.hostCount,
    required this.accountCount,
    required this.loading,
    required this.lastRefreshedAt,
    required this.onRefresh,
  });

  final bool showTitle;
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
              if (showTitle) ...[
                Text(
                  'Usage',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: AppWeights.title,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
              ],
              Text(
                lastRefreshedAt == null
                    ? 'Checking ${hostCount == 1 ? "1 machine" : "$hostCount machines"}.'
                    : 'Updated ${_relativeAgeLabel(lastRefreshedAt!)}',
                style: TextStyle(color: colors.textSecondary),
              ),
            ],
          ),
        ),
        if (loading)
          const MeshDelayedActivityIndicator(active: true)
        else
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh usage',
            onPressed: onRefresh,
          ),
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
      bordered: account.isError,
      borderColor: account.isError
          ? colors.danger.withValues(alpha: AppEmphasis.disabled)
          : null,
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
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      _subtitle(account),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (account.message != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              account.message!,
              style: TextStyle(
                color: colors.textSecondary,
                height: AppLineHeights.caption,
              ),
            ),
          ],
          if (account.windows.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            ...account.windows.map(
              (window) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: _UsageWindowRow(item: window),
              ),
            ),
          ],
          if (account.credits != null) ...[
            const SizedBox(height: AppSpacing.xxs),
            _CreditsRow(credits: account.credits!),
          ],
        ],
      ),
    );
  }

  String _subtitle(ReconciledUsageAccount account) {
    final parts = <String>[account.provider.displayName];
    final plan = account.planType;
    if (plan != null && plan.isNotEmpty) parts.add(plan);
    parts.add('from ${account.latestHostLabel}');
    if (account.hostLabels.length > 1) {
      parts.add('matched on ${account.hostLabels.length} machines');
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
        ? 'reset time unavailable'
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
            Text(
              used == null ? 'Not reported' : '${used.round()}% used',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: _colorForTone(colors, tone),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (progress != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.capsule),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: colors.surfaceMuted,
              valueColor: AlwaysStoppedAnimation<Color>(
                _colorForTone(colors, tone),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.tight),
        Text(
          [resetLabel, ?duration].join(' · '),
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: AppFontSizes.caption,
          ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(
            Icons.account_balance_wallet_rounded,
            size: AppSizes.inlineIcon,
            color: colors.accent,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(label, style: TextStyle(color: colors.textPrimary)),
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
      borderColor: colors.warning.withValues(alpha: AppEmphasis.disabled),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: colors.warning,
            size: AppSizes.icon,
          ),
          const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: Text(
              failures.length == 1
                  ? 'Could not load ${failures.first.host.label}. ${failures.first.message}'
                  : 'Could not load usage from ${failures.length} machines.',
              style: TextStyle(
                color: colors.textSecondary,
                height: AppLineHeights.caption,
              ),
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

String _relativeAgeLabel(DateTime at) {
  final age = _relativeAge(at);
  return age == 'just now' ? age : '$age ago';
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
