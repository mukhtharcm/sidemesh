import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";

import {
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
  type AgentPendingAction,
  type AgentProvider,
  type AgentProviderCapabilities,
  type AgentProviderEvents,
  type AgentSessionLogOptions,
  type AgentSessionActivityDraft,
  type AgentSubmitInputRequest,
  type AgentSubmitInputResult,
} from "./agent-provider.js";
import {
  buildActivityFromThreadItem,
  buildFileChangeChanges,
  buildTurnDiffActivity,
} from "./activity.js";
import { CodexBridge } from "./codex-client.js";
import {
  listRecentRolloutThreads,
  loadRolloutLog,
  loadSessionRuntime,
} from "./codex-history.js";
import type {
  SessionActivity,
  SessionLogSnapshot,
  SessionRuntimeSummary,
  ThreadRecord,
} from "./types.js";

export class CodexAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  private readonly bridge: CodexBridge;

  public readonly kind = "codex";
  public readonly displayName = "Codex";
  public readonly capabilities = CODEX_PROVIDER_CAPABILITIES;

  public constructor(private readonly codexBin: string) {
    super();
    this.bridge = new CodexBridge(codexBin);
    this.bridge.on("notification", (message) => {
      this.emitCodexNotification(message.method, message.params);
    });
    this.bridge.on("serverRequest", (message) => {
      this.emitCodexServerRequest(message.id, message.method, message.params);
    });
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

  public async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> {
    const summaries = await listRecentRolloutThreads(this.runtimeHome, limit);
    const threads: ThreadRecord[] = [];

    for (const summary of summaries) {
      try {
        const result = (await this.readSessionThread(summary.id, false)) as {
          thread?: ThreadRecord;
        };
        threads.push(result.thread ?? summary);
      } catch {
        threads.push(summary);
      }
    }

    return threads;
  }

  public readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    return loadRolloutLog(
      thread.id,
      thread.path,
      this.runtimeHome,
      options.messageLimit ?? null,
      options.activityLimit ?? null,
    );
  }

  public readSessionRuntime(thread: ThreadRecord): Promise<SessionRuntimeSummary | null> {
    return loadSessionRuntime(thread.id, thread.path, this.runtimeHome);
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    const started = (await this.bridge.request(
      "thread/start",
      buildCodexThreadStartParams(request),
    )) as Record<string, unknown>;
    const thread = started.thread as ThreadRecord;
    const runtime = buildRuntimeFromThreadStart(started);

    let activeTurnId: string | null = null;
    if (request.input.length > 0) {
      const turn = (await this.bridge.request("turn/start", {
        threadId: thread.id,
        input: request.input,
      })) as Record<string, unknown>;
      activeTurnId = asString(
        (turn.turn as Record<string, unknown> | undefined)?.id,
      );
    }

    return {
      thread,
      activeTurnId,
      runtime,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    if (request.activeTurnId) {
      const steer = (await this.bridge.request("turn/steer", {
        threadId: request.sessionId,
        input: request.input,
        expectedTurnId: request.activeTurnId,
      })) as Record<string, unknown>;
      return {
        mode: "steer",
        turnId: asString(steer.turnId) || request.activeTurnId,
      };
    }

    if (!(await this.isSessionThreadLoaded(request.sessionId))) {
      await this.resumeSessionThread(request.sessionId, {
        persistExtendedHistory: true,
      });
    }

    const turn = (await this.bridge.request(
      "turn/start",
      buildCodexTurnStartParams(request),
    )) as Record<string, unknown>;
    return {
      mode: "turn",
      turnId: asString(
        (turn.turn as Record<string, unknown> | undefined)?.id,
      ),
    };
  }

  public interruptTurn(threadId: string, turnId: string): Promise<unknown> {
    return this.bridge.request("turn/interrupt", { threadId, turnId });
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: string | null,
  ): boolean {
    const result = buildCodexActionResponse(action, decision);
    if (!result) {
      return false;
    }
    this.bridge.respond(action.providerRequestId, result);
    return true;
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

  private async isSessionThreadLoaded(sessionId: string): Promise<boolean> {
    const result = (await this.listLoadedSessionIds()) as { data?: unknown[] };
    const data = Array.isArray(result.data) ? result.data : [];
    return data.includes(sessionId);
  }

  private emitCodexNotification(method: string, params: unknown): void {
    if (method === "fs/changed") {
      const typed = params && typeof params === "object"
        ? (params as Record<string, unknown>)
        : {};
      this.emit("liveEvent", {
        type: "fs_changed",
        watchId: asString(typed.watchId) || undefined,
        changedPaths: Array.isArray(typed.changedPaths)
          ? typed.changedPaths.map((entry) => String(entry))
          : undefined,
      });
      return;
    }

    if (method === "skills/changed") {
      this.emit("liveEvent", { type: "skills_changed" });
      return;
    }

    const sessionId = extractSessionId(method, params);
    if (!sessionId) {
      return;
    }

    const typed = params && typeof params === "object"
      ? (params as Record<string, unknown>)
      : {};

    if (method === "turn/started") {
      const turn = typed.turn && typeof typed.turn === "object"
        ? (typed.turn as Record<string, unknown>)
        : null;
      const turnId = asString(turn?.id);
      if (turnId) {
        this.emit("liveEvent", { type: "turn_started", sessionId, turnId });
      }
      return;
    }

    if (method === "item/agentMessage/delta") {
      const delta = asString(typed.delta);
      if (delta) {
        this.emit("liveEvent", {
          type: "assistant_delta",
          sessionId,
          delta,
          turnId: asString(typed.turnId) || undefined,
          itemId: asString(typed.itemId) || undefined,
        });
      }
      return;
    }

    if (method === "item/started" || method === "item/completed") {
      const item = typed.item && typeof typed.item === "object"
        ? (typed.item as Record<string, unknown>)
        : null;
      const turnId = asString(typed.turnId);
      if (!item) {
        return;
      }

      const itemType = asString(item.type);
      if (method === "item/completed" && itemType === "agentMessage") {
        const message = buildCodexAssistantMessageDraft(item);
        if (message) {
          this.emit("liveEvent", {
            type: "assistant_message_completed",
            sessionId,
            turnId: turnId || undefined,
            message,
          });
        }
        return;
      }

      const activity = buildActivityFromThreadItem(item as any, {
        turnId,
        createdAt: 0,
        seq: 0,
      });
      const draft = activity ? toActivityDraft(activity) : null;
      if (draft) {
        this.emit("liveEvent", {
          type: "activity_updated",
          sessionId,
          turnId: turnId || undefined,
          activity: draft,
        });
      }
      return;
    }

    if (method === "item/commandExecution/outputDelta") {
      const delta = asString(typed.delta);
      const activityId = asString(typed.itemId);
      if (delta && activityId) {
        this.emit("liveEvent", {
          type: "activity_output_delta",
          sessionId,
          turnId: asString(typed.turnId) || undefined,
          activityId,
          delta,
        });
      }
      return;
    }

    if (method === "item/commandExecution/terminalInteraction") {
      const stdin = asString(typed.stdin);
      const activityId = asString(typed.itemId);
      if (stdin && activityId) {
        this.emit("liveEvent", {
          type: "activity_terminal_input",
          sessionId,
          turnId: asString(typed.turnId) || undefined,
          activityId,
          stdin,
        });
      }
      return;
    }

    if (method === "item/fileChange/patchUpdated") {
      const activityId = asString(typed.itemId);
      if (activityId) {
        this.emit("liveEvent", {
          type: "activity_updated",
          sessionId,
          turnId: asString(typed.turnId) || undefined,
          activity: {
            id: activityId,
            type: "file_change",
            turnId: asString(typed.turnId),
            status: "in_progress",
            changes: buildFileChangeChanges(typed.changes),
          },
        });
      }
      return;
    }

    if (method === "turn/diff/updated") {
      const turnId = asString(typed.turnId);
      const diff = asString(typed.diff);
      if (!turnId || !diff) {
        return;
      }
      const activity = buildTurnDiffActivity(turnId, diff, 0, 0);
      const draft = activity ? toActivityDraft(activity) : null;
      if (draft) {
        this.emit("liveEvent", {
          type: "activity_updated",
          sessionId,
          turnId,
          activity: draft,
        });
      }
      return;
    }

    if (method === "turn/completed") {
      const turn = typed.turn && typeof typed.turn === "object"
        ? (typed.turn as Record<string, unknown>)
        : null;
      const turnId = asString(turn?.id);
      if (turnId) {
        this.emit("liveEvent", {
          type: "turn_completed",
          sessionId,
          turnId,
          status: asString(turn?.status) || "completed",
        });
      }
    }
  }

  private emitCodexServerRequest(
    id: number | string,
    method: string,
    params: unknown,
  ): void {
    if (
      method !== "item/commandExecution/requestApproval" &&
      method !== "item/fileChange/requestApproval" &&
      method !== "item/permissions/requestApproval"
    ) {
      return;
    }

    const sessionId = extractSessionId(method, params);
    if (!sessionId) {
      return;
    }

    this.emit("liveEvent", {
      type: "action_opened",
      action: buildCodexPendingAction(method, params, id, sessionId),
    });
  }
}

function buildCodexAssistantMessageDraft(
  item: Record<string, unknown>,
): { id: string; text: string; phase?: "commentary" | "final_answer" } | null {
  const id = asString(item.id);
  const text = asString(item.text);
  if (!id || !text) {
    return null;
  }

  const phase = asString(item.phase);
  return {
    id,
    text,
    phase:
      phase === "commentary" || phase === "final_answer"
        ? phase
        : undefined,
  };
}

function buildCodexThreadStartParams(
  request: AgentCreateSessionRequest,
): Record<string, unknown> {
  const params: Record<string, unknown> = {
    cwd: request.cwd,
    experimentalRawEvents: false,
    persistExtendedHistory: true,
  };
  const overrides = request.overrides;
  if (overrides.model) {
    params.model = overrides.model;
  }
  if (overrides.fastMode !== null) {
    params.serviceTier = overrides.fastMode ? "fast" : null;
  }
  const approvalPolicy = parseCodexApprovalPolicy(overrides.approvalPolicy);
  if (approvalPolicy) {
    params.approvalPolicy = approvalPolicy;
  }
  const sandboxMode = parseCodexSandboxMode(overrides.sandboxMode);
  if (sandboxMode) {
    params.sandbox = sandboxMode;
  }
  const config = buildCodexThreadConfigOverrides(overrides);
  if (config) {
    params.config = config;
  }
  return params;
}

function buildCodexTurnStartParams(
  request: AgentSubmitInputRequest,
): Record<string, unknown> {
  const overrides = request.overrides;
  const params: Record<string, unknown> = {
    threadId: request.sessionId,
    input: request.input,
  };
  const approvalPolicy = parseCodexApprovalPolicy(overrides.approvalPolicy);
  if (approvalPolicy) {
    params.approvalPolicy = approvalPolicy;
  }
  if (overrides.model) {
    params.model = overrides.model;
  }
  const reasoningEffort = parseCodexReasoningEffort(overrides.reasoningEffort);
  if (reasoningEffort) {
    params.effort = reasoningEffort;
  }
  if (overrides.fastMode !== null) {
    params.serviceTier = overrides.fastMode ? "fast" : null;
  }
  const sandboxMode = parseCodexSandboxMode(overrides.sandboxMode);
  if (sandboxMode || overrides.networkAccess !== null) {
    const sandboxPolicy = buildCodexSandboxPolicyV2(
      sandboxMode,
      overrides.networkAccess,
    );
    if (sandboxPolicy) {
      params.sandboxPolicy = sandboxPolicy;
    }
  }
  return params;
}

function buildRuntimeFromThreadStart(raw: unknown): SessionRuntimeSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const runtime = {
    model: asString(typed.model) ?? undefined,
    modelProvider:
      asString(typed.modelProvider) ??
      asString(typed.model_provider) ??
      undefined,
    serviceTier:
      asString(typed.serviceTier) ??
      asString(typed.service_tier) ??
      undefined,
    reasoningEffort:
      asString(typed.reasoningEffort) ??
      asString(typed.reasoning_effort) ??
      undefined,
    approvalPolicy:
      asString(typed.approvalPolicy) ??
      asString(typed.approval_policy) ??
      undefined,
    sandboxMode:
      asString((typed.sandbox as Record<string, unknown> | undefined)?.type) ??
      asString(
        (typed.permissionProfile as Record<string, unknown> | undefined)
          ?.sandboxMode,
      ) ??
      undefined,
    networkAccess:
      asOptionalBoolean(
        (typed.sandbox as Record<string, unknown> | undefined)?.networkAccess,
      ) ??
      asOptionalBoolean(
        (typed.sandbox as Record<string, unknown> | undefined)?.network_access,
      ) ??
      undefined,
  } satisfies SessionRuntimeSummary;

  if (
    !runtime.model &&
    !runtime.modelProvider &&
    !runtime.serviceTier &&
    !runtime.reasoningEffort &&
    !runtime.approvalPolicy &&
    !runtime.sandboxMode &&
    runtime.networkAccess === undefined
  ) {
    return null;
  }

  return runtime;
}

