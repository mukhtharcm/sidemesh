import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_message_seed_store.dart';
import '../session_policy_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';

enum CreateSessionPresentation { sheet, dialog }

class CreateSessionLaunchResult {
  const CreateSessionLaunchResult({required this.host, required this.session});

  final HostProfile host;
  final SessionSummary session;
}

Future<SessionSummary?> showCreateSessionLauncher(
  BuildContext context, {
  required HostProfile host,
  required ApiClient api,
  String? initialCwd,
}) {
  final isDialog = MediaQuery.sizeOf(context).width >= 760;
  if (isDialog) {
    return showDialog<SessionSummary>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.36),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 820),
          child: CreateSessionSheet(
            host: host,
            api: api,
            initialCwd: initialCwd,
            presentation: CreateSessionPresentation.dialog,
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<SessionSummary>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.94,
      child: CreateSessionSheet(host: host, api: api, initialCwd: initialCwd),
    ),
  );
}

Future<CreateSessionLaunchResult?> showCreateSessionHostLauncher(
  BuildContext context, {
  required List<HostProfile> hosts,
  required ApiClient api,
  String? initialCwd,
}) async {
  if (hosts.isEmpty) return null;
  final host = hosts.length == 1
      ? hosts.first
      : await showCreateSessionHostPicker(context, hosts: hosts);
  if (!context.mounted || host == null) return null;
  final session = await showCreateSessionLauncher(
    context,
    host: host,
    api: api,
    initialCwd: initialCwd,
  );
  if (session == null) return null;
  return CreateSessionLaunchResult(host: host, session: session);
}

Future<HostProfile?> showCreateSessionHostPicker(
  BuildContext context, {
  required List<HostProfile> hosts,
}) {
  final isDialog = MediaQuery.sizeOf(context).width >= 760;
  final picker = _HostPickerSurface(hosts: hosts);
  if (isDialog) {
    return showDialog<HostProfile>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.36),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
          child: picker,
        ),
      ),
    );
  }
  return showModalBottomSheet<HostProfile>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) =>
        FractionallySizedBox(heightFactor: 0.78, child: picker),
  );
}

class _HostPickerSurface extends StatelessWidget {
  const _HostPickerSurface({required this.hosts});

