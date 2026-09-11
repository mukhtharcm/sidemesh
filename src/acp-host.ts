import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { z } from "zod";
import {
  client, CreateElicitationRequest, methods, RequestError,
  type ClientApp, type ClientRequestContext, type CreateTerminalRequest,
  type ReadTextFileRequest, type WriteTextFileRequest,
  type RequestPermissionRequest, type RequestPermissionResponse,
  type CreateElicitationResponse, type TerminalExitStatus,
  type AuthMethod, type SessionNotification,
} from "@agentclientprotocol/sdk";

import { parsePendingActionDecision, parsePendingActionElicitationResponse,
  parsePendingActionProviderOptionResponse, parsePendingActionUserInputResponse, type PendingActionResponseInput } from "./approvals.js";
import type { AgentPendingAction, AgentProviderLiveEvent } from "./agent-provider.js";
import type { AcpxPermissionMode, PendingActionApprovalTarget } from "./types.js";
import { elicitationFields } from "./elicitation.js";
import { writeFileAtomically } from "./fs-routes.js";
import type { AuthenticationTerminalRequest } from "./terminal.js";
import { terminatePipeProcess } from "./terminal.js";
import { resolveWorkspacePath, WorkspaceAccessError } from "./workspace-scope.js";

interface AcpTerminal {
  child: ChildProcessWithoutNullStreams;
  output: Buffer;
  truncated: boolean;
  exitStatus?: TerminalExitStatus;
  done: Promise<TerminalExitStatus>;
}

/** Host resources for one ACP connection and one native session. */
export class AcpHost {
  readonly app: ClientApp;
  nativeSessionId: string | null = null;
  private closed = false;
  private readonly terminals = new Map<string, AcpTerminal>();
  private readonly pending = new Map<string, {
    respond(input: PendingActionResponseInput): boolean;
    cancel(): void;
    elicitationId?: string;
  }>();

  constructor(
    readonly sessionId: string,
    readonly cwd: string,
    private readonly permissionMode: AcpxPermissionMode,
    private readonly emit: (event: AgentProviderLiveEvent) => void,
    onUpdate?: (notification: SessionNotification) => void,
  ) {
    this.app = client();
    // SDK 1.4 walks each handler asynchronously. Keep this synchronous handler
    // first so a following prompt/load response cannot overtake transcript writes.
    if (onUpdate) this.app.onNotification(methods.client.session.update, ({ params }) => onUpdate(params));
    this.app.onRequest(methods.client.session.requestPermission, (ctx) => this.permission(ctx))
      .onRequest(methods.client.fs.readTextFile, (ctx) => this.readTextFile(ctx))
      .onRequest(methods.client.fs.writeTextFile, (ctx) => this.writeTextFile(ctx))
      .onRequest(methods.client.terminal.create, (ctx) => this.createTerminal(ctx))
      .onRequest(methods.client.terminal.output, ({ params }) => {
        const terminal = this.terminal(params.sessionId, params.terminalId);
        return { output: terminal.output.toString("utf8"), truncated: terminal.truncated, exitStatus: terminal.exitStatus };
      })
      .onRequest(methods.client.terminal.waitForExit, ({ params }) => this.terminal(params.sessionId, params.terminalId).done)
      .onRequest(methods.client.terminal.kill, async ({ params }) => {
        await this.stopTerminal(this.terminal(params.sessionId, params.terminalId));
        return {};
      })
      .onRequest(methods.client.terminal.release, async ({ params }) => {
        await this.stopTerminal(this.terminal(params.sessionId, params.terminalId));
        this.terminals.delete(params.terminalId);
        return {};
      })
      .onRequest(methods.client.elicitation.create, (ctx) => this.elicitation(ctx))
      .onNotification(methods.client.elicitation.complete, ({ params }) => {
        for (const pending of this.pending.values()) {
          if (pending.elicitationId === params.elicitationId) pending.cancel();
        }
      });
  }

  respond(actionId: string, input: PendingActionResponseInput): boolean {
    return this.pending.get(actionId)?.respond(input) ?? false;
  }

  async selectAuthentication(authMethods: AuthMethod[], signal: AbortSignal, terminal = false): Promise<string | null> {
    const offered = authMethods.filter((method) => terminal || !("type" in method && method.type === "terminal"));
    if (!offered.length) return null;
    const choices = [...offered.map((method) => `${method.name} (${method.id})`), "Cancel sign-in"];
    const action: AgentPendingAction = {
      ...this.action("tool", "Agent sign-in", "Select the agent sign-in method.", []),
      kind: "user_input", approval: undefined, canApprove: false, canDecline: false,
      userInput: { question: "Select the agent sign-in method.", choices, allowFreeform: false },
    };
    const result = await this.ask<{ methodId: string | null }>(action, signal, (input) => {
      const response = parsePendingActionUserInputResponse(input);
      const index = response ? choices.indexOf(response.answer) : -1;
      return index >= 0 ? { methodId: offered[index]?.id ?? null } : null;
    }, { methodId: null });
    return result.methodId;
  }

