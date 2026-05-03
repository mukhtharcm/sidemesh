import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart' show ApiClient, friendlyError;
import '../models.dart';
import '../session_local_store.dart';
import '../session_overrides_store.dart';
import '../session_read_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/session_row_card.dart';
import 'create_session_sheet.dart';

class HostDetailScreen extends StatefulWidget {
  const HostDetailScreen({
    super.key,
    required this.host,
    required this.api,
    required this.onOpenSession,
    this.embedded = false,
    this.topPadding = 0,
  });

  final HostProfile host;
  final ApiClient api;
  final ValueChanged<SessionSummary> onOpenSession;

  /// When true, drop Scaffold/AppBar/FAB chrome and render a slim header
  /// suitable for embedding inside the desktop two-pane shell.
  final bool embedded;

  /// Extra padding reserved at the top (e.g. macOS titlebar inset).
  final double topPadding;

  @override
  State<HostDetailScreen> createState() => _HostDetailScreenState();
}

class _HostDetailScreenState extends State<HostDetailScreen> {
  final SessionLocalStore _localStore = SessionLocalStore.instance;
  late Future<_HostOverview> _future;
  Timer? _refreshTimer;
  static const Duration _refreshInterval = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    
    _localStore.ensureLoaded();
    SessionReadStore.instance.ensureLoaded();
    _future = _load();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _silentRefresh());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _silentRefresh() async {
    if (!mounted) return;
    try {
      final fresh = await _load();
      if (!mounted) return;
      setState(() => _future = Future.value(fresh));
    } catch (_) {
      // Keep the last good snapshot on transient errors.
    }
  }

  Future<_HostOverview> _load() async {
    final results = await Future.wait<Object>([
      widget.api.fetchNode(widget.host),
      widget.api.fetchSessions(widget.host, limit: 40),
    ]);
    final node = results[0] as NodeInfo;
    final sessions = results[1] as List<SessionSummary>;

    // Merge favorites in the background so the screen paints immediately.
    _localStore.getFavoriteSessions(widget.host).then((favorites) async {
      if (!mounted) return;
      final ghosts = await _localStore.ghostsForHost(widget.host);
      final merged = _mergeSessions(sessions, [...favorites, ...ghosts]);
      setState(() {
        _future = Future.value(_HostOverview(
          node: node,
          workspaces: _buildWorkspaces(merged),
          sessions: merged,
        ));
      });
    });

    final workspaces = _buildWorkspaces(sessions);
    return _HostOverview(
      node: node,
      workspaces: workspaces,
      sessions: sessions,
    );
  }

  List<SessionSummary> _mergeSessions(
    List<SessionSummary> recents,
    List<SessionSummary> favorites,
  ) {
    final byId = <String, SessionSummary>{
      for (final s in recents) s.id: s,
    };
    for (final fav in favorites) {
      byId.putIfAbsent(fav.id, () => fav);
    }
    return byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  List<SessionSummary> _sortSessions(List<SessionSummary> sessions) {
    final overrides = SessionOverridesStore.instance;
    final sorted = sessions
        .map((s) => overrides.overlay(widget.host.id, s))
        .toList();
    sorted.sort((left, right) {
      final leftFavorite = _localStore.isFavorite(widget.host, left.id);
      final rightFavorite = _localStore.isFavorite(widget.host, right.id);
      if (leftFavorite != rightFavorite) {
        return leftFavorite ? -1 : 1;
      }
      return right.updatedAt.compareTo(left.updatedAt);
    });
    return sorted;
  }

  List<WorkspaceSummary> _buildWorkspaces(List<SessionSummary> sessions) {
    final grouped = <String, WorkspaceSummary>{};
    for (final session in sessions) {
      final parts = session.cwd.split('/').where((part) => part.isNotEmpty);
      final label = parts.isEmpty ? session.cwd : parts.last;
      final existing = grouped[session.cwd];
      if (existing == null) {
        grouped[session.cwd] = WorkspaceSummary(
          cwd: session.cwd,
          label: label.isEmpty ? session.cwd : label,
          sessionCount: 1,
          lastUsedAt: session.updatedAt,
        );
        continue;
      }
      grouped[session.cwd] = WorkspaceSummary(
        cwd: existing.cwd,
        label: existing.label,
        sessionCount: existing.sessionCount + 1,
        lastUsedAt: existing.lastUsedAt.isAfter(session.updatedAt)
            ? existing.lastUsedAt
            : session.updatedAt,
      );
    }

    final workspaces = grouped.values.toList();
    workspaces.sort(
      (left, right) => right.lastUsedAt.compareTo(left.lastUsedAt),
    );
    return workspaces;
  }

  Future<void> _startSession({String? prefilledCwd}) async {
    final created = await showCreateSessionLauncher(
      context,
      host: widget.host,
      api: widget.api,
      initialCwd: prefilledCwd,
    );
    if (created != null && mounted) {
      widget.onOpenSession(created);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (widget.embedded) {
      return Container(
        color: colors.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: widget.topPadding),
            _EmbeddedHostHeader(
              host: widget.host,
              onRefresh: _refresh,
              onNewSession: () => _startSession(),
            ),
            Expanded(child: _buildBody(context)),
          ],
        ),
      );
    }
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
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<_HostOverview>(
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
        return ListenableBuilder(
          listenable: Listenable.merge([
            SessionLocalStore.instance,
            SessionOverridesStore.instance,
          ]),
          builder: (context, _) {
            final sortedSessions = _sortSessions(data.sessions);
            return RefreshIndicator(
              color: colors.accent,
              onRefresh: _refresh,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  8,
                  16,
                  widget.embedded ? 32 : 120,
                ),
                children: [
                  _NodeCard(host: widget.host, node: data.node),
                  const SizedBox(height: AppSpacing.sm),
                  _ProviderContractCard(node: data.node),
                  const SizedBox(height: AppSpacing.lg),
                  _SectionHeader(
                    icon: Icons.folder_open_rounded,
                    title: 'Workspaces',
                    subtitle:
                        '${data.workspaces.length} ${data.workspaces.length == 1 ? "entry" : "entries"}',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (data.workspaces.isEmpty)
                    const MeshEmptyState(
                      icon: Icons.folder_off_rounded,
                      title: 'No workspaces',
                      body: 'Start a session and this host will remember it.',
                    )
                  else
                    ...data.workspaces.map(
                      (workspace) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _WorkspaceCard(
                          workspace: workspace,
                          onTap: () =>
                              _startSession(prefilledCwd: workspace.cwd),
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  _SectionHeader(
                    icon: Icons.history_rounded,
                    title: 'Recent sessions',
                    subtitle:
                        '${data.sessions.length} ${data.sessions.length == 1 ? "session" : "sessions"}',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (sortedSessions.isEmpty)
                    const MeshEmptyState(
                      icon: Icons.chat_bubble_outline_rounded,
                      title: 'No sessions yet',
                      body: 'Tap "New session" to start one on this host.',
                    )
                  else
                    ...sortedSessions.map(
                      (session) => Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: SessionRowCard(
                          host: widget.host,
                          session: session,
                          favorite: _localStore.isFavorite(
                            widget.host,
                            session.id,
                          ),
                          onTap: () => widget.onOpenSession(session),
                          onToggleFavorite: () {
                            _localStore.toggleFavorite(widget.host, session.id);
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.lg),
                  _HostManagementCard(
                    host: widget.host,
                    api: widget.api,
                    node: data.node,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _EmbeddedHostHeader extends StatelessWidget {
  const _EmbeddedHostHeader({
    required this.host,
    required this.onRefresh,
    required this.onNewSession,
  });

  final HostProfile host;
  final VoidCallback onRefresh;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 14, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.dns_rounded, size: 17, color: colors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  host.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: onRefresh,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onNewSession,
            icon: const Icon(Icons.play_arrow_rounded, size: 16),
            label: const Text('New session'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: colors.accentOn,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
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
      tone: MeshCardTone.surface,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.3),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.dns_rounded, color: colors.accent, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      node.label.isNotEmpty ? node.label : host.label,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      host.baseUrl,
                      style: monoStyle(
                        color: colors.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
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
                label: node.providerPillLabel,
                icon: Icons.auto_awesome_rounded,
                tone: MeshPillTone.accent,
                mono: true,
              ),
              if (node.providerConfig.command != null)
                MeshPill(
                  label: node.providerConfig.command!,
                  icon: Icons.terminal_rounded,
                  tone: MeshPillTone.neutral,
                  mono: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProviderContractCard extends StatefulWidget {
  const _ProviderContractCard({required this.node});

  final NodeInfo node;

  @override
  State<_ProviderContractCard> createState() => _ProviderContractCardState();
}

class _ProviderContractCardState extends State<_ProviderContractCard> {
  late String _selectedProviderKind = _initialProviderKind(widget.node);

  @override
  void didUpdateWidget(covariant _ProviderContractCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node == widget.node) {
      return;
    }
    final supportedKinds = widget.node.supportedProviders
        .map((provider) => provider.kind)
        .toSet();
    if (_selectedProviderKind.isEmpty ||
        !supportedKinds.contains(_selectedProviderKind)) {
      _selectedProviderKind = _initialProviderKind(widget.node);
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final colors = context.colors;
    final selectedSummary = _selectedProviderSummary(
      node,
      _selectedProviderKind,
    );
    final providerGroups = _capabilityGroups(
      node.capabilitiesForProvider(_selectedProviderKind),
    );
    final hostGroups = _capabilityGroups(node.hostCapabilities);
    final supportedProviders = node.supportedProviders;
    final selectedDisplayName = _providerDisplayName(node, selectedSummary);
    final selectedVersion = _providerDisplayVersion(node, selectedSummary);
    final selectedCommand = _providerCommand(node, selectedSummary);
    final isViewingActiveProvider = _selectedProviderKind == node.provider;

    return MeshCard(
      tone: MeshCardTone.muted,
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: colors.infoMuted,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: colors.info.withValues(alpha: 0.35)),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.hub_rounded, color: colors.info, size: 16),
          ),
          title: Text(
            'Provider contract',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: AppWeights.title),
          ),
          subtitle: Text(
            '$selectedDisplayName - $selectedVersion',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(color: colors.textSecondary, fontSize: 11),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MeshPill(
                    label: 'active: ${node.provider}',
                    icon: Icons.radio_button_checked_rounded,
                    tone: isViewingActiveProvider
                        ? MeshPillTone.success
                        : MeshPillTone.neutral,
                    mono: true,
                  ),
                  if (!isViewingActiveProvider)
                    MeshPill(
                      label: 'viewing: $_selectedProviderKind',
                      icon: Icons.visibility_rounded,
                      tone: MeshPillTone.accent,
                      mono: true,
                    ),
                  if (selectedCommand != null)
                    MeshPill(
                      label: 'command: $selectedCommand',
                      icon: Icons.terminal_rounded,
                      tone: MeshPillTone.neutral,
                      mono: true,
                    ),
                  MeshPill(
                    label: '${supportedProviders.length} supported',
                    icon: Icons.extension_rounded,
                    tone: supportedProviders.isEmpty
                        ? MeshPillTone.warning
                        : MeshPillTone.info,
                    mono: true,
                  ),
                ],
              ),
            ),
            if (supportedProviders.isNotEmpty) ...[
              const SizedBox(height: 14),
              _ProviderDefinitionList(
                currentProvider: node.provider,
                selectedProvider: _selectedProviderKind,
                providers: supportedProviders,
                onSelect: (provider) {
                  setState(() {
                    _selectedProviderKind = provider.kind;
                  });
                },
              ),
            ],
            const SizedBox(height: 14),
            _CapabilityMatrix(
              title: 'Provider-owned capabilities',
              emptyText:
                  'This provider did not report any provider-owned capabilities.',
              groups: providerGroups,
            ),
            const SizedBox(height: 12),
            _CapabilityMatrix(
              title: 'Host-owned capabilities',
              emptyText: 'This daemon did not report host capabilities.',
              groups: hostGroups,
            ),
          ],
        ),
      ),
    );
  }

  static String _initialProviderKind(NodeInfo node) {
    if (node.supportedProviders.any(
      (provider) => provider.kind == node.provider,
    )) {
      return node.provider;
    }
    if (node.supportedProviders.isNotEmpty) {
      return node.supportedProviders.first.kind;
    }
    return node.provider;
  }

  static ProviderDefinitionSummary _selectedProviderSummary(
    NodeInfo node,
    String selectedProviderKind,
  ) {
    return node.providerSummary(selectedProviderKind);
  }

  static String _providerDisplayName(
    NodeInfo node,
    ProviderDefinitionSummary summary,
  ) {
    if (summary.displayName.isNotEmpty) {
      return summary.displayName;
    }
    if (summary.kind == node.provider || summary.kind.isEmpty) {
      return node.providerDisplayName;
    }
    return summary.kind;
  }

  static String _providerDisplayVersion(
    NodeInfo node,
    ProviderDefinitionSummary summary,
  ) {
    if (summary.version.isNotEmpty) {
      return summary.version;
    }
    if (summary.kind == node.provider || summary.kind.isEmpty) {
      return node.providerDisplayVersion;
    }
    return 'version unknown';
  }

  static String? _providerCommand(
    NodeInfo node,
    ProviderDefinitionSummary summary,
  ) {
    if (summary.config.command != null) {
      return summary.config.command;
    }
    if (summary.defaultCommand.isNotEmpty) {
      return summary.defaultCommand;
    }
    if (summary.kind == node.provider || summary.kind.isEmpty) {
      return node.providerConfig.command;
    }
    return null;
  }
}

class _ProviderDefinitionList extends StatelessWidget {
  const _ProviderDefinitionList({
    required this.currentProvider,
    required this.selectedProvider,
    required this.providers,
    required this.onSelect,
  });

  final String currentProvider;
  final String selectedProvider;
  final List<ProviderDefinitionSummary> providers;
  final ValueChanged<ProviderDefinitionSummary> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Daemon-supported providers',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.textSecondary,
            fontWeight: AppWeights.title,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Tap a provider to inspect its contract.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: providers
              .map((provider) {
                final active = provider.kind == currentProvider;
                final selected = provider.kind == selectedProvider;
                return _ProviderSelectPill(
                  label: active
                      ? '${provider.displayName} active'
                      : provider.displayName,
                  icon: active
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  tone: selected
                      ? (active ? MeshPillTone.success : MeshPillTone.accent)
                      : MeshPillTone.neutral,
                  selected: selected,
                  onTap: () => onSelect(provider),
                );
              })
              .toList(growable: false),
        ),
      ],
    );
  }
}

