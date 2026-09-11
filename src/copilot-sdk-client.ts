import type {
  CopilotClient,
  CopilotClientOptions,
  CopilotSession,
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
export type CopilotSdkReasoningEffort = NonNullable<SessionConfig["reasoningEffort"]>;
export type CopilotSdkSessionMode = Awaited<ReturnType<CopilotSession["rpc"]["mode"]["get"]>>;
export type CopilotSdkSessionConfig = SessionConfig;
export type CopilotSdkResumeSessionConfig = ResumeSessionConfig;
export type CopilotSdkSessionEvent = SessionEvent;
export type CopilotSdkSessionListFilter = SessionListFilter;
export type CopilotSdkSessionMetadata = SessionMetadata;
export type CopilotSdkAuthStatus = GetAuthStatusResponse;
export type CopilotSdkUserInputHandler = NonNullable<SessionConfig["onUserInputRequest"]>;
export type CopilotSdkUserInputRequest = Parameters<CopilotSdkUserInputHandler>[0];
export type CopilotSdkUserInputResponse = Awaited<ReturnType<CopilotSdkUserInputHandler>>;

// Select only the official SDK methods used by the adapter so test doubles stay small.
export type CopilotSdkSession = Pick<CopilotSession,
  "sessionId" | "send" | "abort" | "getEvents" | "setModel"
> & Partial<Pick<CopilotSession, "disconnect">> & {
  readonly rpc: {
    mode: Pick<CopilotSession["rpc"]["mode"], "get" | "set">;
    skills: Pick<CopilotSession["rpc"]["skills"], "list" | "enable" | "disable" | "reload">;
    plan: Pick<CopilotSession["rpc"]["plan"], "read">;
    history: Pick<CopilotSession["rpc"]["history"], "compact">;
    metadata: Pick<CopilotSession["rpc"]["metadata"], "activity">;
    name: Pick<CopilotSession["rpc"]["name"], "get" | "set">;
  };
};

export type CopilotSdkClient = Pick<CopilotClient, "start" | "listModels"> &
  Partial<Pick<CopilotClient,
    "stop" | "forceStop" | "getStatus" | "getAuthStatus" | "listSessions" | "getSessionMetadata"
  >> & {
    readonly rpc: {
      skills: Pick<CopilotClient["rpc"]["skills"], "discover"> & {
        config: Pick<CopilotClient["rpc"]["skills"]["config"], "setDisabledSkills">;
      };
    };
    createSession(config: SessionConfig): Promise<CopilotSdkSession>;
    resumeSession(sessionId: string, config: ResumeSessionConfig): Promise<CopilotSdkSession>;
  };

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
  return new CopilotClient(clientOptions);
}

export function approveOnce(): CopilotSdkPermissionResult {
  return { kind: "approve-once" };
}

export function rejectPermission(): CopilotSdkPermissionResult {
  return { kind: "reject" };
}