  async authenticateInTerminal(
    run: (request: AuthenticationTerminalRequest) => Promise<void>,
    request: Omit<AuthenticationTerminalRequest, "cwd" | "sessionId" | "onReady">,
  ): Promise<void> {
    const cancelled = new AbortController();
    try {
      await run({ ...request, cwd: this.cwd, sessionId: this.sessionId,
        signal: AbortSignal.any([request.signal, cancelled.signal]),
        onReady: (terminalId) => {
          const action: AgentPendingAction = {
            ...this.action("tool", "Agent sign-in", "Open the terminal to sign in.", []),
            terminalId, kind: "user_input", approval: undefined, canApprove: false, canDecline: false,
            userInput: { question: "Complete sign-in in the terminal.", choices: ["Cancel sign-in"], allowFreeform: false },
          };
          void this.ask(action, cancelled.signal, (input) =>
            parsePendingActionUserInputResponse(input)?.answer === "Cancel sign-in" ? true : null, false)
            .then(() => cancelled.abort());
        },
      });
    } finally { cancelled.abort(); }
  }

  cancelPending(): void {
    for (const pending of [...this.pending.values()]) pending.cancel();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.cancelPending();
    await Promise.all([...this.terminals.values()].map((terminal) => this.stopTerminal(terminal)));
    this.terminals.clear();
  }

  private checkSession(sessionId: string): void {
    if (this.closed || !this.nativeSessionId || sessionId !== this.nativeSessionId) {
      throw RequestError.invalidParams(undefined, "Unknown or closed ACP session");
    }
  }

  private async permission({ params, signal }: ClientRequestContext<RequestPermissionRequest>): Promise<RequestPermissionResponse> {
    this.checkSession(params.sessionId);
    if (this.permissionMode === "deny-all") return { outcome: { outcome: "cancelled" } };
    const readOnly = params.toolCall.kind === "read" || params.toolCall.kind === "search";
    const once = params.options.find((option) => option.kind === "allow_once");
    // Automatic read approval never substitutes a lasting permission.
    if (readOnly && once) return { outcome: { outcome: "selected", optionId: once.optionId } };
    const kind = params.toolCall.kind === "execute" ? "command"
      : ["edit", "delete", "move"].includes(params.toolCall.kind ?? "") ? "file_change" : "tool";
    const title = params.toolCall.title || "Agent permission";
    const targets: PendingActionApprovalTarget[] = (params.toolCall.locations ?? []).map((location) => ({
      type: "file", path: location.path, access: kind === "file_change" ? "write" : "read",
    }));
    if (!targets.length) targets.push({ type: "tool", name: params.toolCall.name ?? title, args: params.toolCall.rawInput });
    const action = this.action(kind, title, JSON.stringify(params.toolCall.rawInput ?? {}), targets);
    action.approval!.providerOptions = params.options.map((option) => ({
      id: option.optionId, label: option.name, kind: option.kind,
    }));
    action.approval!.supportedScopes = [
      ...(once ? ["once" as const] : []),
      ...(params.options.some((option) => option.kind === "allow_always") ? ["session" as const] : []),
    ];
    action.canApprove = params.options.some((option) => option.kind.startsWith("allow_"));
    action.canApproveForSession = params.options.some((option) => option.kind === "allow_always");
    return this.ask(action, signal, (input) => {
      const exact = parsePendingActionProviderOptionResponse(input);
      if (exact) return params.options.some((option) => option.optionId === exact.providerOptionId)
        ? { outcome: { outcome: "selected", optionId: exact.providerOptionId } } : null;
      const decision = parsePendingActionDecision(input);
      if (!decision) return null;
      if (decision.decision === "cancel") return { outcome: { outcome: "cancelled" } };
      const wanted = decision.decision === "decline" ? "reject_once"
        : decision.scope === "once" ? "allow_once" : decision.scope === "session" ? "allow_always" : null;
      const matches = params.options.filter((option) => option.kind === wanted);
      // The old generic button is safe only when it identifies one exact choice.
      return matches.length === 1 ? { outcome: { outcome: "selected", optionId: matches[0]!.optionId } } : null;
    }, { outcome: { outcome: "cancelled" } });
  }

