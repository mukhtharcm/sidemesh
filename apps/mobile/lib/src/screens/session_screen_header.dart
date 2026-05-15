part of 'session_screen.dart';

class _CachedTranscriptStrip extends StatelessWidget {
  const _CachedTranscriptStrip({
    required this.mode,
    required this.refreshing,
    this.lastConnectedLabel,
    this.onRetry,
  });

  final _TranscriptFreshnessMode mode;
  final bool refreshing;
  final String? lastConnectedLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final icon = switch (mode) {
      _TranscriptFreshnessMode.cached => Icons.history_rounded,
      _TranscriptFreshnessMode.reconnecting => Icons.sync_rounded,
      _TranscriptFreshnessMode.offline => Icons.wifi_off_rounded,
    };
    final text = switch (mode) {
      _TranscriptFreshnessMode.cached =>
        refreshing
            ? 'Cached transcript · syncing latest changes'
            : 'Cached transcript · waiting for latest host snapshot',
      _TranscriptFreshnessMode.reconnecting =>
        lastConnectedLabel == null
            ? 'Reconnecting · checking latest events'
            : 'Reconnecting · $_lastConnectedText',
      _TranscriptFreshnessMode.offline =>
        lastConnectedLabel == null
            ? 'Offline · showing last known session state'
            : 'Offline · $_lastConnectedText',
    };
    return MeshSurface(
      tone: MeshSurfaceTone.warning,
      radius: AppRadii.control,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (refreshing)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
                color: colors.warning,
              ),
            )
          else
            Icon(icon, size: 14, color: colors.warning),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                color: colors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (mode == _TranscriptFreshnessMode.offline && onRetry != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onRetry,
              behavior: HitTestBehavior.opaque,
              child: Text(
                'Retry',
                style: monoStyle(
                  color: colors.warning,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String get _lastConnectedText => lastConnectedLabel == 'just now'
      ? 'last connected just now'
      : 'last connected $lastConnectedLabel ago';
}

enum _SessionActionTone { neutral, accent, warning, danger }

class _SessionActionSpec {
  const _SessionActionSpec({
    required this.value,
    required this.label,
    required this.icon,
    this.detail,
    this.tone = _SessionActionTone.neutral,
    this.active = false,
  });

  final String value;
  final String label;
  final String? detail;
  final IconData icon;
  final _SessionActionTone tone;
  final bool active;
}

class _SessionActionGroup {
  const _SessionActionGroup({required this.label, required this.actions});

  final String label;
  final List<_SessionActionSpec> actions;
}

class _SessionActionSheet extends StatelessWidget {
  const _SessionActionSheet({
    required this.session,
    required this.groups,
    this.desktop = false,
  });

  final SessionSummary session;
  final List<_SessionActionGroup> groups;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.84;
    final visibleGroups = groups
        .where((group) => group.actions.isNotEmpty)
        .toList(growable: false);
    final shape = desktop ? AppShapes.dialog : AppShapes.sheet;
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: shape,
        border: Border.all(color: colors.border),
        boxShadow: desktop
            ? AppShadows.dialog(colors.textPrimary)
            : AppShadows.sheet(colors.textPrimary),
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(14, desktop ? 14 : 10, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!desktop) ...[
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.borderStrong.withValues(alpha: 0.55),
                      borderRadius: AppShapes.pill,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: desktop ? 34 : 38,
                    height: desktop ? 34 : 38,
                    decoration: BoxDecoration(
                      color: colors.accentMuted,
                      borderRadius: AppShapes.iconWell,
                      border: Border.all(
                        color: colors.accent.withValues(alpha: 0.24),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.auto_awesome_mosaic_rounded,
                      size: desktop ? 18 : 19,
                      color: colors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Session actions',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: AppWeights.title,
                                letterSpacing: -0.2,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: colors.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                  if (!desktop)
                    MeshIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Close',
                      color: colors.textSecondary,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              for (var index = 0; index < visibleGroups.length; index++)
                Padding(
                  padding: EdgeInsets.only(
                    bottom: index == visibleGroups.length - 1 ? 0 : 12,
                  ),
                  child: _SessionActionGroupCard(
                    group: visibleGroups[index],
                    compact: desktop,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (desktop) {
      return panel;
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 10, top: 0, right: 10, bottom: 10),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: panel,
          ),
        ),
      ),
    );
  }
}

class _SessionActionGroupCard extends StatelessWidget {
  const _SessionActionGroupCard({required this.group, this.compact = false});

  final _SessionActionGroup group;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 7),
          child: Text(
            group.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            children: [
              for (var index = 0; index < group.actions.length; index++) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    indent: compact ? 52 : 58,
                    color: colors.border.withValues(alpha: 0.72),
                  ),
                _SessionActionRow(
                  action: group.actions[index],
                  compact: compact,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SessionActionRow extends StatelessWidget {
  const _SessionActionRow({required this.action, this.compact = false});

  final _SessionActionSpec action;
  final bool compact;

  Color _toneColor(AppColors colors) {
    return switch (action.tone) {
      _SessionActionTone.accent => colors.accent,
      _SessionActionTone.warning => colors.warning,
      _SessionActionTone.danger => colors.danger,
      _ => colors.textSecondary,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = _toneColor(colors);
    return MeshListRow(
      framed: false,
      dense: true,
      radius: AppRadii.control,
      onTap: () => Navigator.of(context).pop(action.value),
      leading: Container(
        width: compact ? 30 : 34,
        height: compact ? 30 : 34,
        decoration: BoxDecoration(
          color: tone.withValues(alpha: action.active ? 0.14 : 0.08),
          borderRadius: AppShapes.iconWell,
          border: Border.all(color: tone.withValues(alpha: 0.18)),
        ),
        child: Icon(action.icon, size: compact ? 17 : 18, color: tone),
      ),
      title: Text(
        action.label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: action.tone == _SessionActionTone.danger
              ? colors.danger
              : colors.textPrimary,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.1,
        ),
      ),
      subtitle: (action.detail ?? '').isEmpty
          ? null
          : Text(
              action.detail!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.host,
    required this.session,
    required this.gitStatus,
    required this.showGit,
    required this.running,
    required this.favorite,
    required this.pinnedCount,
    required this.pinnedActive,
    required this.onPinnedTap,
    required this.onDetails,
    required this.onGitDetails,
  });

  final HostProfile host;
  final SessionSummary session;
  final SessionGitStatus? gitStatus;
  final bool showGit;
  final bool running;
  final bool favorite;
  final int pinnedCount;
  final bool pinnedActive;
  final VoidCallback onPinnedTap;
  final VoidCallback onDetails;
  final VoidCallback onGitDetails;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final gitLabel = showGit ? _gitHeaderLabel(session, gitStatus) : null;
    final contextLabel = _contextUsageLabel(session.runtime);
    final contextTone = _contextUsageTone(session.runtime);
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 2, right: 16, bottom: 8),
      child: MeshCard(
        padding: const EdgeInsets.only(left: 14, top: 9, right: 8, bottom: 9),
        borderColor: running ? colors.success.withValues(alpha: 0.5) : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _HeaderStatusDot(
                        color: running ? colors.success : colors.textTertiary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        running ? 'running' : 'idle',
                        style: monoStyle(
                          color: running
                              ? colors.success
                              : colors.textSecondary,
                          fontSize: 10.5,
                        ),
                      ),
                      if (session.provider != null) ...[
                        const SizedBox(width: 6),
                        AgentProviderBadge(
                          providerKind: session.provider,
                          compact: true,
                        ),
                      ],
                      if (favorite) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.star_rounded,
                          size: 13,
                          color: colors.warning,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    session.cwd,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoStyle(color: colors.textSecondary, fontSize: 11),
                  ),
                  if (gitLabel != null ||
                      contextLabel != null ||
                      pinnedCount > 0) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (contextLabel != null)
                          MeshPill(
                            label: contextLabel,
                            icon: Icons.data_usage_rounded,
                            tone: contextTone,
                            mono: true,
                          ),
                        if (gitLabel != null)
                          _GitSummaryPill(
                            label: gitLabel,
                            dirty: gitStatus?.dirty ?? false,
                            onTap: onGitDetails,
                          ),
                        if (pinnedCount > 0)
                          _PinnedSummaryPill(
                            count: pinnedCount,
                            active: pinnedActive,
                            onTap: onPinnedTap,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onDetails,
              icon: Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: colors.accent,
              ),
              tooltip: 'Session details',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ],
        ),
      ),
    );
  }
}

