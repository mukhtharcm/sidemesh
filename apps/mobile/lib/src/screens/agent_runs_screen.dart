import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/mesh_widgets.dart';

class AgentRunsScreen extends StatelessWidget {
  const AgentRunsScreen({
    super.key,
    required this.host,
    required this.session,
    required this.api,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.canvas,
      appBar: AppBar(title: const Text('Agents')),
      body: SafeArea(
        top: false,
        child: AgentRunsView(host: host, session: session, api: api),
      ),
    );
  }
}

class AgentRunsView extends StatefulWidget {
  const AgentRunsView({
    super.key,
    required this.host,
    required this.session,
    required this.api,
  });

  final HostProfile host;
  final SessionSummary session;
  final ApiClient api;

  @override
  State<AgentRunsView> createState() => _AgentRunsViewState();
}

class _AgentRunsViewState extends State<AgentRunsView> {
  late Future<List<AgentRunSummary>> _future = _load();
  AgentRunSummary? _selectedRun;
  Future<SessionLog>? _detailFuture;

  Future<List<AgentRunSummary>> _load() =>
      widget.api.fetchAgentRuns(widget.host, widget.session.id);

  void _refresh() {
    setState(() => _future = _load());
  }

  void _openRun(AgentRunSummary run) {
    setState(() {
      _selectedRun = run;
      _detailFuture = widget.api.fetchLog(
        widget.host,
        run.id,
        messageLimit: 100,
        activityLimit: 100,
      );
    });
  }

  void _closeRun() {
    setState(() {
      _selectedRun = null;
      _detailFuture = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedRun = _selectedRun;
    final detailFuture = _detailFuture;
    if (selectedRun != null && detailFuture != null) {
      return _AgentRunDetail(
        run: selectedRun,
        future: detailFuture,
        onBack: _closeRun,
      );
    }
    return FutureBuilder<List<AgentRunSummary>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _AgentRunsLoading();
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MeshEmptyState.compact(
                    icon: Icons.error_outline_rounded,
                    title: 'Could not load agents',
                    body: friendlyError(snapshot.error ?? 'Unknown error'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  OutlinedButton.icon(
                    onPressed: _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                ],
              ),
            ),
          );
        }
        final runs = snapshot.data ?? const <AgentRunSummary>[];
        if (runs.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: MeshEmptyState(
                icon: Icons.account_tree_outlined,
                title: 'No agents yet',
                body:
                    'Agents spawned by this session will appear here with their latest result.',
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            _refresh();
            await _future;
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.xl,
            ),
            itemCount: runs.length + 1,
            separatorBuilder: (_, index) => index == 0
                ? const SizedBox(height: AppSpacing.sm)
                : Divider(
                    height: 1,
                    indent: 44,
                    color: context.colors.border,
                  ),
            itemBuilder: (context, index) {
              if (index == 0) {
                final active = runs.where((run) => run.isActive).length;
                return _AgentRunsSummary(total: runs.length, active: active);
              }
              final run = runs[index - 1];
              return _AgentRunRow(run: run, onTap: () => _openRun(run));
            },
          ),
        );
      },
    );
  }
}

class _AgentRunsSummary extends StatelessWidget {
  const _AgentRunsSummary({required this.total, required this.active});

  final int total;
  final int active;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final completed = total - active;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
      child: Row(
        children: [
          Text(
            '$total ${total == 1 ? 'agent' : 'agents'}',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: colors.textPrimary,
              fontWeight: AppWeights.title,
            ),
          ),
          const Spacer(),
          if (active > 0)
            MeshPill(
              label: '$active active',
              tone: MeshPillTone.success,
              mono: true,
            ),
          if (active > 0 && completed > 0) const SizedBox(width: 6),
          if (completed > 0)
            MeshPill(
              label: '$completed done',
              tone: MeshPillTone.neutral,
              mono: true,
            ),
        ],
      ),
    );
  }
}

class _AgentRunRow extends StatelessWidget {
  const _AgentRunRow({required this.run, required this.onTap});

  final AgentRunSummary run;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusColor = run.isActive ? colors.success : colors.textTertiary;
    return Semantics(
      label: '${run.label}, ${run.isActive ? 'active' : 'done'}',
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          run.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: colors.textPrimary,
                                fontWeight: AppWeights.title,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _relativeAge(run.updatedAt),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  if (run.preview.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      run.preview.trim(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                  Text(
                    run.isActive ? 'Active' : 'Done',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: statusColor,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.textTertiary,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _AgentRunDetail extends StatelessWidget {
  const _AgentRunDetail({
    required this.run,
    required this.future,
    required this.onBack,
  });

  final AgentRunSummary run;
  final Future<SessionLog> future;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<SessionLog>(
      future: future,
      builder: (context, snapshot) {
        final messages = (snapshot.data?.messages ?? const <SessionMessage>[])
            .where((message) => message.isRenderable)
            .toList(growable: false);
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.xl,
          ),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  tooltip: 'Back to agents',
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        run.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: AppWeights.title,
                        ),
                      ),
                      Text(
                        run.isActive ? 'Active' : 'Done',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: run.isActive
                              ? colors.success
                              : colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (snapshot.connectionState != ConnectionState.done)
              const _AgentRunsLoading()
            else if (snapshot.hasError)
              MeshEmptyState.compact(
                icon: Icons.error_outline_rounded,
                title: 'Could not load this agent',
                body: friendlyError(snapshot.error ?? 'Unknown error'),
              )
            else if (messages.isEmpty)
              const MeshEmptyState.compact(
                icon: Icons.chat_bubble_outline_rounded,
                title: 'No transcript yet',
                body: 'This agent has not produced a visible message.',
              )
            else
              for (final message in messages) ...[
                _AgentMessage(message: message),
                const SizedBox(height: AppSpacing.md),
              ],
          ],
        );
      },
    );
  }
}

class _AgentMessage extends StatelessWidget {
  const _AgentMessage({required this.message});

  final SessionMessage message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isAssistant = message.role == 'assistant';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isAssistant ? 'Agent' : 'Prompt',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: colors.textTertiary,
            fontWeight: AppWeights.emphasis,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          message.text.trim(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.textPrimary,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _AgentRunsLoading extends StatelessWidget {
  const _AgentRunsLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(AppSpacing.md),
      child: Column(
        children: [
          MeshListRowSkeleton(framed: false, showTrailing: false),
          MeshListRowSkeleton(framed: false, showTrailing: false),
          MeshListRowSkeleton(framed: false, showTrailing: false),
        ],
      ),
    );
  }
}

String _relativeAge(DateTime time) {
  final difference = DateTime.now().difference(time);
  if (difference.isNegative || difference.inMinutes < 1) return 'now';
  if (difference.inHours < 1) return '${difference.inMinutes}m';
  if (difference.inDays < 1) return '${difference.inHours}h';
  return '${difference.inDays}d';
}
