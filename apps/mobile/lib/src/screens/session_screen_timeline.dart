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
        if (visibleReasoning.trim().isNotEmpty)
          ThinkingBlock(visibleReasoning),
        if (visibleText.trim().isNotEmpty)
          TextBlock(visibleText),
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
}

class _LiveAssistantBubble extends StatelessWidget {
  const _LiveAssistantBubble({
    required this.host,
    required this.api,
    required this.message,
    this.onOpenFile,
  });

  final HostProfile host;
  final ApiClient api;
  final ValueListenable<_LiveAssistantMessageState?> message;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_LiveAssistantMessageState?>(
      valueListenable: message,
      builder: (context, liveMessage, _) {
        if (liveMessage == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _MessageBubble(
            host: host,
            api: api,
            message: liveMessage.toMessage(),
            live: liveMessage.live,
            onOpenFile: onOpenFile,
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
  });

  final String reasoning;
  /// Whether the assistant turn is still streaming.
  final bool live;
  /// True when the message already has answer text, so reasoning should shrink
  /// back to a disclosure row by default.
  final bool collapsedByDefault;
  final void Function(String path)? onOpenFile;

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
    if (!oldWidget.collapsedByDefault && widget.collapsedByDefault && _expanded) {
      setState(() => _expanded = false);
      return;
    }
    if (oldWidget.collapsedByDefault && !widget.collapsedByDefault && !_expanded) {
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
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 6),
              child: Row(
                children: [
                  if (widget.live)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: LivePulse(color: colors.textSecondary),
                    )
                  else ...[
                    Icon(
                      Icons.psychology_outlined,
                      size: 16,
                      color: colors.textSecondary,
                    ),
                    const SizedBox(width: 6),
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
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                    color: colors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 2, 0, 10),
              child: _ReasoningTextBody(
                text: widget.reasoning.trimRight(),
                textColor: colors.textPrimary,
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
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: AppShapes.input,
              border: Border.all(color: colors.border),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const LivePulse(),
                  const SizedBox(width: 10),
                  Text(
                    'Working',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                  const SizedBox(width: 10),
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
  const _ProviderWarningRow({required this.event});

  final LiveEvent event;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final level = (event.level ?? 'warning').toLowerCase();
    final tone = switch (level) {
      'error' => MeshPillTone.danger,
      'info' => MeshPillTone.info,
      _ => MeshPillTone.warning,
    };
    final icon = switch (level) {
      'error' => Icons.error_outline_rounded,
      'info' => Icons.info_outline_rounded,
      _ => Icons.warning_amber_rounded,
    };
    final accent = switch (level) {
      'error' => colors.danger,
      'info' => colors.info,
      _ => colors.warning,
    };
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    MeshPill(label: 'Agent notice', tone: tone, icon: icon),
                    if ((event.source ?? '').isNotEmpty)
                      MeshPill(
                        label: event.source!,
                        tone: MeshPillTone.neutral,
                        mono: true,
                      ),
                    if ((event.code ?? '').isNotEmpty)
                      MeshPill(
                        label: event.code!,
                        tone: MeshPillTone.neutral,
                        mono: true,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  event.message ?? '',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ),
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
      padding: const EdgeInsets.only(left: 4, right: 4, bottom: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
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
                    horizontal: 4,
                    vertical: 7,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: colors.surfaceMuted.withValues(alpha: 0.72),
                          borderRadius: AppShapes.iconWell,
                          border: Border.all(
                            color: colors.border.withValues(alpha: 0.5),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.route_rounded,
                          size: 16,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 10),
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
                              const SizedBox(height: 2),
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
                      const SizedBox(width: 8),
                      MeshStatusBadge(
                        label: '$completedCount/${steps.length}',
                        tone: MeshStatusTone.neutral,
                        icon: Icons.checklist_rounded,
                        compact: true,
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: colors.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topLeft,
              child: _expanded
                  ? Padding(
                      padding: const EdgeInsets.only(left: 44, top: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var index = 0;
                              index < steps.length;
                              index += 1) ...[
                            if (index > 0) const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _planStepIcon(steps[index].status),
                                  size: 17,
                                  color: _planStepColor(
                                    colors,
                                    steps[index].status,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    steps[index].step,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: colors.textPrimary,
                                          fontWeight: FontWeight.w600,
                                          height: 1.35,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 8),
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
    if (_shouldShowThreadStatus(thread)) {
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: pills),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              details.join(' • '),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _shouldShowThreadStatus(LiveEvent? event) {
    if (event == null) {
      return false;
    }
    final status = (event.status ?? '').trim();
    if (status.isEmpty) {
      return false;
    }
    return status != 'running' ||
        (event.message?.isNotEmpty ?? false) ||
        (event.pendingActionKind?.isNotEmpty ?? false);
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
    return whole ? '${seconds.toStringAsFixed(0)}s' : '${seconds.toStringAsFixed(1)}s';
  }
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
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: AppShapes.input,
          border: Border.all(color: colors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.cloud_sync_rounded,
                    color: colors.accent,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
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
                        const SizedBox(height: 2),
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
                  const SizedBox(width: 8),
                  MeshPill(
                    label: pendingSendStateLabel(primary.state),
                    tone: _pendingSendStateTone(primary.state),
                    mono: true,
                  ),
                ],
              ),
              const SizedBox(height: 10),
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.host,
    required this.api,
    required this.message,
    this.live = false,
    this.pinned = false,
    this.onTogglePin,
    this.onOpenFile,
  });

  final HostProfile host;
  final ApiClient api;
  final SessionMessage message;
  final bool live;
  final bool pinned;
  final VoidCallback? onTogglePin;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
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
      'assistant' => colors.assistantBubble,
      _ => colors.surfaceMuted,
    };
    final textColor = isUser ? colors.userBubbleOn : colors.textPrimary;
    final messagePadding = isAssistant
        ? const EdgeInsets.fromLTRB(16, 13, 16, 14)
        : const EdgeInsets.fromLTRB(16, 12, 16, 14);
    final bubbleBorderColor = isAssistant
        ? live
              ? colors.accent.withValues(alpha: 0.36)
              : colors.assistantBubbleBorder
        : live
        ? colors.accent
        : colors.userBubble;
    final phaseLabel = live
        ? 'Writing'
        : message.phase == 'commentary'
        ? 'Progress'
        : null;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(bottom: isAssistant ? 14 : 10),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isAssistant ? 680 : 560),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(isAssistant ? 16 : 20),
              border: Border.all(
                color: bubbleBorderColor,
                width: live ? 1.4 : 1,
              ),
            ),
            child: Padding(
              padding: messagePadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (phaseLabel != null && hasAnswer)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          if (live) ...[
                            const LivePulse(),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            phaseLabel,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: isAssistant
                                      ? colors.textTertiary
                                      : textColor.withValues(alpha: 0.68),
                                  fontWeight: AppWeights.title,
                                  letterSpacing: 0.2,
                                ),
                          ),
                        ],
                      ),
                    ),
                  for (final block in message.content)
                    if (block is ThinkingBlock)
                      Padding(
                        padding: EdgeInsets.only(bottom: hasAnswer ? 10 : 0),
                        child: _ReasoningBlock(
                          reasoning: block.thinking,
                          live: live,
                          collapsedByDefault: hasAnswer,
                          onOpenFile: onOpenFile,
                        ),
                      )
                    else if (block is TextBlock)
                      if (isAssistant)
                        _MarkdownMessageBody(
                          text: block.text,
                          textColor: textColor,
                          onOpenFile: onOpenFile,
                        )
                      else
                        _LinkifiedSelectableText(
                          text: block.text,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            height: 1.45,
                          ),
                          linkColor: colors.accent,
                        ),
                  if (message.attachments.isNotEmpty) ...[
                    _MessageAttachmentsSection(
                      host: host,
                      api: api,
                      attachments: message.attachments,
                    ),
                    if (!hasTextBlocks && hasText)
                      const SizedBox(height: 10),
                  ],
                  if (!hasTextBlocks && hasText)
                    if (isAssistant)
                      _MarkdownMessageBody(
                        text: message.text,
                        textColor: textColor,
                        onOpenFile: onOpenFile,
                      )
                    else
                      _LinkifiedSelectableText(
                        text: message.text,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          height: 1.45,
                        ),
                        linkColor: colors.accent,
                      ),
                  if (canPin || hasText)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _formatMessageTime(message.createdAt),
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: isUser
                                        ? textColor.withValues(alpha: 0.62)
                                        : colors.textTertiary,
                                    fontSize: 10.5,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                            ),
                            if (canPin)
                              _MessagePinButton(
                                pinned: pinned,
                                tone: isUser
                                    ? textColor.withValues(alpha: 0.72)
                                    : colors.textSecondary,
                                accent: colors.warning,
                                onTap: onTogglePin!,
                              ),
                            if (!isUser && hasText)
                              _MessageCopyButton(
                                text: message.text,
                                tone: colors.textSecondary,
                                accent: colors.accent,
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
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
    required this.attachments,
  });

  final HostProfile host;
  final ApiClient api;
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
    required this.attachment,
  });

  final HostProfile host;
  final ApiClient api;
  final SessionMessageAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.isImage && attachment.url != null) {
      return _MessageImageAttachmentTile(url: attachment.url!);
    }
    if (attachment.isLocalImage && attachment.path != null) {
      return _LocalImageAttachmentTile(
        host: host,
        api: api,
        path: attachment.path!,
      );
    }
    return const SizedBox.shrink();
  }
}