function buildCodexThreadConfigOverrides(
  overrides: AgentCreateSessionRequest["overrides"],
): Record<string, unknown> | null {
  const config: Record<string, unknown> = {};
  if (overrides.profile) {
    config.profile = overrides.profile;
  }
  const webSearch = parseCodexWebSearchMode(overrides.webSearch);
  if (webSearch) {
    config.web_search = webSearch;
  }
  const reasoningEffort = parseCodexReasoningEffort(overrides.reasoningEffort);
  if (reasoningEffort) {
    config.model_reasoning_effort = reasoningEffort;
  }
  return Object.keys(config).length > 0 ? config : null;
}

function buildCodexSandboxPolicyV2(
  mode: CodexSandboxModeValue | null,
  networkAccess: boolean | null,
): Record<string, unknown> | null {
  if (!mode) {
    return null;
  }
  switch (mode) {
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    case "read-only":
      return {
        type: "readOnly",
        networkAccess: networkAccess ?? false,
      };
    case "workspace-write":
      return {
        type: "workspaceWrite",
        networkAccess: networkAccess ?? false,
      };
  }
}

type CodexApprovalPolicyValue = "untrusted" | "on-failure" | "on-request" | "never";
type CodexSandboxModeValue = "read-only" | "workspace-write" | "danger-full-access";
type CodexWebSearchModeValue = "disabled" | "cached" | "live";
type CodexReasoningEffortValue = "none" | "minimal" | "low" | "medium" | "high" | "xhigh";

