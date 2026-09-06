import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_update_settings_store.dart';
import '../app_version_store.dart';
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
import '../widgets/app_dialogs.dart';
import '../widgets/app_menu.dart';
import '../widgets/app_primitives.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/appearance_sheet.dart';
import '../widgets/mesh_widgets.dart';
import '../onboarding_store.dart';
import 'desktop_welcome_overlay.dart';
import 'onboarding_screen.dart';

Future<void> openSettingsScreen(
  BuildContext context, {
  VoidCallback? onResetSidebarWidth,
  VoidCallback? onResetInspectorWidth,
}) {
  if (!kIsWeb &&
      defaultTargetPlatform == TargetPlatform.macOS &&
      MediaQuery.sizeOf(context).width >= 760) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppSizes.settingsWidth,
            maxHeight: AppSizes.settingsHeight,
          ),
          child: SettingsScreen(
            embedded: true,
            onResetSidebarWidth: onResetSidebarWidth,
            onResetInspectorWidth: onResetInspectorWidth,
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
    this.initialCategory,
    this.onClose,
    this.onResetSidebarWidth,
    this.onResetInspectorWidth,
  });

  final bool embedded;
  final String? initialCategory;
  final VoidCallback? onClose;
  final VoidCallback? onResetSidebarWidth;
  final VoidCallback? onResetInspectorWidth;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _category = 'General';

  final AppUpdateSettingsStore _appUpdateStore =
      AppUpdateSettingsStore.instance;
  final AppVersionStore _appVersionStore = AppVersionStore.instance;
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
    unawaited(_appUpdateStore.ensureLoaded());
    unawaited(_appVersionStore.ensureLoaded());
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
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const _LaunchDefaultsSheet(page: true),
      ),
    );
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
    final confirmed = await showMeshConfirmDialog(
      context,
      icon: Icons.delete_sweep_rounded,
      title: title,
      description: body,
      confirmLabel: 'Clear data',
      danger: true,
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
    final confirmed = await showMeshConfirmDialog(
      context,
      icon: Icons.play_circle_outline_rounded,
      title: 'Show the guide again?',
      description:
          'This opens the first-run guide again. You can close it whenever you want.',
      confirmLabel: 'Show guide',
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

  Future<void> _checkForUpdatesNow() async {
    try {
      await _appUpdateStore.checkForUpdates();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, _appUpdateErrorMessage(error));
    }
  }

  Future<void> _setAutomaticUpdateChecks(bool value) async {
    try {
      await _appUpdateStore.setAutomaticallyChecksForUpdates(value);
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, _appUpdateErrorMessage(error));
    }
  }

  Future<void> _setUpdateCheckInterval(
    AppUpdateCheckIntervalOption option,
  ) async {
    try {
      await _appUpdateStore.setUpdateCheckIntervalSeconds(option.seconds);
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, _appUpdateErrorMessage(error));
    }
  }

  String _appUpdateErrorMessage(Object error) {
    if (error is PlatformException) {
      if (error.code == 'unsupported') {
        return 'This build does not include in-app updates.';
      }
      if (error.code == 'busy') {
        return 'Another update check is already running.';
      }
    }
    return 'Could not change app update settings.';
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
      category: widget.embedded ? _category : widget.initialCategory,
      appUpdateStore: _appUpdateStore,
      appVersionStore: _appVersionStore,
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
      onRetryAppUpdateSettings: _appUpdateStore.refresh,
      onCheckForUpdatesNow: _checkForUpdatesNow,
      onSetAutomaticUpdateChecks: _setAutomaticUpdateChecks,
      onSetUpdateCheckInterval: _setUpdateCheckInterval,
      onRunStorageAction: _runStorageAction,
      onResetSidebarWidth: widget.onResetSidebarWidth,
      onResetInspectorWidth: widget.onResetInspectorWidth,
      onReplayOnboarding: _replayOnboarding,
    );
    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close settings',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 168,
                  child: Material(
                    color: colors.surface,
                    child: ListView(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      children: [
                        for (final category in [
                          'General',
                          'Appearance',
                          'New sessions',
                          'App updates',
                          'Local data',
                          'About',
                        ])
                          ListTile(
                            dense: true,
                            minTileHeight: AppSizes.desktopChoiceRow,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                            ),
                            title: Text(
                              category,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            selected: _category == category,
                            selectedTileColor: colors.surfaceMuted,
                            selectedColor: colors.textPrimary,
                            shape: RoundedRectangleBorder(
                              borderRadius: AppShapes.input,
                            ),
                            onTap: () => setState(() => _category = category),
                          ),
                      ],
                    ),
                  ),
                ),
                VerticalDivider(width: 1, color: colors.border),
                Expanded(
                  child: switch (_category) {
                    'Appearance' => const AppearanceSettings(embedded: true),
                    'New sessions' => const AppContentColumn(
                      child: Padding(
                        padding: AppPadding.desktopPage,
                        child: _LaunchDefaultsSheet(embedded: true),
                      ),
                    ),
                    _ => content,
                  },
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(title: Text(widget.initialCategory ?? 'Settings')),
      body: content,
    );
  }
}