  final List<HostProfile> hosts;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: const EdgeInsets.all(18),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: colors.accentMuted,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colors.accent.withValues(alpha: 0.35),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.hub_rounded,
                      color: colors.accent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Choose host',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          'Pick where the new Codex session should run.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: hosts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final host = hosts[index];
                    return MeshCard(
                      tone: MeshCardTone.muted,
                      padding: const EdgeInsets.all(14),
                      onTap: () => Navigator.of(context).pop(host),
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: colors.border),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.dns_rounded,
                              color: colors.accent,
                              size: 17,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  host.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  host.baseUrl,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: monoStyle(
                                    color: colors.textSecondary,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: colors.textTertiary,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CreateSessionSheet extends StatefulWidget {
  const CreateSessionSheet({
    super.key,
    required this.host,
    required this.api,
    this.initialCwd,
    this.presentation = CreateSessionPresentation.sheet,
  });

  final HostProfile host;
  final ApiClient api;
  final String? initialCwd;
  final CreateSessionPresentation presentation;

  @override
  State<CreateSessionSheet> createState() => _CreateSessionSheetState();
}

class _CreateSessionSheetState extends State<CreateSessionSheet> {
  late final TextEditingController _cwdController;
  late final TextEditingController _promptController;
  late final TextEditingController _profileController;

  List<ModelCatalogEntry> _models = const <ModelCatalogEntry>[];
  ModelCatalogEntry? _selectedModel;
  String? _reasoningEffort;
  String? _modelsError;
  ApprovalPolicy _approval = ApprovalPolicy.onRequest;
  SandboxMode _sandbox = SandboxMode.workspaceWrite;
  bool _loadingModels = false;
  bool _fastMode = false;
  bool _webSearch = false;
  bool _showAdvanced = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cwdController = TextEditingController(text: widget.initialCwd ?? '');
    _promptController = TextEditingController();
    _profileController = TextEditingController();
  }

  @override
  void dispose() {
    _cwdController.dispose();
    _promptController.dispose();
    _profileController.dispose();
    super.dispose();
  }

  ModelCatalogEntry? get _defaultModelEntry {
    for (final model in _models) {
      if (model.isDefault) return model;
    }
    return _models.isEmpty ? null : _models.first;
  }

  ModelCatalogEntry? get _controlModel => _selectedModel ?? _defaultModelEntry;

  bool get _controlModelIsAuto => _controlModel?.isAutoModel ?? false;

  bool get _fastSupported => _controlModel?.supportsFastMode ?? false;

  String? get _effectiveReasoningEffort {
    final model = _controlModel;
    if (model == null) return _reasoningEffort;
    if (model.isAutoModel) return model.defaultReasoningEffort;
    return _reasoningEffort ?? _trimmedOrNull(model.defaultReasoningEffort);
  }

  List<ModelReasoningEffortOption> get _supportedReasoningOptions {
    final model = _controlModel;
    if (model == null || model.supportedReasoningEfforts.isEmpty) {
      return const <ModelReasoningEffortOption>[];
    }
    return model.supportedReasoningEfforts;
  }

  String get _modelLabel {
    final selected = _selectedModel;
    if (selected != null) return selected.displayName;
    return 'Use host default';
  }

  String get _modelDescription {
    if (_loadingModels) {
      return 'Loading the available Codex models from this host.';
    }
    if (_modelsError != null) {
      return _modelsError!;
    }
    final selected = _selectedModel;
    if (selected != null && selected.description.trim().isNotEmpty) {
      return selected.description.trim();
    }
    final defaultModel = _defaultModelEntry;
    if (defaultModel != null) {
      return 'Host default: ${defaultModel.displayName}. Leave unset to let Codex use this host\'s current config.';
    }
    return 'Leave unset to let Codex use this host\'s current config.';
  }

  String? get _reasoningToSubmit {
    if (_controlModelIsAuto) return null;
    return _trimmedOrNull(_reasoningEffort);
  }

  Future<void> _loadModels() async {
    if (_loadingModels) return;
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });

    try {
      final models = await widget.api.fetchModels(widget.host);
      models.sort(_compareModelEntries);
      if (!mounted) return;
      setState(() {
        _models = models;
        _loadingModels = false;
        _modelsError = models.isEmpty
            ? 'Codex did not return any models for this host.'
            : null;
        _coerceCurrentModelOptions();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _modelsError = friendlyError(error);
      });
    }
  }

  void _coerceCurrentModelOptions() {
    final model = _controlModel;
    if (model == null) return;

    if (model.isAutoModel) {
      _reasoningEffort = null;
    } else {
      final supported = model.supportedReasoningEfforts
          .map((option) => option.reasoningEffort)
          .toSet();
      final reasoning = _trimmedOrNull(_reasoningEffort);
      if (reasoning != null && !supported.contains(reasoning)) {
        _reasoningEffort = _trimmedOrNull(model.defaultReasoningEffort);
      }
    }

    if (!model.supportsFastMode) {
      _fastMode = false;
    }
  }

  void _toggleAdvanced() {
    setState(() => _showAdvanced = !_showAdvanced);
    if (_showAdvanced && _models.isEmpty && _modelsError == null) {
      unawaited(_loadModels());
    }
  }

  Future<void> _chooseModel() async {
    if (_loadingModels) return;
    if (_models.isEmpty) {
      await _loadModels();
      if (!mounted || _models.isEmpty) return;
    }

    final result = await showModalBottomSheet<_ModelPickerResult>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _ModelPickerSheet(
        models: _models,
        currentModel: _selectedModel?.model,
        defaultModel: _defaultModelEntry,
      ),
    );
    if (!mounted || result == null) return;

    setState(() {
      _selectedModel = result.model;
      final model = _controlModel;
      if (model == null || model.isAutoModel) {
        _reasoningEffort = null;
      } else {
        final supported = model.supportedReasoningEfforts
            .map((option) => option.reasoningEffort)
            .toSet();
        if (!supported.contains(_reasoningEffort)) {
          _reasoningEffort = _trimmedOrNull(model.defaultReasoningEffort);
        }
      }
      _coerceCurrentModelOptions();
    });
  }

  void _applyAutopilot() {
    setState(() {
      _approval = ApprovalPolicy.never;
      _sandbox = SandboxMode.dangerFullAccess;
    });
  }

  Future<void> _submit() async {
    final cwd = _cwdController.text.trim();
    final prompt = _promptController.text.trim();
    if (cwd.isEmpty || prompt.isEmpty) {
      setState(() => _error = 'Working directory and prompt are required.');
      return;
    }

    setState(() {
      _error = null;
      _submitting = true;
    });

    try {
      final session = await widget.api.createSession(
        widget.host,
        cwd: cwd,
        prompt: prompt,
        model: _selectedModel?.model,
        reasoningEffort: _reasoningToSubmit,
        fastMode: _fastMode ? true : null,
        approvalPolicy: _approval.wire,
        sandboxMode: _sandbox.wire,
        webSearch: _webSearch ? 'live' : null,
        profile: _trimmedOrNull(_profileController.text),
      );
      final submittedAt = DateTime.now();
      SessionMessageSeedStore.instance.put(
        widget.host,
        session.id,
        SessionMessage(
          id: 'local-create-${submittedAt.microsecondsSinceEpoch}',
          role: 'user',
          text: prompt,
          attachments: const <SessionMessageAttachment>[],
          createdAt: submittedAt,
          seq: 0,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(session);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(error);
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDialog = widget.presentation == CreateSessionPresentation.dialog;
    final bottom = isDialog ? 0.0 : MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: isDialog
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(16, 12, 16, bottom + 16),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: EdgeInsets.all(isDialog ? 20 : 16),
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: 18),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: _buildPrimaryPanel(context)),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 4,
                            child: _showAdvanced
                                ? _buildAdvancedPanel(context)
                                : _buildLaunchSummaryCard(context),
                          ),
                        ],
                      )
                    else ...[
                      _buildPrimaryPanel(context),
                      const SizedBox(height: 14),
                      _showAdvanced
                          ? _buildAdvancedPanel(context)
                          : _buildLaunchSummaryCard(context),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      _ErrorPanel(message: _error!),
                    ],
                    const SizedBox(height: 18),
                    _buildFooter(context),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: colors.accent.withValues(alpha: 0.35)),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.terminal_rounded, color: colors.accent, size: 21),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Launch Codex',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  MeshPill(
                    label: widget.host.label,
                    icon: Icons.dns_rounded,
                    tone: MeshPillTone.accent,
                  ),
                  MeshPill(
                    label: 'fresh session',
                    icon: Icons.play_circle_outline_rounded,
                    tone: MeshPillTone.neutral,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPrimaryPanel(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.muted,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeading(
            icon: Icons.route_rounded,
            title: 'Session route',
            subtitle: 'Where the agent starts and what it should do first.',
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _cwdController,
            textInputAction: TextInputAction.next,
            style: monoStyle(color: colors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              labelText: 'Working directory',
              hintText: '/Users/you/src/project',
              prefixIcon: Icon(Icons.folder_open_rounded),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _promptController,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'Prompt',
              hintText: 'Ask Codex what to work on...',
              alignLabelWithHint: true,
              prefixIcon: Icon(Icons.keyboard_command_key_rounded),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLaunchSummaryCard(BuildContext context) {
    final colors = context.colors;
    return MeshCard(
      tone: MeshCardTone.muted,
      padding: const EdgeInsets.all(16),
      onTap: _submitting ? null : _toggleAdvanced,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeading(
            icon: Icons.tune_rounded,
            title: 'Launch profile',
            subtitle:
                'Defaults are ready. Tune model, speed and permissions if needed.',
            trailing: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: _launchPills()),
          const SizedBox(height: 14),
          TextButton.icon(
            onPressed: _submitting ? null : _toggleAdvanced,
            icon: const Icon(Icons.tune_rounded, size: 18),
            label: const Text('Tune launch'),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedPanel(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final effectiveReasoning = _effectiveReasoningEffort;
    String? reasoningDescription;
    for (final option in _supportedReasoningOptions) {
      if (option.reasoningEffort == effectiveReasoning) {
        reasoningDescription = option.description;
        break;
      }
    }

    return MeshCard(
      tone: MeshCardTone.muted,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeading(
            icon: Icons.tune_rounded,
            title: 'Launch controls',
            subtitle: 'Model, thinking, speed and safety for the first turn.',
            trailing: IconButton(
              tooltip: 'Hide advanced',
              onPressed: _submitting ? null : _toggleAdvanced,
              icon: const Icon(Icons.expand_less_rounded),
            ),
          ),
          const SizedBox(height: 14),
          _CompactControlGroup(
            icon: Icons.memory_rounded,
            title: 'Brain',
            children: [
              _ModelSelectionCard(
                value: _modelLabel,
                subtitle: _modelDescription,
                loading: _loadingModels,
                error: _modelsError,
                compact: true,
                badges: <String>[
                  if (_selectedModel != null) 'override',
                  if (_controlModel?.isAutoModel ?? false) 'auto',
                  if (_controlModel?.isDefault ?? false) 'default',
                  if (_controlModel?.supportsFastMode ?? false) 'fast',
                ],
                onTap: _chooseModel,
                onRetry: () => unawaited(_loadModels()),
              ),
              const SizedBox(height: 10),
              if (_loadingModels && _models.isEmpty)
                const LinearProgressIndicator(minHeight: 3)
              else if (_controlModelIsAuto)
                _CompactInfoLine(
                  icon: Icons.psychology_alt_rounded,
                  text:
                      'Auto thinking: ${_reasoningEffortLabel(effectiveReasoning ?? 'medium')}',
                )
              else if (_supportedReasoningOptions.isEmpty)
                const _CompactInfoLine(
                  icon: Icons.psychology_alt_rounded,
                  text: 'Pick a model to tune reasoning.',
                )
              else ...[
                _MiniChoiceWrap<String>(
                  icon: Icons.psychology_alt_rounded,
                  label: 'Reasoning',
                  value: effectiveReasoning,
                  options: _supportedReasoningOptions
                      .map((option) => option.reasoningEffort)
                      .toList(),
                  optionLabel: _reasoningEffortLabel,
                  isDefault: (value) =>
                      value == _controlModel?.defaultReasoningEffort,
                  onChanged: (value) {
                    setState(() {
                      _reasoningEffort = value;
                    });
                  },
                ),
                if (reasoningDescription != null &&
                    reasoningDescription.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      reasoningDescription.trim(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 10),
              _CompactSwitchRow(
                icon: Icons.bolt_rounded,
                title: 'Fast mode',
                subtitle: _fastSupported
                    ? 'Ask for the fast service tier.'
                    : 'Not advertised by this model.',
                value: _fastMode,
                enabled: _fastSupported,
                onChanged: (value) => setState(() => _fastMode = value),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CompactControlGroup(
            icon: Icons.verified_user_rounded,
            title: 'Permissions',
            trailing: TextButton.icon(
              onPressed: _applyAutopilot,
              icon: const Icon(Icons.auto_awesome_rounded, size: 16),
              label: const Text('Autopilot'),
            ),
            children: [
              _MiniChoiceWrap<ApprovalPolicy>(
                icon: Icons.verified_user_rounded,
                label: 'Approval',
                value: _approval,
                options: ApprovalPolicy.values,
                optionLabel: (policy) => policy.label,
                onChanged: (value) => setState(() => _approval = value),
              ),
              const SizedBox(height: 10),
              _MiniChoiceWrap<SandboxMode>(
                icon: Icons.folder_special_rounded,
                label: 'Sandbox',
                value: _sandbox,
                options: SandboxMode.values,
                optionLabel: (sandbox) => sandbox.label,
                danger: (sandbox) => sandbox == SandboxMode.dangerFullAccess,
                onChanged: (value) => setState(() => _sandbox = value),
              ),
              const SizedBox(height: 8),
              _CompactInfoLine(
                icon: Icons.info_outline_rounded,
                text: '${_approval.description} ${_sandbox.description}',
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CompactControlGroup(
            icon: Icons.public_rounded,
            title: 'Network & profile',
            children: [
              _CompactSwitchRow(
                icon: Icons.public_rounded,
                title: 'Live web search',
                subtitle: 'Starts the thread with Codex web search enabled.',
                value: _webSearch,
                enabled: !_submitting,
                onChanged: (value) => setState(() => _webSearch = value),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _profileController,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Profile override',
                  hintText: 'guardian',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 8, children: _launchPills()),
        ),
        const SizedBox(width: 12),
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded),
          label: const Text('Start'),
        ),
      ],
    );
  }

  List<Widget> _launchPills() {
    final reasoning = _effectiveReasoningEffort;
    return [
      MeshPill(
        label: _selectedModel?.displayName ?? 'host default',
        icon: Icons.memory_rounded,
        tone: _selectedModel == null
            ? MeshPillTone.neutral
            : MeshPillTone.accent,
      ),
      MeshPill(
        label: _controlModelIsAuto
            ? 'auto thinking'
            : reasoning == null
            ? 'default thinking'
            : _reasoningEffortLabel(reasoning),
        icon: Icons.psychology_alt_rounded,
      ),
      if (_fastMode)
        const MeshPill(
          label: 'fast',
          icon: Icons.bolt_rounded,
          tone: MeshPillTone.warning,
        ),
      MeshPill(label: _approval.label, icon: Icons.verified_user_rounded),
      MeshPill(
        label: _sandbox.label,
        icon: _sandbox == SandboxMode.dangerFullAccess
            ? Icons.lock_open_rounded
            : Icons.folder_special_rounded,
        tone: _sandbox == SandboxMode.dangerFullAccess
            ? MeshPillTone.danger
            : MeshPillTone.neutral,
      ),
      if (_webSearch)
        const MeshPill(
          label: 'web search',
          icon: Icons.public_rounded,
          tone: MeshPillTone.info,
        ),
    ];
  }
}

class _PanelHeading extends StatelessWidget {
  const _PanelHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: colors.border),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: colors.accent, size: 17),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.dangerMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: colors.danger, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.danger,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactControlGroup extends StatelessWidget {
  const _CompactControlGroup({
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _MiniChoiceWrap<T> extends StatelessWidget {
  const _MiniChoiceWrap({
    required this.icon,
    required this.label,
    required this.value,
    required this.options,
    required this.optionLabel,
    required this.onChanged,
    this.isDefault,
    this.danger,
  });

  final IconData icon;
  final String label;
  final T? value;
  final List<T> options;
  final String Function(T) optionLabel;
  final bool Function(T)? isDefault;
  final bool Function(T)? danger;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: colors.textSecondary),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: options.map((option) {
            final selected = option == value;
            final optionDanger = danger?.call(option) ?? false;
            final accent = optionDanger ? colors.danger : colors.accent;
            return InkWell(
              onTap: () => onChanged(option),
              borderRadius: BorderRadius.circular(999),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? accent.withValues(alpha: 0.14)
                      : colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: selected ? accent : colors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      optionLabel(option),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? accent : colors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (isDefault?.call(option) ?? false) ...[
                      const SizedBox(width: 5),
                      Text(
                        'default',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.textTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _CompactSwitchRow extends StatelessWidget {
  const _CompactSwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: value
            ? colors.accentMuted.withValues(alpha: 0.38)
            : colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: value ? colors.accent : colors.border),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: value ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: enabled ? onChanged : null),
        ],
      ),
    );
  }
}

class _CompactInfoLine extends StatelessWidget {
  const _CompactInfoLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: colors.textTertiary),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}

class _ModelSelectionCard extends StatelessWidget {
  const _ModelSelectionCard({
    required this.value,
    required this.subtitle,
    required this.loading,
    required this.error,
    required this.badges,
    required this.onTap,
    required this.onRetry,
    this.compact = false,
  });

  final String value;
  final String subtitle;
  final bool loading;
  final String? error;
  final List<String> badges;
  final VoidCallback onTap;
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 10 : 12),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Model',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: colors.textSecondary,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  value,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                ...badges.map((badge) => _InlineBadge(label: badge)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: compact ? 2 : null,
              overflow: compact ? TextOverflow.ellipsis : null,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: compact ? 1.25 : 1.35,
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry loading models'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModelPickerResult {
  const _ModelPickerResult(this.model);

  final ModelCatalogEntry? model;
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.models,
    required this.currentModel,
    required this.defaultModel,
  });

  final List<ModelCatalogEntry> models;
  final String? currentModel;
  final ModelCatalogEntry? defaultModel;

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final TextEditingController _queryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _queryController.addListener(_handleQueryChanged);
  }

  @override
  void dispose() {
    _queryController
      ..removeListener(_handleQueryChanged)
      ..dispose();
    super.dispose();
  }

  void _handleQueryChanged() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final query = _queryController.text.trim().toLowerCase();
    final filtered = widget.models
        .where((model) {
          if (query.isEmpty) return true;
          final haystack = [
            model.displayName,
            model.model,
            model.description,
          ].join('\n').toLowerCase();
          return haystack.contains(query);
        })
        .toList(growable: false);

    return FractionallySizedBox(
      heightFactor: 0.82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose model',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Leave the model unset to inherit this host\'s Codex config, or choose a model for this new session.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _queryController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search models',
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: filtered.isEmpty && query.isNotEmpty
                  ? Center(
                      child: Text(
                        'No models match that search.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length + (query.isEmpty ? 1 : 0),
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        if (query.isEmpty && index == 0) {
                          return _ModelPickerTile(
                            title: 'Use host default',
                            model: widget.defaultModel,
                            description:
                                'Do not send a model override. Codex will use the host profile or default config.',
                            selected: widget.currentModel == null,
                            badges: const <String>['inherit'],
                            onTap: () => Navigator.of(
                              context,
                            ).pop(const _ModelPickerResult(null)),
                          );
                        }
                        final model = filtered[index - (query.isEmpty ? 1 : 0)];
                        return _ModelPickerTile(
                          title: model.displayName,
                          model: model,
                          description: model.description,
                          selected: model.model == widget.currentModel,
                          badges: <String>[
                            if (model.isAutoModel) 'auto',
                            if (model.isDefault) 'default',
                            if (model.supportsFastMode) 'fast',
                            ...model.supportedReasoningEfforts
                                .take(3)
                                .map(
                                  (option) => _reasoningEffortLabel(
                                    option.reasoningEffort,
                                  ),
                                ),
                          ],
                          onTap: () => Navigator.of(
                            context,
                          ).pop(_ModelPickerResult(model)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelPickerTile extends StatelessWidget {
  const _ModelPickerTile({
    required this.title,
    required this.model,
    required this.description,
    required this.selected,
    required this.badges,
    required this.onTap,
  });

  final String title;
  final ModelCatalogEntry? model;
  final String description;
  final bool selected;
  final List<String> badges;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? colors.accent : colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (selected) const _InlineBadge(label: 'selected'),
              ],
            ),
            if (model != null) ...[
              const SizedBox(height: 4),
              Text(
                model!.model,
                style: monoStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: badges
                  .map((badge) => _InlineBadge(label: badge))
                  .toList(),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineBadge extends StatelessWidget {
  const _InlineBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: colors.textSecondary,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

int _compareModelEntries(ModelCatalogEntry left, ModelCatalogEntry right) {
  final rank = _modelSortRank(left).compareTo(_modelSortRank(right));
  if (rank != 0) return rank;
  if (left.isDefault != right.isDefault) {
    return left.isDefault ? -1 : 1;
  }
  final leftName = '${left.displayName}\n${left.model}'.toLowerCase();
  final rightName = '${right.displayName}\n${right.model}'.toLowerCase();
  return leftName.compareTo(rightName);
}

int _modelSortRank(ModelCatalogEntry model) {
  if (!model.isAutoModel) return 10;
  return switch (model.model) {
    'codex-auto-fast' => 0,
    'codex-auto-balanced' => 1,
    'codex-auto-thorough' => 2,
    _ => 3,
  };
}

String _reasoningEffortLabel(String value) {
  return switch (value) {
    'none' => 'None',
    'minimal' => 'Minimal',
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' => 'Extra high',
    _ => value,
  };
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
