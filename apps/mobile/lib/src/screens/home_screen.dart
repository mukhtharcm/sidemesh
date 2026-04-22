import 'dart:math';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../host_store.dart';
import '../models.dart';
import '../session_runtime.dart';
import 'host_detail_screen.dart';
import 'session_screen.dart';

class SidemeshHomeScreen extends StatefulWidget {
  const SidemeshHomeScreen({super.key});

  @override
  State<SidemeshHomeScreen> createState() => _SidemeshHomeScreenState();
}

class _SidemeshHomeScreenState extends State<SidemeshHomeScreen> {
  static const _tabTitles = ['Recent', 'Inbox', 'Hosts'];

  final HostStore _store = HostStore();
  final ApiClient _api = ApiClient();
  List<HostProfile> _hosts = const [];
  bool _loading = true;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _refreshHosts();
  }

  Future<void> _refreshHosts() async {
    final hosts = await _store.loadHosts();
    if (!mounted) {
      return;
    }
    setState(() {
      _hosts = hosts;
      _loading = false;
    });
  }

  Future<void> _showHostEditor({HostProfile? initialHost}) async {
    final result = await showModalBottomSheet<HostProfile>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _HostEditorSheet(initialHost: initialHost),
    );
    if (result == null) {
      return;
    }
    final exists = _hosts.any((item) => item.id == result.id);
    final updated = exists
        ? _hosts.map((item) => item.id == result.id ? result : item).toList()
        : [..._hosts, result];
    await _store.saveHosts(updated);
    await _refreshHosts();
  }

  Future<void> _removeHost(HostProfile host) async {
    final updated = _hosts.where((item) => item.id != host.id).toList();
    await _store.saveHosts(updated);
    await _refreshHosts();
  }

  Future<void> _openSession(HostProfile host, SessionSummary session) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            SessionScreen(host: host, session: session, api: _api),
      ),
    );
  }

  Future<void> _openHost(HostProfile host) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HostDetailScreen(
          host: host,
          api: _api,
          onOpenSession: (session) => _openSession(host, session),
        ),
      ),
    );
  }

  SessionSummary _sessionFromAction(PendingAction action) {
    return SessionSummary(
      id: action.sessionId,
      title: action.sessionTitle ?? 'Session',
      preview: action.detail,
      cwd: action.cwd ?? '',
      createdAt: action.requestedAt,
      updatedAt: action.requestedAt,
      source: 'appServer',
      status: 'pendingApproval',
      runtime: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_tabTitles[_tabIndex]),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refreshHosts,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _tabIndex == 2
          ? FloatingActionButton.extended(
              onPressed: () => _showHostEditor(),
              icon: const Icon(Icons.add_link),
              label: const Text('Add host'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tabIndex,
              children: [
                _RecentPane(
                  hosts: _hosts,
                  api: _api,
                  onOpenSession: _openSession,
                ),
                _InboxPane(
                  hosts: _hosts,
                  api: _api,
                  onOpenSession: (host, action) =>
                      _openSession(host, _sessionFromAction(action)),
                ),
                _HostsPane(
                  hosts: _hosts,
                  onOpenHost: _openHost,
                  onEditHost: (host) => _showHostEditor(initialHost: host),
                  onRemoveHost: _removeHost,
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) {
          setState(() {
            _tabIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.schedule_outlined),
            selectedIcon: Icon(Icons.schedule),
            label: 'Recent',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Inbox',
          ),
          NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub),
            label: 'Hosts',
          ),
        ],
      ),
    );
  }
}

class _RecentPane extends StatefulWidget {
  const _RecentPane({
    required this.hosts,
    required this.api,
    required this.onOpenSession,
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final void Function(HostProfile host, SessionSummary session) onOpenSession;

  @override
  State<_RecentPane> createState() => _RecentPaneState();
}

class _RecentPaneState extends State<_RecentPane> {
  late Future<List<_RemoteSessionEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadRecent();
  }

  @override
  void didUpdateWidget(covariant _RecentPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hosts != widget.hosts) {
      _future = _loadRecent();
    }
  }

