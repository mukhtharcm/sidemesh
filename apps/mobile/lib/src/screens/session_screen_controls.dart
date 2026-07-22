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
    this.runtimeAccessMode,
    required this.policyStore,
    required this.turnConfigStore,
    this.onClose,
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
  final String? runtimeAccessMode;
  final SessionPolicyStore policyStore;
  final SessionTurnConfigStore turnConfigStore;
  final VoidCallback? onClose;

  @override
  State<SessionControlsSheet> createState() => _SessionControlsSheetState();
}

class _SessionControlsSheetState extends State<SessionControlsSheet> {
  late SessionPolicy _policy;
  late SessionTurnConfig _turnConfig;
  List<ModelCatalogEntry> _models = const <ModelCatalogEntry>[];
  List<ProviderModeSummary> _providerModes = const <ProviderModeSummary>[];
  bool _loadingModels = true;
  bool _loadingProviderModes = false;
  bool _loadingNode = false;
  String? _modelsError;
  ProviderAccessModeCatalog? _accessModeCatalog;
  bool _loadingAccessModes = false;
  String? _accessModesError;
  NodeInfo? _nodeInfo;
  bool _showingModelPicker = false;

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
    unawaited(_loadProviderModes());
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

  List<ProviderModeSummary> get _availableModeChoices {
    final result = <ProviderModeSummary>[..._providerModes];
    final currentMode = _trimmedOrNull(_effectiveMode);
    if (currentMode != null &&
        !result.any((candidate) => candidate.id == currentMode)) {
      result.add(
        ProviderModeSummary(
          id: currentMode,
          label: sessionModeLabel(currentMode),
        ),
      );
    }
    return result;
  }

  bool get _supportsReasoningEffort =>
      _supports('runtimeControls', 'reasoningEffort');

  bool get _supportsFastMode => _supports('runtimeControls', 'fastMode');

  bool get _supportsApprovalPolicy =>
      _supports('runtimeControls', 'approvalPolicy');

  bool get _supportsSandboxMode => _supports('runtimeControls', 'sandboxMode');

  bool get _supportsNetworkAccess =>
      _supports('runtimeControls', 'networkAccess');

  bool get _supportsAccessModes =>
      _nodeInfo != null &&
      _supports('configuration', 'accessModes') &&
      _supports('runtimeControls', 'accessMode');

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

  bool get _effectiveNetworkAccess {
    if (_effectiveSandbox == SandboxMode.dangerFullAccess) return true;
    return _policy.networkAccess ?? widget.runtimeNetworkAccess ?? false;
  }

  ApprovalPolicy _resolvedApprovalPolicy(ApprovalPolicy? value) {
    if (_approvalOptions.contains(value)) return value!;
    return _approvalOptions.first;
  }

