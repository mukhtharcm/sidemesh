import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart' show ApiClient, friendlyError;
import '../app_version_store.dart';
import '../mobile_client_version_policy.dart';
import '../models.dart';
import '../host_status_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../session_local_store.dart';
import '../session_overrides_store.dart';
import '../session_read_store.dart';
import '../theme/app_colors.dart';
import '../theme/color_contrast.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_sheets.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/session_row_card.dart';
import 'create_session_sheet.dart';
import 'terminal_screen.dart';
import '../app_icons.dart';

String _hostEndpointLabel(String baseUrl) {
  final uri = Uri.tryParse(baseUrl.trim());
  if (uri == null || uri.host.isEmpty) {
    return baseUrl.trim();
  }
  final hasDefaultPort =
      !uri.hasPort ||
      (uri.scheme == 'http' && uri.port == 80) ||
      (uri.scheme == 'https' && uri.port == 443);
  return hasDefaultPort ? uri.host : '${uri.host}:${uri.port}';
}

String _agentAvailabilityLabel(int count) {
  final noun = count == 1 ? 'agent' : 'agents';
  return '$count $noun available';
}

String _agentInUseLabel(String displayName) => 'In use: $displayName';

String _agentViewingLabel(String displayName) => 'Viewing: $displayName';

String _agentCommandLabel(String command) => 'Command: $command';

String _releaseTrackLabel(String value) {
  return value == 'bleeding-edge' ? 'Early access' : 'Stable';
}

String _releaseTrackDetail(String value) {
  return value == 'bleeding-edge'
      ? 'Early access · newest changes'
      : 'Stable · tagged releases';
}

class HostDetailScreen extends StatefulWidget {
  const HostDetailScreen({
    super.key,
    required this.host,
    required this.api,
    required this.onOpenSession,
    this.embedded = false,
    this.topPadding = 0,
    this.showMobileClientCompatibility = true,
  });

  final HostProfile host;
  final ApiClient api;
  final ValueChanged<SessionSummary> onOpenSession;

  /// When true, drop Scaffold/AppBar/FAB chrome and render a slim header
  /// suitable for embedding inside the desktop two-pane shell.
  final bool embedded;

  /// Extra padding reserved at the top (e.g. macOS titlebar inset).
  final double topPadding;

  /// Mobile-client version hints are only actionable in the mobile app shell.
  final bool showMobileClientCompatibility;

  @override
  State<HostDetailScreen> createState() => _HostDetailScreenState();
}