function parseCodexApprovalPolicy(value: string | null): CodexApprovalPolicyValue | null {
  switch (value) {
    case "untrusted":
    case "on-failure":
    case "on-request":
    case "never":
      return value;
    default:
      return null;
  }
}

function parseCodexSandboxMode(value: string | null): CodexSandboxModeValue | null {
  switch (value) {
    case "read-only":
    case "workspace-write":
    case "danger-full-access":
      return value;
    default:
      return null;
  }
}

function parseCodexWebSearchMode(value: string | null): CodexWebSearchModeValue | null {
  switch (value) {
    case "disabled":
    case "cached":
    case "live":
      return value;
    default:
      return null;
  }
}

function parseCodexReasoningEffort(value: string | null): CodexReasoningEffortValue | null {
  switch (value) {
    case "none":
    case "minimal":
    case "low":
    case "medium":
    case "high":
    case "xhigh":
      return value;
    default:
      return null;
  }
}

function toActivityDraft(activity: SessionActivity): AgentSessionActivityDraft {
  const { createdAt: _createdAt, seq: _seq, ...draft } = activity;
  return draft as AgentSessionActivityDraft;
}

function extractSessionId(method: string, params: unknown): string | null {
  if (!params || typeof params !== "object") {
    return null;
  }
  const typed = params as Record<string, any>;
  if (typeof typed.threadId === "string") {
    return typed.threadId;
  }
  if (method === "turn/started" && typeof typed.turn?.threadId === "string") {
    return typed.turn.threadId;
  }
  if (method === "turn/completed" && typeof typed.threadId === "string") {
    return typed.threadId;
  }
  return null;
}

