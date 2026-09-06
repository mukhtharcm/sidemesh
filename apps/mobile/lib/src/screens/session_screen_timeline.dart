part of 'session_screen.dart';

class _LiveAssistantMessageState {
  const _LiveAssistantMessageState({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.seq,
    required this.phase,
    this.live = true,
    this.reasoning = '',
  });

  final String id;
  final String text;
  final String reasoning;
  final DateTime createdAt;
  final int seq;
  final String? phase;
  final bool live;

  _LiveAssistantMessageState copyWith({
    String? text,
    String? reasoning,
    String? phase,
    bool? live,
  }) {
    return _LiveAssistantMessageState(
      id: id,
      text: text ?? this.text,
      reasoning: reasoning ?? this.reasoning,
      createdAt: createdAt,
      seq: seq,
      phase: phase ?? this.phase,
      live: live ?? this.live,
    );
  }

  SessionMessage toMessage() {
    final visibleReasoning = reasoning.trimRight();
    final visibleText = text.trimRight();
    return SessionMessage(
      id: id,
      role: 'assistant',
      text: text,
      content: <ContentBlock>[
        if (visibleReasoning.trim().isNotEmpty) ThinkingBlock(visibleReasoning),
        if (visibleText.trim().isNotEmpty) TextBlock(visibleText),
      ],
      attachments: const <SessionMessageAttachment>[],
      createdAt: createdAt,
      seq: seq,
      phase: phase,
    );
  }
}

enum _TimelineEntryKind {
  message,
  activity,
  providerWarning,
  planUpdated,
  liveAssistant,
}

enum _TimelineLiveEventKind { providerWarning, planUpdated }

class _TimelineLiveEventRecord {
  const _TimelineLiveEventRecord({
    required this.kind,
    required this.event,
    required this.createdAt,
    required this.seq,
    required this.keyId,
    this.semanticKey,
  });

  final _TimelineLiveEventKind kind;
  final LiveEvent event;
  final DateTime createdAt;
  final int seq;
  final String keyId;
  final String? semanticKey;
}

class _TimelineEntry {
  const _TimelineEntry._({
    required this.kind,
    required this.createdAt,
    required this.seq,
    required this.keyId,
    this.message,
    this.activity,
    this.runtimeEvent,
    this.repeatCount = 1,
  });

  factory _TimelineEntry.message(SessionMessage message) => _TimelineEntry._(
    kind: _TimelineEntryKind.message,
    createdAt: message.createdAt,
    seq: message.seq,
    keyId: 'msg:${message.id}',
    message: message,
  );

  factory _TimelineEntry.activity(SessionActivity activity) => _TimelineEntry._(
    kind: _TimelineEntryKind.activity,
    createdAt: activity.createdAt,
    seq: activity.seq,
    keyId: 'act:${activity.id}',
    activity: activity,
  );

  factory _TimelineEntry.runtimeEvent(_TimelineLiveEventRecord event) =>
      _TimelineEntry._(
        kind: switch (event.kind) {
          _TimelineLiveEventKind.providerWarning =>
            _TimelineEntryKind.providerWarning,
          _TimelineLiveEventKind.planUpdated => _TimelineEntryKind.planUpdated,
        },
        createdAt: event.createdAt,
        seq: event.seq,
        keyId: event.keyId,
        runtimeEvent: event,
      );

  factory _TimelineEntry.liveAssistant(_LiveAssistantMessageState message) =>
      _TimelineEntry._(
        kind: _TimelineEntryKind.liveAssistant,
        createdAt: message.createdAt,
        seq: message.seq,
        keyId: 'msg:${message.id}',
      );

  final _TimelineEntryKind kind;
  final DateTime createdAt;
  final int seq;
  final String keyId;
  final SessionMessage? message;
  final SessionActivity? activity;
  final _TimelineLiveEventRecord? runtimeEvent;
  final int repeatCount;
}

class _LiveAssistantBubble extends StatelessWidget {
  const _LiveAssistantBubble({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.message,
    this.onOpenFile,
    this.onOpenHostUrl,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final ValueListenable<_LiveAssistantMessageState?> message;
  final void Function(String path)? onOpenFile;
  final void Function(String url)? onOpenHostUrl;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_LiveAssistantMessageState?>(
      valueListenable: message,
      builder: (context, liveMessage, _) {
        if (liveMessage == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: _MessageBubble(
            host: host,
            api: api,
            sessionId: sessionId,
            message: liveMessage.toMessage(),
            live: liveMessage.live,
            onOpenFile: onOpenFile,
            onOpenHostUrl: onOpenHostUrl,
          ),
        );
      },
    );
  }
}

class _ReasoningBlock extends StatefulWidget {
  const _ReasoningBlock({
    required this.reasoning,
    this.live = false,
    this.collapsedByDefault = false,
    this.onOpenFile,
    this.onOpenHostUrl,
  });

  final String reasoning;

  /// Whether the assistant turn is still streaming.
  final bool live;

  /// True when the message already has answer text, so reasoning should shrink
  /// back to a disclosure row by default.
  final bool collapsedByDefault;
  final void Function(String path)? onOpenFile;
  final void Function(String url)? onOpenHostUrl;

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  late bool _expanded = !widget.collapsedByDefault;
  bool _userOverrode = false;

  @override
  void didUpdateWidget(covariant _ReasoningBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_userOverrode) {
      return;
    }
    if (!oldWidget.collapsedByDefault &&
        widget.collapsedByDefault &&
        _expanded) {
      setState(() => _expanded = false);
      return;
    }
    if (oldWidget.collapsedByDefault &&
        !widget.collapsedByDefault &&
        !_expanded) {
      setState(() => _expanded = true);
    }
  }

  void _toggle() {
    setState(() {
      _userOverrode = true;
      _expanded = !_expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = widget.live
        ? (_expanded ? 'Working' : 'Working...')
        : 'Working notes';
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: _toggle,
            borderRadius: AppShapes.action,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                0,
                AppSpacing.tight,
                0,
                AppSpacing.tight,
              ),
              child: Row(
                children: [
                  if (widget.live)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.tight),
                      child: LivePulse(color: colors.textSecondary),
                    )
                  else ...[
                    Icon(
                      Icons.psychology_outlined,
                      size: AppSizes.compactIcon,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: AppSpacing.tight),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: AppWeights.title,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: AppSizes.compactIcon,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.xxs,
                0,
                AppSpacing.compact,
              ),
              child: _ReasoningTextBody(
                text: widget.reasoning.trimRight(),
                textColor: colors.textPrimary,
                onOpenHostUrl: widget.onOpenHostUrl,
              ),
            ),
        ],
      ),
    );
  }
}

class _ComposerStatusStrip extends StatelessWidget {
  const _ComposerStatusStrip({required this.thinking});

