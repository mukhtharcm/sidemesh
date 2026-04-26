import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";

import type { AgentProvider, AgentProviderEvents } from "./agent-provider.js";
import { CodexBridge } from "./codex-client.js";

export class CodexAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  private readonly bridge: CodexBridge;

  public readonly kind = "codex";
  public readonly displayName = "Codex";

  public constructor(private readonly codexBin: string) {
    super();
    this.bridge = new CodexBridge(codexBin);
    this.bridge.on("notification", (message) => this.emit("notification", message));
    this.bridge.on("serverRequest", (message) => this.emit("serverRequest", message));
    this.bridge.on("stderr", (line) => this.emit("stderr", line));
    this.bridge.on("exit", (code) => this.emit("exit", code));
  }

  public get runtimeHome(): string | null {
    return this.bridge.codexHome;
  }

  public async start(): Promise<void> {
    await this.bridge.start();
  }

  public async getVersion(): Promise<string> {
    try {
      return execFileSync(this.codexBin, ["--version"], { encoding: "utf8" }).trim();
    } catch {
      return "unknown";
    }
  }

  public listSessionThreads(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("thread/list", params);
  }

  public readSessionThread(threadId: string, includeTurns: boolean): Promise<unknown> {
    return this.bridge.request("thread/read", { threadId, includeTurns });
  }

  public listLoadedSessionIds(): Promise<unknown> {
    return this.bridge.request("thread/loaded/list", {});
  }

  public startSessionThread(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("thread/start", params);
  }

  public resumeSessionThread(
    threadId: string,
    params: Record<string, unknown> = {},
  ): Promise<unknown> {
    return this.bridge.request("thread/resume", { threadId, ...params });
  }

  public setSessionName(threadId: string, name: string): Promise<unknown> {
    return this.bridge.request("thread/name/set", { threadId, name });
  }

  public archiveSession(threadId: string): Promise<unknown> {
    return this.bridge.request("thread/archive", { threadId });
  }

  public unarchiveSession(threadId: string): Promise<unknown> {
    return this.bridge.request("thread/unarchive", { threadId });
  }

  public startTurn(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("turn/start", params);
  }

  public steerTurn(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("turn/steer", params);
  }

  public interruptTurn(threadId: string, turnId: string): Promise<unknown> {
    return this.bridge.request("turn/interrupt", { threadId, turnId });
  }

  public respondToServerRequest(id: number | string, result: unknown): void {
    this.bridge.respond(id, result);
  }

  public readRemoteGitDiff(cwd: string): Promise<unknown> {
    return this.bridge.request("gitDiffToRemote", { cwd });
  }

  public listSkills(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("skills/list", params);
  }

  public writeSkillConfig(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("skills/config/write", params);
  }

  public listModels(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("model/list", params);
  }

  public readConfig(params: Record<string, unknown>): Promise<unknown> {
    return this.bridge.request("config/read", params);
  }

  public fsReadDirectory(path: string): Promise<unknown> {
    return this.bridge.request("fs/readDirectory", { path });
  }

  public fsGetMetadata(path: string): Promise<unknown> {
    return this.bridge.request("fs/getMetadata", { path });
  }

  public fsReadFile(path: string): Promise<unknown> {
    return this.bridge.request("fs/readFile", { path });
  }

  public fsWriteFile(path: string, dataBase64: string): Promise<unknown> {
    return this.bridge.request("fs/writeFile", { path, dataBase64 });
  }

  public fsCreateDirectory(path: string, recursive: boolean): Promise<unknown> {
    return this.bridge.request("fs/createDirectory", { path, recursive });
  }

  public fsRemove(
    path: string,
    options: { recursive: boolean; force: boolean },
  ): Promise<unknown> {
    return this.bridge.request("fs/remove", { path, ...options });
  }

  public fsCopy(params: {
    sourcePath: string;
    destinationPath: string;
    recursive: boolean;
  }): Promise<unknown> {
    return this.bridge.request("fs/copy", params);
  }

  public fsWatch(path: string): Promise<unknown> {
    return this.bridge.request("fs/watch", { path });
  }

  public fsUnwatch(watchId: string): Promise<unknown> {
    return this.bridge.request("fs/unwatch", { watchId });
  }
}
