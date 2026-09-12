import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface, type Interface } from "node:readline";
import { fileURLToPath } from "node:url";
import type { JsonAgentSessionEvent, RpcCommand, RpcExtensionUIRequest, RpcExtensionUIResponse, RpcResponse } from "@earendil-works/pi-coding-agent";
import { terminatePipeProcess } from "./terminal.js";

export type PiRpcEvent = JsonAgentSessionEvent | RpcExtensionUIRequest | { type: "extension_error"; extensionPath: string; event: string; error: string };
export type PiRpcResult<T extends RpcCommand["type"]> = Extract<RpcResponse, { command: T; success: true }> extends { data: infer D } ? D : void;

/** Uses Pi's documented JSONL protocol and exported wire types. Its RpcClient
 * has no public extension-UI response method, which this host must support. */
export class PiRpc extends EventEmitter<{
  event: [PiRpcEvent]; stderr: [string]; exit: [Error];
}> {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly lines: Interface;
  private readonly pending = new Map<string, {
    command: string; resolve(value: unknown): void; reject(error: Error): void; timer: NodeJS.Timeout;
  }>();
  private sequence = 0;
  private closed = false;
  private exited = false;
  private closing = false;
  private readonly done: Promise<void>;

  constructor(options: { cwd: string; agentDir: string; sessionFile?: string | null; temporary?: boolean; entry?: string }) {
    super();
    const env: NodeJS.ProcessEnv = { ...process.env, PI_CODING_AGENT_DIR: options.agentDir };
    delete env.SIDEMESH_TOKEN;
    const entry = options.entry ?? fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent/rpc-entry"));
    const args = [entry];
    if (options.sessionFile) args.push("--session", options.sessionFile);
    if (options.temporary) args.push("--no-session");
    this.child = spawn(process.execPath, args, { cwd: options.cwd, env, stdio: "pipe", detached: process.platform !== "win32" });
    this.done = new Promise((resolve) => this.child.once("close", (code, signal) => {
      this.exited = true;
      this.fail(new Error(`Pi RPC exited (${signal ?? code ?? "unknown"})`));
      resolve();
    }));
    this.lines = createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    this.lines.on("line", (line) => this.receive(line));
    this.child.stderr.on("data", (data: Buffer) => this.emit("stderr", data.toString("utf8")));
    this.child.on("error", (error) => this.fail(error));
    this.child.stdin.on("error", (error) => this.fail(error));
  }

  request<T extends RpcCommand["type"]>(command: Extract<RpcCommand, { type: T }>, timeoutMs = 30_000): Promise<PiRpcResult<T>> {
    if (this.closed) return Promise.reject(new Error("Pi RPC is closed"));
    const id = `sidemesh-${++this.sequence}`;
    return new Promise<PiRpcResult<T>>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.fail(new Error(`Pi RPC ${command.type} timed out`));
        void this.close();
      }, timeoutMs);
      this.pending.set(id, { command: command.type, resolve: (value) => resolve(value as PiRpcResult<T>), reject, timer });
      this.child.stdin.write(`${JSON.stringify({ ...command, id })}\n`, (error) => {
        if (error) this.fail(error);
      });
    });
  }

  respond(response: RpcExtensionUIResponse): void {
    if (this.closed) throw new Error("Pi RPC is closed");
    this.child.stdin.write(`${JSON.stringify(response)}\n`, (error) => { if (error) this.fail(error); });
  }

  close(): Promise<void> {
    if (this.closing) return this.done;
    this.closing = true;
    this.fail(new Error("Pi RPC closed"));
    this.lines.close();
    if (!this.exited) terminatePipeProcess(this.child, () => this.exited);
    return this.done;
  }

  private receive(line: string): void {
    if (this.closed || !line.trim()) return;
    try {
      const message: unknown = JSON.parse(line);
      if (!message || typeof message !== "object" || !("type" in message) || typeof message.type !== "string") {
        throw new Error("Invalid Pi RPC message");
      }
      if (message.type !== "response") {
        this.emit("event", message as PiRpcEvent);
        return;
      }
      if (!("id" in message) || typeof message.id !== "string") throw new Error("Pi RPC response has no request ID");
      const pending = this.pending.get(message.id);
      if (!pending) return;
      if (!("command" in message) || message.command !== pending.command || !("success" in message) || typeof message.success !== "boolean") {
        throw new Error("Pi RPC response does not match its request");
      }
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.success) pending.resolve("data" in message ? message.data : undefined);
      else pending.reject(new Error("error" in message && typeof message.error === "string" ? message.error : "Pi RPC request failed"));
    } catch (error) {
      this.fail(error instanceof Error ? error : new Error(String(error)));
      void this.close();
    }
  }

  private fail(error: Error): void {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
    this.emit("exit", error);
  }
}
