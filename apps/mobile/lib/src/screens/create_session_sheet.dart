import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../create_session_defaults_store.dart';
import '../fs_models.dart';
import '../models.dart';
import '../session_message_seed_store.dart';
import '../session_policy_store.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_snackbar.dart';
import '../theme/app_tokens.dart';
import '../widgets/launch_controls.dart';
import '../widgets/launch_options_form.dart';
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
  final enabledHosts = hosts
      .where((host) => host.enabled)
      .toList(growable: false);
  if (enabledHosts.isEmpty) return null;
  final host = enabledHosts.length == 1
      ? enabledHosts.first
      : await showCreateSessionHostPicker(context, hosts: enabledHosts);
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
                      borderRadius: AppShapes.input,
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
                              ?.copyWith(fontWeight: AppWeights.title),
                        ),
                        Text(
                          'Pick where the new agent session should run.',
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
                                      ?.copyWith(fontWeight: AppWeights.emphasis),
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
  List<ProviderProfileSummary> _profiles = const <ProviderProfileSummary>[];
  ModelCatalogEntry? _selectedModel;
  String? _mode;
  String? _reasoningEffort;
  String? _modelsError;
  String? _profilesError;
  String? _defaultProfileName;
  ApprovalPolicy _approval = ApprovalPolicy.onRequest;
  SandboxMode _sandbox = SandboxMode.workspaceWrite;
  bool _loadingModels = false;
  bool _loadingProfiles = false;
  bool _fastMode = false;
  bool _webSearch = false;
  bool _reasoningTouched = false;
  bool _fastModeTouched = false;
  bool _approvalTouched = false;
  bool _sandboxTouched = false;
  bool _webSearchTouched = false;
  bool _showAdvanced = false;
  bool _submitting = false;
  bool _loadingNode = false;
  String? _error;
  String? _nodeError;
  NodeInfo? _nodeInfo;
  String? _modelsLoadedForCwd;
  String? _modelsLoadedForProfile;
  String? _profilesLoadedForCwd;
  String? _selectedProviderKind;

  @override
  void initState() {
    super.initState();
    final defaults = CreateSessionDefaultsStore.instance.defaults;
    _cwdController = TextEditingController(text: widget.initialCwd ?? '');
    _promptController = TextEditingController();
    _profileController = TextEditingController();
    _approval = defaults.approval;
    _sandbox = defaults.sandbox;
    _fastMode = defaults.fastMode;
    _webSearch = defaults.webSearch;
    _cwdController.addListener(_handleCwdChanged);
    unawaited(_loadNodeInfo());
  }

  @override
  void dispose() {
    _cwdController
      ..removeListener(_handleCwdChanged)
      ..dispose();
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

  ModelCatalogEntry? get _profileModelEntry {
    final profile = _selectedProfile;
    final profileModel = _trimmedOrNull(profile?.model);
    if (profile == null || profileModel == null) return null;
    for (final model in _models) {
      if (model.model == profileModel && model.profileName == profile.name) {
        return model;
      }
    }
    return null;
  }

  ModelCatalogEntry? get _controlModel {
    final selected = _selectedModel;
    if (selected != null) return selected;
    if (_profileToSubmit != null) return _profileModelEntry;
    return _defaultModelEntry;
  }

  bool get _controlModelIsAuto => _controlModel?.isAutoModel ?? false;

  bool get _fastSupported =>
      _supportsFastMode && (_controlModel?.supportsFastMode ?? false);

  List<ProviderDefinitionSummary> get _availableProviders {
    final node = _nodeInfo;
    if (node == null || node.supportedProviders.isEmpty) {
      return const <ProviderDefinitionSummary>[];
    }
    return node.supportedProviders;
  }

  String get _selectedProviderKindOrDefault =>
      _selectedProviderKind ?? _nodeInfo?.provider ?? '';

  ProviderDefinitionSummary get _selectedProviderSummary {
    final node = _nodeInfo;
    if (node == null) {
      return ProviderDefinitionSummary.empty;
    }
    return node.providerSummary(_selectedProviderKindOrDefault);
  }

  String get _providerName {
    final summary = _selectedProviderSummary;
    if (summary.displayName.isNotEmpty) {
      return summary.displayName;
    }
    return _nodeInfo?.providerDisplayName ?? 'agent';
  }

  String get _providerPillLabel {
    final summary = _selectedProviderSummary;
    if (summary.kind.isNotEmpty) {
      final version = summary.version.trim();
      return version.isEmpty
          ? summary.displayName
          : '${summary.displayName} $version';
    }
    final node = _nodeInfo;
    if (node != null) return node.providerPillLabel;
    if (_loadingNode) return 'checking provider';
    if (_nodeError != null) return 'provider unknown';
    return 'agent provider';
  }

  bool get _supportsModels => _supports('configuration', 'models');

  bool get _supportsProfiles => _supports('configuration', 'profiles');

  bool get _supportsModelOverride => _supports('runtimeControls', 'model');

  bool get _supportsMode => _supports('runtimeControls', 'mode');

  bool get _supportsReasoningEffort =>
      _supports('runtimeControls', 'reasoningEffort');

  bool get _supportsFastMode => _supports('runtimeControls', 'fastMode');

  bool get _supportsApprovalPolicy =>
      _supports('runtimeControls', 'approvalPolicy');

  bool get _supportsSandboxMode => _supports('runtimeControls', 'sandboxMode');

  bool get _supportsWebSearch => _supports('runtimeControls', 'webSearch');

  bool _supports(String section, String feature) {
    final node = _nodeInfo;
    if (node == null) return true;
    return node
        .capabilitiesForProvider(_selectedProviderKindOrDefault)
        .supports(section, feature);
  }

  ProviderDefinitionSummary get _activeProviderSummary {
    final node = _nodeInfo;
    if (node == null) {
      return ProviderDefinitionSummary.empty;
    }
    return node.providerSummary(_selectedProviderKindOrDefault);
  }

  List<ApprovalPolicy> get _approvalOptions {
    final supported = _activeProviderSummary.supportedApprovalPolicies;
    if (supported.isEmpty) {
      return ApprovalPolicy.values;
    }
    final options = ApprovalPolicy.values
        .where((policy) => supported.contains(policy.wire))
        .toList(growable: false);
    return options.isEmpty ? ApprovalPolicy.values : options;
  }

  String? get _effectiveReasoningEffort {
    final model = _controlModel;
    final inheritedReasoning = _hasProfileRuntimeContext && !_reasoningTouched
        ? _trimmedOrNull(_activeProfile?.reasoningEffort)
        : null;
    if (model == null) return _reasoningEffort ?? inheritedReasoning;
    if (model.isAutoModel) return model.defaultReasoningEffort;
    return _reasoningEffort ??
        inheritedReasoning ??
        _trimmedOrNull(model.defaultReasoningEffort);
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
    final profile = _selectedProfile;
    final profileModel = _trimmedOrNull(profile?.model);
    if (profile != null && profileModel != null) {
      return profileModel;
    }
    if (_profileToSubmit != null) {
      return 'Use profile default';
    }
    return 'Use host default';
  }

  String get _modelDescription {
    if (!_supportsModels) {
      return 'This provider does not expose a model catalog through Sidemesh.';
    }
    if (_loadingModels) {
      final profile = _profileToSubmit;
      if (profile != null) {
        return 'Loading models for profile $profile.';
      }
      return 'Loading available models from this host.';
    }
    if (_modelsError != null) {
      return _modelsError!;
    }
    final selected = _selectedModel;
    if (selected != null && selected.description.trim().isNotEmpty) {
      return selected.description.trim();
    }
    final profile = _selectedProfile;
    final profileModel = _trimmedOrNull(profile?.model);
    if (profile != null && profileModel != null) {
      return 'No model override will be sent. $_providerName will use profile ${profile.name}\'s model $profileModel.';
    }
    final profileName = _profileToSubmit;
    if (profileName != null) {
      return 'No model override selected. Choose a provider model only if you want to override profile $profileName.';
    }
    final defaultModel = _defaultModelEntry;
    if (defaultModel != null) {
      return 'Host default: ${defaultModel.displayName}. Leave unset to let $_providerName use this host\'s current config.';
    }
    return 'Leave unset to let $_providerName use this host\'s current config.';
  }

  String get _profileLabel {
    final selected = _selectedProfile;
    if (selected != null) return selected.name;
    final profile = _profileToSubmit;
    if (profile != null) return profile;
    return 'Host default';
  }

  String get _profileDescription {
    if (!_supportsProfiles) {
      return 'This provider does not expose config profiles through Sidemesh.';
    }
    if (_loadingProfiles) {
      return 'Loading provider profiles for this workspace.';
    }
    if (_profilesError != null) {
      return _profilesError!;
    }
    final selected = _selectedProfile;
    if (selected != null) {
      final provider = _profileProviderLabel(selected);
      final providerText = provider == null ? '' : ' Provider: $provider.';
      return '${_describeProviderProfile(selected)}$providerText Unchanged launch controls will inherit this profile.';
    }
    final unresolvedProfile = _profileToSubmit;
    if (unresolvedProfile != null) {
      return 'Profile $unresolvedProfile is selected but has not been resolved from the current workspace config yet.';
    }
    if (_defaultProfileName != null) {
      return 'No profile override. $_providerName will inherit workspace default profile $_defaultProfileName.';
    }
    if (_currentCwd == null) {
      return 'Enter a working directory first to discover provider profiles.';
    }
    if (_profilesLoadedForCwd == _currentCwd && _profiles.isEmpty) {
      return 'No named profiles were found for this workspace. $_providerName will use the host config.';
    }
    return 'Choose a discovered provider profile before picking a model, or keep the host config.';
  }

  String? get _reasoningToSubmit {
    if (!_supportsReasoningEffort) return null;
    if (_controlModelIsAuto) return null;
    if (_hasProfileRuntimeContext && !_reasoningTouched) {
      return null;
    }
    return _trimmedOrNull(_reasoningEffort);
  }

  String? get _modeToSubmit {
    if (!_supportsMode) return null;
    return _trimmedOrNull(_mode);
  }

  String? get _currentCwd => _trimmedOrNull(_cwdController.text);

  String? get _profileToSubmit => _trimmedOrNull(_profileController.text);

  ProviderProfileSummary? get _selectedProfile {
    final name = _profileToSubmit;
    if (name == null) return null;
    for (final profile in _profiles) {
      if (profile.name == name) {
        return profile;
      }
    }
    return null;
  }

  ProviderProfileSummary? get _activeProfile {
    final selected = _selectedProfile;
    if (selected != null) {
      return selected;
    }
    final defaultName = _defaultProfileName;
    if (defaultName == null) {
      return null;
    }
    for (final profile in _profiles) {
      if (profile.name == defaultName) {
        return profile;
      }
    }
    return null;
  }

  bool get _hasProfileRuntimeContext =>
      _profileToSubmit != null || _defaultProfileName != null;

  ApprovalPolicy get _effectiveApproval {
    if (_hasProfileRuntimeContext && !_approvalTouched) {
      final inherited = ApprovalPolicy.fromWire(_activeProfile?.approvalPolicy);
      if (inherited != null) {
        return inherited;
      }
    }
    return _approval;
  }

  SandboxMode get _effectiveSandbox {
    if (_hasProfileRuntimeContext && !_sandboxTouched) {
      final inherited = SandboxMode.fromWire(_activeProfile?.sandboxMode);
      if (inherited != null) {
        return inherited;
      }
    }
    return _sandbox;
  }

  bool get _effectiveFastMode {
    if (_hasProfileRuntimeContext && !_fastModeTouched) {
      return (_activeProfile?.serviceTier ?? '').trim() == 'fast';
    }
    return _fastMode;
  }

  bool get _effectiveWebSearch {
    if (_hasProfileRuntimeContext && !_webSearchTouched) {
      return (_activeProfile?.webSearch ?? '').trim() == 'live';
    }
    return _webSearch;
  }

  String? get _approvalPolicyToSubmit {
    if (!_supportsApprovalPolicy) return null;
    if (_hasProfileRuntimeContext && !_approvalTouched) return null;
    return _effectiveApproval.wire;
  }

  String? get _sandboxModeToSubmit {
    if (!_supportsSandboxMode) return null;
    if (_hasProfileRuntimeContext && !_sandboxTouched) return null;
    return _effectiveSandbox.wire;
  }

  bool? get _fastModeToSubmit {
    if (!_supportsFastMode) return null;
    if (_hasProfileRuntimeContext && !_fastModeTouched) return null;
    return _effectiveFastMode;
  }

  String? get _webSearchToSubmit {
    if (!_supportsWebSearch) return null;
    if (_hasProfileRuntimeContext && !_webSearchTouched) return null;
    return _effectiveWebSearch ? 'live' : 'disabled';
  }

  Future<void> _loadNodeInfo() async {
    if (_loadingNode) return;
    setState(() {
      _loadingNode = true;
      _nodeError = null;
    });

    try {
      final node = await widget.api.fetchNode(widget.host);
      if (!mounted) return;
      setState(() {
        _nodeInfo = node;
        _selectedProviderKind ??= node.provider;
        _loadingNode = false;
        _nodeError = null;
        _coerceForProviderCapabilities();
      });
      if (_supportsProfiles && _currentCwd != null) {
        unawaited(_loadProfiles());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingNode = false;
        _nodeError = friendlyError(error);
      });
    }
  }

  Future<void> _browseDirectory() async {
    final node = _nodeInfo;
    if (node == null) return;
    final root = _trimmedOrNull(_cwdController.text) ?? '/';
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _DirectoryPickerSheet(
        host: widget.host,
        api: widget.api,
        initialPath: root,
      ),
    );
    if (selected != null && mounted) {
      _cwdController.text = selected;
      _handleCwdChanged();
    }
  }

  void _coerceForProviderCapabilities() {
    if (!_supportsProfiles) {
      _profileController.clear();
      _profiles = const <ProviderProfileSummary>[];
      _profilesError = null;
      _defaultProfileName = null;
      _profilesLoadedForCwd = null;
    }
    if (!_supportsModels || !_supportsModelOverride) {
      _selectedModel = null;
      _models = const <ModelCatalogEntry>[];
      _modelsError = null;
      _modelsLoadedForCwd = null;
      _modelsLoadedForProfile = null;
    }
    if (!_supportsReasoningEffort) {
      _reasoningEffort = null;
      _reasoningTouched = false;
    }
    if (!_supportsMode) {
      _mode = null;
    }
    if (!_supportsFastMode) {
      _fastMode = false;
      _fastModeTouched = false;
    }
    if (!_supportsApprovalPolicy) {
      _approval = ApprovalPolicy.onRequest;
      _approvalTouched = false;
    } else if (!_approvalOptions.contains(_approval)) {
      _approval = _approvalOptions.first;
      _approvalTouched = false;
    }
    if (!_supportsSandboxMode) {
      _sandbox = SandboxMode.workspaceWrite;
      _sandboxTouched = false;
    }
    if (!_supportsWebSearch) {
      _webSearch = false;
      _webSearchTouched = false;
    }
  }

  void _selectProvider(String? providerKind) {
    final normalized = _trimmedOrNull(providerKind);
    if (_selectedProviderKind == normalized) {
      return;
    }
    _selectedProviderKind = normalized;
    _selectProfile(null);
    _selectedModel = null;
    _models = const <ModelCatalogEntry>[];
    _profiles = const <ProviderProfileSummary>[];
    _modelsError = null;
    _profilesError = null;
    _defaultProfileName = null;
    _modelsLoadedForCwd = null;
    _modelsLoadedForProfile = null;
    _profilesLoadedForCwd = null;
    _reasoningTouched = false;
    _fastModeTouched = false;
    _approvalTouched = false;
    _sandboxTouched = false;
    _webSearchTouched = false;
    _coerceForProviderCapabilities();
  }

  void _handleCwdChanged() {
    final cwd = _currentCwd;
    if (_modelsLoadedForCwd != cwd) {
      setState(() {
        _models = const <ModelCatalogEntry>[];
        _modelsError = null;
        _modelsLoadedForCwd = null;
        _modelsLoadedForProfile = null;
      });
      if (_showAdvanced &&
          _supportsModels &&
          _supportsModelOverride &&
          !_loadingModels) {
        unawaited(_loadModels());
      }
    }
    if (cwd == _profilesLoadedForCwd) {
      return;
    }
    if (_profilesLoadedForCwd == null &&
        _profiles.isEmpty &&
        _profilesError == null &&
        _defaultProfileName == null) {
      return;
    }
    setState(() {
      _profiles = const <ProviderProfileSummary>[];
      _profilesError = null;
      _defaultProfileName = null;
      _profilesLoadedForCwd = null;
    });
    if (_supportsProfiles && cwd != null && !_loadingProfiles) {
      unawaited(_loadProfiles());
    }
  }

  Future<void> _loadModels({bool force = false}) async {
    if (!_supportsModels || !_supportsModelOverride) {
      setState(() {
        _models = const <ModelCatalogEntry>[];
        _modelsError = null;
        _modelsLoadedForCwd = _currentCwd;
        _modelsLoadedForProfile = _profileToSubmit;
      });
      return;
    }
    final cwd = _currentCwd;
    final profile = _profileToSubmit;
    if (_loadingModels) return;
    if (!force &&
        _modelsLoadedForCwd == cwd &&
        _modelsLoadedForProfile == profile &&
        _modelsError == null) {
      return;
    }
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });

    try {
      final models = await widget.api.fetchModels(
        widget.host,
        cwd: cwd,
        profile: profile,
        agentProvider: _selectedProviderKindOrDefault,
      );
      models.sort(_compareModelEntries);
      if (!mounted) return;
      setState(() {
        _models = models;
        _modelsLoadedForCwd = cwd;
        _modelsLoadedForProfile = profile;
        _loadingModels = false;
        _modelsError = models.isEmpty
            ? profile == null
                  ? 'This provider did not return any models for this host.'
                  : 'This provider did not return any models for profile $profile.'
            : null;
        final selectedModel = _selectedModel;
        if (selectedModel != null) {
          ModelCatalogEntry? refreshedSelection;
          for (final entry in models) {
            if (entry.model == selectedModel.model) {
              refreshedSelection = entry;
              break;
            }
          }
          _selectedModel = refreshedSelection;
        }
        _coerceCurrentModelOptions();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _modelsError = friendlyError(error);
        _modelsLoadedForCwd = cwd;
        _modelsLoadedForProfile = profile;
      });
    }
  }

  Future<void> _loadProfiles({bool force = false}) async {
    if (!_supportsProfiles) {
      setState(() {
        _profiles = const <ProviderProfileSummary>[];
        _profilesError = null;
        _defaultProfileName = null;
        _profilesLoadedForCwd = _currentCwd;
      });
      return;
    }
    final cwd = _currentCwd;
    if (cwd == null) {
      setState(() {
        _profiles = const <ProviderProfileSummary>[];
        _profilesError =
            'Enter a working directory to load workspace-aware provider profiles.';
        _defaultProfileName = null;
        _profilesLoadedForCwd = null;
      });
      return;
    }
    if (_loadingProfiles) return;
    if (!force && _profilesLoadedForCwd == cwd && _profilesError == null) {
      return;
    }

    setState(() {
      _loadingProfiles = true;
      _profilesError = null;
    });

    try {
      final catalog = await widget.api.fetchProfiles(
        widget.host,
        cwd: cwd,
        agentProvider: _selectedProviderKindOrDefault,
      );
      if (!mounted) return;
      setState(() {
        _profiles = catalog.profiles;
        _defaultProfileName = catalog.defaultProfile;
        _profilesError = null;
        _loadingProfiles = false;
        _profilesLoadedForCwd = cwd;
        final selectedProfile = _profileToSubmit;
        if (selectedProfile != null &&
            !catalog.profiles.any(
              (profile) => profile.name == selectedProfile,
            )) {
          _selectProfile(null);
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingProfiles = false;
        _profilesError = friendlyError(error);
        _profilesLoadedForCwd = cwd;
      });
    }
  }

  void _coerceCurrentModelOptions() {
    final model = _controlModel;
    if (model == null) {
      _reasoningEffort = null;
      _fastMode = false;
      _reasoningTouched = false;
      _fastModeTouched = false;
      return;
    }

    if (model.isAutoModel) {
      _reasoningEffort = null;
    } else {
      final supported = model.supportedReasoningEfforts
          .map((option) => option.reasoningEffort)
          .toSet();
      final reasoning = _trimmedOrNull(_reasoningEffort);
      if (reasoning != null && !supported.contains(reasoning)) {
        _reasoningEffort = _trimmedOrNull(model.defaultReasoningEffort);
        _reasoningTouched = false;
      }
    }

    if (!model.supportsFastMode) {
      _fastMode = false;
      _fastModeTouched = false;
    }
  }

  void _selectProfile(String? profileName) {
    final normalized = _trimmedOrNull(profileName);
    if (normalized == null) {
      _profileController.clear();
    } else {
      _profileController.text = normalized;
      _profileController.selection = TextSelection.collapsed(
        offset: normalized.length,
      );
    }
    _selectedModel = null;
    _models = const <ModelCatalogEntry>[];
    _modelsError = null;
    _modelsLoadedForCwd = null;
    _modelsLoadedForProfile = null;
    _coerceCurrentModelOptions();
  }

  void _toggleAdvanced() {
    setState(() => _showAdvanced = !_showAdvanced);
    if (_showAdvanced &&
        _supportsModels &&
        _supportsModelOverride &&
        (_modelsLoadedForCwd != _currentCwd ||
            _modelsLoadedForProfile != _profileToSubmit ||
            _models.isEmpty) &&
        !_loadingModels) {
      unawaited(_loadModels());
    }
    if (_showAdvanced &&
        _supportsProfiles &&
        _currentCwd != null &&
        _profilesLoadedForCwd == null &&
        !_loadingProfiles) {
      unawaited(_loadProfiles());
    }
  }

  Future<void> _chooseProfile() async {
    if (!_supportsProfiles) return;
    if (_loadingProfiles) return;
    if (_currentCwd == null) {
      setState(() {
        _profilesError =
            'Enter a working directory to load workspace-aware provider profiles.';
      });
      return;
    }
    await _loadProfiles(force: true);
    if (!mounted) return;

    final result = await showModalBottomSheet<_ProfilePickerResult>(
      context: context,
      backgroundColor: context.colors.surface,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _ProfilePickerSheet(
        profiles: _profiles,
        currentProfile: _profileToSubmit,
        defaultProfile: _defaultProfileName,
        loadError: _profilesError,
        providerName: _providerName,
      ),
    );
    if (!mounted || result == null) return;

    setState(() {
      _selectProfile(result.profileName);
    });
    unawaited(_loadModels(force: true));
  }

  Future<void> _chooseProvider() async {
    if (_availableProviders.length <= 1) {
      return;
    }
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.28),
      showDragHandle: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _ProviderPickerSheet(
        providers: _availableProviders,
        selectedProvider: _selectedProviderKindOrDefault,
      ),
    );
    if (!mounted || result == null) {
      return;
    }
    setState(() {
      _selectProvider(result);
    });
    if (_supportsProfiles && _currentCwd != null) {
      unawaited(_loadProfiles(force: true));
    }
    if (_showAdvanced) {
      unawaited(_loadModels(force: true));
    }
  }

  Future<void> _chooseModel() async {
    if (!_supportsModels || !_supportsModelOverride) return;
    if (_loadingModels) return;
    if (_modelsLoadedForCwd != _currentCwd ||
        _modelsLoadedForProfile != _profileToSubmit ||
        _models.isEmpty) {
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
        profile: _selectedProfile,
        profileName: _profileToSubmit,
        inheritedModel: _profileToSubmit == null
            ? _defaultModelEntry
            : _profileModelEntry,
        providerName: _providerName,
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
      if (_supportsApprovalPolicy &&
          _approvalOptions.contains(ApprovalPolicy.never)) {
        _approval = ApprovalPolicy.never;
        _approvalTouched = true;
      }
      if (_supportsSandboxMode) {
        _sandbox = SandboxMode.dangerFullAccess;
        _sandboxTouched = true;
      }
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
      if (_supportsProfiles &&
          _currentCwd != null &&
          _profilesLoadedForCwd != _currentCwd) {
        await _loadProfiles();
      }
      final session = await widget.api.createSession(
        widget.host,
        cwd: cwd,
        prompt: prompt,
        provider: _selectedProviderKindOrDefault,
        model: _supportsModelOverride ? _selectedModel?.model : null,
        mode: _modeToSubmit,
        reasoningEffort: _reasoningToSubmit,
        fastMode: _fastModeToSubmit,
        approvalPolicy: _approvalPolicyToSubmit,
        sandboxMode: _sandboxModeToSubmit,
        webSearch: _webSearchToSubmit,
        profile: _supportsProfiles ? _profileToSubmit : null,
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
    final maxHeight = (MediaQuery.sizeOf(context).height - 80)
        .clamp(360.0, 820.0)
        .toDouble();

    return Padding(
      padding: isDialog
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(10, 8, 10, bottom + 10),
      child: ConstrainedBox(
        constraints: isDialog
            ? BoxConstraints.tightFor(height: maxHeight)
            : const BoxConstraints(),
        child: MeshCard(
          tone: MeshCardTone.elevated,
          padding: EdgeInsets.all(isDialog ? 18 : 14),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(context),
                        const SizedBox(height: 16),
                        _buildPrimaryPanel(context),
                        const SizedBox(height: 12),
                        _showAdvanced
                            ? _buildAdvancedPanel(context)
                            : _buildLaunchSummaryCard(context),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          _ErrorPanel(message: _error!),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _buildFooter(context),
              ],
            ),
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
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.accentMuted,
            borderRadius: AppShapes.input,
            border: Border.all(color: colors.accent.withValues(alpha: 0.24)),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.play_arrow_rounded, color: colors.accent, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'New $_providerName session',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: AppWeights.title,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.host.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.textSecondary,
                  fontWeight: AppWeights.body,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        MeshIconButton(
          icon: Icons.close_rounded,
          tooltip: 'Close',
          color: colors.textSecondary,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _buildPrimaryPanel(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_availableProviders.length > 1) ...[
          _LaunchSelectorRow(
            key: const ValueKey('create-session-provider-selector'),
            icon: Icons.smart_toy_rounded,
            label: 'Provider',
            value: _providerName,
            detail: _providerPillLabel,
            onTap: _submitting ? null : _chooseProvider,
          ),
          const SizedBox(height: 10),
        ],
        _LaunchFieldFrame(
          icon: Icons.folder_open_rounded,
          label: 'Working directory',
          trailing: _nodeInfo != null
              ? IconButton(
                  tooltip: 'Browse host filesystem',
                  onPressed: _submitting ? null : _browseDirectory,
                  icon: Icon(
                    Icons.folder_rounded,
                    size: 18,
                    color: context.colors.accent,
                  ),
                )
              : _loadingNode
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
          child: TextField(
            controller: _cwdController,
            textInputAction: TextInputAction.next,
            style: monoStyle(color: colors.textPrimary, fontSize: 14),
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              hintText: '/Users/you/src/project',
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        const SizedBox(height: 10),
        _LaunchFieldFrame(
          icon: Icons.keyboard_command_key_rounded,
          label: 'Prompt',
          alignTop: true,
          child: TextField(
            key: const ValueKey('create-session-prompt-field'),
            controller: _promptController,
            minLines: 5,
            maxLines: 10,
            decoration: const InputDecoration(
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              hintText: 'Ask the agent what to work on...',
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLaunchSummaryCard(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: AppShapes.input,
        onTap: _submitting ? null : _toggleAdvanced,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: AppShapes.input,
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 18, color: colors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Tune launch',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _launchSummaryText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }

  String _launchSummaryText() {
    final parts = <String>[
      _providerName,
      if (_supportsProfiles) _profileLabel,
      if (_supportsModels && _supportsModelOverride) _modelLabel,
      if (_supportsApprovalPolicy) _effectiveApproval.label,
      if (_supportsSandboxMode) _effectiveSandbox.label,
      if (_supportsWebSearch && _effectiveWebSearch) 'web search',
    ];
    return parts.join(' · ');
  }

  Widget _buildAdvancedPanel(BuildContext context) {
    final colors = context.colors;
    final effectiveReasoning = _effectiveReasoningEffort;
    String? reasoningDescription;
    for (final option in _supportedReasoningOptions) {
      if (option.reasoningEffort == effectiveReasoning) {
        reasoningDescription = option.description;
        break;
      }
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeading(
            icon: Icons.tune_rounded,
            title: 'Tune launch',
            subtitle:
                'Only controls supported by $_providerName are shown here.',
            trailing: IconButton(
              tooltip: 'Hide advanced',
              onPressed: _submitting ? null : _toggleAdvanced,
              icon: const Icon(Icons.expand_less_rounded),
            ),
          ),
          const SizedBox(height: 14),
          LaunchOptionsForm(
            dense: true,
            capabilities: LaunchOptionsCapabilities(
              supportsApprovalPolicy: _supportsApprovalPolicy,
              supportsSandboxMode: _supportsSandboxMode,
              supportsFastMode: false,
              supportsWebSearch: _supportsWebSearch,
              supportsSessionMode: _supportsMode,
              approvalOptions: _approvalOptions,
            ),
            value: LaunchOptionsValue(
              approval: _effectiveApproval,
              sandbox: _effectiveSandbox,
              fastMode: _effectiveFastMode,
              webSearch: _effectiveWebSearch,
              sessionMode: _modeToSubmit,
            ),
            onApprovalChanged: (policy) => setState(() {
              _approval = policy;
              _approvalTouched = true;
            }),
            onSandboxChanged: (mode) => setState(() {
              _sandbox = mode;
              _sandboxTouched = true;
            }),
            onWebSearchChanged: (next) => setState(() {
              _webSearch = next;
              _webSearchTouched = true;
            }),
            onSessionModeChanged: (mode) => setState(() {
              _mode = mode;
            }),
            permissionsTrailing: _supportsApprovalPolicy &&
                    _approvalOptions.contains(ApprovalPolicy.never) &&
                    _supportsSandboxMode
                ? TextButton.icon(
                    onPressed: _applyAutopilot,
                    icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                    label: const Text('Autopilot'),
                  )
                : null,
            brainExtras: _buildBrainExtras(context, effectiveReasoning,
                reasoningDescription),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _submitting
                      ? null
                      : () async {
                          await CreateSessionDefaultsStore.instance
                              .setDefaults(
                            CreateSessionDefaults(
                              approval: _effectiveApproval,
                              sandbox: _effectiveSandbox,
                              fastMode: _effectiveFastMode,
                              webSearch: _effectiveWebSearch,
                            ),
                          );
                          if (context.mounted) {
                            showAppSnackBar(
                              context,
                              'Saved as default launch options.',
                            );
                            HapticFeedback.mediumImpact();
                          }
                        },
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Save as defaults'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget>? _buildBrainExtras(
    BuildContext context,
    String? effectiveReasoning,
    String? reasoningDescription,
  ) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final extras = <Widget>[];

    if (_supportsProfiles) {
      extras.add(_ModelSelectionCard(
        title: 'Profile',
        icon: Icons.badge_rounded,
        value: _profileLabel,
        subtitle: _profileDescription,
        loading: _loadingProfiles,
        error: _profilesError,
        compact: true,
        badges: _profileBadges(),
        retryLabel: 'Retry loading profiles',
        onTap: _chooseProfile,
        onRetry: () => unawaited(_loadProfiles(force: true)),
      ));
    }

    if (_supportsModels && _supportsModelOverride) {
      extras.add(_ModelSelectionCard(
        title: 'Model',
        icon: Icons.memory_rounded,
        value: _modelLabel,
        subtitle: _modelDescription,
        loading: _loadingModels,
        error: _modelsError,
        compact: true,
        badges: <String>[
          if (_selectedModel != null) 'override',
          if (_selectedModel == null && _profileToSubmit != null)
            'profile default',
          if (_controlModel?.isAutoModel ?? false) 'auto',
          if (_controlModel?.isDefault ?? false) 'default',
          if (_profileToSubmit != null) 'profile scoped',
          if (_controlModel?.supportsFastMode ?? false) 'fast',
        ],
        onTap: _chooseModel,
        onRetry: () => unawaited(_loadModels()),
      ));
    }

    if (!_supportsProfiles &&
        (!_supportsModels || !_supportsModelOverride)) {
      extras.add(LaunchInfoLine(
        icon: Icons.info_outline_rounded,
        text: '$_providerName does not advertise profile or model controls.',
      ));
    }

    if (_supportsReasoningEffort &&
        _supportsModels &&
        _supportsModelOverride) {
      if (_loadingModels && _models.isEmpty) {
        extras.add(const LinearProgressIndicator(minHeight: 3));
      } else if (_controlModelIsAuto) {
        extras.add(LaunchInfoLine(
          icon: Icons.psychology_alt_rounded,
          text:
              'Auto thinking: ${_reasoningEffortLabel(effectiveReasoning ?? 'medium')}',
        ));
      } else if (_supportedReasoningOptions.isEmpty) {
        extras.add(const LaunchInfoLine(
          icon: Icons.psychology_alt_rounded,
          text: 'Pick a model to tune reasoning.',
        ));
      } else {
        extras.add(LaunchChoiceWrap<String>(
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
              _reasoningTouched = true;
            });
          },
        ));
        if (reasoningDescription != null &&
            reasoningDescription.trim().isNotEmpty) {
          extras.add(Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              reasoningDescription.trim(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.textSecondary,
                height: 1.3,
              ),
            ),
          ));
        }
      }
    }

    if (_supportsFastMode) {
      extras.add(LaunchSwitchRow(
        icon: Icons.bolt_rounded,
        title: 'Fast mode',
        subtitle: _fastSupported
            ? 'Ask for the fast service tier.'
            : 'Not advertised by this model.',
        value: _effectiveFastMode,
        enabled: _fastSupported,
        onChanged: (value) => setState(() {
          _fastMode = value;
          _fastModeTouched = true;
        }),
      ));
    }

    return extras.isEmpty ? null : extras;
  }

  Widget _buildFooter(BuildContext context) {
    final colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        final actions = [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.accentOn,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded),
            label: const Text('Start session'),
          ),
        ];
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(spacing: 7, runSpacing: 7, children: _launchPills()),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.accentOn,
                        ),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: const Text('Start session'),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(
              child: Wrap(spacing: 8, runSpacing: 8, children: _launchPills()),
            ),
            const SizedBox(width: 12),
            ...actions.expand((action) => [action, const SizedBox(width: 8)]),
          ]..removeLast(),
        );
      },
    );
  }

  List<Widget> _launchPills() {
    final reasoning = _effectiveReasoningEffort;
    return [
      MeshPill(
        label: _providerPillLabel,
        icon: Icons.smart_toy_rounded,
        tone: MeshPillTone.neutral,
      ),
      if (_supportsProfiles)
        MeshPill(
          label: _profileLabel,
          icon: Icons.badge_rounded,
          tone: _profileToSubmit == null
              ? MeshPillTone.neutral
              : MeshPillTone.accent,
        ),
      if (_supportsMode)
        MeshPill(
          label: _sessionModeChoiceLabel(_modeToSubmit),
          icon: Icons.alt_route_rounded,
          tone: _modeToSubmit == null
              ? MeshPillTone.neutral
              : MeshPillTone.info,
        ),
      if (_supportsModels && _supportsModelOverride)
        MeshPill(
          label: _modelLabel,
          icon: Icons.memory_rounded,
          tone: _selectedModel == null
              ? MeshPillTone.neutral
              : MeshPillTone.accent,
        ),
      if (_supportsReasoningEffort && _supportsModels && _supportsModelOverride)
        MeshPill(
          label: _controlModelIsAuto
              ? 'auto thinking'
              : reasoning == null
              ? 'default thinking'
              : _reasoningEffortLabel(reasoning),
          icon: Icons.psychology_alt_rounded,
        ),
      if (_supportsFastMode && _effectiveFastMode)
        const MeshPill(
          label: 'fast',
          icon: Icons.bolt_rounded,
          tone: MeshPillTone.warning,
        ),
      if (_supportsApprovalPolicy)
        MeshPill(
          label: _effectiveApproval.label,
          icon: Icons.verified_user_rounded,
        ),
      if (_supportsSandboxMode)
        MeshPill(
          label: _effectiveSandbox.label,
          icon: _effectiveSandbox == SandboxMode.dangerFullAccess
              ? Icons.lock_open_rounded
              : Icons.folder_special_rounded,
          tone: _effectiveSandbox == SandboxMode.dangerFullAccess
              ? MeshPillTone.danger
              : MeshPillTone.neutral,
        ),
      if (_supportsWebSearch && _effectiveWebSearch)
        const MeshPill(
          label: 'web search',
          icon: Icons.public_rounded,
          tone: MeshPillTone.info,
        ),
    ];
  }

  List<String> _profileBadges() {
    final selected = _selectedProfile;
    if (selected == null) {
      return <String>[
        if (_defaultProfileName != null) 'workspace default',
        if (_profileToSubmit == null) 'host',
      ];
    }
    return <String>[
      if (selected.isDefault) 'default',
      if (_profileProviderLabel(selected) != null) 'provider',
      if (_trimmedOrNull(selected.model) != null) 'model preset',
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
                  fontWeight: AppWeights.title,
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
        borderRadius: AppShapes.input,
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

class _LaunchFieldFrame extends StatelessWidget {
  const _LaunchFieldFrame({
    required this.icon,
    required this.label,
    required this.child,
    this.alignTop = false,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final Widget child;
  final bool alignTop;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceMuted,
        borderRadius: AppShapes.input,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: alignTop
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Padding(
            padding: EdgeInsets.only(top: alignTop ? 2 : 0),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: colors.border),
              ),
              alignment: Alignment.center,
              child: Icon(icon, color: colors.accent, size: 17),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.textSecondary,
                    fontWeight: AppWeights.title,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                child,
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _LaunchSelectorRow extends StatelessWidget {
  const _LaunchSelectorRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: AppShapes.input,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: AppShapes.input,
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.accentMuted,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: colors.accent.withValues(alpha: 0.24),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: colors.accent, size: 17),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: AppWeights.title,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colors.textPrimary,
                        fontWeight: AppWeights.title,
                      ),
                    ),
                    if (detail.trim().isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          color: colors.textTertiary,
                          fontSize: 11,
                          fontWeight: AppWeights.emphasis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded, color: colors.accent),
            ],
          ),
        ),
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
    this.title = 'Model',
    this.icon = Icons.memory_rounded,
    required this.value,
    required this.subtitle,
    required this.loading,
    required this.error,
    required this.badges,
    required this.onTap,
    required this.onRetry,
    this.retryLabel = 'Retry loading models',
    this.compact = false,
  });

  final String title;
  final IconData icon;
  final String value;
  final String subtitle;
  final bool loading;
  final String? error;
  final List<String> badges;
  final VoidCallback onTap;
  final VoidCallback onRetry;
  final String retryLabel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: AppShapes.input,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(compact ? 10 : 12),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppShapes.input,
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: colors.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: AppWeights.emphasis,
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
                  ).textTheme.bodyLarge?.copyWith(fontWeight: AppWeights.body),
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
                label: Text(retryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProfilePickerResult {
  const _ProfilePickerResult(this.profileName);

  final String? profileName;
}

class _ProviderPickerSheet extends StatelessWidget {
  const _ProviderPickerSheet({
    required this.providers,
    required this.selectedProvider,
  });

  final List<ProviderDefinitionSummary> providers;
  final String selectedProvider;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 560),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceElevated,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: colors.border),
                boxShadow: [
                  BoxShadow(
                    color: colors.textPrimary.withValues(alpha: 0.12),
                    blurRadius: 32,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.borderStrong.withValues(alpha: 0.55),
                            borderRadius: AppShapes.pill,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: colors.accentMuted,
                              borderRadius: AppShapes.input,
                              border: Border.all(
                                color: colors.accent.withValues(alpha: 0.24),
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              Icons.account_tree_rounded,
                              size: 19,
                              color: colors.accent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Choose provider',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: colors.textPrimary,
                                        fontWeight: AppWeights.title,
                                        letterSpacing: -0.2,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Pick the agent runtime for this launch.',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colors.textSecondary,
                                        fontWeight: AppWeights.body,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          MeshIconButton(
                            icon: Icons.close_rounded,
                            tooltip: 'Close',
                            color: colors.textSecondary,
                            onTap: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: AppShapes.card,
                          border: Border.all(color: colors.border),
                        ),
                        child: Column(
                          children: [
                            for (
                              var index = 0;
                              index < providers.length;
                              index++
                            ) ...[
                              if (index > 0)
                                Divider(
                                  height: 1,
                                  indent: 62,
                                  color: colors.border.withValues(alpha: 0.72),
                                ),
                              _ProviderPickerTile(
                                key: ValueKey(
                                  'provider-picker-${providers[index].kind}',
                                ),
                                provider: providers[index],
                                selected:
                                    providers[index].kind == selectedProvider,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderPickerTile extends StatelessWidget {
  const _ProviderPickerTile({
    super.key,
    required this.provider,
    required this.selected,
  });

  final ProviderDefinitionSummary provider;
  final bool selected;

  String get _command {
    final configured = provider.config.command?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    final fallback = provider.defaultCommand.trim();
    return fallback.isEmpty ? provider.kind : fallback;
  }

  List<String> get _badges {
    return [
      if (provider.isDefault) 'default',
      if (provider.capabilities.supports('configuration', 'models')) 'models',
      if (provider.capabilities.supports('input', 'localImage')) 'images',
      if (provider.capabilities.supports('approvals', 'permissions'))
        'permissions',
    ];
  }

  String get _displayName {
    final name = provider.displayName.trim();
    return name.isEmpty ? provider.kind : name;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final meta = [
      provider.kind,
      if (provider.version.trim().isNotEmpty) provider.version.trim(),
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).pop(provider.kind),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: selected
                      ? colors.accentMuted
                      : colors.surfaceMuted.withValues(alpha: 0.8),
                  borderRadius: AppShapes.input,
                  border: Border.all(
                    color: selected
                        ? colors.accent.withValues(alpha: 0.38)
                        : colors.border,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.smart_toy_rounded,
                  size: 19,
                  color: selected ? colors.accent : colors.textSecondary,
                ),
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
                            _displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: colors.textPrimary,
                                  fontWeight: AppWeights.title,
                                ),
                          ),
                        ),
                        if (selected)
                          MeshPill(
                            label: 'selected',
                            icon: Icons.check_rounded,
                            tone: MeshPillTone.accent,
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(
                        color: colors.textSecondary,
                        fontSize: 11.5,
                        fontWeight: AppWeights.emphasis,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _InlineBadge(label: _command),
                        for (final badge in _badges) _InlineBadge(label: badge),
                      ],
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

class _ProfilePickerSheet extends StatefulWidget {
  const _ProfilePickerSheet({
    required this.profiles,
    required this.currentProfile,
    required this.defaultProfile,
    required this.loadError,
    required this.providerName,
  });

  final List<ProviderProfileSummary> profiles;
  final String? currentProfile;
  final String? defaultProfile;
  final String? loadError;
  final String providerName;

  @override
  State<_ProfilePickerSheet> createState() => _ProfilePickerSheetState();
}

class _ProfilePickerSheetState extends State<_ProfilePickerSheet> {
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
    final filtered = widget.profiles
        .where((profile) {
          if (query.isEmpty) return true;
          final haystack = [
            profile.name,
            profile.model ?? '',
            profile.modelProvider ?? '',
            profile.modelProviderName ?? '',
            profile.modelProviderBaseUrl ?? '',
            _describeProviderProfile(profile),
          ].join('\n').toLowerCase();
          return haystack.contains(query);
        })
        .toList(growable: false);

    return FractionallySizedBox(
      heightFactor: 0.78,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose profile',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: AppWeights.emphasis),
            ),
            const SizedBox(height: 6),
            Text(
              'Pick a provider profile first. The model picker will then load models from that profile when possible.',
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
                hintText: 'Search profiles',
              ),
            ),
            if (widget.loadError != null) ...[
              const SizedBox(height: 12),
              _CompactInfoLine(
                icon: Icons.info_outline_rounded,
                text: 'Could not load profiles: ${widget.loadError}',
              ),
            ],
            const SizedBox(height: 14),
            Expanded(
              child: filtered.isEmpty && query.isNotEmpty
                  ? Center(
                      child: Text(
                        'No profiles match that search.',
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
                            title: 'Host default',
                            model: null,
                            description: widget.defaultProfile == null
                                ? 'Do not send a profile override. ${widget.providerName} will use the host config.'
                                : 'Do not send a profile override. ${widget.providerName} will inherit workspace default profile ${widget.defaultProfile}.',
                            selected: widget.currentProfile == null,
                            badges: const <String>['inherit'],
                            onTap: () => Navigator.of(
                              context,
                            ).pop(const _ProfilePickerResult(null)),
                          );
                        }
                        final profile =
                            filtered[index - (query.isEmpty ? 1 : 0)];
                        return _ModelPickerTile(
                          title: profile.name,
                          model: null,
                          description: _profilePickerDescription(profile),
                          selected: profile.name == widget.currentProfile,
                          badges: <String>[
                            if (profile.isDefault) 'default',
                            if (_profileProviderLabel(profile) != null)
                              'provider',
                            if (_trimmedOrNull(profile.model) != null)
                              'model preset',
                          ],
                          onTap: () => Navigator.of(
                            context,
                          ).pop(_ProfilePickerResult(profile.name)),
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

class _ModelPickerResult {
  const _ModelPickerResult({this.model});

  final ModelCatalogEntry? model;
}

class _ModelPickerSheet extends StatefulWidget {
  const _ModelPickerSheet({
    required this.models,
    required this.currentModel,
    required this.profile,
    required this.profileName,
    required this.inheritedModel,
    required this.providerName,
  });

  final List<ModelCatalogEntry> models;
  final String? currentModel;
  final ProviderProfileSummary? profile;
  final String? profileName;
  final ModelCatalogEntry? inheritedModel;
  final String providerName;

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
              ).textTheme.titleLarge?.copyWith(fontWeight: AppWeights.emphasis),
            ),
            const SizedBox(height: 6),
            Text(
              widget.profileName == null
                  ? 'Leave the model unset to inherit this host\'s provider config, or choose a model for this new session.'
                  : 'Models are scoped to profile ${widget.profileName}. Leave unset to let ${widget.providerName} use that profile default.',
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
                          final profileName = widget.profileName;
                          return _ModelPickerTile(
                            title: profileName == null
                                ? 'Use host default'
                                : 'Use profile default',
                            model: widget.inheritedModel,
                            description: profileName == null
                                ? 'Do not send a model override. ${widget.providerName} will use the host or workspace provider config.'
                                : _profileModelInheritDescription(
                                    profileName,
                                    widget.profile,
                                    widget.providerName,
                                  ),
                            selected: widget.currentModel == null,
                            badges: <String>[
                              'inherit',
                              if (widget.profile?.isDefault ?? false)
                                'default profile',
                            ],
                            onTap: () => Navigator.of(
                              context,
                            ).pop(const _ModelPickerResult()),
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
                            if (model.isProfileModel) 'profile provider',
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
                          ).pop(_ModelPickerResult(model: model)),
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
      borderRadius: AppShapes.input,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          borderRadius: AppShapes.input,
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
                      fontWeight: AppWeights.emphasis,
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
                  fontWeight: AppWeights.body,
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
        borderRadius: AppShapes.pill,
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
    return 'provider default';
  }
  return sessionModeLabel(value);
}

String _describeProviderProfile(ProviderProfileSummary profile) {
  final parts = <String>[
    if ((profile.model ?? '').isNotEmpty) 'model ${profile.model}',
    if ((profile.serviceTier ?? '').isNotEmpty)
      'tier ${_serviceTierLabel(profile.serviceTier!)}',
    if ((profile.reasoningEffort ?? '').isNotEmpty)
      '${_reasoningEffortLabel(profile.reasoningEffort!)} reasoning',
    if ((profile.approvalPolicy ?? '').isNotEmpty)
      'approval ${_approvalPolicyLabel(profile.approvalPolicy!)}',
    if ((profile.sandboxMode ?? '').isNotEmpty)
      'sandbox ${_sandboxModeLabel(profile.sandboxMode!)}',
    if ((profile.webSearch ?? '').isNotEmpty)
      'web search ${_webSearchModeLabel(profile.webSearch!)}',
    if ((profile.personality ?? '').isNotEmpty)
      'personality ${profile.personality}',
  ];
  if (parts.isEmpty) {
    return 'is a named provider config preset.';
  }
  return 'sets ${parts.join(', ')}.';
}

String? _profileProviderLabel(ProviderProfileSummary profile) =>
    _trimmedOrNull(profile.modelProviderName) ??
    _trimmedOrNull(profile.modelProvider);

String _profilePickerDescription(ProviderProfileSummary profile) {
  final provider = _profileProviderLabel(profile);
  final providerText = provider == null ? '' : ' Provider: $provider.';
  final baseUrl = _trimmedOrNull(profile.modelProviderBaseUrl);
  final baseUrlText = baseUrl == null ? '' : ' $baseUrl';
  return '${_describeProviderProfile(profile)}$providerText$baseUrlText';
}

String _profileModelInheritDescription(
  String profileName,
  ProviderProfileSummary? profile,
  String providerName,
) {
  final profileModel = _trimmedOrNull(profile?.model);
  if (profileModel != null) {
    return 'Do not send a model override. $providerName will use profile $profileName\'s configured model $profileModel.';
  }
  return 'Do not send a model override. $providerName will use profile $profileName and its provider defaults.';
}

String _approvalPolicyLabel(String value) {
  return switch (value) {
    'on-request' => 'on request',
    'on-failure' => 'on failure',
    'untrusted' => 'untrusted',
    'never' => 'never',
    _ => value,
  };
}

String _sandboxModeLabel(String value) {
  return switch (value) {
    'read-only' => 'read-only',
    'workspace-write' => 'workspace-write',
    'danger-full-access' => 'danger-full-access',
    _ => value,
  };
}

String _serviceTierLabel(String value) {
  return switch (value) {
    'fast' => 'fast',
    'flex' => 'flex',
    _ => value,
  };
}

String _webSearchModeLabel(String value) {
  return switch (value) {
    'disabled' => 'disabled',
    'cached' => 'cached',
    'live' => 'live',
    _ => value,
  };
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}

// ---------------------------------------------------------------------------
// Simple host directory picker
// ---------------------------------------------------------------------------

class _DirectoryPickerSheet extends StatefulWidget {
  const _DirectoryPickerSheet({
    required this.host,
    required this.api,
    required this.initialPath,
  });

  final HostProfile host;
  final ApiClient api;
  final String initialPath;

  @override
  State<_DirectoryPickerSheet> createState() => _DirectoryPickerSheetState();
}

class _DirectoryPickerSheetState extends State<_DirectoryPickerSheet> {
  late String _path;
  bool _loading = true;
  String? _error;
  List<FsEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.api.listDirectory(widget.host, _path);
      if (!mounted) return;
      setState(() {
        _entries = listing.entries.where((e) => e.isDirectory).toList()
          ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  void _enter(String name) {
    setState(() {
      _path = _path.endsWith('/') ? '$_path$name' : '$_path/$name';
    });
    unawaited(_load());
  }

  void _up() {
    final parts = _path.split('/');
    if (parts.length <= 2 && _path.startsWith('/')) {
      setState(() => _path = '/');
    } else {
      parts.removeLast();
      setState(() => _path = parts.join('/').isEmpty ? '/' : parts.join('/'));
    }
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: AppShapes.card,
        ),
        child: ClipRRect(
          borderRadius: AppShapes.card,
          child: Scaffold(
            backgroundColor: colors.surface,
            appBar: AppBar(
              backgroundColor: colors.surface,
              foregroundColor: colors.textPrimary,
              elevation: 0,
              scrolledUnderElevation: 0,
              title: Text(
                _path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(color: colors.textPrimary, fontSize: 13),
              ),
              leading: IconButton(
                icon: const Icon(Icons.arrow_upward_rounded),
                tooltip: 'Parent directory',
                onPressed: _up,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_path),
                  child: const Text('Select'),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(color: colors.danger),
                        ),
                      )
                    : _entries.isEmpty
                        ? Center(
                            child: Text(
                              'No sub-directories',
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _entries.length,
                            itemBuilder: (context, i) {
                              final entry = _entries[i];
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  Icons.folder_rounded,
                                  color: colors.accent,
                                ),
                                title: Text(entry.name),
                                onTap: () => _enter(entry.name),
                              );
                            },
                          ),
          ),
        ),
      ),
    );
  }
}
