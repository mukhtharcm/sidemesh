import { randomUUID } from "node:crypto";
import {
  spawn as spawnChild,
  type ChildProcessWithoutNullStreams,
} from "node:child_process";
import { createRequire } from "node:module";
import { arch, homedir, platform, userInfo } from "node:os";
import { chmodSync, existsSync } from "node:fs";
import { basename, dirname, join } from "node:path";

import * as pty from "node-pty";
import type { WebSocket } from "ws";

const DEFAULT_COLS = 100;
const DEFAULT_ROWS = 30;
const MIN_COLS = 20;
const MAX_COLS = 240;
const MIN_ROWS = 8;
const MAX_ROWS = 80;
const DEFAULT_MAX_SESSIONS = 12;
const DEFAULT_REPLAY_BYTES = 512 * 1024;
const DEFAULT_IDLE_TTL_MS = 6 * 60 * 60 * 1000;
const EXITED_TTL_MS = 5 * 60 * 1000;
const MAX_WS_BUFFERED_AMOUNT = 4 * 1024 * 1024;
const require = createRequire(import.meta.url);

export interface TerminalRegistryOptions {
  enabled: boolean;
  resolveCwd: (cwd: string, request: CreateTerminalRequest) => Promise<string>;
  maxSessions?: number;
  replayBytes?: number;
  idleTtlMs?: number;
  shell?: string | null;
  requirePty?: boolean;
}

export interface CreateTerminalRequest {
  cwd: string;
  title?: string | null;
  sessionId?: string | null;
  rows?: number | null;
  cols?: number | null;
  replaceExisting?: boolean | null;
}

export interface TerminalInfo {
  id: string;
  title: string;
  cwd: string;
  sessionId: string | null;
  status: "running" | "exited";
  backend: TerminalBackend;
  shell: string;
  rows: number;
  cols: number;
  createdAt: number;
  updatedAt: number;
  exitCode: number | null;
  signal: number | null;
  nextSeq: number;
  clients: number;
}

type TerminalReplayFrame =
  | {
      type: "output";
      terminalId: string;
      seq: number;
      data: string;
    }
  | {
      type: "exit";
      terminalId: string;
      seq: number;
      exitCode: number | null;
      signal: number | null;
    }
  | {
      type: "replace";
      terminalId: string;
      seq: number;
      replacement: TerminalInfo;
    };

type TerminalBackend = "direct-pty" | "pipe";

interface TerminalProcess {
  backend: TerminalBackend;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(): void;
  onData(callback: (data: string) => void): void;
  onExit(
    callback: (event: {
      exitCode: number | null;
      signal: number | null;
    }) => void,
  ): void;
}

interface TerminalRecord {
  id: string;
  title: string;
  cwd: string;
  sessionId: string | null;
  shell: string;
  process: TerminalProcess;
  backend: TerminalBackend;
  rows: number;
  cols: number;
  createdAt: number;
  updatedAt: number;
  lastClientAt: number;
  status: "running" | "exited";
  exitCode: number | null;
  signal: number | null;
  nextSeq: number;
  replayBytes: number;
  replay: TerminalReplayFrame[];
  clients: Set<WebSocket>;
}

export class TerminalRegistry {
  private readonly terminals = new Map<string, TerminalRecord>();
  private readonly enabled: boolean;
  private readonly resolveCwd: (
    cwd: string,
    request: CreateTerminalRequest,
  ) => Promise<string>;
  private readonly maxSessions: number;
  private readonly maxReplayBytes: number;
  private readonly idleTtlMs: number;
  private readonly shellOverride: string | null;
  private readonly requirePty: boolean;
  private cleanupTimer: NodeJS.Timeout | null = null;

  public constructor(options: TerminalRegistryOptions) {
    this.enabled = options.enabled;
    this.resolveCwd = options.resolveCwd;
    this.maxSessions = options.maxSessions ?? DEFAULT_MAX_SESSIONS;
    this.maxReplayBytes = options.replayBytes ?? DEFAULT_REPLAY_BYTES;
    this.idleTtlMs = options.idleTtlMs ?? DEFAULT_IDLE_TTL_MS;
    this.shellOverride = options.shell?.trim() || null;
    this.requirePty = options.requirePty === true;
    if (this.enabled) {
      this.cleanupTimer = setInterval(() => this.cleanup(), 60_000);
      this.cleanupTimer.unref?.();
    }
  }

