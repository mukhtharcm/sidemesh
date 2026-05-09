part of 'session_screen.dart';

class SessionControlsSheet extends StatefulWidget {
  const SessionControlsSheet({
    super.key,
    required this.api,
    required this.host,
    required this.session,
    required this.runtimeModel,
    required this.runtimeModelProvider,
    required this.runtimeMode,
    required this.runtimeServiceTier,
    required this.runtimeReasoningEffort,
    required this.runtimeApproval,
    required this.runtimeSandbox,
    required this.runtimeNetworkAccess,
    required this.policyStore,
    required this.turnConfigStore,
  });

  final ApiClient api;
  final HostProfile host;
  final SessionSummary session;
  final String? runtimeModel;
  final String? runtimeModelProvider;
  final String? runtimeMode;
  final String? runtimeServiceTier;
  final String? runtimeReasoningEffort;
  final ApprovalPolicy? runtimeApproval;
  final SandboxMode? runtimeSandbox;
  final bool? runtimeNetworkAccess;
  final SessionPolicyStore policyStore;
  final SessionTurnConfigStore turnConfigStore;

  @override
  State<SessionControlsSheet> createState() => _SessionControlsSheetState();
}

class _SessionControlsSheetState extends State<SessionControlsSheet> {
  late SessionPolicy _policy;
  late SessionTurnConfig _turnConfig;
  List<ModelCatalogEntry> _models = const <ModelCatalogEntry>[];
  bool _loadingModels = true;
  bool _loadingNode = false;
  String? _modelsError;
  NodeInfo? _nodeInfo;

  @override
  void initState() {
    super.initState();
    _policy = widget.policyStore.policyFor(widget.host, widget.session.id);
    _turnConfig = widget.turnConfigStore.configFor(
      widget.host,
      widget.session.id,
    );
    unawaited(_loadNodeInfo());
    unawaited(_loadModels());
  }

  String get _providerKind => widget.session.provider ?? '';

  String get _providerName {
    final node = _nodeInfo;
    if (node == null) return 'agent';
    final summary = node.providerSummary(_providerKind);
    if (summary.displayName.isNotEmpty) {
      return summary.displayName;
    }
    return node.providerDisplayName;
  }

  bool get _supportsModels => _supports('configuration', 'models');

  bool get _supportsModelOverride => _supports('runtimeControls', 'model');

  bool get _supportsMode => _supports('runtimeControls', 'mode');

  bool get _supportsReasoningEffort =>
      _supports('runtimeControls', 'reasoningEffort');

  bool get _supportsFastMode => _supports('runtimeControls', 'fastMode');

  bool get _supportsApprovalPolicy =>
      _supports('runtimeControls', 'approvalPolicy');

  bool get _supportsSandboxMode => _supports('runtimeControls', 'sandboxMode');

  bool get _supportsNetworkAccess =>
      _supports('runtimeControls', 'networkAccess');

  bool _supports(String section, String feature) {
    final node = _nodeInfo;
    if (node == null) return true;
    return node
        .capabilitiesForProvider(_providerKind)
        .supports(section, feature);
  }

  ProviderDefinitionSummary get _providerSummary {
    final node = _nodeInfo;
    if (node == null) {
      return ProviderDefinitionSummary.empty;
    }
    return node.providerSummary(_providerKind);
  }

  List<ApprovalPolicy> get _approvalOptions {
    final supported = _providerSummary.supportedApprovalPolicies;
    if (supported.isEmpty) {
      return ApprovalPolicy.values;
    }
    final options = ApprovalPolicy.values
        .where((policy) => supported.contains(policy.wire))
        .toList(growable: false);
    return options.isEmpty ? ApprovalPolicy.values : options;
  }

  ApprovalPolicy get _effectiveApproval =>
      _resolvedApprovalPolicy(_policy.approval ?? widget.runtimeApproval);

  SandboxMode get _effectiveSandbox =>
      _policy.sandbox ?? widget.runtimeSandbox ?? SandboxMode.workspaceWrite;

