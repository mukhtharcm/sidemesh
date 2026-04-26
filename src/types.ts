export interface NodeConfig {
  label: string;
  port: number;
  token: string;
  tokenSource: "env" | "generated";
  codexBin: string;
  stateDir: string;
}

export interface SessionSummary {
  id: string;
  title: string;
  preview: string;
  cwd: string;
  createdAt: number;
  updatedAt: number;
  source: string;
  status: string;
  rolloutPath: string | null;
  runtime: SessionRuntimeSummary | null;
  gitInfo: GitInfoSummary | null;
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

export interface ModelSummary {
  id: string;
  model: string;
  displayName: string;
  description: string;
  defaultReasoningEffort: string;
  supportedReasoningEfforts: ModelReasoningEffortSummary[];
  supportsPersonality: boolean;
  additionalSpeedTiers: string[];
  inputModalities: string[];
  isDefault: boolean;
  source?: string | null;
  profileName?: string | null;
}

export interface CodexProfileCatalog {
  defaultProfile: string | null;
  profiles: CodexProfileSummary[];
}

export interface CodexProfileSummary {
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
  type: "command" | "file_change" | "turn_diff" | "web_search" | "image_generation";
  turnId: string | null;
  createdAt: number;
  seq: number;
  status: "in_progress" | "completed" | "failed" | "declined";
}

export interface SessionCommandActionSummary {
  kind: "read" | "list_files" | "search" | "unknown";
  label: string;
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

export type SessionActivity =
  | CommandActivity
  | FileChangeActivity
  | TurnDiffActivity
  | WebSearchActivity
  | ImageGenerationActivity;

export interface PendingAction {
  id: string;
  sessionId: string;
  kind: "command" | "file_change" | "permissions";
  title: string;
  detail: string;
  requestedAt: number;
  canApprove: boolean;
  canApproveForSession: boolean;
  canDecline: boolean;
  sessionTitle?: string;
  cwd?: string;
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
}

export interface ApprovalLiveEvent {
  type: "hello" | "snapshot" | "action_opened" | "action_resolved" | "error";
  actions?: PendingAction[];
  action?: PendingAction;
  actionId?: string;
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
  serviceTier?: string;
  reasoningEffort?: string;
  approvalPolicy?: string;
  sandboxMode?: string;
  networkAccess?: boolean;
  summaryMode?: string;
  personality?: string;
  updatedAt?: number;
}
