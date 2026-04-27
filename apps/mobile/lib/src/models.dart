class HostProfile {
  const HostProfile({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.token,
    this.enabled = true,
  });

  final String id;
  final String label;
  final String baseUrl;
  final String token;
  final bool enabled;

  HostProfile copyWith({
    String? id,
    String? label,
    String? baseUrl,
    String? token,
    bool? enabled,
  }) {
    return HostProfile(
      id: id ?? this.id,
      label: label ?? this.label,
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'baseUrl': baseUrl,
    'token': token,
    'enabled': enabled,
  };

  factory HostProfile.fromJson(Map<String, dynamic> json) => HostProfile(
    id: json['id'] as String,
    label: json['label'] as String,
    baseUrl: json['baseUrl'] as String,
    token: json['token'] as String,
    enabled: json['enabled'] != false,
  );
}

class NodeInfo {
  const NodeInfo({
    required this.label,
    required this.hostname,
    required this.platform,
    required this.codexVersion,
    required this.provider,
    required this.providerName,
    required this.providerVersion,
    required this.providerConfig,
    required this.providerCapabilities,
    required this.hostCapabilities,
    required this.supportedProviders,
  });

  final String label;
  final String hostname;
  final String platform;
  final String codexVersion;
  final String provider;
  final String providerName;
  final String providerVersion;
  final ProviderConfigSummary providerConfig;
  final ProviderCapabilities providerCapabilities;
  final ProviderCapabilities hostCapabilities;
  final List<ProviderDefinitionSummary> supportedProviders;

  String get providerDisplayName {
    if (providerName.isNotEmpty) return providerName;
    if (provider.isNotEmpty) return provider;
    return 'Codex';
  }

  String get providerDisplayVersion {
    if (providerVersion.isNotEmpty) return providerVersion;
    return codexVersion;
  }

  String get providerPillLabel {
    final version = providerDisplayVersion;
    if (version.isEmpty) return providerDisplayName;
    return '$providerDisplayName $version';
  }

  bool supportsHostCapability(String section, String feature) {
    return hostCapabilities.supports(section, feature);
  }

  ProviderDefinitionSummary providerSummary(String? kind) {
    if ((kind ?? '').isEmpty) {
      return supportedProviders.firstWhere(
        (provider) => provider.kind == providerConfig.kind,
        orElse: () => ProviderDefinitionSummary.empty,
      );
    }
    return supportedProviders.firstWhere(
      (provider) => provider.kind == kind,
      orElse: () => ProviderDefinitionSummary.empty,
    );
  }

  ProviderCapabilities capabilitiesForProvider(String? kind) {
    final summary = providerSummary(kind);
    if (!summary.capabilities.isEmpty) {
      return summary.capabilities;
    }
    if ((kind ?? '').isEmpty || kind == provider) {
      return providerCapabilities;
    }
    return ProviderCapabilities.empty;
  }

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
    label: _stringValue(json['label']),
    hostname: _stringValue(json['hostname']),
    platform: _stringValue(json['platform']),
    codexVersion: _stringValue(json['codexVersion']),
    provider: _stringOrNull(json['provider']) ?? 'codex',
    providerName: _stringOrNull(json['providerName']) ?? 'Codex',
    providerVersion:
        _stringOrNull(json['providerVersion']) ??
        _stringValue(json['codexVersion']),
    providerConfig: ProviderConfigSummary.fromJson(json['providerConfig']),
    providerCapabilities: ProviderCapabilities.fromJson(
      json['providerCapabilities'],
    ),
    hostCapabilities: ProviderCapabilities.fromJson(json['hostCapabilities']),
    supportedProviders: ProviderDefinitionSummary.listFromJson(
      json['supportedProviders'],
    ),
  );
}

class ProviderMetadata {
  const ProviderMetadata({
    required this.currentProvider,
    required this.providers,
  });

  final String currentProvider;
  final List<ProviderDefinitionSummary> providers;

  factory ProviderMetadata.fromJson(Map<String, dynamic> json) =>
      ProviderMetadata(
        currentProvider: _stringValue(json['currentProvider']),
        providers: ProviderDefinitionSummary.listFromJson(json['providers']),
      );
}

class ProviderDefinitionSummary {
  const ProviderDefinitionSummary({
    required this.kind,
    required this.displayName,
    required this.defaultCommand,
    required this.commandEnvironmentVariables,
    required this.capabilities,
    required this.config,
    required this.version,
    required this.isDefault,
  });

  static const empty = ProviderDefinitionSummary(
    kind: '',
    displayName: '',
    defaultCommand: '',
    commandEnvironmentVariables: <String>[],
    capabilities: ProviderCapabilities.empty,
    config: ProviderConfigSummary.empty,
    version: '',
    isDefault: false,
  );

  final String kind;
  final String displayName;
  final String defaultCommand;
  final List<String> commandEnvironmentVariables;
  final ProviderCapabilities capabilities;
  final ProviderConfigSummary config;
  final String version;
  final bool isDefault;

  factory ProviderDefinitionSummary.fromJson(Object? json) {
    if (json is! Map) return empty;
    return ProviderDefinitionSummary(
      kind: _stringValue(json['kind']),
      displayName: _stringValue(json['displayName']),
      defaultCommand: _stringValue(json['defaultCommand']),
      commandEnvironmentVariables:
          (json['commandEnvironmentVariables'] as List<dynamic>? ?? const [])
              .map(_stringValue)
              .where((value) => value.isNotEmpty)
              .toList(),
      capabilities: ProviderCapabilities.fromJson(json['capabilities']),
      config: ProviderConfigSummary.fromJson(json['config']),
      version: _stringOrNull(json['version']) ?? '',
      isDefault: json['isDefault'] == true,
    );
  }

