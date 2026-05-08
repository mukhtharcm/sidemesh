import 'package:flutter/material.dart';

import '../api_client.dart' show ApiClient, friendlyError;
import '../models.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../widgets/mesh_widgets.dart';

Future<HostServerConfigUpdateResult?> showHostServerConfigSheet(
  BuildContext context, {
  required HostProfile host,
  required ApiClient api,
}) {
  return showModalBottomSheet<HostServerConfigUpdateResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _HostServerConfigSheet(host: host, api: api),
  );
}

class _HostServerConfigSheet extends StatefulWidget {
  const _HostServerConfigSheet({required this.host, required this.api});

  final HostProfile host;
  final ApiClient api;

  @override
  State<_HostServerConfigSheet> createState() => _HostServerConfigSheetState();
}

class _HostServerConfigSheetState extends State<_HostServerConfigSheet> {
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _recommendedController = TextEditingController();
  final TextEditingController _minimumController = TextEditingController();
  final TextEditingController _terminalShellController =
      TextEditingController();
  final TextEditingController _browserChromePathController =
      TextEditingController();
  final TextEditingController _browserMaxPreviewsController =
      TextEditingController();
  final TextEditingController _browserIdleTtlController =
      TextEditingController();
  final TextEditingController _browserFrameIntervalController =
      TextEditingController();
  final TextEditingController _browserQualityController =
      TextEditingController();