class _ProviderSelectPill extends StatelessWidget {
  const _ProviderSelectPill({
    required this.label,
    required this.icon,
    required this.tone,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final MeshPillTone tone;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppShapes.pill,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 140),
          scale: selected ? 1.0 : 0.985,
          child: MeshPill(label: label, icon: icon, tone: tone, mono: true),
        ),
      ),
    );
  }
}

class _CapabilityMatrix extends StatelessWidget {
  const _CapabilityMatrix({
    required this.title,
    required this.emptyText,
    required this.groups,
  });

  final String title;
  final String emptyText;
  final List<_CapabilityGroup> groups;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.textSecondary,
            fontWeight: AppWeights.title,
          ),
        ),
        const SizedBox(height: 8),
        if (groups.isEmpty)
          Text(
            emptyText,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          )
        else
          Column(
            children: groups
                .map(
                  (group) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CapabilityGroupRow(group: group),
                  ),
                )
                .toList(growable: false),
          ),
      ],
    );
  }
}

class _CapabilityGroupRow extends StatelessWidget {
  const _CapabilityGroupRow({required this.group});

  final _CapabilityGroup group;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final allEnabled = group.enabledCount == group.totalCount;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(group.icon, size: 16, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  group.title,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
                ),
              ),
              MeshPill(
                label: '${group.enabledCount}/${group.totalCount}',
                tone: allEnabled ? MeshPillTone.success : MeshPillTone.warning,
                mono: true,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: group.features
                .map((feature) {
                  return MeshPill(
                    label: feature.label,
                    icon: feature.enabled
                        ? Icons.check_rounded
                        : Icons.remove_rounded,
                    tone: feature.enabled
                        ? MeshPillTone.success
                        : MeshPillTone.neutral,
                    bold: false,
                    mono: true,
                  );
                })
                .toList(growable: false),
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
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.accent),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: AppWeights.title),
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

