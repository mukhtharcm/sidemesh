part of 'session_screen.dart';

class _CachedTranscriptStrip extends StatelessWidget {
  const _CachedTranscriptStrip({required this.refreshing});

  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.warning.withValues(alpha: 0.26)),
      ),
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
            Icon(Icons.history_rounded, size: 14, color: colors.warning),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              refreshing
                  ? 'Cached transcript · refreshing host'
                  : 'Cached transcript · host not fresh yet',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                color: colors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.host,
    required this.session,
    required this.gitStatus,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: MeshCard(
        padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
        accentStrip: running ? colors.success : colors.accent,
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
                  if (_gitHeaderLabel(session, gitStatus) != null ||
                      pinnedCount > 0) ...[
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (_gitHeaderLabel(session, gitStatus) != null)
                          _GitSummaryPill(
                            label: _gitHeaderLabel(session, gitStatus)!,
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
              icon: Icon(Icons.tune_rounded, size: 18, color: colors.accent),
              tooltip: 'Session details',
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
    return GestureDetector(
      onTap: onTap,
      child: MeshPill(
        label: label,
        icon: Icons.account_tree_outlined,
        tone: dirty ? MeshPillTone.warning : MeshPillTone.neutral,
        mono: true,
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
    return GestureDetector(
      onTap: onTap,
      child: MeshPill(
        label: '$count pinned',
        icon: Icons.push_pin_rounded,
        tone: active ? MeshPillTone.accent : MeshPillTone.neutral,
        mono: true,
      ),
    );
  }
}

/// Compact single-line header used on mobile. Everything that isn't
/// immediately useful at a glance lives behind the tune button (session
/// details sheet) so the chat surface gets maximum vertical real estate.
class _JumpToLatestPill extends StatelessWidget {
  const _JumpToLatestPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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
                color: colors.userBubbleOn,
              ),
              const SizedBox(width: 6),
              Text(
                'Jump to latest',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colors.userBubbleOn,
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

class _SessionAppBarSubtitle extends StatelessWidget {
  const _SessionAppBarSubtitle({
    required this.host,
    required this.session,
    required this.gitStatus,
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
    final gitLabel = _gitHeaderLabel(session, gitStatus);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onDetails,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
          child: Row(
            children: [
              Icon(Icons.dns_rounded, size: 12, color: colors.textTertiary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '  ·  ',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: colors.textTertiary),
              ),
              Flexible(
                child: Text(
                  folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (gitLabel != null) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: onGitDetails,
                  child: MeshPill(
                    label: gitLabel,
                    icon: Icons.account_tree_outlined,
                    tone: (gitStatus?.dirty ?? false)
                        ? MeshPillTone.warning
                        : MeshPillTone.neutral,
                    mono: true,
                  ),
                ),
              ],
              if (pinnedCount > 0) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onPinnedTap,
                  child: MeshPill(
                    label: '$pinnedCount',
                    icon: Icons.push_pin_rounded,
                    tone: pinnedActive
                        ? MeshPillTone.accent
                        : MeshPillTone.neutral,
                    mono: true,
                  ),
                ),
              ],
              const SizedBox(width: 6),
              Icon(Icons.tune_rounded, size: 14, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
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

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Git details',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: loading ? null : onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: 'Refresh git status',
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (loading && status == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (status != null && !status!.isRepo)
              MeshEmptyState(
                icon: Icons.account_tree_outlined,
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
                    icon: Icons.account_tree_outlined,
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
                    icon: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: const Text('Staged diff'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => onShowDiff('remote'),
                    icon: const Icon(Icons.cloud_outlined, size: 18),
                    label: const Text('Remote diff'),
                  ),
                ],
              ),
              if (status != null && status!.files.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Changed files',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
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
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.86,
      child: FutureBuilder<SessionGitDiff>(
        future: future,
        builder: (context, snapshot) {
          final title = snapshot.data == null
              ? 'Git diff'
              : _gitDiffTitle(snapshot.data!);
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Builder(
                    builder: (context) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return MeshEmptyState(
                          icon: Icons.error_outline_rounded,
                          title: 'Could not load diff',
                          body: friendlyError(
                            snapshot.error ?? 'Unknown error',
                          ),
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
                                  label:
                                      'Truncated after ${diff.maxChars} chars',
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
                ),
              ],
            ),
          );
        },
      ),
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
    required this.onClose,
  });

  final List<PinnedSessionMessage> Function() pinsBuilder;
  final Listenable refresh;
  final ValueChanged<PinnedSessionMessage> onOpen;
  final ValueChanged<PinnedSessionMessage> onUnpin;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        color: colors.surfaceElevated,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.push_pin_rounded,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Pinned messages',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.border),
            Expanded(
              child: ListenableBuilder(
                listenable: refresh,
                builder: (context, _) => PinnedListPanel(
                  pins: pinsBuilder(),
                  onOpen: onOpen,
                  onUnpin: onUnpin,
                ),
              ),
            ),
          ],
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
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.push_pin_rounded, size: 20, color: colors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Pinned ${pin.roleLabel.toLowerCase()} message',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (pin.hasText)
                  _MessageCopyButton(
                    text: pin.text,
                    tone: colors.textSecondary,
                    accent: colors.accent,
                  ),
                const SizedBox(width: 6),
                TextButton.icon(
                  onPressed: onUnpin,
                  icon: const Icon(Icons.push_pin_outlined, size: 17),
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
                      ? Icons.smart_toy_outlined
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
                                onOpenFile: onOpenFile,
                              )
                            : _LinkifiedSelectableText(
                                text: pin.text,
                                style: textStyle,
                                linkColor: colors.accent,
                              ))
                      : Text(
                          pin.preview,
                          style: textStyle?.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
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

class _PendingActionCard extends StatelessWidget {
  const _PendingActionCard({required this.action, required this.onRespond});

  final PendingAction action;
  final ValueChanged<String> onRespond;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mq = MediaQuery.of(context);
    // Cap the card at ~38% of available height so a verbose approval
    // payload (e.g. a long shell command or write-file preview) can never
    // push the composer off the screen on mobile. Internal scroll keeps
    // every button reachable.
    final maxHeight = mq.size.height * 0.38;
    return MeshCard(
      tone: MeshCardTone.surface,
      borderColor: colors.warning.withValues(alpha: 0.5),
      accentStrip: colors.warning,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.shield_rounded, color: colors.warning, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Approval required',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.warning,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
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
                    const SizedBox(height: 8),
                    Text(
                      action.detail,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (action.canApprove)
                  FilledButton.icon(
                    onPressed: () => onRespond('accept'),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Approve'),
                  ),
                if (action.canApproveForSession)
                  OutlinedButton.icon(
                    onPressed: () => onRespond('acceptForSession'),
                    icon: const Icon(Icons.all_inclusive_rounded, size: 18),
                    label: const Text('Approve for session'),
                  ),
                if (action.canDecline)
                  OutlinedButton.icon(
                    onPressed: () => onRespond('decline'),
                    icon: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: colors.danger,
                    ),
                    label: Text(
                      'Decline',
                      style: TextStyle(color: colors.danger),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                        color: colors.danger.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
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
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
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