function buildCodexPendingAction(
  method: string,
  params: unknown,
  providerRequestId: number | string,
  sessionId: string,
): AgentPendingAction {
  const typed = (params || {}) as Record<string, any>;
  const requestedAt = Date.now();

  if (method === "item/commandExecution/requestApproval") {
    const command = asString(typed.command) || "Command approval";
    return {
      id: asString(typed.approvalId) || randomFallbackId(),
      sessionId,
      kind: "command",
      title: "Command approval",
      detail: command,
      requestedAt,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      providerRequestId,
      providerRequestKind: method,
    };
  }

  if (method === "item/fileChange/requestApproval") {
    return {
      id: randomFallbackId(),
      sessionId,
      kind: "file_change",
      title: "File change approval",
      detail: asString(typed.reason) || "Codex wants to modify files.",
      requestedAt,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      providerRequestId,
      providerRequestKind: method,
    };
  }

  return {
    id: randomFallbackId(),
    sessionId,
    kind: "permissions",
    title: "Permission request",
    detail: formatPermissionRequestDetail(typed.reason, typed.permissions),
    requestedAt,
    canApprove: true,
    canApproveForSession: true,
    canDecline: true,
    providerRequestId,
    providerRequestKind: method,
    providerPayload: typed.permissions,
  };
}

