import type {
  CopilotClientOptions,
  GetStatusResponse,
  GetAuthStatusResponse,
  MessageOptions,
  ModelInfo,
  ElicitationContext,
  ElicitationHandler,
  ElicitationResult,
  PermissionHandler,
  PermissionRequest,
  PermissionRequestResult,
  ResumeSessionConfig,
  SessionConfig,
  SessionEvent,
  SessionListFilter,
  SessionMetadata,
} from "@github/copilot-sdk";

export type CopilotSdkModelInfo = ModelInfo;
export type CopilotSdkMessageOptions = MessageOptions;
export type CopilotSdkPermissionHandler = PermissionHandler;
export type CopilotSdkPermissionRequest = PermissionRequest;
export type CopilotSdkPermissionResult = PermissionRequestResult;
export type CopilotSdkElicitationContext = ElicitationContext;
export type CopilotSdkElicitationHandler = ElicitationHandler;
export type CopilotSdkElicitationResult = ElicitationResult;
export type CopilotSdkReasoningEffort = "low" | "medium" | "high" | "xhigh";
export type CopilotSdkSessionMode = "interactive" | "plan" | "autopilot";
export type CopilotSdkSessionConfig = SessionConfig;
export type CopilotSdkResumeSessionConfig = ResumeSessionConfig;
export type CopilotSdkSessionEvent = SessionEvent;
export type CopilotSdkSessionListFilter = SessionListFilter;
export type CopilotSdkSessionMetadata = SessionMetadata;
export type CopilotSdkAuthStatus = GetAuthStatusResponse;
export interface CopilotSdkUserInputRequest {
  question: string;
  choices?: string[];
  allowFreeform?: boolean;
}

export interface CopilotSdkUserInputResponse {
  answer: string;
  wasFreeform: boolean;
}

export type CopilotSdkUserInputHandler = (
  request: CopilotSdkUserInputRequest,
  invocation: { sessionId: string },
) => Promise<CopilotSdkUserInputResponse> | CopilotSdkUserInputResponse;
export interface CopilotSdkServerSkill {
  name: string;
  description: string;
  source: string;
  userInvocable: boolean;
  enabled: boolean;
  path?: string;
  projectPath?: string;
}

export interface CopilotSdkSkillListResult {
  skills: Array<{
    name: string;
    description: string;
    source: string;
    userInvocable: boolean;
    enabled: boolean;
    path?: string;
  }>;
}

export interface CopilotSdkServerSkillListResult {
  skills: CopilotSdkServerSkill[];
}

export interface CopilotSdkPlanReadResult {
  exists: boolean;
  content: string | null;
  path: string | null;
}

export interface CopilotSdkSession {
  readonly sessionId: string;
  send(options: CopilotSdkMessageOptions): Promise<string>;
  abort(): Promise<void>;
  getMessages?(): Promise<CopilotSdkSessionEvent[]>;
  disconnect?(): Promise<void>;
  setModel?(
    model: string,
    options?: {
      reasoningEffort?: CopilotSdkReasoningEffort;
      modelCapabilities?: unknown;
    },
  ): Promise<void>;
  readonly rpc?: {
    mode: {
      get(): Promise<CopilotSdkSessionMode>;
      set(params: { mode: CopilotSdkSessionMode }): Promise<void>;
    };
    skills: {
      list(): Promise<CopilotSdkSkillListResult>;
      enable(params: { name: string }): Promise<void>;
      disable(params: { name: string }): Promise<void>;
      reload(): Promise<void>;
    };
    plan?: {
      read(): Promise<CopilotSdkPlanReadResult>;
    };
    compaction?: {
      compact(): Promise<{
        success: boolean;
        tokensRemoved: number;
        messagesRemoved: number;
      }>;
    };
  };
}

export interface CopilotSdkClient {
  start(): Promise<void>;
  stop?(): Promise<unknown>;
  forceStop?(): Promise<void>;
  getStatus?(): Promise<GetStatusResponse>;
  getAuthStatus?(): Promise<GetAuthStatusResponse>;
  listModels(): Promise<CopilotSdkModelInfo[]>;
  listSessions?(
    filter?: CopilotSdkSessionListFilter,
  ): Promise<CopilotSdkSessionMetadata[]>;
  getSessionMetadata?(
    sessionId: string,
  ): Promise<CopilotSdkSessionMetadata | undefined>;
  readonly rpc?: {
    skills: {
      config: {
        setDisabledSkills(params: { disabledSkills: string[] }): Promise<void>;
      };
      discover(params: {
        projectPaths?: string[];
        skillDirectories?: string[];
      }): Promise<CopilotSdkServerSkillListResult>;
    };
  };
  createSession(config: CopilotSdkSessionConfig): Promise<CopilotSdkSession>;
  resumeSession(
    sessionId: string,
    config: CopilotSdkResumeSessionConfig,
  ): Promise<CopilotSdkSession>;
}

export interface CopilotSdkClientFactoryOptions {
  bin: string;
  cwd: string;
  env: Record<string, string | undefined>;
}

export type CopilotSdkClientFactory = (
  options: CopilotSdkClientFactoryOptions,
) => CopilotSdkClient | Promise<CopilotSdkClient>;

export async function createCopilotSdkClient(
  options: CopilotSdkClientFactoryOptions,
): Promise<CopilotSdkClient> {
  const { CopilotClient, RuntimeConnection } = await import(
    "@github/copilot-sdk"
  );
  const customBin = options.bin.trim();
  const clientOptions: CopilotClientOptions = {
    workingDirectory: options.cwd,
    env: options.env,
    logLevel: "error",
    sessionIdleTimeoutSeconds: 0,
    connection:
      customBin && customBin !== "copilot"
        ? RuntimeConnection.forStdio({ path: customBin })
        : RuntimeConnection.forStdio(),
  };
  return new CopilotClient(clientOptions) as unknown as CopilotSdkClient;
}

export function approveOnce(): CopilotSdkPermissionResult {
  return { kind: "approve-once" };
}

export function rejectPermission(): CopilotSdkPermissionResult {
  return { kind: "reject" };
}
