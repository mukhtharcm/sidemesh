import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../background_sync_service.dart';
import '../create_session_defaults_store.dart';
import '../image_blob_cache_store.dart';
import '../live_activity_service.dart';
import '../local_notification_service.dart';
import '../screen_awake_settings_store.dart';
import '../session_cache_store.dart';
import '../session_policy_store.dart';
import '../session_send_outbox_store.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/appearance_sheet.dart';
import '../widgets/mesh_widgets.dart';
import '../onboarding_store.dart';
import 'onboarding_screen.dart';

Future<void> openSettingsScreen(
  BuildContext context, {
  VoidCallback? onResetSidebarWidth,
  VoidCallback? onResetInspectorWidth,
}) {
  final desktop = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
  if (desktop) {
    final colors = context.colors;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 860),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: colors.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 40,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            child: SettingsScreen(
              embedded: true,
              onClose: () => Navigator.of(dialogContext).pop(),
              onResetSidebarWidth: onResetSidebarWidth,
              onResetInspectorWidth: onResetInspectorWidth,
            ),
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(
        onResetSidebarWidth: onResetSidebarWidth,
        onResetInspectorWidth: onResetInspectorWidth,
      ),
    ),
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.embedded = false,
    this.onClose,
    this.onResetSidebarWidth,
    this.onResetInspectorWidth,
  });

  final bool embedded;
  final VoidCallback? onClose;
  final VoidCallback? onResetSidebarWidth;
  final VoidCallback? onResetInspectorWidth;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final CreateSessionDefaultsStore _defaultsStore =
      CreateSessionDefaultsStore.instance;
  final ScreenAwakeSettingsStore _screenAwakeStore =
      ScreenAwakeSettingsStore.instance;

  bool _notificationsLoading = true;
  bool _notificationsRequesting = false;
  bool _notificationsSupported = false;
  bool _notificationsAllowed = false;
  bool _liveActivitiesSupported = false;
  String? _busyAction;

  @override
  void initState() {
    super.initState();
    unawaited(_defaultsStore.ensureLoaded());
    unawaited(_screenAwakeStore.ensureLoaded());
    unawaited(_refreshNotificationStatus());
  }

  Future<void> _refreshNotificationStatus() async {
    final notificationService = LocalNotificationService.instance;
    final supported = notificationService.isSupported;
    final allowed = supported
        ? await notificationService.checkPermissions()
        : false;
    final liveActivities = await LiveActivityService.instance
        .isSupportedForCurrentDevice();
    if (!mounted) return;
    setState(() {
      _notificationsSupported = supported;
      _notificationsAllowed = allowed;
      _liveActivitiesSupported = liveActivities;
      _notificationsLoading = false;
    });
  }

  Future<void> _requestNotifications() async {
    if (_notificationsRequesting) return;
    setState(() => _notificationsRequesting = true);
    final allowed = await LocalNotificationService.instance
        .requestPermissions();
    if (!mounted) return;
    setState(() {
      _notificationsAllowed = allowed;
      _notificationsRequesting = false;
    });
    showAppSnackBar(
      context,
      allowed
          ? 'Approval alerts enabled.'
          : 'Notifications were not enabled on this device.',
    );
  }

  Future<void> _editLaunchDefaults() async {
    if (!mounted) return;
    final desktop = widget.embedded;
    bool? updated;
    if (desktop) {
      updated = await showDialog<bool>(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 36,
            vertical: 28,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: const _LaunchDefaultsSheet(embedded: true),
          ),
        ),
      );
    } else {
      updated = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const _LaunchDefaultsSheet(),
      );
    }
    if (!mounted) return;
    if (updated == true) {
      showAppSnackBar(context, 'New session defaults updated.');
    }
  }

  Future<void> _runStorageAction({
    required String key,
    required String title,
    required String body,
    required Future<void> Function() action,
    required String successMessage,
  }) async {
    if (_busyAction != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = dialogContext.colors;
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyAction = key);
    try {
      await action();
      if (!mounted) return;
      showAppSnackBar(context, successMessage);
    } finally {
      if (mounted) {
        setState(() => _busyAction = null);
      }
    }
  }

  Future<void> _replayOnboarding() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = dialogContext.colors;
        return AlertDialog(
          backgroundColor: colors.surface,
          title: const Text('Replay onboarding?'),
          content: const Text(
            'This will show the first-run guide again. You can skip it at any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Replay'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await OnboardingStore.instance.reset();
    if (!mounted) return;
    await showOnboardingScreen(context, themeController: ThemeScope.of(context));
  }

  String _platformLabel() {
    if (kIsWeb) return 'Web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android',
      TargetPlatform.iOS => 'iPhone',
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      TargetPlatform.fuchsia => 'Fuchsia',
    };
  }

  String _themeModeLabel(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => 'System',
      ThemeMode.light => 'Light',
      ThemeMode.dark => 'Dark',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final themeController = ThemeScope.of(context);
    final hasDesktopControls =
        widget.onResetSidebarWidth != null ||
        widget.onResetInspectorWidth != null;
    final canReplayOnboarding =
        kIsWeb || defaultTargetPlatform != TargetPlatform.macOS;
    final content = _SettingsContent(
      embedded: widget.embedded,
      onClose: widget.onClose,
      themeController: themeController,
      defaultsStore: _defaultsStore,
      screenAwakeStore: _screenAwakeStore,
      notificationsLoading: _notificationsLoading,
      notificationsRequesting: _notificationsRequesting,
      notificationsSupported: _notificationsSupported,
      notificationsAllowed: _notificationsAllowed,
      liveActivitiesSupported: _liveActivitiesSupported,
      busyAction: _busyAction,
      hasDesktopControls: hasDesktopControls,
      platformLabel: _platformLabel(),
      themeModeLabelFor: _themeModeLabel,
      onRefreshNotifications: _refreshNotificationStatus,
      onRequestNotifications: _requestNotifications,
      onEditLaunchDefaults: _editLaunchDefaults,
      onRunStorageAction: _runStorageAction,
      onResetSidebarWidth: widget.onResetSidebarWidth,
      onResetInspectorWidth: widget.onResetInspectorWidth,
      onReplayOnboarding: canReplayOnboarding ? _replayOnboarding : null,
    );
    if (widget.embedded) {
      return content;
    }
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(title: const Text('Settings')),
      body: content,
    );
  }
}