class _MessageImageAttachmentTile extends StatefulWidget {
  const _MessageImageAttachmentTile({required this.url});

  final String url;

  @override
  State<_MessageImageAttachmentTile> createState() =>
      _MessageImageAttachmentTileState();
}

class _MessageImageAttachmentTileState
    extends State<_MessageImageAttachmentTile> {
  Uint8List? _dataUrlBytes;

  @override
  void initState() {
    super.initState();
    _decodeDataUrlIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _MessageImageAttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _decodeDataUrlIfNeeded();
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
    final colors = context.colors;
    final imageProvider = _imageProvider();
    final heroTag = _messageImageHeroTag(widget.url);
    return _ImageAttachmentCard(
      imageProvider: imageProvider,
      heroTag: heroTag,
      fallback: _AttachmentLoadError(colors: colors),
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
    required this.path,
  });

  final HostProfile host;
  final ApiClient api;
  final String path;

  @override
  State<_LocalImageAttachmentTile> createState() =>
      _LocalImageAttachmentTileState();
}

class _LocalImageAttachmentTileState extends State<_LocalImageAttachmentTile> {
  File? _file;
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
        oldWidget.path != widget.path) {
      _load();
    }
  }

  Future<void> _load() async {
    final gen = ++_loadGeneration;
    setState(() {
      _file = null;
      _error = null;
    });
    try {
      final file = await ImageBlobCacheStore.instance.load(
        host: widget.host,
        path: widget.path,
        api: widget.api,
      );
      if (!mounted || gen != _loadGeneration) {
        return;
      }
      setState(() => _file = file);
    } catch (error) {
      if (!mounted || gen != _loadGeneration) {
        return;
      }
      setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final heroTag = _messageImageHeroTag('${widget.host.id}:${widget.path}');
    final file = _file;
    final imageProvider = file == null ? null : FileImage(file);
    final hasFailed = _error != null;
    return _ImageAttachmentCard(
      imageProvider: imageProvider,
      heroTag: heroTag,
      fallback: _LocalImageFallback(
        path: widget.path,
        colors: colors,
        loading: !hasFailed && imageProvider == null,
      ),
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

class _ImageAttachmentCard extends StatelessWidget {
  const _ImageAttachmentCard({
    required this.imageProvider,
    required this.heroTag,
    required this.fallback,
    required this.onOpen,
  });

  final ImageProvider<Object>? imageProvider;
  final String heroTag;
  final Widget fallback;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final imageChild = imageProvider == null
        ? fallback
        : Hero(
            tag: heroTag,
            child: Image(
              image: imageProvider!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => fallback,
            ),
          );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onOpen,
            child: AspectRatio(aspectRatio: 1.35, child: imageChild),
          ),
        ),
      ),
    );
  }
}