  final ValueListenable<bool> thinking;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: thinking,
      builder: (context, show, _) {
        if (!show) {
          return const SizedBox.shrink();
        }
        final colors = context.colors;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.compact,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: AppShapes.input,
              border: Border.all(color: colors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.compact,
              ),
              child: Row(
                children: [
                  const LivePulse(),
                  const SizedBox(width: AppSpacing.compact),
                  Text(
                    'Working',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.compact),
                  Expanded(
                    child: Text(
                      'Waiting for assistant output…',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProviderWarningRow extends StatelessWidget {
  const _ProviderWarningRow({required this.event, this.repeatCount = 1});
  final LiveEvent event;
  final int repeatCount;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final level = (event.level ?? 'warning').toLowerCase();
    final icon = switch (level) {
      'error' => Icons.error_outline_rounded,
      'info' => Icons.info_outline_rounded,
      _ => Icons.warning_amber_rounded,
    };
    final accent = switch (level) {
      'error' => colors.danger,
      'info' => colors.textSecondary,
      _ => colors.warning,
    };
    final details = [
      event.source,
      event.code,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' · ');
    if (level == 'info') {
      return ExpansionTile(
        title: Text(
          repeatCount > 1
              ? 'Provider notice · $repeatCount occurrences'
              : 'Provider notice',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: SelectableText(
              [
                event.message ?? '',
                details,
              ].where((text) => text.isNotEmpty).join('\n'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: AppSizes.compactIcon, color: accent),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  event.message ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (details.isNotEmpty || repeatCount > 1)
            ExpansionTile(
              title: Text(
                repeatCount > 1
                    ? 'Notice details · $repeatCount occurrences'
                    : 'Notice details',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    details,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _PlanUpdateCard extends StatefulWidget {
  const _PlanUpdateCard({required this.event});

  final LiveEvent event;

  @override
  State<_PlanUpdateCard> createState() => _PlanUpdateCardState();
}

class _PlanUpdateCardState extends State<_PlanUpdateCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final event = widget.event;
    final steps = event.plan ?? const <LiveEventPlanStep>[];
    final completedCount = steps
        .where((step) => step.status == 'completed')
        .length;
    final explanation = (event.explanation ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.xs,
        right: AppSpacing.xs,
        bottom: AppSpacing.compact,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSizes.readingMaxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: AppShapes.input,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: AppSpacing.sm,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: colors.surfaceMuted.withValues(
                            alpha: AppEmphasis.secondary,
                          ),
                          borderRadius: AppShapes.iconWell,
                          border: Border.all(
                            color: colors.border.withValues(
                              alpha: AppEmphasis.disabled,
                            ),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.route_rounded,
                          size: AppSizes.compactIcon,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.compact),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Plan update',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(
                                    color: colors.textPrimary,
                                    fontWeight: AppWeights.emphasis,
                                  ),
                            ),
                            if (explanation.isNotEmpty) ...[
                              const SizedBox(height: AppSpacing.xxs),
                              Text(
                                explanation,
                                maxLines: _expanded ? 3 : 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: colors.textSecondary,
                                      fontWeight: AppWeights.body,
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      MeshStatusBadge(
                        label: '$completedCount/${steps.length}',
                        tone: MeshStatusTone.neutral,
                        icon: Icons.checklist_rounded,
                        compact: true,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: AppSizes.inlineIcon,
                        color: colors.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: AppMotion.quick,
              curve: AppMotion.standard,
              alignment: Alignment.topLeft,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.only(
                        left: AppSizes.menuItem,
                        top: AppSpacing.tight,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (
                            var index = 0;
                            index < steps.length;
                            index += 1
                          ) ...[
                            if (index > 0)
                              const SizedBox(height: AppSpacing.sm),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _planStepIcon(steps[index].status),
                                  size: AppSizes.inlineIcon,
                                  color: _planStepColor(
                                    colors,
                                    steps[index].status,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.compact),
                                Expanded(
                                  child: Text(
                                    steps[index].step,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: colors.textPrimary,
                                          fontWeight: AppWeights.title,
                                          height: AppLineHeights.caption,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                MeshStatusBadge(
                                  label: _planStepLabel(steps[index].status),
                                  tone: _planStepTone(steps[index].status),
                                  icon: _planStepIcon(steps[index].status),
                                  compact: true,
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  IconData _planStepIcon(String status) => switch (status) {
    'completed' => Icons.check_circle_rounded,
    'in_progress' => Icons.timelapse_rounded,
    _ => Icons.radio_button_unchecked_rounded,
  };

  Color _planStepColor(AppColors colors, String status) => switch (status) {
    'completed' => colors.success,
    'in_progress' => colors.accent,
    _ => colors.textTertiary,
  };

  MeshStatusTone _planStepTone(String status) => switch (status) {
    'completed' => MeshStatusTone.success,
    'in_progress' => MeshStatusTone.running,
    _ => MeshStatusTone.neutral,
  };

  String _planStepLabel(String status) => switch (status) {
    'completed' => 'Completed',
    'in_progress' => 'In progress',
    _ => 'Pending',
  };
}

class _RuntimeSignalStrip extends StatelessWidget {
  const _RuntimeSignalStrip({
    required this.threadStatus,
    required this.queueUpdated,
    required this.autoRetryUpdated,
  });

  final LiveEvent? threadStatus;
  final LiveEvent? queueUpdated;
  final LiveEvent? autoRetryUpdated;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pills = <Widget>[];
    final details = <String>[];

    final thread = threadStatus;
    if (_shouldShowThreadStatusEvent(thread)) {
      pills.add(
        MeshStatusBadge(
          label: _threadStatusLabel(thread!),
          tone: _threadStatusTone(thread.status),
          icon: _threadStatusIcon(thread.status),
          compact: true,
        ),
      );
      final message = (thread.message ?? '').trim();
      if (message.isNotEmpty) {
        details.add(message);
      } else if ((thread.pendingActionKind ?? '').isNotEmpty) {
        details.add(
          'Pending ${thread.pendingActionKind!.replaceAll('_', ' ')} action.',
        );
      }
    }

    final queue = queueUpdated;
    if (_hasQueueData(queue)) {
      pills.add(
        MeshPill(
          label:
              'Queue · ${queue!.steeringCount ?? 0} steering · ${queue.followUpCount ?? 0} follow-up',
          tone: MeshPillTone.info,
          icon: Icons.queue_rounded,
        ),
      );
      final queuePreview = _queuePreview(queue);
      if (queuePreview.isNotEmpty) {
        details.add(queuePreview);
      }
    }

    final retry = autoRetryUpdated;
    if (retry != null) {
      pills.add(
        MeshPill(
          label: _retryLabel(retry),
          tone: _retryTone(retry),
          icon: _retryIcon(retry),
        ),
      );
      final retryDetail =
          (retry.phase == 'started' ? retry.errorMessage : retry.finalError) ??
          '';
      if (retryDetail.trim().isNotEmpty) {
        details.add(retryDetail.trim());
      }
    }

    if (pills.isEmpty) {
      return const SizedBox.shrink();
    }

    return MeshSurface(
      radius: AppRadii.control,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.compact,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: pills),
          if (details.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              details.join(' • '),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontWeight: AppWeights.title,
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _hasQueueData(LiveEvent? event) {
    if (event == null) {
      return false;
    }
    return (event.steeringCount ?? 0) > 0 ||
        (event.followUpCount ?? 0) > 0 ||
        (event.steeringPreview?.isNotEmpty ?? false) ||
        (event.followUpPreview?.isNotEmpty ?? false);
  }

  String _threadStatusLabel(LiveEvent event) {
    final status = event.status ?? 'unknown';
    if (status == 'waiting_for_approval' &&
        (event.pendingActionKind?.isNotEmpty ?? false)) {
      return 'Waiting for ${event.pendingActionKind!.replaceAll('_', ' ')}';
    }
    return switch (status) {
      'idle' => 'Idle',
      'running' => 'Running',
      'waiting_for_input' => 'Waiting for input',
      'waiting_for_approval' => 'Waiting for approval',
      'errored' => 'Errored',
      'closed' => 'Closed',
      _ => 'Unknown status',
    };
  }

  MeshStatusTone _threadStatusTone(String? status) => switch (status) {
    'waiting_for_input' => MeshStatusTone.waiting,
    'waiting_for_approval' => MeshStatusTone.approval,
    'errored' => MeshStatusTone.danger,
    'running' => MeshStatusTone.running,
    _ => MeshStatusTone.neutral,
  };

  IconData _threadStatusIcon(String? status) => switch (status) {
    'waiting_for_input' => Icons.keyboard_rounded,
    'waiting_for_approval' => Icons.gpp_maybe_rounded,
    'errored' => Icons.error_outline_rounded,
    'closed' => Icons.lock_outline_rounded,
    'running' => Icons.play_circle_outline_rounded,
    _ => Icons.info_outline_rounded,
  };

  String _queuePreview(LiveEvent event) {
    final parts = <String>[];
    final steering = event.steeringPreview;
    if (steering != null && steering.isNotEmpty) {
      parts.add('Steering: ${steering.join(', ')}');
    }
    final followUp = event.followUpPreview;
    if (followUp != null && followUp.isNotEmpty) {
      parts.add('Follow-up: ${followUp.join(', ')}');
    }
    return parts.join(' • ');
  }

  String _retryLabel(LiveEvent event) {
    if (event.phase == 'started') {
      final maxAttempts = event.maxAttempts;
      final delayMs = event.delayMs;
      final delayLabel = delayMs == null ? 'soon' : _formatDelay(delayMs);
      return maxAttempts == null
          ? 'Retry ${event.attempt ?? '?'} in $delayLabel'
          : 'Retry ${event.attempt ?? '?'} / $maxAttempts in $delayLabel';
    }
    if (event.success == true) {
      return 'Retry recovered on attempt ${event.attempt ?? '?'}';
    }
    return 'Retry failed on attempt ${event.attempt ?? '?'}';
  }

  MeshPillTone _retryTone(LiveEvent event) {
    if (event.phase == 'started') {
      return MeshPillTone.warning;
    }
    return event.success == true ? MeshPillTone.success : MeshPillTone.danger;
  }

  IconData _retryIcon(LiveEvent event) {
    if (event.phase == 'started') {
      return Icons.schedule_rounded;
    }
    return event.success == true
        ? Icons.check_circle_outline_rounded
        : Icons.error_outline_rounded;
  }

  String _formatDelay(int delayMs) {
    final seconds = delayMs / 1000;
    final whole = delayMs % 1000 == 0;
    return whole
        ? '${seconds.toStringAsFixed(0)}s'
        : '${seconds.toStringAsFixed(1)}s';
  }
}

bool _shouldShowThreadStatusEvent(LiveEvent? event) {
  if (event == null) {
    return false;
  }
  final status = (event.status ?? '').trim();
  if (status.isEmpty || status == 'closed') {
    return false;
  }
  return status != 'running' ||
      (event.message?.isNotEmpty ?? false) ||
      (event.pendingActionKind?.isNotEmpty ?? false);
}

class _PendingSendStrip extends StatelessWidget {
  const _PendingSendStrip({
    required this.host,
    required this.pending,
    required this.retrying,
    required this.onRetryNow,
    required this.onEditCopy,
    required this.onDiscard,
  });

  final HostProfile host;
  final List<PendingSessionSend> pending;
  final bool retrying;
  final VoidCallback onRetryNow;
  final ValueChanged<PendingSessionSend> onEditCopy;
  final ValueChanged<PendingSessionSend> onDiscard;

  @override
  Widget build(BuildContext context) {
    if (pending.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = context.colors;
    final analyses = pending
        .map(
          (send) => analyzePendingSend(
            send,
            hosts: [host],
            retrying: retrying && send.key == pending.first.key,
          ),
        )
        .toList(growable: false);
    final count = analyses.length;
    final blockedCount = analyses
        .where((analysis) => analysis.needsAttention)
        .length;
    final primary = analyses.firstWhere(
      (analysis) => analysis.needsAttention,
      orElse: () => analyses.first,
    );
    final retryable = analyses
        .where((analysis) => analysis.canRetryNow)
        .toList(growable: false);
    final nextAttempt = (retryable.isEmpty ? analyses : retryable)
        .map((analysis) => analysis.send.nextAttemptAt)
        .reduce((left, right) => left.isBefore(right) ? left : right);
    final lastError = primary.send.lastError;
    final title = blockedCount > 0
        ? (blockedCount == 1
              ? '1 message needs attention'
              : '$blockedCount messages need attention')
        : (count == 1
              ? '1 message waiting to retry'
              : '$count messages waiting to retry');
    final detail = retrying
        ? 'Retrying now...'
        : blockedCount > 0
        ? pendingSendRecoveryMessage(primary)
        : '${_formatRetryDelay(nextAttempt)}${lastError == null ? '' : ' - $lastError'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.compact,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: AppShapes.input,
          border: Border.all(color: colors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.compact,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.cloud_sync_rounded,
                    color: colors.accent,
                    size: AppSizes.icon,
                  ),
                  const SizedBox(width: AppSpacing.compact),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: AppWeights.title,
                              ),
                        ),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  MeshPill(
                    label: pendingSendStateLabel(primary.state),
                    tone: _pendingSendStateTone(primary.state),
                    mono: true,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.compact),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: retrying ? null : onRetryNow,
                    child: const Text('Retry now'),
                  ),
                  if (count == 1) ...[
                    TextButton(
                      onPressed: () => onEditCopy(primary.send),
                      child: const Text('Edit copy'),
                    ),
                    TextButton(
                      onPressed: () => onDiscard(primary.send),
                      child: const Text('Discard'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatRetryDelay(DateTime nextAttempt) {
    final remaining = nextAttempt.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      return 'Retrying soon';
    }
    if (remaining.inMinutes >= 1) {
      return 'Next retry in ${remaining.inMinutes}m';
    }
    return 'Next retry in ${remaining.inSeconds}s';
  }
}

MeshPillTone _pendingSendStateTone(PendingSendDisplayState state) {
  return switch (state) {
    PendingSendDisplayState.queued => MeshPillTone.info,
    PendingSendDisplayState.retrying => MeshPillTone.accent,
    PendingSendDisplayState.blocked => MeshPillTone.warning,
  };
}

class _CommandTitleParts {
  const _CommandTitleParts({required this.verb, required this.command});

  final String verb;
  final String command;

  String get plainText => '$verb $command';
}

class _MessageBubble extends StatefulWidget {
  const _MessageBubble({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.message,
    this.live = false,
    this.pinned = false,
    this.onTogglePin,
    this.onOpenFile,
    this.onOpenHostUrl,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final SessionMessage message;
  final bool live;
  final bool pinned;
  final VoidCallback? onTogglePin;
  final void Function(String path)? onOpenFile;
  final void Function(String url)? onOpenHostUrl;

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    final api = widget.api;
    final sessionId = widget.sessionId;
    final message = widget.message;
    final live = widget.live;
    final pinned = widget.pinned;
    final onTogglePin = widget.onTogglePin;
    final onOpenFile = widget.onOpenFile;
    final onOpenHostUrl = widget.onOpenHostUrl;
    final touch = !{
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }.contains(Theme.of(context).platform);
    final showActions = touch || _hovered || _focused;
    final colors = context.colors;
    final isUser = message.role == 'user';
    final isAssistant = message.role == 'assistant';
    final hasText = message.text.trim().isNotEmpty;
    final hasTextBlocks = message.content.any(
      (b) => b is TextBlock && b.text.trim().isNotEmpty,
    );
    final hasAnswer = hasTextBlocks || hasText;
    final canPin = onTogglePin != null && message.hasVisibleContent;

    final bubbleColor = switch (message.role) {
      'user' => colors.userBubble,
      'assistant' => colors.canvas,
      _ => colors.surfaceMuted,
    };
    final textColor = messageBodyColor(colors, userBubble: isUser);
    final metaColor = messageMetaColor(colors, userBubble: isUser);
    final assistantMetaColor = messageMetaColor(colors, userBubble: false);
    final selectionForeground = readableTextOn(
      colors,
      background: bubbleColor,
      preferred: textColor,
    );
    final bubbleSelectionTheme = TextSelectionThemeData(
      cursorColor: selectionForeground,
      selectionColor: selectionFillForBackground(
        colors,
        background: bubbleColor,
        foreground: selectionForeground,
      ),
      selectionHandleColor: selectionForeground,
    );
    final bodyStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: textColor,
      height: AppLineHeights.reading,
    );
    final linkStyle = messageLinkStyle(
      colors,
      userBubble: isUser,
      baseStyle: bodyStyle,
    );
    final assistantLinkStyle = messageLinkStyle(
      colors,
      userBubble: false,
      baseStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: colors.textPrimary,
        height: AppLineHeights.code,
      ),
    );
    final messagePadding = isAssistant
        ? const EdgeInsets.symmetric(vertical: AppSpacing.sm)
        : const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.md,
          );
    final bubbleBorderColor = isAssistant
        ? live
              ? colors.accent.withValues(alpha: AppEmphasis.muted)
              : colors.assistantBubbleBorder
        : live
        ? colors.accent
        : colors.accent.withValues(alpha: AppEmphasis.borderTint);
    final phaseLabel = live
        ? 'Writing'
        : message.phase == 'commentary'
        ? 'Progress'
        : null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        onFocusChange: (value) => setState(() => _focused = value),
        child: Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: isAssistant ? AppSpacing.md : AppSpacing.compact,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: isAssistant ? AppSizes.readingMaxWidth : 560,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(
                    isAssistant ? AppRadii.surface : AppRadii.sheet,
                  ),
                  border: isAssistant
                      ? null
                      : Border.all(color: bubbleBorderColor),
                ),
                child: TextSelectionTheme(
                  data: bubbleSelectionTheme,
                  child: Padding(
                    padding: messagePadding,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (phaseLabel != null && hasAnswer)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.tight,
                            ),
                            child: Row(
                              children: [
                                if (live) ...[
                                  const LivePulse(),
                                  const SizedBox(width: AppSpacing.tight),
                                ],
                                Text(
                                  phaseLabel,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: isAssistant
                                            ? assistantMetaColor
                                            : metaColor,
                                        fontWeight: AppWeights.title,
                                        letterSpacing: AppLetterSpacing.caps,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        for (final block in message.content)
                          if (block is ThinkingBlock)
                            Padding(
                              padding: EdgeInsets.only(
                                bottom: hasAnswer ? AppSpacing.compact : 0,
                              ),
                              child: _ReasoningBlock(
                                reasoning: block.thinking,
                                live: live,
                                collapsedByDefault: hasAnswer,
                                onOpenFile: onOpenFile,
                                onOpenHostUrl: onOpenHostUrl,
                              ),
                            )
                          else if (block is TextBlock)
                            if (isAssistant)
                              _MarkdownMessageBody(
                                text: block.text,
                                textColor: textColor,
                                linkStyle: assistantLinkStyle,
                                onOpenFile: onOpenFile,
                                onOpenHostUrl: onOpenHostUrl,
                                host: host,
                                api: api,
                                sessionId: sessionId,
                              )
                            else
                              _LinkifiedSelectableText(
                                text: block.text,
                                style: bodyStyle,
                                linkStyle: linkStyle,
                                onOpenHostUrl: onOpenHostUrl,
                              ),
                        if (message.attachments.isNotEmpty) ...[
                          _MessageAttachmentsSection(
                            host: host,
                            api: api,
                            sessionId: sessionId,
                            attachments: message.attachments,
                          ),
                          if (!hasTextBlocks && hasText)
                            const SizedBox(height: AppSpacing.compact),
                        ],
                        if (!hasTextBlocks && hasText)
                          if (isAssistant)
                            _MarkdownMessageBody(
                              text: message.text,
                              textColor: textColor,
                              linkStyle: assistantLinkStyle,
                              onOpenFile: onOpenFile,
                              onOpenHostUrl: onOpenHostUrl,
                              host: host,
                              api: api,
                              sessionId: sessionId,
                            )
                          else
                            _LinkifiedSelectableText(
                              text: message.text,
                              style: bodyStyle,
                              linkStyle: linkStyle,
                              onOpenHostUrl: onOpenHostUrl,
                            ),
                        if (canPin || hasText)
                          Align(
                            alignment: Alignment.centerRight,
                            child: AnimatedOpacity(
                              opacity: showActions ? AppEmphasis.full : 0,
                              duration: AppMotion.quick,
                              alwaysIncludeSemantics: true,
                              child: IgnorePointer(
                                ignoring: !showActions,
                                child: Tooltip(
                                  message: _formatMessageTime(
                                    message.createdAt,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (hasText)
                                        IconButton(
                                          tooltip: 'Copy message',
                                          icon: const Icon(
                                            Icons.copy_outlined,
                                            size: AppSizes.compactIcon,
                                          ),
                                          onPressed: () => Clipboard.setData(
                                            ClipboardData(text: message.text),
                                          ),
                                        ),
                                      if (canPin)
                                        IconButton(
                                          tooltip: pinned
                                              ? 'Unpin message'
                                              : 'Pin message',
                                          icon: Icon(
                                            pinned
                                                ? Icons.push_pin_rounded
                                                : Icons.push_pin_outlined,
                                            size: AppSizes.compactIcon,
                                          ),
                                          onPressed: onTogglePin,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageAttachmentsSection extends StatelessWidget {
  const _MessageAttachmentsSection({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.attachments,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final List<SessionMessageAttachment> attachments;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = attachments.length == 1
            ? constraints.maxWidth
            : ((constraints.maxWidth - 8) / 2)
                  .clamp(120.0, constraints.maxWidth)
                  .toDouble();
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: attachments
              .map((attachment) {
                return SizedBox(
                  width: attachment.isLocalImage
                      ? constraints.maxWidth
                      : itemWidth,
                  child: _MessageAttachmentTile(
                    host: host,
                    api: api,
                    sessionId: sessionId,
                    attachment: attachment,
                  ),
                );
              })
              .toList(growable: false),
        );
      },
    );
  }
}

class _MessageAttachmentTile extends StatelessWidget {
  const _MessageAttachmentTile({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.attachment,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final SessionMessageAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage && attachment.url != null) {
      return _MessageImageAttachmentTile(
        host: host,
        api: api,
        url: attachment.url!,
      );
    }
    if (attachment.isLocalImage && attachment.path != null) {
      return _LocalImageAttachmentTile(
        host: host,
        api: api,
        sessionId: sessionId,
        path: attachment.path!,
      );
    }
    return const SizedBox.shrink();
  }
}

class _MessageImageAttachmentTile extends StatefulWidget {
  const _MessageImageAttachmentTile({
    required this.host,
    required this.api,
    required this.url,
  });

  final HostProfile host;
  final ApiClient api;
  final String url;

  @override
  State<_MessageImageAttachmentTile> createState() =>
      _MessageImageAttachmentTileState();
}

class _MessageImageAttachmentTileState
    extends State<_MessageImageAttachmentTile> {
  Uint8List? _dataUrlBytes;
  Uint8List? _hostUrlBytes;
  Object? _hostUrlError;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _decodeDataUrlIfNeeded();
    unawaited(_loadHostUrlIfNeeded());
  }

  @override
  void didUpdateWidget(covariant _MessageImageAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.host.id != widget.host.id ||
        oldWidget.host.baseUrl != widget.host.baseUrl ||
        oldWidget.host.token != widget.host.token) {
      _decodeDataUrlIfNeeded();
      unawaited(_loadHostUrlIfNeeded());
    }
  }

  Future<void> _loadHostUrlIfNeeded() async {
    final gen = ++_loadGeneration;
    if (!isHostLoopbackUrl(widget.url)) {
      if (mounted) {
        setState(() {
          _hostUrlBytes = null;
          _hostUrlError = null;
        });
      }
      return;
    }
    setState(() {
      _hostUrlBytes = null;
      _hostUrlError = null;
    });
    try {
      final bytes = await widget.api.fetchHostResource(widget.host, widget.url);
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _hostUrlBytes = bytes);
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() => _hostUrlError = error);
    }
  }

  void _decodeDataUrlIfNeeded() {
    if (!_isInlineImageDataUrl(widget.url)) {
      _dataUrlBytes = null;
      return;
    }
    _dataUrlBytes = _decodeInlineImageDataUrl(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    final imageProvider = _imageProvider();
    final heroTag = _messageImageHeroTag(widget.url);
    return _ImageAttachmentCard(
      imageProvider: imageProvider,
      heroTag: heroTag,
      loading:
          isHostLoopbackUrl(widget.url) &&
          _hostUrlError == null &&
          imageProvider == null,
      onRetry: _loadHostUrlIfNeeded,
      onOpen: imageProvider == null
          ? null
          : () {
              showImageViewer(
                context,
                source: ImageViewerSource(
                  imageProvider: imageProvider,
                  heroTag: heroTag,
                  title: 'Image attachment',
                ),
              );
            },
    );
  }

  ImageProvider<Object>? _imageProvider() {
    if (_dataUrlBytes != null) {
      return MemoryImage(_dataUrlBytes!);
    }
    if (_hostUrlBytes != null) {
      return MemoryImage(_hostUrlBytes!);
    }
    if (isHostLoopbackUrl(widget.url)) {
      return null;
    }
    if (!_isInlineImageDataUrl(widget.url)) {
      return NetworkImage(widget.url);
    }
    return null;
  }
}

class _LocalImageAttachmentTile extends StatefulWidget {
  const _LocalImageAttachmentTile({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.path,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final String path;

  @override
  State<_LocalImageAttachmentTile> createState() =>
      _LocalImageAttachmentTileState();
}

class _LocalImageAttachmentTileState extends State<_LocalImageAttachmentTile> {
  ImageProvider<Object>? _imageProvider;
  Object? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LocalImageAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.id != widget.host.id ||
        oldWidget.host.baseUrl != widget.host.baseUrl ||
        oldWidget.host.token != widget.host.token ||
        oldWidget.sessionId != widget.sessionId ||
        oldWidget.path != widget.path) {
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    setState(() {
      _imageProvider = null;
      _error = null;
    });
    try {
      ImageProvider<Object> imageProvider;
      try {
        imageProvider = await ImageBlobCacheStore.instance.loadImageProvider(
          host: widget.host,
          path: widget.path,
          api: widget.api,
          sessionId: widget.sessionId,
        );
      } on ApiException catch (error) {
        if (error.statusCode != 403) rethrow;
        final artifact = await widget.api.publishSessionArtifact(
          widget.host,
          sessionId: widget.sessionId,
          source: widget.path,
        );
        imageProvider = MemoryImage(
          await widget.api.fetchSessionArtifact(widget.host, artifact.id),
        );
      }
      if (!mounted || gen != _loadGeneration) {
        return;
      }
      setState(() => _imageProvider = imageProvider);
    } catch (error) {
      if (!mounted || gen != _loadGeneration) {
        return;
      }
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final heroTag = _messageImageHeroTag('${widget.host.id}:${widget.path}');
    final imageProvider = _imageProvider;
    final hasFailed = _error != null;
    return _ImageAttachmentCard(
      imageProvider: imageProvider,
      heroTag: heroTag,
      loading: !hasFailed && imageProvider == null,
      onRetry: _load,
      onOpen: imageProvider == null
          ? null
          : () {
              showImageViewer(
                context,
                source: ImageViewerSource(
                  imageProvider: imageProvider,
                  heroTag: heroTag,
                  title: _basename(widget.path),
                  subtitle: widget.path,
                ),
              );
            },
    );
  }
}

class _ImageAttachmentCard extends StatefulWidget {
  const _ImageAttachmentCard({
    required this.imageProvider,
    required this.heroTag,
    required this.loading,
    required this.onRetry,
    required this.onOpen,
  });
  final ImageProvider<Object>? imageProvider;
  final String heroTag;
  final bool loading;
  final VoidCallback onRetry;
  final VoidCallback? onOpen;
  @override
  State<_ImageAttachmentCard> createState() => _ImageAttachmentCardState();
}

class _ImageAttachmentCardState extends State<_ImageAttachmentCard> {
  int _retry = 0;
  Future<void> _reload() async {
    await widget.imageProvider?.evict();
    if (!mounted) return;
    setState(() => _retry++);
    widget.onRetry();
  }

  Widget _error() => MeshEmptyState.compact(
    icon: Icons.broken_image_rounded,
    title: 'Could not load image',
    action: TextButton(onPressed: _reload, child: const Text('Retry')),
  );
  @override
  Widget build(BuildContext context) {
    final provider = widget.imageProvider;
    final imageChild = provider == null
        ? (widget.loading ? const MeshLoader(label: 'Loading image') : _error())
        : Hero(
            tag: widget.heroTag,
            child: Image(
              key: ValueKey(_retry),
              image: provider,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, _) => frame == null
                  ? const MeshLoader(label: 'Loading image')
                  : child,
              errorBuilder: (context, error, stackTrace) => _error(),
            ),
          );
    return ClipRRect(
      borderRadius: AppShapes.panel,
      child: Material(
        color: context.colors.surfaceMuted,
        child: InkWell(
          onTap: widget.onOpen,
          child: AspectRatio(aspectRatio: 1.35, child: imageChild),
        ),
      ),
    );
  }
}

class _MarkdownMessageBody extends StatelessWidget {
  const _MarkdownMessageBody({
    required this.text,
    required this.textColor,
    this.linkStyle,
    this.onOpenFile,
    this.onOpenHostUrl,
    this.host,
    this.api,
    this.sessionId,
  });

  final String text;
  final Color textColor;
  final TextStyle? linkStyle;
  final void Function(String path)? onOpenFile;
  final void Function(String url)? onOpenHostUrl;
  final HostProfile? host;
  final ApiClient? api;
  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    return MarkdownContent(
      text: text,
      textColor: textColor,
      linkStyle: linkStyle,
      onOpenFile: onOpenFile,
      onOpenHostUrl: onOpenHostUrl,
      host: host,
      api: api,
      sessionId: sessionId,
    );
  }
}

class _ReasoningTextBody extends StatelessWidget {
  const _ReasoningTextBody({
    required this.text,
    required this.textColor,
    this.onOpenHostUrl,
  });

  final String text;
  final Color textColor;
  final void Function(String url)? onOpenHostUrl;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: textColor,
      height: AppLineHeights.code,
    );
    return _LinkifiedSelectableText(
      text: text,
      style: style,
      linkStyle: linkTextStyleForBackground(
        background: colors.assistantBubble,
        preferred: colors.accent,
        fallbacks: [colors.info, colors.textPrimary, colors.textSecondary],
        baseStyle: style,
      ),
      onOpenHostUrl: onOpenHostUrl,
    );
  }
}

bool _isInlineImageDataUrl(String value) => value.startsWith('data:image/');

Uint8List? _decodeInlineImageDataUrl(String value) {
  try {
    return UriData.parse(value).contentAsBytes();
  } catch (_) {
    return null;
  }
}

String? _inlineImageMimeType(String value) {
  try {
    return UriData.parse(value).mimeType;
  } catch (_) {
    return null;
  }
}

String _messageImageHeroTag(String url) =>
    'session-image:${url.hashCode.toUnsigned(32)}';

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/');
  return parts.isEmpty ? path : parts.last;
}

String _formatByteCount(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _truncateMiddle(String value, int maxLength) {
  if (value.length <= maxLength || maxLength < 7) {
    return value;
  }
  final prefixLength = ((maxLength - 1) / 2).floor() - 1;
  final suffixLength = maxLength - prefixLength - 1;
  return '${value.substring(0, prefixLength)}…${value.substring(value.length - suffixLength)}';
}

class _LinkifiedSelectableText extends StatefulWidget {
  const _LinkifiedSelectableText({
    required this.text,
    required this.style,
    required this.linkStyle,
    this.onOpenHostUrl,
  });

  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;
  final void Function(String url)? onOpenHostUrl;

  @override
  State<_LinkifiedSelectableText> createState() =>
      _LinkifiedSelectableTextState();
}

class _LinkifiedSelectableTextState extends State<_LinkifiedSelectableText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    final matches = _urlRegExp.allMatches(widget.text).toList();
    var cursor = 0;
    for (final m in matches) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: widget.text.substring(cursor, m.start)));
      }
      var raw = m.group(0)!;
      // Trim common trailing punctuation that usually isn't part of the URL.
      final trimmed = raw.replaceAll(RegExp(r'[),.!?;:\]]+$'), '');
      final trailing = raw.substring(trimmed.length);
      raw = trimmed;
      final href = raw.startsWith('www.') ? 'https://$raw' : raw;
      final recognizer = TapGestureRecognizer()
        ..onTap = () =>
            _openLink(context, href, onOpenHostUrl: widget.onOpenHostUrl);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(text: raw, style: widget.linkStyle, recognizer: recognizer),
      );
      if (trailing.isNotEmpty) {
        spans.add(TextSpan(text: trailing));
      }
      cursor = m.end;
    }
    if (cursor < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(cursor)));
    }

    return SelectableText.rich(TextSpan(style: widget.style, children: spans));
  }
}

Future<void> _openLink(
  BuildContext context,
  String href, {
  void Function(String url)? onOpenHostUrl,
}) async {
  if (isHostLoopbackUrl(href)) {
    if (onOpenHostUrl != null) {
      onOpenHostUrl(href);
    } else if (context.mounted) {
      showAppSnackBar(
        context,
        'This address belongs to the connected host and cannot open directly on this device.',
      );
    }
    return;
  }
  final uri = Uri.tryParse(href);
  if (uri == null) return;
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    showAppSnackBar(context, 'Could not open link');
  }
}

final RegExp _urlRegExp = RegExp(
  r'(https?:\/\/[^\s<>]+|www\.[^\s<>]+)',
  caseSensitive: false,
);

class _ActivityCard extends StatefulWidget {
  const _ActivityCard({
    required this.host,
    required this.api,
    required this.sessionId,
    required this.activity,
    required this.sessionCwd,
    this.defaultCollapsed = true,
    this.onOpenFile,
    this.onBrowsePath,
    this.onOpenBrowserPreview,
    this.onOpenTerminal,
    this.opensFilesInInspector = false,
  });

  final HostProfile host;
  final ApiClient api;
  final String sessionId;
  final SessionActivity activity;
  final String sessionCwd;
  final bool defaultCollapsed;
  final void Function(String path)? onOpenFile;
  final void Function(String path)? onBrowsePath;
  final void Function(BrowserPreviewTargetCandidate target)?
  onOpenBrowserPreview;
  final void Function(String? cwd)? onOpenTerminal;
  final bool opensFilesInInspector;

  @override
  State<_ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<_ActivityCard> {
  static const _collapsedLineLimit = 15;
  bool _outputExpanded = false;
  bool _diffExpanded = false;
  late bool _cardCollapsed = _resolveInitialCollapsed();
  bool _userOverrode = false;

  bool get _activityRunning {
    const terminal = {'completed', 'failed', 'declined'};
    return !terminal.contains(widget.activity.status);
  }

  bool _resolveInitialCollapsed() {
    if (widget.activity.type == 'image_generation') {
      return widget.defaultCollapsed;
    }
    if (_activityRunning) return false;
    return widget.defaultCollapsed;
  }

  @override
  void didUpdateWidget(covariant _ActivityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_userOverrode) return;
    if (widget.activity.type == 'image_generation') return;
    const terminal = {'completed', 'failed', 'declined'};
    final wasRunning = !terminal.contains(oldWidget.activity.status);
    final isRunning = _activityRunning;
    if (wasRunning && !isRunning && !_cardCollapsed) {
      setState(() => _cardCollapsed = true);
    } else if (!wasRunning && isRunning && _cardCollapsed) {
      setState(() => _cardCollapsed = false);
    }
  }

  void _openWorkspaceFile(String path) => widget.onOpenFile?.call(path);

  String? get _primaryFilePath {
    final activity = widget.activity;
    if (activity.isImageGeneration) {
      final savedPath = (activity.savedPath ?? '').trim();
      return savedPath.isEmpty ? null : savedPath;
    }
    if (activity.isFileChange && activity.changes.length == 1) {
      return activity.changes.first.path;
    }
    if (activity.isTool) {
      final target = (activity.toolTarget ?? '').trim();
      if ((activity.toolCategory == 'filesystem' ||
              activity.toolCategory == 'command') &&
          target.isNotEmpty &&
          !target.startsWith('http://') &&
          !target.startsWith('https://')) {
        return target;
      }
    }
    return null;
  }

  String? get _browsePath {
    final activity = widget.activity;
    if (activity.isImageGeneration) {
      return _primaryFilePath;
    }
    if (activity.isFileChange) {
      if (activity.changes.length == 1) {
        return activity.changes.first.path;
      }
      if (activity.changes.isNotEmpty) {
        return activity.changes.first.path;
      }
    }
    if (activity.isTool) {
      final target = (activity.toolTarget ?? '').trim();
      if (target.isNotEmpty &&
          !target.startsWith('http://') &&
          !target.startsWith('https://')) {
        return target;
      }
    }
    return null;
  }

  BrowserPreviewTargetCandidate? get _browserPreviewTarget {
    final callback = widget.onOpenBrowserPreview;
    if (callback == null) {
      return null;
    }
    final candidates = browserPreviewCandidatesForActivity(widget.activity);
    if (candidates.isEmpty) {
      return null;
    }
    return candidates.first;
  }

  List<_ActivityActionSpec> _buildContextActions() {
    final actions = <_ActivityActionSpec>[];
    final previewTarget = _browserPreviewTarget;
    if (previewTarget != null) {
      actions.add(
        _ActivityActionSpec(
          label: previewTarget.previewLabel,
          icon: Icons.open_in_browser_rounded,
          tone: _ActivityActionTone.accent,
          onTap: () => widget.onOpenBrowserPreview!(previewTarget),
        ),
      );
    }
    final browsePath = _browsePath;
    if (browsePath != null && widget.onBrowsePath != null) {
      actions.add(
        _ActivityActionSpec(
          label: widget.activity.isFileChange && widget.opensFilesInInspector
              ? 'Open in inspector'
              : 'Browse files',
          icon: Icons.folder_open_rounded,
          onTap: () => widget.onBrowsePath!(browsePath),
        ),
      );
    }
    final openFilePath = _primaryFilePath;
    if (openFilePath != null && widget.onOpenFile != null) {
      actions.add(
        _ActivityActionSpec(
          label: 'Open file',
          icon: Icons.description_rounded,
          onTap: () => widget.onOpenFile!(openFilePath),
        ),
      );
    }
    if (widget.activity.isCommand && widget.onOpenTerminal != null) {
      actions.add(
        _ActivityActionSpec(
          label: 'Open terminal',
          icon: Icons.terminal_rounded,
          onTap: () => widget.onOpenTerminal!(widget.activity.cwd),
        ),
      );
    }
    return actions;
  }

  Widget? _activityStatusBadge(SessionActivity activity) {
    if (activity.status == 'completed') {
      return null;
    }
    final statusTone = switch (activity.status) {
      'failed' => MeshStatusTone.danger,
      'declined' => MeshStatusTone.neutral,
      _ => MeshStatusTone.running,
    };
    final statusLabel = switch (activity.status) {
      'failed' => 'failed',
      'declined' => 'declined',
      _ => 'running',
    };
    final statusIcon = switch (activity.status) {
      'failed' => Icons.error_outline_rounded,
      'declined' => Icons.block_rounded,
      _ => Icons.bolt_rounded,
    };
    return MeshStatusBadge(
      label: statusLabel,
      tone: statusTone,
      icon: statusIcon,
      compact: true,
    );
  }

  List<Widget> _activityDetailPills(SessionActivity activity) {
    final pills = <Widget>[];
    if (activity.isCommand) {
      if (activity.exitCode != null && activity.exitCode != 0) {
        pills.add(
          MeshPill(
            label: 'exit ${activity.exitCode}',
            tone: MeshPillTone.danger,
            mono: true,
          ),
        );
      }
      if (activity.durationMs != null &&
          (activity.status == 'failed' || activity.durationMs! >= 10000)) {
        pills.add(
          MeshPill(label: _formatDuration(activity.durationMs!), mono: true),
        );
      }
      if (activity.terminalStatus == 'input') {
        pills.add(
          const MeshPill(label: 'stdin', tone: MeshPillTone.info, mono: true),
        );
      }
      if (activity.terminalStatus == 'waiting') {
        pills.add(
          const MeshPill(
            label: 'interactive',
            tone: MeshPillTone.warning,
            mono: true,
          ),
        );
      }
    }
    if (activity.isTool && activity.toolError == true) {
      pills.add(
        const MeshPill(
          label: 'tool error',
          tone: MeshPillTone.danger,
          mono: true,
        ),
      );
    }
    return pills;
  }

  _CommandTitleParts? _activityCommandTitleParts(SessionActivity activity) {
    final rawCommand = activity.isCommand
        ? activity.command ?? ''
        : activity.isTool && _toolIsCommandActivity(activity)
        ? _toolCommandText(activity)
        : '';
    return _commandTitleParts(rawCommand, activity.status);
  }

  Widget _buildActivityTitle(
    BuildContext context, {
    required SessionActivity activity,
    required String title,
  }) {
    final commandTitle = _activityCommandTitleParts(activity);
    final child = commandTitle != null
        ? Semantics(
            key: ValueKey('cmd:${commandTitle.plainText}:$_cardCollapsed'),
            label: commandTitle.plainText,
            child: ExcludeSemantics(
              child: _CommandTitleChip(
                parts: commandTitle,
                collapsed: _cardCollapsed,
              ),
            ),
          )
        : Text(
            title,
            key: ValueKey('title:$title:$_cardCollapsed'),
            maxLines: _cardCollapsed ? 1 : 3,
            overflow: TextOverflow.ellipsis,
            style:
                (activity.isTool
                        ? monoStyle(
                            color: context.colors.textPrimary,
                            fontSize: AppFontSizes.compact,
                          )
                        : Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: AppWeights.emphasis,
                          ))
                    ?.copyWith(height: AppLineHeights.caption),
          );
    return AnimatedSwitcher(
      duration: AppMotion.quick,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      child: child,
    );
  }

  Widget _activityDetailsPanel(BuildContext context, Widget child) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.tight),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.compact,
          AppSpacing.compact,
          AppSpacing.compact,
          AppSpacing.compact,
        ),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: AppEmphasis.medium),
          borderRadius: AppShapes.input,
          border: Border.all(
            color: colors.border.withValues(alpha: AppEmphasis.disabled),
          ),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activity = widget.activity;
    final sessionCwd = widget.sessionCwd;
    final colors = context.colors;
    if (activity.isFileChange) {
      return _buildFileChangeInlineActivity(context, activity);
    }

    final title = switch (activity.type) {
      'command' => _commandActivityTitle(activity),
      'tool' => _toolActivityTitle(activity, sessionCwd),
      'file_change' =>
        activity.changes.length == 1
            ? _relativeSessionPath(activity.changes.first.path, sessionCwd)
            : 'Edited ${activity.changes.length} files',
      'turn_diff' => _turnDiffActivityTitle(activity),
      'web_search' => _webSearchTitle(activity),
      'image_generation' => _imageGenerationTitle(activity),
      'context_compaction' => _contextCompactionTitle(activity),
      _ => 'Activity',
    };

    final subtitle = switch (activity.type) {
      'command' => _relativeSessionPath(activity.cwd ?? sessionCwd, sessionCwd),
      'tool' => _toolActivitySubtitle(activity, sessionCwd),
      'file_change' => _activityFileSummary(activity.changes, sessionCwd),
      'turn_diff' => null,
      'web_search' => _webSearchSubtitle(activity),
      'image_generation' =>
        (activity.savedPath ?? '').isNotEmpty
            ? _relativeSessionPath(activity.savedPath!, sessionCwd)
            : 'Image generation output',
      'context_compaction' => _contextCompactionSubtitle(activity),
      _ => null,
    };

    final activityLabel = switch (activity.type) {
      'command' => null,
      'tool' => _toolActivityLabel(activity),
      'file_change' => 'File edit',
      'turn_diff' => null,
      'web_search' => 'Web search',
      'image_generation' => 'Image',
      'context_compaction' => 'Context',
      _ => 'Activity',
    };

    final activityIcon = switch (activity.type) {
      'command' => Icons.terminal_rounded,
      'tool' => _toolActivityIcon(activity),
      'file_change' => Icons.edit_note_rounded,
      'turn_diff' => Icons.difference_rounded,
      'web_search' => Icons.travel_explore_rounded,
      'image_generation' => Icons.image_rounded,
      'context_compaction' => Icons.compress_rounded,
      _ => Icons.bolt_rounded,
    };

    final statusBadge = _activityStatusBadge(activity);
    final contextActions = _buildContextActions();
    final detailPills = _activityDetailPills(activity);

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.compact),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSizes.readingMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: Colors.transparent,
                shape: RoundedRectangleBorder(borderRadius: AppShapes.input),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _cardCollapsed = !_cardCollapsed;
                      _userOverrode = true;
                    });
                  },
                  borderRadius: AppShapes.input,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 0,
                      vertical: AppSpacing.tight,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Icon(
                          activityIcon,
                          size: AppSizes.compactIcon,
                          color: colors.textTertiary,
                        ),
                        const SizedBox(width: AppSpacing.compact),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (activityLabel != null) ...[
                                Text(
                                  activityLabel,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: colors.textTertiary,
                                        fontWeight: AppWeights.title,
                                        letterSpacing: AppLetterSpacing.caps,
                                      ),
                                ),
                                const SizedBox(height: AppSpacing.xxs),
                              ],
                              _buildActivityTitle(
                                context,
                                activity: activity,
                                title: title,
                              ),
                              if (!_cardCollapsed &&
                                  subtitle != null &&
                                  subtitle.isNotEmpty) ...[
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: colors.textSecondary),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (statusBadge != null) ...[
                          const SizedBox(width: AppSpacing.sm),
                          statusBadge,
                        ],
                        const SizedBox(width: AppSpacing.xs),
                        Icon(
                          _cardCollapsed
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_up_rounded,
                          size: AppSizes.inlineIcon,
                          color: colors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: AppMotion.quick,
                curve: AppMotion.standard,
                alignment: Alignment.topLeft,
                child: _cardCollapsed
                    ? const SizedBox.shrink()
                    : _activityDetailsPanel(
                        context,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (detailPills.isNotEmpty) ...[
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: detailPills,
                              ),
                              const SizedBox(height: AppSpacing.md),
                            ],
                            if (activity.isCommand)
                              ..._buildCommandBody(context, activity)
                            else if (activity.isTool)
                              ..._buildToolBody(context, activity)
                            else if (activity.isWebSearch) ...[
                              _buildWebSearchBody(context, activity),
                            ] else if (activity.isImageGeneration) ...[
                              _buildImageGenerationBody(context, activity),
                            ] else if (activity.isContextCompaction) ...[
                              ..._buildContextCompactionBody(context, activity),
                            ] else if (activity.isTurnDiff) ...[
                              if ((activity.diff ?? '').isNotEmpty)
                                _buildLazyDiff(
                                  context,
                                  label:
                                      'View patch (${_diffLineCount(activity.diff!)} lines)',
                                  diff: activity.diff!,
                                )
                              else
                                _waitingText(context, 'Tracking file changes.'),
                            ] else if (activity.changes.isEmpty) ...[
                              _waitingText(
                                context,
                                'Waiting for file changes.',
                              ),
                            ] else ...[
                              _buildLazyFileChanges(
                                context,
                                changes: activity.changes,
                                sessionCwd: sessionCwd,
                              ),
                            ],
                            if (contextActions.isNotEmpty) ...[
                              const SizedBox(height: AppSpacing.md),
                              _ActivityActionRow(actions: contextActions),
                            ],
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileChangeInlineActivity(
    BuildContext context,
    SessionActivity activity,
  ) {
    final colors = context.colors;
    final changes = activity.changes;
    final sessionCwd = widget.sessionCwd;
    final title = _fileChangeActivityTitle(activity);
    final subtitle = _activityFileSummary(changes, sessionCwd);
    final statusBadge = _activityStatusBadge(activity);
    final contextActions = _buildContextActions();

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.compact),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSizes.readingMaxWidth),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: colors.surfaceMuted.withValues(
                  alpha: AppEmphasis.disabled,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: AppShapes.input,
                  side: BorderSide(
                    color: colors.border.withValues(alpha: AppEmphasis.medium),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _cardCollapsed = !_cardCollapsed;
                      _userOverrode = true;
                    });
                  },
                  borderRadius: AppShapes.input,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.compact,
                      vertical: AppSpacing.sm,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: colors.surfaceMuted.withValues(
                              alpha: AppEmphasis.secondary,
                            ),
                            borderRadius: AppShapes.iconWell,
                            border: Border.all(
                              color: colors.border.withValues(
                                alpha: AppEmphasis.disabled,
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.edit_note_rounded,
                            size: AppSizes.compactIcon,
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.compact),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      color: colors.textPrimary,
                                      fontWeight: AppWeights.emphasis,
                                      height: AppLineHeights.title,
                                    ),
                              ),
                              if (subtitle.isNotEmpty) ...[
                                const SizedBox(height: AppSpacing.xxs),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: monoStyle(
                                    color: colors.textSecondary,
                                    fontSize: AppFontSizes.caption,
                                    fontWeight: AppWeights.body,
                                  ).copyWith(height: AppLineHeights.label),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (statusBadge != null) ...[
                          const SizedBox(width: AppSpacing.sm),
                          statusBadge,
                        ],
                        const SizedBox(width: AppSpacing.xs),
                        Icon(
                          _cardCollapsed
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_up_rounded,
                          size: AppSizes.inlineIcon,
                          color: colors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: AppMotion.quick,
                curve: AppMotion.standard,
                alignment: Alignment.topLeft,
                child: _cardCollapsed
                    ? const SizedBox.shrink()
                    : _activityDetailsPanel(
                        context,
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (contextActions.isNotEmpty) ...[
                              _ActivityActionRow(actions: contextActions),
                              const SizedBox(height: AppSpacing.compact),
                            ],
                            if (changes.isEmpty)
                              _waitingText(context, 'Waiting for file changes.')
                            else if (_diffExpanded)
                              _buildLazyFileChanges(
                                context,
                                changes: changes,
                                sessionCwd: sessionCwd,
                              )
                            else ...[
                              for (final change in changes)
                                _InlineFileChangeRow(
                                  change: change,
                                  sessionCwd: sessionCwd,
                                  onOpen: _openWorkspaceFile,
                                ),
                              const SizedBox(height: AppSpacing.sm),
                              _buildLazyFileChanges(
                                context,
                                changes: changes,
                                sessionCwd: sessionCwd,
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildCommandBody(
    BuildContext context,
    SessionActivity activity,
  ) {
    final colors = context.colors;
    final widgets = <Widget>[];
    final command = _displayCommandText(activity.command ?? '');

    if (_friendlyCommandTitleParts(command, activity.status) != null) {
      widgets.add(_activityCodeBlock(context, 'Raw command', command, 'bash'));
      widgets.add(const SizedBox(height: AppSpacing.md));
    }

    if ((activity.terminalInput ?? '').isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Text(
            'Sent to terminal',
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: AppFontSizes.metadata,
              fontWeight: AppWeights.emphasis,
            ).copyWith(letterSpacing: AppLetterSpacing.caps),
          ),
        ),
      );
      widgets.add(
        SyntaxCodeBlock(text: activity.terminalInput!, language: 'bash'),
      );
      widgets.add(const SizedBox(height: AppSpacing.md));
    }

    if ((activity.output ?? '').isNotEmpty) {
      final output = activity.output!;
      final lines = output.split('\n');
      final isLong = lines.length > _collapsedLineLimit;
      final displayText = isLong && !_outputExpanded
          ? lines.take(_collapsedLineLimit).join('\n')
          : output;
      widgets.add(SyntaxCodeBlock(text: displayText, language: 'bash'));
      if (isLong) {
        widgets.add(const SizedBox(height: AppSpacing.tight));
        widgets.add(
          _ExpandToggle(
            expanded: _outputExpanded,
            hiddenCount: lines.length - _collapsedLineLimit,
            onToggle: () => setState(() => _outputExpanded = !_outputExpanded),
          ),
        );
      }
    } else if (_activityRunning && activity.terminalStatus == 'waiting') {
      widgets.add(_waitingText(context, 'Interactive command is running.'));
    } else if (_activityRunning) {
      widgets.add(_waitingText(context, 'Waiting for command output.'));
    } else if (activity.status == 'failed') {
      widgets.add(_waitingText(context, 'Command failed without output.'));
    } else if (activity.status == 'declined') {
      widgets.add(_waitingText(context, 'Command was declined.'));
    } else {
      widgets.add(_waitingText(context, 'Command completed without output.'));
    }

    return widgets;
  }

  List<Widget> _buildToolBody(BuildContext context, SessionActivity activity) {
    final widgets = <Widget>[];
    widgets.addAll(_buildToolSemanticBlocks(context, activity));
    if (widgets.isNotEmpty) {
      widgets.add(const SizedBox(height: AppSpacing.md));
    }
    final command = _displayCommandText(_toolCommandText(activity));
    if (_friendlyCommandTitleParts(command, activity.status) != null) {
      widgets.add(_activityCodeBlock(context, 'Raw command', command, 'bash'));
      widgets.add(const SizedBox(height: AppSpacing.md));
    }
    final output = (activity.output ?? '').trimRight();
    final args = _formatActivityValue(activity.toolArgs);
    final result = _formatActivityValue(activity.toolResult);

    if (args.isNotEmpty) {
      widgets.add(_activityCodeBlock(context, 'Arguments', args, 'json'));
      widgets.add(const SizedBox(height: AppSpacing.md));
    }

    if (output.isNotEmpty) {
      widgets.add(_activityCodeBlock(context, 'Output', output, 'text'));
      widgets.add(const SizedBox(height: AppSpacing.md));
    }

    if (activity.toolAttachments.isNotEmpty) {
      widgets.add(
        _MessageAttachmentsSection(
          host: widget.host,
          api: widget.api,
          sessionId: widget.sessionId,
          attachments: activity.toolAttachments,
        ),
      );
      widgets.add(const SizedBox(height: AppSpacing.md));
    }

    if (result.isNotEmpty) {
      widgets.add(_activityCodeBlock(context, 'Result', result, 'json'));
      widgets.add(const SizedBox(height: AppSpacing.md));
    }

    if (widgets.isEmpty) {
      final message = switch (activity.status) {
        'failed' => 'Tool failed without additional details.',
        'declined' => 'Tool was declined.',
        'completed' => 'Tool completed without additional details.',
        _ => 'Waiting for tool details.',
      };
      widgets.add(_waitingText(context, message));
    } else {
      widgets.removeLast();
    }

    return widgets;
  }

  Widget _activityCodeBlock(
    BuildContext context,
    String label,
    String text,
    String language,
  ) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: monoStyle(
            color: colors.textSecondary,
            fontSize: AppFontSizes.metadata,
            fontWeight: AppWeights.emphasis,
          ).copyWith(letterSpacing: AppLetterSpacing.caps),
        ),
        const SizedBox(height: AppSpacing.sm),
        SyntaxCodeBlock(text: text, language: language),
      ],
    );
  }

