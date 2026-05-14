import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../background_sync_service.dart';
import '../create_session_defaults_store.dart';
import '../image_blob_cache_store.dart';
import '../live_activity_service.dart';
import '../local_notification_service.dart';
import '../screen_awake_settings_store.dart';
import '../session_local_store.dart';
import '../session_policy_store.dart';
import '../session_send_outbox_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../theme/theme_controller.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/appearance_sheet.dart';
import '../widgets/launch_options_form.dart';
import '../widgets/mesh_widgets.dart';
import '../onboarding_store.dart';
import 'desktop_welcome_overlay.dart';
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
    final desktop = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    if (desktop) {
      await showDialog<void>(
        context: context,
        barrierColor: Colors.transparent,
        builder: (_) => DesktopWelcomeOverlay(
          themeController: ThemeScope.of(context),
          onDismissed: () => Navigator.of(context).pop(),
        ),
      );
    } else {
      await showOnboardingScreen(context);
    }
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
      onReplayOnboarding: _replayOnboarding,
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
                    Icon(Icons.rocket_launch_rounded, color: colors.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'New session defaults',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: AppWeights.title,
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
                LaunchOptionsForm(
                  capabilities: const LaunchOptionsCapabilities(
                    supportsApprovalPolicy: true,
                    supportsSandboxMode: true,
                    supportsFastMode: true,
                    supportsWebSearch: true,
                  ),
                  value: LaunchOptionsValue(
                    approval: _draft.approval,
                    sandbox: _draft.sandbox,
                    fastMode: _draft.fastMode,
                    webSearch: _draft.webSearch,
                  ),
                  onChanged: (next) {
                    setState(() {
                      _draft = _draft.copyWith(
                        approval: next.approval,
                        sandbox: next.sandbox,
                        fastMode: next.fastMode,
                        webSearch: next.webSearch,
                      );
                    });
                  },
                ),
                if (_draft.sandbox == SandboxMode.dangerFullAccess ||
                    _draft.approval == ApprovalPolicy.never) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.warning.withValues(alpha: 0.11),
                      borderRadius: AppShapes.input,
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
        embedded ? AppSpacing.xl : AppSpacing.lg,
        AppSpacing.lg,
        embedded ? AppSpacing.xl : AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: [
        _SettingsSection(
          icon: Icons.palette_rounded,
          title: 'Appearance & device',
          subtitle: 'Theme, text, and screen behavior.',
          children: [
            ListenableBuilder(
              listenable: themeController,
              builder: (context, _) => _SettingsCard(
                icon: Icons.palette_rounded,
                title: 'Appearance',
                subtitle:
                    '${themeModeLabelFor(themeController.mode)} · ${themeController.variant.label} · ${themeController.typography.interfaceFont.label}',
                trailing: FilledButton(
                  onPressed: () => showAppearanceSheet(context),
                  child: const Text('Customize'),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ListenableBuilder(
              listenable: screenAwakeStore,
              builder: (context, _) {
                final enabled = screenAwakeStore.keepScreenAwakeWhileAgentRuns;
                return _SettingsCard(
                  icon: Icons.light_mode_rounded,
                  title: 'Display',
                  subtitle: enabled
                      ? 'This screen stays awake while an agent is working.'
                      : 'This device can sleep normally.',
                  body:
                      'Sidemesh only keeps this screen awake while an agent run is active. The wake lock ends when the run stops, the app leaves the foreground, or you turn this off.',
                  footer: _ToggleTile(
                    icon: Icons.screen_lock_portrait_rounded,
                    title: 'Keep screen awake while agent runs',
                    subtitle:
                        'Useful for long turns. May use more battery.',
                    value: enabled,
                    onChanged: (value) => unawaited(
                      screenAwakeStore.setKeepScreenAwakeWhileAgentRuns(value),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _SettingsSection(
          icon: Icons.notifications_rounded,
          title: 'Alerts',
          subtitle: 'Notification permissions and background support.',
          children: [
            _SettingsCard(
              icon: Icons.notifications_rounded,
              title: 'Notifications',
              subtitle: notificationsLoading
                  ? 'Checking device notification status...'
                  : notificationsSupported
                  ? notificationsAllowed
                        ? 'Approval alerts are enabled.'
                        : 'Approval alerts are available but currently disabled.'
                  : 'This platform does not support local approval alerts.',
              footer: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
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
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_off_rounded,
                  ),
                  MeshPill(
                    label: BackgroundSyncService.instance.supportsBackgroundFetch
                        ? 'background sync'
                        : 'foreground only',
                    tone:
                        BackgroundSyncService.instance.supportsBackgroundFetch
                        ? MeshPillTone.info
                        : MeshPillTone.neutral,
                    icon: Icons.sync_rounded,
                  ),
                  if (liveActivitiesSupported)
                    const MeshPill(
                      label: 'live activity',
                      tone: MeshPillTone.info,
                      icon: Icons.view_agenda_rounded,
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
                    const SizedBox(width: AppSpacing.sm),
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
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _SettingsSection(
          icon: Icons.rocket_launch_rounded,
          title: 'Session defaults',
          subtitle: 'Starting values before host-specific overrides.',
          children: [
            ListenableBuilder(
              listenable: defaultsStore,
              builder: (context, _) {
                final defaults = defaultsStore.defaults;
                return _SettingsCard(
                  icon: Icons.rocket_launch_rounded,
                  title: 'New session defaults',
                  subtitle:
                      '${defaults.approval.label} · ${defaults.sandbox.label}',
                  footer: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      MeshPill(
                        label: defaults.fastMode
                            ? 'fast mode on'
                            : 'fast mode off',
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
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _SettingsSection(
          icon: Icons.warning_amber_rounded,
          title: 'Local data',
          subtitle: 'Clear information saved only on this device.',
          children: [
            _SettingsCard(
              icon: Icons.storage_rounded,
              title: 'On-device state',
              subtitle: 'These actions only touch local data.',
              footer: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ActionRow(
                    icon: Icons.history_rounded,
                    title: 'Clear saved transcript cache',
                    danger: true,
                    subtitle: 'Drop saved recent sessions and saved logs.',
                    busy: busyAction == 'transcript-cache',
                    onTap: () => unawaited(
                      onRunStorageAction(
                        key: 'transcript-cache',
                        title: 'Clear saved transcript cache?',
                        body:
                            'This removes saved recent sessions and saved transcripts from this device. Open panes keep their current contents until refreshed.',
                        action: SessionLocalStore.instance.clearAll,
                        successMessage: 'Saved transcript cache cleared.',
                      ),
                    ),
                  ),
                  Divider(color: colors.border),
                  _ActionRow(
                    icon: Icons.image_rounded,
                    title: 'Clear saved image cache',
                    danger: true,
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
                    icon: Icons.outbox_rounded,
                    title: 'Clear queued sends',
                    danger: true,
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
          ],
        ),

        const SizedBox(height: AppSpacing.xl),
        _AboutFooter(
          platformLabel: platformLabel,
          hasDesktopControls: hasDesktopControls,
          onResetSidebarWidth: onResetSidebarWidth,
          onResetInspectorWidth: onResetInspectorWidth,
          onReplayOnboarding: onReplayOnboarding,
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
                  borderRadius: AppShapes.input,
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
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Global app controls for appearance, alerts, defaults, and local data.',
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

class _SettingsSection extends StatefulWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  State<_SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<_SettingsSection>
    with SingleTickerProviderStateMixin {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MeshListRow(
          framed: false,
          radius: AppRadii.control,
          onTap: () => setState(() => _expanded = !_expanded),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: colors.accentMuted,
              borderRadius: BorderRadius.circular(AppRadii.control),
              border: Border.all(
                color: colors.accent.withValues(alpha: 0.28),
              ),
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 17, color: colors.accent),
          ),
          title: Text(
            widget.title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: AppWeights.title,
              letterSpacing: AppLetterSpacing.headline,
            ),
          ),
          subtitle: Text(
            widget.subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
            ),
          ),
          trailing: AnimatedRotation(
            duration: const Duration(milliseconds: 180),
            turns: _expanded ? 0.5 : 0,
            child: Icon(
              Icons.expand_more_rounded,
              color: colors.textSecondary,
              size: 22,
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.children,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _AboutFooter extends StatelessWidget {
  const _AboutFooter({
    required this.platformLabel,
    required this.hasDesktopControls,
    required this.onResetSidebarWidth,
    required this.onResetInspectorWidth,
    required this.onReplayOnboarding,
  });

  final String platformLabel;
  final bool hasDesktopControls;
  final VoidCallback? onResetSidebarWidth;
  final VoidCallback? onResetInspectorWidth;
  final VoidCallback? onReplayOnboarding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'About',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.textSecondary,
              fontWeight: AppWeights.title,
              letterSpacing: AppLetterSpacing.caps,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Sidemesh on $platformLabel. Hosts, tokens, favorites, caches, and other local state stay inside this app install.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.35,
            ),
          ),
          if (onReplayOnboarding != null ||
              (hasDesktopControls &&
                  (onResetSidebarWidth != null ||
                      onResetInspectorWidth != null))) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                if (onReplayOnboarding != null)
                  OutlinedButton.icon(
                    onPressed: onReplayOnboarding,
                    icon: const Icon(Icons.replay_rounded, size: 16),
                    label: const Text('Replay onboarding'),
                  ),
                if (hasDesktopControls && onResetSidebarWidth != null)
                  OutlinedButton.icon(
                    onPressed: onResetSidebarWidth,
                    icon: const Icon(Icons.view_sidebar_rounded, size: 16),
                    label: const Text('Reset sidebar'),
                  ),
                if (hasDesktopControls && onResetInspectorWidth != null)
                  OutlinedButton.icon(
                    onPressed: onResetInspectorWidth,
                    icon: const Icon(Icons.tune_rounded, size: 16),
                    label: const Text('Reset inspector'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.body,
    this.trailing,
    this.footer,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? body;
  final Widget? trailing;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.surface,
      padding: AppPadding.card,
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
                  borderRadius: AppShapes.input,
                  border: Border.all(color: colors.border),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: colors.accent),
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
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.md),
                trailing!,
              ],
            ],
          ),
          if (body != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              body!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          if (footer != null) ...[
            const SizedBox(height: AppSpacing.md),
            footer!,
          ],
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
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool busy;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconColor = danger ? colors.danger : colors.accent;
    final titleColor = danger ? colors.danger : colors.textPrimary;
    final iconBg = danger ? colors.dangerMuted : colors.surfaceMuted;
    final iconBorder = danger
        ? colors.danger.withValues(alpha: 0.25)
        : colors.border;
    return MeshListRow(
      framed: false,
      dense: true,
      radius: AppRadii.control,
      enabled: !busy,
      onTap: busy ? null : onTap,
      leading: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: iconBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: iconBorder),
        ),
        alignment: Alignment.center,
        child: busy
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: iconColor,
                ),
              )
            : Icon(icon, size: 17, color: iconColor),
      ),
      title: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: AppWeights.emphasis,
          color: titleColor,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colors.textSecondary,
          height: 1.3,
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
    return MeshSurface(
      tone: MeshSurfaceTone.muted,
      selected: value,
      radius: AppRadii.control,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Icon(
              icon,
              size: 18,
              color: value ? colors.accent : colors.textSecondary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: AppWeights.emphasis,
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
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
