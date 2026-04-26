import 'dart:async';

import 'package:flutter/material.dart';

import '../api_client.dart';
import '../create_session_defaults_store.dart';
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
  List<CodexProfileSummary> _profiles = const <CodexProfileSummary>[];
  ModelCatalogEntry? _selectedModel;
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
  bool _showAdvanced = false;
  bool _submitting = false;
  String? _error;
  String? _modelsLoadedForCwd;
  String? _modelsLoadedForProfile;
  String? _profilesLoadedForCwd;

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
    if (_loadingModels) {
      final profile = _profileToSubmit;
      if (profile != null) {
        return 'Loading models for profile $profile.';
      }
      return 'Loading the available Codex models from this host.';
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
      return 'No model override will be sent. Codex will use profile ${profile.name}\'s model $profileModel.';
    }
    final profileName = _profileToSubmit;
    if (profileName != null) {
      return 'No model override selected. Choose a provider model only if you want to override profile $profileName.';
    }
    final defaultModel = _defaultModelEntry;
    if (defaultModel != null) {
      return 'Host default: ${defaultModel.displayName}. Leave unset to let Codex use this host\'s current config.';
    }
    return 'Leave unset to let Codex use this host\'s current config.';
  }

  String get _profileLabel {
    final selected = _selectedProfile;
    if (selected != null) return selected.name;
    final profile = _profileToSubmit;
    if (profile != null) return profile;
    return 'Host default';
  }

  String get _profileDescription {
    if (_loadingProfiles) {
      return 'Loading Codex profiles for this workspace.';
    }
    if (_profilesError != null) {
      return _profilesError!;
    }
    final selected = _selectedProfile;
    if (selected != null) {
      final provider = _profileProviderLabel(selected);
      final providerText = provider == null ? '' : ' Provider: $provider.';
      return '${_describeCodexProfile(selected)}$providerText Model discovery will use this profile first.';
    }
    final unresolvedProfile = _profileToSubmit;
    if (unresolvedProfile != null) {
      return 'Profile $unresolvedProfile is selected but has not been resolved from the current workspace config yet.';
    }
    if (_defaultProfileName != null) {
      return 'No profile override. Codex will inherit workspace default profile $_defaultProfileName.';
    }
    if (_currentCwd == null) {
      return 'Enter a working directory first to discover Codex profiles.';
    }
    if (_profilesLoadedForCwd == _currentCwd && _profiles.isEmpty) {
      return 'No named profiles were found for this workspace. Codex will use the host config.';
    }
    return 'Choose a discovered Codex profile before picking a model, or keep the host config.';
  }

  String? get _reasoningToSubmit {
    if (_controlModelIsAuto) return null;
    return _trimmedOrNull(_reasoningEffort);
  }

  String? get _currentCwd => _trimmedOrNull(_cwdController.text);

  String? get _profileToSubmit => _trimmedOrNull(_profileController.text);

  CodexProfileSummary? get _selectedProfile {
    final name = _profileToSubmit;
    if (name == null) return null;
    for (final profile in _profiles) {
      if (profile.name == name) {
        return profile;
      }
    }
    return null;
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
      if (_showAdvanced && !_loadingModels) {
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
      _profiles = const <CodexProfileSummary>[];
      _profilesError = null;
      _defaultProfileName = null;
      _profilesLoadedForCwd = null;
    });
    if (_showAdvanced && cwd != null && !_loadingProfiles) {
      unawaited(_loadProfiles());
    }
  }

  Future<void> _loadModels({bool force = false}) async {
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
                  ? 'Codex did not return any models for this host.'
                  : 'Codex did not return any models for profile $profile.'
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
    final cwd = _currentCwd;
    if (cwd == null) {
      setState(() {
        _profiles = const <CodexProfileSummary>[];
        _profilesError =
            'Enter a working directory to load workspace-aware Codex profiles.';
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
      final catalog = await widget.api.fetchProfiles(widget.host, cwd: cwd);
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
      }
    }

    if (!model.supportsFastMode) {
      _fastMode = false;
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
        (_modelsLoadedForCwd != _currentCwd ||
            _modelsLoadedForProfile != _profileToSubmit ||
            _models.isEmpty) &&
        !_loadingModels) {
      unawaited(_loadModels());
    }
    if (_showAdvanced &&
        _currentCwd != null &&
        _profilesLoadedForCwd == null &&
        !_loadingProfiles) {
      unawaited(_loadProfiles());
    }
  }

  Future<void> _chooseProfile() async {
    if (_loadingProfiles) return;
    if (_currentCwd == null) {
      setState(() {
        _profilesError =
            'Enter a working directory to load workspace-aware Codex profiles.';
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
      ),
    );
    if (!mounted || result == null) return;

    setState(() {
      _selectProfile(result.profileName);
    });
    unawaited(_loadModels(force: true));
  }

  Future<void> _chooseModel() async {
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
        profile: _profileToSubmit,
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
                title: 'Profile',
                icon: Icons.badge_outlined,
                value: _profileLabel,
                subtitle: _profileDescription,
                loading: _loadingProfiles,
                error: _profilesError,
                compact: true,
                badges: _profileBadges(),
                retryLabel: 'Retry loading profiles',
                onTap: _chooseProfile,
                onRetry: () => unawaited(_loadProfiles(force: true)),
              ),
              const SizedBox(height: 10),
              _ModelSelectionCard(
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
            title: 'Network',
            children: [
              _CompactSwitchRow(
                icon: Icons.public_rounded,
                title: 'Live web search',
                subtitle: 'Starts the thread with Codex web search enabled.',
                value: _webSearch,
                enabled: !_submitting,
                onChanged: (value) => setState(() => _webSearch = value),
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
        label: _profileLabel,
        icon: Icons.badge_outlined,
        tone: _profileToSubmit == null
            ? MeshPillTone.neutral
            : MeshPillTone.accent,
      ),
      MeshPill(
        label: _modelLabel,
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
                Icon(icon, size: 16, color: colors.textSecondary),
                const SizedBox(width: 8),
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

class _ProfilePickerSheet extends StatefulWidget {
  const _ProfilePickerSheet({
    required this.profiles,
    required this.currentProfile,
    required this.defaultProfile,
    required this.loadError,
  });

  final List<CodexProfileSummary> profiles;
  final String? currentProfile;
  final String? defaultProfile;
  final String? loadError;

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
            _describeCodexProfile(profile),
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
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Pick a Codex config profile first. The model picker will then load models from that profile\'s provider when possible.',
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
                                ? 'Do not send a profile override. Codex will use the host config.'
                                : 'Do not send a profile override. Codex will inherit workspace default profile ${widget.defaultProfile}.',
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
  });

  final List<ModelCatalogEntry> models;
  final String? currentModel;
  final CodexProfileSummary? profile;
  final String? profileName;
  final ModelCatalogEntry? inheritedModel;

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
              widget.profileName == null
                  ? 'Leave the model unset to inherit this host\'s Codex config, or choose a model for this new session.'
                  : 'Models are scoped to profile ${widget.profileName}. Leave unset to let Codex use that profile default.',
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
                                ? 'Do not send a model override. Codex will use the host or workspace Codex config.'
                                : _profileModelInheritDescription(
                                    profileName,
                                    widget.profile,
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
  if (model.isProfileModel) return 4;
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

String _describeCodexProfile(CodexProfileSummary profile) {
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
    return 'is a named Codex config preset.';
  }
  return 'sets ${parts.join(', ')}.';
}

String? _profileProviderLabel(CodexProfileSummary profile) =>
    _trimmedOrNull(profile.modelProviderName) ??
    _trimmedOrNull(profile.modelProvider);

String _profilePickerDescription(CodexProfileSummary profile) {
  final provider = _profileProviderLabel(profile);
  final providerText = provider == null ? '' : ' Provider: $provider.';
  final baseUrl = _trimmedOrNull(profile.modelProviderBaseUrl);
  final baseUrlText = baseUrl == null ? '' : ' $baseUrl';
  return '${_describeCodexProfile(profile)}$providerText$baseUrlText';
}

String _profileModelInheritDescription(
  String profileName,
  CodexProfileSummary? profile,
) {
  final profileModel = _trimmedOrNull(profile?.model);
  if (profileModel != null) {
    return 'Do not send a model override. Codex will use profile $profileName\'s configured model $profileModel.';
  }
  return 'Do not send a model override. Codex will use profile $profileName and its provider defaults.';
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