  Widget _buildWebSearchBody(BuildContext context, SessionActivity activity) {
    final colors = context.colors;
    final rows = <Widget>[];
    final primaryQuery = (activity.query ?? '').trim();
    final queryList = activity.queries
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final targetUrl = (activity.targetUrl ?? '').trim();
    final pattern = (activity.pattern ?? '').trim();

    if (primaryQuery.isNotEmpty) {
      rows.add(_activityInfoBlock(context, 'Query', primaryQuery));
    }
    if (queryList.isNotEmpty) {
      rows.add(
        _activityInfoBlock(
          context,
          queryList.length > 1 ? 'Queries' : 'Query',
          queryList.join('\n'),
        ),
      );
    }
    if (targetUrl.isNotEmpty) {
      rows.add(
        _activityInfoBlock(
          context,
          pattern.isNotEmpty ? 'Page' : 'URL',
          targetUrl,
          linkify: true,
        ),
      );
    }
    if (pattern.isNotEmpty) {
      rows.add(_activityInfoBlock(context, 'Pattern', pattern));
    }

    if (rows.isEmpty) {
      return _waitingText(context, 'Waiting for search details.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...rows.expand(
          (row) => [row, const SizedBox(height: AppSpacing.compact)],
        ),
        Text(
          _webSearchStatusCopy(activity),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  Widget _activityInfoBlock(
    BuildContext context,
    String label,
    String text, {
    bool linkify = false,
  }) {
    final colors = context.colors;
    final bodyStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: colors.textPrimary,
      height: AppLineHeights.body,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.compact,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: AppFontSizes.metadata,
              fontWeight: AppWeights.emphasis,
            ).copyWith(letterSpacing: AppLetterSpacing.caps),
          ),
          const SizedBox(height: AppSpacing.tight),
          linkify
              ? _LinkifiedSelectableText(
                  text: text,
                  style: bodyStyle,
                  linkStyle: linkTextStyleForBackground(
                    background: colors.surfaceMuted,
                    preferred: colors.accent,
                    fallbacks: [
                      colors.info,
                      colors.textPrimary,
                      colors.textSecondary,
                    ],
                    baseStyle: bodyStyle,
                  ),
                  onOpenHostUrl: _openHostActivityUrl,
                )
              : SelectableText(text, style: bodyStyle),
        ],
      ),
    );
  }

  void _openHostActivityUrl(String raw) {
    final callback = widget.onOpenBrowserPreview;
    if (callback == null) {
      showAppSnackBar(
        context,
        'This address belongs to the connected host and cannot open directly on this device.',
      );
      return;
    }
    final parsed = parseBrowserPreviewTargetInput(
      raw,
      sourceLabel: 'Activity link',
      cwd: widget.sessionCwd,
    );
    final candidate = parsed.candidate;
    if (candidate == null) {
      showAppSnackBar(context, parsed.error ?? 'Could not open host link.');
      return;
    }
    callback(candidate);
  }

  Widget _buildImageGenerationBody(
    BuildContext context,
    SessionActivity activity,
  ) {
    final colors = context.colors;
    final prompt = (activity.revisedPrompt ?? '').trim();
    final savedPath = (activity.savedPath ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (prompt.isNotEmpty) ...[
          Text(
            'Prompt used',
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: AppFontSizes.metadata,
              fontWeight: AppWeights.emphasis,
            ).copyWith(letterSpacing: AppLetterSpacing.caps),
          ),
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.compact,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: AppShapes.input,
              border: Border.all(color: colors.border),
            ),
            child: SelectableText(
              prompt,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textPrimary,
                height: AppLineHeights.body,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (savedPath.isNotEmpty) ...[
          _LocalImageAttachmentTile(
            host: widget.host,
            api: widget.api,
            sessionId: widget.sessionId,
            path: savedPath,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            savedPath,
            style: monoStyle(
              color: colors.textTertiary,
              fontSize: AppFontSizes.metadata,
            ),
          ),
        ] else if (activity.status == 'completed') ...[
          _waitingText(
            context,
            'Image completed, but no saved file was reported.',
          ),
        ] else ...[
          _waitingText(context, switch (activity.status) {
            'failed' => 'Image generation failed.',
            'declined' => 'Image generation was declined.',
            _ => 'Generating image...',
          }),
        ],
      ],
    );
  }

  List<Widget> _buildContextCompactionBody(
    BuildContext context,
    SessionActivity activity,
  ) {
    final message = switch (activity.status) {
      'completed' =>
        'The agent summarized older history so the session can keep working with more free context.',
      'failed' =>
        'The agent tried to compact the session context, but the compaction failed.',
      'declined' => 'Context compaction was declined.',
      _ => 'The agent is compacting older history to free context.',
    };
    return [_activityInfoBlock(context, 'What happened', message)];
  }

  String _toolActivityTitle(SessionActivity activity, String sessionCwd) {
    final target = _toolPrimaryTarget(activity, sessionCwd);
    final query = (activity.toolQuery ?? '').trim();
    final url = (activity.toolUrl ?? '').trim();
    final mode = (activity.toolMode ?? '').trim();
    final command = _toolCommandText(activity);

    if (activity.toolAction == 'mode_change' && mode.isNotEmpty) {
      final verb = _activityActionVerb(
        activity.status,
        completed: 'Switched',
        progress: 'Switching',
        infinitive: 'switch',
      );
      return '$verb to $mode mode';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'read' &&
        target.isNotEmpty) {
      final verb = _activityActionVerb(
        activity.status,
        completed: 'Read',
        progress: 'Reading',
        infinitive: 'read',
      );
      return '$verb $target';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'write' &&
        target.isNotEmpty) {
      final verb = _activityActionVerb(
        activity.status,
        completed: 'Edited',
        progress: 'Editing',
        infinitive: 'edit',
      );
      return '$verb $target';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'list' &&
        target.isNotEmpty) {
      final verb = _activityActionVerb(
        activity.status,
        completed: 'Listed',
        progress: 'Listing',
        infinitive: 'list',
      );
      return '$verb $target';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'search') {
      if (query.isNotEmpty && target.isNotEmpty) {
        return 'Search "$query" in $target';
      }
      if (query.isNotEmpty) {
        return 'Search "$query"';
      }
    }
    if (activity.toolCategory == 'network' &&
        activity.toolAction == 'fetch' &&
        url.isNotEmpty) {
      return 'Fetch ${_truncateMiddle(url, 44)}';
    }
    if (activity.toolCategory == 'network' &&
        activity.toolAction == 'search' &&
        query.isNotEmpty) {
      return 'Search web for "$query"';
    }
    if (_toolIsCommandActivity(activity) && command.isNotEmpty) {
      return _commandTitleParts(command, activity.status)?.plainText ??
          _commandStatusTitle(activity.status, _displayCommandText(command));
    }

    final title = (activity.toolTitle ?? '').trim();
    if (title.isNotEmpty) return title;
    final args = activity.toolArgs;
    if (args is Map) {
      final label = args['title'];
      if (label is String && label.trim().isNotEmpty) return label.trim();
    }
    final name = (activity.toolName ?? '').trim();
    if (name.isNotEmpty) return name;
    return 'Tool execution';
  }

  String? _toolActivitySubtitle(SessionActivity activity, String sessionCwd) {
    final target = _toolPrimaryTarget(activity, sessionCwd);
    final url = (activity.toolUrl ?? '').trim();
    final query = (activity.toolQuery ?? '').trim();
    if (activity.toolAction == 'mode_change') {
      return 'Session runtime control';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'search' &&
        target.isNotEmpty &&
        query.isNotEmpty) {
      return target;
    }
    if (activity.toolCategory == 'network' && url.isNotEmpty) {
      return _truncateMiddle(url, 72);
    }
    if (target.isNotEmpty &&
        (activity.toolCategory == 'filesystem' ||
            activity.toolCategory == 'command')) {
      return target;
    }
    final name = (activity.toolName ?? '').trim();
    return name.isNotEmpty ? name : null;
  }

  String? _toolActivityLabel(SessionActivity activity) {
    if (activity.toolAction == 'mode_change') {
      return 'Mode';
    }
    if (_toolIsCommandActivity(activity)) {
      return null;
    }
    return switch (activity.toolCategory) {
      'filesystem' => switch (activity.toolAction) {
        'read' => 'File read',
        'write' => 'File edit',
        'list' => 'File list',
        'search' => 'File search',
        _ => 'Filesystem',
      },
      'network' => switch (activity.toolAction) {
        'fetch' => 'Web fetch',
        'search' => 'Web search',
        _ => 'Network',
      },
      'command' => null,
      'session' => 'Session',
      'memory' => 'Memory',
      'task' => 'Task',
      _ => null,
    };
  }

  IconData _toolActivityIcon(SessionActivity activity) {
    if (activity.toolAction == 'mode_change') {
      return Icons.tune_rounded;
    }
    if (_toolIsCommandActivity(activity)) {
      return Icons.terminal_rounded;
    }
    return switch (activity.toolCategory) {
      'filesystem' => switch (activity.toolAction) {
        'write' => Icons.edit_note_rounded,
        'search' => Icons.manage_search_rounded,
        'list' => Icons.folder_open_rounded,
        _ => Icons.description_rounded,
      },
      'network' =>
        activity.toolAction == 'search'
            ? Icons.travel_explore_rounded
            : Icons.public_rounded,
      'command' => Icons.terminal_rounded,
      'session' => Icons.tune_rounded,
      'memory' => Icons.psychology_alt_rounded,
      'task' => Icons.checklist_rounded,
      _ => Icons.extension_rounded,
    };
  }

  List<Widget> _buildToolSemanticBlocks(
    BuildContext context,
    SessionActivity activity,
  ) {
    final target = _toolPrimaryTarget(activity, widget.sessionCwd);
    final targets = activity.toolTargets
        .map((item) => _toolDisplayPath(item, widget.sessionCwd))
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final rows = <Widget>[];

    if ((activity.toolMode ?? '').trim().isNotEmpty) {
      rows.add(_activityInfoBlock(context, 'Mode', activity.toolMode!.trim()));
    }
    if ((activity.toolQuery ?? '').trim().isNotEmpty) {
      rows.add(
        _activityInfoBlock(context, 'Query', activity.toolQuery!.trim()),
      );
    }
    if ((activity.toolUrl ?? '').trim().isNotEmpty) {
      rows.add(
        _activityInfoBlock(
          context,
          'URL',
          activity.toolUrl!.trim(),
          linkify: true,
        ),
      );
    }
    if (targets.length > 1) {
      rows.add(_activityInfoBlock(context, 'Targets', targets.join('\n')));
    } else if (target.isNotEmpty) {
      rows.add(_activityInfoBlock(context, 'Target', target));
    }

    if (rows.isEmpty) {
      return const [];
    }

    return [
      ...rows.expand(
        (row) => [row, const SizedBox(height: AppSpacing.compact)],
      ),
    ]..removeLast();
  }

  String _toolPrimaryTarget(SessionActivity activity, String sessionCwd) {
    final raw = (activity.toolTarget ?? '').trim();
    if (raw.isNotEmpty) {
      return _toolDisplayPath(raw, sessionCwd);
    }
    if (activity.toolTargets.isNotEmpty) {
      return _toolDisplayPath(activity.toolTargets.first, sessionCwd);
    }
    return '';
  }

  String _toolDisplayPath(String raw, String sessionCwd) {
    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return _truncateMiddle(raw, 72);
    }
    return _relativeSessionPath(raw, sessionCwd);
  }

  bool _toolIsCommandActivity(SessionActivity activity) {
    return activity.toolCategory == 'command' ||
        _toolCommandText(activity).isNotEmpty;
  }

  String _toolCommandText(SessionActivity activity) {
    for (final target in activity.toolSemanticTargets) {
      final command = (target.command ?? '').trim();
      if (target.type == 'command' && command.isNotEmpty) {
        return command;
      }
    }
    final args = activity.toolArgs;
    if (args is Map<String, dynamic>) {
      final command =
          (args['command'] ?? args['cmd'] ?? args['fullCommandText'])
              ?.toString()
              .trim();
      if (command != null && command.isNotEmpty) {
        return command;
      }
    }
    if (args is Map) {
      final command =
          (args['command'] ?? args['cmd'] ?? args['fullCommandText'])
              ?.toString()
              .trim();
      if (command != null && command.isNotEmpty) {
        return command;
      }
    }
    return '';
  }

  String _formatActivityValue(Object? value) {
    if (value == null) return '';
    if (value is String) return value.trimRight();
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }

  String _webSearchTitle(SessionActivity activity) {
    final primaryQuery = (activity.query ?? '').trim();
    final targetUrl = (activity.targetUrl ?? '').trim();
    final pattern = (activity.pattern ?? '').trim();
    if (pattern.isNotEmpty && targetUrl.isNotEmpty) {
      return 'Find "$pattern" in ${_truncateMiddle(targetUrl, 44)}';
    }
    if (targetUrl.isNotEmpty) {
      return 'Open ${_truncateMiddle(targetUrl, 48)}';
    }
    if (primaryQuery.isNotEmpty) {
      return primaryQuery;
    }
    if (activity.queries.isNotEmpty) {
      return activity.queries.first;
    }
    return 'Web search';
  }

  String? _webSearchSubtitle(SessionActivity activity) {
    final queries = activity.queries
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (queries.length > 1) {
      return '${queries.length} related queries';
    }
    final targetUrl = (activity.targetUrl ?? '').trim();
    if (targetUrl.isNotEmpty) {
      return targetUrl;
    }
    final pattern = (activity.pattern ?? '').trim();
    if (pattern.isNotEmpty) {
      return 'Looking for "$pattern"';
    }
    return null;
  }

  String _webSearchKindLabel(SessionActivity activity) {
    final targetUrl = (activity.targetUrl ?? '').trim();
    final pattern = (activity.pattern ?? '').trim();
    if (pattern.isNotEmpty && targetUrl.isNotEmpty) {
      return 'find in page';
    }
    if (targetUrl.isNotEmpty) {
      return 'open page';
    }
    return 'search';
  }

  String _webSearchStatusCopy(SessionActivity activity) {
    return switch (activity.status) {
      'completed' => switch (_webSearchKindLabel(activity)) {
        'find in page' => 'Finished searching within a page.',
        'open page' => 'Opened a web page for more detail.',
        _ => 'Finished web search.',
      },
      'failed' => 'Web search failed.',
      'declined' => 'Web search was declined.',
      _ => 'Web search is running.',
    };
  }

  Widget _waitingText(BuildContext context, String text) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.compact,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
      ),
    );
  }

  Widget _buildLazyDiff(
    BuildContext context, {
    required String label,
    required String diff,
  }) {
    if (_diffExpanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DiffView(diff: diff),
          const SizedBox(height: AppSpacing.tight),
          _DiffToggle(
            expanded: true,
            label: label,
            expandedLabel: 'Hide patch',
            onToggle: () => setState(() => _diffExpanded = false),
          ),
        ],
      );
    }
    return _DiffToggle(
      expanded: false,
      label: label,
      expandedLabel: 'Hide patch',
      onToggle: () => setState(() => _diffExpanded = true),
    );
  }

  Widget _buildLazyFileChanges(
    BuildContext context, {
    required List<SessionActivityChange> changes,
    required String sessionCwd,
  }) {
    final totalLines = changes.fold<int>(
      0,
      (sum, c) => sum + _diffLineCount(c.diff),
    );
    final label = changes.length == 1
        ? 'View diff ($totalLines lines)'
        : 'View ${changes.length} file diffs ($totalLines lines)';
    if (_diffExpanded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final change in changes)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: _FileChangeBlock(
                change: change,
                sessionCwd: sessionCwd,
                onOpen: _openWorkspaceFile,
              ),
            ),
          _DiffToggle(
            expanded: true,
            label: label,
            expandedLabel: 'Hide diffs',
            onToggle: () => setState(() => _diffExpanded = false),
          ),
        ],
      );
    }
    return _DiffToggle(
      expanded: false,
      label: label,
      expandedLabel: 'Hide diffs',
      onToggle: () => setState(() => _diffExpanded = true),
    );
  }
}

