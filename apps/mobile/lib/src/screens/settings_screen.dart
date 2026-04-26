import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../background_sync_service.dart';
import '../create_session_defaults_store.dart';
import '../image_blob_cache_store.dart';
import '../live_activity_service.dart';
import '../local_notification_service.dart';
import '../session_cache_store.dart';
import '../session_policy_store.dart';
import '../session_send_outbox_store.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/appearance_sheet.dart';
import '../widgets/mesh_widgets.dart';

Future<void> openSettingsScreen(
  BuildContext context, {
  VoidCallback? onResetSidebarWidth,
  VoidCallback? onResetInspectorWidth,
}) {
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
    this.onResetSidebarWidth,
    this.onResetInspectorWidth,
  });

  final VoidCallback? onResetSidebarWidth;
  final VoidCallback? onResetInspectorWidth;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final CreateSessionDefaultsStore _defaultsStore =
      CreateSessionDefaultsStore.instance;

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
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _LaunchDefaultsSheet(),
    );
    if (updated == true && mounted) {
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
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
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
                  '${_themeModeLabel(themeController.mode)} · ${themeController.variant.label} · ${themeController.typography.interfaceFont.label}',
              body:
                  'Theme mode, palette, and typography are global. Use the shared appearance controls from here.',
              trailing: FilledButton(
                onPressed: () => showAppearanceSheet(context),
                child: const Text('Customize'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _SettingsCard(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            subtitle: _notificationsLoading
                ? 'Checking device notification status...'
                : _notificationsSupported
                ? _notificationsAllowed
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
                  label: _notificationsLoading
                      ? 'checking alerts'
                      : _notificationsAllowed
                      ? 'alerts on'
                      : 'alerts off',
                  tone: _notificationsAllowed
                      ? MeshPillTone.success
                      : MeshPillTone.warning,
                  icon: _notificationsAllowed
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
                  label: _liveActivitiesSupported
                      ? 'live activity supported'
                      : 'live activity unavailable',
                  tone: _liveActivitiesSupported
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
                  onPressed: _notificationsLoading
                      ? null
                      : () => unawaited(_refreshNotificationStatus()),
                  child: const Text('Refresh'),
                ),
                if (_notificationsSupported && !_notificationsAllowed) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _notificationsRequesting
                        ? null
                        : () => unawaited(_requestNotifications()),
                    child: Text(
                      _notificationsRequesting ? 'Enabling...' : 'Enable',
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          ListenableBuilder(
            listenable: _defaultsStore,
            builder: (context, _) {
              final defaults = _defaultsStore.defaults;
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
                  onPressed: () => unawaited(_editLaunchDefaults()),
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
                  busy: _busyAction == 'transcript-cache',
                  onTap: () => unawaited(
                    _runStorageAction(
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
                  busy: _busyAction == 'image-cache',
                  onTap: () => unawaited(
                    _runStorageAction(
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
                      'Discard locally queued messages that are waiting to retry.',
                  busy: _busyAction == 'queued-sends',
                  onTap: () => unawaited(
                    _runStorageAction(
                      key: 'queued-sends',
                      title: 'Clear queued sends?',
                      body:
                          'This discards any locally queued messages waiting for retry. Remote sessions are unchanged.',
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
                  if (widget.onResetSidebarWidth != null)
                    OutlinedButton.icon(
                      onPressed: () {
                        widget.onResetSidebarWidth!.call();
                        showAppSnackBar(context, 'Sidebar width reset.');
                      },
                      icon: const Icon(Icons.view_sidebar_outlined, size: 18),
                      label: const Text('Reset sidebar'),
                    ),
                  if (widget.onResetInspectorWidth != null)
                    OutlinedButton.icon(
                      onPressed: () {
                        widget.onResetInspectorWidth!.call();
                        showAppSnackBar(context, 'Inspector width reset.');
                      },
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
            subtitle: _platformLabel(),
            body:
                'Hosts, tokens, favorites, pins, caches, and other local state stay inside this app install and flavor.',
            footer: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                MeshPill(
                  label: _platformLabel(),
                  icon: Icons.devices_rounded,
                  tone: MeshPillTone.neutral,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LaunchDefaultsSheet extends StatefulWidget {
  const _LaunchDefaultsSheet();

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
      padding: EdgeInsets.fromLTRB(
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
                      'Start new sessions with Codex web search enabled by default.',
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