  static List<ProviderDefinitionSummary> listFromJson(Object? json) {
    if (json is! List) return const [];
    return json
        .map(ProviderDefinitionSummary.fromJson)
        .where((provider) => provider.kind.isNotEmpty)
        .toList();
  }
}

class ProviderConfigSummary {
  const ProviderConfigSummary({required this.kind, required this.command});

  static const empty = ProviderConfigSummary(kind: '', command: null);

  final String kind;
  final String? command;

  factory ProviderConfigSummary.fromJson(Object? json) {
    if (json is! Map) return empty;
    return ProviderConfigSummary(
      kind: _stringValue(json['kind']),
      command: _stringOrNull(json['command']),
    );
  }
}

class ProviderCapabilities {
  const ProviderCapabilities(this.values);

  static const empty = ProviderCapabilities(<String, dynamic>{});

  final Map<String, dynamic> values;

  bool get isEmpty => values.isEmpty;

  bool supports(String section, String feature) {
    final rawSection = values[section];
    if (rawSection is! Map) return false;
    return rawSection[feature] == true;
  }

  factory ProviderCapabilities.fromJson(Object? json) {
    if (json is! Map) return empty;
    return ProviderCapabilities(
      Map<String, dynamic>.fromEntries(
        json.entries.map(
          (entry) => MapEntry(entry.key.toString(), entry.value),
        ),
      ),
    );
  }
}

class GitInfoSummary {
  const GitInfoSummary({this.sha, this.branch, this.originUrl});

  final String? sha;
  final String? branch;
  final String? originUrl;

  bool get isEmpty =>
      (sha ?? '').isEmpty &&
      (branch ?? '').isEmpty &&
      (originUrl ?? '').isEmpty;

  String? get shortSha {
    final value = sha;
    if (value == null || value.isEmpty) return null;
    return value.length <= 12 ? value : value.substring(0, 12);
  }

  factory GitInfoSummary.fromJson(Map<String, dynamic> json) => GitInfoSummary(
    sha: _stringOrNull(json['sha']),
    branch: _stringOrNull(json['branch']),
    originUrl: _stringOrNull(json['originUrl']),
  );

  Map<String, dynamic> toJson() => {
    'sha': sha,
    'branch': branch,
    'originUrl': originUrl,
  };
}

class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.preview,
    required this.cwd,
    required this.createdAt,
    required this.updatedAt,
    required this.source,
    required this.provider,
    required this.status,
    required this.runtime,
    required this.gitInfo,
  });

  final String id;
  final String title;
  final String preview;
  final String cwd;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String source;
  final String? provider;
  final String status;
  final SessionRuntimeSummary? runtime;
  final GitInfoSummary? gitInfo;

  /// Older Sidemesh builds used `running`, while Codex app-server reports
  /// active threads as `active`.
  bool get isActive => status == 'active' || status == 'running';

  factory SessionSummary.fromJson(Map<String, dynamic> json) => SessionSummary(
    id: _stringValue(json['id']),
    title: _stringValue(json['title']),
    preview: _stringValue(json['preview']),
    cwd: _stringValue(json['cwd']),
    createdAt: _dateValue(json['createdAt']),
    updatedAt: _dateValue(json['updatedAt']),
    source: _stringValue(json['source']),
    provider: _stringOrNull(json['provider']),
    status: _stringValue(json['status']),
    runtime: json['runtime'] is Map<String, dynamic>
        ? SessionRuntimeSummary.fromJson(
            json['runtime'] as Map<String, dynamic>,
          )
        : null,
    gitInfo: json['gitInfo'] is Map<String, dynamic>
        ? GitInfoSummary.fromJson(json['gitInfo'] as Map<String, dynamic>)
        : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'preview': preview,
    'cwd': cwd,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'source': source,
    'provider': provider,
    'status': status,
    'runtime': runtime?.toJson(),
    'gitInfo': gitInfo?.toJson(),
  };
}

class SessionRuntimeSummary {
  const SessionRuntimeSummary({
    this.model,
    this.modelProvider,
    this.serviceTier,
    this.reasoningEffort,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.summaryMode,
    this.personality,
    this.updatedAt,
  });

  final String? model;
  final String? modelProvider;
  final String? serviceTier;
  final String? reasoningEffort;
  final String? approvalPolicy;
  final String? sandboxMode;
  final bool? networkAccess;
  final String? summaryMode;
  final String? personality;
  final DateTime? updatedAt;

  factory SessionRuntimeSummary.fromJson(Map<String, dynamic> json) =>
      SessionRuntimeSummary(
        model: json['model'] as String?,
        modelProvider: json['modelProvider'] as String?,
        serviceTier: json['serviceTier'] as String?,
        reasoningEffort: json['reasoningEffort'] as String?,
        approvalPolicy: json['approvalPolicy'] as String?,
        sandboxMode: json['sandboxMode'] as String?,
        networkAccess: json['networkAccess'] as bool?,
        summaryMode: json['summaryMode'] as String?,
        personality: json['personality'] as String?,
        updatedAt: json['updatedAt'] == null
            ? null
            : _dateValue(json['updatedAt']),
      );