  bool get _effectiveNetworkOn {
    if (_effectiveSandbox == SandboxMode.dangerFullAccess) return true;
    return _policy.networkAccess ?? widget.runtimeNetworkAccess ?? false;
  }

  bool get _networkToggleDisabled =>
      _effectiveSandbox == SandboxMode.dangerFullAccess;

  bool get _isAutopilot =>
      _effectiveApproval == ApprovalPolicy.never &&
      _effectiveSandbox == SandboxMode.dangerFullAccess;

  ApprovalPolicy _resolvedApprovalPolicy(ApprovalPolicy? value) {
    if (_approvalOptions.contains(value)) {
      return value!;
    }
    return _approvalOptions.isEmpty
        ? ApprovalPolicy.untrusted
        : _approvalOptions.first;
  }

  String? get _effectiveModelValue {
    final local = _trimmedOrNull(_turnConfig.model);
    if (local != null) {
      return local;
    }
    final runtime = _trimmedOrNull(widget.runtimeModel);
    if (runtime != null) {
      return runtime;
    }
    return _defaultModelEntry?.model;
  }

  String? get _effectiveMode {
    final local = _trimmedOrNull(_turnConfig.mode);
    if (local != null) {
      return local;
    }
    return _trimmedOrNull(widget.runtimeMode);
  }

  ModelCatalogEntry? get _defaultModelEntry {
    for (final model in _models) {
      if (model.isDefault) {
        return model;
      }
    }
    return _models.isEmpty ? null : _models.first;
  }

  ModelCatalogEntry? get _selectedModelEntry =>
      _findModelByName(_effectiveModelValue);

  bool get _selectedModelIsAuto => _selectedModelEntry?.isAutoModel ?? false;

  String get _effectiveModelLabel {
    final selected = _selectedModelEntry;
    if (selected != null) {
      return selected.displayName;
    }
    return _effectiveModelValue ?? 'Use provider default';
  }

  String get _effectiveModelDescription {
    if (_loadingModels) {
      final provider = _runtimeModelProvider;
      if (provider != null) {
        return 'Loading models from this session\'s $provider provider.';
      }
      return 'Loading the available models from this host.';
    }
    if (_modelsError != null) {
      return _modelsError!;
    }
    final selected = _selectedModelEntry;
    if (selected != null && selected.description.trim().isNotEmpty) {
      return selected.description.trim();
    }
    final provider = _runtimeModelProvider;
    if (provider != null) {
      return 'Use the current $provider provider for new turns.';
    }
    return 'Use the host default model for new turns.';
  }

  String? get _runtimeModelProvider {
    final provider = _trimmedOrNull(widget.runtimeModelProvider);
    if (provider == null || provider == 'openai') {
      return null;
    }
    return provider;
  }

  String? get _effectiveReasoningEffort {
    final selected = _selectedModelEntry;
    if (selected != null && selected.isAutoModel) {
      return selected.defaultReasoningEffort;
    }
    final local = _trimmedOrNull(_turnConfig.reasoningEffort);
    if (local != null) {
      return local;
    }
    final runtime = _trimmedOrNull(widget.runtimeReasoningEffort);
    if (runtime != null) {
      return runtime;
    }
    return selected?.defaultReasoningEffort;
  }

  List<ModelReasoningEffortOption> get _supportedReasoningOptions {
    final selected = _selectedModelEntry;
    if (selected != null && selected.supportedReasoningEfforts.isNotEmpty) {
      return selected.supportedReasoningEfforts;
    }
    final effective = _effectiveReasoningEffort;
    if (effective == null) {
      return const <ModelReasoningEffortOption>[];
    }
    return <ModelReasoningEffortOption>[
      ModelReasoningEffortOption(
        reasoningEffort: effective,
        description: 'Current thread reasoning effort.',
      ),
    ];
  }

  bool get _selectedModelSupportsFast {
    if (!_supportsFastMode) return false;
    final selected = _selectedModelEntry;
    if (selected != null) {
      return selected.supportsFastMode;
    }
    return widget.runtimeServiceTier == 'fast';
  }

