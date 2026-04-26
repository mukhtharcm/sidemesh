import type { EventEmitter } from "node:events";

export interface AgentProviderNotification {
  method: string;
  params: unknown;
}

export interface AgentProviderServerRequest {
  id: number | string;
  method: string;
  params: unknown;
}

export interface AgentProviderEvents {
  notification: [message: AgentProviderNotification];
  serverRequest: [message: AgentProviderServerRequest];
  stderr: [line: string];
  exit: [code: number | null];
}

export interface AgentProvider extends EventEmitter<AgentProviderEvents> {
  readonly kind: string;
  readonly displayName: string;
  readonly runtimeHome: string | null;

  start(): Promise<void>;
  getVersion(): Promise<string>;

  listSessionThreads(params: Record<string, unknown>): Promise<unknown>;
  readSessionThread(threadId: string, includeTurns: boolean): Promise<unknown>;
  listLoadedSessionIds(): Promise<unknown>;
  startSessionThread(params: Record<string, unknown>): Promise<unknown>;
  resumeSessionThread(threadId: string, params?: Record<string, unknown>): Promise<unknown>;
  setSessionName(threadId: string, name: string): Promise<unknown>;
  archiveSession(threadId: string): Promise<unknown>;
  unarchiveSession(threadId: string): Promise<unknown>;

  startTurn(params: Record<string, unknown>): Promise<unknown>;
  steerTurn(params: Record<string, unknown>): Promise<unknown>;
  interruptTurn(threadId: string, turnId: string): Promise<unknown>;

  respondToServerRequest(id: number | string, result: unknown): void;

  readRemoteGitDiff(cwd: string): Promise<unknown>;
  listSkills(params: Record<string, unknown>): Promise<unknown>;
  writeSkillConfig(params: Record<string, unknown>): Promise<unknown>;
  listModels(params: Record<string, unknown>): Promise<unknown>;
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