  private async readTextFile({ params, signal }: ClientRequestContext<ReadTextFileRequest>): Promise<{ content: string }> {
    this.checkSession(params.sessionId);
    if (this.permissionMode === "deny-all") throw RequestError.requestCancelled();
    signal.throwIfAborted();
    const path = await acpWorkspacePath(params.path, [this.cwd]);
    if ((await stat(path)).size > 8 * 1024 * 1024) throw RequestError.invalidParams(undefined, "File exceeds 8 MiB");
    const content = await readFile(path, "utf8");
    const start = (params.line ?? 1) - 1;
    if (start < 0 || !Number.isInteger(start) || (params.limit != null && (!Number.isInteger(params.limit) || params.limit < 0))) {
      throw RequestError.invalidParams(undefined, "Invalid line range");
    }
    return { content: params.line == null && params.limit == null ? content
      : content.split("\n").slice(start, params.limit == null ? undefined : start + params.limit).join("\n") };
  }

  private async writeTextFile({ params, signal }: ClientRequestContext<WriteTextFileRequest>): Promise<Record<string, never>> {
    this.checkSession(params.sessionId);
    if (Buffer.byteLength(params.content) > 8 * 1024 * 1024) throw RequestError.invalidParams(undefined, "File exceeds 8 MiB");
    const path = await acpWorkspacePath(params.path, [this.cwd], { allowMissing: true });
    const before = await readOptionalFile(path);
    const action = this.action("file_change", "Write file", params.path, [{
      type: "file", path, access: "write", diff: params.content,
    }]);
    await this.approveHostAction(action, signal);
    this.checkSession(params.sessionId);
    const checkedPath = await acpWorkspacePath(params.path, [this.cwd], { allowMissing: true });
    const current = await readOptionalFile(checkedPath);
    if (checkedPath !== path || (before === null ? current !== null : current === null || !before.equals(current))) {
      throw RequestError.invalidParams(undefined, "File changed while approval was pending; request approval again");
    }
    signal.throwIfAborted();
    this.checkSession(params.sessionId);
    await writeFileAtomically(path, Buffer.from(params.content));
    return {};
  }

  private async createTerminal({ params, signal }: ClientRequestContext<CreateTerminalRequest>): Promise<{ terminalId: string }> {
    this.checkSession(params.sessionId);
    if (this.terminals.size >= 12) throw RequestError.invalidParams(undefined, "Release an existing terminal first");
    const cwd = await acpWorkspacePath(params.cwd ?? this.cwd, [this.cwd]);
    const command = [params.command, ...(params.args ?? [])].join(" ");
    const action = this.action("command", "Run command", command, [{ type: "command", command, cwd }]);
    await this.approveHostAction(action, signal);
    this.checkSession(params.sessionId);
    signal.throwIfAborted();
    // Recheck scope after the user has had time to change files or links.
    if (await acpWorkspacePath(params.cwd ?? this.cwd, [this.cwd]) !== cwd) throw RequestError.invalidParams();
    this.checkSession(params.sessionId);
    signal.throwIfAborted();
    if (this.terminals.size >= 12) throw RequestError.invalidParams(undefined, "Release an existing terminal first");
    const env: NodeJS.ProcessEnv = { ...process.env, ...Object.fromEntries((params.env ?? []).map(({ name, value }) => [name, value])) };
    delete env.SIDEMESH_TOKEN;
    env.SIDEMESH_TERMINAL_SESSION = "1";
    const child = spawn(params.command, params.args ?? [], { cwd, env, stdio: "pipe", detached: process.platform !== "win32" });
    const terminalId = randomUUID();
    const limit = Math.min(1024 * 1024, Math.max(0, Math.trunc(params.outputByteLimit ?? 512 * 1024)));
    const terminal: AcpTerminal = { child, output: Buffer.alloc(0), truncated: false, done: Promise.resolve({}) };
    terminal.done = new Promise((resolve) => child.once("close", (exitCode, signal) => {
      terminal.exitStatus = { exitCode, signal };
      resolve(terminal.exitStatus);
    }));
    const append = (chunk: Buffer) => {
      terminal.output = Buffer.concat([terminal.output, chunk]);
      if (terminal.output.length > limit) {
        let start = terminal.output.length - limit;
        while (start < terminal.output.length && (terminal.output[start]! & 0xc0) === 0x80) start++;
        terminal.output = terminal.output.subarray(start);
        terminal.truncated = true;
      }
    };
    child.stdout.on("data", append);
    child.stderr.on("data", append);
    child.stdin.end();
    this.terminals.set(terminalId, terminal);
    try {
      await new Promise<void>((resolve, reject) => { child.once("spawn", resolve); child.once("error", reject); });
    } catch (error) {
      this.terminals.delete(terminalId);
      throw error;
    }
    return { terminalId };
  }