class _CommandTitleChip extends StatelessWidget {
  const _CommandTitleChip({required this.parts, required this.collapsed});

  final _CommandTitleParts parts;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final style = monoStyle(
      color: context.colors.textSecondary,
      fontSize: AppFontSizes.code,
    ).copyWith(height: AppLineHeights.body, fontWeight: AppWeights.body);
    return Row(
      children: [
        Text('${parts.verb} ', style: style),
        Expanded(
          child: Text(
            parts.command,
            maxLines: collapsed ? 1 : 2,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

enum _ActivityActionTone { neutral, accent }

class _ActivityActionSpec {
  const _ActivityActionSpec({
    required this.label,
    required this.icon,
    required this.onTap,
    this.tone = _ActivityActionTone.neutral,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final _ActivityActionTone tone;
}

class _ActivityActionRow extends StatelessWidget {
  const _ActivityActionRow({required this.actions});

  final List<_ActivityActionSpec> actions;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: actions
          .map((action) => _ActivityActionChip(action: action))
          .toList(growable: false),
    );
  }
}

class _ActivityActionChip extends StatelessWidget {
  const _ActivityActionChip({required this.action});

  final _ActivityActionSpec action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = action.tone == _ActivityActionTone.accent
        ? colors.accent
        : colors.textSecondary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: action.onTap,
        borderRadius: BorderRadius.circular(AppRadii.capsule),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: AppEmphasis.focus),
            borderRadius: BorderRadius.circular(AppRadii.capsule),
            border: Border.all(color: tone.withValues(alpha: AppEmphasis.soft)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(action.icon, size: AppSizes.compactIcon, color: tone),
              const SizedBox(width: AppSpacing.tight),
              Text(
                action.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: action.tone == _ActivityActionTone.accent
                      ? colors.accent
                      : colors.textPrimary,
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

class _DiffToggle extends StatelessWidget {
  const _DiffToggle({
    required this.expanded,
    required this.label,
    required this.expandedLabel,
    required this.onToggle,
  });

  final bool expanded;
  final String label;
  final String expandedLabel;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onToggle,
          borderRadius: AppShapes.badge,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.surfaceElevated.withValues(
                alpha: AppEmphasis.secondary,
              ),
              borderRadius: AppShapes.badge,
              border: Border.all(
                color: colors.border.withValues(alpha: AppEmphasis.secondary),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  expanded
                      ? Icons.unfold_less_rounded
                      : Icons.unfold_more_rounded,
                  size: AppSizes.compactIcon,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.tight),
                Text(
                  expanded ? expandedLabel : label,
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: AppFontSizes.caption,
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandToggle extends StatelessWidget {
  const _ExpandToggle({
    required this.expanded,
    required this.hiddenCount,
    required this.onToggle,
  });

  final bool expanded;
  final int hiddenCount;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.accentMuted,
          borderRadius: BorderRadius.circular(AppRadii.control),
          border: Border.all(
            color: colors.accent.withValues(alpha: AppEmphasis.borderTint),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
              size: AppSizes.compactIcon,
              color: colors.accent,
            ),
            const SizedBox(width: AppSpacing.tight),
            Text(
              expanded ? 'Show less' : '+$hiddenCount lines',
              style: monoStyle(
                color: colors.accent,
                fontSize: AppFontSizes.caption,
                fontWeight: AppWeights.body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileChangeBlock extends StatelessWidget {
  const _FileChangeBlock({
    required this.change,
    required this.sessionCwd,
    this.onOpen,
  });

  final SessionActivityChange change;
  final String sessionCwd;
  final void Function(String path)? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = switch (change.kind) {
      'added' || 'add' || 'create' => MeshPillTone.success,
      'deleted' || 'delete' || 'remove' => MeshPillTone.danger,
      'moved' || 'move' || 'rename' => MeshPillTone.info,
      _ => MeshPillTone.neutral,
    };
    final isDeleted = switch (change.kind) {
      'deleted' || 'delete' || 'remove' => true,
      _ => false,
    };
    final canOpen = onOpen != null && !isDeleted;
    final pathRow = Row(
      children: [
        Icon(
          Icons.description_rounded,
          size: AppSizes.compactIcon,
          color: colors.textSecondary,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            _relativeSessionPath(change.path, sessionCwd),
            style:
                monoStyle(
                  color: canOpen ? colors.accent : colors.textPrimary,
                  fontSize: AppFontSizes.code,
                  fontWeight: AppWeights.body,
                ).copyWith(
                  decoration: canOpen ? TextDecoration.underline : null,
                  decorationColor: canOpen ? colors.accent : null,
                ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        MeshPill(label: change.kind, tone: tone, mono: true),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        canOpen
            ? InkWell(
                onTap: () => onOpen!(change.path),
                borderRadius: BorderRadius.circular(AppRadii.hover),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                  child: pathRow,
                ),
              )
            : pathRow,
        if ((change.movePath ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(
              top: AppSpacing.xs,
              bottom: AppSpacing.sm,
              left: AppSpacing.xl,
            ),
            child: Text(
              'Moved from ${_relativeSessionPath(change.movePath!, sessionCwd)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          )
        else
          const SizedBox(height: AppSpacing.sm),
        DiffView(diff: change.diff),
      ],
    );
  }
}

class _InlineFileChangeRow extends StatelessWidget {
  const _InlineFileChangeRow({
    required this.change,
    required this.sessionCwd,
    this.onOpen,
  });

  final SessionActivityChange change;
  final String sessionCwd;
  final void Function(String path)? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = switch (change.kind) {
      'added' || 'add' || 'create' => MeshPillTone.success,
      'deleted' || 'delete' || 'remove' => MeshPillTone.danger,
      'moved' || 'move' || 'rename' => MeshPillTone.info,
      _ => MeshPillTone.neutral,
    };
    final isDeleted = switch (change.kind) {
      'deleted' || 'delete' || 'remove' => true,
      _ => false,
    };
    final canOpen = onOpen != null && !isDeleted;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.description_rounded,
            size: AppSizes.compactIcon,
            color: colors.textTertiary,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              _relativeSessionPath(change.path, sessionCwd),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  monoStyle(
                    color: canOpen ? colors.accent : colors.textPrimary,
                    fontSize: AppFontSizes.code,
                    fontWeight: AppWeights.body,
                  ).copyWith(
                    decoration: canOpen ? TextDecoration.underline : null,
                    decorationColor: canOpen ? colors.accent : null,
                  ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          MeshPill(label: change.kind, tone: tone, mono: true),
        ],
      ),
    );

    if (!canOpen) {
      return row;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onOpen!(change.path),
        borderRadius: AppShapes.badge,
        child: row,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: context.colors.textSecondary),
    );
    final valueWidget = SelectableText(
      value,
      style: Theme.of(context).textTheme.bodyMedium,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 500
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: labelWidget),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(flex: 3, child: valueWidget),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  labelWidget,
                  const SizedBox(height: AppSpacing.xs),
                  valueWidget,
                ],
              ),
      ),
    );
  }
}

class _SessionRuntimeDetails extends StatelessWidget {
  const _SessionRuntimeDetails({required this.runtime});

  final SessionRuntimeSummary runtime;

  @override
  Widget build(BuildContext context) {
    final runtimeDetails = <({String label, String value})>[
      (label: 'Model', value: runtimeValue(runtime.model)),
      if ((runtime.modelProvider ?? '').isNotEmpty &&
          runtime.modelProvider != 'openai')
        (label: 'Service', value: runtime.modelProvider!),
      (label: 'Speed', value: runtimeServiceTierValue(runtime.serviceTier)),
      (label: 'Thinking', value: runtimeValue(runtime.reasoningEffort)),
      (label: 'Approval', value: runtimeValue(runtime.approvalPolicy)),
      (label: 'Sandbox', value: runtimeValue(runtime.sandboxMode)),
      (label: 'Network', value: runtimeNetworkValue(runtime.networkAccess)),
    ];

    if ((runtime.personality ?? '').isNotEmpty) {
      runtimeDetails.add((label: 'Style', value: runtime.personality!));
    }
    if ((runtime.summaryMode ?? '').isNotEmpty) {
      runtimeDetails.add((label: 'Summary', value: runtime.summaryMode!));
    }

    final telemetry = runtime.telemetry;
    final contextDetails = telemetry?.contextWindow == null
        ? const <({String label, String value})>[]
        : <({String label, String value})>[
            (
              label: 'Window',
              value: _formatTokenWindow(telemetry!.contextWindow!),
            ),
            (
              label: 'Messages',
              value: '${telemetry.contextWindow!.messagesLength}',
            ),
            if (telemetry.contextWindow!.conversationTokens != null)
              (
                label: 'Conversation',
                value: '${telemetry.contextWindow!.conversationTokens!} tokens',
              ),
            if (telemetry.contextWindow!.systemTokens != null)
              (
                label: 'System',
                value: '${telemetry.contextWindow!.systemTokens!} tokens',
              ),
            if (telemetry.contextWindow!.toolDefinitionsTokens != null)
              (
                label: 'Tools',
                value:
                    '${telemetry.contextWindow!.toolDefinitionsTokens!} tokens',
              ),
          ];
    final usageDetails = telemetry?.lastUsage == null
        ? const <({String label, String value})>[]
        : <({String label, String value})>[
            if ((telemetry!.lastUsage!.model ?? '').isNotEmpty)
              (label: 'Model', value: telemetry.lastUsage!.model!),
            if (telemetry.lastUsage!.inputTokens != null)
              (label: 'Input', value: '${telemetry.lastUsage!.inputTokens}'),
            if (telemetry.lastUsage!.outputTokens != null)
              (label: 'Output', value: '${telemetry.lastUsage!.outputTokens}'),
            if (telemetry.lastUsage!.reasoningTokens != null)
              (
                label: 'Thinking',
                value: '${telemetry.lastUsage!.reasoningTokens}',
              ),
            if (telemetry.lastUsage!.durationMs != null)
              (
                label: 'Duration',
                value: _formatDurationMs(telemetry.lastUsage!.durationMs!),
              ),
            if (telemetry.lastUsage!.ttftMs != null)
              (
                label: 'TTFT',
                value: _formatDurationMs(telemetry.lastUsage!.ttftMs!),
              ),
            if (telemetry.lastUsage!.cacheReadTokens != null)
              (
                label: 'Cache read',
                value: '${telemetry.lastUsage!.cacheReadTokens}',
              ),
            if (telemetry.lastUsage!.cacheWriteTokens != null)
              (
                label: 'Cache write',
                value: '${telemetry.lastUsage!.cacheWriteTokens}',
              ),
          ];
    final compactionDetails = telemetry?.compaction == null
        ? const <({String label, String value})>[]
        : <({String label, String value})>[
            (label: 'Status', value: _titleCase(telemetry!.compaction!.status)),
            if (telemetry.compaction!.tokensRemoved != null)
              (
                label: 'Tokens removed',
                value: '${telemetry.compaction!.tokensRemoved}',
              ),
            if (telemetry.compaction!.messagesRemoved != null)
              (
                label: 'Messages removed',
                value: '${telemetry.compaction!.messagesRemoved}',
              ),
            if (telemetry.compaction!.durationMs != null)
              (
                label: 'Duration',
                value: _formatDurationMs(telemetry.compaction!.durationMs!),
              ),
            if ((telemetry.compaction!.model ?? '').isNotEmpty)
              (label: 'Model', value: telemetry.compaction!.model!),
            if ((telemetry.compaction!.error ?? '').isNotEmpty)
              (label: 'Error', value: telemetry.compaction!.error!),
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final detail in runtimeDetails)
          _DetailRow(label: detail.label, value: detail.value),
        if (contextDetails.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.tight),
          _RuntimeExpansionSection(title: 'Context', details: contextDetails),
        ],
        if (usageDetails.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          _RuntimeExpansionSection(title: 'Last usage', details: usageDetails),
        ],
        if (compactionDetails.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          _RuntimeExpansionSection(
            title: 'Compaction',
            details: compactionDetails,
          ),
        ],
      ],
    );
  }
}

class _RuntimeExpansionSection extends StatelessWidget {
  const _RuntimeExpansionSection({required this.title, required this.details});

  final String title;
  final List<({String label, String value})> details;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: AppSpacing.tight),
      visualDensity: VisualDensity.compact,
      iconColor: colors.textSecondary,
      collapsedIconColor: colors.textSecondary,
      title: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: colors.textPrimary,
          fontWeight: AppWeights.title,
        ),
      ),

      children: [
        for (final detail in details)
          _DetailRow(label: detail.label, value: detail.value),
      ],
    );
  }
}

