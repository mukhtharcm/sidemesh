export interface NodeConfig {
  label: string;
  port: number;
  token: string;
  tokenSource: "env" | "generated";
  codexBin: string;
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

export interface SessionActivityChange {
  path: string;
  kind: "add" | "delete" | "update";
  movePath?: string | null;
  diff: string;
}

export interface SessionActivityBase {
  id: string;
  type: "command" | "file_change" | "turn_diff" | "image_generation";
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

export interface ImageGenerationActivity extends SessionActivityBase {
  type: "image_generation";
  revisedPrompt: string | null;
  savedPath: string | null;
}

export type SessionActivity =
  | CommandActivity
  | FileChangeActivity
  | TurnDiffActivity
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

export interface RolloutLog {
  messages: SessionMessage[];
  activities: SessionActivity[];
  runtime: SessionRuntimeSummary | null;
  totalMessages: number;
  totalActivities: number;
  nextSeq: number;
}

export interface SessionRuntimeSummary {
  model?: string;
  reasoningEffort?: string;
  approvalPolicy?: string;
  sandboxMode?: string;
  networkAccess?: boolean;
  summaryMode?: string;
  personality?: string;
  updatedAt?: number;
}