class _LocalImageFallback extends StatelessWidget {
  const _LocalImageFallback({
    required this.path,
    required this.colors,
    this.loading = false,
  });

  final String path;
  final AppColors colors;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surfaceMuted,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(
            loading ? Icons.downloading_rounded : Icons.image_rounded,
            color: colors.accent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  loading ? 'Loading image...' : _basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: AppWeights.emphasis),
                ),
                const SizedBox(height: 2),
                Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentLoadError extends StatelessWidget {
  const _AttachmentLoadError({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: colors.surfaceMuted,
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_rounded,
        color: colors.textTertiary,
        size: 28,
      ),
    );
  }
}

class _MessageCopyButton extends StatefulWidget {
  const _MessageCopyButton({
    required this.text,
    required this.tone,
    required this.accent,
  });

  final String text;
  final Color tone;
  final Color accent;

  @override
  State<_MessageCopyButton> createState() => _MessageCopyButtonState();
}

class _MessageCopyButtonState extends State<_MessageCopyButton> {
  bool _copied = false;

  Future<void> _handle() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = _copied ? widget.accent : widget.tone;
    return InkWell(
      onTap: _handle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 13,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? 'Copied' : 'Copy',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: AppWeights.emphasis,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessagePinButton extends StatelessWidget {
  const _MessagePinButton({
    required this.pinned,
    required this.tone,
    required this.accent,
    required this.onTap,
  });

  final bool pinned;
  final Color tone;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = pinned ? accent : tone;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              size: 13,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              pinned ? 'Pinned' : 'Pin',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: AppWeights.emphasis,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkdownMessageBody extends StatelessWidget {
  const _MarkdownMessageBody({
    required this.text,
    required this.textColor,
    this.onOpenFile,
  });

  final String text;
  final Color textColor;
  final void Function(String path)? onOpenFile;

  @override
  Widget build(BuildContext context) {
    return MarkdownContent(
      text: text,
      textColor: textColor,
      onOpenFile: onOpenFile,
    );
  }
}

class _ReasoningTextBody extends StatelessWidget {
  const _ReasoningTextBody({
    required this.text,
    required this.textColor,
  });

  final String text;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return _LinkifiedSelectableText(
      text: text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: textColor,
        height: 1.5,
      ),
      linkColor: context.colors.accent,
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

Map<String, Object?> _compressDraftImagePayload(Map<String, Object?> payload) {
  final name = payload['name']! as String;
  final mimeType = payload['mimeType']! as String;
  final bytes = payload['bytes']! as Uint8List;

  if (mimeType == 'image/gif') {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final baked = img.bakeOrientation(decoded);
  final longestEdge = math.max(baked.width, baked.height);
  final isPng = mimeType == 'image/png';
  final shouldKeepOriginal =
      longestEdge <= 1800 &&
      bytes.length <= 900 * 1024 &&
      !mimeType.contains('bmp');
  if (shouldKeepOriginal) {
    return <String, Object?>{
      'name': name,
      'mimeType': mimeType,
      'bytes': bytes,
    };
  }

  final resized = longestEdge > 1800
      ? img.copyResize(
          baked,
          width: baked.width >= baked.height ? 1800 : null,
          height: baked.height > baked.width ? 1800 : null,
          interpolation: img.Interpolation.cubic,
        )
      : baked;

  final outputMimeType = isPng ? 'image/png' : 'image/jpeg';
  final encoded = outputMimeType == 'image/png'
      ? Uint8List.fromList(img.encodePng(resized, level: 6))
      : Uint8List.fromList(img.encodeJpg(resized, quality: 84));

  final chosenBytes = encoded.length < bytes.length ? encoded : bytes;
  final chosenMimeType = identical(chosenBytes, encoded)
      ? outputMimeType
      : mimeType;

  return <String, Object?>{
    'name': name,
    'mimeType': chosenMimeType,
    'bytes': chosenBytes,
  };
}

class _LinkifiedSelectableText extends StatefulWidget {
  const _LinkifiedSelectableText({
    required this.text,
    required this.style,
    required this.linkColor,
  });

  final String text;
  final TextStyle? style;
  final Color linkColor;

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
        ..onTap = () => _openLink(context, href);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: raw,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: recognizer,
        ),
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

Future<void> _openLink(BuildContext context, String href) async {
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
  final SessionActivity activity;
  final String sessionCwd;
  final bool defaultCollapsed;
  final void Function(String path)? onOpenFile;
  final void Function(String path)? onBrowsePath;
  final void Function(BrowserPreviewTargetCandidate target)? onOpenBrowserPreview;
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
          const MeshPill(
            label: 'stdin',
            tone: MeshPillTone.info,
            mono: true,
          ),
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
    final command = activity.isCommand
        ? _displayCommandText(activity.command ?? '')
        : activity.isTool && _toolIsCommandActivity(activity)
        ? _displayCommandText(_toolCommandText(activity))
        : '';
    if (command.isEmpty) {
      return null;
    }
    return _CommandTitleParts(
      verb: _commandStatusVerb(activity.status),
      command: command,
    );
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
                            fontSize: 13,
                          )
                        : Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: AppWeights.emphasis,
                          ))
                    ?.copyWith(height: 1.35),
          );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      child: child,
    );
  }

  Widget _activityDetailsPanel(BuildContext context, Widget child) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.58),
          borderRadius: AppShapes.input,
          border: Border.all(color: colors.border.withValues(alpha: 0.52)),
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
    final commandLikeActivity =
        activity.isCommand ||
        (activity.isTool && _toolIsCommandActivity(activity));
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
      'image_generation' => 'Generated image',
      'context_compaction' => 'Context compacted',
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
      'context_compaction' =>
        'Older conversation history was summarized to free context.',
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
        padding: const EdgeInsets.only(bottom: 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: commandLikeActivity
                    ? colors.surface.withValues(alpha: 0.76)
                    : colors.surfaceMuted.withValues(alpha: 0.48),
                shape: RoundedRectangleBorder(
                  borderRadius: AppShapes.input,
                  side: BorderSide(
                    color: commandLikeActivity
                        ? colors.codeBorder.withValues(alpha: 0.76)
                        : colors.border.withValues(alpha: 0.62),
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
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: commandLikeActivity
                                ? colors.surfaceElevated
                                : activity.isCommand || activity.isTool
                                ? colors.surfaceMuted.withValues(alpha: 0.72)
                                : colors.accentMuted.withValues(alpha: 0.68),
                            borderRadius: AppShapes.iconWell,
                            border: Border.all(
                              color: colors.border.withValues(alpha: 0.5),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            activityIcon,
                            size: 16,
                            color: commandLikeActivity
                                ? colors.codeForeground
                                : activity.isCommand || activity.isTool
                                ? colors.textPrimary
                                : colors.accent,
                          ),
                        ),
                        const SizedBox(width: 10),
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
                                        letterSpacing: 0.2,
                                      ),
                                ),
                                const SizedBox(height: 2),
                              ],
                              _buildActivityTitle(
                                context,
                                activity: activity,
                                title: title,
                              ),
                              if (!_cardCollapsed &&
                                  subtitle != null &&
                                  subtitle.isNotEmpty) ...[
                                const SizedBox(height: 4),
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
                          const SizedBox(width: 8),
                          statusBadge,
                        ],
                        const SizedBox(width: 4),
                        Icon(
                          _cardCollapsed
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_up_rounded,
                          size: 18,
                          color: colors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
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
                              const SizedBox(height: 12),
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
                              const SizedBox(height: 12),
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
    final title = _fileChangeActivityTitle(activity, running: _activityRunning);
    final subtitle = _activityFileSummary(changes, sessionCwd);
    final statusBadge = _activityStatusBadge(activity);
    final contextActions = _buildContextActions();

    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Material(
                color: colors.surfaceMuted.withValues(alpha: 0.48),
                shape: RoundedRectangleBorder(
                  borderRadius: AppShapes.input,
                  side: BorderSide(
                    color: colors.border.withValues(alpha: 0.62),
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
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: colors.surfaceMuted.withValues(alpha: 0.72),
                            borderRadius: AppShapes.iconWell,
                            border: Border.all(
                              color: colors.border.withValues(alpha: 0.5),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.edit_note_rounded,
                            size: 16,
                            color: colors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 10),
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
                                      height: 1.25,
                                    ),
                              ),
                              if (subtitle.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      monoStyle(
                                        color: colors.textSecondary,
                                        fontSize: 12,
                                        fontWeight: AppWeights.body,
                                      ).copyWith(height: 1.3),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (statusBadge != null) ...[
                          const SizedBox(width: 8),
                          statusBadge,
                        ],
                        const SizedBox(width: 4),
                        Icon(
                          _cardCollapsed
                              ? Icons.keyboard_arrow_down_rounded
                              : Icons.keyboard_arrow_up_rounded,
                          size: 18,
                          color: colors.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
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
                              const SizedBox(height: 10),
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
                              const SizedBox(height: 8),
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

    if ((activity.terminalInput ?? '').isNotEmpty) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Sent to terminal',
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 11,
              fontWeight: AppWeights.emphasis,
            ).copyWith(letterSpacing: 0.8),
          ),
        ),
      );
      widgets.add(
        SyntaxCodeBlock(text: activity.terminalInput!, language: 'bash'),
      );
      widgets.add(const SizedBox(height: 12));
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
        widgets.add(const SizedBox(height: 6));
        widgets.add(
          _ExpandToggle(
            expanded: _outputExpanded,
            hiddenCount: lines.length - _collapsedLineLimit,
            onToggle: () => setState(() => _outputExpanded = !_outputExpanded),
          ),
        );
      }
    } else if (activity.terminalStatus == 'waiting') {
      widgets.add(_waitingText(context, 'Interactive command is running.'));
    } else {
      widgets.add(_waitingText(context, 'Waiting for command output.'));
    }

    return widgets;
  }

  List<Widget> _buildToolBody(BuildContext context, SessionActivity activity) {
    final widgets = <Widget>[];
    widgets.addAll(_buildToolSemanticBlocks(context, activity));
    if (widgets.isNotEmpty) {
      widgets.add(const SizedBox(height: 12));
    }
    final output = (activity.output ?? '').trimRight();
    final args = _formatActivityValue(activity.toolArgs);
    final result = _formatActivityValue(activity.toolResult);

    if (args.isNotEmpty) {
      widgets.add(_activityCodeBlock(context, 'Arguments', args, 'json'));
      widgets.add(const SizedBox(height: 12));
    }

    if (output.isNotEmpty) {
      widgets.add(_activityCodeBlock(context, 'Output', output, 'text'));
      widgets.add(const SizedBox(height: 12));
    }

    if (result.isNotEmpty) {
      widgets.add(_activityCodeBlock(context, 'Result', result, 'json'));
      widgets.add(const SizedBox(height: 12));
    }

    if (widgets.isEmpty) {
      widgets.add(_waitingText(context, 'Waiting for tool details.'));
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
            fontSize: 11,
            fontWeight: AppWeights.emphasis,
          ).copyWith(letterSpacing: 0.8),
        ),
        const SizedBox(height: 8),
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
        ...rows.expand((row) => [row, const SizedBox(height: 10)]),
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              fontSize: 11,
              fontWeight: AppWeights.emphasis,
            ).copyWith(letterSpacing: 0.8),
          ),
          const SizedBox(height: 6),
          linkify
              ? _LinkifiedSelectableText(
                  text: text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textPrimary,
                    height: 1.4,
                  ),
                  linkColor: colors.accent,
                )
              : SelectableText(
                  text,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textPrimary,
                    height: 1.4,
                  ),
                ),
        ],
      ),
    );
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
              fontSize: 11,
              fontWeight: AppWeights.emphasis,
            ).copyWith(letterSpacing: 0.8),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.surfaceMuted,
              borderRadius: AppShapes.input,
              border: Border.all(color: colors.border),
            ),
            child: SelectableText(
              prompt,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textPrimary,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (savedPath.isNotEmpty) ...[
          _LocalImageAttachmentTile(
            host: widget.host,
            api: widget.api,
            path: savedPath,
          ),
          const SizedBox(height: 8),
          Text(
            savedPath,
            style: monoStyle(color: colors.textTertiary, fontSize: 10.5),
          ),
        ] else if (activity.status == 'completed') ...[
          _waitingText(
            context,
            'Image completed, but no saved file was reported.',
          ),
        ] else ...[
          _waitingText(context, 'Generating image...'),
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
        'Codex summarized older history so the session can keep working with more free context.',
      'failed' =>
        'Codex tried to compact the session context, but the compaction failed.',
      _ => 'Codex is compacting older history to free context.',
    };
    return [
      _activityInfoBlock(context, 'What happened', message),
    ];
  }

  String _toolActivityTitle(SessionActivity activity, String sessionCwd) {
    final target = _toolPrimaryTarget(activity, sessionCwd);
    final query = (activity.toolQuery ?? '').trim();
    final url = (activity.toolUrl ?? '').trim();
    final mode = (activity.toolMode ?? '').trim();
    final command = _toolCommandText(activity);

    if (activity.toolAction == 'mode_change' && mode.isNotEmpty) {
      return 'Switched to $mode mode';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'read' &&
        target.isNotEmpty) {
      return 'Read $target';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'write' &&
        target.isNotEmpty) {
      return 'Edited $target';
    }
    if (activity.toolCategory == 'filesystem' &&
        activity.toolAction == 'list' &&
        target.isNotEmpty) {
      return 'Listed $target';
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
      return _commandStatusTitle(activity.status, _displayCommandText(command));
    }

    final title = (activity.toolTitle ?? '').trim();
    if (title.isNotEmpty) return title;
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
      _ => 'Tool',
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
      ...rows.expand((row) => [row, const SizedBox(height: 10)]),
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
    if (activity.status == 'completed') {
      return switch (_webSearchKindLabel(activity)) {
        'find in page' => 'Finished searching within a page.',
        'open page' => 'Opened a web page for more detail.',
        _ => 'Finished web search.',
      };
    }
    return 'Web search is running.';
  }

  Widget _waitingText(BuildContext context, String text) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
          const SizedBox(height: 6),
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
              padding: const EdgeInsets.only(bottom: 14),
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
  const _CommandTitleChip({
    required this.parts,
    required this.collapsed,
  });

  final _CommandTitleParts parts;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final verbStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: colors.textPrimary,
      fontWeight: AppWeights.emphasis,
      height: 1.35,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxCommandWidth = constraints.hasBoundedWidth
            ? math.max(96.0, constraints.maxWidth - 34)
            : 420.0;
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            Text('${parts.verb} ', style: verbStyle),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxCommandWidth),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.surfaceElevated,
                  borderRadius: BorderRadius.circular(AppRadii.badge),
                  border: Border.all(
                    color: colors.codeBorder.withValues(alpha: 0.92),
                  ),
                ),
                child: Text(
                  parts.command,
                  maxLines: collapsed ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(
                    color: colors.codeForeground,
                    fontSize: 12.5,
                    fontWeight: AppWeights.emphasis,
                  ).copyWith(height: 1.25),
                ),
              ),
            ),
          ],
        );
      },
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
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tone.withValues(alpha: 0.18)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(action.icon, size: 16, color: tone),
              const SizedBox(width: 6),
              Text(
                action.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: action.tone == _ActivityActionTone.accent
                      ? colors.accent
                      : colors.textPrimary,
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
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: colors.surfaceElevated.withValues(alpha: 0.78),
              borderRadius: AppShapes.badge,
              border: Border.all(
                color: colors.border.withValues(alpha: 0.72),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  expanded
                      ? Icons.unfold_less_rounded
                      : Icons.unfold_more_rounded,
                  size: 15,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  expanded ? expandedLabel : label,
                  style: monoStyle(
                    color: colors.textSecondary,
                    fontSize: 12,
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.accentMuted,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
              size: 16,
              color: colors.accent,
            ),
            const SizedBox(width: 6),
            Text(
              expanded ? 'Show less' : '+$hiddenCount lines',
              style: monoStyle(
                color: colors.accent,
                fontSize: 12,
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
        Icon(Icons.description_rounded, size: 16, color: colors.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _relativeSessionPath(change.path, sessionCwd),
            style:
                monoStyle(
                  color: canOpen ? colors.accent : colors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: AppWeights.body,
                ).copyWith(
                  decoration: canOpen ? TextDecoration.underline : null,
                  decorationColor: canOpen ? colors.accent : null,
                ),
          ),
        ),
        const SizedBox(width: 8),
        MeshPill(label: change.kind, tone: tone, mono: true),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        canOpen
            ? InkWell(
                onTap: () => onOpen!(change.path),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: pathRow,
                ),
              )
            : pathRow,
        if ((change.movePath ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8, left: 24),
            child: Text(
              'Moved from ${_relativeSessionPath(change.movePath!, sessionCwd)}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          )
        else
          const SizedBox(height: 8),
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.description_rounded,
            size: 15,
            color: colors.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _relativeSessionPath(change.path, sessionCwd),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  monoStyle(
                    color: canOpen ? colors.accent : colors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: AppWeights.body,
                  ).copyWith(
                    decoration: canOpen ? TextDecoration.underline : null,
                    decorationColor: canOpen ? colors.accent : null,
                  ),
            ),
          ),
          const SizedBox(width: 8),
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
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 10.5,
              fontWeight: AppWeights.title,
            ).copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _SessionRuntimeDetails extends StatelessWidget {
  const _SessionRuntimeDetails({required this.runtime});

  final SessionRuntimeSummary runtime;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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

    return MeshCard(
      tone: MeshCardTone.muted,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_rounded, size: 16, color: colors.accent),
              const SizedBox(width: 7),
              Text(
                'Runtime',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.textPrimary,
                  fontWeight: AppWeights.title,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _RuntimeSection(
            title: 'Runtime',
            details: runtimeDetails,
            showTitle: false,
          ),
          if (contextDetails.isNotEmpty) ...[
            const SizedBox(height: 6),
            _RuntimeExpansionSection(title: 'Context', details: contextDetails),
          ],
          if (usageDetails.isNotEmpty) ...[
            const SizedBox(height: 4),
            _RuntimeExpansionSection(
              title: 'Last usage',
              details: usageDetails,
            ),
          ],
          if (compactionDetails.isNotEmpty) ...[
            const SizedBox(height: 4),
            _RuntimeExpansionSection(
              title: 'Compaction',
              details: compactionDetails,
            ),
          ],
        ],
      ),
    );
  }
}