String? _gitHeaderLabel(SessionSummary session, SessionGitStatus? status) {
  final branch = status?.branch ?? session.gitInfo?.branch;
  final shortSha = status?.shortSha ?? session.gitInfo?.shortSha;
  final label = (branch ?? shortSha ?? '').trim();
  if (label.isEmpty) {
    return null;
  }
  final changed = status?.changed ?? 0;
  if (changed > 0) {
    return '$label · $changed changed';
  }
  if ((status?.ahead ?? 0) > 0 || (status?.behind ?? 0) > 0) {
    final ahead = status!.ahead > 0 ? '↑${status.ahead}' : null;
    final behind = status.behind > 0 ? '↓${status.behind}' : null;
    return [label, ahead, behind].whereType<String>().join(' · ');
  }
  return label;
}

class _GitSummaryPill extends StatelessWidget {
  const _GitSummaryPill({
    required this.label,
    required this.dirty,
    required this.onTap,
  });

  final String label;
  final bool dirty;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        onTap: onTap,
        child: MeshPill(
          label: label,
          icon: Icons.account_tree_rounded,
          tone: dirty ? MeshPillTone.warning : MeshPillTone.neutral,
          mono: true,
        ),
      ),
    );
  }
}

class _PinnedSummaryPill extends StatelessWidget {
  const _PinnedSummaryPill({
    required this.count,
    required this.active,
    required this.onTap,
  });

  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(999)),
        onTap: onTap,
        child: MeshPill(
          label: '$count pinned',
          icon: Icons.push_pin_rounded,
          tone: active ? MeshPillTone.accent : MeshPillTone.neutral,
          mono: true,
        ),
      ),
    );
  }
}