class _HostDetailScreenState extends State<HostDetailScreen>
    with WidgetsBindingObserver {
  final SessionLocalStore _localStore = SessionLocalStore.instance;
  final AppVersionStore _appVersionStore = AppVersionStore.instance;
  late Future<_HostOverview> _future;
  Timer? _refreshTimer;
  Future<void>? _updateInfoRefresh;
  bool _checkingUpdateInfo = false;
  AppLifecycleState? _lifecycleState;
  static const Duration _refreshInterval = Duration(minutes: 1);

  @override
  void initState() {
    super.initState();

    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _localStore.ensureLoaded();
    SessionReadStore.instance.ensureLoaded();
    if (widget.showMobileClientCompatibility) {
      _appVersionStore.addListener(_handleAppVersionChanged);
      unawaited(_appVersionStore.ensureLoaded());
    }
    _future = _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshUpdateInfo());
    });
    _startRefreshTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRefreshTimer();
    if (widget.showMobileClientCompatibility) {
      _appVersionStore.removeListener(_handleAppVersionChanged);
    }
    super.dispose();
  }

  void _handleAppVersionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _startRefreshTimer();
      unawaited(_silentRefresh());
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _stopRefreshTimer();
    }
  }

  void _startRefreshTimer() {
    if (_lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _silentRefresh());
  }

  void _stopRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
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
      var displayNode = node;
      try {
        final latestNode = (await _future).node;
        displayNode = node.copyWithUpdateInfo(latestNode.updateInfo);
      } catch (_) {
        displayNode = node;
      }
      if (!mounted) return;
      final merged = _mergeSessions(sessions, [...favorites, ...ghosts]);
      setState(() {
        _future = Future.value(
          _HostOverview(
            node: displayNode,
            workspaces: _buildWorkspaces(merged),
            sessions: merged,
          ),
        );
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
    final byId = <String, SessionSummary>{for (final s in recents) s.id: s};
    for (final fav in favorites) {
      byId.putIfAbsent(fav.id, () => fav);
    }
    return byId.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
    unawaited(_refreshUpdateInfo());
  }

  Future<void> _refreshUpdateInfo() {
    final existing = _updateInfoRefresh;
    if (existing != null) {
      return existing;
    }
    final future = _runUpdateInfoRefresh();
    _updateInfoRefresh = future;
    return future;
  }

  Future<void> _runUpdateInfoRefresh() async {
    if (mounted) {
      setState(() => _checkingUpdateInfo = true);
    }
    try {
      final info = await widget.api.refreshUpdateInfo(widget.host);
      final overview = await _future;
      if (!mounted) return;
      setState(() {
        _future = Future.value(
          overview.copyWith(node: overview.node.copyWithUpdateInfo(info)),
        );
      });
    } catch (_) {
      // Keep the existing snapshot if the update check cannot reach the remote.
    } finally {
      _updateInfoRefresh = null;
      if (mounted) {
        setState(() => _checkingUpdateInfo = false);
      }
    }
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
            icon: const Icon(AppIcons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startSession(),
        icon: const Icon(AppIcons.play_arrow_rounded),
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
          return _HostDetailLoadingState(embedded: widget.embedded);
        }
        if (snapshot.hasError) {
          return MeshEmptyState(
            icon: AppIcons.wifi_off_rounded,
            title: 'Could not reach host',
            body: friendlyError(snapshot.error!),
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
                  if (widget.showMobileClientCompatibility &&
                      data.node.advertisesMobileClientVersionHints) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _MobileClientCompatibilityCard(
                      node: data.node,
                      appVersionInfo: _appVersionStore.info,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  if (widget.embedded)
                    _ProviderContractCard(node: data.node)
                  else
                    _ProviderContractSummaryCard(node: data.node),
                  if (data.workspaces.length > 1) ...[
                    const SizedBox(height: AppSpacing.lg),
                    _SectionHeader(
                      icon: AppIcons.folder_open_rounded,
                      title: 'Start from folder',
                      subtitle:
                          '${data.workspaces.length} recent ${data.workspaces.length == 1 ? "folder" : "folders"}',
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    _WorkspaceLaunchRow(
                      workspaces: data.workspaces,
                      onTap: (workspace) =>
                          _startSession(prefilledCwd: workspace.cwd),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  _SectionHeader(
                    icon: AppIcons.medical_services_rounded,
                    title: 'Manage this machine',
                    subtitle: 'Open tools, updates, and restart controls',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _HostManagementCard(
                    host: widget.host,
                    api: widget.api,
                    node: data.node,
                    checkingUpdateInfo: _checkingUpdateInfo,
                    onRefresh: _refresh,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _SectionHeader(
                    icon: AppIcons.history_rounded,
                    title: 'Recent sessions',
                    subtitle:
                        '${data.sessions.length} ${data.sessions.length == 1 ? "session" : "sessions"}',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (sortedSessions.isEmpty)
                    const MeshEmptyState(
                      icon: AppIcons.chat_bubble_outline_rounded,
                      title: 'No sessions yet',
                      body: 'Start a session on this machine to see it here.',
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
                          showHost: false,
                          onTap: () => widget.onOpenSession(session),
                          onToggleFavorite: () {
                            _localStore.toggleFavorite(widget.host, session.id);
                          },
                        ),
                      ),
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
            child: Icon(AppIcons.dns_rounded, size: 17, color: colors.accent),
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
                  _hostEndpointLabel(host.baseUrl),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(color: colors.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(AppIcons.refresh_rounded, size: 18),
            onPressed: onRefresh,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: onNewSession,
            icon: const Icon(AppIcons.play_arrow_rounded, size: 16),
            label: const Text('New session'),
            style: FilledButton.styleFrom(
              backgroundColor: colors.accent,
              foregroundColor: readableActionForeground(colors, colors.accent),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostDetailLoadingState extends StatelessWidget {
  const _HostDetailLoadingState({required this.embedded});

  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 8, 16, embedded ? 32 : 120),
      children: const [
        MeshCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MeshSkeleton(width: 34, height: 34, radius: 10),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          widthFactor: 0.32,
                          alignment: Alignment.centerLeft,
                          child: MeshSkeleton(
                            height: 16,
                            radius: AppRadii.badge,
                          ),
                        ),
                        SizedBox(height: 6),
                        FractionallySizedBox(
                          widthFactor: 0.44,
                          alignment: Alignment.centerLeft,
                          child: MeshSkeleton(
                            height: 12,
                            radius: AppRadii.badge,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MeshSkeleton(width: 92, height: 20, radius: 999),
                  MeshSkeleton(width: 74, height: 20, radius: 999),
                  MeshSkeleton(width: 116, height: 20, radius: 999),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.sm),
        MeshCard(
          tone: MeshCardTone.muted,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MeshSectionHeadingSkeleton(
                titleWidthFactor: 0.24,
                subtitleWidthFactor: 0.52,
              ),
              SizedBox(height: 14),
              Row(
                children: [
                  Expanded(child: _HostSummaryCardSkeleton()),
                  SizedBox(width: 12),
                  Expanded(child: _HostSummaryCardSkeleton()),
                ],
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.lg),
        MeshSectionHeadingSkeleton(
          titleWidthFactor: 0.22,
          subtitleWidthFactor: 0.38,
        ),
        SizedBox(height: AppSpacing.sm),
        MeshListRowSkeleton(
          titleWidthFactor: 0.42,
          subtitleWidthFactor: 0.62,
          showTrailing: false,
        ),
        SizedBox(height: AppSpacing.sm),
        MeshListRowSkeleton(
          titleWidthFactor: 0.5,
          subtitleWidthFactor: 0.72,
          showMeta: true,
          badgeCount: 1,
        ),
        SizedBox(height: AppSpacing.sm),
        MeshListRowSkeleton(
          titleWidthFactor: 0.46,
          subtitleWidthFactor: 0.68,
          showMeta: true,
        ),
      ],
    );
  }
}

class _HostSummaryCardSkeleton extends StatelessWidget {
  const _HostSummaryCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return MeshSurface(
      tone: MeshSurfaceTone.surface,
      radius: AppRadii.control,
      padding: const EdgeInsets.all(12),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FractionallySizedBox(
            widthFactor: 0.34,
            alignment: Alignment.centerLeft,
            child: MeshSkeleton(height: 10, radius: AppRadii.badge),
          ),
          SizedBox(height: 10),
          FractionallySizedBox(
            widthFactor: 0.58,
            alignment: Alignment.centerLeft,
            child: MeshSkeleton(height: 18, radius: AppRadii.badge),
          ),
          SizedBox(height: 8),
          FractionallySizedBox(
            widthFactor: 0.44,
            alignment: Alignment.centerLeft,
            child: MeshSkeleton(height: 12, radius: AppRadii.badge),
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
                child: Icon(AppIcons.dns_rounded, color: colors.accent, size: 18),
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
                icon: AppIcons.memory_rounded,
                tone: MeshPillTone.neutral,
                mono: true,
              ),
              MeshPill(
                label: node.platform,
                icon: AppIcons.devices_other_rounded,
                tone: MeshPillTone.neutral,
                mono: true,
              ),
              MeshPill(
                label: node.providerPillLabel,
                icon: AppIcons.auto_awesome_rounded,
                tone: MeshPillTone.accent,
                mono: true,
              ),
              if (node.providerConfig.command != null)
                MeshPill(
                  label: node.providerConfig.command!,
                  icon: AppIcons.terminal_rounded,
                  tone: MeshPillTone.neutral,
                  mono: true,
                ),
              if (node.updateAvailable)
                MeshPill(
                  label: node.usesBleedingEdgeTrack
                      ? 'New commits on main'
                      : 'Update: ${node.latestInstallLabel} available',
                  icon: AppIcons.system_update_alt_rounded,
                  tone: MeshPillTone.warning,
                  mono: true,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MobileClientCompatibilityCard extends StatelessWidget {
  const _MobileClientCompatibilityCard({
    required this.node,
    required this.appVersionInfo,
  });

  final NodeInfo node;
  final AppVersionInfo appVersionInfo;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final installedVersion = appVersionInfo.comparableVersion;
    final compatibility = evaluateMobileClientCompatibility(
      installedVersion: installedVersion,
      recommendedVersion: node.recommendedMobileClientVersion,
      minimumVersion: node.minimumMobileClientVersion,
    );
    final requiresUpdate =
        compatibility.level == MobileClientCompatibilityLevel.required;
    final recommendsUpdate =
        compatibility.level == MobileClientCompatibilityLevel.recommended;
    final accent = requiresUpdate ? colors.danger : colors.info;
    final accentMuted = requiresUpdate ? colors.dangerMuted : colors.infoMuted;
    final title = requiresUpdate
        ? 'Mobile client update required'
        : recommendsUpdate
        ? 'Mobile client update recommended'
        : 'Mobile client compatibility';
    final currentVersion = appVersionInfo.hasVersion
        ? 'You are on ${appVersionInfo.displayVersion}.'
        : 'Current mobile app version is unavailable on this device.';
    final guidance = switch (compatibility.level) {
      MobileClientCompatibilityLevel.required =>
        'This host requires Sidemesh mobile ${mobileClientVersionLabel(compatibility.targetVersion)} or newer.',
      MobileClientCompatibilityLevel.recommended =>
        'This host recommends Sidemesh mobile ${mobileClientVersionLabel(compatibility.targetVersion)} or newer.',
      MobileClientCompatibilityLevel.none =>
        node.minimumMobileClientVersion != null &&
                node.minimumMobileClientVersion!.isNotEmpty
            ? 'This host currently supports Sidemesh mobile ${mobileClientVersionLabel(node.minimumMobileClientVersion!)} or newer.'
            : node.recommendedMobileClientVersion != null &&
                  node.recommendedMobileClientVersion!.isNotEmpty
            ? 'This host currently recommends Sidemesh mobile ${mobileClientVersionLabel(node.recommendedMobileClientVersion!)} or newer.'
            : 'This host did not publish a mobile client policy.',
    };

    return MeshCard(
      tone: MeshCardTone.muted,
      borderColor: accent.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accentMuted,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accent.withValues(alpha: 0.3)),
            ),
            alignment: Alignment.center,
            child: Icon(AppIcons.phone_android_rounded, color: accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppWeights.title,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  guidance,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    MeshPill(
                      label: appVersionInfo.displayVersion,
                      icon: AppIcons.smartphone_rounded,
                      tone: MeshPillTone.neutral,
                      mono: true,
                    ),
                    if ((node.minimumMobileClientVersion ?? '').isNotEmpty)
                      MeshPill(
                        label:
                            'minimum ${mobileClientVersionLabel(node.minimumMobileClientVersion!)}',
                        icon: AppIcons.lock_outline_rounded,
                        tone: requiresUpdate
                            ? MeshPillTone.danger
                            : MeshPillTone.neutral,
                        mono: true,
                      ),
                    if ((node.recommendedMobileClientVersion ?? '').isNotEmpty)
                      MeshPill(
                        label:
                            'recommended ${mobileClientVersionLabel(node.recommendedMobileClientVersion!)}',
                        icon: AppIcons.system_update_alt_rounded,
                        tone: recommendsUpdate
                            ? MeshPillTone.info
                            : MeshPillTone.neutral,
                        mono: true,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  currentVersion,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HostProviderContractScreen extends StatelessWidget {
  const HostProviderContractScreen({super.key, required this.node});

  final NodeInfo node;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final title = node.label.isNotEmpty ? node.label : node.hostname;
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(title: Text('Agents on this machine')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [_ProviderContractDetailPanel(node: node, title: title)],
      ),
    );
  }
}

class _ProviderContractDetailPanel extends StatefulWidget {
  const _ProviderContractDetailPanel({required this.node, required this.title});

  final NodeInfo node;
  final String title;

  @override
  State<_ProviderContractDetailPanel> createState() =>
      _ProviderContractDetailPanelState();
}

class _ProviderContractDetailPanelState
    extends State<_ProviderContractDetailPanel> {
  late String _selectedProviderKind = _initialProviderKind(widget.node);

  @override
  void didUpdateWidget(covariant _ProviderContractDetailPanel oldWidget) {
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
    final selectedSummary = node.providerSummary(_selectedProviderKind);
    final selectedDisplayName = _providerDisplayName(node, selectedSummary);
    final selectedVersion = _providerDisplayVersion(node, selectedSummary);
    final selectedCommand = _providerCommand(node, selectedSummary);
    final providerGroups = _capabilityGroups(
      node.capabilitiesForProvider(_selectedProviderKind),
    );
    final hostGroups = _capabilityGroups(node.hostCapabilities);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ProviderContractOverviewCard(
          title: widget.title,
          node: node,
          selectedProviderKind: _selectedProviderKind,
          selectedDisplayName: selectedDisplayName,
          selectedVersion: selectedVersion,
          selectedCommand: selectedCommand,
        ),
        if (node.supportedProviders.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          _ProviderDefinitionSection(
            currentProvider: node.provider,
            selectedProvider: _selectedProviderKind,
            providers: node.supportedProviders,
            onSelect: (provider) {
              setState(() {
                _selectedProviderKind = provider.kind;
              });
            },
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        _CapabilitySummaryMatrix(
          title: 'Agent features',
          emptyText: 'This agent did not report any extra features.',
          groups: providerGroups,
        ),
        const SizedBox(height: AppSpacing.lg),
        _CapabilitySummaryMatrix(
          title: 'Machine features',
          emptyText: 'This machine did not report any extra features.',
          groups: hostGroups,
        ),
      ],
    );
  }
}

class _ProviderContractOverviewCard extends StatelessWidget {
  const _ProviderContractOverviewCard({
    required this.title,
    required this.node,
    required this.selectedProviderKind,
    required this.selectedDisplayName,
    required this.selectedVersion,
    required this.selectedCommand,
  });

  final String title;
  final NodeInfo node;
  final String selectedProviderKind;
  final String selectedDisplayName;
  final String selectedVersion;
  final String? selectedCommand;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isViewingActiveProvider = selectedProviderKind == node.provider;
    return MeshCard(
      tone: MeshCardTone.surface,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.infoMuted,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: colors.info.withValues(alpha: 0.32),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(AppIcons.hub_rounded, color: colors.info, size: 19),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$selectedDisplayName · $selectedVersion',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textTertiary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: _agentInUseLabel(node.providerDisplayName),
                icon: AppIcons.radio_button_checked_rounded,
                tone: isViewingActiveProvider
                    ? MeshPillTone.success
                    : MeshPillTone.neutral,
              ),
              if (!isViewingActiveProvider)
                MeshPill(
                  label: _agentViewingLabel(selectedDisplayName),
                  icon: AppIcons.visibility_rounded,
                  tone: MeshPillTone.accent,
                ),
              if (selectedCommand != null)
                MeshPill(
                  label: _agentCommandLabel(selectedCommand!),
                  icon: AppIcons.terminal_rounded,
                  tone: MeshPillTone.neutral,
                ),
              MeshPill(
                label: _agentAvailabilityLabel(node.supportedProviders.length),
                icon: AppIcons.extension_rounded,
                tone: node.supportedProviders.isEmpty
                    ? MeshPillTone.warning
                    : MeshPillTone.info,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProviderDefinitionSection extends StatelessWidget {
  const _ProviderDefinitionSection({
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
        _ContractSectionLabel(
          icon: AppIcons.extension_rounded,
          title: 'Available agents',
          detail: '${providers.length} available',
        ),
        const SizedBox(height: 8),
        MeshSurface(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var index = 0; index < providers.length; index++) ...[
                _ProviderDefinitionRow(
                  provider: providers[index],
                  active: providers[index].kind == currentProvider,
                  selected: providers[index].kind == selectedProvider,
                  onTap: () => onSelect(providers[index]),
                ),
                if (index < providers.length - 1)
                  Divider(height: 1, indent: 54, color: colors.border),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ProviderDefinitionRow extends StatelessWidget {
  const _ProviderDefinitionRow({
    required this.provider,
    required this.active,
    required this.selected,
    required this.onTap,
  });

  final ProviderDefinitionSummary provider;
  final bool active;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final command = provider.config.command ?? provider.defaultCommand;
    final iconTone = selected ? colors.accent : colors.textTertiary;
    final iconBackground = selected ? colors.accentMuted : colors.surfaceMuted;
    return MeshListRow(
      framed: false,
      dense: true,
      onTap: onTap,
      leading: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: iconBackground,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected
                ? colors.accent.withValues(alpha: 0.36)
                : colors.border,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(
          selected
              ? AppIcons.radio_button_checked_rounded
              : AppIcons.radio_button_unchecked_rounded,
          size: 17,
          color: iconTone,
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              provider.displayName.isEmpty
                  ? provider.kind
                  : provider.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontWeight: AppWeights.title),
            ),
          ),
          if (active) ...[
            const SizedBox(width: 7),
            _TinyStatusPill(label: 'In use', tone: MeshPillTone.success),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (provider.version.trim().isNotEmpty) provider.version.trim(),
          if (command.trim().isNotEmpty) _agentCommandLabel(command.trim()),
          if (provider.version.trim().isEmpty && command.trim().isEmpty)
            provider.kind,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
      ),
      trailing: selected
          ? Icon(AppIcons.check_rounded, color: colors.accent, size: 18)
          : null,
    );
  }
}

class _CapabilitySummaryMatrix extends StatelessWidget {
  const _CapabilitySummaryMatrix({
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
    final enabled = groups.fold<int>(
      0,
      (count, group) => count + group.enabledCount,
    );
    final total = groups.fold<int>(
      0,
      (count, group) => count + group.totalCount,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ContractSectionLabel(
          icon: title.startsWith('Machine')
              ? AppIcons.dns_rounded
              : AppIcons.verified_user_rounded,
          title: title,
          detail: total == 0 ? null : '$enabled/$total ready',
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
                    child: _CapabilitySummaryGroup(group: group),
                  ),
                )
                .toList(growable: false),
          ),
      ],
    );
  }
}

class _CapabilitySummaryGroup extends StatelessWidget {
  const _CapabilitySummaryGroup({required this.group});

  final _CapabilityGroup group;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final allEnabled = group.enabledCount == group.totalCount;
    return MeshSurface(
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: colors.infoMuted,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(group.icon, size: 15, color: colors.info),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  group.title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: AppWeights.title,
                  ),
                ),
              ),
              _TinyStatusPill(
                label: '${group.enabledCount}/${group.totalCount}',
                tone: allEnabled ? MeshPillTone.success : MeshPillTone.warning,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: group.features
                .map((feature) {
                  return _CapabilityStatusChip(feature: feature);
                })
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _CapabilityStatusChip extends StatelessWidget {
  const _CapabilityStatusChip({required this.feature});

  final _CapabilityFeature feature;

  @override
  Widget build(BuildContext context) {
    return MeshPill(
      label: feature.label,
      icon: feature.enabled ? AppIcons.check_rounded : AppIcons.remove_rounded,
      tone: feature.enabled ? MeshPillTone.success : MeshPillTone.neutral,
      mono: true,
    );
  }
}

class _ContractSectionLabel extends StatelessWidget {
  const _ContractSectionLabel({
    required this.icon,
    required this.title,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      children: [
        Icon(icon, size: 16, color: colors.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colors.textSecondary,
              fontWeight: AppWeights.title,
            ),
          ),
        ),
        if (detail != null)
          Text(
            detail!,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
          ),
      ],
    );
  }
}

class _TinyStatusPill extends StatelessWidget {
  const _TinyStatusPill({required this.label, required this.tone});

  final String label;
  final MeshPillTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final toneColors = meshPillColors(colors, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: toneColors.background,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: toneColors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: toneColors.foreground,
          fontWeight: AppWeights.title,
        ),
      ),
    );
  }
}

String _initialProviderKind(NodeInfo node) {
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

String _providerDisplayName(NodeInfo node, ProviderDefinitionSummary summary) {
  if (summary.displayName.isNotEmpty) {
    return summary.displayName;
  }
  if (summary.kind == node.provider || summary.kind.isEmpty) {
    return node.providerDisplayName;
  }
  return summary.kind;
}

String _providerDisplayVersion(
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

String? _providerCommand(NodeInfo node, ProviderDefinitionSummary summary) {
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

class _ProviderContractSummaryCard extends StatelessWidget {
  const _ProviderContractSummaryCard({required this.node});

  final NodeInfo node;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final supportedProviders = node.supportedProviders.length;
    final providerCountLabel = _agentAvailabilityLabel(supportedProviders);
    return MeshCard(
      tone: MeshCardTone.muted,
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppShapes.card,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HostProviderContractScreen(node: node),
              ),
            );
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: colors.infoMuted,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: colors.info.withValues(alpha: 0.3),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(AppIcons.hub_rounded, color: colors.info, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Agents on this machine',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: AppWeights.title,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${node.providerDisplayName} in use, $providerCountLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  AppIcons.chevron_right_rounded,
                  color: colors.textTertiary,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
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
            child: Icon(AppIcons.hub_rounded, color: colors.info, size: 16),
          ),
          title: Text(
            'Agents on this machine',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: AppWeights.title),
          ),
          subtitle: Text(
            '$selectedDisplayName · $selectedVersion',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.3,
            ),
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MeshPill(
                    label: _agentInUseLabel(node.providerDisplayName),
                    icon: AppIcons.radio_button_checked_rounded,
                    tone: isViewingActiveProvider
                        ? MeshPillTone.success
                        : MeshPillTone.neutral,
                  ),
                  if (!isViewingActiveProvider)
                    MeshPill(
                      label: _agentViewingLabel(selectedDisplayName),
                      icon: AppIcons.visibility_rounded,
                      tone: MeshPillTone.accent,
                    ),
                  if (selectedCommand != null)
                    MeshPill(
                      label: _agentCommandLabel(selectedCommand),
                      icon: AppIcons.terminal_rounded,
                      tone: MeshPillTone.neutral,
                    ),
                  MeshPill(
                    label: _agentAvailabilityLabel(supportedProviders.length),
                    icon: AppIcons.extension_rounded,
                    tone: supportedProviders.isEmpty
                        ? MeshPillTone.warning
                        : MeshPillTone.info,
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
              title: 'Agent features',
              emptyText: 'This agent did not report any extra features.',
              groups: providerGroups,
            ),
            const SizedBox(height: 12),
            _CapabilityMatrix(
              title: 'Machine features',
              emptyText: 'This machine did not report any extra features.',
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
          'Available agents',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: colors.textSecondary,
            fontWeight: AppWeights.title,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Choose one to see what it can do.',
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
                      ? '${provider.displayName} in use'
                      : provider.displayName,
                  icon: active
                      ? AppIcons.check_circle_rounded
                      : AppIcons.circle_outlined,
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
  final VoidCallback? onTap;

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
          child: MeshPill(label: label, icon: icon, tone: tone),
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
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: AppWeights.title,
                  ),
                ),
              ),
              MeshPill(
                label: '${group.enabledCount}/${group.totalCount}',
                tone: allEnabled ? MeshPillTone.success : MeshPillTone.warning,
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
                        ? AppIcons.check_rounded
                        : AppIcons.remove_rounded,
                    tone: feature.enabled
                        ? MeshPillTone.success
                        : MeshPillTone.neutral,
                    bold: false,
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colors.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppWeights.title,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
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
    'interaction' => 'Follow-ups',
    'approvals' => 'Approvals',
    'configuration' => 'Setup',
    'runtimeControls' => 'Session controls',
    'workspace' => 'Files & Git',
    _ => _humanizeCamelCase(key),
  };
}

IconData _capabilitySectionIcon(String key) {
  return switch (key) {
    'sessions' => AppIcons.forum_rounded,
    'input' => AppIcons.input_rounded,
    'interaction' => AppIcons.rate_review_rounded,
    'approvals' => AppIcons.verified_user_rounded,
    'configuration' => AppIcons.tune_rounded,
    'runtimeControls' => AppIcons.speed_rounded,
    'workspace' => AppIcons.folder_special_rounded,
    _ => AppIcons.extension_rounded,
  };
}

String _capabilityFeatureLabel(String key) {
  return switch (key) {
    'imageUrl' => 'image URL',
    'localImage' => 'local image',
    'eventReplay' => 'event replay',
    'recentFallback' => 'recent fallback',
    'skillManagement' => 'skills',
    'mode' => 'work style',
    'reasoningEffort' => 'thinking',
    'fastMode' => 'fast mode',
    'approvalPolicy' => 'approvals',
    'sandboxMode' => 'workspace access',
    'networkAccess' => 'network access',
    'webSearch' => 'web search',
    'gitStatus' => 'git status',
    'gitDiff' => 'git diff',
    'portForwarding' => 'port forwarding',
    'approveForSession' => 'remember approval',
    'userInput' => 'ask for input',
    'elicitation' => 'forms',
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

class _WorkspaceLaunchRow extends StatelessWidget {
  const _WorkspaceLaunchRow({required this.workspaces, required this.onTap});

  final List<WorkspaceSummary> workspaces;
  final ValueChanged<WorkspaceSummary> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: workspaces.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) {
          final ws = workspaces[i];
          return InkWell(
            borderRadius: AppShapes.pill,
            onTap: () => onTap(ws),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: AppShapes.pill,
                border: Border.all(color: colors.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.folder_rounded, size: 14, color: colors.accent),
                  const SizedBox(width: 6),
                  Text(
                    ws.label,
                    style: monoStyle(
                      color: colors.textPrimary,
                      fontSize: 12,
                      fontWeight: AppWeights.emphasis,
                    ),
                  ),
                  if (ws.sessionCount > 1) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceElevated,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(
                        '${ws.sessionCount}',
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 10,
                          fontWeight: AppWeights.emphasis,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HostManagementCard extends StatefulWidget {
  const _HostManagementCard({
    required this.host,
    required this.api,
    required this.node,
    required this.checkingUpdateInfo,
    required this.onRefresh,
  });

  final HostProfile host;
  final ApiClient api;
  final NodeInfo node;
  final bool checkingUpdateInfo;
  final Future<void> Function() onRefresh;

  @override
  State<_HostManagementCard> createState() => _HostManagementCardState();
}

class _HostManagementCardState extends State<_HostManagementCard> {
  bool _updating = false;
  bool _restartingDaemon = false;
  bool _restartingProvider = false;
  bool _savingUpdateChannel = false;

  DateTime? _updateStartedAt;
  String? _updatePreviousVersion;
  String? _updatePreviousCommitSha;
  String? _updateTargetLabel;
  String? _updateChannelAtStart;
  late String _selectedUpdateChannel;

  @override
  void initState() {
    super.initState();
    _selectedUpdateChannel = widget.node.updateChannel;
  }

  @override
  void didUpdateWidget(covariant _HostManagementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.id != widget.host.id ||
        oldWidget.node.updateChannel != widget.node.updateChannel) {
      _selectedUpdateChannel = widget.node.updateChannel;
    }
  }

  bool get _supportsRestart => widget.node
      .capabilitiesForProvider(null)
      .supports('lifecycle', 'restart');

  bool get _updateSupported => widget.node.updateSupported;

  bool get _supportsChannelSelection =>
      _updateSupported && widget.node.installType == 'git';

  bool get _useBleedingEdgeForNextUpdate =>
      _selectedUpdateChannel == 'bleeding-edge';

  String get _providerDisplayName => widget.node.providerDisplayName;

  Future<void> _restartProvider() async {
    if (_restartingProvider) return;
    setState(() => _restartingProvider = true);
    try {
      await widget.api.restartProvider(widget.host, widget.node.provider);
      if (!mounted) return;
      showAppSnackBar(context, 'Restarting $_providerDisplayName…');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Restart failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _restartingProvider = false);
    }
  }

  Future<void> _restartDaemon() async {
    if (_restartingDaemon) return;
    setState(() => _restartingDaemon = true);
    try {
      await widget.api.restartDaemon(widget.host);
      if (!mounted) return;
      showAppSnackBar(context, 'Restarting Sidemesh…');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Restart failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _restartingDaemon = false);
    }
  }

  Future<void> _pickUpdateChannel() async {
    if (!_supportsChannelSelection || _savingUpdateChannel) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) {
        final colors = context.colors;
        return MeshBottomSheetScaffold(
          icon: AppIcons.system_update_rounded,
          title: 'Choose release track',
          description:
              'Stable gets tagged releases. Early access gets the newest changes.',
          maxWidth: 560,
          maxHeightFactor: 0.44,
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: [
              MeshListRow(
                framed: false,
                dense: true,
                radius: AppRadii.control,
                leading: Icon(AppIcons.verified_rounded, color: colors.accent),
                title: const Text('Stable'),
                subtitle: const Text('Tagged releases'),
                trailing: _selectedUpdateChannel == 'stable'
                    ? Icon(AppIcons.check_rounded, color: colors.accent)
                    : null,
                onTap: () => Navigator.of(context).pop('stable'),
              ),
              MeshListRow(
                framed: false,
                dense: true,
                radius: AppRadii.control,
                leading: Icon(AppIcons.science_rounded, color: colors.accent),
                title: const Text('Early access'),
                subtitle: const Text('Newest changes'),
                trailing: _selectedUpdateChannel == 'bleeding-edge'
                    ? Icon(AppIcons.check_rounded, color: colors.accent)
                    : null,
                onTap: () => Navigator.of(context).pop('bleeding-edge'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || selected == null || selected == _selectedUpdateChannel) {
      return;
    }
    setState(() => _savingUpdateChannel = true);
    try {
      await widget.api.setUpdateChannel(widget.host, selected);
      if (!mounted) return;
      setState(() => _selectedUpdateChannel = selected);
      var refreshFailed = false;
      try {
        await widget.onRefresh();
      } catch (_) {
        refreshFailed = true;
      }
      if (!mounted) return;
      showAppSnackBar(
        context,
        refreshFailed
            ? 'Release track saved, but refresh failed.'
            : 'Release track set to ${_releaseTrackLabel(selected)}.',
      );
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Could not save the release track: ${friendlyError(e)}',
      );
    } finally {
      if (mounted) setState(() => _savingUpdateChannel = false);
    }
  }

  String get _updateDialogTitle {
    if (_useBleedingEdgeForNextUpdate) {
      return 'Install the newest Early access build?';
    }
    final current = widget.node.packageVersion;
    final latest = widget.node.latestVersion;
    if (current != null &&
        current.isNotEmpty &&
        latest != null &&
        latest.isNotEmpty) {
      return 'Update Sidemesh to v$latest?';
    }
    return 'Update Sidemesh?';
  }

  Future<void> _updateDaemon() async {
    if (_updating || _updateStartedAt != null) return;

    final prefs = await SharedPreferences.getInstance();
    final skipConfirm = prefs.getBool('sidemesh_update_skip_confirm') ?? false;

    if (!mounted) return;
    if (!skipConfirm) {
      bool skipNextTime = false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => MeshDialogScaffold(
          icon: AppIcons.system_update_alt_rounded,
          title: _updateDialogTitle,
          description: _useBleedingEdgeForNextUpdate
              ? 'This installs the newest Early access build of Sidemesh on this machine.'
              : 'This installs the latest available Sidemesh update on this machine.',
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Update now'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Open terminals, forwarded ports, and browser previews disconnect while the update starts.',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: dialogContext.colors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              StatefulBuilder(
                builder: (context, setLocalState) {
                  return MeshListRow(
                    framed: false,
                    dense: true,
                    radius: AppRadii.control,
                    onTap: () {
                      setLocalState(() => skipNextTime = !skipNextTime);
                    },
                    title: const Text('Skip this confirmation next time'),
                    trailing: Checkbox(
                      value: skipNextTime,
                      onChanged: (v) {
                        setLocalState(() => skipNextTime = v ?? false);
                      },
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );

      if (confirmed == true && skipNextTime) {
        await prefs.setBool('sidemesh_update_skip_confirm', true);
      }
      if (confirmed != true) return;
    }

    if (!mounted) return;

    setState(() => _updating = true);
    try {
      await widget.api.updateDaemon(
        widget.host,
        updateChannel: _selectedUpdateChannel,
      );
      if (!mounted) return;
      setState(() {
        _updateStartedAt = DateTime.now();
        _updatePreviousVersion = widget.node.packageVersion;
        _updatePreviousCommitSha = widget.node.currentCommitSha;
        _updateTargetLabel = _targetUpdateLabel();
        _updateChannelAtStart = _selectedUpdateChannel;
      });
      showAppSnackBar(context, 'Starting Sidemesh update…');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Update failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _openTerminal() async {
    final cwd = widget.node.homeDirectory ?? '/';
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalScreen(
          host: widget.host,
          api: widget.api,
          cwd: cwd,
          title: 'Terminal · ${widget.host.label}',
        ),
      ),
    );
  }

  String _targetUpdateLabel() {
    if (_useBleedingEdgeForNextUpdate) {
      return widget.node.shortLatestCommitSha == null
          ? 'latest Early access build'
          : 'Early access build ${widget.node.shortLatestCommitSha}';
    }
    final latestVersion = widget.node.latestVersion;
    if (latestVersion != null && latestVersion.isNotEmpty) {
      return 'v$latestVersion';
    }
    return 'latest version';
  }

  String _updateChannelDetail() {
    final configured = _selectedUpdateChannel == widget.node.updateChannel;
    final base = _releaseTrackDetail(_selectedUpdateChannel);
    return configured ? base : '$base · next update only';
  }

  String _updateDetail() {
    final isOffline =
        HostStatusStore.instance.statusFor(widget.host.id).reachability ==
        HostReachability.offline;
    if (isOffline) {
      return 'Machine offline, cannot update';
    }
    if (widget.checkingUpdateInfo) {
      return 'Checking for updates…';
    }

    if (widget.node.usesBleedingEdgeTrack) {
      final current = widget.node.currentInstallLabel;
      final latest = widget.node.latestInstallLabel;
      if (!widget.node.updateAvailable) {
        return 'Up to date · $current';
      }
      if (widget.node.shortCurrentCommitSha != null &&
          widget.node.shortLatestCommitSha != null) {
        return '$current → $latest';
      }
      return current;
    }

    final packageVersion = widget.node.packageVersion;
    final latestVersion = widget.node.latestVersion;
    final hasCurrent = packageVersion != null && packageVersion.isNotEmpty;
    final hasLatest = latestVersion != null && latestVersion.isNotEmpty;

    if (!widget.node.updateAvailable) {
      if (hasCurrent) return 'Up to date · v$packageVersion';
      return 'Up to date · version unavailable';
    }

    if (hasCurrent && hasLatest) {
      return 'v$packageVersion → v$latestVersion';
    }
    if (hasCurrent) {
      return 'Current version: v$packageVersion';
    }
    return 'Version unavailable';
  }

  IconData get _updateIcon {
    if (widget.checkingUpdateInfo) {
      return AppIcons.sync_rounded;
    }
    if (!widget.node.updateAvailable) {
      return AppIcons.check_circle_rounded;
    }
    return AppIcons.system_update_alt_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: HostStatusStore.instance,
      builder: (context, _) {
        final colors = context.colors;
        final isOffline =
            HostStatusStore.instance.statusFor(widget.host.id).reachability ==
            HostReachability.offline;

        return MeshCard(
          tone: MeshCardTone.muted,
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_updateStartedAt != null) ...[
                _UpdateProgressBanner(
                  hostId: widget.host.id,
                  startedAt: _updateStartedAt!,
                  targetLabel: _updateTargetLabel,
                  previousVersion: _updatePreviousVersion,
                  previousCommitSha: _updatePreviousCommitSha,
                  updateChannel:
                      _updateChannelAtStart ?? widget.node.updateChannel,
                  currentNode: widget.node,
                  onDismiss: () => setState(() => _updateStartedAt = null),
                  onRetry: () {
                    setState(() => _updateStartedAt = null);
                    unawaited(_updateDaemon());
                  },
                ),
                Divider(height: 1, color: colors.border),
              ],
              if (widget.node.supportsHostCapability('workspace', 'terminal'))
                _ManagementRow(
                  icon: AppIcons.terminal_rounded,
                  label: 'Open terminal',
                  detail: 'Open a shell on this machine.',
                  busy: false,
                  onTap: _openTerminal,
                ),
              if (widget.node.supportsHostCapability('workspace', 'terminal'))
                Divider(height: 1, indent: 46, color: colors.border),
              if (_supportsRestart)
                _ManagementRow(
                  icon: AppIcons.refresh_rounded,
                  label: 'Restart $_providerDisplayName',
                  detail: 'Leaves terminals and forwarded ports running.',
                  busy: _restartingProvider,
                  onTap: _restartProvider,
                ),
              if (_supportsRestart)
                Divider(height: 1, indent: 46, color: colors.border),
              if (_supportsChannelSelection)
                _ManagementRow(
                  icon: AppIcons.alt_route_rounded,
                  label: 'Release track',
                  detail: _updateChannelDetail(),
                  busy: _savingUpdateChannel,
                  onTap: _pickUpdateChannel,
                ),
              if (_supportsChannelSelection)
                Divider(height: 1, indent: 46, color: colors.border),
              if (_updateSupported)
                _ManagementRow(
                  icon: _updateIcon,
                  label: 'Update Sidemesh',
                  detail: _updateDetail(),
                  busy: _updating || widget.checkingUpdateInfo,
                  onTap: isOffline || _updateStartedAt != null
                      ? null
                      : () => unawaited(_updateDaemon()),
                ),
              if (_updateSupported)
                Divider(height: 1, indent: 46, color: colors.border),
              _ManagementRow(
                icon: AppIcons.restart_alt_rounded,
                label: 'Restart Sidemesh',
                detail: 'Reconnects automatically after the restart.',
                busy: _restartingDaemon,
                onTap: _restartDaemon,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UpdateProgressBanner extends StatelessWidget {
  const _UpdateProgressBanner({
    required this.hostId,
    required this.startedAt,
    required this.targetLabel,
    required this.previousVersion,
    required this.previousCommitSha,
    required this.updateChannel,
    required this.currentNode,
    required this.onDismiss,
    required this.onRetry,
  });

  final String hostId;
  final DateTime startedAt;
  final String? targetLabel;
  final String? previousVersion;
  final String? previousCommitSha;
  final String updateChannel;
  final NodeInfo currentNode;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final status = HostStatusStore.instance.statusFor(hostId);
    final elapsed = DateTime.now().difference(startedAt);

    if (elapsed < const Duration(seconds: 5)) {
      return _buildUpdating(context, colors);
    }

    if (status.reachability == HostReachability.online) {
      final changed = updateChannel == 'bleeding-edge'
          ? currentNode.currentCommitSha != null &&
                currentNode.currentCommitSha != previousCommitSha
          : currentNode.packageVersion != null &&
                currentNode.packageVersion!.isNotEmpty &&
                currentNode.packageVersion != previousVersion;
      if (changed) {
        return _buildSuccess(context, colors, _successLabel());
      }
      return _buildFailure(context, colors);
    }

    if (elapsed > const Duration(seconds: 60)) {
      return _buildFailure(context, colors);
    }

    return _buildUpdating(context, colors);
  }

  String _successLabel() {
    if (updateChannel == 'bleeding-edge') {
      final sha = currentNode.shortCurrentCommitSha;
      return sha == null
          ? 'latest Early access build'
          : 'Early access build $sha';
    }
    final version = currentNode.packageVersion;
    if (version != null && version.isNotEmpty) {
      return 'v$version';
    }
    return currentNode.currentInstallLabel;
  }

  Widget _buildUpdating(BuildContext context, AppColors colors) {
    return _buildRow(
      context,
      colors: colors,
      icon: AppIcons.update_rounded,
      iconColor: colors.accent,
      title: 'Installing ${targetLabel ?? 'latest update'}…',
      subtitle: 'This usually takes 20 to 45 seconds',
      showSpinner: true,
    );
  }

  Widget _buildSuccess(BuildContext context, AppColors colors, String label) {
    return _buildRow(
      context,
      colors: colors,
      icon: AppIcons.check_circle_rounded,
      iconColor: colors.success,
      title: 'Updated to $label',
      showDismiss: true,
    );
  }

  Widget _buildFailure(BuildContext context, AppColors colors) {
    return InkWell(
      onTap: onRetry,
      child: _buildRow(
        context,
        colors: colors,
        icon: AppIcons.error_outline_rounded,
        iconColor: colors.danger,
        title: 'Update did not finish',
        subtitle: 'Tap to try again',
        showDismiss: true,
      ),
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required AppColors colors,
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    bool showSpinner = false,
    bool showDismiss = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: iconColor.withValues(alpha: 0.35)),
            ),
            alignment: Alignment.center,
            child: showSpinner
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: iconColor,
                    ),
                  )
                : Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: AppWeights.emphasis,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showDismiss)
            MeshIconButton(
              icon: AppIcons.close_rounded,
              onTap: onDismiss,
              color: colors.textSecondary,
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshListRow(
      framed: false,
      dense: true,
      radius: AppRadii.control,
      enabled: !busy,
      onTap: busy ? null : onTap,
      leading: Container(
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
      title: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontWeight: AppWeights.emphasis),
      ),
      subtitle: Text(
        detail,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
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

  _HostOverview copyWith({NodeInfo? node}) {
    return _HostOverview(
      node: node ?? this.node,
      workspaces: workspaces,
      sessions: sessions,
    );
  }
}
