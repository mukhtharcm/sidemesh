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
}

export interface WorkspaceSummary {
  cwd: string;
  label: string;
  sessionCount: number;
  lastUsedAt: number;
}

export interface SessionMessage {
  id: string;
  role: "user" | "assistant" | "system";
  text: string;
  createdAt: number;
  phase?: "commentary" | "final_answer";
}

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
    | "turn_started"
    | "assistant_delta"
    | "turn_completed"
    | "action_opened"
    | "action_resolved"
    | "error";
  sessionId: string;
  turnId?: string;
  delta?: string;
  status?: string;
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
  turns?: Array<TurnRecord>;
}

export interface TurnRecord {
  id: string;
  status: string;
  startedAt: number | null;
  completedAt: number | null;
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
}
