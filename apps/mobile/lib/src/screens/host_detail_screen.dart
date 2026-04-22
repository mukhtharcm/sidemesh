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
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.3),
                  ),
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
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
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
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
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
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  workspace.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textSecondary, fontSize: 11.5),
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
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
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

enum _SessionLaunchMode { inherit, readOnly, defaultPreset, fullAccess, custom }

extension on _SessionLaunchMode {
  String get label => switch (this) {
    _SessionLaunchMode.inherit => 'Inherit',
    _SessionLaunchMode.readOnly => 'Read Only',
    _SessionLaunchMode.defaultPreset => 'Default',
    _SessionLaunchMode.fullAccess => 'Full Access',
    _SessionLaunchMode.custom => 'Custom',
  };

  String get description => switch (this) {
    _SessionLaunchMode.inherit =>
      'Matches plain Codex TUI startup and inherits this host\'s active config.',
    _SessionLaunchMode.readOnly =>
      'Codex can read files in the workspace. Approval is required to edit files or access the internet.',
    _SessionLaunchMode.defaultPreset =>
      'Codex can read and edit the workspace, and run commands. Approval is required to access the internet or edit other files.',
    _SessionLaunchMode.fullAccess =>
      'Codex can access the internet and edit files outside the workspace without asking.',
    _SessionLaunchMode.custom =>
      'Choose approval policy and sandbox mode explicitly.',
  };
}

class _CreateSessionSheetState extends State<_CreateSessionSheet> {
  late final TextEditingController _cwdController;
  late final TextEditingController _promptController;
  late final TextEditingController _modelController;
  late final TextEditingController _profileController;
  _SessionLaunchMode _launchMode = _SessionLaunchMode.defaultPreset;
  String _customApprovalPolicy = 'on-request';
  String _customSandboxMode = 'workspace-write';
  bool _enableSearch = false;
  bool _showAdvanced = false;
  bool _submitting = false;
  String? _error;

  static const _approvalPolicies = [
    ('untrusted', 'Untrusted'),
    ('on-failure', 'On failure'),
    ('on-request', 'On request'),
    ('never', 'Never'),
  ];

  static const _sandboxModes = [
    ('read-only', 'Read only'),
    ('workspace-write', 'Workspace write'),
    ('danger-full-access', 'Danger full access'),
  ];

  @override
  void initState() {
    super.initState();
    _cwdController = TextEditingController(text: widget.initialCwd ?? '');
    _promptController = TextEditingController();
    _modelController = TextEditingController();
    _profileController = TextEditingController();
  }

  @override
  void dispose() {
    _cwdController.dispose();
    _promptController.dispose();
    _modelController.dispose();
    _profileController.dispose();
    super.dispose();
  }

  String? _normalized(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  String? _selectedApprovalPolicy() {
    return switch (_launchMode) {
      _SessionLaunchMode.inherit => null,
      _SessionLaunchMode.readOnly => 'on-request',
      _SessionLaunchMode.defaultPreset => 'on-request',
      _SessionLaunchMode.fullAccess => 'never',
      _SessionLaunchMode.custom => _customApprovalPolicy,
    };
  }

  String? _selectedSandboxMode() {
    return switch (_launchMode) {
      _SessionLaunchMode.inherit => null,
      _SessionLaunchMode.readOnly => 'read-only',
      _SessionLaunchMode.defaultPreset => 'workspace-write',
      _SessionLaunchMode.fullAccess => 'danger-full-access',
      _SessionLaunchMode.custom => _customSandboxMode,
    };
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
        model: _normalized(_modelController),
        profile: _normalized(_profileController),
        approvalPolicy: _selectedApprovalPolicy(),
        sandboxMode: _selectedSandboxMode(),
        webSearch: _enableSearch ? 'live' : null,
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
    final helperStyle = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.textSecondary, height: 1.45);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: const EdgeInsets.all(22),
        child: SingleChildScrollView(
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
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: colors.accent,
                      size: 18,
                    ),
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
              const SizedBox(height: 14),
              DropdownButtonFormField<_SessionLaunchMode>(
                initialValue: _launchMode,
                decoration: const InputDecoration(labelText: 'Runtime mode'),
                items: _SessionLaunchMode.values
                    .map(
                      (mode) => DropdownMenuItem<_SessionLaunchMode>(
                        value: mode,
                        child: Text(mode.label),
                      ),
                    )
                    .toList(),
                onChanged: _submitting
                    ? null
                    : (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() => _launchMode = value);
                      },
              ),
              const SizedBox(height: 8),
              Text(_launchMode.description, style: helperStyle),
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _enableSearch,
                onChanged: _submitting
                    ? null
                    : (value) => setState(() => _enableSearch = value),
                title: const Text('Enable live web search'),
                subtitle: Text(
                  'Matches Codex TUI `--search` and sets `web_search="live"` for this thread.',
                  style: helperStyle,
                ),
              ),
              TextButton.icon(
                onPressed: _submitting
                    ? null
                    : () => setState(() => _showAdvanced = !_showAdvanced),
                icon: Icon(
                  _showAdvanced
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                label: Text(_showAdvanced ? 'Hide advanced' : 'Show advanced'),
              ),
              if (_showAdvanced) ...[
                const SizedBox(height: 6),
                TextField(
                  controller: _modelController,
                  decoration: const InputDecoration(
                    labelText: 'Model override',
                    hintText: 'gpt-5.4',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _profileController,
                  decoration: const InputDecoration(
                    labelText: 'Profile override',
                    hintText: 'guardian',
                  ),
                ),
                if (_launchMode == _SessionLaunchMode.custom) ...[
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _customApprovalPolicy,
                    decoration: const InputDecoration(
                      labelText: 'Approval policy',
                    ),
                    items: _approvalPolicies
                        .map(
                          (entry) => DropdownMenuItem<String>(
                            value: entry.$1,
                            child: Text(entry.$2),
                          ),
                        )
                        .toList(),
                    onChanged: _submitting
                        ? null
                        : (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => _customApprovalPolicy = value);
                          },
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: _customSandboxMode,
                    decoration: const InputDecoration(
                      labelText: 'Sandbox mode',
                    ),
                    items: _sandboxModes
                        .map(
                          (entry) => DropdownMenuItem<String>(
                            value: entry.$1,
                            child: Text(entry.$2),
                          ),
                        )
                        .toList(),
                    onChanged: _submitting
                        ? null
                        : (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() => _customSandboxMode = value);
                          },
                  ),
                ],
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.danger),
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