  private terminal(sessionId: string, terminalId: string): AcpTerminal {
    this.checkSession(sessionId);
    const terminal = this.terminals.get(terminalId);
    if (!terminal) throw RequestError.resourceNotFound(terminalId);
    return terminal;
  }

  private async stopTerminal(terminal: AcpTerminal): Promise<void> {
    if (!terminal.exitStatus) terminatePipeProcess(terminal.child, () => Boolean(terminal.exitStatus));
    await terminal.done;
  }

  private async elicitation({ params, signal }: ClientRequestContext<import("@agentclientprotocol/sdk").CreateElicitationRequest>): Promise<CreateElicitationResponse> {
    if ("sessionId" in params && typeof params.sessionId === "string") this.checkSession(params.sessionId);
    else if (this.closed) return { action: "cancel" };
    const form = CreateElicitationRequest.isForm(params);
    const url = CreateElicitationRequest.isUrl(params);
    if (!form && !url) return { action: "cancel" };
    const fields = form ? elicitationFields(params.requestedSchema) : [];
    if (form && params.requestedSchema.required?.some((key) => !fields.some((field) => field.key === key))) return { action: "cancel" };
    const action: AgentPendingAction = {
      ...this.action("tool", "Agent input", params.message, []), kind: "elicitation", approval: undefined,
      canApprove: false, canApproveForSession: false,
      elicitation: { mode: url ? "url" : "form", message: params.message, fields, ...(url ? { url: params.url } : {}) },
    };
    // ACP permits null for omitted schema keywords; JSON Schema omits them.
    const schema = form ? z.fromJSONSchema(JSON.parse(JSON.stringify(
      params.requestedSchema, (_key, value: unknown) => value === null ? undefined : value,
    ))) : null;
    return this.ask<CreateElicitationResponse>(action, signal, (input) => {
      const response = parsePendingActionElicitationResponse(input);
      if (!response) return null;
      if (response.action === "accept") {
        if (schema && !schema.safeParse(response.content ?? {}).success) return null;
        return { action: "accept", ...(response.content ? { content: response.content } : {}) };
      }
      return { action: response.action };
    }, { action: "cancel" }, url ? params.elicitationId : undefined);
  }

  private action(kind: "command" | "file_change" | "tool", title: string, detail: string, targets: PendingActionApprovalTarget[]): AgentPendingAction {
    const id = `acp-approval-${randomUUID()}`;
    return {
      id, sessionId: this.sessionId, kind, title, detail, requestedAt: Date.now(), cwd: this.cwd,
      canApprove: true, canApproveForSession: false, canDecline: true,
      approval: { category: kind, operation: kind, summary: title, detail, cwd: this.cwd, targets, supportedScopes: ["once"], suggestedScope: "once" },
      providerRequestId: id, providerRequestKind: "acp/host",
    };
  }

  private async approveHostAction(action: AgentPendingAction, signal: AbortSignal): Promise<void> {
    if (this.permissionMode === "deny-all") throw RequestError.requestCancelled();
    const allowed = await this.ask(action, signal, (input) => {
      const decision = parsePendingActionDecision(input);
      if (!decision || (decision.decision === "approve" && decision.scope !== "once")) return null;
      return decision.decision === "approve";
    }, false);
    if (!allowed) throw RequestError.requestCancelled();
  }

  private ask<T>(action: AgentPendingAction, signal: AbortSignal,
    parse: (input: PendingActionResponseInput) => T | null, cancelled: T, elicitationId?: string): Promise<T> {
    if (this.closed || signal.aborted) return Promise.resolve(cancelled);
    return new Promise((resolve) => {
      const finish = (value: T, notify: boolean) => {
        if (!this.pending.delete(action.id)) return;
        signal.removeEventListener("abort", cancel);
        if (notify) this.emit({ type: "action_resolved", sessionId: this.sessionId, actionId: action.id });
        resolve(value);
      };
      const cancel = () => finish(cancelled, true);
      this.pending.set(action.id, { cancel, elicitationId, respond: (input) => {
        const parsed = parse(input);
        if (parsed === null) return false;
        finish(parsed, false);
        return true;
      } });
      signal.addEventListener("abort", cancel, { once: true });
      this.emit({ type: "action_opened", action });
    });
  }
}

async function readOptionalFile(path: string): Promise<Buffer | null> {
  try {
    if ((await stat(path)).size > 8 * 1024 * 1024) throw RequestError.invalidParams(undefined, "File exceeds 8 MiB");
    return await readFile(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}

async function acpWorkspacePath(...args: Parameters<typeof resolveWorkspacePath>): Promise<string> {
  try { return await resolveWorkspacePath(...args); }
  catch (error) {
    if (error instanceof WorkspaceAccessError) throw RequestError.invalidParams(undefined, error.message);
    throw error;
  }
}