class _JumpToLatestPill extends StatelessWidget {
  const _JumpToLatestPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = readableActionForeground(colors, colors.accent);
    return Material(
      color: colors.accent,
      shape: const StadiumBorder(),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_downward_rounded,
                size: 16,
                color: foreground,
              ),
              const SizedBox(width: 6),
              Text(
                'Jump to latest',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact mobile header. It preserves orientation while keeping detailed
/// session metadata behind the details and overflow surfaces.
class _SessionAppBarSubtitle extends StatelessWidget {
  const _SessionAppBarSubtitle({
    required this.host,
    required this.session,
    required this.gitStatus,
    required this.showGit,
    required this.running,
    required this.pinnedCount,
    required this.pinnedActive,
    required this.onPinnedTap,
    required this.onDetails,
    required this.onGitDetails,
  });

  final HostProfile host;
  final SessionSummary session;
  final SessionGitStatus? gitStatus;
  final bool showGit;
  final bool running;
  final int pinnedCount;
  final bool pinnedActive;
  final VoidCallback onPinnedTap;
  final VoidCallback onDetails;
  final VoidCallback onGitDetails;

  String _shortFolder(String cwd) {
    if (cwd.isEmpty) return '~';
    final trimmed = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
    final slash = trimmed.lastIndexOf('/');
    if (slash < 0 || slash == trimmed.length - 1) return trimmed;
    return trimmed.substring(slash + 1);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final folder = _shortFolder(session.cwd);
    final gitLabel = showGit ? _gitHeaderLabel(session, gitStatus) : null;
    final contextLabel = _contextUsageShortLabel(session.runtime);
    final contextTone = _contextUsageTone(session.runtime);
    final gitDirty = gitStatus?.dirty ?? false;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDetails,
        child: Padding(
          padding: const EdgeInsets.only(
            left: 16,
            top: 0,
            right: 10,
            bottom: 6,
          ),
          child: Row(
            children: [
              _HeaderStatusDot(
                color: running ? colors.success : colors.textTertiary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${host.label} · $folder',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (session.provider != null) ...[
                const SizedBox(width: 8),
                AgentProviderBadge(
                  providerKind: session.provider,
                  compact: true,
                ),
              ],
              if (gitLabel != null && gitDirty) ...[
                const SizedBox(width: 6),
                _CompactMetaChip(
                  label: '${gitStatus?.changed ?? 0}',
                  icon: Icons.account_tree_rounded,
                  color: colors.warning,
                  onTap: onGitDetails,
                ),
              ],
              if (contextLabel != null) ...[
                const SizedBox(width: 6),
                _CompactMetaChip(
                  label: contextLabel,
                  icon: Icons.data_usage_rounded,
                  color: switch (contextTone) {
                    MeshPillTone.danger => colors.danger,
                    MeshPillTone.warning => colors.warning,
                    _ => colors.textSecondary,
                  },
                ),
              ],
              if (pinnedCount > 0) ...[
                const SizedBox(width: 6),
                _CompactMetaChip(
                  label: '$pinnedCount',
                  icon: Icons.push_pin_rounded,
                  color: pinnedActive ? colors.accent : colors.textSecondary,
                  onTap: onPinnedTap,
                ),
              ],
              const SizedBox(width: 6),
              Icon(Icons.info_outline_rounded, size: 14, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactMetaChip extends StatelessWidget {
  const _CompactMetaChip({
    required this.label,
    required this.icon,
    required this.color,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(
              color: colors.textPrimary,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) {
      return content;
    }
    return GestureDetector(onTap: onTap, child: content);
  }
}

String _formatTokenLimit(int limit) {
  if (limit >= 1_000_000) {
    return '${(limit / 1_000_000).toStringAsFixed(0)}M';
  }
  if (limit >= 1_000) {
    return '${(limit / 1_000).toStringAsFixed(0)}k';
  }
  return '$limit';
}

String? _contextUsageLabel(SessionRuntimeSummary? runtime) {
  final context = runtime?.telemetry?.contextWindow;
  if (context == null || context.tokenLimit <= 0) {
    return null;
  }
  if (context.currentTokens == null) {
    return '?/${_formatTokenLimit(context.tokenLimit)} ctx';
  }
  final usedPercent = ((context.currentTokens! / context.tokenLimit) * 100)
      .clamp(0, 100)
      .round();
  return '$usedPercent% ctx used';
}

String? _contextUsageShortLabel(SessionRuntimeSummary? runtime) {
  final context = runtime?.telemetry?.contextWindow;
  if (context == null || context.tokenLimit <= 0) {
    return null;
  }
  if (context.currentTokens == null) {
    return '?%';
  }
  final usedPercent = ((context.currentTokens! / context.tokenLimit) * 100)
      .clamp(0, 100)
      .round();
  return '$usedPercent%';
}

MeshPillTone _contextUsageTone(SessionRuntimeSummary? runtime) {
  final context = runtime?.telemetry?.contextWindow;
  if (context == null ||
      context.tokenLimit <= 0 ||
      context.currentTokens == null) {
    return MeshPillTone.neutral;
  }
  final used = context.currentTokens! / context.tokenLimit;
  if (used >= 0.9) {
    return MeshPillTone.danger;
  }
  if (used >= 0.75) {
    return MeshPillTone.warning;
  }
  return MeshPillTone.neutral;
}

class _HeaderStatusDot extends StatelessWidget {
  const _HeaderStatusDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _GitDetailsSheet extends StatelessWidget {
  const _GitDetailsSheet({
    required this.session,
    required this.status,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onShowDiff,
  });

  final SessionSummary session;
  final SessionGitStatus? status;
  final bool loading;
  final String? error;
  final VoidCallback onRefresh;
  final ValueChanged<String> onShowDiff;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final gitInfo = session.gitInfo;
    final branch = status?.branch ?? gitInfo?.branch;
    final shortSha = status?.shortSha ?? gitInfo?.shortSha;
    final originUrl = status?.originUrl ?? gitInfo?.originUrl;

    return MeshBottomSheetScaffold(
      icon: Icons.account_tree_rounded,
      title: 'Git details',
      description:
          'Review branch status, changed files, and the diffs available for this session.',
      maxWidth: 920,
      maxHeightFactor: 0.88,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: loading ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Refresh'),
              ),
            ),
            const SizedBox(height: 12),
            if (loading && status == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (status != null && !status!.isRepo)
              MeshEmptyState(
                icon: Icons.account_tree_rounded,
                title: 'No Git repo found',
                body:
                    'This session working directory is not inside a Git worktree.',
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MeshPill(
                    label: branch ?? 'detached',
                    icon: Icons.account_tree_rounded,
                    tone: MeshPillTone.accent,
                    mono: true,
                  ),
                  if (shortSha != null)
                    MeshPill(
                      label: shortSha,
                      icon: Icons.tag_rounded,
                      tone: MeshPillTone.neutral,
                      mono: true,
                    ),
                  if (status != null)
                    MeshPill(
                      label: status!.dirty
                          ? '${status!.changed} changed'
                          : 'clean',
                      icon: status!.dirty
                          ? Icons.warning_amber_rounded
                          : Icons.check_rounded,
                      tone: status!.dirty
                          ? MeshPillTone.warning
                          : MeshPillTone.success,
                      mono: true,
                    ),
                  if ((status?.ahead ?? 0) > 0)
                    MeshPill(
                      label: 'ahead ${status!.ahead}',
                      tone: MeshPillTone.info,
                      mono: true,
                    ),
                  if ((status?.behind ?? 0) > 0)
                    MeshPill(
                      label: 'behind ${status!.behind}',
                      tone: MeshPillTone.info,
                      mono: true,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              MeshCard(
                tone: MeshCardTone.muted,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(label: 'Working dir', value: session.cwd),
                    if (status?.repoRoot != null)
                      _DetailRow(label: 'Repo root', value: status!.repoRoot!),
                    if (status?.upstream != null)
                      _DetailRow(label: 'Upstream', value: status!.upstream!),
                    if (originUrl != null)
                      _DetailRow(label: 'Origin', value: originUrl),
                    if (error != null)
                      Text(
                        error!,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: colors.warning),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => onShowDiff('working'),
                    icon: const Icon(Icons.difference_rounded, size: 18),
                    label: const Text('Working diff'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onShowDiff('staged'),
                    icon: const Icon(Icons.inventory_2_rounded, size: 18),
                    label: const Text('Staged diff'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onShowDiff('remote'),
                    icon: const Icon(Icons.cloud_rounded, size: 18),
                    label: const Text('Remote diff'),
                  ),
                ],
              ),
              if (status != null && status!.files.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Changed files',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppWeights.title,
                  ),
                ),
                const SizedBox(height: 10),
                MeshCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final file in status!.files.take(40))
                        _GitFileStatusRow(file: file),
                      if (status!.files.length > 40 || status!.filesTruncated)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            status!.filesTruncated
                                ? 'More files omitted by server cap.'
                                : '${status!.files.length - 40} more files omitted.',
                            style: monoStyle(
                              color: colors.textSecondary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _GitFileStatusRow extends StatelessWidget {
  const _GitFileStatusRow({required this.file});

  final SessionGitFileStatus file;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final status = file.isUntracked
        ? '??'
        : '${file.indexStatus}${file.worktreeStatus}';
    final path = file.originalPath == null
        ? file.path
        : '${file.originalPath} -> ${file.path}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              status,
              style: monoStyle(
                color: file.isUntracked
                    ? colors.warning
                    : file.isStaged
                    ? colors.success
                    : colors.textSecondary,
                fontWeight: FontWeight.w800,
                fontSize: 11.5,
              ),
            ),
          ),
          Expanded(
            child: Text(
              path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(color: colors.textPrimary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _GitDiffSheet extends StatelessWidget {
  const _GitDiffSheet({required this.future});

  final Future<SessionGitDiff> future;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<SessionGitDiff>(
      future: future,
      builder: (context, snapshot) {
        final title = snapshot.data == null
            ? 'Git diff'
            : _gitDiffTitle(snapshot.data!);
        return MeshBottomSheetScaffold(
          icon: Icons.difference_rounded,
          title: title,
          description: 'Review the Git patch for this session.',
          maxWidth: 980,
          maxHeightFactor: 0.9,
          child: Builder(
            builder: (context) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return MeshEmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load diff',
                  body: friendlyError(snapshot.error ?? 'Unknown error'),
                );
              }
              final diff = snapshot.data!;
              if (diff.diff.trim().isEmpty) {
                return MeshEmptyState(
                  icon: Icons.check_rounded,
                  title: 'No diff',
                  body: 'Git did not report changes for this view.',
                );
              }
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (diff.truncated)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: MeshPill(
                          label: 'Truncated after ${diff.maxChars} chars',
                          icon: Icons.content_cut_rounded,
                          tone: MeshPillTone.warning,
                          mono: true,
                        ),
                      ),
                    if (diff.baseSha != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Base ${diff.baseSha}',
                          style: monoStyle(
                            color: colors.textSecondary,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    DiffView(diff: diff.diff),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

String _gitDiffTitle(SessionGitDiff diff) {
  return switch (diff.kind) {
    'staged' => 'Staged diff',
    'unstaged' => 'Unstaged diff',
    'remote' => 'Remote diff',
    _ => 'Working diff',
  };
}

class _PinnedListSheet extends StatelessWidget {
  const _PinnedListSheet({
    required this.pinsBuilder,
    required this.refresh,
    required this.onOpen,
    required this.onUnpin,
  });

  final List<PinnedSessionMessage> Function() pinsBuilder;
  final Listenable refresh;
  final ValueChanged<PinnedSessionMessage> onOpen;
  final ValueChanged<PinnedSessionMessage> onUnpin;

  @override
  Widget build(BuildContext context) {
    return MeshBottomSheetScaffold(
      icon: Icons.push_pin_rounded,
      title: 'Pinned messages',
      description:
          'Jump back to saved messages or remove them from the pinned list.',
      maxWidth: 760,
      maxHeightFactor: 0.78,
      child: ListenableBuilder(
        listenable: refresh,
        builder: (context, _) => PinnedListPanel(
          pins: pinsBuilder(),
          onOpen: onOpen,
          onUnpin: onUnpin,
        ),
      ),
    );
  }
}

class _PinnedMessageSheet extends StatelessWidget {
  const _PinnedMessageSheet({
    required this.pin,
    required this.onUnpin,
    this.onOpenFile,
  });

  final PinnedSessionMessage pin;
  final VoidCallback onUnpin;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: colors.textPrimary, height: 1.45);
    final pinnedLinkStyle = linkTextStyleForBackground(
      background: colors.surfaceMuted,
      preferred: colors.accent,
      fallbacks: [
        colors.info,
        colors.textPrimary,
        colors.textSecondary,
      ],
      baseStyle: textStyle,
    );
    return MeshBottomSheetScaffold(
      icon: Icons.push_pin_rounded,
      title: 'Pinned ${pin.roleLabel.toLowerCase()} message',
      description:
          'Keep an important message visible while you work through this session.',
      maxWidth: 920,
      maxHeightFactor: 0.84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Spacer(),
              if (pin.hasText)
                _MessageCopyButton(
                  text: pin.text,
                  tone: colors.textSecondary,
                  accent: colors.accent,
                ),
              if (pin.hasText) const SizedBox(width: 6),
              TextButton.icon(
                onPressed: onUnpin,
                icon: const Icon(Icons.push_pin_rounded, size: 17),
                label: const Text('Unpin'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: pin.roleLabel,
                icon: pin.role == 'assistant'
                    ? Icons.smart_toy_rounded
                    : Icons.person_outline_rounded,
              ),
              MeshPill(
                label: 'Pinned ${_formatPinnedTimestamp(pin.pinnedAt)}',
                icon: Icons.schedule_rounded,
              ),
              if (pin.attachmentCount > 0)
                MeshPill(
                  label:
                      '${pin.attachmentCount} attachment${pin.attachmentCount == 1 ? '' : 's'}',
                  icon: Icons.attachment_rounded,
                ),
              if (pin.textTruncated)
                const MeshPill(
                  label: 'Stored preview truncated',
                  icon: Icons.content_cut_rounded,
                  tone: MeshPillTone.warning,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: MeshCard(
              tone: MeshCardTone.muted,
              padding: const EdgeInsets.all(14),
              child: SingleChildScrollView(
                child: pin.hasText
                    ? (pin.role == 'assistant'
                          ? _MarkdownMessageBody(
                              text: pin.text,
                              textColor: colors.textPrimary,
                              linkStyle: pinnedLinkStyle,
                              onOpenFile: onOpenFile,
                            )
                          : _LinkifiedSelectableText(
                              text: pin.text,
                              style: textStyle,
                              linkStyle: pinnedLinkStyle,
                            ))
                    : Text(
                        pin.preview,
                        style: textStyle?.copyWith(color: colors.textSecondary),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatPinnedTimestamp(DateTime value) {
  if (value.millisecondsSinceEpoch <= 0) return 'earlier';
  final now = DateTime.now();
  final sameDay =
      value.year == now.year &&
      value.month == now.month &&
      value.day == now.day;
  final time = '${_twoDigits(value.hour)}:${_twoDigits(value.minute)}';
  if (sameDay) return 'today $time';
  return '${value.month}/${value.day} $time';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

class _PendingActionCard extends StatefulWidget {
  const _PendingActionCard({required this.action, required this.onRespond});

  final PendingAction action;
  final ValueChanged<PendingActionResponseDraft> onRespond;

  @override
  State<_PendingActionCard> createState() => _PendingActionCardState();
}

class _PendingActionCardState extends State<_PendingActionCard> {
  late final TextEditingController _answerController;
  final Map<String, TextEditingController> _textControllers =
      <String, TextEditingController>{};
  final Map<String, bool> _boolValues = <String, bool>{};
  final Map<String, String?> _singleValues = <String, String?>{};
  final Map<String, Set<String>> _multiValues = <String, Set<String>>{};
  bool _responding = false;

  PendingAction get action => widget.action;

  @override
  void initState() {
    super.initState();
    _answerController = TextEditingController();
    _seedActionState(widget.action);
  }

  @override
  void didUpdateWidget(covariant _PendingActionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.action.id == widget.action.id) {
      return;
    }
    _disposeFieldControllers();
    _answerController.clear();
    _seedActionState(widget.action);
  }

  @override
  void dispose() {
    _answerController.dispose();
    _disposeFieldControllers();
    super.dispose();
  }

  void _disposeFieldControllers() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    _textControllers.clear();
    _boolValues.clear();
    _singleValues.clear();
    _multiValues.clear();
  }

  void _seedActionState(PendingAction action) {
    final prompt = action.userInput;
    if (prompt != null &&
        prompt.choices.length == 1 &&
        prompt.allowFreeform == false) {
      _answerController.text = prompt.choices.first;
    }
    for (final field in action.elicitation?.fields ?? const []) {
      switch (field.type) {
        case 'boolean':
          _boolValues[field.key] = field.defaultValue == true;
          break;
        case 'number':
          _textControllers[field.key] = TextEditingController(
            text: field.defaultValue?.toString() ?? '',
          );
          break;
        case 'string[]':
          final defaults = field.defaultValue is List
              ? (field.defaultValue as List).whereType<String>().toSet()
              : <String>{};
          _multiValues[field.key] = defaults;
          break;
        case 'string':
        default:
          final controller = TextEditingController(
            text: field.defaultValue is String
                ? field.defaultValue as String
                : '',
          );
          _textControllers[field.key] = controller;
          if ((field.options ?? const []).isNotEmpty) {
            _singleValues[field.key] = controller.text.isEmpty
                ? null
                : controller.text;
          }
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mq = MediaQuery.of(context);
    final kindMeta = _kindMeta(action, colors);
    final maxHeight = mq.size.height * 0.5;
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: kindMeta.accent.withValues(alpha: 0.7),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                MeshStatusBadge(
                  label: kindMeta.kicker,
                  tone: kindMeta.tone,
                  icon: kindMeta.icon,
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      action.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (action.detail.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        action.detail,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    if (action.isUserInput) ...[
                      const SizedBox(height: 12),
                      _buildUserInputBody(context, action.userInput!),
                    ] else if (action.isElicitation) ...[
                      const SizedBox(height: 12),
                      _buildElicitationBody(context, action.elicitation!),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _buildFooterActions(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUserInputBody(
    BuildContext context,
    PendingActionUserInputRequest prompt,
  ) {
    final colors = context.colors;
    final choices = prompt.choices;
    final answer = _answerController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (choices.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: choices
                .map(
                  (choice) => ChoiceChip(
                    label: Text(choice),
                    selected: answer == choice,
                    onSelected: (_) {
                      setState(() {
                        _answerController.text = choice;
                        _answerController.selection = TextSelection.collapsed(
                          offset: choice.length,
                        );
                      });
                    },
                  ),
                )
                .toList(growable: false),
          ),
          if (prompt.allowFreeform) const SizedBox(height: 12),
        ],
        if (prompt.allowFreeform || choices.isEmpty)
          TextField(
            controller: _answerController,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: choices.isEmpty
                  ? 'Type your answer'
                  : 'Choose above or type your own answer',
              filled: true,
              fillColor: colors.surfaceMuted,
              border: OutlineInputBorder(
                borderRadius: AppShapes.input,
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: AppShapes.input,
                borderSide: BorderSide(color: colors.border),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
      ],
    );
  }

  Widget _buildElicitationBody(
    BuildContext context,
    PendingActionElicitationRequest elicitation,
  ) {
    final colors = context.colors;
    final source = elicitation.source?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (source != null && source.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: MeshPill(
              label: source,
              icon: Icons.extension_rounded,
              tone: MeshPillTone.neutral,
              mono: true,
            ),
          ),
        if (elicitation.mode == 'url' && (elicitation.url ?? '').isNotEmpty)
          GestureDetector(
            onTap: _openElicitationUrl,
            child: MeshPill(
              label: 'Open browser link',
              icon: Icons.open_in_new_rounded,
              tone: MeshPillTone.accent,
            ),
          ),
        if (elicitation.mode == 'url' && (elicitation.url ?? '').isNotEmpty)
          const SizedBox(height: 12),
        if (elicitation.fields.isEmpty)
          Text(
            'No structured fields were provided for this request.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: elicitation.fields
                .map((field) => _buildElicitationField(context, field))
                .toList(growable: false),
          ),
      ],
    );
  }

  Widget _buildElicitationField(
    BuildContext context,
    PendingActionElicitationField field,
  ) {
    final colors = context.colors;
    final label = field.required ? '${field.title} *' : field.title;
    Widget child;
    switch (field.type) {
      case 'boolean':
        final value = _boolValues[field.key] ?? false;
        child = MeshSurface(
          tone: MeshSurfaceTone.muted,
          selected: value,
          radius: AppRadii.control,
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          onTap: () => setState(() => _boolValues[field.key] = !value),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label),
                    if (field.description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        field.description!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Switch(
                value: value,
                onChanged: (next) {
                  setState(() => _boolValues[field.key] = next);
                },
              ),
            ],
          ),
        );
      case 'number':
        child = TextField(
          controller: _textControllers[field.key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: _fieldDecoration(
            colors,
            label,
            field.description,
            hintText: field.integer ? 'Integer' : 'Number',
          ),
          onChanged: (_) => setState(() {}),
        );
      case 'string[]':
        final selected = _multiValues[field.key] ?? <String>{};
        child = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (field.description != null) ...[
              const SizedBox(height: 4),
              Text(
                field.description!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: (field.options ?? const [])
                  .map(
                    (option) => FilterChip(
                      label: Text(option.label),
                      selected: selected.contains(option.value),
                      onSelected: (picked) {
                        setState(() {
                          final next = {...selected};
                          if (picked) {
                            next.add(option.value);
                          } else {
                            next.remove(option.value);
                          }
                          _multiValues[field.key] = next;
                        });
                      },
                    ),
                  )
                  .toList(growable: false),
            ),
          ],
        );
      case 'string':
      default:
        final options =
            field.options ?? const <PendingActionElicitationOption>[];
        if (options.isNotEmpty) {
          child = DropdownButtonFormField<String>(
            key: ValueKey('${field.key}:${_singleValues[field.key] ?? ''}'),
            initialValue: _singleValues[field.key],
            decoration: _fieldDecoration(colors, label, field.description),
            items: options
                .map(
                  (option) => DropdownMenuItem<String>(
                    value: option.value,
                    child: Text(option.label),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) {
              setState(() {
                _singleValues[field.key] = value;
                _textControllers[field.key]?.text = value ?? '';
              });
            },
          );
        } else {
          child = TextField(
            controller: _textControllers[field.key],
            minLines: 1,
            maxLines: field.maxLength != null && field.maxLength! > 120 ? 4 : 1,
            keyboardType: _keyboardTypeForField(field),
            decoration: _fieldDecoration(
              colors,
              label,
              field.description,
              hintText: _hintForField(field),
            ),
            onChanged: (_) => setState(() {}),
          );
        }
    }
    return Padding(padding: const EdgeInsets.only(bottom: 12), child: child);
  }

  InputDecoration _fieldDecoration(
    AppColors colors,
    String label,
    String? helper, {
    String? hintText,
  }) {
    return InputDecoration(
      labelText: label,
      helperText: helper,
      hintText: hintText,
      filled: true,
      fillColor: colors.surfaceMuted,
      border: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: colors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppShapes.input,
        borderSide: BorderSide(color: colors.border),
      ),
    );
  }

  TextInputType? _keyboardTypeForField(PendingActionElicitationField field) {
    return switch (field.format) {
      'email' => TextInputType.emailAddress,
      'uri' => TextInputType.url,
      'date' => TextInputType.datetime,
      'date-time' => TextInputType.datetime,
      _ => TextInputType.text,
    };
  }

  String? _hintForField(PendingActionElicitationField field) {
    return switch (field.format) {
      'email' => 'name@example.com',
      'uri' => 'https://example.com',
      'date' => 'YYYY-MM-DD',
      'date-time' => 'ISO date-time',
      _ => null,
    };
  }

  List<Widget> _buildFooterActions(BuildContext context) {
    if (action.isUserInput) {
      return [
        FilledButton.icon(
          onPressed: _responding ? null : _submitUserInput,
          icon: const Icon(Icons.send_rounded, size: 18),
          label: const Text('Send answer'),
        ),
      ];
    }
    if (action.isElicitation) {
      return [
        FilledButton.icon(
          onPressed: _responding ? null : _submitElicitation,
          icon: const Icon(Icons.check_rounded, size: 18),
          label: Text(
            action.elicitation?.mode == 'url' ? 'Continue' : 'Submit',
          ),
        ),
        if (action.canDecline)
          MeshDangerAction(
            onPressed: () => widget.onRespond(
              PendingActionResponseDraft.elicitation(action: 'decline'),
            ),
            icon: Icons.thumb_down_alt_rounded,
            label: 'Decline',
          ),
        OutlinedButton.icon(
          onPressed: () => widget.onRespond(
            PendingActionResponseDraft.elicitation(action: 'cancel'),
          ),
          icon: const Icon(Icons.close_rounded, size: 18),
          label: const Text('Cancel'),
        ),
      ];
    }
    return [
      if (action.canApprove)
        FilledButton.icon(
          onPressed: _responding
              ? null
              : () {
                  if (!_responding) setState(() => _responding = true);
                  widget.onRespond(
                    PendingActionResponseDraft.approval('accept'),
                  );
                },
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('Approve'),
        ),
      if (action.canApproveForSession)
        OutlinedButton.icon(
          onPressed: () => widget.onRespond(
            PendingActionResponseDraft.approval('acceptForSession'),
          ),
          icon: const Icon(Icons.all_inclusive_rounded, size: 18),
          label: const Text('Approve for session'),
        ),
      if (action.canDecline)
        MeshDangerAction(
          onPressed: _responding
              ? null
              : () {
                  if (!_responding) setState(() => _responding = true);
                  widget.onRespond(
                    PendingActionResponseDraft.approval('decline'),
                  );
                },
          icon: Icons.close_rounded,
          label: 'Decline',
        ),
    ];
  }

  void _submitUserInput() {
    final prompt = action.userInput;
    if (prompt == null) {
      return;
    }
    final answer = _answerController.text.trim();
    if (answer.isEmpty) {
      showAppSnackBar(context, 'Enter an answer first.');
      return;
    }
    final wasFreeform = !prompt.choices.contains(answer);
    widget.onRespond(
      PendingActionResponseDraft.userInput(
        answer: answer,
        wasFreeform: wasFreeform,
      ),
    );
  }

  void _submitElicitation() {
    final elicitation = action.elicitation;
    if (elicitation == null) {
      return;
    }
    final content = <String, dynamic>{};
    for (final field in elicitation.fields) {
      switch (field.type) {
        case 'boolean':
          content[field.key] = _boolValues[field.key] ?? false;
          break;
        case 'number':
          final raw = _textControllers[field.key]?.text.trim() ?? '';
          if (raw.isEmpty) {
            if (field.required) {
              showAppSnackBar(context, 'Fill in ${field.title}.');
              return;
            }
            continue;
          }
          final parsed = field.integer ? int.tryParse(raw) : num.tryParse(raw);
          if (parsed == null) {
            showAppSnackBar(
              context,
              'Enter a valid number for ${field.title}.',
            );
            return;
          }
          content[field.key] = parsed;
          break;
        case 'string[]':
          final values = (_multiValues[field.key] ?? <String>{}).toList();
          if (field.required && values.isEmpty) {
            showAppSnackBar(
              context,
              'Choose at least one value for ${field.title}.',
            );
            return;
          }
          if (values.isNotEmpty) {
            content[field.key] = values;
          }
          break;
        case 'string':
        default:
          final value = (_textControllers[field.key]?.text ?? '').trim();
          if (field.required && value.isEmpty) {
            showAppSnackBar(context, 'Fill in ${field.title}.');
            return;
          }
          if (value.isNotEmpty) {
            content[field.key] = value;
          }
          break;
      }
    }
    widget.onRespond(
      PendingActionResponseDraft.elicitation(
        action: 'accept',
        content: content.isEmpty ? null : content,
      ),
    );
  }

  Future<void> _openElicitationUrl() async {
    final raw = action.elicitation?.url;
    if (raw == null || raw.trim().isEmpty) {
      return;
    }
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) {
      showAppSnackBar(context, 'This link is invalid.');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) {
      return;
    }
    if (!ok) {
      showAppSnackBar(context, 'Unable to open that link.');
    }
  }
}

class _PendingActionKindMeta {
  const _PendingActionKindMeta({
    required this.kicker,
    required this.icon,
    required this.accent,
    required this.tone,
  });

  final String kicker;
  final IconData icon;
  final Color accent;
  final MeshStatusTone tone;
}

_PendingActionKindMeta _kindMeta(PendingAction action, AppColors colors) {
  if (action.isUserInput) {
    return _PendingActionKindMeta(
      kicker: 'INPUT NEEDED',
      icon: Icons.chat_bubble_outline_rounded,
      accent: colors.accent,
      tone: MeshStatusTone.waiting,
    );
  }
  if (action.isElicitation) {
    return _PendingActionKindMeta(
      kicker: 'FORM REQUIRED',
      icon: Icons.fact_check_rounded,
      accent: colors.info,
      tone: MeshStatusTone.queued,
    );
  }
  return _PendingActionKindMeta(
    kicker: 'APPROVAL REQUIRED',
    icon: Icons.shield_rounded,
    accent: colors.warning,
    tone: MeshStatusTone.approval,
  );
}

class _HistoryTruncationCard extends StatelessWidget {
  const _HistoryTruncationCard({
    required this.history,
    required this.loading,
    required this.onLoadOlderHistory,
    this.onDismiss,
  });

  final SessionLogHistorySummary history;
  final bool loading;
  final VoidCallback onLoadOlderHistory;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final hiddenMessages = (history.totalMessages - history.returnedMessages)
        .clamp(0, 1 << 30);
    final hiddenActivities =
        (history.totalActivities - history.returnedActivities).clamp(
          0,
          1 << 30,
        );

    final hiddenParts = <String>[];
    if (hiddenMessages > 0) {
      hiddenParts.add('$hiddenMessages older messages');
    }
    if (hiddenActivities > 0) {
      hiddenParts.add('$hiddenActivities older actions');
    }

    return Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 14, color: colors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hiddenParts.isEmpty
                  ? '${history.returnedMessages} msgs · ${history.returnedActivities} actions loaded'
                  : '${hiddenParts.join(' · ')} hidden',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontSize: 11.5,
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (loading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else
            InkWell(
              onTap: onLoadOlderHistory,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  'Load older',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ),
          if (onDismiss != null)
            InkResponse(
              radius: 18,
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: colors.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
