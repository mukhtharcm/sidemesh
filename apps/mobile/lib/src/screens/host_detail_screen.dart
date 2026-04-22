import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_runtime.dart';

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
  NodeInfo? _node;
  List<WorkspaceSummary> _workspaces = const [];
  List<SessionSummary> _sessions = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final node = await widget.api.fetchNode(widget.host);
      final workspaces = await widget.api.fetchWorkspaces(widget.host);
      final sessions = await widget.api.fetchSessions(widget.host);
      if (!mounted) {
        return;
      }
      setState(() {
        _node = node;
        _workspaces = workspaces;
        _sessions = sessions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _createSession() async {
    final result = await showModalBottomSheet<_CreateSessionInput>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _CreateSessionSheet(workspaces: _workspaces),
    );
    if (result == null) {
      return;
    }

    try {
      final session = await widget.api.createSession(
        widget.host,
        cwd: result.cwd,
        prompt: result.prompt,
      );
      if (!mounted) {
        return;
      }
      await _refresh();
      widget.onOpenSession(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to create session: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.host.label),
        actions: [
          IconButton(
            tooltip: 'New session',
            onPressed: _createSession,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _node?.label ?? widget.host.label,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(widget.host.baseUrl),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _InfoChip(label: _node?.platform ?? 'unknown'),
                              _InfoChip(label: _node?.hostname ?? 'unresolved'),
                              _InfoChip(
                                label: _node?.codexVersion ?? 'codex unknown',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Known workspaces',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  if (_workspaces.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 20),
                      child: Text('No prior workspaces on this host yet.'),
                    )
                  else
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: _workspaces
                          .map(
                            (workspace) => Chip(
                              label: Text(
                                '${workspace.label} · ${workspace.sessionCount}',
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Sessions',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _createSession,
                        icon: const Icon(Icons.add),
                        label: const Text('New'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_sessions.isEmpty)
                    const Text('No sessions found.')
                  else
                    ..._sessions.map(
                      (session) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.all(18),
                            title: Text(session.title),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(session.cwd),
                                  if (session.runtime != null) ...[
                                    const SizedBox(height: 8),
                                    SessionRuntimeWrap(
                                      runtime: session.runtime,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => widget.onOpenSession(session),
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

class _CreateSessionSheet extends StatefulWidget {
  const _CreateSessionSheet({required this.workspaces});

  final List<WorkspaceSummary> workspaces;

  @override
  State<_CreateSessionSheet> createState() => _CreateSessionSheetState();
}

class _CreateSessionSheetState extends State<_CreateSessionSheet> {
  final _cwdController = TextEditingController();
  final _promptController = TextEditingController();

  @override
  void dispose() {
    _cwdController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'New session',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _cwdController,
                decoration: const InputDecoration(
                  labelText: 'Working directory',
                  hintText: '/Users/me/project',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _promptController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Opening prompt',
                  hintText: 'Inspect the latest diff and summarize it.',
                ),
              ),
              if (widget.workspaces.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  'Reuse a known workspace',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: widget.workspaces
                      .take(8)
                      .map(
                        (workspace) => ActionChip(
                          label: Text(workspace.label),
                          onPressed: () {
                            _cwdController.text = workspace.cwd;
                          },
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: () {
                    final cwd = _cwdController.text.trim();
                    final prompt = _promptController.text.trim();
                    if (cwd.isEmpty || prompt.isEmpty) {
                      return;
                    }
                    Navigator.of(
                      context,
                    ).pop(_CreateSessionInput(cwd: cwd, prompt: prompt));
                  },
                  icon: const Icon(Icons.rocket_launch_outlined),
                  label: const Text('Launch'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateSessionInput {
  const _CreateSessionInput({required this.cwd, required this.prompt});

  final String cwd;
  final String prompt;
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEBC8A1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label),
    );
  }
}
