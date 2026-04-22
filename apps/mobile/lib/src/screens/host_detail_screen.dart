import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_runtime.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';

class HostDetailScreen extends StatefulWidget {
  const HostDetailScreen({
    super.key,
    required this.host,
    required this.api,
    required this.onOpenSession,
  });

  final HostProfile host;
  final ApiClient api;
  final ValueChanged<SessionSummary> onOpenSession;

  @override
  State<HostDetailScreen> createState() => _HostDetailScreenState();
}

class _HostDetailScreenState extends State<HostDetailScreen> {
  late Future<_HostOverview> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_HostOverview> _load() async {
    final node = await widget.api.fetchNode(widget.host);
    final workspaces = await widget.api.fetchWorkspaces(widget.host);
    final sessions = await widget.api.fetchSessions(widget.host);
    return _HostOverview(
      node: node,
      workspaces: workspaces,
      sessions: sessions,
    );
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  Future<void> _startSession({String? prefilledCwd}) async {
    final created = await showModalBottomSheet<SessionSummary>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CreateSessionSheet(
        host: widget.host,
        api: widget.api,
        initialCwd: prefilledCwd,
      ),
    );
    if (created != null && mounted) {
      widget.onOpenSession(created);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        title: Text(widget.host.label),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startSession(),
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('New session'),
      ),
      body: FutureBuilder<_HostOverview>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const MeshLoader();
          }
          if (snapshot.hasError) {
            return MeshEmptyState(
              icon: Icons.wifi_off_rounded,
              title: 'Could not reach host',
              body: snapshot.error.toString(),
            );
          }
          final data = snapshot.data!;
          return RefreshIndicator(
            color: colors.accent,
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                _NodeCard(host: widget.host, node: data.node),
                const SizedBox(height: 18),
                _SectionHeader(
                  icon: Icons.folder_open_rounded,
                  title: 'Workspaces',
                  subtitle:
                      '${data.workspaces.length} ${data.workspaces.length == 1 ? "entry" : "entries"}',
                ),
                const SizedBox(height: 8),
                if (data.workspaces.isEmpty)
                  const MeshEmptyState(
                    icon: Icons.folder_off_outlined,
                    title: 'No workspaces',
                    body: 'Start a session and this host will remember it.',
                  )
                else
                  ...data.workspaces.map(
                    (workspace) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _WorkspaceCard(
                        workspace: workspace,
                        onTap: () => _startSession(prefilledCwd: workspace.cwd),
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                _SectionHeader(
                  icon: Icons.history_rounded,
                  title: 'Recent sessions',
                  subtitle:
                      '${data.sessions.length} ${data.sessions.length == 1 ? "session" : "sessions"}',
                ),
                const SizedBox(height: 8),
                if (data.sessions.isEmpty)
                  const MeshEmptyState(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'No sessions yet',
                    body: 'Tap "New session" to start one on this host.',
                  )
                else
                  ...data.sessions.map(
                    (session) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _SessionRow(
                        session: session,
                        onTap: () => widget.onOpenSession(session),
                      ),
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

class _NodeCard extends StatelessWidget {
  const _NodeCard({required this.host, required this.node});

  final HostProfile host;
  final NodeInfo node;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.elevated,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: BorderRadius.circular(13),
                  border:
                      Border.all(color: colors.accent.withValues(alpha: 0.3)),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.dns_rounded, color: colors.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.label.isNotEmpty ? node.label : host.label,
                      style:
                          Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host.baseUrl,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: node.hostname,
                icon: Icons.memory_rounded,
                tone: MeshPillTone.neutral,
                mono: true,
              ),
              MeshPill(
                label: node.platform,
                icon: Icons.devices_other_rounded,
                tone: MeshPillTone.neutral,
                mono: true,
              ),
              MeshPill(
                label: 'codex ${node.codexVersion}',
                icon: Icons.auto_awesome_rounded,
                tone: MeshPillTone.accent,
                mono: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.accent),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const Spacer(),
          Text(
            subtitle,
            style: monoStyle(color: colors.textTertiary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({required this.workspace, required this.onTap});

  final WorkspaceSummary workspace;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Icon(Icons.folder_rounded, color: colors.accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  workspace.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      monoStyle(color: colors.textSecondary, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          MeshPill(
            label: '${workspace.sessionCount}',
            icon: Icons.forum_outlined,
            tone: MeshPillTone.neutral,
            mono: true,
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onTap});

  final SessionSummary session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final running = session.isActive;
    return MeshCard(
      onTap: onTap,
      accentStrip: running ? colors.success : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            session.cwd,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(color: colors.textTertiary, fontSize: 11.5),
          ),
          if (session.runtime != null) ...[
            const SizedBox(height: 8),
            SessionRuntimeWrap(runtime: session.runtime),
          ],
        ],
      ),
    );
  }
}

class _CreateSessionSheet extends StatefulWidget {
  const _CreateSessionSheet({
    required this.host,
    required this.api,
    this.initialCwd,
  });

  final HostProfile host;
  final ApiClient api;
  final String? initialCwd;

  @override
  State<_CreateSessionSheet> createState() => _CreateSessionSheetState();
}

class _CreateSessionSheetState extends State<_CreateSessionSheet> {
  late final TextEditingController _cwdController;
  late final TextEditingController _promptController;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cwdController = TextEditingController(text: widget.initialCwd ?? '');
    _promptController = TextEditingController();
  }

  @override
  void dispose() {
    _cwdController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final cwd = _cwdController.text.trim();
    final prompt = _promptController.text.trim();
    if (cwd.isEmpty || prompt.isEmpty) {
      setState(() => _error = 'cwd and prompt are required');
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      final session = await widget.api.createSession(
        widget.host,
        cwd: cwd,
        prompt: prompt,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors.accentMuted,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Icon(Icons.play_arrow_rounded,
                      color: colors.accent, size: 18),
                ),
                const SizedBox(width: 12),
                Text(
                  'New session',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _cwdController,
              decoration: const InputDecoration(
                labelText: 'Working directory',
                hintText: '/Users/you/src/project',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _promptController,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Prompt',
                hintText: 'Refactor this module so...',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.danger),
              ),
            ],
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: const Text('Start session'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HostOverview {
  const _HostOverview({
    required this.node,
    required this.workspaces,
    required this.sessions,
  });

  final NodeInfo node;
  final List<WorkspaceSummary> workspaces;
  final List<SessionSummary> sessions;
}
