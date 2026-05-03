import type { EventEmitter } from "node:events";

import type { PendingActionResponseInput } from "./approvals.js";
import type {
  CommandActivity,
  ContextCompactionActivity,
  FileChangeActivity,
  ImageGenerationActivity,
  PendingAction,
  SessionLogSnapshot,
  SessionActivity,
  SessionMessage,
  SessionRuntimeSummary,
  ToolActivity,
  ModelSummary,
  ProviderProfileCatalog,
  SkillCatalogEntry,
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
  | Omit<ToolActivity, "createdAt" | "seq">
  | Omit<FileChangeActivity, "createdAt" | "seq">
  | Omit<TurnDiffActivity, "createdAt" | "seq">
  | Omit<WebSearchActivity, "createdAt" | "seq">
  | Omit<ImageGenerationActivity, "createdAt" | "seq">
  | Omit<ContextCompactionActivity, "createdAt" | "seq">;

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
    }
  | {
      type: "file";
      path: string;
      isDirectory?: boolean;
    };

export interface AgentSessionOverrides {
  model: string | null;
  mode: string | null;
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
  provider?: string | null;
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

export interface AgentSessionListOptions {
  limit: number;
  archived: boolean;
}

export interface AgentSessionResumeOptions {
  persistExtendedHistory: boolean;
  model?: string;
  modelProvider?: string;
  serviceTier?: string | null;
  approvalPolicy?: string;
  sandbox?: string;
  config?: Record<string, unknown>;
}

export interface AgentRemoteGitDiff {
  diff: string;
  sha: string | null;
}

export interface AgentFsDirectoryEntry {
  fileName: string;
  isDirectory: boolean;
  isFile: boolean;
}

export interface AgentFsDirectoryListing {
  entries: AgentFsDirectoryEntry[];
}

export interface AgentFsMetadata {
  isDirectory: boolean;
  isFile: boolean;
  isSymlink: boolean;
  createdAtMs: number;
  modifiedAtMs: number;
}

export interface AgentFsFile {
  dataBase64: string;
}

export interface AgentFsWatchResult {
  watchId: string;
}

export interface AgentModelListOptions {
  cwd: string | null;
  profile: string | null;
  provider: string | null;
}

export interface AgentProfileListOptions {
  cwd: string | null;
}

export interface AgentSkillListOptions {
  cwd: string;
  forceReload: boolean;
}

export interface AgentSkillConfigWriteRequest {
  path: string | null;
  name: string | null;
  enabled: boolean;
}

export interface AgentProviderCapabilities {
  sessions: {
    create: boolean;
    resume: boolean;
    rename: boolean;
    archive: boolean;
    compact: boolean;
    interrupt: boolean;
    history: boolean;
    eventReplay: boolean;
    recentFallback: boolean;
    searchSessions: boolean;
  };
  input: {
    text: boolean;
    imageUrl: boolean;
    localImage: boolean;
    skills: boolean;
    fileMentions: boolean;
  };
  interaction: {
    userInput: boolean;
    elicitation: boolean;
  };
  approvals: {
    command: boolean;
    tool: boolean;
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
    mode: boolean;
    reasoningEffort: boolean;
    fastMode: boolean;
    approvalPolicy: boolean;
    sandboxMode: boolean;
    networkAccess: boolean;
    webSearch: boolean;
  };
  workspace: {
    remoteGitDiff: boolean;
  };
  lifecycle: {
    restart: boolean;
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
      type: "runtime_updated";
      sessionId: string;
      runtime: SessionRuntimeSummary | null;
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

export interface AgentProviderCore extends EventEmitter<AgentProviderEvents> {
  readonly kind: string;
  readonly displayName: string;
  readonly capabilities: AgentProviderCapabilities;

  start(): Promise<void>;
  close?(): Promise<void>;
  restart?(): Promise<void>;
  health?(): Promise<boolean>;
  getVersion(): Promise<string>;
}

export interface AgentSessionHistoryProvider {
  listSessionThreads(options: AgentSessionListOptions): Promise<ThreadRecord[]>;
  readSessionThread(threadId: string, includeTurns: boolean): Promise<ThreadRecord>;
  listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]>;
  readSessionLog(
    thread: ThreadRecord,
    options?: AgentSessionLogOptions,
  ): Promise<SessionLogSnapshot>;
  readSessionRuntime(thread: ThreadRecord): Promise<SessionRuntimeSummary | null>;
}

export interface AgentSessionLifecycleProvider {
  listLoadedSessionIds(): Promise<string[]>;
  resumeSessionThread(
    threadId: string,
    options?: AgentSessionResumeOptions,
  ): Promise<unknown>;
  setSessionName(threadId: string, name: string): Promise<unknown>;
  archiveSession(threadId: string): Promise<unknown>;
  unarchiveSession(threadId: string): Promise<unknown>;
  compactSession(threadId: string): Promise<unknown>;
  createSession(request: AgentCreateSessionRequest): Promise<AgentCreateSessionResult>;
  submitInput(request: AgentSubmitInputRequest): Promise<AgentSubmitInputResult>;
  interruptTurn(threadId: string, turnId: string): Promise<unknown>;
}

export interface AgentApprovalProvider {
  respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean;
}

export interface AgentWorkspaceProvider {
  readRemoteGitDiff(cwd: string): Promise<AgentRemoteGitDiff>;
}

export interface AgentConfigurationProvider {
  listSkills(options: AgentSkillListOptions): Promise<SkillCatalogEntry>;
  writeSkillConfig(request: AgentSkillConfigWriteRequest): Promise<unknown>;
  listModels(options: AgentModelListOptions): Promise<ModelSummary[]>;
  listProfiles(options: AgentProfileListOptions): Promise<ProviderProfileCatalog>;
}

// Provider-native remote filesystem APIs are intentionally not part of the
// shared AgentProvider surface. Local filesystem access is daemon-owned in
// src/fs-routes.ts and advertised through hostCapabilities.
export interface AgentFilesystemProvider {
  fsReadDirectory(path: string): Promise<AgentFsDirectoryListing>;
  fsGetMetadata(path: string): Promise<AgentFsMetadata>;
  fsReadFile(path: string): Promise<AgentFsFile>;
  fsWriteFile(path: string, dataBase64: string): Promise<unknown>;
  fsCreateDirectory(path: string, recursive: boolean): Promise<unknown>;
  fsRemove(path: string, options: { recursive: boolean; force: boolean }): Promise<unknown>;
  fsCopy(params: {
    sourcePath: string;
    destinationPath: string;
    recursive: boolean;
  }): Promise<unknown>;
  fsWatch(path: string): Promise<AgentFsWatchResult>;
  fsUnwatch(watchId: string): Promise<unknown>;
}

export interface AgentProvider
  extends AgentProviderCore,
    Partial<AgentSessionHistoryProvider>,
    Partial<AgentSessionLifecycleProvider>,
    Partial<AgentApprovalProvider>,
    Partial<AgentWorkspaceProvider>,
    Partial<AgentConfigurationProvider> {}

export type AgentProviderMethod<K extends keyof AgentProvider> = Extract<
  NonNullable<AgentProvider[K]>,
  (...args: any[]) => unknown
>;

export type AgentProviderMethodName = {
  [K in keyof AgentProvider]-?: AgentProviderMethod<K> extends never ? never : K;
}[keyof AgentProvider];

export function hasProviderMethod<K extends AgentProviderMethodName>(
  provider: AgentProvider,
  method: K,
): provider is AgentProvider & { [P in K]-?: AgentProviderMethod<P> } {
  return typeof provider[method] === "function";
}

export function requireProviderMethod<K extends AgentProviderMethodName>(
  provider: AgentProvider,
  method: K,
  feature: string,
): AgentProviderMethod<K> {
  const candidate = provider[method];
  if (typeof candidate !== "function") {
    throw new Error(`${provider.displayName} does not implement ${feature}`);
  }
  return candidate as AgentProviderMethod<K>;
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