  public isEnabled(): boolean {
    return this.enabled;
  }

  public list(): TerminalInfo[] {
    return [...this.terminals.values()]
      .map((terminal) => this.info(terminal))
      .sort((left, right) => right.updatedAt - left.updatedAt);
  }

  public get(id: string): TerminalInfo | null {
    const terminal = this.terminals.get(id);
    return terminal ? this.info(terminal) : null;
  }

  public async create(request: CreateTerminalRequest): Promise<TerminalInfo> {
    this.assertEnabled();
    this.enforceSessionLimit();

    const cwd = await this.resolveCwd(request.cwd, request);
    const shell = this.resolveShell();
    const dimensions = normalizeDimensions(request.cols, request.rows);
    const id = randomUUID();
    const title = request.title?.trim() || basename(cwd) || "Terminal";
    const now = Date.now();
    const terminalProcess = spawnTerminalProcess(shell.path, shell.args, {
      cwd,
      cols: dimensions.cols,
      rows: dimensions.rows,
      env: terminalEnvironment(),
      requirePty: this.requirePty,
    });
    const terminal: TerminalRecord = {
      id,
      title,
      cwd,
      sessionId: request.sessionId?.trim() || null,
      shell: shell.path,
      process: terminalProcess,
      backend: terminalProcess.backend,
      rows: dimensions.rows,
      cols: dimensions.cols,
      createdAt: now,
      updatedAt: now,
      lastClientAt: now,
      status: "running",
      exitCode: null,
      signal: null,
      nextSeq: 0,
      replayBytes: 0,
      replay: [],
      clients: new Set(),
    };
    this.terminals.set(id, terminal);

    terminalProcess.onData((data) => {
      const frame = this.pushFrame(terminal, {
        type: "output",
        terminalId: terminal.id,
        seq: terminal.nextSeq++,
        data,
      });
      this.broadcast(terminal, frame);
    });
    terminalProcess.onExit((event) => {
      terminal.status = "exited";
      terminal.exitCode = event.exitCode ?? null;
      terminal.signal = event.signal ?? null;
      terminal.updatedAt = Date.now();
      const frame = this.pushFrame(terminal, {
        type: "exit",
        terminalId: terminal.id,
        seq: terminal.nextSeq++,
        exitCode: terminal.exitCode,
        signal: terminal.signal,
      });
      this.broadcast(terminal, frame);
    });

    if (request.replaceExisting === true) {
      this.broadcastReplacement(terminal);
    }

    return this.info(terminal);
  }

  public resize(
    id: string,
    cols: number | null,
    rows: number | null,
  ): TerminalInfo {
    this.assertEnabled();
    const terminal = this.requireTerminal(id);
    const dimensions = normalizeDimensions(cols, rows);
    terminal.cols = dimensions.cols;
    terminal.rows = dimensions.rows;
    terminal.updatedAt = Date.now();
    if (terminal.status === "running") {
      terminal.process.resize(dimensions.cols, dimensions.rows);
    }
    return this.info(terminal);
  }

  public kill(id: string): TerminalInfo {
    this.assertEnabled();
    const terminal = this.requireTerminal(id);
    if (terminal.status === "running") {
      terminal.process.kill();
      terminal.updatedAt = Date.now();
    }
    return this.info(terminal);
  }

  public attach(socket: WebSocket, id: string, since: number): void {
    if (!this.enabled) {
      sendJson(socket, {
        type: "error",
        message: "terminal access is disabled",
      });
      socket.close();
      return;
    }
    const terminal = this.terminals.get(id);
    if (!terminal) {
      sendJson(socket, { type: "error", message: "terminal not found" });
      socket.close();
      return;
    }

    terminal.clients.add(socket);
    terminal.lastClientAt = Date.now();
    sendJson(socket, {
      type: "hello",
      terminal: this.info(terminal),
      nextSeq: terminal.nextSeq,
    });
    for (const frame of terminal.replay) {
      if (frame.seq > since) {
        sendJson(socket, frame);
      }
    }

    socket.on("message", (raw) => {
      this.handleClientMessage(terminal, socket, raw);
    });
    socket.on("close", () => {
      terminal.clients.delete(socket);
      terminal.lastClientAt = Date.now();
    });
  }

  public dispose(): void {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
    for (const terminal of this.terminals.values()) {
      try {
        terminal.process.kill();
      } catch {
        // noop
      }
    }
    this.terminals.clear();
  }