class _CapabilityGroup {
  const _CapabilityGroup({
    required this.key,
    required this.title,
    required this.icon,
    required this.features,
  });

  final String key;
  final String title;
  final IconData icon;
  final List<_CapabilityFeature> features;

  int get totalCount => features.length;
  int get enabledCount => features.where((feature) => feature.enabled).length;
}

class _CapabilityFeature {
  const _CapabilityFeature({required this.label, required this.enabled});

  final String label;
  final bool enabled;
}

List<_CapabilityGroup> _capabilityGroups(ProviderCapabilities capabilities) {
  final groups = <_CapabilityGroup>[];
  for (final entry in capabilities.values.entries) {
    final rawFeatures = entry.value;
    if (rawFeatures is! Map) continue;
    final features = rawFeatures.entries
        .map(
          (feature) => _CapabilityFeature(
            label: _capabilityFeatureLabel(feature.key.toString()),
            enabled: feature.value == true,
          ),
        )
        .toList(growable: false);
    if (features.isEmpty) continue;
    groups.add(
      _CapabilityGroup(
        key: entry.key,
        title: _capabilitySectionTitle(entry.key),
        icon: _capabilitySectionIcon(entry.key),
        features: features,
      ),
    );
  }
  groups.sort(
    (left, right) => _capabilitySectionOrder(
      left.key,
    ).compareTo(_capabilitySectionOrder(right.key)),
  );
  return groups;
}