  bool get _effectiveFastMode {
    final override = _turnConfig.fastMode;
    if (override != null) {
      return override;
    }
    return widget.runtimeServiceTier == 'fast';
  }

  bool get _showFastSection =>
      _supportsFastMode &&
      (_selectedModelSupportsFast || widget.runtimeServiceTier == 'fast');

  Future<void> _loadNodeInfo() async {
    if (_loadingNode) return;
    setState(() {
      _loadingNode = true;
    });

    try {
      final node = await widget.api.fetchNode(widget.host);
      if (!mounted) return;
      setState(() {
        _nodeInfo = node;
        _loadingNode = false;
        _coerceForProviderCapabilities();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingNode = false;
      });
    }
  }

  void _coerceForProviderCapabilities() {
    var nextPolicy = _policy;
    if (!_supportsApprovalPolicy) {
      nextPolicy = nextPolicy.copyWith(approval: null);
    } else if (nextPolicy.approval != null &&
        !_approvalOptions.contains(nextPolicy.approval)) {
      nextPolicy = nextPolicy.copyWith(approval: null);
    }
    if (!_supportsSandboxMode) {
      nextPolicy = nextPolicy.copyWith(sandbox: null);
    }
    if (!_supportsNetworkAccess) {
      nextPolicy = nextPolicy.copyWith(networkAccess: null);
    }

    var nextConfig = _turnConfig;
    if (!_supportsModelOverride || !_supportsModels) {
      nextConfig = nextConfig.copyWith(model: null);
      _models = const <ModelCatalogEntry>[];
      _modelsError = null;
      _loadingModels = false;
    }
    if (!_supportsReasoningEffort) {
      nextConfig = nextConfig.copyWith(reasoningEffort: null);
    }
    if (!_supportsMode) {
      nextConfig = nextConfig.copyWith(mode: null);
    }
    if (!_supportsFastMode) {
      nextConfig = nextConfig.copyWith(fastMode: null);
    }

    _policy = nextPolicy;
    _turnConfig = nextConfig;
  }

  Future<void> _loadModels() async {
    if (!_supportsModels || !_supportsModelOverride) {
      setState(() {
        _models = const <ModelCatalogEntry>[];
        _loadingModels = false;
        _modelsError = null;
      });
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });

