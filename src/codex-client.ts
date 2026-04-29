import { EventEmitter } from "node:events";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { access } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

import { codexRpcAudit } from "./codex-rpc-audit.js";
import type { JsonRpcMessage } from "./types.js";

interface PendingRequest {
  method: string;
  startedAt: number;
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
}

interface InitializeResult {
  codexHome?: string;
}

const SHELL_ENV_START_MARKER = "__SIDEMESH_SHELL_ENV_START__";
const SHELL_ENV_END_MARKER = "__SIDEMESH_SHELL_ENV_END__";

function buildSeededCodexSpawnEnv(): NodeJS.ProcessEnv {
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

async function buildCodexSpawnEnv(): Promise<NodeJS.ProcessEnv> {
  const seeded = buildSeededCodexSpawnEnv();
  const shellEnv = await captureLoginShellEnv(seeded);
  if (!shellEnv) {
    return seeded;
  }

  return {
    ...seeded,
    ...shellEnv,
    HOME: shellEnv.HOME || seeded.HOME,
    USER: shellEnv.USER || seeded.USER,
    LOGNAME: shellEnv.LOGNAME || seeded.LOGNAME,
    SHELL: shellEnv.SHELL || seeded.SHELL,
    // Preserve the actual service cwd instead of the shell's startup dir.
    PWD: seeded.PWD || process.cwd(),
  };
}

async function captureLoginShellEnv(
  baseEnv: NodeJS.ProcessEnv,
): Promise<NodeJS.ProcessEnv | null> {
  if (process.platform === "win32") {
    return null;
  }

  const shellPath = await resolveShellPath(baseEnv);
  if (!shellPath) {
    return null;
  }

  const shellArgs = shellCaptureArgs(shellPath);
  if (!shellArgs) {
    return null;
  }

  const script = [
    `printf '%s\\0' '${SHELL_ENV_START_MARKER}'`,
    "env -0",
    `printf '%s\\0' '${SHELL_ENV_END_MARKER}'`,
  ].join("; ");

  const captured = await runShellEnvCapture(shellPath, [...shellArgs, script], baseEnv);
  if (!captured) {
    return null;
  }

  return parseShellEnvCapture(captured);
}

async function resolveShellPath(baseEnv: NodeJS.ProcessEnv): Promise<string | null> {
  const candidates = [
    baseEnv.SHELL?.trim(),
    "/bin/zsh",
    "/usr/bin/zsh",
    "/bin/bash",
    "/usr/bin/bash",
    "/bin/sh",
    "/usr/bin/sh",
  ];

  for (const candidate of candidates) {
    if (!candidate) {
      continue;
    }
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next known shell path.
    }
  }

  return null;
}

function shellCaptureArgs(shellPath: string): string[] | null {
  switch (path.basename(shellPath).toLowerCase()) {
    case "zsh":
    case "bash":
    case "sh":
    case "ksh":
    case "fish":
      return ["-l", "-i", "-c"];
    default:
      return null;
  }
}

async function runShellEnvCapture(
  shellPath: string,
  args: string[],
  env: NodeJS.ProcessEnv,
): Promise<Buffer | null> {
  return new Promise((resolve) => {
    const stdoutChunks: Buffer[] = [];
    const child = spawn(shellPath, args, {
      env,
      stdio: ["ignore", "pipe", "ignore"],
    });

    child.on("error", () => resolve(null));
    child.stdout.on("data", (chunk: Buffer | string) => {
      stdoutChunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
    });
    child.on("close", () => {
      if (stdoutChunks.length === 0) {
        resolve(null);
        return;
      }
      resolve(Buffer.concat(stdoutChunks));
    });
  });
}

function parseShellEnvCapture(buffer: Buffer): NodeJS.ProcessEnv | null {
  const output = buffer.toString("utf8");
  const startMarker = `${SHELL_ENV_START_MARKER}\0`;
  const endMarker = `${SHELL_ENV_END_MARKER}\0`;
  const startIndex = output.indexOf(startMarker);
  if (startIndex === -1) {
    return null;
  }

  const bodyStart = startIndex + startMarker.length;
  const endIndex = output.indexOf(endMarker, bodyStart);
  if (endIndex === -1) {
    return null;
  }

  const body = output.slice(bodyStart, endIndex);
  const env: NodeJS.ProcessEnv = {};
  for (const entry of body.split("\0")) {
    if (!entry) {
      continue;
    }
    const separatorIndex = entry.indexOf("=");
    if (separatorIndex <= 0) {
      continue;
    }
    env[entry.slice(0, separatorIndex)] = entry.slice(separatorIndex + 1);
  }

  return Object.keys(env).length > 0 ? env : null;
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
    const spawnEnv = await buildCodexSpawnEnv();
    this.process = spawn(this.codexBin, ["app-server"], {
      env: spawnEnv,
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
    const startedAt = Date.now();
    const promise = new Promise<T>((resolve, reject) => {
      this.pending.set(id, {
        method,
        startedAt,
        resolve: resolve as (value: unknown) => void,
        reject,
      });
    });
    codexRpcAudit.recordRequest(method);
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
        const message = parsed.error.message || `Request failed: ${pending.method}`;
        codexRpcAudit.recordResponse(
          pending.method,
          pending.startedAt,
          "error",
          message,
        );
        pending.reject(new Error(message));
        return;
      }
      codexRpcAudit.recordResponse(pending.method, pending.startedAt, "ok");
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
      codexRpcAudit.recordNotification(parsed.method, parsed.params);
      this.emit("notification", {
        method: parsed.method,
        params: parsed.params,
      });
    }
  }
}