  private handleClientMessage(
    terminal: TerminalRecord,
    socket: WebSocket,
    raw: WebSocket.RawData,
  ): void {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(raw.toString()) as Record<string, unknown>;
    } catch {
      sendJson(socket, { type: "error", message: "invalid terminal frame" });
      return;
    }

    switch (message.type) {
      case "input": {
        if (terminal.status !== "running") return;
        const data = typeof message.data === "string" ? message.data : "";
        if (!data) return;
        terminal.updatedAt = Date.now();
        terminal.process.write(data);
        return;
      }
      case "resize": {
        const dimensions = normalizeDimensions(
          asInteger(message.cols),
          asInteger(message.rows),
        );
        terminal.cols = dimensions.cols;
        terminal.rows = dimensions.rows;
        terminal.updatedAt = Date.now();
        if (terminal.status === "running") {
          terminal.process.resize(dimensions.cols, dimensions.rows);
        }
        return;
      }
      case "kill": {
        this.kill(terminal.id);
        return;
      }
      case "ping": {
        sendJson(socket, { type: "pong", terminalId: terminal.id });
        return;
      }
      default:
        sendJson(socket, { type: "error", message: "unknown terminal frame" });
    }
  }

  private pushFrame<T extends TerminalReplayFrame>(
    terminal: TerminalRecord,
    frame: T,
  ): T {
    terminal.updatedAt = Date.now();
    terminal.replay.push(frame);
    terminal.replayBytes += frameSize(frame);
    while (
      terminal.replay.length > 0 &&
      terminal.replayBytes > this.maxReplayBytes
    ) {
      const removed = terminal.replay.shift();
      if (!removed) break;
      terminal.replayBytes -= frameSize(removed);
    }
    return frame;
  }

  private broadcast(terminal: TerminalRecord, frame: TerminalReplayFrame): void {
    for (const client of terminal.clients) {
      if (client.readyState !== client.OPEN) continue;
      if (client.bufferedAmount > MAX_WS_BUFFERED_AMOUNT) {
        sendJson(client, {
          type: "error",
          message: "terminal client is too far behind; reconnecting",
        });
        client.close();
        continue;
      }
      sendJson(client, frame);
    }
  }

  private broadcastReplacement(replacement: TerminalRecord): void {
    const replacementInfo = this.info(replacement);
    for (const terminal of this.terminals.values()) {
      if (terminal.id === replacement.id) continue;
      if (terminal.clients.size === 0) continue;
      if (!sameLogicalTerminal(terminal, replacement)) continue;
      const frame = this.pushFrame(terminal, {
        type: "replace",
        terminalId: terminal.id,
        seq: terminal.nextSeq++,
        replacement: replacementInfo,
      });
      this.broadcast(terminal, frame);
    }
  }

  private cleanup(): void {
    const now = Date.now();
    for (const terminal of this.terminals.values()) {
      if (
        terminal.status === "exited" &&
        terminal.clients.size === 0 &&
        now - terminal.updatedAt > EXITED_TTL_MS
      ) {
        this.terminals.delete(terminal.id);
        continue;
      }
      if (
        terminal.clients.size === 0 &&
        now - terminal.lastClientAt > this.idleTtlMs
      ) {
        try {
          terminal.process.kill();
        } catch {
          // noop
        }
        this.terminals.delete(terminal.id);
      }
    }
  }

  private enforceSessionLimit(): void {
    this.cleanup();
    if (this.terminals.size < this.maxSessions) {
      return;
    }
    const stale = [...this.terminals.values()]
      .filter((terminal) => terminal.clients.size === 0)
      .sort((left, right) => left.lastClientAt - right.lastClientAt)[0];
    if (!stale) {
      throw new TerminalError("terminal session limit reached", 429);
    }
    try {
      stale.process.kill();
    } catch {
      // noop
    }
    this.terminals.delete(stale.id);
  }

  private resolveShell(): { path: string; args: string[] } {
    const shell =
      this.shellOverride ||
      process.env.SHELL?.trim() ||
      (platform() === "win32" ? "powershell.exe" : "/bin/bash");
    const name = basename(shell);
    if (platform() !== "win32" && ["bash", "zsh", "fish"].includes(name)) {
      return { path: shell, args: ["-l"] };
    }
    return { path: shell, args: [] };
  }

  private info(terminal: TerminalRecord): TerminalInfo {
    return {
      id: terminal.id,
      title: terminal.title,
      cwd: terminal.cwd,
      sessionId: terminal.sessionId,
      status: terminal.status,
      backend: terminal.backend,
      shell: terminal.shell,
      rows: terminal.rows,
      cols: terminal.cols,
      createdAt: terminal.createdAt,
      updatedAt: terminal.updatedAt,
      exitCode: terminal.exitCode,
      signal: terminal.signal,
      nextSeq: terminal.nextSeq,
      clients: terminal.clients.size,
    };
  }

  private assertEnabled(): void {
    if (!this.enabled) {
      throw new TerminalError("terminal access is disabled", 403);
    }
  }

  private requireTerminal(id: string): TerminalRecord {
    const terminal = this.terminals.get(id);
    if (!terminal) {
      throw new TerminalError("terminal not found", 404);
    }
    return terminal;
  }
}

