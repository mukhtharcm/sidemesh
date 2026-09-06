part of 'session_screen.dart';

class _OfflineTranscriptStrip extends StatelessWidget {
  const _OfflineTranscriptStrip({this.lastConnectedLabel, this.onRetry});

  final String? lastConnectedLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final text = lastConnectedLabel == null
        ? 'Offline · showing saved transcript'
        : 'Offline · showing saved transcript · $_lastConnectedText';
    return MeshSurface(
      tone: MeshSurfaceTone.warning,
      radius: AppRadii.control,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.xs,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Icon(
            Icons.wifi_off_rounded,
            size: AppSizes.compactIcon,
            color: colors.warning,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontWeight: AppWeights.emphasis,
              ),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: AppSpacing.sm),
            TextButton(
              onPressed: onRetry,
              style: AppControlStyles.foreground(colors.warning),
              child: const Text('Retry'),
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
  });

  final String value;
  final String label;
  final String? detail;
  final IconData icon;
  final _SessionActionTone tone;
}

class _SessionActionGroup {
  const _SessionActionGroup({required this.label, required this.actions});

  final String label;
  final List<_SessionActionSpec> actions;
}

class _SessionActionSheet extends StatelessWidget {
  const _SessionActionSheet({required this.session, required this.groups});

  final SessionSummary session;
  final List<_SessionActionGroup> groups;