  Map<String, dynamic> toJson() => {
    'model': model,
    'modelProvider': modelProvider,
    'serviceTier': serviceTier,
    'reasoningEffort': reasoningEffort,
    'approvalPolicy': approvalPolicy,
    'sandboxMode': sandboxMode,
    'networkAccess': networkAccess,
    'summaryMode': summaryMode,
    'personality': personality,
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
  };
}

class SessionGitFileStatus {
  const SessionGitFileStatus({
    required this.path,
    required this.originalPath,
    required this.indexStatus,
    required this.worktreeStatus,
  });

  final String path;
  final String? originalPath;
  final String indexStatus;
  final String worktreeStatus;

  bool get isUntracked => indexStatus == '?' && worktreeStatus == '?';
  bool get isStaged => indexStatus.trim().isNotEmpty && indexStatus != '?';
  bool get isUnstaged =>
      worktreeStatus.trim().isNotEmpty && worktreeStatus != '?';

  factory SessionGitFileStatus.fromJson(Map<String, dynamic> json) =>
      SessionGitFileStatus(
        path: _stringValue(json['path']),
        originalPath: _stringOrNull(json['originalPath']),
        indexStatus: _stringValue(json['indexStatus']),
        worktreeStatus: _stringValue(json['worktreeStatus']),
      );
}

class SessionGitStatus {
  const SessionGitStatus({
    required this.isRepo,
    required this.cwd,
    required this.repoRoot,
    required this.branch,
    required this.sha,
    required this.shortSha,
    required this.upstream,
    required this.ahead,
    required this.behind,
    required this.dirty,
    required this.staged,
    required this.unstaged,
    required this.untracked,
    required this.changed,
    required this.originUrl,
    required this.files,
    required this.filesTruncated,
    required this.refreshedAt,
    required this.error,
  });

  final bool isRepo;
  final String cwd;
  final String? repoRoot;
  final String? branch;
  final String? sha;
  final String? shortSha;
  final String? upstream;
  final int ahead;
  final int behind;
  final bool dirty;
  final int staged;
  final int unstaged;
  final int untracked;
  final int changed;
  final String? originUrl;
  final List<SessionGitFileStatus> files;
  final bool filesTruncated;
  final DateTime refreshedAt;
  final String? error;

  factory SessionGitStatus.fromJson(Map<String, dynamic> json) =>
      SessionGitStatus(
        isRepo: _boolValue(json['isRepo']),
        cwd: _stringValue(json['cwd']),
        repoRoot: _stringOrNull(json['repoRoot']),
        branch: _stringOrNull(json['branch']),
        sha: _stringOrNull(json['sha']),
        shortSha: _stringOrNull(json['shortSha']),
        upstream: _stringOrNull(json['upstream']),
        ahead: _intValue(json['ahead']),
        behind: _intValue(json['behind']),
        dirty: _boolValue(json['dirty']),
        staged: _intValue(json['staged']),
        unstaged: _intValue(json['unstaged']),
        untracked: _intValue(json['untracked']),
        changed: _intValue(json['changed']),
        originUrl: _stringOrNull(json['originUrl']),
        files: (json['files'] as List<dynamic>? ?? const [])
            .map(
              (item) =>
                  SessionGitFileStatus.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        filesTruncated: _boolValue(json['filesTruncated']),
        refreshedAt: _dateValue(json['refreshedAt']),
        error: _stringOrNull(json['error']),
      );
}

class SessionGitDiff {
  const SessionGitDiff({
    required this.kind,
    required this.diff,
    required this.baseSha,
    required this.truncated,
    required this.maxChars,
  });

  final String kind;
  final String diff;
  final String? baseSha;
  final bool truncated;
  final int maxChars;

  factory SessionGitDiff.fromJson(Map<String, dynamic> json) => SessionGitDiff(
    kind: _stringValue(json['kind']),
    diff: _stringValue(json['diff']),
    baseSha: _stringOrNull(json['baseSha']),
    truncated: _boolValue(json['truncated']),
    maxChars: _intValue(json['maxChars']),
  );
}

class WorkspaceSummary {
  const WorkspaceSummary({
    required this.cwd,
    required this.label,
    required this.sessionCount,
    required this.lastUsedAt,
  });

  final String cwd;
  final String label;
  final int sessionCount;
  final DateTime lastUsedAt;

  factory WorkspaceSummary.fromJson(Map<String, dynamic> json) =>
      WorkspaceSummary(
        cwd: _stringValue(json['cwd']),
        label: _stringValue(json['label']),
        sessionCount: _intValue(json['sessionCount']),
        lastUsedAt: _dateValue(json['lastUsedAt']),
      );
}

class SkillCatalog {
  const SkillCatalog({
    required this.cwd,
    required this.skills,
    required this.errors,
  });

  final String cwd;
  final List<SkillSummary> skills;
  final List<SkillErrorInfo> errors;

  factory SkillCatalog.fromJson(Map<String, dynamic> json) => SkillCatalog(
    cwd: _stringValue(json['cwd']),
    skills: (json['skills'] as List<dynamic>? ?? [])
        .map((item) => SkillSummary.fromJson(item as Map<String, dynamic>))
        .toList(),
    errors: (json['errors'] as List<dynamic>? ?? [])
        .map((item) => SkillErrorInfo.fromJson(item as Map<String, dynamic>))
        .toList(),
  );
}

class SkillInterfaceSummary {
  const SkillInterfaceSummary({
    this.displayName,
    this.shortDescription,
    this.brandColor,
    this.defaultPrompt,
  });

  final String? displayName;
  final String? shortDescription;
  final String? brandColor;
  final String? defaultPrompt;