  HostServerConfigSnapshot? _snapshot;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  bool _terminalEnabled = false;
  bool _terminalRequirePty = false;
  bool _portForwardingEnabled = false;
  bool _portForwardingAllowNonLoopbackTargets = false;
  bool _browserPreviewEnabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _labelController.dispose();
    _recommendedController.dispose();
    _minimumController.dispose();
    _terminalShellController.dispose();
    _browserChromePathController.dispose();
    _browserMaxPreviewsController.dispose();
    _browserIdleTtlController.dispose();
    _browserFrameIntervalController.dispose();
    _browserQualityController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final snapshot = await widget.api.fetchServerConfig(widget.host);
      if (!mounted) return;
      _applySnapshot(snapshot);
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = friendlyError(error);
      });
    }
  }

  void _applySnapshot(HostServerConfigSnapshot snapshot) {
    final config = snapshot.config;
    _labelController.text = config.label;
    _recommendedController.text = config.recommendedMobileClientVersion ?? '';
    _minimumController.text = config.minimumMobileClientVersion ?? '';
    _terminalEnabled = config.terminal.enabled;
    _terminalShellController.text = config.terminal.shell ?? '';
    _terminalRequirePty = config.terminal.requirePty;
    _portForwardingEnabled = config.portForwarding.enabled;
    _portForwardingAllowNonLoopbackTargets =
        config.portForwarding.allowNonLoopbackTargets;
    _browserPreviewEnabled = config.browserPreview.enabled;
    _browserChromePathController.text = config.browserPreview.chromePath ?? '';
    _browserMaxPreviewsController.text = '${config.browserPreview.maxPreviews}';
    _browserIdleTtlController.text = '${config.browserPreview.idleTtlMs}';
    _browserFrameIntervalController.text =
        '${config.browserPreview.frameIntervalMs}';
    _browserQualityController.text = '${config.browserPreview.quality}';
  }

  HostServerConfigFieldMeta _meta(String path) {
    return _snapshot?.fields[path] ?? HostServerConfigFieldMeta.empty;
  }

  bool _editable(String path) => !_saving && _meta(path).writable;

  String _fieldHint(String path) {
    final meta = _meta(path);
    final source = switch (meta.source) {
      'env' => 'source: env override',
      'file' => 'source: config file',
      _ => 'source: default',
    };
    final apply = meta.requiresRestart
        ? 'requires daemon restart'
        : 'applies immediately';
    return '$source · $apply';
  }

  Future<void> _save() async {
    final snapshot = _snapshot;
    if (snapshot == null || _saving) {
      return;
    }
    final config = snapshot.config;
    final patch = <String, dynamic>{};

    final label = _labelController.text.trim();
    if (label.isEmpty) {
      showAppSnackBar(context, 'Label cannot be empty.');
      return;
    }
    if (label != config.label) {
      patch['label'] = label;
    }

    final recommended = _normalizeNullableString(_recommendedController.text);
    if (recommended != config.recommendedMobileClientVersion) {
      patch['recommendedMobileClientVersion'] = recommended;
    }

    final minimum = _normalizeNullableString(_minimumController.text);
    if (minimum != config.minimumMobileClientVersion) {
      patch['minimumMobileClientVersion'] = minimum;
    }

    final terminalPatch = <String, dynamic>{};
    if (_terminalEnabled != config.terminal.enabled) {
      terminalPatch['enabled'] = _terminalEnabled;
    }
    final terminalShell = _normalizeNullableString(
      _terminalShellController.text,
    );
    if (terminalShell != config.terminal.shell) {
      terminalPatch['shell'] = terminalShell;
    }
    if (_terminalRequirePty != config.terminal.requirePty) {
      terminalPatch['requirePty'] = _terminalRequirePty;
    }
    if (terminalPatch.isNotEmpty) {
      patch['terminal'] = terminalPatch;
    }

    final portPatch = <String, dynamic>{};
    if (_portForwardingEnabled != config.portForwarding.enabled) {
      portPatch['enabled'] = _portForwardingEnabled;
    }
    if (_portForwardingAllowNonLoopbackTargets !=
        config.portForwarding.allowNonLoopbackTargets) {
      portPatch['allowNonLoopbackTargets'] =
          _portForwardingAllowNonLoopbackTargets;
    }
    if (portPatch.isNotEmpty) {
      patch['portForwarding'] = portPatch;
    }

    final browserPatch = <String, dynamic>{};
    if (_browserPreviewEnabled != config.browserPreview.enabled) {
      browserPatch['enabled'] = _browserPreviewEnabled;
    }
    final chromePath = _normalizeNullableString(
      _browserChromePathController.text,
    );
    if (chromePath != config.browserPreview.chromePath) {
      browserPatch['chromePath'] = chromePath;
    }
    final maxPreviews = _parseIntField(
      controller: _browserMaxPreviewsController,
      label: 'Browser preview max sessions',
    );
    if (maxPreviews == null) return;
    if (maxPreviews != config.browserPreview.maxPreviews) {
      browserPatch['maxPreviews'] = maxPreviews;
    }
    final idleTtlMs = _parseIntField(
      controller: _browserIdleTtlController,
      label: 'Browser preview idle TTL',
    );
    if (idleTtlMs == null) return;
    if (idleTtlMs != config.browserPreview.idleTtlMs) {
      browserPatch['idleTtlMs'] = idleTtlMs;
    }
    final frameIntervalMs = _parseIntField(
      controller: _browserFrameIntervalController,
      label: 'Browser preview frame interval',
    );
    if (frameIntervalMs == null) return;
    if (frameIntervalMs != config.browserPreview.frameIntervalMs) {
      browserPatch['frameIntervalMs'] = frameIntervalMs;
    }
    final quality = _parseIntField(
      controller: _browserQualityController,
      label: 'Browser preview quality',
    );
    if (quality == null) return;
    if (quality != config.browserPreview.quality) {
      browserPatch['quality'] = quality;
    }
    if (browserPatch.isNotEmpty) {
      patch['browserPreview'] = browserPatch;
    }

    if (patch.isEmpty) {
      showAppSnackBar(context, 'No changes to save.');
      return;
    }

    setState(() => _saving = true);
    try {
      final result = await widget.api.updateServerConfig(
        widget.host,
        patch: patch,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, 'Save failed: ${friendlyError(error)}');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  int? _parseIntField({
    required TextEditingController controller,
    required String label,
  }) {
    final value = int.tryParse(controller.text.trim());
    if (value == null) {
      showAppSnackBar(context, '$label must be a whole number.');
      return null;
    }
    return value;
  }

  String? _normalizeNullableString(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.94,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: AppShapes.sheetTop,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            children: [
              _SheetHeader(
                saving: _saving,
                onClose: () => Navigator.of(context).pop(),
                onSave: _loading || _loadError != null || _saving
                    ? null
                    : _save,
              ),
              Expanded(
                child: _loading
                    ? const Center(child: MeshLoader())
                    : _loadError != null
                    ? _LoadErrorView(
                        message: _loadError!,
                        onRetry: _saving ? null : _load,
                      )
                    : _ConfigFormView(
                        snapshot: _snapshot!,
                        labelController: _labelController,
                        recommendedController: _recommendedController,
                        minimumController: _minimumController,
                        terminalEnabled: _terminalEnabled,
                        terminalShellController: _terminalShellController,
                        terminalRequirePty: _terminalRequirePty,
                        portForwardingEnabled: _portForwardingEnabled,
                        portForwardingAllowNonLoopbackTargets:
                            _portForwardingAllowNonLoopbackTargets,
                        browserPreviewEnabled: _browserPreviewEnabled,
                        browserChromePathController:
                            _browserChromePathController,
                        browserMaxPreviewsController:
                            _browserMaxPreviewsController,
                        browserIdleTtlController: _browserIdleTtlController,
                        browserFrameIntervalController:
                            _browserFrameIntervalController,
                        browserQualityController: _browserQualityController,
                        editable: _editable,
                        fieldHint: _fieldHint,
                        onTerminalEnabledChanged: (value) =>
                            setState(() => _terminalEnabled = value),
                        onTerminalRequirePtyChanged: (value) =>
                            setState(() => _terminalRequirePty = value),
                        onPortForwardingEnabledChanged: (value) =>
                            setState(() => _portForwardingEnabled = value),
                        onPortAllowNonLoopbackChanged: (value) => setState(
                          () => _portForwardingAllowNonLoopbackTargets = value,
                        ),
                        onBrowserPreviewEnabledChanged: (value) =>
                            setState(() => _browserPreviewEnabled = value),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.saving,
    required this.onClose,
    required this.onSave,
  });

  final bool saving;
  final VoidCallback onClose;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Server settings',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: AppWeights.title),
            ),
          ),
          TextButton(
            onPressed: saving ? null : onClose,
            child: const Text('Close'),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: onSave,
            child: Text(saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}

class _LoadErrorView extends StatelessWidget {
  const _LoadErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 26),
            const SizedBox(height: AppSpacing.sm),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.md),
            FilledButton(
              onPressed: onRetry == null ? null : () => onRetry!(),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfigFormView extends StatelessWidget {
  const _ConfigFormView({
    required this.snapshot,
    required this.labelController,
    required this.recommendedController,
    required this.minimumController,
    required this.terminalEnabled,
    required this.terminalShellController,
    required this.terminalRequirePty,
    required this.portForwardingEnabled,
    required this.portForwardingAllowNonLoopbackTargets,
    required this.browserPreviewEnabled,
    required this.browserChromePathController,
    required this.browserMaxPreviewsController,
    required this.browserIdleTtlController,
    required this.browserFrameIntervalController,
    required this.browserQualityController,
    required this.editable,
    required this.fieldHint,
    required this.onTerminalEnabledChanged,
    required this.onTerminalRequirePtyChanged,
    required this.onPortForwardingEnabledChanged,
    required this.onPortAllowNonLoopbackChanged,
    required this.onBrowserPreviewEnabledChanged,
  });

  final HostServerConfigSnapshot snapshot;
  final TextEditingController labelController;
  final TextEditingController recommendedController;
  final TextEditingController minimumController;
  final bool terminalEnabled;
  final TextEditingController terminalShellController;
  final bool terminalRequirePty;
  final bool portForwardingEnabled;
  final bool portForwardingAllowNonLoopbackTargets;
  final bool browserPreviewEnabled;
  final TextEditingController browserChromePathController;
  final TextEditingController browserMaxPreviewsController;
  final TextEditingController browserIdleTtlController;
  final TextEditingController browserFrameIntervalController;
  final TextEditingController browserQualityController;
  final bool Function(String path) editable;
  final String Function(String path) fieldHint;
  final ValueChanged<bool> onTerminalEnabledChanged;
  final ValueChanged<bool> onTerminalRequirePtyChanged;
  final ValueChanged<bool> onPortForwardingEnabledChanged;
  final ValueChanged<bool> onPortAllowNonLoopbackChanged;
  final ValueChanged<bool> onBrowserPreviewEnabledChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final restart = snapshot.restart;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        if (!restart.serviceManaged)
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: colors.warningMuted,
              borderRadius: BorderRadius.circular(AppRadii.input),
              border: Border.all(color: colors.warning.withValues(alpha: 0.45)),
            ),
            child: Text(
              'This host is not service-managed. Restart-required changes may need a manual daemon restart.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        _SectionLabel(title: 'Host'),
        _TextFieldRow(
          controller: labelController,
          label: 'Label',
          hint: fieldHint('label'),
          enabled: editable('label'),
        ),
        _TextFieldRow(
          controller: recommendedController,
          label: 'Recommended mobile version',
          hint: fieldHint('recommendedMobileClientVersion'),
          enabled: editable('recommendedMobileClientVersion'),
          placeholder: 'e.g. 1.5.0',
        ),
        _TextFieldRow(
          controller: minimumController,
          label: 'Minimum mobile version',
          hint: fieldHint('minimumMobileClientVersion'),
          enabled: editable('minimumMobileClientVersion'),
          placeholder: 'e.g. 1.3.0',
        ),
        const SizedBox(height: AppSpacing.lg),
        _SectionLabel(title: 'Terminal'),
        _SwitchRow(
          value: terminalEnabled,
          label: 'Enabled',
          hint: fieldHint('terminal.enabled'),
          enabled: editable('terminal.enabled'),
          onChanged: onTerminalEnabledChanged,
        ),
        _TextFieldRow(
          controller: terminalShellController,
          label: 'Shell path',
          hint: fieldHint('terminal.shell'),
          enabled: editable('terminal.shell'),
          placeholder: '/bin/zsh',
        ),
        _SwitchRow(
          value: terminalRequirePty,
          label: 'Require PTY',
          hint: fieldHint('terminal.requirePty'),
          enabled: editable('terminal.requirePty'),
          onChanged: onTerminalRequirePtyChanged,
        ),
        const SizedBox(height: AppSpacing.lg),
        _SectionLabel(title: 'Port forwarding'),
        _SwitchRow(
          value: portForwardingEnabled,
          label: 'Enabled',
          hint: fieldHint('portForwarding.enabled'),
          enabled: editable('portForwarding.enabled'),
          onChanged: onPortForwardingEnabledChanged,
        ),
        _SwitchRow(
          value: portForwardingAllowNonLoopbackTargets,
          label: 'Allow non-loopback targets',
          hint: fieldHint('portForwarding.allowNonLoopbackTargets'),
          enabled: editable('portForwarding.allowNonLoopbackTargets'),
          onChanged: onPortAllowNonLoopbackChanged,
        ),
        const SizedBox(height: AppSpacing.lg),
        _SectionLabel(title: 'Browser preview'),
        _SwitchRow(
          value: browserPreviewEnabled,
          label: 'Enabled',
          hint: fieldHint('browserPreview.enabled'),
          enabled: editable('browserPreview.enabled'),
          onChanged: onBrowserPreviewEnabledChanged,
        ),
        _TextFieldRow(
          controller: browserChromePathController,
          label: 'Chrome path',
          hint: fieldHint('browserPreview.chromePath'),
          enabled: editable('browserPreview.chromePath'),
          placeholder: '/usr/bin/google-chrome',
        ),
        _TextFieldRow(
          controller: browserMaxPreviewsController,
          label: 'Max previews',
          hint: fieldHint('browserPreview.maxPreviews'),
          enabled: editable('browserPreview.maxPreviews'),
          keyboardType: TextInputType.number,
        ),
        _TextFieldRow(
          controller: browserIdleTtlController,
          label: 'Idle TTL (ms)',
          hint: fieldHint('browserPreview.idleTtlMs'),
          enabled: editable('browserPreview.idleTtlMs'),
          keyboardType: TextInputType.number,
        ),
        _TextFieldRow(
          controller: browserFrameIntervalController,
          label: 'Frame interval (ms)',
          hint: fieldHint('browserPreview.frameIntervalMs'),
          enabled: editable('browserPreview.frameIntervalMs'),
          keyboardType: TextInputType.number,
        ),
        _TextFieldRow(
          controller: browserQualityController,
          label: 'JPEG quality',
          hint: fieldHint('browserPreview.quality'),
          enabled: editable('browserPreview.quality'),
          keyboardType: TextInputType.number,
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: colors.textTertiary,
          letterSpacing: AppLetterSpacing.caps,
          fontWeight: AppWeights.emphasis,
        ),
      ),
    );
  }
}

class _TextFieldRow extends StatelessWidget {
  const _TextFieldRow({
    required this.controller,
    required this.label,
    required this.hint,
    required this.enabled,
    this.keyboardType,
    this.placeholder,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool enabled;
  final TextInputType? keyboardType;
  final String? placeholder;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            controller: controller,
            enabled: enabled,
            keyboardType: keyboardType,
            decoration: InputDecoration(hintText: placeholder, isDense: true),
          ),
          const SizedBox(height: 2),
          Text(
            hint,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: enabled ? colors.textTertiary : colors.warning,
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.value,
    required this.label,
    required this.hint,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final String hint;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(
        hint,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: enabled ? colors.textTertiary : colors.warning,
        ),
      ),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}
