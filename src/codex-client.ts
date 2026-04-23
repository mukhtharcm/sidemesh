import { EventEmitter } from "node:events";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import os from "node:os";
import readline from "node:readline";

import type { JsonRpcMessage } from "./types.js";

interface PendingRequest {
  method: string;
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

interface InitializeResult {
  codexHome?: string;
}

function buildCodexSpawnEnv(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = { ...process.env };

  // Service managers sometimes launch sidemesh with a stripped environment.
  // Codex later derives shell/tool env from its own process environment, so
  // missing HOME/USER here leaks into app-started sessions.
  const home = env.HOME?.trim() || os.homedir().trim();
  if (home) {
    env.HOME = home;
  }

  let username = env.USER?.trim() || env.LOGNAME?.trim() || "";
  if (!username) {
    try {
      username = os.userInfo().username.trim();
    } catch {
      username = "";
    }
  }
  if (username) {
    if (!env.USER?.trim()) {
      env.USER = username;
    }
    if (!env.LOGNAME?.trim()) {
      env.LOGNAME = username;
    }
  }

  return env;
}

export class CodexBridge extends EventEmitter<{
  notification: [message: { method: string; params: unknown }];
  serverRequest: [message: { id: number | string; method: string; params: unknown }];
  stderr: [line: string];
  exit: [code: number | null];
}> {
  private process: ChildProcessWithoutNullStreams | null = null;
  private requestId = 1;
  private readonly pending = new Map<number | string, PendingRequest>();
  private codexHomePath: string | null = null;

  public constructor(private readonly codexBin: string) {
    super();
  }

  public get codexHome(): string | null {
    return this.codexHomePath;
  }

  public async start(): Promise<void> {
    this.process = spawn(this.codexBin, ["app-server"], {
      env: buildCodexSpawnEnv(),
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.process.stderr.setEncoding("utf8");
    this.process.stderr.on("data", (chunk) => {
      this.emit("stderr", chunk.toString());
    });

    this.process.on("exit", (code) => {
      const error = new Error(`codex app-server exited with code ${code ?? "unknown"}`);
      for (const request of this.pending.values()) {
        request.reject(error);
      }
      this.pending.clear();
      this.emit("exit", code);
    });

    const lines = readline.createInterface({ input: this.process.stdout });
    lines.on("line", (line) => {
      this.handleLine(line);
    });

    const init = (await this.request("initialize", {
      clientInfo: {
        name: "sidemesh_node",
        title: "Sidemesh Node",
        version: "0.1.0",
      },
      capabilities: {
        experimentalApi: true,
      },
    })) as InitializeResult;
    this.codexHomePath = typeof init.codexHome === "string" ? init.codexHome : null;
    this.notify("initialized", {});
  }

  public async request<T>(method: string, params: unknown): Promise<T> {
    const id = this.requestId++;
    const payload: JsonRpcMessage = { id, method, params };
    const promise = new Promise<T>((resolve, reject) => {
      this.pending.set(id, {
        method,
        resolve: resolve as (value: unknown) => void,
        reject,
      });
    });
    this.send(payload);
    return promise;
  }

  public respond(id: number | string, result: unknown): void {
    this.send({ id, result });
  }

  public notify(method: string, params: unknown): void {
    this.send({ method, params });
  }

  private send(payload: JsonRpcMessage): void {
    if (!this.process) {
      throw new Error("codex app-server is not running");
    }
    this.process.stdin.write(`${JSON.stringify(payload)}\n`);
  }

  private handleLine(line: string): void {
    let parsed: JsonRpcMessage;
    try {
      parsed = JSON.parse(line) as JsonRpcMessage;
    } catch {
      return;
    }

    if (parsed.id !== undefined && (parsed.result !== undefined || parsed.error)) {
      const pending = this.pending.get(parsed.id);
      if (!pending) {
        return;
      }
      this.pending.delete(parsed.id);
      if (parsed.error) {
        pending.reject(new Error(parsed.error.message || `Request failed: ${pending.method}`));
        return;
      }
      pending.resolve(parsed.result);
      return;
    }

    if (parsed.method && parsed.id !== undefined) {
      this.emit("serverRequest", {
        id: parsed.id,
        method: parsed.method,
        params: parsed.params,
      });
      return;
    }

    if (parsed.method) {
      this.emit("notification", {
        method: parsed.method,
        params: parsed.params,
      });
    }
  }
}