  factory SkillInterfaceSummary.fromJson(Map<String, dynamic> json) =>
      SkillInterfaceSummary(
        displayName: _stringOrNull(json['displayName']),
        shortDescription: _stringOrNull(json['shortDescription']),
        brandColor: _stringOrNull(json['brandColor']),
        defaultPrompt: _stringOrNull(json['defaultPrompt']),
      );
}

class SkillSummary {
  const SkillSummary({
    required this.name,
    required this.description,
    required this.path,
    required this.scope,
    required this.enabled,
    this.shortDescription,
    this.interface,
  });

  final String name;
  final String description;
  final String? shortDescription;
  final SkillInterfaceSummary? interface;
  final String path;
  final String scope;
  final bool enabled;

  String get displayName {
    final interfaceName = interface?.displayName?.trim();
    if (interfaceName != null && interfaceName.isNotEmpty) {
      return interfaceName;
    }
    final parts = name.split(':');
    if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[1]} (${parts[0]})';
    }
    return name;
  }

  String get summaryDescription {
    final interfaceSummary = interface?.shortDescription?.trim();
    if (interfaceSummary != null && interfaceSummary.isNotEmpty) {
      return interfaceSummary;
    }
    final legacySummary = shortDescription?.trim();
    if (legacySummary != null && legacySummary.isNotEmpty) {
      return legacySummary;
    }
    return description;
  }

  String get mentionToken => '\$$name';

  String get scopeLabel => switch (scope) {
    'repo' => 'workspace',
    'user' => 'user',
    'system' => 'system',
    'admin' => 'admin',
    _ => scope.isEmpty ? 'skill' : scope,
  };

  int get scopeRank => switch (scope) {
    'repo' => 0,
    'user' => 1,
    'system' => 2,
    'admin' => 3,
    _ => 4,
  };

  factory SkillSummary.fromJson(Map<String, dynamic> json) => SkillSummary(
    name: _stringValue(json['name']),
    description: _stringValue(json['description']),
    shortDescription: _stringOrNull(json['shortDescription']),
    interface: json['interface'] is Map<String, dynamic>
        ? SkillInterfaceSummary.fromJson(
            json['interface'] as Map<String, dynamic>,
          )
        : null,
    path: _stringValue(json['path']),
    scope: _stringValue(json['scope']),
    enabled: _boolValue(json['enabled']),
  );
}

class SkillErrorInfo {
  const SkillErrorInfo({required this.path, required this.message});

  final String path;
  final String message;

  factory SkillErrorInfo.fromJson(Map<String, dynamic> json) => SkillErrorInfo(
    path: _stringValue(json['path']),
    message: _stringValue(json['message']),
  );
}

class ModelCatalogEntry {
  const ModelCatalogEntry({
    required this.id,
    required this.model,
    required this.displayName,
    required this.description,
    required this.defaultReasoningEffort,
    required this.supportedReasoningEfforts,
    required this.reasoningEffortControl,
    required this.supportsPersonality,
    required this.additionalSpeedTiers,
    required this.inputModalities,
    required this.isDefault,
    this.sortOrder,
    this.source,
    this.profileName,
  });

  final String id;
  final String model;
  final String displayName;
  final String description;
  final String defaultReasoningEffort;
  final List<ModelReasoningEffortOption> supportedReasoningEfforts;
  final String reasoningEffortControl;
  final bool supportsPersonality;
  final List<String> additionalSpeedTiers;
  final List<String> inputModalities;
  final bool isDefault;
  final int? sortOrder;
  final String? source;
  final String? profileName;

  bool get supportsFastMode => additionalSpeedTiers.contains('fast');
  bool get isAutoModel => reasoningEffortControl == 'provider';
  bool get isProfileModel => source == 'profile';

  factory ModelCatalogEntry.fromJson(
    Map<String, dynamic> json,
  ) => ModelCatalogEntry(
    id: _stringValue(json['id']),
    model: _stringValue(json['model']),
    displayName: _stringValue(json['displayName']),
    description: _stringValue(json['description']),
    defaultReasoningEffort: _stringValue(json['defaultReasoningEffort']),
    supportedReasoningEfforts:
        (json['supportedReasoningEfforts'] as List<dynamic>? ?? [])
            .map(
              (item) => ModelReasoningEffortOption.fromJson(
                item as Map<String, dynamic>,
              ),
            )
            .toList(),
    reasoningEffortControl:
        _stringOrNull(json['reasoningEffortControl']) ?? 'client',
    supportsPersonality: _boolValue(json['supportsPersonality']),
    additionalSpeedTiers: (json['additionalSpeedTiers'] as List<dynamic>? ?? [])
        .map(_stringValue)
        .toList(),
    inputModalities: (json['inputModalities'] as List<dynamic>? ?? [])
        .map(_stringValue)
        .toList(),
    isDefault: _boolValue(json['isDefault']),
    sortOrder: _intOrNull(json['sortOrder']),
    source: _stringOrNull(json['source']),
    profileName: _stringOrNull(json['profileName']),
  );
}

class ModelReasoningEffortOption {
  const ModelReasoningEffortOption({
    required this.reasoningEffort,
    required this.description,
  });

  final String reasoningEffort;
  final String description;

  factory ModelReasoningEffortOption.fromJson(Map<String, dynamic> json) =>
      ModelReasoningEffortOption(
        reasoningEffort: _stringValue(json['reasoningEffort']),
        description: _stringValue(json['description']),
      );
}

class ProviderProfileCatalog {
  const ProviderProfileCatalog({
    required this.defaultProfile,
    required this.profiles,
  });

