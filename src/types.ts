export type AgentProviderKind = "codex" | "fake" | "copilot";

export type AgentProviderConfig =
  | CodexProviderConfig
  | FakeProviderConfig
  | CopilotProviderConfig;

export interface CodexProviderConfig {
  kind: "codex";
  bin: string;
}

export interface FakeProviderConfig {
  kind: "fake";
  latencyMs: number;
  seedSessions: boolean;
  workspaceRoot: string | null;
  capabilityProfile: FakeCapabilityProfile;
}

export interface CopilotProviderConfig {
  kind: "copilot";
  bin: string;
  stateDir: string | null;
  allowAll: boolean;
  configuredModel: string | null;
}

export type FakeCapabilityProfile =
  | "full"
  | "chat-only"
  | "no-files"
  | "no-model-controls"
  | "no-approvals"
  | "minimal";

export interface AgentProviderConfigSummary {
  kind: AgentProviderKind | string;
  command: string | null;
}

export interface HostTerminalConfig {
  enabled: boolean;
  shell: string | null;
  requirePty: boolean;
}

export interface HostPortForwardingConfig {
  enabled: boolean;
  allowNonLoopbackTargets: boolean;
}

export interface HostBrowserPreviewConfig {
  enabled: boolean;
  chromePath: string | null;
  maxPreviews: number;
  idleTtlMs: number;
  frameIntervalMs: number;
  quality: number;
}

export interface HostCapabilities {
  workspace: {
    filesystem: boolean;
    gitStatus: boolean;
    gitDiff: boolean;
    terminal: boolean;
    portForwarding: boolean;
    browserPreview: boolean;
  };
}

export interface NodeConfig {
  label: string;
  port: number;
  token: string;
  tokenSource: "env" | "file" | "generated";
  provider: AgentProviderConfig;
  providers: AgentProviderConfig[];
  defaultProviderKind: AgentProviderKind;
  stateDir: string;
  terminal: HostTerminalConfig;
  portForwarding: HostPortForwardingConfig;
  browserPreview: HostBrowserPreviewConfig;
  configPath: string;
  configExists: boolean;
}

export interface SessionSummary {
  id: string;
  title: string;
  preview: string;
  cwd: string;
  createdAt: number;
  updatedAt: number;
  source: string;
  provider?: string | null;
  status: string;
  rolloutPath: string | null;
  runtime: SessionRuntimeSummary | null;
  gitInfo: GitInfoSummary | null;
  isSubAgent?: boolean;
}

export interface GitInfoSummary {
  sha: string | null;
  branch: string | null;
  originUrl: string | null;
}

export interface SessionGitFileStatus {
  path: string;
  originalPath: string | null;
  indexStatus: string;
  worktreeStatus: string;
}

export interface SessionGitStatus {
  isRepo: boolean;
  cwd: string;
  repoRoot: string | null;
  branch: string | null;
  sha: string | null;
  shortSha: string | null;
  upstream: string | null;
  ahead: number;
  behind: number;
  dirty: boolean;
  staged: number;
  unstaged: number;
  untracked: number;
  changed: number;
  originUrl: string | null;
  files: SessionGitFileStatus[];
  filesTruncated: boolean;
  refreshedAt: number;
  error: string | null;
}

export interface SessionGitDiff {
  kind: "working" | "staged" | "unstaged" | "remote";
  diff: string;
  baseSha: string | null;
  truncated: boolean;
  maxChars: number;
}

export interface WorkspaceSummary {
  cwd: string;
  label: string;
  sessionCount: number;
  lastUsedAt: number;
}

export interface SkillInterfaceSummary {
  displayName?: string | null;
  shortDescription?: string | null;
  brandColor?: string | null;
  defaultPrompt?: string | null;
}

export interface SkillSummary {
  name: string;
  description: string;
  shortDescription?: string | null;
  interface?: SkillInterfaceSummary | null;
  path: string;
  scope: "user" | "repo" | "system" | "admin" | string;
  enabled: boolean;
}

export interface SkillErrorInfo {
  path: string;
  message: string;
}

export interface SkillCatalogEntry {
  cwd: string;
  skills: SkillSummary[];
  errors: SkillErrorInfo[];
}

export interface ModelReasoningEffortSummary {
  reasoningEffort: string;
  description: string;
}

export type ModelReasoningEffortControl = "client" | "provider";