  String? get _effectiveAccessMode =>
      _trimmedOrNull(_policy.accessMode) ??
      _trimmedOrNull(widget.runtimeAccessMode) ??
      _trimmedOrNull(_accessModeCatalog?.defaultMode);

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
    return _effectiveModelValue ?? 'Use session default';
  }

  String get _effectiveModelDescription {
    if (_loadingModels) {
      final provider = _runtimeModelProvider;
      if (provider != null) {
        return 'Loading models for this session…';
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
      return 'Use the current model source for new turns.';
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
      if (_supportsMode) {
        unawaited(_loadProviderModes(force: true));
      }
      if (_supportsAccessModes) {
        unawaited(_loadAccessModes());
      }
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
    if (!_supportsAccessModes) {
      nextPolicy = nextPolicy.copyWith(accessMode: null);
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
      _providerModes = const <ProviderModeSummary>[];
      _loadingProviderModes = false;
    }
    if (!_supportsFastMode) {
      nextConfig = nextConfig.copyWith(fastMode: null);
    }

    _policy = nextPolicy;
    _turnConfig = nextConfig;
  }

  Future<void> _loadAccessModes() async {
    if (!_supportsAccessModes || _loadingAccessModes) return;
    setState(() {
      _loadingAccessModes = true;
      _accessModesError = null;
    });
    try {
      final catalog = await widget.api.fetchAccessModes(
        widget.host,
        cwd: widget.session.cwd,
        agentProvider: widget.session.provider,
      );
      if (!mounted) return;
      setState(() {
        _accessModeCatalog = catalog;
        _loadingAccessModes = false;
        final selectedPolicyMode = providerAccessModeById(
          catalog,
          _policy.accessMode,
        );
        if (_policy.accessMode != null &&
            !(selectedPolicyMode?.enabled ?? false)) {
          _policy = _policy.copyWith(accessMode: null);
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingAccessModes = false;
        _accessModesError = friendlyError(error);
      });
    }
  }

  Future<void> _loadProviderModes({bool force = false}) async {
    if (!_supportsMode) {
      setState(() {
        _providerModes = const <ProviderModeSummary>[];
        _loadingProviderModes = false;
      });
      return;
    }
    if (_loadingProviderModes && !force) {
      return;
    }
    setState(() {
      _loadingProviderModes = true;
    });

    try {
      final catalog = await widget.api.fetchModes(
        widget.host,
        cwd: widget.session.cwd,
        agentProvider: widget.session.provider,
      );
      if (!mounted) return;
      setState(() {
        _providerModes = catalog.modes;
        _loadingProviderModes = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingProviderModes = false;
        if (_shouldUseModeFallback(error)) {
          _providerModes = kDefaultProviderModes;
        } else {
          _providerModes = const <ProviderModeSummary>[];
        }
      });
    }
  }

  bool _shouldUseModeFallback(Object error) =>
      error is ApiException &&
      (error.statusCode == 404 || error.statusCode == 501);

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
      final models = [
        ...await widget.api.fetchModels(
          widget.host,
          cwd: widget.session.cwd,
          agentProvider: widget.session.provider,
          provider: _runtimeModelProvider,
        ),
      ];
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
                  ? 'No models are available from this host right now.'
                  : 'No models were returned for this session.'
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

    setState(() => _showingModelPicker = true);
  }

  void _close() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
      return;
    }
    Navigator.of(context).maybePop();
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
      approval: _supportsAccessModes
          ? null
          : (_supportsApprovalPolicy && _policy.approval != null
                ? _effectiveApproval
                : null),
      sandbox: _supportsAccessModes
          ? null
          : (_supportsSandboxMode ? _policy.sandbox : null),
      networkAccess: _supportsAccessModes
          ? null
          : (_supportsNetworkAccess ? _policy.networkAccess : null),
      accessMode: _supportsAccessModes
          ? _trimmedOrNull(_policy.accessMode)
          : null,
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
    _close();
    showAppSnackBar(
      context,
      savedPolicy.isEmpty && savedTurnConfig.isEmpty
          ? 'This session will use the default settings on the next reply.'
          : 'Changes will apply on the next reply.',
    );
  }

  void _reset() {
    setState(() {
      _policy = _supportsAccessModes
          ? const SessionPolicy()
          : SessionPolicy.factoryDefaults;
      _turnConfig = _factoryTurnConfig();
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

  Widget _buildActions(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final reset = TextButton.icon(
          onPressed: _reset,
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text('Reset'),
        );
        final cancel = TextButton(
          onPressed: _close,
          child: const Text('Cancel'),
        );
        final apply = FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('Apply'),
        );
        if (constraints.maxWidth < 380) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              apply,
              const SizedBox(height: 4),
              Row(children: [reset, const Spacer(), cancel]),
            ],
          );
        }
        return Row(
          children: [
            reset,
            const Spacer(),
            cancel,
            const SizedBox(width: 8),
            apply,
          ],
        );
      },
    );
  }

  Widget _buildAccessModeControls(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final catalog = _accessModeCatalog;
    if (_loadingAccessModes && catalog == null) {
      return const MeshSelectionCardSkeleton(
        showIcon: false,
        badgeCount: 0,
        showCurrentValue: true,
      );
    }
    if (_accessModesError != null && catalog == null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              _accessModesError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          TextButton(onPressed: _loadAccessModes, child: const Text('Retry')),
        ],
      );
    }
    if (catalog == null || catalog.modes.isEmpty) {
      return Text(
        'No access modes are available for this session.',
        style: theme.textTheme.bodySmall?.copyWith(color: colors.textSecondary),
      );
    }
    return ProviderAccessModeChoices(
      modes: catalog.modes,
      selectedModeId: _effectiveAccessMode,
      onSelected: (mode) => unawaited(_selectAccessMode(mode)),
    );
  }

  Future<void> _selectAccessMode(ProviderAccessModeSummary mode) async {
    if (!mode.enabled) return;
    if (mode.id == _effectiveAccessMode) return;
    final confirmation = mode.confirmation;
    if (confirmation != null) {
      final confirmed = await showMeshConfirmDialog(
        context,
        icon: providerAccessModeIcon(mode.icon),
        title: confirmation.title,
        description: confirmation.description,
        confirmLabel: confirmation.confirmLabel,
        danger: confirmation.danger,
      );
      if (!mounted || !confirmed) return;
    }
    if (!mounted) return;
    setState(() {
      _policy = _policy.copyWith(
        approval: null,
        sandbox: null,
        networkAccess: null,
        accessMode: mode.id,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    if (_showingModelPicker) {
      final picker = _ModelPickerSheet(
        models: _models,
        currentModel: _effectiveModelValue,
        providerName: _runtimeModelProvider,
        embedded: true,
        onBack: () => setState(() => _showingModelPicker = false),
        onSelected: (model) {
          _applySelectedModel(model);
          setState(() => _showingModelPicker = false);
        },
      );
      return SafeArea(top: false, child: picker);
    }
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
    final showAccessControls = _supportsAccessModes;
    final showLegacyPolicyControls =
        _nodeInfo != null &&
        !showAccessControls &&
        (_supportsApprovalPolicy ||
            _supportsSandboxMode ||
            _supportsNetworkAccess);
    final showAnyControls =
        showModeControls ||
        showModelControls ||
        showReasoningControls ||
        _showFastSection ||
        showAccessControls ||
        showLegacyPolicyControls;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!showAnyControls) ...[
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
                        'Nothing to change here',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$_providerName does not offer session settings you can change after a run starts.',
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
            Text(
              'Mode',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.textSecondary,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  <String?>[
                    null,
                    ..._availableModeChoices.map((mode) => mode.id),
                  ].map((mode) {
                    final selected = mode == _effectiveMode;
                    final fromRuntime =
                        mode != null &&
                        _turnConfig.mode == null &&
                        widget.runtimeMode == mode;
                    return _ReasoningChoiceChip(
                      label: _sessionModeChoiceLabel(
                        mode,
                        _availableModeChoices,
                      ),
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
                modes: _availableModeChoices,
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
              showReasoningControls ? 'Model and thinking' : 'Model',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.textSecondary,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            _loadingModels && _models.isEmpty
                ? const MeshSelectionCardSkeleton(
                    showIcon: false,
                    badgeCount: 3,
                    showCurrentValue: true,
                  )
                : MeshSelectionCard(
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
              const MeshChipSkeletonWrap()
            else if (_selectedModelIsAuto)
              _InlineSettingNote(
                text:
                    'Auto models choose the thinking effort themselves. The agent will use ${_reasoningEffortLabel(effectiveReasoning ?? selectedModel?.defaultReasoningEffort ?? 'medium')}.',
              )
            else if (_supportedReasoningOptions.isEmpty)
              const _InlineSettingNote(
                text: 'This model does not expose adjustable thinking effort.',
              )
            else ...[
              _ReasoningEffortSlider(
                options: _supportedReasoningOptions,
                selectedEffort: effectiveReasoning,
                defaultEffort: selectedModel?.defaultReasoningEffort,
                onChanged: (effort) {
                  setState(() {
                    _turnConfig = _normalisedTurnConfig(
                      _turnConfig.copyWith(reasoningEffort: effort),
                    );
                  });
                },
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
          if (showAccessControls) ...[
            const SizedBox(height: 18),
            Text(
              'Access',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.textSecondary,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose how the provider should handle sensitive actions.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            _buildAccessModeControls(context),
          ],
          if (showLegacyPolicyControls) ...[
            const SizedBox(height: 18),
            LaunchOptionsForm(
              dense: true,
              value: LaunchOptionsValue(
                approval: _effectiveApproval,
                sandbox: _effectiveSandbox,
                networkAccess: _effectiveNetworkAccess,
              ),
              capabilities: LaunchOptionsCapabilities(
                supportsApprovalPolicy: _supportsApprovalPolicy,
                supportsSandboxMode: _supportsSandboxMode,
                supportsNetworkAccess:
                    _supportsNetworkAccess &&
                    _effectiveSandbox != SandboxMode.dangerFullAccess,
                approvalOptions: _approvalOptions,
              ),
              onApprovalChanged: (approval) {
                setState(() {
                  _policy = _policy.copyWith(approval: approval);
                });
              },
              onSandboxChanged: (sandbox) {
                setState(() {
                  _policy = _policy.copyWith(sandbox: sandbox);
                });
              },
              onNetworkAccessChanged: (networkAccess) {
                setState(() {
                  _policy = _policy.copyWith(networkAccess: networkAccess);
                });
              },
            ),
          ],
        ],
        const SizedBox(height: 22),
        _buildActions(context),
      ],
    );

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: content,
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
    return MeshSurface(
      onTap: onTap,
      selected: selected,
      tone: MeshSurfaceTone.muted,
      radius: AppRadii.control,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
            MeshInlineBadge(label: defaultLabel),
          ],
        ],
      ),
    );
  }
}

class _ReasoningEffortSlider extends StatelessWidget {
  const _ReasoningEffortSlider({
    required this.options,
    required this.selectedEffort,
    required this.defaultEffort,
    required this.onChanged,
  });

  final List<ModelReasoningEffortOption> options;
  final String? selectedEffort;
  final String? defaultEffort;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    var selectedIndex = options.indexWhere(
      (option) => option.reasoningEffort == selectedEffort,
    );
    if (selectedIndex < 0) {
      selectedIndex = options.indexWhere(
        (option) => option.reasoningEffort == defaultEffort,
      );
    }
    if (selectedIndex < 0) selectedIndex = 0;
    final selected = options[selectedIndex];
    final selectedLabel = _reasoningEffortLabel(selected.reasoningEffort);
    final isDefault = selected.reasoningEffort == defaultEffort;

    if (options.length == 1) {
      return Text(
        selectedLabel,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: colors.textPrimary,
          fontWeight: AppWeights.emphasis,
        ),
      );
    }

    return Semantics(
      label: 'Reasoning effort',
      value: selectedLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                selectedLabel,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.accent,
                  fontWeight: AppWeights.title,
                ),
              ),
              if (isDefault) ...[
                const SizedBox(width: 8),
                const MeshInlineBadge(label: 'default'),
              ],
            ],
          ),
          Slider(
            value: selectedIndex.toDouble(),
            min: 0,
            max: (options.length - 1).toDouble(),
            divisions: options.length - 1,
            label: selectedLabel,
            onChanged: (value) {
              final index = value.round().clamp(0, options.length - 1);
              onChanged(options[index].reasoningEffort);
            },
          ),
          Row(
            children: [
              Text(
                _reasoningEffortLabel(options.first.reasoningEffort),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
              const Spacer(),
              Text(
                _reasoningEffortLabel(options.last.reasoningEffort),
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ],
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
    return AppSettingsRow(
      icon: Icons.bolt_rounded,
      title: 'Fast mode',
      subtitle: enabled
          ? 'Prefer the faster service tier on the next reply.'
          : 'This model does not support Fast mode.',
      onTap: enabled ? () => onChanged(!value) : null,
      trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
  }
}

class _InlineSettingNote extends StatelessWidget {
  const _InlineSettingNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colors.textTertiary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
                height: 1.35,
              ),
            ),
          ),
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
    this.embedded = false,
    this.showEmbeddedHeader = true,
    this.onBack,
    this.onSelected,
  });

  final List<ModelCatalogEntry> models;
  final String? currentModel;
  final String? providerName;
  final bool embedded;
  final bool showEmbeddedHeader;
  final VoidCallback? onBack;
  final ValueChanged<ModelCatalogEntry>? onSelected;

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

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.embedded && widget.showEmbeddedHeader) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Tooltip(
                  message: 'Back to session controls',
                  child: TextButton.icon(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back_rounded, size: 18),
                    label: const Text('All controls'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Choose a model',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: AppWeights.title),
                      ),
                      Text(
                        'Changes apply to the next reply.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
        Padding(
          padding: widget.embedded
              ? const EdgeInsets.symmetric(horizontal: 16)
              : EdgeInsets.zero,
          child: TextField(
            controller: _queryController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Search models',
            ),
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
                  padding: widget.embedded
                      ? const EdgeInsets.fromLTRB(8, 0, 8, 24)
                      : EdgeInsets.zero,
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, indent: 56, color: colors.border),
                  itemBuilder: (context, index) {
                    final model = filtered[index];
                    final isCurrent =
                        model.model == _trimmedOrNull(widget.currentModel);
                    return AppChoiceRow(
                      title: model.displayName,
                      subtitle: model.description,
                      icon: Icons.memory_rounded,
                      selected: isCurrent,
                      onTap: () {
                        final onSelected = widget.onSelected;
                        if (onSelected != null) {
                          onSelected(model);
                        } else {
                          Navigator.of(context).pop(model);
                        }
                      },
                      footer: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            model.model,
                            style: monoStyle(
                              color: colors.textSecondary,
                              fontSize: 12,
                              fontWeight: AppWeights.body,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.sm,
                            children: [
                              if (widget.providerName != null)
                                MeshInlineBadge(label: widget.providerName!),
                              if (model.isAutoModel)
                                const MeshInlineBadge(label: 'auto'),
                              if (model.isDefault)
                                const MeshInlineBadge(label: 'default'),
                              if (model.supportsFastMode)
                                const MeshInlineBadge(label: 'fast'),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
    if (widget.embedded) {
      return content;
    }
    return MeshBottomSheetScaffold(
      icon: Icons.memory_rounded,
      title: 'Choose a model',
      description: widget.providerName == null
          ? 'Pick the model for the next reply. Auto models keep things simple.'
          : 'Pick the model for the next reply in this session.',
      maxWidth: 760,
      child: content,
    );
  }
}

class _ReasoningPickerSheet extends StatelessWidget {
  const _ReasoningPickerSheet({
    required this.options,
    required this.currentReasoning,
    required this.defaultReasoning,
    required this.modelLabel,
  });

  final List<ModelReasoningEffortOption> options;
  final String currentReasoning;
  final String defaultReasoning;
  final String modelLabel;

  @override
  Widget build(BuildContext context) {
    return MeshBottomSheetScaffold(
      icon: Icons.psychology_alt_rounded,
      title: 'Choose thinking level',
      description:
          'Set how much thinking the next reply should use with $modelLabel.',
      maxWidth: 520,
      maxHeightFactor: 0.72,
      child: ListView.separated(
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final option = options[index];
          final selected = option.reasoningEffort == currentReasoning;
          final isDefault = option.reasoningEffort == defaultReasoning;
          return AppChoiceRow(
            title: _reasoningEffortLabel(option.reasoningEffort),
            subtitle: option.description,
            icon: Icons.psychology_alt_rounded,
            selected: selected,
            onTap: () => Navigator.of(context).pop(option.reasoningEffort),
            trailing: !selected && isDefault
                ? const MeshInlineBadge(label: 'default')
                : null,
          );
        },
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

String _sessionModeChoiceLabel(
  String? value,
  Iterable<ProviderModeSummary> modes,
) {
  if (value == null || value.trim().isEmpty) {
    return 'Inherit current';
  }
  return providerModeLabel(value, modes);
}

String _sessionModeDescription(
  String? value, {
  required String providerName,
  required Iterable<ProviderModeSummary> modes,
}) {
  final summary = findProviderModeSummary(modes, value);
  if (summary?.description case final description?
      when description.trim().isNotEmpty) {
    return description.trim();
  }
  return switch (value) {
    null => 'Keep the current mode for the next reply.',
    'interactive' =>
      'Interactive keeps the agent conversational and approval-oriented.',
    'plan' =>
      'Plan focuses on outlining or analyzing before it starts making changes.',
    'autopilot' =>
      'Autopilot lets the agent keep going with fewer interruptions.',
    _ => 'The next reply will use ${providerModeLabel(value, modes)} mode.',
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