class _RuntimeSection extends StatelessWidget {
  const _RuntimeSection({
    required this.title,
    required this.details,
    this.showTitle = true,
  });

  final String title;
  final List<({String label, String value})> details;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle) ...[
          Text(
            title.toUpperCase(),
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 9.5,
              fontWeight: AppWeights.title,
            ).copyWith(letterSpacing: 1.1),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: details
              .map((detail) => _RuntimeDetailChip(detail: detail))
              .toList(),
        ),
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
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 6),
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
        subtitle: Text(
          '${details.length} ${details.length == 1 ? 'field' : 'fields'}',
          style: monoStyle(color: colors.textSecondary, fontSize: 10.5),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: _RuntimeSection(
              title: title,
              details: details,
              showTitle: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _RuntimeDetailChip extends StatelessWidget {
  const _RuntimeDetailChip({required this.detail});

  final ({String label, String value}) detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            detail.label,
            style: monoStyle(
              color: colors.textSecondary,
              fontSize: 10.5,
              fontWeight: AppWeights.title,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              detail.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textPrimary,
                fontWeight: AppWeights.emphasis,
              ),
            ),
          ),
        ],
      ),
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
  final command = _displayCommandText(activity.command ?? '');
  return _commandStatusTitle(activity.status, command);
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

String _fileChangeActivityTitle(
  SessionActivity activity, {
  required bool running,
}) {
  final count = _fileChangeFileCount(activity.changes);
  if (count == 0) {
    return running ? 'Editing files' : 'No file changes';
  }
  final noun = count == 1 ? 'file' : 'files';
  return '${running ? 'Editing' : 'Edited'} $count $noun';
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
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Divider(color: colors.border, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.textTertiary,
                fontWeight: AppWeights.emphasis,
                letterSpacing: 0.6,
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
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textTertiary,
            ),
          ),
          if (onStop != null) ...[
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_rounded, size: 17),
              label: const Text('Stop agent'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.danger,
                side: BorderSide(
                  color: colors.danger.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
