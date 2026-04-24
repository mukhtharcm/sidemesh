class HostProfile {
  const HostProfile({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.token,
  });

  final String id;
  final String label;
  final String baseUrl;
  final String token;

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'baseUrl': baseUrl,
    'token': token,
  };

  factory HostProfile.fromJson(Map<String, dynamic> json) => HostProfile(
    id: json['id'] as String,
    label: json['label'] as String,
    baseUrl: json['baseUrl'] as String,
    token: json['token'] as String,
  );
}

class NodeInfo {
  const NodeInfo({
    required this.label,
    required this.hostname,
    required this.platform,
    required this.codexVersion,
  });

  final String label;
  final String hostname;
  final String platform;
  final String codexVersion;

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
    label: _stringValue(json['label']),
    hostname: _stringValue(json['hostname']),
    platform: _stringValue(json['platform']),
    codexVersion: _stringValue(json['codexVersion']),
  );
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
    required this.status,
    required this.runtime,
  });

  final String id;
  final String title;
  final String preview;
  final String cwd;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String source;
  final String status;
  final SessionRuntimeSummary? runtime;

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
    status: _stringValue(json['status']),
    runtime: json['runtime'] is Map<String, dynamic>
        ? SessionRuntimeSummary.fromJson(
            json['runtime'] as Map<String, dynamic>,
          )
        : null,
  );
}

class SessionRuntimeSummary {
  const SessionRuntimeSummary({
    this.model,
    this.reasoningEffort,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.summaryMode,
    this.personality,
    this.updatedAt,
  });

  final String? model;
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
    required this.changes,
    required this.diff,
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
  final List<SessionActivityChange> changes;
  final String? diff;
  final String? revisedPrompt;
  final String? savedPath;

  bool get isCommand => type == 'command';
  bool get isFileChange => type == 'file_change';
  bool get isTurnDiff => type == 'turn_diff';
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
        changes: (json['changes'] as List<dynamic>? ?? [])
            .map(
              (item) =>
                  SessionActivityChange.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        diff: _stringOrNull(json['diff']),
        revisedPrompt: _stringOrNull(json['revisedPrompt']),
        savedPath: _stringOrNull(json['savedPath']),
      );
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
