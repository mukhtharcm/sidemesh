import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart' show ApiClient, ApiException, friendlyError;
import '../app_version_store.dart';
import '../mobile_client_version_policy.dart';
import '../models.dart';
import '../host_status_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_sheets.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/app_menu.dart';
import '../widgets/mesh_widgets.dart';
import '../widgets/app_primitives.dart';
import 'create_session_sheet.dart';
import 'terminal_screen.dart';
import '../theme/app_status_styles.dart';

String _releaseTrackLabel(String value) {
  return value == 'bleeding-edge' ? 'Early access' : 'Stable';
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
  final AppVersionStore _appVersionStore = AppVersionStore.instance;
  late Future<NodeInfo> _future;
  Timer? _refreshTimer;
  bool _terminalOpen = false;
  String _terminalCwd = '/';
  Future<void>? _updateInfoRefresh;
  AppLifecycleState? _lifecycleState;
  static const Duration _refreshInterval = Duration(minutes: 1);

  @override
  void initState() {
    super.initState();

    _lifecycleState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
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
      setState(() {
        _future = Future.value(fresh);
      });
    } catch (_) {
      // Keep the last good snapshot on transient errors.
    }
  }

  Future<NodeInfo> _load() => widget.api.fetchNode(widget.host);

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
    });
    try {
      await _future;
    } catch (_) {
      // The page shows the load error and Retry action.
      return;
    }
    if (mounted) unawaited(_refreshUpdateInfo());
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
    try {
      final info = await widget.api.refreshUpdateInfo(widget.host);
      final node = await _future;
      if (!mounted) return;
      setState(() {
        _future = Future.value(node.copyWithUpdateInfo(info));
      });
    } catch (_) {
      // Keep the existing snapshot if the update check cannot reach the remote.
    } finally {
      _updateInfoRefresh = null;
    }
  }

  bool _shouldShowMobileCompatibility(NodeInfo node) {
    if (!widget.showMobileClientCompatibility ||
        !node.advertisesMobileClientVersionHints) {
      return false;
    }
    return evaluateMobileClientCompatibility(
          installedVersion: _appVersionStore.info.comparableVersion,
          recommendedVersion: node.recommendedMobileClientVersion,
          minimumVersion: node.minimumMobileClientVersion,
        ).level !=
        MobileClientCompatibilityLevel.none;
  }

  Future<void> _startSession() async {
    final created = await showCreateSessionLauncher(
      context,
      host: widget.host,
      api: widget.api,
    );
    if (created != null && mounted) {
      widget.onOpenSession(created);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (widget.embedded && _terminalOpen) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topPadding),
        child: TerminalScreen(
          host: widget.host,
          api: widget.api,
          cwd: _terminalCwd,
          onClose: () => setState(() => _terminalOpen = false),
        ),
      );
    }
    if (widget.embedded) {
      return Container(
        color: colors.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(height: widget.topPadding),
            _EmbeddedHostHeader(host: widget.host, onRefresh: _refresh),
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
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<NodeInfo>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return MeshLoader(label: 'Loading machine');
        }
        if (snapshot.hasError && !snapshot.hasData) {
          return MeshEmptyState(
            icon: Icons.wifi_off_rounded,
            title: 'Could not reach machine',
            body: friendlyError(snapshot.error!),
            action: TextButton(onPressed: _refresh, child: const Text('Retry')),
          );
        }
        final node = snapshot.data!;
        return AppContentColumn(
          maxWidth: AppSizes.readingMaxWidth,
          child: RefreshIndicator(
            color: colors.accent,
            onRefresh: _refresh,
            child: ListView(
              padding: widget.embedded
                  ? AppPadding.desktopPage
                  : AppPadding.mobilePage.copyWith(bottom: AppSpacing.xl),
              children: [
                _NodeCard(
                  host: widget.host,
                  node: node,
                  showAddress: !widget.embedded,
                ),
                const SizedBox(height: AppSpacing.sm),
                _MachineAgents(node: node),
                if (_shouldShowMobileCompatibility(node)) ...[
                  const SizedBox(height: AppSpacing.md),
                  _MobileClientCompatibilityCard(
                    node: node,
                    appVersionInfo: _appVersionStore.info,
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                _HostManagementCard(
                  onNewSession: () => _startSession(),
                  host: widget.host,
                  api: widget.api,
                  node: node,
                  onRefresh: _refresh,
                  onOpenTerminal: widget.embedded
                      ? () => setState(() {
                          _terminalCwd = node.homeDirectory ?? '/';
                          _terminalOpen = true;
                        })
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _EmbeddedHostHeader extends StatelessWidget {
  const _EmbeddedHostHeader({required this.host, required this.onRefresh});

  final HostProfile host;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return AppContentColumn(
      maxWidth: AppSizes.readingMaxWidth,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.desktopGutter,
          AppSpacing.md,
          AppSizes.desktopGutter,
          AppSpacing.md,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      host.label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    SelectableText(
                      host.baseUrl,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: onRefresh,
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({
    required this.host,
    required this.node,
    required this.showAddress,
  });

  final bool showAddress;

  final HostProfile host;
  final NodeInfo node;

  @override
  Widget build(BuildContext context) {
    final platform = switch (node.platform) {
      'darwin' => 'macOS',
      'linux' => 'Linux',
      'win32' => 'Windows',
      _ => node.platform,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: SelectableText(
        [
          if (showAddress) host.baseUrl,
          platform,
          if (node.packageVersion != null) 'Sidemesh ${node.packageVersion}',
        ].join(' · '),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: context.colors.textSecondary),
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
      borderColor: accent.withValues(alpha: AppEmphasis.disabled),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: accentMuted,
              borderRadius: AppShapes.iconWell,
              border: Border.all(
                color: accent.withValues(alpha: AppEmphasis.borderTint),
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.phone_android_rounded,
              color: accent,
              size: AppSizes.inlineIcon,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
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
                const SizedBox(height: AppSpacing.xs),
                Text(
                  guidance,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: AppLineHeights.label,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    MeshPill(
                      label: appVersionInfo.displayVersion,
                      icon: Icons.smartphone_rounded,
                      tone: MeshPillTone.neutral,
                      mono: true,
                    ),
                    if ((node.minimumMobileClientVersion ?? '').isNotEmpty)
                      MeshPill(
                        label:
                            'minimum ${mobileClientVersionLabel(node.minimumMobileClientVersion!)}',
                        icon: Icons.lock_outline_rounded,
                        tone: requiresUpdate
                            ? MeshPillTone.danger
                            : MeshPillTone.neutral,
                        mono: true,
                      ),
                    if ((node.recommendedMobileClientVersion ?? '').isNotEmpty)
                      MeshPill(
                        label:
                            'recommended ${mobileClientVersionLabel(node.recommendedMobileClientVersion!)}',
                        icon: Icons.system_update_alt_rounded,
                        tone: recommendsUpdate
                            ? MeshPillTone.info
                            : MeshPillTone.neutral,
                        mono: true,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
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

class _MachineAgents extends StatelessWidget {
  const _MachineAgents({required this.node});

  final NodeInfo node;

  @override
  Widget build(BuildContext context) {
    final providers = node.supportedProviders;
    final names = providers.isEmpty
        ? ['${node.providerDisplayName} (default)']
        : providers.map((provider) {
            final name = provider.displayName.isEmpty
                ? provider.kind
                : provider.displayName;
            return provider.isDefault ? '$name (default)' : name;
          });
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Text(
        'Agents: ${names.join(' · ')}',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}

class _HostManagementCard extends StatefulWidget {
  const _HostManagementCard({
    required this.host,
    required this.api,
    required this.node,
    required this.onRefresh,
    required this.onNewSession,
    this.onOpenTerminal,
  });

  final VoidCallback onNewSession;
  final VoidCallback? onOpenTerminal;
  final HostProfile host;
  final ApiClient api;
  final NodeInfo node;
  final Future<void> Function() onRefresh;

  @override
  State<_HostManagementCard> createState() => _HostManagementCardState();
}

class _HostManagementCardState extends State<_HostManagementCard> {
  static const Duration _updateStatusPollInterval = Duration(seconds: 2);
  static const Duration _recentUpdateWindow = Duration(minutes: 10);

  bool _updating = false;
  bool _restartingDaemon = false;
  bool _restartingProvider = false;
  bool _savingUpdateChannel = false;
  bool _pollingUpdateStatus = false;
  int _updateStatusPollFailures = 0;
  Timer? _updateStatusTimer;
  UpdateOperation? _updateOperation;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_restoreUpdateStatus());
    });
  }

  @override
  void didUpdateWidget(covariant _HostManagementCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.id != widget.host.id ||
        oldWidget.node.updateChannel != widget.node.updateChannel) {
      _selectedUpdateChannel = widget.node.updateChannel;
    }
    if (oldWidget.host.id != widget.host.id) {
      _updateStatusTimer?.cancel();
      _updateStatusTimer = null;
      _updateStatusPollFailures = 0;
      _updateOperation = null;
      _updateStartedAt = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_restoreUpdateStatus());
      });
    }
  }

  @override
  void dispose() {
    _updateStatusTimer?.cancel();
    super.dispose();
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

  Future<void> _restoreUpdateStatus() async {
    final hostId = widget.host.id;
    try {
      final operation = await widget.api.fetchUpdateStatus(widget.host);
      if (!mounted || widget.host.id != hostId || operation == null) return;
      final lastChanged =
          operation.finishedDateTime ?? operation.updatedDateTime;
      if (!operation.isInProgress &&
          DateTime.now().difference(lastChanged) > _recentUpdateWindow) {
        return;
      }
      _applyUpdateOperation(operation);
    } catch (error) {
      if (!mounted || widget.host.id != hostId) return;
      if (_shouldRetryUpdateStatus(error)) {
        // The app may have reopened during daemon cutover. Retry transient
        // connection failures long enough to recover the persisted operation.
        _startUpdateStatusPolling();
      }
      // Older daemons return 404. Keep their legacy inference fallback.
    }
  }

  void _applyUpdateOperation(UpdateOperation operation) {
    if (!mounted) return;
    setState(() {
      _updateStatusPollFailures = 0;
      _updateOperation = operation;
      _updateStartedAt = operation.startedDateTime;
      _updatePreviousVersion = operation.previousVersion;
      _updatePreviousCommitSha = operation.previousCommitSha;
      _updateTargetLabel = _targetUpdateLabelForOperation(operation);
      _updateChannelAtStart = operation.channel;
    });
    if (operation.isInProgress) {
      _startUpdateStatusPolling();
    } else {
      _updateStatusTimer?.cancel();
      _updateStatusTimer = null;
    }
  }

  void _startUpdateStatusPolling() {
    _updateStatusTimer ??= Timer.periodic(
      _updateStatusPollInterval,
      (_) => unawaited(_pollUpdateStatus()),
    );
    unawaited(_pollUpdateStatus());
  }

  Future<void> _pollUpdateStatus() async {
    if (_pollingUpdateStatus) return;
    _pollingUpdateStatus = true;
    final hostId = widget.host.id;
    try {
      final operation = await widget.api.fetchUpdateStatus(widget.host);
      if (!mounted || widget.host.id != hostId) return;
      if (operation == null) {
        _updateStatusPollFailures = 0;
        _updateStatusTimer?.cancel();
        _updateStatusTimer = null;
        return;
      }
      _applyUpdateOperation(operation);
      if (operation.isTerminal) {
        try {
          await widget.onRefresh();
        } catch (_) {
          // The persisted operation is authoritative even if node refresh fails.
        }
      }
    } catch (error) {
      if (!mounted || widget.host.id != hostId) return;
      if (_updateOperation == null) {
        _updateStatusPollFailures += 1;
      }
      if (!_shouldRetryUpdateStatus(error) || _updateStatusPollFailures >= 30) {
        _updateStatusTimer?.cancel();
        _updateStatusTimer = null;
      }
      // Connection failures are expected while the daemon switches releases.
      // Once an operation is known, keep polling until its terminal result.
    } finally {
      _pollingUpdateStatus = false;
    }
  }

  bool _shouldRetryUpdateStatus(Object error) {
    if (error is! ApiException) return true;
    return const {408, 429, 500, 502, 503, 504}.contains(error.statusCode);
  }

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
          title: 'Release track',
          maxWidth: AppSizes.pickerWidth,
          maxHeightFactor: 0.44,
          child: ListView(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            children: [
              MeshListRow(
                framed: false,
                dense: true,
                radius: AppRadii.control,
                title: const Text('Stable'),
                subtitle: const Text('Tagged releases'),
                trailing: _selectedUpdateChannel == 'stable'
                    ? Icon(Icons.check_rounded, color: colors.accent)
                    : null,
                onTap: () => Navigator.of(context).pop('stable'),
              ),
              MeshListRow(
                framed: false,
                dense: true,
                radius: AppRadii.control,
                title: const Text('Early access'),
                subtitle: const Text('Newest CI-verified changes'),
                trailing: _selectedUpdateChannel == 'bleeding-edge'
                    ? Icon(Icons.check_rounded, color: colors.accent)
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
          icon: Icons.system_update_alt_rounded,
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
                'Open terminals and browser tabs disconnect while the update starts.',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: dialogContext.colors.textSecondary,
                  height: AppLineHeights.body,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              StatefulBuilder(
                builder: (context, setLocalState) {
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      'Skip this confirmation next time',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    value: skipNextTime,
                    onChanged: (value) {
                      setLocalState(() => skipNextTime = value ?? false);
                    },
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
      final operation = await widget.api.updateDaemon(
        widget.host,
        updateChannel: _selectedUpdateChannel,
      );
      if (!mounted) return;
      if (operation != null) {
        _applyUpdateOperation(operation);
      } else {
        setState(() {
          _updateStartedAt = DateTime.now();
          _updatePreviousVersion = widget.node.packageVersion;
          _updatePreviousCommitSha = widget.node.currentCommitSha;
          _updateTargetLabel = _targetUpdateLabel();
          _updateChannelAtStart = _selectedUpdateChannel;
        });
      }
      showAppSnackBar(context, 'Starting Sidemesh update…');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, 'Update failed: ${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _openTerminal() async {
    if (widget.onOpenTerminal != null) {
      widget.onOpenTerminal!();
      return;
    }
    final cwd = widget.node.homeDirectory ?? '/';
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalScreen(
          host: widget.host,
          api: widget.api,
          cwd: cwd,
          title: 'Terminal',
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

  String _targetUpdateLabelForOperation(UpdateOperation operation) {
    if (operation.channel == 'bleeding-edge') {
      final sha = operation.shortTargetCommitSha;
      return sha == null
          ? 'latest verified Early access build'
          : 'verified Early access build $sha';
    }
    final version = operation.targetVersion;
    if (version != null && version.isNotEmpty) {
      return 'v${version.replaceFirst(RegExp(r'^v'), '')}';
    }
    return 'latest version';
  }

  String _updateDetail() {
    return widget.node.updateAvailable ? 'Update available' : 'Up to date';
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

        return Column(
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
                operation: _updateOperation,
                onDismiss: () => setState(() {
                  _updateOperation = null;
                  _updateStartedAt = null;
                }),
                onRetry: () {
                  setState(() {
                    _updateOperation = null;
                    _updateStartedAt = null;
                  });
                  unawaited(_updateDaemon());
                },
              ),
              Divider(height: 1, color: colors.border),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: isOffline ? null : widget.onNewSession,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('New session'),
                  ),
                  if (widget.node.supportsHostCapability(
                    'workspace',
                    'terminal',
                  ))
                    OutlinedButton.icon(
                      onPressed: isOffline ? null : _openTerminal,
                      icon: const Icon(Icons.terminal_rounded),
                      label: const Text('Open terminal'),
                    ),
                  AppMenuButton(
                    tooltip: 'More machine actions',
                    children: [
                      if (_supportsChannelSelection)
                        MenuItemButton(
                          onPressed: isOffline || _savingUpdateChannel
                              ? null
                              : _pickUpdateChannel,
                          child: const Text('Release track'),
                        ),
                      if (_supportsRestart)
                        MenuItemButton(
                          onPressed: isOffline || _restartingProvider
                              ? null
                              : _restartProvider,
                          child: Text('Restart $_providerDisplayName'),
                        ),
                      MenuItemButton(
                        onPressed: isOffline || _restartingDaemon
                            ? null
                            : _restartDaemon,
                        child: const Text('Restart Sidemesh'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_updateSupported) ...[
              const SizedBox(height: AppSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        isOffline ? 'Machine offline' : _updateDetail(),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (_updating || (_updateOperation?.isInProgress ?? false))
                      const SizedBox.square(
                        dimension: AppSizes.icon,
                        child: CircularProgressIndicator(
                          strokeWidth: AppStrokes.indicator,
                        ),
                      )
                    else if (widget.node.updateAvailable)
                      TextButton(
                        onPressed: isOffline || _updateStartedAt != null
                            ? null
                            : () => unawaited(_updateDaemon()),
                        child: const Text('Update Sidemesh'),
                      ),
                  ],
                ),
              ),
            ],
          ],
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
    required this.operation,
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
  final UpdateOperation? operation;
  final VoidCallback onDismiss;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final persistedOperation = operation;
    if (persistedOperation != null) {
      if (persistedOperation.isSucceeded) {
        return _buildSuccess(
          context,
          colors,
          _operationSuccessLabel(persistedOperation),
        );
      }
      if (persistedOperation.isFailed) {
        return _buildOperationFailure(context, colors, persistedOperation);
      }
      return _buildOperationProgress(context, colors, persistedOperation);
    }

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

  String _operationSuccessLabel(UpdateOperation operation) {
    if (operation.channel == 'bleeding-edge') {
      final sha = operation.shortInstalledCommitSha;
      return sha == null ? 'verified Early access build' : 'Early access $sha';
    }
    final version = operation.installedVersion;
    if (version != null && version.isNotEmpty) {
      return 'v${version.replaceFirst(RegExp(r'^v'), '')}';
    }
    return currentNode.currentInstallLabel;
  }

  Widget _buildOperationProgress(
    BuildContext context,
    AppColors colors,
    UpdateOperation operation,
  ) {
    final title = switch (operation.phase) {
      'queued' => 'Update queued…',
      'preflight' => 'Checking update…',
      'staging' => 'Installing update…',
      'stopping' => 'Stopping Sidemesh…',
      'switching' => 'Switching releases…',
      'starting' => 'Starting Sidemesh…',
      'verifying' => 'Verifying update…',
      'rolling_back' => 'Restoring the previous release…',
      _ => 'Updating Sidemesh…',
    };
    return _buildRow(
      context,
      colors: colors,
      icon: operation.phase == 'rolling_back'
          ? Icons.restore_rounded
          : Icons.update_rounded,
      iconColor: operation.phase == 'rolling_back'
          ? colors.warning
          : colors.accent,
      title: title,
      showSpinner: true,
    );
  }

  Widget _buildOperationFailure(
    BuildContext context,
    AppColors colors,
    UpdateOperation operation,
  ) {
    final needsAttention = operation.cutoverStarted && !operation.restored;
    final restoredDetail = operation.restored
        ? 'Previous release restored and healthy.'
        : operation.cutoverStarted
        ? 'Automatic restore could not be verified.'
        : 'The current release was left running.';
    final error = operation.error;
    final subtitle = error == null || error.isEmpty
        ? '$restoredDetail Tap to try again.'
        : '$restoredDetail $error Tap to retry.';
    return InkWell(
      onTap: onRetry,
      child: _buildRow(
        context,
        colors: colors,
        icon: operation.restored
            ? Icons.restore_rounded
            : needsAttention
            ? Icons.error_outline_rounded
            : Icons.info_outline_rounded,
        iconColor: needsAttention ? colors.danger : colors.warning,
        title: operation.restored
            ? 'Update failed — previous release restored'
            : needsAttention
            ? 'Update and rollback need attention'
            : 'Update stopped before cutover',
        subtitle: subtitle,
        showDismiss: true,
      ),
    );
  }

  Widget _buildUpdating(BuildContext context, AppColors colors) {
    return _buildRow(
      context,
      colors: colors,
      icon: Icons.update_rounded,
      iconColor: colors.accent,
      title: 'Installing ${targetLabel ?? 'latest update'}…',
      showSpinner: true,
    );
  }

  Widget _buildSuccess(BuildContext context, AppColors colors, String label) {
    return _buildRow(
      context,
      colors: colors,
      icon: Icons.check_circle_rounded,
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
        icon: Icons.error_outline_rounded,
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
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: AppEmphasis.tint),
              borderRadius: AppShapes.iconWell,
              border: Border.all(
                color: iconColor.withValues(alpha: AppEmphasis.muted),
              ),
            ),
            alignment: Alignment.center,
            child: showSpinner
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: AppStrokes.focus,
                      color: iconColor,
                    ),
                  )
                : Icon(icon, size: AppSizes.compactIcon, color: iconColor),
          ),
          const SizedBox(width: AppSpacing.md),
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
                  const SizedBox(height: AppSpacing.xxs),
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
              icon: Icons.close_rounded,
              onTap: onDismiss,
              color: colors.textSecondary,
            ),
        ],
      ),
    );
  }
}