int _capabilitySectionOrder(String key) {
  return switch (key) {
    'sessions' => 0,
    'input' => 1,
    'interaction' => 2,
    'approvals' => 3,
    'configuration' => 4,
    'runtimeControls' => 5,
    'workspace' => 6,
    _ => 99,
  };
}

String _capabilitySectionTitle(String key) {
  return switch (key) {
    'sessions' => 'Sessions',
    'input' => 'Input',
    'interaction' => 'Interactive input',
    'approvals' => 'Approvals',
    'configuration' => 'Configuration',
    'runtimeControls' => 'Runtime controls',
    'workspace' => 'Workspace',
    _ => _humanizeCamelCase(key),
  };
}

IconData _capabilitySectionIcon(String key) {
  return switch (key) {
    'sessions' => Icons.forum_rounded,
    'input' => Icons.input_rounded,
    'interaction' => Icons.rate_review_rounded,
    'approvals' => Icons.verified_user_rounded,
    'configuration' => Icons.tune_rounded,
    'runtimeControls' => Icons.speed_rounded,
    'workspace' => Icons.folder_special_rounded,
    _ => Icons.extension_rounded,
  };
}

String _capabilityFeatureLabel(String key) {
  return switch (key) {
    'imageUrl' => 'image URL',
    'localImage' => 'local image',
    'eventReplay' => 'event replay',
    'recentFallback' => 'recent fallback',
    'skillManagement' => 'skill management',
    'mode' => 'mode',
    'reasoningEffort' => 'reasoning',
    'fastMode' => 'fast mode',
    'approvalPolicy' => 'approval policy',
    'sandboxMode' => 'sandbox',
    'networkAccess' => 'network',
    'webSearch' => 'web search',
    'remoteGitDiff' => 'remote git diff',
    'gitStatus' => 'git status',
    'gitDiff' => 'git diff',
    'portForwarding' => 'port forwarding',
    'approveForSession' => 'approve for session',
    'userInput' => 'ask user',
    'elicitation' => 'form requests',
    _ => _humanizeCamelCase(key),
  };
}