export class TerminalError extends Error {
  public readonly status: number;

  public constructor(message: string, status = 500) {
    super(message);
    this.name = "TerminalError";
    this.status = status;
  }
}

export function terminalEnabledFromEnv(
  env: Record<string, string | undefined> = process.env,
): boolean {
  const value =
    env.SIDEMESH_TERMINAL?.trim() || env.SIDEMESH_ENABLE_TERMINAL?.trim();
  return value === "1" || value?.toLowerCase() === "true";
}

export function terminalShellFromEnv(
  env: Record<string, string | undefined> = process.env,
): string | null {
  return normalizeTerminalShell(env.SIDEMESH_TERMINAL_SHELL);
}

export function normalizeTerminalShell(
  value: string | null | undefined,
): string | null {
  const shell = value?.trim();
  if (!shell) return null;
  if (platform() !== "win32" && shell.startsWith("/") && !existsSync(shell)) {
    throw new TerminalError(`terminal shell does not exist: ${shell}`, 400);
  }
  return shell;
}

function spawnTerminalProcess(
  shell: string,
  args: string[],
  options: {
    cwd: string;
    cols: number;
    rows: number;
    env: NodeJS.ProcessEnv;
    requirePty: boolean;
  },
): TerminalProcess {
  try {
    return spawnPtyTerminalProcess(shell, args, options);
  } catch (error) {
    if (repairNodePtySpawnHelper()) {
      try {
        return spawnPtyTerminalProcess(shell, args, options);
      } catch {
        // Fall through to the configured PTY failure behavior below.
      }
    }
    if (options.requirePty) {
      throw error;
    }
    return spawnPipeTerminalProcess(
      shell,
      fallbackShellArgs(shell, args),
      options,
    );
  }
}

function spawnPtyTerminalProcess(
  shell: string,
  args: string[],
  options: {
    cwd: string;
    cols: number;
    rows: number;
    env: NodeJS.ProcessEnv;
  },
): TerminalProcess {
  const ptyProcess = pty.spawn(shell, args, {
    name: "xterm-256color",
    cwd: options.cwd,
    cols: options.cols,
    rows: options.rows,
    env: options.env,
    handleFlowControl: true,
  });
  return {
    backend: "direct-pty",
    write: (data) => ptyProcess.write(data),
    resize: (cols, rows) => ptyProcess.resize(cols, rows),
    kill: () => ptyProcess.kill(),
    onData: (callback) => {
      ptyProcess.onData(callback);
    },
    onExit: (callback) => {
      ptyProcess.onExit((event) =>
        callback({
          exitCode: event.exitCode ?? null,
          signal: event.signal ?? null,
        }),
      );
    },
  };
}

function repairNodePtySpawnHelper(): boolean {
  if (platform() !== "darwin") return false;
  const cpu = arch();
  if (cpu !== "arm64" && cpu !== "x64") return false;

  try {
    const packagePath = require.resolve("node-pty/package.json");
    const helperPath = join(
      dirname(packagePath),
      "prebuilds",
      `darwin-${cpu}`,
      "spawn-helper",
    );
    if (!existsSync(helperPath)) return false;
    chmodSync(helperPath, 0o755);
    return true;
  } catch {
    return false;
  }
}

