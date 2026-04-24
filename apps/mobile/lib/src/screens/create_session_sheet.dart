import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../models.dart';
import '../session_policy_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/mesh_widgets.dart';

class CreateSessionSheet extends StatefulWidget {
  const CreateSessionSheet({
    super.key,
    required this.host,
    required this.api,
    this.initialCwd,
  });

  final HostProfile host;
  final ApiClient api;
  final String? initialCwd;

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
    final colors = context.colors;
    final theme = Theme.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final effectiveReasoning = _effectiveReasoningEffort;
    String? reasoningDescription;
    for (final option in _supportedReasoningOptions) {
      if (option.reasoningEffort == effectiveReasoning) {
        reasoningDescription = option.description;
        break;
      }
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottom + 16),
      child: MeshCard(
        tone: MeshCardTone.surface,
        padding: const EdgeInsets.all(22),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.add_comment_outlined,
                        color: colors.accent,
                        size: 19,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'New Codex session',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Start a fresh session on ${widget.host.label}. Advanced options mirror the controls used on the chat page.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _cwdController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Working directory',
                    hintText: '/Users/you/src/project',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _promptController,
                  minLines: 3,
                  maxLines: 7,
                  decoration: const InputDecoration(
                    labelText: 'Prompt',
                    hintText: 'Ask Codex what to work on...',
                  ),
                ),
                const SizedBox(height: 14),
                TextButton.icon(
                  onPressed: _submitting ? null : _toggleAdvanced,
                  icon: Icon(
                    _showAdvanced
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _showAdvanced ? 'Hide advanced' : 'Show advanced',
                  ),
                ),
                if (_showAdvanced) ...[
                  const SizedBox(height: 8),
                  _SectionLabel(label: 'Model & thinking'),
                  const SizedBox(height: 8),
                  _ModelSelectionCard(
                    value: _modelLabel,
                    subtitle: _modelDescription,
                    loading: _loadingModels,
                    error: _modelsError,
                    badges: <String>[
                      if (_selectedModel != null) 'override',
                      if (_controlModel?.isAutoModel ?? false) 'auto',
                      if (_controlModel?.isDefault ?? false) 'default',
                      if (_controlModel?.supportsFastMode ?? false) 'fast',
                    ],
                    onTap: _chooseModel,
                    onRetry: () => unawaited(_loadModels()),
                  ),
                  const SizedBox(height: 18),
                  _SectionLabel(label: 'Reasoning effort'),
                  const SizedBox(height: 8),
                  if (_loadingModels && _models.isEmpty)
                    const LinearProgressIndicator(minHeight: 3)
                  else if (_controlModelIsAuto)
                    _InfoPanel(
                      text:
                          'Auto models choose the thinking effort themselves. Codex will use ${_reasoningEffortLabel(effectiveReasoning ?? 'medium')}.',
                    )
                  else if (_supportedReasoningOptions.isEmpty)
                    const _InfoPanel(
                      text:
                          'Pick a model to see the reasoning efforts this host exposes.',
                    )
                  else ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _supportedReasoningOptions.map((option) {
                        final selected =
                            option.reasoningEffort == effectiveReasoning;
                        final isDefault =
                            option.reasoningEffort ==
                            _controlModel?.defaultReasoningEffort;
                        return _ReasoningChoiceChip(
                          label: _reasoningEffortLabel(option.reasoningEffort),
                          selected: selected,
                          isDefault: isDefault,
                          onTap: () {
                            setState(() {
                              _reasoningEffort = option.reasoningEffort;
                            });
                          },
                        );
                      }).toList(),
                    ),
                    if (reasoningDescription != null &&
                        reasoningDescription.trim().isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        reasoningDescription.trim(),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 18),
                  _SectionLabel(label: 'Speed'),
                  const SizedBox(height: 8),
                  _FastModeTile(
                    value: _fastMode,
                    enabled: _fastSupported,
                    onChanged: (value) => setState(() => _fastMode = value),
                  ),
                  const SizedBox(height: 18),
                  _PolicyAutopilotCard(
                    active:
                        _approval == ApprovalPolicy.never &&
                        _sandbox == SandboxMode.dangerFullAccess,
                    onTap: _applyAutopilot,
                  ),
                  const SizedBox(height: 22),
                  _SectionLabel(label: 'Approval policy'),
                  const SizedBox(height: 8),
                  for (final policy in ApprovalPolicy.values)
                    _PolicyRadioTile<ApprovalPolicy>(
                      value: policy,
                      groupValue: _approval,
                      title: policy.label,
                      subtitle: policy.description,
                      onSelected: (value) => setState(() => _approval = value),
                    ),
                  const SizedBox(height: 18),
                  _SectionLabel(label: 'Sandbox'),
                  const SizedBox(height: 8),
                  for (final sandbox in SandboxMode.values)
                    _PolicyRadioTile<SandboxMode>(
                      value: sandbox,
                      groupValue: _sandbox,
                      title: sandbox.label,
                      subtitle: sandbox.description,
                      danger: sandbox == SandboxMode.dangerFullAccess,
                      onSelected: (value) => setState(() => _sandbox = value),
                    ),
                  const SizedBox(height: 18),
                  _SectionLabel(label: 'Network & profile'),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _webSearch,
                    onChanged: _submitting
                        ? null
                        : (value) => setState(() => _webSearch = value),
                    title: const Text('Enable live web search'),
                    subtitle: Text(
                      'Starts the thread with Codex web search enabled.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _profileController,
                    decoration: const InputDecoration(
                      labelText: 'Profile override',
                      hintText: 'guardian',
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.danger,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
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
                          : const Icon(Icons.send_rounded),
                      label: const Text('Start session'),
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: context.colors.textSecondary,
        letterSpacing: 0.4,
      ),
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
  });

  final String value;
  final String subtitle;
  final bool loading;
  final String? error;
  final List<String> badges;
  final VoidCallback onTap;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.35,
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

class _ReasoningChoiceChip extends StatelessWidget {
  const _ReasoningChoiceChip({
    required this.label,
    required this.selected,
    required this.isDefault,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool isDefault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? colors.accentMuted.withValues(alpha: 0.55) : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? colors.accent : colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (isDefault) ...[
              const SizedBox(width: 8),
              const _InlineBadge(label: 'default'),
            ],
          ],
        ),
      ),
    );
  }
}

class _FastModeTile extends StatelessWidget {
  const _FastModeTile({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: value ? colors.accentMuted.withValues(alpha: 0.45) : null,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: value ? colors.accent : colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.bolt_rounded,
            size: 20,
            color: value ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fast mode',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled
                      ? 'Ask Codex for the fast service tier from session start.'
                      : 'Pick a model that advertises Fast mode to enable this.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.35,
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

class _PolicyAutopilotCard extends StatelessWidget {
  const _PolicyAutopilotCard({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: active ? colors.accentMuted : colors.surfaceMuted,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? colors.accent : colors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome_rounded, color: colors.accent, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Autopilot launch',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Approval = never and sandbox = full access. Use this only on hosts you trust.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (active)
              Icon(Icons.check_circle_rounded, color: colors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}

class _PolicyRadioTile<T> extends StatelessWidget {
  const _PolicyRadioTile({
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
  final bool danger;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = value == groupValue;
    final accent = danger ? colors.danger : colors.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => onSelected(value),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: selected ? colors.accentMuted.withValues(alpha: 0.55) : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? accent : colors.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 20,
                color: selected ? accent : colors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
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
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: colors.textSecondary,
          height: 1.35,
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