  Future<List<_RemoteSessionEntry>> _loadRecent() async {
    final merged = <_RemoteSessionEntry>[];
    for (final host in widget.hosts) {
      try {
        final sessions = await widget.api.fetchSessions(host);
        merged.addAll(
          sessions
              .take(20)
              .map(
                (session) => _RemoteSessionEntry(host: host, session: session),
              ),
        );
      } catch (_) {
        continue;
      }
    }
    merged.sort(
      (left, right) =>
          right.session.updatedAt.compareTo(left.session.updatedAt),
    );
    return merged;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hosts.isEmpty) {
      return const _EmptyState(
        icon: Icons.schedule_outlined,
        title: 'No sessions yet',
        body:
            'Add a host first, then your most recent Codex sessions will land here.',
      );
    }

    return FutureBuilder<List<_RemoteSessionEntry>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final entries = snapshot.data ?? const [];
        if (entries.isEmpty) {
          return const _EmptyState(
            icon: Icons.cloud_off,
            title: 'No reachable sessions',
            body:
                'The saved hosts are fine, but none of them returned recent sessions right now.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            setState(() {
              _future = _loadRecent();
            });
            await _future;
          },
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 14),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(18),
                  title: Text(entry.session.title),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${entry.host.label}  •  ${entry.session.cwd}'),
                        if (entry.session.runtime != null) ...[
                          const SizedBox(height: 8),
                          SessionRuntimeWrap(runtime: entry.session.runtime),
                        ],
                        if (entry.session.preview.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            entry.session.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: const Color(0xFF6D5B49)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.onOpenSession(entry.host, entry.session),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _InboxPane extends StatefulWidget {
  const _InboxPane({
    required this.hosts,
    required this.api,
    required this.onOpenSession,
  });

  final List<HostProfile> hosts;
  final ApiClient api;
  final void Function(HostProfile host, PendingAction action) onOpenSession;

  @override
  State<_InboxPane> createState() => _InboxPaneState();
}

class _InboxPaneState extends State<_InboxPane> {
  late Future<List<_PendingActionEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadInbox();
  }

  @override
  void didUpdateWidget(covariant _InboxPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hosts != widget.hosts) {
      _future = _loadInbox();
    }
  }

  Future<List<_PendingActionEntry>> _loadInbox() async {
    final merged = <_PendingActionEntry>[];
    for (final host in widget.hosts) {
      try {
        final actions = await widget.api.fetchPendingActions(host);
        merged.addAll(
          actions.map(
            (action) => _PendingActionEntry(host: host, action: action),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    merged.sort(
      (left, right) =>
          right.action.requestedAt.compareTo(left.action.requestedAt),
    );
    return merged;
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _loadInbox();
    });
    await _future;
  }

  Future<void> _respond(
    HostProfile host,
    PendingAction action,
    String decision,
  ) async {
    try {
      await widget.api.respondToAction(
        host,
        actionId: action.id,
        decision: decision,
      );
      if (!mounted) {
        return;
      }
      await _refresh();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resolve action: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hosts.isEmpty) {
      return const _EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'Inbox is empty',
        body:
            'Add a host first. Pending approvals from every machine will show up here.',
      );
    }

    return FutureBuilder<List<_PendingActionEntry>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        final entries = snapshot.data ?? const [];
        if (entries.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(height: 120),
                _EmptyState(
                  icon: Icons.verified_outlined,
                  title: 'No pending approvals',
                  body:
                      'Command, file, and permission prompts from your Codex nodes will appear here.',
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(height: 14),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final action = entry.action;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              action.title,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          _ActionKindChip(kind: action.kind),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${entry.host.label}  •  ${action.sessionTitle ?? action.sessionId}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF6D5B49),
                        ),
                      ),
                      if ((action.cwd ?? '').isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          action.cwd!,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFF6D5B49)),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(action.detail),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () =>
                                widget.onOpenSession(entry.host, action),
                            icon: const Icon(Icons.forum_outlined),
                            label: const Text('Open session'),
                          ),
                          if (action.canApprove)
                            FilledButton(
                              onPressed: () =>
                                  _respond(entry.host, action, 'accept'),
                              child: const Text('Approve'),
                            ),
                          if (action.canApproveForSession)
                            FilledButton.tonal(
                              onPressed: () => _respond(
                                entry.host,
                                action,
                                'acceptForSession',
                              ),
                              child: const Text('Approve for session'),
                            ),
                          if (action.canDecline)
                            OutlinedButton(
                              onPressed: () =>
                                  _respond(entry.host, action, 'decline'),
                              child: const Text('Decline'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _HostsPane extends StatelessWidget {
  const _HostsPane({
    required this.hosts,
    required this.onOpenHost,
    required this.onEditHost,
    required this.onRemoveHost,
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onOpenHost;
  final ValueChanged<HostProfile> onEditHost;
  final ValueChanged<HostProfile> onRemoveHost;

  @override
  Widget build(BuildContext context) {
    if (hosts.isEmpty) {
      return const _EmptyState(
        icon: Icons.route_outlined,
        title: 'No hosts yet',
        body:
            'Add a MacBook or VPS node by pasting its Tailscale address and shared token.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
      itemCount: hosts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        final host = hosts[index];
        return Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => onOpenHost(host),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Color(0xFFEBC8A1),
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                    ),
                    child: const Icon(
                      Icons.storage_rounded,
                      color: Color(0xFF221C15),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          host.label,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          host.baseUrl,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFF6D5B49)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit host',
                    onPressed: () => onEditHost(host),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: 'Remove host',
                    onPressed: () => onRemoveHost(host),
                    icon: const Icon(Icons.delete_outline),
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

class _HostEditorSheet extends StatefulWidget {
  const _HostEditorSheet({this.initialHost});

  final HostProfile? initialHost;

  @override
  State<_HostEditorSheet> createState() => _HostEditorSheetState();
}

class _HostEditorSheetState extends State<_HostEditorSheet> {
  late final TextEditingController _labelController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(
      text: widget.initialHost?.label ?? '',
    );
    _baseUrlController = TextEditingController(
      text: widget.initialHost?.baseUrl ?? '',
    );
    _tokenController = TextEditingController(
      text: widget.initialHost?.token ?? '',
    );
  }

  @override
  void dispose() {
    _labelController.dispose();
    _baseUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final isEditing = widget.initialHost != null;
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
                isEditing ? 'Edit host' : 'Add host',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _labelController,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  hintText: 'MacBook or VPS-1',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'http://macbook.tailnet.ts.net:8787',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(labelText: 'Shared token'),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: () {
                    final label = _labelController.text.trim();
                    final baseUrl = normalizeBaseUrl(_baseUrlController.text);
                    final token = _tokenController.text.trim();
                    if (label.isEmpty || baseUrl.isEmpty || token.isEmpty) {
                      return;
                    }
                    Navigator.of(context).pop(
                      HostProfile(
                        id: widget.initialHost?.id ?? _randomId(),
                        label: label,
                        baseUrl: baseUrl,
                        token: token,
                      ),
                    );
                  },
                  icon: const Icon(Icons.check),
                  label: Text(isEditing ? 'Save changes' : 'Save host'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteSessionEntry {
  const _RemoteSessionEntry({required this.host, required this.session});

  final HostProfile host;
  final SessionSummary session;
}

class _PendingActionEntry {
  const _PendingActionEntry({required this.host, required this.action});

  final HostProfile host;
  final PendingAction action;
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: const Color(0xFFCA6B1F)),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionKindChip extends StatelessWidget {
  const _ActionKindChip({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    final label = switch (kind) {
      'command' => 'Command',
      'file_change' => 'Files',
      'permissions' => 'Permissions',
      _ => kind,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEBC8A1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label),
    );
  }
}

String _randomId() {
  final random = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(
    12,
    (_) => alphabet[random.nextInt(alphabet.length)],
  ).join();
}