String _formatTokenWindow(SessionContextWindowSummary summary) {
  final percent = summary.usageFraction == null
      ? null
      : (summary.usageFraction! * 100).clamp(0, 999).round();
  final current = summary.currentTokens;
  final base = current == null
      ? '?/${summary.tokenLimit} tokens'
      : '$current/${summary.tokenLimit} tokens';
  return percent == null ? base : '$base ($percent%)';
}

String _formatDurationMs(int value) {
  if (value >= 1000) {
    final seconds = value / 1000;
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}s';
  }
  return '${value}ms';
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

String _relativeSessionPath(String fullPath, String sessionCwd) {
  if (fullPath.isEmpty) {
    return fullPath;
  }
  if (fullPath == sessionCwd) {
    return '.';
  }
  final prefix = '$sessionCwd/';
  if (fullPath.startsWith(prefix)) {
    return fullPath.substring(prefix.length);
  }
  return fullPath;
}

String _activityFileSummary(
  List<SessionActivityChange> changes,
  String sessionCwd,
) {
  if (changes.isEmpty) {
    return 'Waiting for file changes.';
  }

  final uniqueChanges = _uniqueFileChangePaths(changes);
  final labels = uniqueChanges
      .take(3)
      .map((change) => _relativeSessionPath(change.path, sessionCwd))
      .toList();
  final remainder = uniqueChanges.length - labels.length;
  if (remainder > 0) {
    labels.add('+$remainder more');
  }
  return labels.join('  •  ');
}

