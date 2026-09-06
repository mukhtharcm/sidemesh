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
          return const MeshLoader(label: 'Loading agents');
        }
        if (snapshot.hasError) {
          return MeshEmptyState.compact(
            icon: Icons.error_outline_rounded,
            title: 'Could not load agents',
            body: friendlyError(snapshot.error ?? 'Unknown error'),
            action: TextButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          );
        }
        final runs = snapshot.data ?? const <AgentRunSummary>[];
        if (runs.isEmpty) {
          return const MeshEmptyState.compact(
            icon: Icons.account_tree_outlined,
            title: 'No agents yet',
            body: 'Agents started by this session appear here.',
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
                : Divider(height: 1, indent: 44, color: context.colors.border),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Text(
                  '${runs.length} ${runs.length == 1 ? 'agent' : 'agents'}',
                  style: Theme.of(context).textTheme.titleSmall,
                );
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

String _agentStatusLabel(AgentRunSummary run) => switch (run.status) {
  'active' || 'running' => 'Running',
  'waiting_for_input' => 'Needs input',
  'waiting_for_approval' => 'Needs approval',
  'errored' || 'failed' => 'Error',
  'closed' || 'cancelled' || 'interrupted' => 'Stopped',
  'completed' => 'Completed',
  'idle' => 'Idle',
  _ => 'Unknown status',
};

Color _agentStatusColor(AgentRunSummary run, AppColors colors) =>
    switch (run.status) {
      'active' || 'running' => colors.success,
      'waiting_for_input' || 'waiting_for_approval' => colors.warning,
      'errored' || 'failed' => colors.danger,
      _ => colors.textSecondary,
    };

class _AgentRunRow extends StatelessWidget {
  const _AgentRunRow({required this.run, required this.onTap});

  final AgentRunSummary run;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final statusLabel = _agentStatusLabel(run);
    final statusColor = _agentStatusColor(run, colors);
    return Semantics(
      label: '${run.label}, $statusLabel',
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.md,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
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
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          _relativeAge(run.updatedAt),
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: colors.textTertiary),
                        ),
                      ],
                    ),
                    if (run.preview.trim().isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        run.preview.trim(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          height: AppLineHeights.body,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      statusLabel,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: AppWeights.emphasis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: AppSizes.inlineIcon,
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
                const SizedBox(width: AppSpacing.xs),
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
                        _agentStatusLabel(run),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: _agentStatusColor(run, colors),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (snapshot.connectionState != ConnectionState.done)
              const MeshLoader(label: 'Loading agents')
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
        const SizedBox(height: AppSpacing.xs),
        Text(
          message.text.trim(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colors.textPrimary,
            height: AppLineHeights.reading,
          ),
        ),
      ],
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