export const CODEX_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
  sessions: {
    create: true,
    resume: true,
    rename: true,
    archive: true,
    interrupt: true,
    history: true,
    eventReplay: true,
    recentFallback: true,
  },
  input: {
    text: true,
    imageUrl: true,
    localImage: true,
    skills: true,
  },
  approvals: {
    command: true,
    fileChange: true,
    permissions: true,
    approveForSession: true,
  },
  configuration: {
    models: true,
    profiles: true,
    skills: true,
    skillManagement: true,
  },
  runtimeControls: {
    model: true,
    reasoningEffort: true,
    fastMode: true,
    approvalPolicy: true,
    sandboxMode: true,
    networkAccess: true,
    webSearch: true,
  },
  workspace: {
    filesystem: true,
    gitStatus: true,
    gitDiff: true,
    remoteGitDiff: true,
  },
};

function buildCodexActionResponse(
  action: AgentPendingAction,
  decision: string | null,
): unknown | null {
  if (!decision) {
    return null;
  }

  if (
    action.providerRequestKind === "item/commandExecution/requestApproval" ||
    action.providerRequestKind === "item/fileChange/requestApproval"
  ) {
    if (decision === "accept" || decision === "acceptForSession" || decision === "decline" || decision === "cancel") {
      return { decision };
    }
    return null;
  }

  if (action.providerRequestKind === "item/permissions/requestApproval") {
    if (decision === "accept") {
      return {
        scope: "turn",
        permissions: action.providerPayload || {},
      };
    }
    if (decision === "acceptForSession") {
      return {
        scope: "session",
        permissions: action.providerPayload || {},
      };
    }
    if (decision === "decline" || decision === "cancel") {
      return { scope: "turn", permissions: {} };
    }
  }

  return null;
}

function formatPermissionRequestDetail(reason: unknown, permissions: unknown): string {
  const parts = [asString(reason) || "Codex requested additional permissions."];
  const summary = summarizePermissions(permissions);
  if (summary) {
    parts.push(summary);
  }
  return parts.join("\n\n");
}

function summarizePermissions(permissions: unknown): string | null {
  if (!permissions || typeof permissions !== "object") {
    return null;
  }

  const typed = permissions as Record<string, any>;
  const lines: string[] = [];

  const fileSystem = typed.fileSystem as Record<string, any> | undefined;
  if (fileSystem) {
    appendPermissionPaths(lines, "File read", fileSystem.read);
    appendPermissionPaths(lines, "File write", fileSystem.write);
  }

  const network = typed.network as Record<string, any> | undefined;
  if (network) {
    if (typeof network.mode === "string") {
      lines.push(`Network: ${network.mode}`);
    } else if (network.enabled === true) {
      lines.push("Network: enabled");
    }
  }

  if (lines.length === 0) {
    const fallback = JSON.stringify(permissions, null, 2);
    return fallback === "{}" ? null : fallback;
  }

  return lines.join("\n");
}

function appendPermissionPaths(lines: string[], label: string, paths: unknown): void {
  if (!Array.isArray(paths) || paths.length === 0) {
    return;
  }
  const normalized = paths.filter((path): path is string => typeof path === "string" && path.length > 0);
  if (normalized.length === 0) {
    return;
  }
  lines.push(`${label}: ${normalized.join(", ")}`);
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function asOptionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function randomFallbackId(): string {
  return randomUUID();
}