export interface ModelSummary {
  id: string;
  model: string;
  displayName: string;
  description: string;
  defaultReasoningEffort: string;
  supportedReasoningEfforts: ModelReasoningEffortSummary[];
  reasoningEffortControl: ModelReasoningEffortControl;
  supportsPersonality: boolean;
  additionalSpeedTiers: string[];
  inputModalities: string[];
  isDefault: boolean;
  sortOrder?: number | null;
  source?: string | null;
  profileName?: string | null;
}

export interface ProviderProfileCatalog {
  defaultProfile: string | null;
  profiles: ProviderProfileSummary[];
}

export interface ProviderProfileSummary {
  name: string;
  isDefault: boolean;
  model: string | null;
  modelProvider: string | null;
  modelProviderName: string | null;
  modelProviderBaseUrl: string | null;
  approvalPolicy: string | null;
  sandboxMode: string | null;
  serviceTier: string | null;
  reasoningEffort: string | null;
  reasoningSummary: string | null;
  verbosity: string | null;
  webSearch: string | null;
  personality: string | null;
}

export type CodexProfileCatalog = ProviderProfileCatalog;
export type CodexProfileSummary = ProviderProfileSummary;

export interface SessionMessage {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  attachments: SessionMessageAttachment[];
  createdAt: number;
  seq: number;
  phase?: "commentary" | "final_answer";
}

export interface SessionMessageAttachment {
  type: "image" | "localImage";
  url?: string;
  path?: string;
}

export interface SessionResource {
  id: string;
  kind: "image" | "link" | "file";
  source:
    | "message_attachment"
    | "message_link"
    | "message_file"
    | "web_search"
    | "image_generation";
  createdAt: number;
  title: string;
  subtitle: string | null;
  url: string | null;
  path: string | null;
  messageId: string | null;
  activityId: string | null;
}

export interface SessionResourcesResponse {
  sessionId: string;
  updatedAt: number;
  resources: SessionResource[];
}

export interface SessionActivityChange {
  path: string;
  kind: "add" | "delete" | "update";
  movePath?: string | null;
  diff: string;
}

export interface SessionActivityBase {
  id: string;
  type:
    | "command"
    | "tool"
    | "file_change"
    | "turn_diff"
    | "web_search"
    | "image_generation"
    | "context_compaction";
  turnId: string | null;
  createdAt: number;
  seq: number;
  status: "in_progress" | "completed" | "failed" | "declined";
}

export interface SessionCommandActionSummary {
  kind: "read" | "list_files" | "search" | "unknown";
  label: string;
}

export type ToolActivitySemanticCategory =
  | "filesystem"
  | "network"
  | "command"
  | "interaction"
  | "session"
  | "memory"
  | "task"
  | "unknown";

export type ToolActivitySemanticAction =
  | "read"
  | "write"
  | "search"
  | "list"
  | "fetch"
  | "ask"
  | "report"
  | "mode_change"
  | "invoke"
  | "unknown";

export type ToolActivitySemanticTarget =
  | {
      type: "file";
      path: string;
      access?: "read" | "write";
      role?: "target" | "context";
    }
  | {
      type: "url";
      url: string;
      role?: "target" | "context";
    }
  | {
      type: "query";
      value: string;
    }
  | {
      type: "mode";
      value: string;
    }
  | {
      type: "command";
      command: string;
    }
  | {
      type: "unknown";
      label: string;
    };

export interface ToolActivitySemantic {
  category: ToolActivitySemanticCategory;
  action: ToolActivitySemanticAction;
  targets: ToolActivitySemanticTarget[];
}

export interface CommandActivity extends SessionActivityBase {
  type: "command";
  command: string;
  cwd: string;
  output: string | null;
  exitCode: number | null;
  durationMs: number | null;
  source: string | null;
  processId: string | null;
  commandActions: SessionCommandActionSummary[];
  terminalStatus: "waiting" | "input" | null;
  terminalInput: string | null;
}

export interface ToolActivity extends SessionActivityBase {
  type: "tool";
  toolName: string;
  title: string | null;
  args: unknown;
  output: string | null;
  result: unknown;
  isError: boolean | null;
  semantic: ToolActivitySemantic | null;
}

export interface FileChangeActivity extends SessionActivityBase {
  type: "file_change";
  changes: SessionActivityChange[];
}