class _LaunchDefaultsSheet extends StatefulWidget {
  const _LaunchDefaultsSheet({this.embedded = false});

  final bool embedded;

  @override
  State<_LaunchDefaultsSheet> createState() => _LaunchDefaultsSheetState();
}

class _LaunchDefaultsSheetState extends State<_LaunchDefaultsSheet> {
  late CreateSessionDefaults _draft;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = CreateSessionDefaultsStore.instance.defaults;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    await CreateSessionDefaultsStore.instance.setDefaults(_draft);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: widget.embedded
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(
              16,
              12,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 16,
            ),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: const EdgeInsets.all(20),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(Icons.rocket_launch_outlined, color: colors.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'New session defaults',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    MeshIconButton(
                      icon: Icons.close_rounded,
                      tooltip: 'Close',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'These values prefill the create-session flow before any host-specific model or profile overrides are chosen.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                _SectionLabel(text: 'Approval'),
                const SizedBox(height: 8),
                for (final policy in ApprovalPolicy.values)
                  _ChoiceTile<ApprovalPolicy>(
                    value: policy,
                    groupValue: _draft.approval,
                    title: policy.label,
                    subtitle: policy.description,
                    danger: policy == ApprovalPolicy.never,
                    onSelected: (value) {
                      setState(() => _draft = _draft.copyWith(approval: value));
                    },
                  ),
                const SizedBox(height: 18),
                _SectionLabel(text: 'Sandbox'),
                const SizedBox(height: 8),
                for (final sandbox in SandboxMode.values)
                  _ChoiceTile<SandboxMode>(
                    value: sandbox,
                    groupValue: _draft.sandbox,
                    title: sandbox.label,
                    subtitle: sandbox.description,
                    danger: sandbox == SandboxMode.dangerFullAccess,
                    onSelected: (value) {
                      setState(() => _draft = _draft.copyWith(sandbox: value));
                    },
                  ),
                const SizedBox(height: 18),
                _SectionLabel(text: 'Launch behavior'),
                const SizedBox(height: 8),
                _ToggleTile(
                  icon: Icons.bolt_rounded,
                  title: 'Fast mode',
                  subtitle:
                      'Ask for the fast service tier when the chosen model supports it.',
                  value: _draft.fastMode,
                  onChanged: (value) {
                    setState(() => _draft = _draft.copyWith(fastMode: value));
                  },
                ),
                const SizedBox(height: 10),
                _ToggleTile(
                  icon: Icons.public_rounded,
                  title: 'Live web search',
                  subtitle:
                      'Start new sessions with provider web search enabled by default.',
                  value: _draft.webSearch,
                  onChanged: (value) {
                    setState(() => _draft = _draft.copyWith(webSearch: value));
                  },
                ),
                if (_draft.sandbox == SandboxMode.dangerFullAccess ||
                    _draft.approval == ApprovalPolicy.never) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.warning.withValues(alpha: 0.11),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: colors.warning.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      'These defaults are permissive. New sessions will start closer to autopilot behavior.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textPrimary,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () {
                              setState(() {
                                _draft = CreateSessionDefaults.factoryDefaults;
                              });
                            },
                      child: const Text('Reset'),
                    ),
                    const Spacer(),
                    OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).maybePop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saving ? null : () => unawaited(_save()),
                      child: Text(_saving ? 'Saving...' : 'Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef _ThemeModeLabelFor = String Function(ThemeMode mode);

class _SettingsContent extends StatelessWidget {
  const _SettingsContent({
    required this.embedded,
    required this.onClose,
    required this.themeController,
    required this.defaultsStore,
    required this.screenAwakeStore,
    required this.notificationsLoading,
    required this.notificationsRequesting,
    required this.notificationsSupported,
    required this.notificationsAllowed,
    required this.liveActivitiesSupported,
    required this.busyAction,
    required this.hasDesktopControls,
    required this.platformLabel,
    required this.themeModeLabelFor,
    required this.onRefreshNotifications,
    required this.onRequestNotifications,
    required this.onEditLaunchDefaults,
    required this.onRunStorageAction,
    required this.onResetSidebarWidth,
    required this.onResetInspectorWidth,
    required this.onReplayOnboarding,
  });

  final bool embedded;
  final VoidCallback? onClose;
  final ThemeController themeController;
  final CreateSessionDefaultsStore defaultsStore;
  final ScreenAwakeSettingsStore screenAwakeStore;
  final bool notificationsLoading;
  final bool notificationsRequesting;
  final bool notificationsSupported;
  final bool notificationsAllowed;
  final bool liveActivitiesSupported;
  final String? busyAction;
  final bool hasDesktopControls;
  final String platformLabel;
  final _ThemeModeLabelFor themeModeLabelFor;
  final Future<void> Function() onRefreshNotifications;
  final Future<void> Function() onRequestNotifications;
  final Future<void> Function() onEditLaunchDefaults;
  final Future<void> Function({
    required String key,
    required String title,
    required String body,
    required Future<void> Function() action,
    required String successMessage,
  })
  onRunStorageAction;
  final VoidCallback? onResetSidebarWidth;
  final VoidCallback? onResetInspectorWidth;
  final VoidCallback? onReplayOnboarding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final list = ListView(
      padding: EdgeInsets.fromLTRB(
        embedded ? 24 : 16,
        16,
        embedded ? 24 : 16,
        28,
      ),
      children: [
        _SectionHeader(
          icon: Icons.tune_rounded,
          title: 'App preferences',
          subtitle: 'Global settings that apply across hosts and sessions.',
        ),
        const SizedBox(height: 10),
        ListenableBuilder(
          listenable: themeController,
          builder: (context, _) => _SettingsCard(
            icon: Icons.palette_outlined,
            title: 'Appearance',
            subtitle:
                '${themeModeLabelFor(themeController.mode)} · ${themeController.variant.label} · ${themeController.typography.interfaceFont.label}',
            body:
                'Theme mode, palette, and typography are global. Use the shared appearance controls from here.',
            trailing: FilledButton(
              onPressed: () => showAppearanceSheet(context),
              child: const Text('Customize'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: screenAwakeStore,
          builder: (context, _) {
            final enabled = screenAwakeStore.keepScreenAwakeWhileAgentRuns;
            return _SettingsCard(
              icon: Icons.light_mode_outlined,
              title: 'Display',
              subtitle: enabled
                  ? 'Screen stays awake while an agent is working.'
                  : 'Screen can sleep normally.',
              body:
                  'When enabled, Sidemesh keeps this device awake only while it can see an active agent session. The wake lock is released when the run ends, the app leaves the foreground, or this setting is turned off.',
              footer: _ToggleTile(
                icon: Icons.screen_lock_portrait_outlined,
                title: 'Keep screen awake while agent runs',
                subtitle:
                    'Useful for monitoring long turns without repeatedly unlocking the device. This may use more battery.',
                value: enabled,
                onChanged: (value) => unawaited(
                  screenAwakeStore.setKeepScreenAwakeWhileAgentRuns(value),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        _SettingsCard(
          icon: Icons.notifications_outlined,
          title: 'Notifications',
          subtitle: notificationsLoading
              ? 'Checking device notification status...'
              : notificationsSupported
              ? notificationsAllowed
                    ? 'Approval alerts are enabled.'
                    : 'Approval alerts are available but currently disabled.'
              : 'This platform does not support local approval alerts.',
          body:
              'Approval notifications, background polling, and Live Activities are app-level behaviors, not per-session toggles.',
          footer: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: notificationsLoading
                    ? 'checking alerts'
                    : notificationsAllowed
                    ? 'alerts on'
                    : 'alerts off',
                tone: notificationsAllowed
                    ? MeshPillTone.success
                    : MeshPillTone.warning,
                icon: notificationsAllowed
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              MeshPill(
                label: BackgroundSyncService.instance.supportsBackgroundFetch
                    ? 'background polling supported'
                    : 'background polling unavailable',
                tone: BackgroundSyncService.instance.supportsBackgroundFetch
                    ? MeshPillTone.info
                    : MeshPillTone.neutral,
                icon: Icons.sync_rounded,
              ),
              MeshPill(
                label: liveActivitiesSupported
                    ? 'live activity supported'
                    : 'live activity unavailable',
                tone: liveActivitiesSupported
                    ? MeshPillTone.info
                    : MeshPillTone.neutral,
                icon: Icons.view_agenda_outlined,
              ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: notificationsLoading
                    ? null
                    : () => unawaited(onRefreshNotifications()),
                child: const Text('Refresh'),
              ),
              if (notificationsSupported && !notificationsAllowed) ...[
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: notificationsRequesting
                      ? null
                      : () => unawaited(onRequestNotifications()),
                  child: Text(
                    notificationsRequesting ? 'Enabling...' : 'Enable',
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        ListenableBuilder(
          listenable: defaultsStore,
          builder: (context, _) {
            final defaults = defaultsStore.defaults;
            return _SettingsCard(
              icon: Icons.rocket_launch_outlined,
              title: 'New session defaults',
              subtitle:
                  '${defaults.approval.label} · ${defaults.sandbox.label}',
              body:
                  'These defaults seed the create-session flow before any host-specific model or profile selection.',
              footer: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  MeshPill(
                    label: defaults.approval.label,
                    icon: Icons.verified_user_rounded,
                  ),
                  MeshPill(
                    label: defaults.sandbox.label,
                    icon: defaults.sandbox == SandboxMode.dangerFullAccess
                        ? Icons.warning_amber_rounded
                        : Icons.folder_special_rounded,
                    tone: defaults.sandbox == SandboxMode.dangerFullAccess
                        ? MeshPillTone.warning
                        : MeshPillTone.neutral,
                  ),
                  MeshPill(
                    label: defaults.fastMode ? 'fast mode on' : 'fast mode off',
                    icon: Icons.bolt_rounded,
                    tone: defaults.fastMode
                        ? MeshPillTone.accent
                        : MeshPillTone.neutral,
                  ),
                  MeshPill(
                    label: defaults.webSearch
                        ? 'web search on'
                        : 'web search off',
                    icon: Icons.public_rounded,
                    tone: defaults.webSearch
                        ? MeshPillTone.info
                        : MeshPillTone.neutral,
                  ),
                ],
              ),
              trailing: FilledButton(
                onPressed: () => unawaited(onEditLaunchDefaults()),
                child: const Text('Edit'),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        _SettingsCard(
          icon: Icons.storage_rounded,
          title: 'Storage & recovery',
          subtitle: 'Clear saved caches and queued recovery state.',
          body:
              'These actions only touch on-device state. Open panes keep their current contents until refreshed or reopened.',
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ActionRow(
                icon: Icons.history_rounded,
                title: 'Clear saved transcript cache',
                subtitle: 'Drop saved recent sessions and saved logs.',
                busy: busyAction == 'transcript-cache',
                onTap: () => unawaited(
                  onRunStorageAction(
                    key: 'transcript-cache',
                    title: 'Clear saved transcript cache?',
                    body:
                        'This removes saved recent sessions and saved transcripts from this device. Open panes keep their current contents until refreshed.',
                    action: SessionCacheStore.instance.clearAll,
                    successMessage: 'Saved transcript cache cleared.',
                  ),
                ),
              ),
              Divider(color: colors.border),
              _ActionRow(
                icon: Icons.image_outlined,
                title: 'Clear saved image cache',
                subtitle: 'Remove saved image blobs from disk.',
                busy: busyAction == 'image-cache',
                onTap: () => unawaited(
                  onRunStorageAction(
                    key: 'image-cache',
                    title: 'Clear saved image cache?',
                    body:
                        'This removes downloaded image blobs saved on this device. Images already open may remain visible until reopened.',
                    action: ImageBlobCacheStore.instance.clearAll,
                    successMessage: 'Saved image cache cleared.',
                  ),
                ),
              ),
              Divider(color: colors.border),
              _ActionRow(
                icon: Icons.outbox_outlined,
                title: 'Clear queued sends',
                subtitle:
                    'Discard queued retries that have not already started.',
                busy: busyAction == 'queued-sends',
                onTap: () => unawaited(
                  onRunStorageAction(
                    key: 'queued-sends',
                    title: 'Clear queued sends?',
                    body:
                        'This discards locally queued messages waiting for retry. A retry already in progress may still finish. Remote sessions are unchanged.',
                    action: SessionSendOutboxStore.instance.clearAll,
                    successMessage: 'Queued sends cleared.',
                  ),
                ),
              ),
            ],
          ),
        ),
        if (hasDesktopControls) ...[
          const SizedBox(height: 12),
          _SettingsCard(
            icon: Icons.desktop_mac_outlined,
            title: 'Desktop layout',
            subtitle: 'Reset saved shell sizing preferences.',
            body:
                'These controls only appear inside the desktop shell and affect the local window layout.',
            footer: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (onResetSidebarWidth != null)
                  OutlinedButton.icon(
                    onPressed: onResetSidebarWidth,
                    icon: const Icon(Icons.view_sidebar_outlined, size: 18),
                    label: const Text('Reset sidebar'),
                  ),
                if (onResetInspectorWidth != null)
                  OutlinedButton.icon(
                    onPressed: onResetInspectorWidth,
                    icon: const Icon(Icons.tune_rounded, size: 18),
                    label: const Text('Reset inspector'),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        _SettingsCard(
          icon: Icons.info_outline_rounded,
          title: 'About this build',
          subtitle: platformLabel,
          body:
              'Hosts, tokens, favorites, pins, caches, and other local state stay inside this app install and flavor.',
          footer: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MeshPill(
                label: platformLabel,
                icon: Icons.devices_rounded,
                tone: MeshPillTone.neutral,
              ),
              if (onReplayOnboarding != null)
                OutlinedButton.icon(
                  onPressed: onReplayOnboarding,
                  icon: const Icon(Icons.replay_rounded, size: 16),
                  label: const Text('Replay onboarding'),
                ),
            ],
          ),
        ),
      ],
    );

    final centered = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: list,
      ),
    );

    if (!embedded) {
      return centered;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.28),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.tune_rounded, size: 20, color: colors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Settings',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Global app controls for appearance, display, defaults, storage, and notifications.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              MeshIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Close',
                onTap: onClose ?? () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: colors.border),
        Expanded(child: centered),
      ],
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
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: colors.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.body,
    this.trailing,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String body;
  final Widget? trailing;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.surface,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: colors.border),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: colors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.35,
            ),
          ),
          if (footer != null) ...[const SizedBox(height: 14), footer!],
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.border),
                ),
                alignment: Alignment.center,
                child: busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.accent,
                        ),
                      )
                    : Icon(icon, size: 17, color: colors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: colors.textTertiary,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    );
  }
}

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.onSelected,
    this.danger = false,
  });

  final T value;
  final T groupValue;
  final String title;
  final String subtitle;
  final ValueChanged<T> onSelected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = value == groupValue;
    final accent = danger ? colors.warning : colors.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onSelected(value),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? accent.withValues(alpha: 0.09)
                  : colors.surfaceMuted,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? accent.withValues(alpha: 0.5) : colors.border,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: selected ? accent : colors.textTertiary,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          height: 1.3,
                        ),
                      ),
                    ],
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

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Icon(icon, size: 18, color: colors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