  final String? defaultProfile;
  final List<ProviderProfileSummary> profiles;

  factory ProviderProfileCatalog.fromJson(Map<String, dynamic> json) =>
      ProviderProfileCatalog(
        defaultProfile: _stringOrNull(json['defaultProfile']),
        profiles: (json['profiles'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(ProviderProfileSummary.fromJson)
            .toList(),
      );
}

class ProviderProfileSummary {
  const ProviderProfileSummary({
    required this.name,
    required this.isDefault,
    this.model,
    this.modelProvider,
    this.modelProviderName,
    this.modelProviderBaseUrl,
    this.approvalPolicy,
    this.sandboxMode,
    this.serviceTier,
    this.reasoningEffort,
    this.reasoningSummary,
    this.verbosity,
    this.webSearch,
    this.personality,
  });

  final String name;
  final bool isDefault;
  final String? model;
  final String? modelProvider;
  final String? modelProviderName;
  final String? modelProviderBaseUrl;
  final String? approvalPolicy;
  final String? sandboxMode;
  final String? serviceTier;
  final String? reasoningEffort;
  final String? reasoningSummary;
  final String? verbosity;
  final String? webSearch;
  final String? personality;

  factory ProviderProfileSummary.fromJson(Map<String, dynamic> json) =>
      ProviderProfileSummary(
        name: _stringValue(json['name']),
        isDefault: _boolValue(json['isDefault']),
        model: _stringOrNull(json['model']),
        modelProvider: _stringOrNull(json['modelProvider']),
        modelProviderName: _stringOrNull(json['modelProviderName']),
        modelProviderBaseUrl: _stringOrNull(json['modelProviderBaseUrl']),
        approvalPolicy: _stringOrNull(json['approvalPolicy']),
        sandboxMode: _stringOrNull(json['sandboxMode']),
        serviceTier: _stringOrNull(json['serviceTier']),
        reasoningEffort: _stringOrNull(json['reasoningEffort']),
        reasoningSummary: _stringOrNull(json['reasoningSummary']),
        verbosity: _stringOrNull(json['verbosity']),
        webSearch: _stringOrNull(json['webSearch']),
        personality: _stringOrNull(json['personality']),
      );
}

class SessionMessage {
  const SessionMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.attachments,
    required this.createdAt,
    required this.seq,
    this.phase,
  });

  final String id;
  final String role;
  final String text;
  final List<SessionMessageAttachment> attachments;
  final DateTime createdAt;
  final int seq;
  final String? phase;

  bool get hasVisibleContent =>
      text.trim().isNotEmpty || attachments.isNotEmpty;

