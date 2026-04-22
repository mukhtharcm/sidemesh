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

class SessionMessage {
  const SessionMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.phase,
  });

  final String id;
  final String role;
  final String text;
  final DateTime createdAt;
  final String? phase;

  factory SessionMessage.fromJson(Map<String, dynamic> json) => SessionMessage(
    id: _stringValue(json['id']),
    role: _stringValue(json['role']),
    text: _stringValue(json['text']),
    createdAt: _dateValue(json['createdAt']),
    phase: json['phase'] as String?,
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
    required this.pendingAction,
  });

  final SessionSummary session;
  final List<SessionMessage> messages;
  final PendingAction? pendingAction;

  factory SessionLog.fromJson(Map<String, dynamic> json) => SessionLog(
    session: SessionSummary.fromJson(json['session'] as Map<String, dynamic>),
    messages: (json['messages'] as List<dynamic>? ?? [])
        .map((item) => SessionMessage.fromJson(item as Map<String, dynamic>))
        .toList(),
    pendingAction: json['pendingAction'] == null
        ? null
        : PendingAction.fromJson(json['pendingAction'] as Map<String, dynamic>),
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
    this.turnId,
    this.delta,
    this.status,
    this.action,
    this.actionId,
    this.message,
  });

  final String type;
  final String sessionId;
  final String? turnId;
  final String? delta;
  final String? status;
  final PendingAction? action;
  final String? actionId;
  final String? message;

  factory LiveEvent.fromJson(Map<String, dynamic> json) => LiveEvent(
    type: _stringValue(json['type']),
    sessionId: _stringValue(json['sessionId']),
    turnId: json['turnId'] as String?,
    delta: json['delta'] as String?,
    status: json['status'] as String?,
    action: json['action'] == null
        ? null
        : PendingAction.fromJson(json['action'] as Map<String, dynamic>),
    actionId: json['actionId'] as String?,
    message: json['message'] as String?,
  );
}

String _stringValue(Object? value) => value is String ? value : '';

int _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return 0;
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