  Widget _action(BuildContext context, _SessionActionSpec action) => ListTile(
    minTileHeight: AppSizes.control,
    leading: Icon(
      action.icon,
      size: AppSizes.icon,
      color: action.tone == _SessionActionTone.danger
          ? context.colors.danger
          : context.colors.textSecondary,
    ),
    title: Text(action.label, style: Theme.of(context).textTheme.bodyLarge),
    onTap: () => Navigator.of(context).pop(action.value),
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: colors.surfaceElevated,
      borderRadius: AppShapes.sheetTop,
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: [
              ListTile(
                title: Text(
                  'Session actions',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                trailing: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              // Primary actions stay visible; workspace and recovery tools expand in place.
              for (final group in groups.where(
                (group) =>
                    group.label != 'Open' && group.label != 'Troubleshooting',
              ))
                for (final action in group.actions) _action(context, action),
              for (final group in groups.where(
                (group) =>
                    group.label == 'Open' || group.label == 'Troubleshooting',
              ))
                ExpansionTile(
                  title: Text(
                    group.label == 'Open' ? 'Workspace tools' : group.label,
                  ),
                  children: [
                    for (final action in group.actions)
                      _action(context, action),
                  ],
                ),
            ],
          ),
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
      shadowColor: AppOverlayColors.shadow.withValues(
        alpha: AppEmphasis.borderTint,
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_downward_rounded,
                size: AppSizes.compactIcon,
                color: foreground,
              ),
              const SizedBox(width: AppSpacing.tight),
              Text(
                'Jump to latest',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: AppWeights.strong,
                ),
              ),
            ],
          ),
        ),
      ),
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
      title: 'Git details',
      maxWidth: AppSizes.readingMaxWidth,
      maxHeightFactor: 0.88,
      actions: [
        if (loading)
          const MeshDelayedActivityIndicator(active: true)
        else
          IconButton(
            tooltip: 'Refresh Git status',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
      ],
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                  error!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.warning),
                ),
              ),
            if (loading && status == null)
              const MeshLoader(label: 'Loading changes')
            else if (status != null && !status!.isRepo)
              const MeshEmptyState.compact(
                icon: Icons.account_tree_rounded,
                title: 'No Git repository',
                body: 'This folder is outside a Git repository.',
              )
            else ...[
              if (branch != null) _DetailRow(label: 'Branch', value: branch),
              if (shortSha != null)
                _DetailRow(label: 'Commit', value: shortSha),
              if (status != null)
                _DetailRow(
                  label: 'Changes',
                  value: status!.dirty
                      ? '${status!.changed} changed'
                      : 'No changes',
                ),
              if ((status?.ahead ?? 0) > 0 || (status?.behind ?? 0) > 0)
                _DetailRow(
                  label: 'Sync',
                  value: [
                    if (status!.ahead > 0) '${status!.ahead} ahead',
                    if (status!.behind > 0) '${status!.behind} behind',
                  ].join(' · '),
                ),
              _DetailRow(label: 'Folder', value: session.cwd),
              if (status?.repoRoot != null && status!.repoRoot != session.cwd)
                _DetailRow(label: 'Repository', value: status!.repoRoot!),
              if (status?.upstream != null)
                _DetailRow(label: 'Upstream', value: status!.upstream!),
              if (originUrl != null)
                _DetailRow(label: 'Origin', value: originUrl),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  TextButton.icon(
                    onPressed: () => onShowDiff('working'),
                    icon: const Icon(Icons.difference_rounded),
                    label: const Text('Working diff'),
                  ),
                  TextButton.icon(
                    onPressed: () => onShowDiff('staged'),
                    icon: const Icon(Icons.inventory_2_rounded),
                    label: const Text('Staged diff'),
                  ),
                ],
              ),
              if (status != null && status!.files.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xl),
                Text(
                  'Changed files',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppWeights.title,
                  ),
                ),
                const SizedBox(height: AppSpacing.compact),
                MeshCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final file in status!.files.take(40))
                        _GitFileStatusRow(file: file),
                      if (status!.files.length > 40 || status!.filesTruncated)
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Text(
                            status!.filesTruncated
                                ? 'More files omitted by server cap.'
                                : '${status!.files.length - 40} more files omitted.',
                            style: monoStyle(
                              color: colors.textSecondary,
                              fontSize: AppFontSizes.caption,
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.compact,
      ),
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
                fontWeight: AppWeights.body,
                fontSize: AppFontSizes.caption,
              ),
            ),
          ),
          Expanded(
            child: Text(
              path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                color: colors.textPrimary,
                fontSize: AppFontSizes.caption,
              ),
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
          maxWidth: 980,
          maxHeightFactor: 0.9,
          child: Builder(
            builder: (context) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const MeshLoader(label: 'Loading diff');
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
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.compact,
                        ),
                        child: MeshPill(
                          label: 'Truncated after ${diff.maxChars} chars',
                          icon: Icons.content_cut_rounded,
                          tone: MeshPillTone.warning,
                          mono: true,
                        ),
                      ),
                    if (diff.baseSha != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          bottom: AppSpacing.compact,
                        ),
                        child: Text(
                          'Base ${diff.baseSha}',
                          style: monoStyle(
                            color: colors.textSecondary,
                            fontSize: AppFontSizes.caption,
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
    this.onOpenHostUrl,
  });

  final PinnedSessionMessage pin;
  final VoidCallback onUnpin;
  final void Function(String path)? onOpenFile;
  final void Function(String url)? onOpenHostUrl;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: colors.textPrimary,
      height: AppLineHeights.reading,
    );
    final pinnedLinkStyle = linkTextStyleForBackground(
      background: colors.surfaceElevated,
      preferred: colors.accent,
      fallbacks: [colors.info, colors.textPrimary, colors.textSecondary],
      baseStyle: textStyle,
    );
    return MeshBottomSheetScaffold(
      icon: Icons.push_pin_rounded,
      title: 'Pinned message',
      maxWidth: AppSizes.readingMaxWidth,
      maxHeightFactor: 0.84,
      actions: [
        if (pin.hasText)
          IconButton(
            tooltip: 'Copy message',
            icon: const Icon(Icons.copy_rounded),
            onPressed: () => Clipboard.setData(ClipboardData(text: pin.text)),
          ),
        IconButton(
          tooltip: 'Unpin message',
          icon: const Icon(Icons.push_pin_outlined),
          onPressed: onUnpin,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              '${pin.roleLabel} · Pinned ${_formatPinnedTimestamp(pin.pinnedAt)}',
              if (pin.attachmentCount > 0)
                '${pin.attachmentCount} attachment${pin.attachmentCount == 1 ? '' : 's'}',
            ].join(' · '),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          if (pin.textTruncated)
            const Text('This saved preview is incomplete.'),
          const SizedBox(height: AppSpacing.md),
          Flexible(
            child: SingleChildScrollView(
              child: pin.hasText
                  ? (pin.role == 'assistant'
                        ? _MarkdownMessageBody(
                            text: pin.text,
                            textColor: colors.textPrimary,
                            linkStyle: pinnedLinkStyle,
                            onOpenFile: onOpenFile,
                            onOpenHostUrl: onOpenHostUrl,
                          )
                        : _LinkifiedSelectableText(
                            text: pin.text,
                            style: textStyle,
                            linkStyle: pinnedLinkStyle,
                            onOpenHostUrl: onOpenHostUrl,
                          ))
                  : Text(
                      pin.preview,
                      style: textStyle?.copyWith(color: colors.textSecondary),
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
      borderColor: kindMeta.accent.withValues(alpha: AppEmphasis.secondary),
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
            const SizedBox(height: AppSpacing.sm),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      action.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: AppWeights.strong,
                      ),
                    ),
                    if (action.detail.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        action.detail,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    if (action.isUserInput) ...[
                      const SizedBox(height: AppSpacing.md),
                      _buildUserInputBody(context, action.userInput!),
                    ] else if (action.isElicitation) ...[
                      const SizedBox(height: AppSpacing.md),
                      _buildElicitationBody(context, action.elicitation!),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
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
          if (prompt.allowFreeform) const SizedBox(height: AppSpacing.md),
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
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
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
          const SizedBox(height: AppSpacing.md),
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
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
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
                      const SizedBox(height: AppSpacing.xxs),
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
              ).textTheme.labelLarge?.copyWith(fontWeight: AppWeights.strong),
            ),
            if (field.description != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                field.description!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
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
          child = InputDecorator(
            decoration: _fieldDecoration(colors, label, field.description),
            child: AppSelect<String>(
              value: _singleValues[field.key],
              values: options.map((option) => option.value).toList(),
              label: (value) =>
                  options
                      .where((option) => option.value == value)
                      .firstOrNull
                      ?.label ??
                  value,
              onChanged: (value) => setState(() {
                _singleValues[field.key] = value;
                _textControllers[field.key]?.text = value;
              }),
            ),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: child,
    );
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
          icon: const Icon(Icons.send_rounded, size: AppSizes.inlineIcon),
          label: const Text('Send answer'),
        ),
      ];
    }
    if (action.isElicitation) {
      return [
        FilledButton.icon(
          onPressed: _responding ? null : _submitElicitation,
          icon: const Icon(Icons.check_rounded, size: AppSizes.inlineIcon),
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
          icon: const Icon(Icons.close_rounded, size: AppSizes.inlineIcon),
          label: const Text('Cancel'),
        ),
      ];
    }
    final providerOptions = action.approval?.providerOptions ?? const [];
    if (providerOptions.isNotEmpty) {
      return [
        for (var index = 0; index < providerOptions.length; index++)
          if (providerOptions[index].rejects)
            MeshDangerAction(
              onPressed: _responding
                  ? null
                  : () {
                      setState(() => _responding = true);
                      widget.onRespond(
                        PendingActionResponseDraft.providerOption(
                          providerOptions[index].id,
                        ),
                      );
                    },
              icon: Icons.close_rounded,
              label: providerOptions[index].label,
            )
          else if (index == 0)
            FilledButton.icon(
              onPressed: _responding
                  ? null
                  : () {
                      setState(() => _responding = true);
                      widget.onRespond(
                        PendingActionResponseDraft.providerOption(
                          providerOptions[index].id,
                        ),
                      );
                    },
              icon: const Icon(Icons.check_rounded, size: AppSizes.inlineIcon),
              label: Text(providerOptions[index].label),
            )
          else
            OutlinedButton.icon(
              onPressed: _responding
                  ? null
                  : () {
                      setState(() => _responding = true);
                      widget.onRespond(
                        PendingActionResponseDraft.providerOption(
                          providerOptions[index].id,
                        ),
                      );
                    },
              icon: const Icon(Icons.check_rounded, size: AppSizes.inlineIcon),
              label: Text(providerOptions[index].label),
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
          icon: const Icon(Icons.check_rounded, size: AppSizes.inlineIcon),
          label: const Text('Approve'),
        ),
      if (action.canApproveForSession)
        OutlinedButton.icon(
          onPressed: () => widget.onRespond(
            PendingActionResponseDraft.approval('acceptForSession'),
          ),
          icon: const Icon(
            Icons.all_inclusive_rounded,
            size: AppSizes.inlineIcon,
          ),
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
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            Icons.history_rounded,
            size: AppSizes.smallIcon,
            color: colors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              hiddenParts.isEmpty
                  ? '${history.returnedMessages} msgs · ${history.returnedActivities} actions loaded'
                  : '${hiddenParts.join(' · ')} hidden',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontSize: AppFontSizes.caption,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (loading)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: AppStrokes.focus),
            )
          else
            InkWell(
              onTap: onLoadOlderHistory,
              borderRadius: BorderRadius.circular(AppRadii.hover),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: Text(
                  'Load older',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.accent,
                    fontWeight: AppWeights.title,
                    fontSize: AppFontSizes.caption,
                  ),
                ),
              ),
            ),
          if (onDismiss != null)
            InkResponse(
              radius: AppSizes.touchFeedbackRadius,
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.tight),
                child: Icon(
                  Icons.close_rounded,
                  size: AppSizes.smallIcon,
                  color: colors.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