export interface TurnDiffActivity extends SessionActivityBase {
  type: "turn_diff";
  diff: string | null;
}

export interface WebSearchActivity extends SessionActivityBase {
  type: "web_search";
  query: string | null;
  queries: string[];
  targetUrl: string | null;
  pattern: string | null;
}

export interface ImageGenerationActivity extends SessionActivityBase {
  type: "image_generation";
  revisedPrompt: string | null;
  savedPath: string | null;
}

export interface ContextCompactionActivity extends SessionActivityBase {
  type: "context_compaction";
}

export type SessionActivity =
  | CommandActivity
  | ToolActivity
  | FileChangeActivity
  | TurnDiffActivity
  | WebSearchActivity
  | ImageGenerationActivity
  | ContextCompactionActivity;

export type PendingActionApprovalScope = "once" | "session" | "location";

export type PendingActionKind =
  | "command"
  | "tool"
  | "file_change"
  | "permissions"
  | "user_input"
  | "elicitation";

export type PendingActionDecisionId =
  | "accept"
  | "acceptForSession"
  | "acceptForLocation"
  | "decline"
  | "cancel";

export type PendingActionDecisionKind = "approve" | "decline" | "cancel";

export interface PendingActionDecisionRequest {
  decision: PendingActionDecisionKind;
  scope?: PendingActionApprovalScope;
}

export type PendingActionApprovalCategory =
  | "command"
  | "file_change"
  | "filesystem"
  | "network"
  | "tool"
  | "memory"
  | "hook"
  | "permissions";

export type PendingActionApprovalTarget =
  | {
      type: "command";
      command: string;
      cwd?: string;
      identifiers?: string[];
      readOnly?: boolean;
      possiblePaths?: string[];
      possibleUrls?: string[];
      intention?: string;
      warning?: string;
    }
  | {
      type: "file";
      path: string;
      access: "read" | "write";
      diff?: string;
      intention?: string;
    }
  | {
      type: "url";
      url: string;
      intention?: string;
    }
  | {
      type: "tool";
      name: string;
      title?: string;
      serverName?: string;
      readOnly?: boolean;
      description?: string;
      args?: unknown;
    }
  | {
      type: "memory";
      fact?: string;
      subject?: string;
      action?: string;
      direction?: string;
      reason?: string;
      citations?: string;
    }
  | {
      type: "hook";
      toolName?: string;
      message?: string;
      args?: unknown;
    }
  | {
      type: "permission_profile";
      permissions: unknown;
      cwd?: string;
      reason?: string;
    }
  | {
      type: "unknown";
      label: string;
    };

export interface PendingActionApproval {
  category: PendingActionApprovalCategory;
  operation: string;
  summary: string;
  detail?: string;
  cwd?: string;
  targets: PendingActionApprovalTarget[];
  supportedScopes: PendingActionApprovalScope[];
  suggestedScope?: PendingActionApprovalScope;
}

export interface PendingActionUserInputRequest {
  question: string;
  choices: string[];
  allowFreeform: boolean;
}

export type PendingActionElicitationFieldValue =
  | string
  | number
  | boolean
  | string[];

export type PendingActionElicitationField =
  | {
      key: string;
      type: "string";
      title: string;
      description?: string;
      required: boolean;
      defaultValue?: string;
      minLength?: number;
      maxLength?: number;
      format?: "email" | "uri" | "date" | "date-time";
      options?: Array<{ value: string; label: string }>;
    }
  | {
      key: string;
      type: "string[]";
      title: string;
      description?: string;
      required: boolean;
      defaultValue?: string[];
      minItems?: number;
      maxItems?: number;
      options: Array<{ value: string; label: string }>;
    }
  | {
      key: string;
      type: "boolean";
      title: string;
      description?: string;
      required: boolean;
      defaultValue?: boolean;
    }
  | {
      key: string;
      type: "number";
      title: string;
      description?: string;
      required: boolean;
      defaultValue?: number;
      minimum?: number;
      maximum?: number;
      integer?: boolean;
    };

export interface PendingActionElicitationRequest {
  mode: "form" | "url";
  message: string;
  source?: string;
  url?: string;
  fields: PendingActionElicitationField[];
}