    try {
      final models = await widget.api.fetchModels(
        widget.host,
        cwd: widget.session.cwd,
        agentProvider: widget.session.provider,
        provider: _runtimeModelProvider,
      );
      models.sort(_compareModelEntries);
      if (!mounted) {
        return;
      }
      if (!_supportsModels || !_supportsModelOverride) {
        setState(() {
          _models = const <ModelCatalogEntry>[];
          _loadingModels = false;
          _modelsError = null;
        });
        return;
      }
      setState(() {
        _models = models;
        _loadingModels = false;
        _modelsError = models.isEmpty
            ? _runtimeModelProvider == null
                  ? 'This provider did not return any models for this host.'
                  : 'No models returned for provider $_runtimeModelProvider.'
            : null;
      });
      _coerceTurnConfigForSelectedModel();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingModels = false;
        _modelsError = friendlyError(error);
      });
    }
  }

  void _coerceTurnConfigForSelectedModel() {
    final selected = _selectedModelEntry;
    if (selected == null) {
      return;
    }

    var next = _turnConfig;
    if (selected.isAutoModel && _trimmedOrNull(next.reasoningEffort) != null) {
      next = next.copyWith(reasoningEffort: null);
    } else if (!selected.isAutoModel) {
      final supported = selected.supportedReasoningEfforts
          .map((option) => option.reasoningEffort)
          .toSet();
      final reasoning = _trimmedOrNull(next.reasoningEffort);
      if (reasoning != null && !supported.contains(reasoning)) {
        next = next.copyWith(reasoningEffort: selected.defaultReasoningEffort);
      }
    }

    if (!selected.supportsFastMode && next.fastMode == true) {
      next = next.copyWith(fastMode: false);
    }

    if (!_sameTurnConfig(next, _turnConfig)) {
      setState(() => _turnConfig = next);
    }
  }

  Future<void> _chooseModel() async {
    if (_loadingModels) {
      return;
    }
    if (_models.isEmpty) {
      await _loadModels();
      if (!mounted || _models.isEmpty) {
        return;
      }
    }

    final selected = await showModalBottomSheet<ModelCatalogEntry>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => _ModelPickerSheet(
        models: _models,
        currentModel: _effectiveModelValue,
        providerName: _runtimeModelProvider,
      ),
    );
    if (!mounted || selected == null) {
      return;
    }

    _applySelectedModel(selected);
  }

  void _applySelectedModel(ModelCatalogEntry selected) {
    final runtimeModel = _trimmedOrNull(widget.runtimeModel);
    final currentReasoning = _trimmedOrNull(_effectiveReasoningEffort);
    final supported = selected.supportedReasoningEfforts
        .map((option) => option.reasoningEffort)
        .toSet();

    String? nextReasoning;
    if (!selected.isAutoModel) {
      if (currentReasoning != null && supported.contains(currentReasoning)) {
        nextReasoning = currentReasoning;
      } else {
        nextReasoning = selected.defaultReasoningEffort;
      }
    }

    bool? nextFast = _turnConfig.fastMode;
    if (!selected.supportsFastMode && _effectiveFastMode) {
      nextFast = false;
    }

    final nextConfig = SessionTurnConfig(
      model: runtimeModel == selected.model ? null : selected.model,
      reasoningEffort: nextReasoning,
      fastMode: nextFast,
    );

    setState(() {
      _turnConfig = _normalisedTurnConfig(nextConfig, selectedModel: selected);
    });
  }

  Future<void> _save() async {
    final savedPolicy = SessionPolicy(
      approval: _supportsApprovalPolicy ? _policy.approval : null,
      sandbox: _supportsSandboxMode ? _policy.sandbox : null,
      networkAccess: _supportsNetworkAccess ? _policy.networkAccess : null,
    );
    final savedTurnConfig = _normalisedTurnConfig(
      SessionTurnConfig(
        model: _supportsModelOverride ? _turnConfig.model : null,
        mode: _supportsMode ? _turnConfig.mode : null,
        reasoningEffort: _supportsReasoningEffort
            ? _turnConfig.reasoningEffort
            : null,
        fastMode: _supportsFastMode ? _turnConfig.fastMode : null,
      ),
    );
    await widget.policyStore.setPolicy(
      widget.host,
      widget.session.id,
      savedPolicy,
    );
    await widget.turnConfigStore.setConfig(
      widget.host,
      widget.session.id,
      savedTurnConfig,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    showAppSnackBar(
      context,
      savedPolicy.isEmpty && savedTurnConfig.isEmpty
          ? 'Session will use default controls on your next fresh turn.'
          : 'Applied on your next fresh turn.',
    );
  }

  void _reset() {
    setState(() {
      _policy = SessionPolicy.factoryDefaults;
      _turnConfig = _factoryTurnConfig();
    });
  }

  void _applyAutopilot() {
    setState(() {
      _policy = _policy.copyWith(
        approval:
            _supportsApprovalPolicy &&
                _approvalOptions.contains(ApprovalPolicy.never)
            ? ApprovalPolicy.never
            : null,
        sandbox: _supportsSandboxMode ? SandboxMode.dangerFullAccess : null,
        networkAccess: _supportsNetworkAccess ? true : null,
      );
    });
  }

  SessionTurnConfig _factoryTurnConfig() {
    if (!_supportsModels || !_supportsModelOverride) {
      return const SessionTurnConfig();
    }
    final defaultModel = _defaultModelEntry;
    if (defaultModel == null) {
      return const SessionTurnConfig(fastMode: false);
    }
    return SessionTurnConfig(
      model: defaultModel.model,
      mode: null,
      reasoningEffort: defaultModel.isAutoModel
          ? null
          : defaultModel.defaultReasoningEffort,
      fastMode: false,
    );
  }

  SessionTurnConfig _normalisedTurnConfig(
    SessionTurnConfig config, {
    ModelCatalogEntry? selectedModel,
  }) {
    if (!_supportsModels || !_supportsModelOverride) {
      return SessionTurnConfig(mode: _supportsMode ? config.mode : null);
    }
    final resolvedModel = _trimmedOrNull(config.model);
    final model =
        selectedModel ?? _findModelByName(resolvedModel ?? widget.runtimeModel);
    final runtimeMode = _trimmedOrNull(widget.runtimeMode);
    var nextModel = resolvedModel;
    var nextMode = _trimmedOrNull(config.mode);
    var nextReasoning = _trimmedOrNull(config.reasoningEffort);
    var nextFast = config.fastMode;

    final runtimeModel = _trimmedOrNull(widget.runtimeModel);
    final runtimeReasoning = _trimmedOrNull(widget.runtimeReasoningEffort);
    final runtimeFast = widget.runtimeServiceTier == 'fast';

    if (runtimeModel != null && nextModel == runtimeModel) {
      nextModel = null;
    }
    if (!_supportsMode) {
      nextMode = null;
    } else if (runtimeMode != null && nextMode == runtimeMode) {
      nextMode = null;
    }
    if (!_supportsReasoningEffort || (model != null && model.isAutoModel)) {
      nextReasoning = null;
    }
    if (!_supportsFastMode) {
      nextFast = null;
    } else if (model != null && !model.supportsFastMode) {
      nextFast = false;
    }
    if (nextModel == null &&
        runtimeReasoning != null &&
        nextReasoning == runtimeReasoning) {
      nextReasoning = null;
    }
    if (nextModel == null && nextFast != null && nextFast == runtimeFast) {
      nextFast = null;
    }

    return SessionTurnConfig(
      model: nextModel,
      mode: nextMode,
      reasoningEffort: nextReasoning,
      fastMode: nextFast,
    );
  }

  ModelCatalogEntry? _findModelByName(String? value) {
    final modelId = _trimmedOrNull(value);
    if (modelId == null) {
      return _defaultModelEntry;
    }
    for (final model in _models) {
      if (model.model == modelId) {
        return model;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final selectedModel = _selectedModelEntry;
    final effectiveReasoning = _effectiveReasoningEffort;
    String? reasoningDescription;
    for (final option in _supportedReasoningOptions) {
      if (option.reasoningEffort == effectiveReasoning) {
        reasoningDescription = option.description;
        break;
      }
    }
    final showModelControls = _supportsModels && _supportsModelOverride;
    final showModeControls = _supportsMode;
    final showReasoningControls = showModelControls && _supportsReasoningEffort;
    final showAutopilot =
        _supportsApprovalPolicy &&
        _approvalOptions.contains(ApprovalPolicy.never) &&
        _supportsSandboxMode &&
        _supportsNetworkAccess;
    final showPolicyControls =
        _supportsApprovalPolicy ||
        _supportsSandboxMode ||
        _supportsNetworkAccess;
    final showAnyControls =
        showModeControls ||
        showModelControls ||
        showReasoningControls ||
        _showFastSection ||
        showPolicyControls;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.tune_rounded, color: colors.accent, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Session controls',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: AppWeights.title,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Change how the agent handles the model, thinking effort, Fast mode, approvals, file access and network for this session. Applied on your next fresh turn. If the agent is already responding, these changes wait until the current turn finishes.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
              if (!showAnyControls) ...[
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colors.surfaceMuted,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: colors.border),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: colors.textSecondary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'No adjustable controls',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$_providerName does not advertise runtime controls for existing sessions.',
                              style: theme.textTheme.bodySmall?.copyWith(
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
              ] else ...[
                if (showModeControls) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Session mode',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.textSecondary,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <String?>[null, ...kSessionModes].map((mode) {
                      final selected = mode == _effectiveMode;
                      final fromRuntime =
                          mode != null &&
                          _turnConfig.mode == null &&
                          widget.runtimeMode == mode;
                      return _ReasoningChoiceChip(
                        label: _sessionModeChoiceLabel(mode),
                        selected: selected,
                        isDefault: mode == null || fromRuntime,
                        defaultLabel: mode == null ? 'inherit' : 'current',
                        onTap: () {
                          setState(() {
                            _turnConfig = _normalisedTurnConfig(
                              _turnConfig.copyWith(mode: mode),
                            );
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _sessionModeDescription(
                      _effectiveMode,
                      providerName: _providerName,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      height: 1.35,
                    ),
                  ),
                ],
                if (showModelControls) ...[
                  const SizedBox(height: 20),
                  Text(
                    showReasoningControls ? 'Model & thinking' : 'Model',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.textSecondary,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _ModelSelectionCard(
                    title: 'Model',
                    value: _effectiveModelLabel,
                    subtitle: _effectiveModelDescription,
                    loading: _loadingModels,
                    error: _modelsError,
                    currentValue: _turnConfig.model != null
                        ? widget.runtimeModel
                        : null,
                    badges: <String>[
                      ?_runtimeModelProvider,
                      if (selectedModel?.isAutoModel ?? false) 'auto',
                      if (selectedModel?.isDefault ?? false) 'default',
                      if (_turnConfig.model != null) 'next turn',
                    ],
                    onTap: _chooseModel,
                    onRetry: () {
                      unawaited(_loadModels());
                    },
                  ),
                ],
                if (showReasoningControls) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Reasoning effort',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.textSecondary,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_loadingModels && _models.isEmpty)
                    const LinearProgressIndicator(minHeight: 3)
                  else if (_selectedModelIsAuto)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.surfaceMuted,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(
                        'Auto models choose the thinking effort themselves. The agent will use ${_reasoningEffortLabel(effectiveReasoning ?? selectedModel?.defaultReasoningEffort ?? 'medium')}.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    )
                  else if (_supportedReasoningOptions.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colors.surfaceMuted,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colors.border),
                      ),
                      child: Text(
                        'This model does not expose adjustable thinking effort.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    )
                  else ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _supportedReasoningOptions.map((option) {
                        final isDefault =
                            selectedModel != null &&
                            option.reasoningEffort ==
                                selectedModel.defaultReasoningEffort;
                        final selected =
                            option.reasoningEffort == effectiveReasoning;
                        return _ReasoningChoiceChip(
                          label: _reasoningEffortLabel(option.reasoningEffort),
                          selected: selected,
                          isDefault: isDefault,
                          onTap: () {
                            setState(() {
                              _turnConfig = _normalisedTurnConfig(
                                _turnConfig.copyWith(
                                  reasoningEffort: option.reasoningEffort,
                                ),
                              );
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
                ],
                if (_showFastSection) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Speed',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: colors.textSecondary,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _FastModeTile(
                    value: _effectiveFastMode,
                    enabled: _selectedModelSupportsFast,
                    onChanged: (value) {
                      setState(() {
                        _turnConfig = _normalisedTurnConfig(
                          _turnConfig.copyWith(fastMode: value),
                        );
                      });
                    },
                  ),
                ],
                if (showPolicyControls) ...[
                  const SizedBox(height: 18),
                  if (showAutopilot) ...[
                    _PolicyAutopilotCard(
                      active: _isAutopilot,
                      onTap: _applyAutopilot,
                      colors: colors,
                    ),
                    const SizedBox(height: 22),
                  ],
                  if (_supportsApprovalPolicy) ...[
                    Text(
                      'Approval policy',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.textSecondary,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final policy in _approvalOptions)
                      _PolicyRadioTile<ApprovalPolicy>(
                        value: policy,
                        groupValue: _effectiveApproval,
                        title: policy.label,
                        subtitle: policy.description,
                        fromRuntime:
                            _policy.approval == null &&
                            widget.runtimeApproval == policy,
                        onSelected: (value) {
                          setState(() {
                            _policy = _policy.copyWith(approval: value);
                          });
                        },
                      ),
                  ],
                  if (_supportsApprovalPolicy && _supportsSandboxMode)
                    const SizedBox(height: 18),
                  if (_supportsSandboxMode) ...[
                    Text(
                      'Sandbox',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.textSecondary,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final sandbox in SandboxMode.values)
                      _PolicyRadioTile<SandboxMode>(
                        value: sandbox,
                        groupValue: _effectiveSandbox,
                        title: sandbox.label,
                        subtitle: sandbox.description,
                        fromRuntime:
                            _policy.sandbox == null &&
                            widget.runtimeSandbox == sandbox,
                        danger: sandbox == SandboxMode.dangerFullAccess,
                        onSelected: (value) {
                          setState(() {
                            _policy = _policy.copyWith(sandbox: value);
                          });
                        },
                      ),
                  ],
                  if ((_supportsApprovalPolicy || _supportsSandboxMode) &&
                      _supportsNetworkAccess)
                    const SizedBox(height: 18),
                  if (_supportsNetworkAccess) ...[
                    Text(
                      'Network',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.textSecondary,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _PolicyNetworkTile(
                      value: _effectiveNetworkOn,
                      disabled: _networkToggleDisabled,
                      subtitle: _networkToggleDisabled
                          ? 'Full access already grants network. Toggle locked.'
                          : (_effectiveSandbox == SandboxMode.workspaceWrite ||
                                _effectiveSandbox == SandboxMode.readOnly)
                          ? 'Allow outbound network for tools like gh, curl, pip. Off by default for read-only / workspace-write.'
                          : 'Allow outbound network.',
                      onChanged: (value) {
                        setState(() {
                          _policy = _policy.copyWith(networkAccess: value);
                        });
                      },
                    ),
                  ],
                ],
              ],
              const SizedBox(height: 22),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('Reset to defaults'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelSelectionCard extends StatelessWidget {
  const _ModelSelectionCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.loading,
    required this.error,
    required this.currentValue,
    required this.badges,
    required this.onTap,
    required this.onRetry,
  });

  final String title;
  final String value;
  final String subtitle;
  final bool loading;
  final String? error;
  final String? currentValue;
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
                    title,
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
            if ((currentValue ?? '').trim().isNotEmpty &&
                currentValue!.trim() != value.trim()) ...[
              const SizedBox(height: 8),
              Text(
                'Current thread: ${currentValue!.trim()}',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
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
    this.defaultLabel = 'default',
  });

  final String label;
  final bool selected;
  final bool isDefault;
  final VoidCallback onTap;
  final String defaultLabel;

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
              _InlineBadge(label: defaultLabel),
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
                      ? 'Ask for the fast service tier on your next fresh turn.'
                      : 'This model does not advertise Fast mode.',
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

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.models,
    required this.currentModel,
    required this.providerName,
  });

  final List<ModelCatalogEntry> models;
  final String? currentModel;
  final String? providerName;

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
          if (query.isEmpty) {
            return true;
          }
          final haystack = [
            model.displayName,
            model.model,
            model.description,
          ].join('\n').toLowerCase();
          return matchesSearchQuery(haystack, query);
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
              widget.providerName == null
                  ? 'Pick the model for your next fresh turn. Auto models stay simple; specific models let you adjust thinking effort.'
                  : 'Pick the model for your next fresh turn on this session\'s ${widget.providerName} provider.',
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
              child: filtered.isEmpty
                  ? Center(
                      child: Text(
                        'No models match that search.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final model = filtered[index];
                        final isCurrent =
                            model.model == _trimmedOrNull(widget.currentModel);
                        return InkWell(
                          onTap: () => Navigator.of(context).pop(model),
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: colors.surfaceMuted,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isCurrent
                                    ? colors.accent
                                    : colors.border,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        model.displayName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    ),
                                    if (isCurrent)
                                      const _InlineBadge(label: 'current'),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  model.model,
                                  style: monoStyle(
                                    color: colors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (widget.providerName != null)
                                      _InlineBadge(label: widget.providerName!),
                                    if (model.isAutoModel)
                                      const _InlineBadge(label: 'auto'),
                                    if (model.isDefault)
                                      const _InlineBadge(label: 'default'),
                                    if (model.supportsFastMode)
                                      const _InlineBadge(label: 'fast'),
                                    ...model.supportedReasoningEfforts
                                        .take(3)
                                        .map(
                                          (option) => _InlineBadge(
                                            label: _reasoningEffortLabel(
                                              option.reasoningEffort,
                                            ),
                                          ),
                                        ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  model.description,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colors.textSecondary,
                                        height: 1.35,
                                      ),
                                ),
                              ],
                            ),
                          ),
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

class _PolicyAutopilotCard extends StatelessWidget {
  const _PolicyAutopilotCard({
    required this.active,
    required this.onTap,
    required this.colors,
  });

  final bool active;
  final VoidCallback onTap;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final border = active ? colors.accent : colors.border;
    final bg = active ? colors.accentMuted : colors.surfaceMuted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
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
                    'Autopilot — never ask again',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Approval = never · Sandbox = full access · Network = on. The agent runs without pausing for approvals and can hit the internet.',
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

class _PolicyNetworkTile extends StatelessWidget {
  const _PolicyNetworkTile({
    required this.value,
    required this.disabled,
    required this.subtitle,
    required this.onChanged,
  });

  final bool value;
  final bool disabled;
  final String subtitle;
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
            value ? Icons.public_rounded : Icons.public_off_rounded,
            size: 20,
            color: value ? colors.accent : colors.textSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Allow outbound network',
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
          Switch(value: value, onChanged: disabled ? null : onChanged),
        ],
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
    this.fromRuntime = false,
    this.danger = false,
  });

  final T value;
  final T groupValue;
  final String title;
  final String subtitle;
  final bool fromRuntime;
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: colors.textPrimary,
                                ),
                          ),
                        ),
                        if (fromRuntime)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors.surfaceMuted,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: colors.border),
                            ),
                            child: Text(
                              'current',
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    color: colors.textSecondary,
                                    letterSpacing: 0.4,
                                  ),
                            ),
                          ),
                      ],
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