  factory SessionMessage.fromJson(Map<String, dynamic> json) => SessionMessage(
    id: _stringValue(json['id']),
    role: _stringValue(json['role']),
    text: _stringValue(json['text']),
    attachments: (json['attachments'] as List<dynamic>? ?? [])
        .map(
          (item) =>
              SessionMessageAttachment.fromJson(item as Map<String, dynamic>),
        )
        .toList(),
    createdAt: _dateValue(json['createdAt']),
    seq: _intOrNull(json['seq']) ?? 0,
    phase: json['phase'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'text': text,
    'attachments': attachments.map((item) => item.toJson()).toList(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'seq': seq,
    'phase': phase,
  };
}

class SessionMessageAttachment {
  const SessionMessageAttachment({required this.type, this.url, this.path});

  final String type;
  final String? url;
  final String? path;

  bool get isImage => type == 'image' && (url?.isNotEmpty ?? false);
  bool get isLocalImage => type == 'localImage' && (path?.isNotEmpty ?? false);

  factory SessionMessageAttachment.fromJson(Map<String, dynamic> json) =>
      SessionMessageAttachment(
        type: _stringValue(json['type']),
        url: _stringOrNull(json['url']),
        path: _stringOrNull(json['path']),
      );

  Map<String, dynamic> toJson() => {'type': type, 'url': url, 'path': path};
}

class SessionResource {
  const SessionResource({
    required this.id,
    required this.kind,
    required this.source,
    required this.createdAt,
    required this.title,
    required this.subtitle,
    required this.url,
    required this.path,
    required this.messageId,
    required this.activityId,
  });

  final String id;
  final String kind;
  final String source;
  final DateTime createdAt;
  final String title;
  final String? subtitle;
  final String? url;
  final String? path;
  final String? messageId;
  final String? activityId;

  bool get isImage => kind == 'image';
  bool get isLink => kind == 'link' && (url?.isNotEmpty ?? false);
  bool get isFile => kind == 'file';
  bool get hasPath => path?.isNotEmpty ?? false;

  factory SessionResource.fromJson(Map<String, dynamic> json) =>
      SessionResource(
        id: _stringValue(json['id']),
        kind: _stringValue(json['kind']),
        source: _stringValue(json['source']),
        createdAt: _dateValue(json['createdAt']),
        title: _stringValue(json['title']),
        subtitle: _stringOrNull(json['subtitle']),
        url: _stringOrNull(json['url']),
        path: _stringOrNull(json['path']),
        messageId: _stringOrNull(json['messageId']),
        activityId: _stringOrNull(json['activityId']),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'source': source,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'title': title,
    'subtitle': subtitle,
    'url': url,
    'path': path,
    'messageId': messageId,
    'activityId': activityId,
  };
}

class SessionResourcesResponse {
  const SessionResourcesResponse({
    required this.sessionId,
    required this.updatedAt,
    required this.resources,
  });

  final String sessionId;
  final DateTime updatedAt;
  final List<SessionResource> resources;

  factory SessionResourcesResponse.fromJson(Map<String, dynamic> json) =>
      SessionResourcesResponse(
        sessionId: _stringValue(json['sessionId']),
        updatedAt: _dateValue(json['updatedAt']),
        resources: (json['resources'] as List<dynamic>? ?? [])
            .map(
              (item) => SessionResource.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
      );
}

class SessionInputItem {
  const SessionInputItem._({
    required this.type,
    this.text,
    this.url,
    this.name,
    this.path,
  });

  const SessionInputItem.text(String text) : this._(type: 'text', text: text);

  const SessionInputItem.image(String url) : this._(type: 'image', url: url);

  const SessionInputItem.localImage(String path)
    : this._(type: 'localImage', path: path);

  const SessionInputItem.skill(String name, String path)
    : this._(type: 'skill', name: name, path: path);

  final String type;
  final String? text;
  final String? url;
  final String? name;
  final String? path;

  factory SessionInputItem.fromJson(Map<String, dynamic> json) {
    final type = _stringValue(json['type']);
    switch (type) {
      case 'text':
        return SessionInputItem.text(_stringValue(json['text']));
      case 'image':
        return SessionInputItem.image(_stringValue(json['url']));
      case 'localImage':
        return SessionInputItem.localImage(_stringValue(json['path']));
      case 'skill':
        return SessionInputItem.skill(
          _stringValue(json['name']),
          _stringValue(json['path']),
        );
      default:
        return SessionInputItem._(type: type);
    }
  }

  Map<String, dynamic> toJson() {
    switch (type) {
      case 'text':
        return {
          'type': 'text',
          'text': text ?? '',
          'text_elements': const <dynamic>[],
        };
      case 'image':
        return {'type': 'image', 'url': url ?? ''};
      case 'localImage':
        return {'type': 'localImage', 'path': path ?? ''};
      case 'skill':
        return {'type': 'skill', 'name': name ?? '', 'path': path ?? ''};
      default:
        return {'type': type};
    }
  }
}

class SessionActivityChange {
  const SessionActivityChange({
    required this.path,
    required this.kind,
    required this.diff,
    this.movePath,
  });

  final String path;
  final String kind;
  final String diff;
  final String? movePath;

  factory SessionActivityChange.fromJson(Map<String, dynamic> json) =>
      SessionActivityChange(
        path: _stringValue(json['path']),
        kind: _stringValue(json['kind']),
        diff: _stringValue(json['diff']),
        movePath: _stringOrNull(json['movePath']),
      );

  Map<String, dynamic> toJson() => {
    'path': path,
    'kind': kind,
    'diff': diff,
    'movePath': movePath,
  };
}

class SessionCommandActionSummary {
  const SessionCommandActionSummary({required this.kind, required this.label});

  final String kind;
  final String label;

  factory SessionCommandActionSummary.fromJson(Map<String, dynamic> json) =>
      SessionCommandActionSummary(
        kind: _stringValue(json['kind']),
        label: _stringValue(json['label']),
      );

  Map<String, dynamic> toJson() => {'kind': kind, 'label': label};
}

class SessionActivity {
  const SessionActivity({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.seq,
    required this.status,
    required this.turnId,
    required this.command,
    required this.cwd,
    required this.output,
    required this.exitCode,
    required this.durationMs,
    required this.source,
    required this.processId,
    required this.commandActions,
    required this.terminalStatus,
    required this.terminalInput,
    required this.toolName,
    required this.toolTitle,
    required this.toolArgs,
    required this.toolResult,
    required this.toolError,
    required this.changes,
    required this.diff,
    required this.query,
    required this.queries,
    required this.targetUrl,
    required this.pattern,
    required this.revisedPrompt,
    required this.savedPath,
  });

  final String id;
  final String type;
  final DateTime createdAt;
  final int seq;
  final String status;
  final String? turnId;
  final String? command;
  final String? cwd;
  final String? output;
  final int? exitCode;
  final int? durationMs;
  final String? source;
  final String? processId;
  final List<SessionCommandActionSummary> commandActions;
  final String? terminalStatus;
  final String? terminalInput;
  final String? toolName;
  final String? toolTitle;
  final Object? toolArgs;
  final Object? toolResult;
  final bool? toolError;
  final List<SessionActivityChange> changes;
  final String? diff;
  final String? query;
  final List<String> queries;
  final String? targetUrl;
  final String? pattern;
  final String? revisedPrompt;
  final String? savedPath;

  bool get isCommand => type == 'command';
  bool get isTool => type == 'tool';
  bool get isFileChange => type == 'file_change';
  bool get isTurnDiff => type == 'turn_diff';
  bool get isWebSearch => type == 'web_search';
  bool get isImageGeneration => type == 'image_generation';

  factory SessionActivity.fromJson(Map<String, dynamic> json) =>
      SessionActivity(
        id: _stringValue(json['id']),
        type: _stringValue(json['type']),
        createdAt: _dateValue(json['createdAt']),
        seq: _intOrNull(json['seq']) ?? 0,
        status: _stringValue(json['status']),
        turnId: _stringOrNull(json['turnId']),
        command: _stringOrNull(json['command']),
        cwd: _stringOrNull(json['cwd']),
        output: _stringOrNull(json['output']),
        exitCode: _intOrNull(json['exitCode']),
        durationMs: _intOrNull(json['durationMs']),
        source: _stringOrNull(json['source']),
        processId: _stringOrNull(json['processId']),
        commandActions: (json['commandActions'] as List<dynamic>? ?? [])
            .map(
              (item) => SessionCommandActionSummary.fromJson(
                item as Map<String, dynamic>,
              ),
            )
            .toList(),
        terminalStatus: _stringOrNull(json['terminalStatus']),
        terminalInput: _stringOrNull(json['terminalInput']),
        toolName: _stringOrNull(json['toolName']),
        toolTitle: _stringOrNull(json['title']),
        toolArgs: json['args'],
        toolResult: json['result'],
        toolError: json['isError'] is bool ? json['isError'] as bool : null,
        changes: (json['changes'] as List<dynamic>? ?? [])
            .map(
              (item) =>
                  SessionActivityChange.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        diff: _stringOrNull(json['diff']),
        query: _stringOrNull(json['query']),
        queries: (json['queries'] as List<dynamic>? ?? const <dynamic>[])
            .map((item) => _stringValue(item))
            .where((item) => item.isNotEmpty)
            .toList(),
        targetUrl: _stringOrNull(json['targetUrl']),
        pattern: _stringOrNull(json['pattern']),
        revisedPrompt: _stringOrNull(json['revisedPrompt']),
        savedPath: _stringOrNull(json['savedPath']),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'seq': seq,
    'status': status,
    'turnId': turnId,
    'command': command,
    'cwd': cwd,
    'output': output,
    'exitCode': exitCode,
    'durationMs': durationMs,
    'source': source,
    'processId': processId,
    'commandActions': commandActions.map((item) => item.toJson()).toList(),
    'terminalStatus': terminalStatus,
    'terminalInput': terminalInput,
    'toolName': toolName,
    'title': toolTitle,
    'args': toolArgs,
    'result': toolResult,
    'isError': toolError,
    'changes': changes.map((item) => item.toJson()).toList(),
    'diff': diff,
    'query': query,
    'queries': queries,
    'targetUrl': targetUrl,
    'pattern': pattern,
    'revisedPrompt': revisedPrompt,
    'savedPath': savedPath,
  };
}

class PendingAction {
  const PendingAction({
    required this.id,
    required this.sessionId,
    required this.kind,
    required this.title,
    required this.detail,
    required this.requestedAt,
    required this.canApprove,
    required this.canApproveForSession,
    required this.canDecline,
    this.sessionTitle,
    this.cwd,
  });

  final String id;
  final String sessionId;
  final String kind;
  final String title;
  final String detail;
  final DateTime requestedAt;
  final bool canApprove;
  final bool canApproveForSession;
  final bool canDecline;
  final String? sessionTitle;
  final String? cwd;

  factory PendingAction.fromJson(Map<String, dynamic> json) => PendingAction(
    id: _stringValue(json['id']),
    sessionId: _stringValue(json['sessionId']),
    kind: _stringValue(json['kind']),
    title: _stringValue(json['title']),
    detail: _stringValue(json['detail']),
    requestedAt: _dateValue(json['requestedAt']),
    canApprove: _boolValue(json['canApprove']),
    canApproveForSession: _boolValue(json['canApproveForSession']),
    canDecline: _boolValue(json['canDecline']),
    sessionTitle: json['sessionTitle'] as String?,
    cwd: json['cwd'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'kind': kind,
    'title': title,
    'detail': detail,
    'requestedAt': requestedAt.millisecondsSinceEpoch,
    'canApprove': canApprove,
    'canApproveForSession': canApproveForSession,
    'canDecline': canDecline,
    'sessionTitle': sessionTitle,
    'cwd': cwd,
  };
}

class SessionLog {
  const SessionLog({
    required this.session,
    required this.messages,
    required this.activities,
    required this.pendingAction,
    required this.history,
  });

  final SessionSummary session;
  final List<SessionMessage> messages;
  final List<SessionActivity> activities;
  final PendingAction? pendingAction;
  final SessionLogHistorySummary? history;

  factory SessionLog.fromJson(Map<String, dynamic> json) => SessionLog(
    session: SessionSummary.fromJson(json['session'] as Map<String, dynamic>),
    messages: (json['messages'] as List<dynamic>? ?? [])
        .map((item) => SessionMessage.fromJson(item as Map<String, dynamic>))
        .toList(),
    activities: (json['activities'] as List<dynamic>? ?? [])
        .map((item) => SessionActivity.fromJson(item as Map<String, dynamic>))
        .toList(),
    pendingAction: json['pendingAction'] == null
        ? null
        : PendingAction.fromJson(json['pendingAction'] as Map<String, dynamic>),
    history: json['history'] == null
        ? null
        : SessionLogHistorySummary.fromJson(
            json['history'] as Map<String, dynamic>,
          ),
  );

  Map<String, dynamic> toJson() => {
    'session': session.toJson(),
    'messages': messages.map((item) => item.toJson()).toList(),
    'activities': activities.map((item) => item.toJson()).toList(),
    'pendingAction': pendingAction?.toJson(),
    'history': history?.toJson(),
  };
}

class SessionEventsDelta {
  const SessionEventsDelta({
    required this.sessionId,
    required this.since,
    required this.nextSeq,
    required this.messages,
    required this.activities,
    required this.pendingAction,
    required this.session,
  });

  final String sessionId;
  final int since;
  final int nextSeq;
  final List<SessionMessage> messages;
  final List<SessionActivity> activities;
  final PendingAction? pendingAction;
  final SessionSummary? session;

  factory SessionEventsDelta.fromJson(
    Map<String, dynamic> json,
  ) => SessionEventsDelta(
    sessionId: _stringValue(json['sessionId']),
    since: _intValue(json['since']),
    nextSeq: _intValue(json['nextSeq']),
    messages: (json['messages'] as List<dynamic>? ?? [])
        .map((item) => SessionMessage.fromJson(item as Map<String, dynamic>))
        .toList(),
    activities: (json['activities'] as List<dynamic>? ?? [])
        .map((item) => SessionActivity.fromJson(item as Map<String, dynamic>))
        .toList(),
    pendingAction: json['pendingAction'] == null
        ? null
        : PendingAction.fromJson(json['pendingAction'] as Map<String, dynamic>),
    session: json['session'] == null
        ? null
        : SessionSummary.fromJson(json['session'] as Map<String, dynamic>),
  );
}

class SessionLogHistorySummary {
  const SessionLogHistorySummary({
    required this.isTruncated,
    required this.totalMessages,
    required this.returnedMessages,
    required this.totalActivities,
    required this.returnedActivities,
  });

  final bool isTruncated;
  final int totalMessages;
  final int returnedMessages;
  final int totalActivities;
  final int returnedActivities;

  factory SessionLogHistorySummary.fromJson(Map<String, dynamic> json) =>
      SessionLogHistorySummary(
        isTruncated: _boolValue(json['isTruncated']),
        totalMessages: _intValue(json['totalMessages']),
        returnedMessages: _intValue(json['returnedMessages']),
        totalActivities: _intValue(json['totalActivities']),
        returnedActivities: _intValue(json['returnedActivities']),
      );

  Map<String, dynamic> toJson() => {
    'isTruncated': isTruncated,
    'totalMessages': totalMessages,
    'returnedMessages': returnedMessages,
    'totalActivities': totalActivities,
    'returnedActivities': returnedActivities,
  };
}

class SessionStatus {
  const SessionStatus({
    required this.sessionId,
    required this.isRunning,
    required this.activeTurnId,
    required this.pendingAction,
  });

  final String sessionId;
  final bool isRunning;
  final String? activeTurnId;
  final PendingAction? pendingAction;

  factory SessionStatus.fromJson(Map<String, dynamic> json) => SessionStatus(
    sessionId: _stringValue(json['sessionId']),
    isRunning: _boolValue(json['isRunning']),
    activeTurnId: json['activeTurnId'] as String?,
    pendingAction: json['pendingAction'] == null
        ? null
        : PendingAction.fromJson(json['pendingAction'] as Map<String, dynamic>),
  );
}

class RecentSessionsLiveEvent {
  const RecentSessionsLiveEvent({
    required this.type,
    this.sessions,
    this.session,
    this.sessionId,
    this.message,
  });

  final String type;
  final List<SessionSummary>? sessions;
  final SessionSummary? session;
  final String? sessionId;
  final String? message;

  factory RecentSessionsLiveEvent.fromJson(Map<String, dynamic> json) =>
      RecentSessionsLiveEvent(
        type: _stringValue(json['type']),
        sessions: json['sessions'] is List<dynamic>
            ? (json['sessions'] as List<dynamic>)
                  .whereType<Map<dynamic, dynamic>>()
                  .map(
                    (item) =>
                        SessionSummary.fromJson(item.cast<String, dynamic>()),
                  )
                  .toList(growable: false)
            : null,
        session: json['session'] is Map<dynamic, dynamic>
            ? SessionSummary.fromJson(
                (json['session'] as Map<dynamic, dynamic>)
                    .cast<String, dynamic>(),
              )
            : null,
        sessionId: json['sessionId'] as String?,
        message: json['message'] as String?,
      );
}

class LiveEvent {
  const LiveEvent({
    required this.type,
    required this.sessionId,
    this.seq,
    this.nextSeq,
    this.turnId,
    this.itemId,
    this.delta,
    this.status,
    this.action,
    this.actionId,
    this.message,
    this.messageItem,
    this.activity,
  });

  final String type;
  final String sessionId;
  final int? seq;
  final int? nextSeq;
  final String? turnId;
  final String? itemId;
  final String? delta;
  final String? status;
  final PendingAction? action;
  final String? actionId;
  final String? message;
  final SessionMessage? messageItem;
  final SessionActivity? activity;

  factory LiveEvent.fromJson(Map<String, dynamic> json) => LiveEvent(
    type: _stringValue(json['type']),
    sessionId: _stringValue(json['sessionId']),
    seq: _intOrNull(json['seq']),
    nextSeq: _intOrNull(json['nextSeq']),
    turnId: json['turnId'] as String?,
    itemId: json['itemId'] as String?,
    delta: json['delta'] as String?,
    status: json['status'] as String?,
    action: json['action'] == null
        ? null
        : PendingAction.fromJson(json['action'] as Map<String, dynamic>),
    actionId: json['actionId'] as String?,
    message: json['message'] as String?,
    messageItem: json['messageItem'] == null
        ? null
        : SessionMessage.fromJson(json['messageItem'] as Map<String, dynamic>),
    activity: json['activity'] == null
        ? null
        : SessionActivity.fromJson(json['activity'] as Map<String, dynamic>),
  );
}

String _stringValue(Object? value) => value is String ? value : '';

String? _stringOrNull(Object? value) {
  final normalized = _stringValue(value);
  return normalized.isEmpty ? null : normalized;
}

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return 0;
}

int? _intOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return null;
}

bool _boolValue(Object? value) => value == true;

DateTime _dateValue(Object? value) {
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