class _LaunchDefaultsSheet extends StatefulWidget {
  const _LaunchDefaultsSheet({this.embedded = false, this.page = false});

  final bool embedded;
  final bool page;

  @override
  State<_LaunchDefaultsSheet> createState() => _LaunchDefaultsSheetState();
}

class _LaunchDefaultsSheetState extends State<_LaunchDefaultsSheet> {
  late CreateSessionDefaults _initial;
  late CreateSessionDefaults _draft;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _initial = CreateSessionDefaultsStore.instance.defaults;
    _draft = _initial;
  }

  bool get _hasChanges =>
      _draft.approval != _initial.approval ||
      _draft.sandbox != _initial.sandbox ||
      _draft.fastMode != _initial.fastMode ||
      _draft.webSearch != _initial.webSearch;

  Future<void> _save() async {
    if (_saving || !_hasChanges) return;
    setState(() => _saving = true);
    await CreateSessionDefaultsStore.instance.setDefaults(_draft);
    if (!mounted) return;
    if (widget.embedded) {
      setState(() {
        _initial = _draft;
        _saving = false;
      });
      showAppSnackBar(context, 'New session defaults saved.');
    } else {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _pickApproval() async {
    final selected = await _showChoiceSheet<ApprovalPolicy>(
      title: 'Approval policy',
      current: _draft.approval,
      values: ApprovalPolicy.values,
      label: (value) => value.label,
      description: (value) => value.description,
    );
    if (selected != null && mounted) {
      setState(() => _draft = _draft.copyWith(approval: selected));
    }
  }

  Future<void> _pickSandbox() async {
    final selected = await _showChoiceSheet<SandboxMode>(
      title: 'File access',
      current: _draft.sandbox,
      values: SandboxMode.values,
      label: (value) => value.label,
      description: (value) => value.description,
    );
    if (selected != null && mounted) {
      setState(() => _draft = _draft.copyWith(sandbox: selected));
    }
  }

  Future<T?> _showChoiceSheet<T>({
    required String title,
    required T current,
    required List<T> values,
    required String Function(T value) label,
    required String Function(T value) description,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                AppSpacing.md,
              ),
              child: Text(
                title,
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: AppWeights.title),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var index = 0; index < values.length; index++) ...[
                      AppChoiceRow(
                        title: label(values[index]),
                        subtitle: description(values[index]),
                        selected: values[index] == current,
                        onTap: () =>
                            Navigator.of(sheetContext).pop(values[index]),
                      ),
                      if (index != values.length - 1)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: AppSizes.nestedRowIndent,
                          ),
                          child: Divider(
                            height: 1,
                            color: context.colors.border,
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _valueTrailing(BuildContext context, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Icon(
          Icons.chevron_right_rounded,
          size: AppSizes.icon,
          color: context.colors.textSecondary,
        ),
      ],
    );
  }

  Widget _desktopDropdown<T>({
    required T value,
    required List<T> values,
    required String Function(T value) label,
    required ValueChanged<T> onChanged,
  }) {
    return AppSelect<T>(
      value: value,
      values: values,
      label: label,
      onChanged: _saving ? null : onChanged,
    );
  }

  void _reset() {
    setState(() => _draft = CreateSessionDefaults.factoryDefaults);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.embedded) ...[
            const AppSectionHeader(title: 'New session defaults'),
            const SizedBox(height: AppSpacing.md),
          ] else if (!widget.page) ...[
            Row(
              children: [
                Icon(Icons.rocket_launch_rounded, color: colors.accent),
                const SizedBox(width: AppSpacing.compact),
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
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Used when you start a new session.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: AppLineHeights.caption,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          AppSettingsRow(
            icon: Icons.bolt_rounded,
            title: 'Fast mode',
            trailing: Semantics(
              label: 'Fast mode',
              child: Switch(
                value: _draft.fastMode,
                onChanged: _saving
                    ? null
                    : (value) => setState(
                        () => _draft = _draft.copyWith(fastMode: value),
                      ),
              ),
            ),
          ),
          Divider(
            height: 1,
            indent: AppSpacing.md + AppSizes.icon + AppSpacing.sm,
            color: colors.border,
          ),
          AppSettingsRow(
            icon: Icons.verified_user_outlined,
            title: 'Approval policy',
            trailing: widget.embedded
                ? _desktopDropdown<ApprovalPolicy>(
                    value: _draft.approval,
                    values: ApprovalPolicy.values,
                    label: (value) => value.label,
                    onChanged: (value) => setState(
                      () => _draft = _draft.copyWith(approval: value),
                    ),
                  )
                : _valueTrailing(context, _draft.approval.label),
            onTap: widget.embedded || _saving
                ? null
                : () => unawaited(_pickApproval()),
          ),
          Divider(
            height: 1,
            indent: AppSpacing.md + AppSizes.icon + AppSpacing.sm,
            color: colors.border,
          ),
          AppSettingsRow(
            icon: Icons.folder_outlined,
            title: 'File access',
            trailing: widget.embedded
                ? _desktopDropdown<SandboxMode>(
                    value: _draft.sandbox,
                    values: SandboxMode.values,
                    label: (value) => value.label,
                    onChanged: (value) => setState(
                      () => _draft = _draft.copyWith(sandbox: value),
                    ),
                  )
                : _valueTrailing(context, _draft.sandbox.label),
            onTap: widget.embedded || _saving
                ? null
                : () => unawaited(_pickSandbox()),
          ),
          Divider(
            height: 1,
            indent: AppSpacing.md + AppSizes.icon + AppSpacing.sm,
            color: colors.border,
          ),
          AppSettingsRow(
            icon: Icons.public_rounded,
            title: 'Web search',
            trailing: Semantics(
              label: 'Web search',
              child: Switch(
                value: _draft.webSearch,
                onChanged: _saving
                    ? null
                    : (value) => setState(
                        () => _draft = _draft.copyWith(webSearch: value),
                      ),
              ),
            ),
          ),
          if (_draft.sandbox == SandboxMode.dangerFullAccess ||
              _draft.approval == ApprovalPolicy.never) ...[
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colors.warning.withValues(alpha: AppEmphasis.tint),
                borderRadius: AppShapes.input,
                border: Border.all(
                  color: colors.warning.withValues(
                    alpha: AppEmphasis.borderTint,
                  ),
                ),
              ),
              child: Text(
                _draft.sandbox == SandboxMode.dangerFullAccess
                    ? 'Full access removes the file sandbox for new sessions.'
                    : 'New sessions will run without asking for approval.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textPrimary,
                  height: AppLineHeights.caption,
                ),
              ),
            ),
          ],
          if (!widget.page) ...[
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                TextButton(
                  onPressed: _saving ? null : _reset,
                  child: const Text('Reset'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _saving || !_hasChanges
                      ? null
                      : () => unawaited(_save()),
                  child: Text(_saving ? 'Saving...' : 'Save'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
    if (widget.page) {
      return Scaffold(
        backgroundColor: colors.canvas,
        appBar: AppBar(
          title: const Text('New session defaults'),
          actions: [
            TextButton(
              onPressed: _saving || !_hasChanges
                  ? null
                  : () => unawaited(_save()),
              child: Text(_saving ? 'Saving...' : 'Save'),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
        ),
        body: AppContentColumn(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppSizes.mobileGutter,
                AppSpacing.sm,
                AppSizes.mobileGutter,
                MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl,
              ),
              child: content,
            ),
          ),
        ),
      );
    }
    if (widget.embedded) return content;
    return Padding(
      padding: widget.embedded
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(
              AppSizes.mobileGutter,
              AppSpacing.md,
              AppSizes.mobileGutter,
              MediaQuery.viewInsetsOf(context).bottom + AppSpacing.lg,
            ),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: SafeArea(top: false, child: content),
      ),
    );
  }
}

typedef _ThemeModeLabelFor = String Function(ThemeMode mode);

class _SettingsContent extends StatelessWidget {
  const _SettingsContent({
    this.category,
    required this.appUpdateStore,
    required this.appVersionStore,
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
    required this.onRetryAppUpdateSettings,
    required this.onCheckForUpdatesNow,
    required this.onSetAutomaticUpdateChecks,
    required this.onSetUpdateCheckInterval,
    required this.onRunStorageAction,
    required this.onResetSidebarWidth,
    required this.onResetInspectorWidth,
    required this.onReplayOnboarding,
  });

  final String? category;
  final AppUpdateSettingsStore appUpdateStore;
  final AppVersionStore appVersionStore;
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
  final Future<void> Function() onRetryAppUpdateSettings;
  final Future<void> Function() onCheckForUpdatesNow;
  final Future<void> Function(bool value) onSetAutomaticUpdateChecks;
  final Future<void> Function(AppUpdateCheckIntervalOption option)
  onSetUpdateCheckInterval;
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
    final showAppUpdateSection =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;
    final list = ListView(
      padding: AppSizes.usesPointerControls(Theme.of(context).platform)
          ? AppPadding.desktopPage
          : AppPadding.mobilePage,
      children: [
        if (category == null || category == 'General')
          _SettingsSection(
            icon: Icons.palette_rounded,
            title: category == null ? 'Appearance & device' : 'Device',
            subtitle: 'Theme, text, and screen behavior.',
            children: [
              if (category == null) ...[
                ListenableBuilder(
                  listenable: themeController,
                  builder: (context, _) => _ActionRow(
                    icon: Icons.palette_outlined,
                    title: 'Appearance',
                    subtitle:
                        '${themeModeLabelFor(themeController.mode)} · ${themeController.variant.label} · ${themeController.typography.interfaceFont.label}',
                    onTap: () => showAppearanceSheet(context),
                  ),
                ),
                const Divider(
                  height: 1,
                  indent: AppSpacing.md + AppSizes.icon + AppSpacing.sm,
                  endIndent: AppSpacing.md,
                ),
              ],
              ListenableBuilder(
                listenable: screenAwakeStore,
                builder: (context, _) {
                  final enabled =
                      screenAwakeStore.keepScreenAwakeWhileAgentRuns;
                  return _ToggleTile(
                    icon: Icons.screen_lock_portrait_rounded,
                    title: 'Keep screen awake',
                    subtitle: enabled
                        ? 'While an agent is running.'
                        : 'The device can sleep normally.',
                    value: enabled,
                    onChanged: (value) => unawaited(
                      screenAwakeStore.setKeepScreenAwakeWhileAgentRuns(value),
                    ),
                  );
                },
              ),
            ],
          ),
        if (category == null || category == 'General')
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
                          ? 'Agent and approval alerts are enabled.'
                          : 'Agent and approval alerts are available but currently disabled.'
                    : 'This platform does not support agent alerts.',
                trailing: notificationsSupported && !notificationsAllowed
                    ? FilledButton(
                        onPressed: notificationsRequesting
                            ? null
                            : () => unawaited(onRequestNotifications()),
                        child: Text(
                          notificationsRequesting ? 'Enabling...' : 'Enable',
                        ),
                      )
                    : IconButton(
                        tooltip: 'Refresh notification status',
                        onPressed: notificationsLoading
                            ? null
                            : () => unawaited(onRefreshNotifications()),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
              ),
            ],
          ),
        if (showAppUpdateSection &&
            (category == null || category == 'App updates')) ...[
          _SettingsSection(
            icon: Icons.system_update_rounded,
            title: 'App updates',
            openAsPage: category == null,
            subtitle: 'Automatic checks and installed version.',
            children: [
              _AppUpdateSettingsCard(
                appUpdateStore: appUpdateStore,
                appVersionStore: appVersionStore,
                onRetryAppUpdateSettings: onRetryAppUpdateSettings,
                onCheckForUpdatesNow: onCheckForUpdatesNow,
                onSetAutomaticUpdateChecks: onSetAutomaticUpdateChecks,
                onSetUpdateCheckInterval: onSetUpdateCheckInterval,
              ),
            ],
          ),
        ],
        if (category == null)
          _SettingsSection(
            icon: Icons.rocket_launch_rounded,
            title: 'Session defaults',
            subtitle: 'Starting values before host-specific overrides.',
            children: [
              ListenableBuilder(
                listenable: defaultsStore,
                builder: (context, _) {
                  final defaults = defaultsStore.defaults;
                  return _ActionRow(
                    icon: Icons.tune_rounded,
                    title: 'New session defaults',
                    subtitle:
                        '${defaults.approval.label} · ${defaults.sandbox.label}',
                    onTap: () => unawaited(onEditLaunchDefaults()),
                  );
                },
              ),
            ],
          ),
        if (category == null || category == 'Local data')
          _SettingsSection(
            icon: Icons.warning_amber_rounded,
            title: 'Local data',
            openAsPage: category == null,
            subtitle: 'Clear information saved only on this device.',
            children: [
              Column(
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
                  Divider(
                    color: colors.border,
                    indent: AppSpacing.md + AppSizes.icon + AppSpacing.sm,
                  ),
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
                  Divider(
                    color: colors.border,
                    indent: AppSpacing.md + AppSizes.icon + AppSpacing.sm,
                  ),
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
            ],
          ),

        if (category == null || category == 'About')
          _AboutFooter(
            platformLabel: platformLabel,
            hasDesktopControls: hasDesktopControls,
            onResetSidebarWidth: onResetSidebarWidth,
            onResetInspectorWidth: onResetInspectorWidth,
            onReplayOnboarding: onReplayOnboarding,
          ),
      ],
    );

    return AppContentColumn(child: list);
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
    this.openAsPage = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool openAsPage;

  @override
  Widget build(BuildContext context) {
    if (openAsPage) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        child: Material(
          color: context.colors.surfaceElevated,
          borderRadius: AppShapes.card,
          child: AppSettingsRow(
            icon: icon,
            title: title,
            subtitle: subtitle,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(initialCategory: title),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Text(
              title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.colors.textSecondary,
              ),
            ),
          ),
          Material(
            color: context.colors.surfaceElevated,
            borderRadius: AppShapes.card,
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppUpdateSettingsCard extends StatelessWidget {
  const _AppUpdateSettingsCard({
    required this.appUpdateStore,
    required this.appVersionStore,
    required this.onRetryAppUpdateSettings,
    required this.onCheckForUpdatesNow,
    required this.onSetAutomaticUpdateChecks,
    required this.onSetUpdateCheckInterval,
  });

  final AppUpdateSettingsStore appUpdateStore;
  final AppVersionStore appVersionStore;
  final Future<void> Function() onRetryAppUpdateSettings;
  final Future<void> Function() onCheckForUpdatesNow;
  final Future<void> Function(bool value) onSetAutomaticUpdateChecks;
  final Future<void> Function(AppUpdateCheckIntervalOption option)
  onSetUpdateCheckInterval;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appUpdateStore, appVersionStore]),
      builder: (context, _) {
        final settings = appUpdateStore.settings;
        final versionInfo = appVersionStore.info;
        final supported = settings.supported;
        final loaded = settings.loaded;
        final loadFailed = settings.loadFailed;
        final automaticChecks = settings.automaticallyChecksForUpdates;
        final checkNowEnabled =
            supported &&
            loaded &&
            settings.canCheckForUpdates &&
            !appUpdateStore.checking &&
            !appUpdateStore.saving;
        final subtitle = !loaded
            ? 'Loading macOS update settings...'
            : loadFailed
            ? 'Could not load macOS update settings.'
            : supported
            ? automaticChecks
                  ? '${settings.intervalLabel} background checks are on.'
                  : 'Automatic checks are off. Manual checks still work.'
            : 'Automatic updates are unavailable in this build.';
        final versionLabel = versionInfo.loaded
            ? versionInfo.displayVersion
            : 'Version unavailable';
        final cardBody = !loaded
            ? 'Reading the updater configuration for $versionLabel.'
            : loadFailed
            ? 'Sidemesh could not reach its macOS updater. Retry the connection, or restart the app if the problem continues.'
            : supported
            ? 'You are on $versionLabel. '
            : 'You are on $versionLabel. Install the signed production macOS build if you want in-app update checks.';
        final selectedInterval = settings.selectedIntervalOption;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsCard(
              icon: Icons.system_update_rounded,
              title: 'Mac app updates',
              subtitle: subtitle,
              body: cardBody,
              trailing: loadFailed
                  ? OutlinedButton(
                      onPressed: appUpdateStore.loading
                          ? null
                          : () => unawaited(onRetryAppUpdateSettings()),
                      child: Text(
                        appUpdateStore.loading ? 'Retrying...' : 'Retry',
                      ),
                    )
                  : supported
                  ? OutlinedButton(
                      onPressed: checkNowEnabled
                          ? () => unawaited(onCheckForUpdatesNow())
                          : null,
                      child: Text(
                        appUpdateStore.checking ? 'Checking...' : 'Check now',
                      ),
                    )
                  : null,
            ),
            if (supported) ...[
              const SizedBox(height: AppSpacing.md),
              _ToggleTile(
                icon: Icons.schedule_rounded,
                title: 'Check automatically',
                subtitle: 'Check for updates in the background.',
                value: automaticChecks,
                onChanged: !appUpdateStore.saving
                    ? (value) => unawaited(onSetAutomaticUpdateChecks(value))
                    : null,
              ),
              AppSettingsRow(
                icon: Icons.event_repeat_rounded,
                title: 'How often',
                subtitle: automaticChecks ? null : 'Automatic checks are off.',
                trailing: AppSelect<AppUpdateCheckIntervalOption>(
                  value: selectedInterval,
                  values: AppUpdateCheckIntervalOption.values,
                  label: (option) => option.label,
                  hint: settings.intervalLabel,
                  onChanged: automaticChecks && !appUpdateStore.saving
                      ? (option) => unawaited(onSetUpdateCheckInterval(option))
                      : null,
                ),
              ),
            ],
          ],
        );
      },
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
        horizontal: AppSpacing.md,
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
              height: AppLineHeights.caption,
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
                    icon: const Icon(
                      Icons.replay_rounded,
                      size: AppSizes.compactIcon,
                    ),
                    label: const Text('Replay onboarding'),
                  ),
                if (hasDesktopControls && onResetSidebarWidth != null)
                  OutlinedButton.icon(
                    onPressed: onResetSidebarWidth,
                    icon: const Icon(
                      Icons.view_sidebar_rounded,
                      size: AppSizes.compactIcon,
                    ),
                    label: const Text('Reset sidebar'),
                  ),
                if (hasDesktopControls && onResetInspectorWidth != null)
                  OutlinedButton.icon(
                    onPressed: onResetInspectorWidth,
                    icon: const Icon(
                      Icons.tune_rounded,
                      size: AppSizes.compactIcon,
                    ),
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
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? body;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AppSettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      footer: body == null
          ? null
          : Text(
              body!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
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
    return AppSettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      danger: danger,
      onTap: busy ? null : onTap,
      trailing: busy
          ? const SizedBox.square(
              dimension: AppSizes.icon,
              child: CircularProgressIndicator(
                strokeWidth: AppStrokes.indicator,
              ),
            )
          : const Icon(Icons.chevron_right_rounded),
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
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AppSettingsRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}