String _humanizeCamelCase(String value) {
  if (value.isEmpty) return value;
  final withSpaces = value.replaceAllMapped(
    RegExp(r'(?<=[a-z0-9])([A-Z])'),
    (match) => ' ${match.group(1)!.toLowerCase()}',
  );
  return withSpaces.replaceAll('_', ' ');
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
                  ).textTheme.titleSmall?.copyWith(fontWeight: AppWeights.emphasis),
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
            icon: Icons.forum_rounded,
            tone: MeshPillTone.neutral,
            mono: true,
          ),
        ],
      ),
    );
  }
}


class _HostManagementCard extends StatefulWidget {
  const _HostManagementCard({
    required this.host,
    required this.api,
    required this.node,
  });

  final HostProfile host;
  final ApiClient api;
  final NodeInfo node;

  @override
  State<_HostManagementCard> createState() => _HostManagementCardState();
}

class _HostManagementCardState extends State<_HostManagementCard> {
  bool _busy = false;

  bool get _supportsRestart => widget.node
      .capabilitiesForProvider(null)
      .supports('lifecycle', 'restart');

  String get _providerDisplayName => widget.node.providerDisplayName;

  Future<void> _restartProvider() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.restartProvider(widget.host, widget.node.provider);
      if (!mounted) return;
      showAppSnackBar(context, '$_providerDisplayName restarting…');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Restart failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restartDaemon() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.restartDaemon(widget.host);
      if (!mounted) return;
      showAppSnackBar(context, 'Daemon restarting…');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Restart failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.muted,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Icon(
                  Icons.medical_services_rounded,
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Host management',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppWeights.title,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.border),
          if (_supportsRestart)
            _ManagementRow(
              icon: Icons.refresh_rounded,
              label: 'Restart $_providerDisplayName provider',
              detail: 'Preserves terminals and port forwards.',
              busy: _busy,
              onTap: _restartProvider,
            ),
          if (_supportsRestart) Divider(height: 1, indent: 46, color: colors.border),
          _ManagementRow(
            icon: Icons.restart_alt_rounded,
            label: 'Restart Sidemesh daemon',
            detail: 'Full process restart — reconnect automatically.',
            busy: _busy,
            onTap: _restartDaemon,
          ),
        ],
      ),
    );
  }
}

class _ManagementRow extends StatelessWidget {
  const _ManagementRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: colors.border),
                ),
                alignment: Alignment.center,
                child: busy
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: colors.textSecondary,
                        ),
                      )
                    : Icon(icon, size: 16, color: colors.textSecondary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: AppWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
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