String _commandActivityTitle(SessionActivity activity) {
  return _commandTitleParts(
        activity.command ?? '',
        activity.status,
      )?.plainText ??
      _commandStatusTitle(activity.status, '');
}

String _contextCompactionTitle(SessionActivity activity) {
  return switch (activity.status) {
    'completed' => 'Context compacted',
    'failed' => 'Context compaction failed',
    'declined' => 'Context compaction declined',
    _ => 'Compacting context',
  };
}

String _contextCompactionSubtitle(SessionActivity activity) {
  return switch (activity.status) {
    'completed' => 'Older conversation history was summarized to free context.',
    'failed' => 'Older conversation history could not be summarized.',
    'declined' => 'Context compaction did not run.',
    _ => 'Summarizing older conversation history to free context.',
  };
}

String _imageGenerationTitle(SessionActivity activity) {
  return switch (activity.status) {
    'completed' => 'Generated image',
    'failed' => 'Image generation failed',
    'declined' => 'Image generation declined',
    _ => 'Generating image',
  };
}

String _activityActionVerb(
  String status, {
  required String completed,
  required String progress,
  required String infinitive,
}) {
  return switch (status) {
    'failed' => 'Failed to $infinitive',
    'declined' => 'Did not $infinitive',
    'in_progress' => progress,
    _ => completed,
  };
}