int _compareModelEntries(ModelCatalogEntry left, ModelCatalogEntry right) {
  final rank = _modelSortRank(left).compareTo(_modelSortRank(right));
  if (rank != 0) {
    return rank;
  }
  if (left.isDefault != right.isDefault) {
    return left.isDefault ? -1 : 1;
  }
  final leftName = '${left.displayName}\n${left.model}'.toLowerCase();
  final rightName = '${right.displayName}\n${right.model}'.toLowerCase();
  return leftName.compareTo(rightName);
}

int _modelSortRank(ModelCatalogEntry model) {
  final sortOrder = model.sortOrder;
  if (sortOrder != null) return sortOrder;
  return model.isProfileModel ? 4000 : 10000;
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

String _sessionModeChoiceLabel(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Inherit current';
  }
  return sessionModeLabel(value);
}

String _sessionModeDescription(String? value, {required String providerName}) {
  return switch (value) {
    null =>
      'Leave mode alone and keep the current $providerName session behavior.',
    'interactive' =>
      'Interactive keeps the agent conversational and approval-oriented.',
    'plan' =>
      'Plan focuses on outlining or analyzing before it starts making changes.',
    'autopilot' =>
      'Autopilot lets the provider run with its most self-directed execution mode.',
    _ =>
      '$providerName will switch to ${sessionModeLabel(value)} mode on the next fresh turn.',
  };
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

bool _sameTurnConfig(SessionTurnConfig left, SessionTurnConfig right) {
  return left.model == right.model &&
      left.mode == right.mode &&
      left.reasoningEffort == right.reasoningEffort &&
      left.fastMode == right.fastMode;
}