function spawnPipeTerminalProcess(
  shell: string,
  args: string[],
  options: {
    cwd: string;
    env: NodeJS.ProcessEnv;
  },
): TerminalProcess {
  let exited = false;
  const child = spawnChild(shell, args, {
    cwd: options.cwd,
    env: options.env,
    detached: platform() !== "win32",
    stdio: "pipe",
  });
  return {
    backend: "pipe",
    write: (data) => {
      child.stdin.write(data);
    },
    resize: () => {
      // Pipe fallback has no PTY resize support.
    },
    kill: () => {
      terminatePipeProcess(child, () => exited);
    },
    onData: (callback) => {
      child.stdout.on("data", (data) => callback(data.toString()));
      child.stderr.on("data", (data) => callback(data.toString()));
    },
    onExit: (callback) => {
      child.on("exit", (exitCode) => {
        exited = true;
        callback({ exitCode, signal: null });
      });
    },
  };
}

function terminatePipeProcess(
  child: ChildProcessWithoutNullStreams,
  hasExited: () => boolean,
): void {
  child.stdin.end();
  sendSignal(child, "SIGTERM");
  setTimeout(() => {
    if (!hasExited()) {
      sendSignal(child, "SIGKILL");
    }
  }, 750).unref?.();
}

function sendSignal(
  child: ChildProcessWithoutNullStreams,
  signal: NodeJS.Signals,
): void {
  if (platform() !== "win32" && child.pid) {
    try {
      process.kill(-child.pid, signal);
      return;
    } catch {
      // Fall through to killing the direct child. This can happen if process
      // group creation failed or the process already exited.
    }
  }
  try {
    child.kill(signal);
  } catch {
    // noop
  }
}

function fallbackShellArgs(shell: string, args: string[]): string[] {
  const name = basename(shell);
  if (platform() !== "win32" && ["bash", "zsh"].includes(name)) {
    const next = new Set(args);
    next.add("-i");
    return [...next];
  }
  if (platform() !== "win32" && name === "fish") {
    const next = new Set(args);
    next.add("-i");
    return [...next];
  }
  return args;
}

function terminalEnvironment(): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    TERM: "xterm-256color",
    COLORTERM: process.env.COLORTERM || "truecolor",
    SIDEMESH_TERMINAL_SESSION: "1",
  };
  seedInteractiveIdentity(env);
  // Do not leak the daemon bearer token into arbitrary terminal children.
  delete env.SIDEMESH_TOKEN;
  return env;
}

function seedInteractiveIdentity(env: NodeJS.ProcessEnv): void {
  const home = env.HOME?.trim() || homedir().trim();
  if (home) {
    env.HOME = home;
  }

  let username = env.USER?.trim() || env.LOGNAME?.trim() || "";
  let shell = env.SHELL?.trim() || "";
  try {
    const info = userInfo();
    username ||= info.username.trim();
    shell ||= info.shell?.trim() || "";
  } catch {
    // Keep the best-effort defaults below.
  }
  if (username) {
    env.USER ||= username;
    env.LOGNAME ||= username;
  }
  if (!shell && platform() !== "win32") {
    shell = "/bin/bash";
  }
  if (shell) {
    env.SHELL ||= shell;
  }
}

function normalizeDimensions(
  cols: number | null | undefined,
  rows: number | null | undefined,
): { cols: number; rows: number } {
  return {
    cols: clampInteger(cols, DEFAULT_COLS, MIN_COLS, MAX_COLS),
    rows: clampInteger(rows, DEFAULT_ROWS, MIN_ROWS, MAX_ROWS),
  };
}

function clampInteger(
  value: number | null | undefined,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = Number.isFinite(value) ? Math.trunc(value as number) : fallback;
  return Math.max(min, Math.min(max, parsed));
}

function frameSize(frame: TerminalReplayFrame): number {
  return Buffer.byteLength(JSON.stringify(frame), "utf8");
}

function sameLogicalTerminal(
  left: Pick<TerminalRecord, "cwd" | "sessionId">,
  right: Pick<TerminalRecord, "cwd" | "sessionId">,
): boolean {
  if (left.cwd !== right.cwd) return false;
  if (left.sessionId || right.sessionId) {
    return left.sessionId !== null && left.sessionId === right.sessionId;
  }
  return true;
}

function sendJson(socket: WebSocket, payload: unknown): void {
  if (socket.readyState !== socket.OPEN) return;
  try {
    socket.send(JSON.stringify(payload));
  } catch {
    // noop
  }
}

function asInteger(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}
