import type { EventEmitter } from "node:events";

import type {
  CommandActivity,
  FileChangeActivity,
  ImageGenerationActivity,
  PendingAction,
  SessionLogSnapshot,
  SessionActivity,
  SessionMessage,
  SessionRuntimeSummary,
  ModelSummary,
  CodexProfileCatalog,
  ThreadRecord,
  TurnDiffActivity,
  WebSearchActivity,
} from "./types.js";

export interface AgentProviderEvents {
  liveEvent: [event: AgentProviderLiveEvent];
  stderr: [line: string];
  exit: [code: number | null];
}

export type AgentSessionActivityDraft =
  | Omit<CommandActivity, "createdAt" | "seq">
  | Omit<FileChangeActivity, "createdAt" | "seq">
  | Omit<TurnDiffActivity, "createdAt" | "seq">
  | Omit<WebSearchActivity, "createdAt" | "seq">
  | Omit<ImageGenerationActivity, "createdAt" | "seq">;

export interface AgentMessageDraft {
  id: string;
  text: string;
  phase?: SessionMessage["phase"];
}

export interface AgentPendingAction extends PendingAction {
  providerRequestId: number | string;
  providerRequestKind: string;
  providerPayload?: unknown;
}

export interface AgentSessionLogOptions {
  messageLimit?: number | null;
  activityLimit?: number | null;
}

export type AgentSessionInputItem =
  | {
      type: "text";
      text: string;
      text_elements: unknown[];
    }
  | {
      type: "image";
      url: string;
    }
  | {
      type: "localImage";
      path: string;
    }
  | {
      type: "skill";
      name: string;
      path: string;
    };

export interface AgentSessionOverrides {
  model: string | null;
  reasoningEffort: string | null;
  fastMode: boolean | null;
  approvalPolicy: string | null;
  sandboxMode: string | null;
  networkAccess: boolean | null;
  webSearch: string | null;
  profile: string | null;
}

export interface AgentCreateSessionRequest {
  cwd: string;
  input: AgentSessionInputItem[];
  overrides: AgentSessionOverrides;
}

export interface AgentCreateSessionResult {
  thread: ThreadRecord;
  activeTurnId: string | null;
  runtime: SessionRuntimeSummary | null;
}

export interface AgentSubmitInputRequest {
  sessionId: string;
  input: AgentSessionInputItem[];
  activeTurnId: string | null;
  overrides: AgentSessionOverrides;
}

export interface AgentSubmitInputResult {
  mode: "steer" | "turn";
  turnId: string | null;
}

export interface AgentModelListOptions {
  cwd: string | null;
  profile: string | null;
  provider: string | null;
}

export interface AgentProfileListOptions {
  cwd: string | null;
}

export interface AgentProviderCapabilities {
  sessions: {
    create: boolean;
    resume: boolean;
    rename: boolean;
    archive: boolean;
    interrupt: boolean;
    history: boolean;
    eventReplay: boolean;
    recentFallback: boolean;
  };
  input: {
    text: boolean;
    imageUrl: boolean;
    localImage: boolean;
    skills: boolean;
  };
  approvals: {
    command: boolean;
    fileChange: boolean;
    permissions: boolean;
    approveForSession: boolean;
  };
  configuration: {
    models: boolean;
    profiles: boolean;
    skills: boolean;
    skillManagement: boolean;
  };
  runtimeControls: {
    model: boolean;
    reasoningEffort: boolean;
    fastMode: boolean;
    approvalPolicy: boolean;
    sandboxMode: boolean;
    networkAccess: boolean;
    webSearch: boolean;
  };
  workspace: {
    filesystem: boolean;
    gitStatus: boolean;
    gitDiff: boolean;
    remoteGitDiff: boolean;
  };
}

export type AgentProviderLiveEvent =
  | {
      type: "fs_changed";
      watchId?: string;
      changedPaths?: string[];
    }
  | {
      type: "skills_changed";
    }
  | {
      type: "turn_started";
      sessionId: string;
      turnId: string;
    }
  | {
      type: "assistant_delta";
      sessionId: string;
      delta: string;
      turnId?: string;
      itemId?: string;
    }
  | {
      type: "assistant_message_completed";
      sessionId: string;
      turnId?: string;
      message: AgentMessageDraft;
    }
  | {
      type: "activity_updated";
      sessionId: string;
      turnId?: string;
      activity: AgentSessionActivityDraft;
    }
  | {
      type: "activity_output_delta";
      sessionId: string;
      turnId?: string;
      activityId: string;
      delta: string;
    }
  | {
      type: "activity_terminal_input";
      sessionId: string;
      turnId?: string;
      activityId: string;
      stdin: string;
    }
  | {
      type: "turn_completed";
      sessionId: string;
      turnId: string;
      status: string;
    }
  | {
      type: "action_opened";
      action: AgentPendingAction;
    };

export interface AgentProvider extends EventEmitter<AgentProviderEvents> {
  readonly kind: string;
  readonly displayName: string;
  readonly capabilities: AgentProviderCapabilities;

  start(): Promise<void>;
  getVersion(): Promise<string>;

  listSessionThreads(params: Record<string, unknown>): Promise<unknown>;
  readSessionThread(threadId: string, includeTurns: boolean): Promise<unknown>;
  listLoadedSessionIds(): Promise<unknown>;
  resumeSessionThread(threadId: string, params?: Record<string, unknown>): Promise<unknown>;
  setSessionName(threadId: string, name: string): Promise<unknown>;
  archiveSession(threadId: string): Promise<unknown>;
  unarchiveSession(threadId: string): Promise<unknown>;
  listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]>;
  readSessionLog(
    thread: ThreadRecord,
    options?: AgentSessionLogOptions,
  ): Promise<SessionLogSnapshot>;
  readSessionRuntime(thread: ThreadRecord): Promise<SessionRuntimeSummary | null>;
  createSession(request: AgentCreateSessionRequest): Promise<AgentCreateSessionResult>;
  submitInput(request: AgentSubmitInputRequest): Promise<AgentSubmitInputResult>;

  interruptTurn(threadId: string, turnId: string): Promise<unknown>;

  respondToPendingAction(action: AgentPendingAction, decision: string | null): boolean;

  readRemoteGitDiff(cwd: string): Promise<unknown>;
  listSkills(params: Record<string, unknown>): Promise<unknown>;
  writeSkillConfig(params: Record<string, unknown>): Promise<unknown>;
  listModels(options: AgentModelListOptions): Promise<ModelSummary[]>;
  listProfiles(options: AgentProfileListOptions): Promise<CodexProfileCatalog>;
  readConfig(params: Record<string, unknown>): Promise<unknown>;

  fsReadDirectory(path: string): Promise<unknown>;
  fsGetMetadata(path: string): Promise<unknown>;
  fsReadFile(path: string): Promise<unknown>;
  fsWriteFile(path: string, dataBase64: string): Promise<unknown>;
  fsCreateDirectory(path: string, recursive: boolean): Promise<unknown>;
  fsRemove(path: string, options: { recursive: boolean; force: boolean }): Promise<unknown>;
  fsCopy(params: {
    sourcePath: string;
    destinationPath: string;
    recursive: boolean;
  }): Promise<unknown>;
  fsWatch(path: string): Promise<unknown>;
  fsUnwatch(watchId: string): Promise<unknown>;
}

export function materializeAgentActivityDraft(
  draft: AgentSessionActivityDraft,
  context: { createdAt: number; seq: number },
): SessionActivity {
  return {
    ...draft,
    createdAt: context.createdAt,
    seq: context.seq,
  } as SessionActivity;
}