export interface PendingAction {
  id: string;
  sessionId: string;
  kind: PendingActionKind;
  title: string;
  detail: string;
  requestedAt: number;
  canApprove: boolean;
  canApproveForSession: boolean;
  canDecline: boolean;
  sessionTitle?: string;
  cwd?: string;
  state?: "pending" | "recovered";
  recoverable?: boolean;
  relatedActivityId?: string;
  approval?: PendingActionApproval;
  userInput?: PendingActionUserInputRequest;
  elicitation?: PendingActionElicitationRequest;
}

export interface LiveEvent {
  type:
    | "hello"
    | "user_message_submitted"
    | "turn_started"
    | "assistant_delta"
    | "assistant_message_completed"
    | "turn_completed"
    | "activity_updated"
    | "runtime_updated"
    | "action_opened"
    | "action_resolved"
    | "skills_changed"
    | "error";
  sessionId: string;
  seq?: number;
  nextSeq?: number;
  turnId?: string;
  itemId?: string;
  delta?: string;
  status?: string;
  action?: PendingAction;
  actionId?: string;
  message?: string;
  messageItem?: SessionMessage;
  activity?: SessionActivity;
  runtime?: SessionRuntimeSummary;
}

export interface ApprovalLiveEvent {
  type: "hello" | "snapshot" | "action_opened" | "action_resolved" | "error";
  actions?: PendingAction[];
  action?: PendingAction;
  actionId?: string;
  message?: string;
}

export interface RecentSessionsLiveEvent {
  type: "hello" | "snapshot" | "upsert" | "remove" | "error";
  sessions?: SessionSummary[];
  session?: SessionSummary;
  sessionId?: string;
  message?: string;
}

export interface JsonRpcMessage {
  id?: number | string;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code?: number; message?: string };
}

export interface ThreadStatus {
  type: string;
  activeFlags?: Array<string>;
}

export interface ThreadRecord {
  id: string;
  name: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
  cwd: string;
  source: string | { custom?: string; subAgent?: unknown };
  path: string | null;
  status: ThreadStatus;
  gitInfo?: GitInfoSummary | null;
  turns?: Array<TurnRecord>;
}

export interface TurnRecord {
  id: string;
  status: string;
  startedAt: number | null;
  completedAt: number | null;
  items?: ThreadItemRecord[];
}

export interface ThreadItemRecord {
  id: string;
  type: string;
  [key: string]: unknown;
}

export interface ActiveTurnState {
  turnId: string;
  startedAt: number;
}

export interface PendingActionRecord extends PendingAction {
  jsonRpcId: number | string;
  requestMethod: string;
  requestedPermissions?: unknown;
}

export interface SessionLogSnapshot {
  messages: SessionMessage[];
  activities: SessionActivity[];
  runtime: SessionRuntimeSummary | null;
  totalMessages: number;
  totalActivities: number;
  nextSeq: number;
}

export interface SessionRuntimeSummary {
  model?: string;
  modelProvider?: string;
  mode?: string;
  turnId?: string;
  serviceTier?: string;
  reasoningEffort?: string;
  approvalPolicy?: string;
  sandboxMode?: string;
  networkAccess?: boolean;
  summaryMode?: string;
  personality?: string;
  telemetry?: SessionTelemetrySummary;
  updatedAt?: number;
}

export interface SessionTelemetrySummary {
  contextWindow?: SessionContextWindowSummary;
  lastUsage?: SessionLastUsageSummary;
  compaction?: SessionCompactionSummary;
}

export interface SessionContextWindowSummary {
  currentTokens: number;
  tokenLimit: number;
  messagesLength: number;
  conversationTokens?: number;
  systemTokens?: number;
  toolDefinitionsTokens?: number;
  updatedAt: number;
}

export interface SessionLastUsageSummary {
  model?: string;
  inputTokens?: number;
  outputTokens?: number;
  reasoningTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  durationMs?: number;
  ttftMs?: number;
  interTokenLatencyMs?: number;
  cost?: number;
  reasoningEffort?: string;
  totalNanoAiu?: number;
  updatedAt: number;
}

export interface SessionCompactionSummary {
  status: "running" | "completed" | "failed";
  startedAt?: number;
  completedAt?: number;
  preCompactionTokens?: number;
  postCompactionTokens?: number;
  tokensRemoved?: number;
  messagesRemoved?: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
  durationMs?: number;
  model?: string;
  totalNanoAiu?: number;
  error?: string;
  updatedAt: number;
}
