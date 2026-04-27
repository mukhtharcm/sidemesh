import type {
  CopilotClientOptions,
  GetStatusResponse,
  MessageOptions,
  ModelInfo,
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
export type CopilotSdkReasoningEffort = "low" | "medium" | "high" | "xhigh";
export type CopilotSdkSessionConfig = SessionConfig;
export type CopilotSdkResumeSessionConfig = ResumeSessionConfig;
export type CopilotSdkSessionEvent = SessionEvent;
export type CopilotSdkSessionListFilter = SessionListFilter;
export type CopilotSdkSessionMetadata = SessionMetadata;

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
}

export interface CopilotSdkClient {
  start(): Promise<void>;
  stop?(): Promise<unknown>;
  forceStop?(): Promise<void>;
  getStatus?(): Promise<GetStatusResponse>;
  listModels(): Promise<CopilotSdkModelInfo[]>;
  listSessions?(
    filter?: CopilotSdkSessionListFilter,
  ): Promise<CopilotSdkSessionMetadata[]>;
  getSessionMetadata?(
    sessionId: string,
  ): Promise<CopilotSdkSessionMetadata | undefined>;
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
  const { CopilotClient } = await import("@github/copilot-sdk");
  const clientOptions: CopilotClientOptions = {
    cwd: options.cwd,
    env: options.env,
    logLevel: "error",
    sessionIdleTimeoutSeconds: 0,
    useStdio: true,
  };
  if (options.bin.trim() && options.bin.trim() !== "copilot") {
    clientOptions.cliPath = options.bin;
  }
  return new CopilotClient(clientOptions) as unknown as CopilotSdkClient;
}

export function approveOnce(): CopilotSdkPermissionResult {
  return { kind: "approve-once" };
}

export function rejectPermission(): CopilotSdkPermissionResult {
  return { kind: "reject" };
}