_CommandTitleParts? _commandTitleParts(String rawCommand, String status) {
  final command = _displayCommandText(rawCommand);
  if (command.isEmpty) {
    return null;
  }
  return _friendlyCommandTitleParts(command, status) ??
      _CommandTitleParts(verb: _commandStatusVerb(status), command: command);
}

String _commandStatusVerb(String status) {
  return switch (status) {
    'failed' => 'failed',
    'declined' => 'declined',
    'in_progress' => 'running',
    _ => 'ran',
  };
}

String _commandStatusTitle(String status, String command) {
  final verb = _commandStatusVerb(status);
  final target = command.trim();
  if (target.isEmpty) {
    return switch (status) {
      'failed' => 'command failed',
      'declined' => 'command declined',
      _ => '$verb command',
    };
  }
  return '$verb $target';
}

_CommandTitleParts? _friendlyCommandTitleParts(String command, String status) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final words = _splitShellWords(trimmed);
  if (words.isEmpty) {
    return null;
  }
  final program = _commandProgramName(words.first);
  return switch (program) {
    'sed' => _friendlySedCommandTitle(words, status),
    'rg' => _friendlySearchCommandTitle(words, status, filesFlag: '--files'),
    'grep' => _friendlySearchCommandTitle(words, status),
    'ls' => _friendlyListCommandTitle(words, status),
    'cat' => _friendlyCatCommandTitle(words, status),
    _ => null,
  };
}

_CommandTitleParts? _friendlySedCommandTitle(
  List<String> words,
  String status,
) {
  String? script;
  var pathStart = 1;
  for (var index = 1; index < words.length; index += 1) {
    final word = words[index];
    if (_isShellControlWord(word)) {
      break;
    }
    if (word == '-n') {
      continue;
    }
    if (word == '-e' && index + 1 < words.length) {
      script = words[index + 1];
      pathStart = index + 2;
      break;
    }
    if (word.startsWith('-')) {
      continue;
    }
    script = word;
    pathStart = index + 1;
    break;
  }
  final match = script == null
      ? null
      : RegExp(r'^(\d+)(?:,(\d+))?p$').firstMatch(script);
  if (match == null) {
    return null;
  }
  final start = match.group(1)!;
  final end = match.group(2);
  final lineLabel = end == null || end == start
      ? 'line $start'
      : 'lines $start-$end';
  final target = _firstCommandPath(words, pathStart);
  final command = target == null
      ? '"$lineLabel"'
      : '"${_friendlyPathLabel(target)} $lineLabel"';
  return _CommandTitleParts(
    verb: _actionVerb(status, completed: 'viewed', progress: 'viewing'),
    command: command,
  );
}

_CommandTitleParts? _friendlySearchCommandTitle(
  List<String> words,
  String status, {
  String? filesFlag,
}) {
  final targets = <String>[];
  var sawFilesFlag = false;
  String? query;

  for (var index = 1; index < words.length; index += 1) {
    final word = words[index];
    if (_isShellControlWord(word)) {
      break;
    }
    if (filesFlag != null && word == filesFlag) {
      sawFilesFlag = true;
      continue;
    }
    if (word == '-e' || word == '--regexp') {
      if (index + 1 < words.length) {
        query = words[index + 1];
        index += 1;
      }
      continue;
    }
    if (word.startsWith('--regexp=')) {
      query = word.substring('--regexp='.length);
      continue;
    }
    if (_commandOptionTakesValue(word)) {
      index += 1;
      continue;
    }
    if (word.startsWith('-')) {
      continue;
    }
    if (query == null) {
      query = word;
    } else {
      targets.add(word);
    }
  }

  if ((query == null || query.trim().isEmpty) && sawFilesFlag) {
    final targetLabel = _friendlyTargetLabel(targets);
    return _CommandTitleParts(
      verb: _actionVerb(status, completed: 'listed', progress: 'listing'),
      command: targetLabel.isEmpty ? 'files' : 'files in $targetLabel',
    );
  }
  if (query == null || query.trim().isEmpty) {
    return null;
  }

  final queryLabel = _friendlySnippet(query, 44);
  final targetLabel = _friendlyTargetLabel(targets);
  return _CommandTitleParts(
    verb: _actionVerb(status, completed: 'searched', progress: 'searching'),
    command: targetLabel.isEmpty
        ? 'for "$queryLabel"'
        : 'for "$queryLabel" in $targetLabel',
  );
}

_CommandTitleParts? _friendlyListCommandTitle(
  List<String> words,
  String status,
) {
  final targets = _commandPathArgs(words, start: 1);
  final targetLabel = _friendlyTargetLabel(targets);
  return _CommandTitleParts(
    verb: _actionVerb(status, completed: 'listed', progress: 'listing'),
    command: targetLabel.isEmpty ? 'files' : 'files in $targetLabel',
  );
}

_CommandTitleParts? _friendlyCatCommandTitle(
  List<String> words,
  String status,
) {
  final target = _firstCommandPath(words, 1);
  if (target == null) {
    return null;
  }
  return _CommandTitleParts(
    verb: _actionVerb(status, completed: 'viewed', progress: 'viewing'),
    command: '"${_friendlyPathLabel(target)}"',
  );
}

String _actionVerb(
  String status, {
  required String completed,
  required String progress,
}) {
  return switch (status) {
    'failed' => 'failed $progress',
    'declined' => 'declined $progress',
    'in_progress' => progress,
    _ => completed,
  };
}

String _commandProgramName(String value) {
  return value.replaceAll('\\', '/').split('/').last;
}

bool _isShellControlWord(String value) {
  return value == '|' ||
      value == '&&' ||
      value == '||' ||
      value == ';' ||
      value == '>' ||
      value == '>>' ||
      value == '<' ||
      value == '2>' ||
      value == '2>&1';
}

bool _commandOptionTakesValue(String value) {
  const options = {
    '-A',
    '-B',
    '-C',
    '-g',
    '-m',
    '-t',
    '--after-context',
    '--before-context',
    '--context',
    '--glob',
    '--max-count',
    '--type',
  };
  return options.contains(value);
}

String? _firstCommandPath(List<String> words, int start) {
  final args = _commandPathArgs(words, start: start);
  return args.isEmpty ? null : args.first;
}

List<String> _commandPathArgs(List<String> words, {required int start}) {
  final args = <String>[];
  for (var index = start; index < words.length; index += 1) {
    final word = words[index];
    if (_isShellControlWord(word)) {
      break;
    }
    if (_commandOptionTakesValue(word)) {
      index += 1;
      continue;
    }
    if (word.startsWith('-')) {
      continue;
    }
    args.add(word);
  }
  return args;
}

String _friendlyTargetLabel(List<String> targets) {
  if (targets.isEmpty) {
    return '';
  }
  final labels = targets
      .take(2)
      .map(_friendlyPathLabel)
      .where((label) => label.isNotEmpty)
      .toList();
  final remainder = targets.length - labels.length;
  if (remainder > 0) {
    labels.add('+$remainder more');
  }
  return labels.join(', ');
}

String _friendlyPathLabel(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  if (trimmed == '.' || trimmed == '..') {
    return trimmed;
  }
  final normalized = trimmed.replaceAll('\\', '/');
  final withoutTrailingSlash = normalized.replaceFirst(RegExp(r'/+$'), '');
  final parts = withoutTrailingSlash
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    return _friendlySnippet(trimmed, 36);
  }
  return _friendlySnippet(parts.last, 36);
}

String _friendlySnippet(String value, int maxLength) {
  final singleLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (singleLine.length <= maxLength) {
    return singleLine;
  }
  if (maxLength <= 3) {
    return singleLine.substring(0, maxLength);
  }
  return '${singleLine.substring(0, maxLength - 3)}...';
}

String _displayCommandText(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final words = _splitShellWords(trimmed);
  if (words.length >= 3 &&
      _isShellProgram(words.first) &&
      _isShellCommandFlag(words[1])) {
    final inner = words.sublist(2).join(' ').trim();
    if (inner.isNotEmpty) {
      return inner;
    }
  }
  return trimmed;
}

bool _isShellProgram(String value) {
  final name = value.replaceAll('\\', '/').split('/').last;
  return name == 'bash' || name == 'sh' || name == 'zsh' || name == 'dash';
}

bool _isShellCommandFlag(String value) => value == '-lc' || value == '-c';

List<String> _splitShellWords(String input) {
  final words = <String>[];
  final buffer = StringBuffer();
  var inSingleQuote = false;
  var inDoubleQuote = false;
  var escaping = false;

  void flush() {
    if (buffer.length == 0) {
      return;
    }
    words.add(buffer.toString());
    buffer.clear();
  }

  for (var index = 0; index < input.length; index += 1) {
    final char = input[index];
    if (escaping) {
      buffer.write(char);
      escaping = false;
      continue;
    }
    if (char == '\\' && !inSingleQuote) {
      escaping = true;
      continue;
    }
    if (inSingleQuote) {
      if (char == "'") {
        inSingleQuote = false;
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (inDoubleQuote) {
      if (char == '"') {
        inDoubleQuote = false;
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == "'") {
      inSingleQuote = true;
      continue;
    }
    if (char == '"') {
      inDoubleQuote = true;
      continue;
    }
    if (char.trim().isEmpty) {
      flush();
      continue;
    }
    buffer.write(char);
  }

  if (escaping) {
    buffer.write('\\');
  }
  flush();
  return words;
}

String _turnDiffActivityTitle(SessionActivity activity) {
  final diff = (activity.diff ?? '').trim();
  if (diff.isEmpty) {
    return activity.status == 'completed'
        ? 'no live diff captured'
        : 'tracking live diff';
  }
  final lines = _diffLineCount(diff);
  final noun = lines == 1 ? 'line' : 'lines';
  return 'live diff · $lines $noun';
}

int _diffLineCount(String diff) {
  if (diff.isEmpty) return 0;
  return '\n'.allMatches(diff).length + 1;
}

String _fileChangeActivityTitle(SessionActivity activity) {
  final count = _fileChangeFileCount(activity.changes);
  if (count == 0) {
    return switch (activity.status) {
      'failed' => 'File editing failed',
      'declined' => 'File editing declined',
      'in_progress' => 'Editing files',
      _ => 'No file changes',
    };
  }
  final noun = count == 1 ? 'file' : 'files';
  return switch (activity.status) {
    'failed' => 'Could not edit $count $noun',
    'declined' => 'Did not edit $count $noun',
    'in_progress' => 'Editing $count $noun',
    _ => 'Edited $count $noun',
  };
}

int _fileChangeFileCount(List<SessionActivityChange> changes) {
  return _uniqueFileChangePaths(changes).length;
}

List<SessionActivityChange> _uniqueFileChangePaths(
  List<SessionActivityChange> changes,
) {
  final seen = <String>{};
  final unique = <SessionActivityChange>[];
  for (final change in changes) {
    final key = change.path.trim();
    if (key.isEmpty || seen.contains(key)) continue;
    seen.add(key);
    unique.add(change);
  }
  return unique;
}

String _formatDuration(int durationMs) {
  if (durationMs >= 1000) {
    final seconds = durationMs / 1000;
    return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}s';
  }
  return '${durationMs}ms';
}

bool _sameCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatMessageTime(DateTime value) {
  final now = DateTime.now();
  final time =
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  if (_sameCalendarDay(value, now)) {
    return time;
  }
  final diffDays = now.difference(value).inDays;
  if (diffDays < 7 && diffDays >= 0) {
    return '${_weekdayShort(value.weekday)} · $time';
  }
  if (value.year == now.year) {
    return '${_monthShort(value.month)} ${value.day} · $time';
  }
  return '${_monthShort(value.month)} ${value.day} ${value.year}';
}

String _formatDaySeparator(DateTime value) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(value.year, value.month, value.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (value.year == now.year) {
    return '${_weekdayShort(value.weekday)}, ${_monthShort(value.month)} ${value.day}';
  }
  return '${_monthShort(value.month)} ${value.day}, ${value.year}';
}

String _weekdayShort(int weekday) {
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return names[(weekday - 1).clamp(0, 6)];
}

String _monthShort(int month) {
  const names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return names[(month - 1).clamp(0, 11)];
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
      child: Row(
        children: [
          Expanded(child: Divider(color: colors.border, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.textTertiary,
                fontWeight: AppWeights.emphasis,
                letterSpacing: AppLetterSpacing.caps,
              ),
            ),
          ),
          Expanded(child: Divider(color: colors.border, height: 1)),
        ],
      ),
    );
  }
}

/// Shown when the session has loaded (no longer _loading) but has no
/// messages yet — typically the first 0.5-5 s of a newly created session
/// while the agent initialises.
class _SessionWaitingState extends StatelessWidget {
  const _SessionWaitingState({this.onStop});

  /// Called when the user wants to interrupt the agent while it is starting.
  /// Pass null when the provider does not support interrupt.
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LivePulse(color: colors.accent),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Waiting for agent\u2026',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colors.textSecondary,
              fontWeight: AppWeights.emphasis,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Your message was sent. The agent is starting.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
          if (onStop != null) ...[
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: onStop,
              icon: const Icon(
                Icons.stop_circle_rounded,
                size: AppSizes.inlineIcon,
              ),
              label: const Text('Stop agent'),
              style: AppControlStyles.danger(colors),
            ),
          ],
        ],
      ),
    );
  }
}
