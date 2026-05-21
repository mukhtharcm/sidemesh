import { createHash, randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { readdir, mkdir } from "node:fs/promises";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import nodePath from "node:path";

import {
  createAcpRuntime,
  createAgentRegistry,
  createRuntimeStore,
  type AcpAgentRegistry,
  type AcpPermissionDecision,
  type AcpPermissionRequest,
  type AcpRuntime,
  type AcpRuntimeEvent,
  type AcpRuntimeHandle,
  type AcpRuntimeOptions,
  type AcpRuntimeTurn,
  type AcpRuntimeTurnAttachment,
  type AcpSessionRecord,
  type AcpSessionStore,
} from "acpx/runtime";

import {
  normalizePendingActionDecision,
  type PendingActionDecisionInput,
  type PendingActionResponseInput,
} from "./approvals.js";
import type {
  AgentCreateSessionRequest,
  AgentCreateSessionResult,
  AgentModelListOptions,
  AgentPendingAction,
  AgentProvider,
  AgentProviderCapabilities,
  AgentProviderEvents,
  AgentSessionActivityDraft,
  AgentSessionInputItem,
  AgentSessionListOptions,
  AgentSessionLogOptions,
  AgentSessionResumeOptions,
  AgentSubmitInputRequest,
  AgentSubmitInputResult,
} from "./agent-provider.js";
import type {
  AcpxPermissionMode,
  ModelSummary,
  PendingActionApproval,
  PendingActionApprovalCategory,
  PendingActionApprovalTarget,
  PendingActionKind,
  SessionActivity,
  SessionMessage,
  SessionMessageAttachment,
  SessionMessageContentBlock,
  SessionLogSnapshot,
  SessionRuntimeSummary,
  ThreadRecord,
  ToolActivitySemantic,
  ToolActivitySemanticAction,
  ToolActivitySemanticCategory,
  ToolActivitySemanticTarget,
} from "./types.js";

export interface AcpxAgentProviderOptions {
  agent: string;
  command?: string | null;
  stateDir?: string | null;
  permissionMode?: AcpxPermissionMode;
  cwd?: string | null;
  timeoutMs?: number;
}

interface AcpxAgentProviderDependencies {
  runtime?: AcpRuntime;
  runtimeFactory?: (options: AcpRuntimeOptions) => AcpRuntime;
  sessionStore?: ListableAcpSessionStore;
  agentRegistry?: AcpAgentRegistry;
}

interface ListableAcpSessionStore extends AcpSessionStore {
  listRecords(): Promise<AcpSessionRecord[]>;
}

interface ActiveAcpxTurn {
  sessionId: string;
  turnId: string;
  handle: AcpRuntimeHandle;
  turn: AcpRuntimeTurn;
  abortController: AbortController;
  outputText: string;
  reasoningText: string;
  toolFallbackIndex: number;
  queuedInputs: QueuedAcpxInput[];
}

interface QueuedAcpxInput {
  input: AgentSessionInputItem[];
  overrides: AgentSubmitInputRequest["overrides"];
}

interface PendingAcpxApproval {
  action: AgentPendingAction;
  resolve(decision: AcpPermissionDecision): void;
  signal: AbortSignal;
  abortHandler: () => void;
}

type AcpxUserContent = Array<
  | { Text: string }
  | { Mention: { uri: string; content: string } }
  | { Image: { source: string } }
>;

const require = createRequire(import.meta.url);
const DEFAULT_ACPX_AGENT = "gemini";
const DEFAULT_ACPX_TIMEOUT_MS = 10 * 60 * 1000;
const TOOL_OUTPUT_MAX_CHARS = 4_000;
const MODEL_SOURCE = "acpx";

export const ACPX_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
  sessions: {
    create: true,
    resume: true,
    rename: true,
    archive: true,
    compact: false,
    interrupt: true,
    history: true,
    eventReplay: false,
    recentFallback: true,
    searchSessions: true,
  },
  input: {
    text: true,
    imageUrl: false,
    localImage: false,
    skills: false,
    fileMentions: false,
  },
  interaction: {
    userInput: false,
    elicitation: false,
  },
  approvals: {
    command: true,
    tool: true,
    fileChange: true,
    permissions: true,
    approveForSession: true,
  },
  configuration: {
    models: true,
    profiles: false,
    skills: false,
    skillManagement: false,
  },
  runtimeControls: {
    model: true,
    mode: false,
    reasoningEffort: false,
    fastMode: false,
    approvalPolicy: false,
    sandboxMode: false,
    networkAccess: false,
    webSearch: false,
  },
  lifecycle: {
    restart: false,
  },
  usage: {
    accountLimits: false,
    localTelemetry: true,
    credits: false,
    resetWindows: false,
  },
};

export class AcpxAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  public readonly kind = "acpx";
  public readonly displayName: string;
  public readonly capabilities = ACPX_PROVIDER_CAPABILITIES;

  private readonly agent: string;
  private readonly command: string | null;
  private readonly permissionMode: AcpxPermissionMode;
  private readonly stateDir: string;
  private readonly cwd: string;
  private readonly runtime: AcpRuntime;
  private readonly store: ListableAcpSessionStore;
  private readonly agentRegistry: AcpAgentRegistry;
  private readonly agentCommand: string;
  private readonly timeoutMs: number;
  private readonly activeTurnsBySession = new Map<string, ActiveAcpxTurn>();
  private readonly activeTurnsByTurn = new Map<string, ActiveAcpxTurn>();
  private readonly loadedSessionIds = new Set<string>();
  private readonly handlesBySessionId = new Map<string, AcpRuntimeHandle>();
  private readonly pendingApprovals = new Map<string, PendingAcpxApproval>();
  private readonly sessionIdsByBackendSessionId = new Map<string, string>();

  public constructor(
    options: AcpxAgentProviderOptions,
    dependencies: AcpxAgentProviderDependencies = {},
  ) {
    super();
    this.agent = normalizeAgent(options.agent || DEFAULT_ACPX_AGENT);
    this.command = options.command?.trim() || null;
    this.permissionMode = options.permissionMode ?? "approve-reads";
    this.stateDir = nodePath.resolve(
      options.stateDir?.trim() || defaultAcpxStateDir(this.agent),
    );
    this.cwd = nodePath.resolve(options.cwd?.trim() || process.cwd());
    this.timeoutMs = Math.max(1_000, Math.trunc(options.timeoutMs ?? DEFAULT_ACPX_TIMEOUT_MS));
    this.displayName = `ACP via acpx (${this.agent})`;
    this.agentRegistry = dependencies.agentRegistry ?? createAgentRegistry({
      overrides: this.command ? { [this.agent]: this.command } : undefined,
    });
    this.agentCommand = this.agentRegistry.resolve(this.agent);
    this.store = dependencies.sessionStore ?? new FileListingAcpSessionStore(this.stateDir);
    const runtimeOptions: AcpRuntimeOptions = {
      cwd: this.cwd,
      sessionStore: this.store,
      agentRegistry: this.agentRegistry,
      permissionMode: this.permissionMode,
      nonInteractivePermissions: "deny",
      timeoutMs: this.timeoutMs,
      probeAgent: this.agent,
      onPermissionRequest: (request, context) =>
        this.handlePermissionRequest(request, context),
    };
    this.runtime =
      dependencies.runtime ??
      dependencies.runtimeFactory?.(runtimeOptions) ??
      createAcpRuntime(runtimeOptions);
  }

  public async start(): Promise<void> {
    await mkdir(nodePath.join(this.stateDir, "sessions"), { recursive: true });
  }

  public async close(): Promise<void> {
    for (const pending of [...this.pendingApprovals.values()]) {
      this.resolvePendingApproval(pending.action.id, { outcome: "cancel" });
    }
    await Promise.all(
      [...this.activeTurnsBySession.values()].map(async (active) => {
        active.abortController.abort();
        await active.turn.cancel({ reason: "provider close" }).catch(() => {});
        await active.turn.closeStream({ reason: "provider close" }).catch(() => {});
      }),
    );
    await this.releaseRuntimeHandles();
  }

  public async health(): Promise<boolean> {
    return true;
  }

  public async getVersion(): Promise<string> {
    const pkg = require("acpx/package.json") as { version?: string };
    return pkg.version ? `acpx ${pkg.version}` : "acpx";
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    const records = await this.listOwnedRecords();
    return records
      .filter((record) => Boolean(record.closed) === options.archived)
      .sort((left, right) => recordUpdatedMillis(right) - recordUpdatedMillis(left))
      .slice(0, options.limit)
      .map((record) => this.recordToThread(record, false));
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    const record = await this.requireOwnedRecord(threadId);
    this.rememberRecord(record);
    return this.recordToThread(record, includeTurns);
  }

  public async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> {
    const records = await this.listOwnedRecords();
    return records
      .filter((record) => record.closed !== true)
      .sort((left, right) => recordUpdatedMillis(right) - recordUpdatedMillis(left))
      .slice(0, limit)
      .map((record) => this.recordToThread(record, false));
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    const record = await this.requireOwnedRecord(thread.id);
    return mapAcpxRecordToSessionLog(record, options);
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    const record = await this.requireOwnedRecord(thread.id);
    return runtimeSummaryFromRecord(record);
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    return [...new Set([
      ...this.loadedSessionIds,
      ...this.activeTurnsBySession.keys(),
    ])];
  }

  public async resumeSessionThread(
    threadId: string,
    options: AgentSessionResumeOptions = { persistExtendedHistory: false },
  ): Promise<unknown> {
    const record = await this.requireOwnedRecord(threadId);
    const handle = await this.ensureHandleForRecord(record, options);
    this.loadedSessionIds.add(handle.acpxRecordId ?? threadId);
    return { resumed: true };
  }

  public async setSessionName(threadId: string, name: string): Promise<unknown> {
    const record = await this.requireOwnedRecord(threadId);
    record.name = name.trim();
    record.title = record.name || record.title;
    record.lastUsedAt = new Date().toISOString();
    record.updated_at = record.lastUsedAt;
    await this.store.save(record);
    return { renamed: true };
  }

  public async archiveSession(threadId: string): Promise<unknown> {
    const record = await this.requireOwnedRecord(threadId);
    const active = this.activeTurnsBySession.get(threadId);
    if (active) {
      await this.interruptTurn(threadId, active.turnId);
    }
    // Mark the acpx record closed without calling ensureSession(). Archiving
    // should never spawn or download an ACP agent just to update local state.
    record.closed = true;
    record.closedAt = new Date().toISOString();
    record.lastUsedAt = record.closedAt;
    record.updated_at = record.closedAt;
    await this.store.save(record);
    const handle = this.handlesBySessionId.get(threadId);
    if (handle) {
      await this.runtime.close({
        handle,
        reason: "Sidemesh archive",
        discardPersistentState: false,
      }).catch(() => {});
    }
    return { archived: true };
  }

  public async unarchiveSession(threadId: string): Promise<unknown> {
    const record = await this.requireOwnedRecord(threadId);
    record.closed = false;
    record.closedAt = undefined;
    record.lastUsedAt = new Date().toISOString();
    record.updated_at = record.lastUsedAt;
    await this.store.save(record);
    return { unarchived: true };
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    const cwd = nodePath.resolve(request.cwd || this.cwd);
    const sessionKey = `sidemesh-${randomUUID()}`;
    const handle = await this.runtime.ensureSession({
      sessionKey,
      agent: this.agent,
      mode: "persistent",
      cwd,
      sessionOptions: sessionOptionsFromOverrides(request.overrides),
    });
    const sessionId = handle.acpxRecordId ?? sessionKey;
    this.loadedSessionIds.add(sessionId);
    this.rememberHandle(sessionId, handle);

    let activeTurnId: string | null = null;
    if (request.input.length > 0) {
      activeTurnId = await this.startPromptTurn({
        sessionId,
        handle,
        input: request.input,
        overrides: request.overrides,
      });
    }

    const record = await this.requireOwnedRecord(sessionId);
    const thread = this.recordToThread(record, false);
    const preview = previewFromInput(request.input);
    if (preview) {
      thread.preview = preview;
    }
    return {
      thread,
      activeTurnId,
      runtime: runtimeSummaryFromRecord(record),
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    const active = this.activeTurnsBySession.get(request.sessionId);
    if (active) {
      active.queuedInputs.push({
        input: request.input,
        overrides: request.overrides,
      });
      this.emitQueueUpdated(active);
      return {
        mode: "steer",
        turnId: active.turnId,
      };
    }

    const record = await this.requireOwnedRecord(request.sessionId);
    const handle = await this.ensureHandleForRecord(record, {
      model: request.overrides.model ?? undefined,
      persistExtendedHistory: true,
    });
    const turnId = await this.startPromptTurn({
      sessionId: request.sessionId,
      handle,
      input: request.input,
      overrides: request.overrides,
    });
    return {
      mode: "turn",
      turnId,
    };
  }

  public async interruptTurn(threadId: string, turnId: string): Promise<unknown> {
    const active = this.activeTurnsBySession.get(threadId);
    if (!active || active.turnId !== turnId) {
      return { interrupted: false };
    }
    this.resolvePendingApprovalsForSession(threadId, { outcome: "cancel" });
    active.abortController.abort();
    await active.turn.cancel({ reason: "Sidemesh interrupt" }).catch(() => {});
    return { interrupted: true };
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean {
    const normalized = normalizePendingActionDecision(
      decision as PendingActionDecisionInput,
    );
    if (!normalized) {
      return false;
    }
    let acpxDecision: AcpPermissionDecision;
    switch (normalized.decision) {
      case "approve":
        acpxDecision = {
          outcome: normalized.scope === "once" ? "allow_once" : "allow_always",
        };
        break;
      case "decline":
        acpxDecision = { outcome: "reject_once" };
        break;
      case "cancel":
        acpxDecision = { outcome: "cancel" };
        break;
    }
    return this.resolvePendingApproval(action.id, acpxDecision);
  }

  public async listModels(_options: AgentModelListOptions): Promise<ModelSummary[]> {
    const records = await this.listOwnedRecords();
    const modelIds = new Set<string>();
    let currentModel: string | null = null;
    for (const record of records) {
      if (record.acpx?.current_model_id) {
        currentModel ??= record.acpx.current_model_id;
        modelIds.add(record.acpx.current_model_id);
      }
      for (const modelId of record.acpx?.available_models ?? []) {
        modelIds.add(modelId);
      }
    }
    return [...modelIds].sort().map((modelId) => ({
      id: modelId,
      model: modelId,
      displayName: modelId,
      description: `ACP model advertised by ${this.agent}`,
      defaultReasoningEffort: "auto",
      supportedReasoningEfforts: [],
      reasoningEffortControl: "provider",
      supportsPersonality: false,
      additionalSpeedTiers: [],
      inputModalities: ["text"],
      isDefault: currentModel === modelId,
      source: MODEL_SOURCE,
    }));
  }

  private async startPromptTurn(input: {
    sessionId: string;
    handle: AcpRuntimeHandle;
    input: AgentSessionInputItem[];
    overrides: AgentSubmitInputRequest["overrides"];
  }): Promise<string> {
    await this.applyTurnOverrides(input.handle, input.overrides);
    const turnId = `acpx-turn-${randomUUID()}`;
    const text = promptTextFromInput(input.input);
    const attachments = attachmentsFromInput(input.input);
    const abortController = new AbortController();
    const turn = this.runtime.startTurn({
      handle: input.handle,
      text,
      attachments,
      mode: "prompt",
      requestId: turnId,
      timeoutMs: this.timeoutMs,
      signal: abortController.signal,
    });
    const active: ActiveAcpxTurn = {
      sessionId: input.sessionId,
      turnId,
      handle: input.handle,
      turn,
      abortController,
      outputText: "",
      reasoningText: "",
      toolFallbackIndex: 0,
      queuedInputs: [],
    };
    this.activeTurnsBySession.set(input.sessionId, active);
    this.activeTurnsByTurn.set(turnId, active);
    this.loadedSessionIds.add(input.sessionId);
    this.emit("liveEvent", {
      type: "turn_started",
      sessionId: input.sessionId,
      turnId,
    });
    this.emitThreadStatus(input.sessionId, "running");
    void this.consumeTurn(active);
    return turnId;
  }

  private async consumeTurn(active: ActiveAcpxTurn): Promise<void> {
    let status: "completed" | "failed" | "interrupted" = "completed";
    try {
      for await (const event of active.turn.events) {
        this.handleRuntimeEvent(active, event);
      }
      const result = await active.turn.result;
      if (result.status === "cancelled") {
        status = "interrupted";
      } else if (result.status === "failed") {
        status = "failed";
        this.emit("liveEvent", {
          type: "provider_warning",
          sessionId: active.sessionId,
          level: "error",
          code: result.error.code,
          message: result.error.message,
          source: "acpx/runtime",
        });
      }
    } catch (error) {
      status = "failed";
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId: active.sessionId,
        level: "error",
        code: "acpx_turn_error",
        message: formatError(error),
        source: "acpx/runtime",
      });
    } finally {
      this.completeActiveTurn(active, status);
      await this.startNextQueuedTurn(active).catch((error) => {
        this.emit("liveEvent", {
          type: "provider_warning",
          sessionId: active.sessionId,
          level: "error",
          code: "acpx_queue_error",
          message: formatError(error),
          source: "acpx/runtime",
        });
      });
    }
  }

  private handleRuntimeEvent(active: ActiveAcpxTurn, event: AcpRuntimeEvent): void {
    switch (event.type) {
      case "text_delta":
        if (event.stream === "thought") {
          active.reasoningText += event.text;
          this.emit("liveEvent", {
            type: "reasoning_delta",
            sessionId: active.sessionId,
            turnId: active.turnId,
            itemId: `acpx-reasoning-${active.turnId}`,
            reasoningId: `acpx-reasoning-${active.turnId}`,
            delta: event.text,
            summary: false,
          });
        } else {
          active.outputText += event.text;
          this.emit("liveEvent", {
            type: "assistant_delta",
            sessionId: active.sessionId,
            turnId: active.turnId,
            itemId: `acpx-assistant-${active.turnId}`,
            delta: event.text,
          });
        }
        return;
      case "tool_call":
        this.emit("liveEvent", {
          type: "activity_updated",
          sessionId: active.sessionId,
          turnId: active.turnId,
          activity: toolActivityFromRuntimeEvent(active, event),
        });
        return;
      case "status":
        if (event.tag === "usage_update") {
          this.emit("liveEvent", {
            type: "runtime_updated",
            sessionId: active.sessionId,
            runtime: runtimeSummaryFromUsageEvent(event),
          });
        }
        return;
      case "error":
        this.emit("liveEvent", {
          type: "provider_warning",
          sessionId: active.sessionId,
          level: "error",
          code: event.code,
          message: event.message,
          source: "acpx/runtime",
        });
        return;
      case "done":
        return;
    }
  }

  private completeActiveTurn(
    active: ActiveAcpxTurn,
    status: "completed" | "failed" | "interrupted",
  ): void {
    this.activeTurnsBySession.delete(active.sessionId);
    this.activeTurnsByTurn.delete(active.turnId);
    this.resolvePendingApprovalsForSession(active.sessionId, { outcome: "cancel" });
    if (active.outputText.trim().length > 0 || active.reasoningText.trim().length > 0) {
      const content: SessionMessageContentBlock[] = [];
      if (active.reasoningText.trim().length > 0) {
        content.push({
          type: "thinking",
          thinking: active.reasoningText,
          reasoningId: `acpx-reasoning-${active.turnId}`,
        });
      }
      if (active.outputText.trim().length > 0) {
        content.push({ type: "text", text: active.outputText });
      }
      this.emit("liveEvent", {
        type: "assistant_message_completed",
        sessionId: active.sessionId,
        turnId: active.turnId,
        message: {
          id: `acpx-assistant-${active.turnId}`,
          text: active.outputText,
          content,
          phase: "final_answer",
        },
      });
    }
    this.emitThreadStatus(
      active.sessionId,
      status === "failed" ? "errored" : "idle",
      status === "failed" ? "ACP turn failed." : undefined,
    );
    this.emit("liveEvent", {
      type: "turn_completed",
      sessionId: active.sessionId,
      turnId: active.turnId,
      status,
    });
  }

  private async startNextQueuedTurn(active: ActiveAcpxTurn): Promise<void> {
    const next = active.queuedInputs.shift();
    this.emitQueueUpdated(active);
    if (!next) {
      return;
    }
    const record = await this.requireOwnedRecord(active.sessionId);
    const handle = await this.ensureHandleForRecord(record, {
      model: next.overrides.model ?? undefined,
      persistExtendedHistory: true,
    });
    const turnId = await this.startPromptTurn({
      sessionId: active.sessionId,
      handle,
      input: next.input,
      overrides: next.overrides,
    });
    const started = this.activeTurnsByTurn.get(turnId);
    if (started) {
      started.queuedInputs.push(...active.queuedInputs);
      this.emitQueueUpdated(started);
    }
  }

  private emitQueueUpdated(active: ActiveAcpxTurn): void {
    this.emit("liveEvent", {
      type: "queue_updated",
      sessionId: active.sessionId,
      steeringCount: 0,
      followUpCount: active.queuedInputs.length,
      followUpPreview: active.queuedInputs
        .slice(0, 3)
        .map((item) => previewFromInput(item.input))
        .filter((item): item is string => Boolean(item)),
    });
  }

  private async ensureHandleForRecord(
    record: AcpSessionRecord,
    options: Partial<AgentSessionResumeOptions> = {},
  ): Promise<AcpRuntimeHandle> {
    const handle = await this.runtime.ensureSession({
      sessionKey: record.acpxRecordId,
      agent: this.agent,
      mode: "persistent",
      cwd: record.cwd,
      resumeSessionId: options.model ? undefined : record.acpSessionId,
      sessionOptions: options.model ? { model: options.model } : undefined,
    });
    this.rememberHandle(record.acpxRecordId, handle);
    return handle;
  }

  private async applyTurnOverrides(
    handle: AcpRuntimeHandle,
    overrides: AgentSubmitInputRequest["overrides"],
  ): Promise<void> {
    const model = overrides.model?.trim();
    if (model && this.runtime.setConfigOption) {
      await this.runtime.setConfigOption({
        handle,
        key: "model",
        value: model,
      }).catch((error) => {
        this.emit("liveEvent", {
          type: "provider_warning",
          sessionId: handle.acpxRecordId ?? handle.sessionKey,
          level: "warning",
          code: "acpx_model_override_failed",
          message: `Failed to apply model override ${model}: ${formatError(error)}`,
          source: "acpx/runtime",
        });
      });
    }
  }

  private async handlePermissionRequest(
    request: AcpPermissionRequest,
    context: { signal: AbortSignal },
  ): Promise<AcpPermissionDecision | undefined> {
    if (this.permissionMode === "deny-all") {
      return { outcome: "reject_once" };
    }
    if (isReadOnlyPermission(request)) {
      return { outcome: "allow_once" };
    }

    const sessionId = await this.sessionIdForPermissionRequest(request);
    const actionId = `acpx-approval-${hashId(`${sessionId}:${request.raw.toolCall.toolCallId || randomUUID()}`)}`;
    const kind = pendingActionKindForPermission(request);
    const action: AgentPendingAction = {
      id: actionId,
      sessionId,
      kind,
      title: permissionTitle(request),
      detail: permissionDetail(request),
      requestedAt: Date.now(),
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      cwd: await this.cwdForSession(sessionId),
      approval: approvalFromPermissionRequest(request, await this.cwdForSession(sessionId)),
      providerRequestId: request.raw.toolCall.toolCallId || actionId,
      providerRequestKind: "acpx/permission/request",
      providerPayload: request.raw,
    };
    this.emitThreadStatus(sessionId, "waiting_for_approval", "Waiting for ACP permission approval.", kind);
    this.emit("liveEvent", { type: "action_opened", action });

    return await new Promise<AcpPermissionDecision>((resolve) => {
      const abortHandler = () => {
        this.resolvePendingApproval(actionId, { outcome: "cancel" });
      };
      const pending: PendingAcpxApproval = {
        action,
        signal: context.signal,
        abortHandler,
        resolve: (decision) => {
          context.signal.removeEventListener("abort", abortHandler);
          this.emitThreadStatus(sessionId, "running");
          resolve(decision);
        },
      };
      this.pendingApprovals.set(actionId, pending);
      if (context.signal.aborted) {
        this.resolvePendingApproval(actionId, { outcome: "cancel" });
      } else {
        context.signal.addEventListener("abort", abortHandler, { once: true });
      }
    });
  }

  private resolvePendingApproval(
    actionId: string,
    decision: AcpPermissionDecision,
  ): boolean {
    const pending = this.pendingApprovals.get(actionId);
    if (!pending) {
      return false;
    }
    this.pendingApprovals.delete(actionId);
    pending.resolve(decision);
    return true;
  }

  private resolvePendingApprovalsForSession(
    sessionId: string,
    decision: AcpPermissionDecision,
  ): void {
    for (const pending of [...this.pendingApprovals.values()]) {
      if (pending.action.sessionId === sessionId) {
        this.resolvePendingApproval(pending.action.id, decision);
      }
    }
  }

  private async releaseRuntimeHandles(): Promise<void> {
    const entries = [...this.handlesBySessionId.entries()];
    this.handlesBySessionId.clear();
    await Promise.all(
      entries.map(async ([sessionId, handle]) => {
        const before = await this.store.load(sessionId).catch(() => undefined);
        await this.runtime.close({
          handle,
          reason: "Sidemesh provider shutdown",
          discardPersistentState: false,
        }).catch(() => {});
        if (before?.closed === true) {
          return;
        }
        const after = await this.store.load(sessionId).catch(() => undefined);
        if (!after) {
          return;
        }
        after.closed = false;
        after.closedAt = undefined;
        await this.store.save(after).catch(() => {});
      }),
    );
  }

  private async sessionIdForPermissionRequest(
    request: AcpPermissionRequest,
  ): Promise<string> {
    const cached = this.sessionIdsByBackendSessionId.get(request.sessionId);
    if (cached) {
      return cached;
    }
    const records = await this.listOwnedRecords();
    const record = records.find(
      (candidate) => candidate.acpSessionId === request.sessionId,
    );
    if (record) {
      this.rememberRecord(record);
      return record.acpxRecordId;
    }
    return request.sessionId;
  }

  private async cwdForSession(sessionId: string): Promise<string | undefined> {
    const record = await this.store.load(sessionId).catch(() => undefined);
    return record?.cwd;
  }

  private emitThreadStatus(
    sessionId: string,
    status: "idle" | "running" | "waiting_for_approval" | "errored",
    message?: string,
    pendingActionKind?: PendingActionKind,
  ): void {
    this.emit("liveEvent", {
      type: "thread_status_changed",
      sessionId,
      status,
      message,
      pendingActionKind,
    });
  }

  private async listOwnedRecords(): Promise<AcpSessionRecord[]> {
    const records = await this.store.listRecords();
    return records.filter((record) => this.ownsRecord(record));
  }

  private async requireOwnedRecord(threadId: string): Promise<AcpSessionRecord> {
    const record = await this.store.load(threadId);
    if (!record || !this.ownsRecord(record)) {
      throw new Error(`ACP session not found: ${threadId}`);
    }
    return record;
  }

  private ownsRecord(record: AcpSessionRecord): boolean {
    return record.agentCommand === this.agentCommand;
  }

  private recordToThread(record: AcpSessionRecord, includeTurns: boolean): ThreadRecord {
    return mapAcpxRecordToThread(record, {
      includeTurns,
      activeTurnId: this.activeTurnsBySession.get(record.acpxRecordId)?.turnId ?? null,
    });
  }

  private rememberHandle(sessionId: string, handle: AcpRuntimeHandle): void {
    this.handlesBySessionId.set(sessionId, handle);
    if (handle.backendSessionId) {
      this.sessionIdsByBackendSessionId.set(handle.backendSessionId, sessionId);
    }
    this.loadedSessionIds.add(sessionId);
  }

  private rememberRecord(record: AcpSessionRecord): void {
    this.loadedSessionIds.add(record.acpxRecordId);
    if (record.acpSessionId) {
      this.sessionIdsByBackendSessionId.set(record.acpSessionId, record.acpxRecordId);
    }
  }
}

class FileListingAcpSessionStore implements ListableAcpSessionStore {
  private readonly delegate: AcpSessionStore;

  public constructor(private readonly stateDir: string) {
    this.delegate = createRuntimeStore({ stateDir });
  }

  public async load(sessionId: string): Promise<AcpSessionRecord | undefined> {
    return await this.delegate.load(sessionId);
  }

  public async save(record: AcpSessionRecord): Promise<void> {
    await this.delegate.save(record);
  }

  public async listRecords(): Promise<AcpSessionRecord[]> {
    const sessionsDir = nodePath.join(this.stateDir, "sessions");
    await mkdir(sessionsDir, { recursive: true });
    const entries = await readdir(sessionsDir, { withFileTypes: true });
    const records: AcpSessionRecord[] = [];
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) {
        continue;
      }
      const encodedId = entry.name.slice(0, -".json".length);
      let sessionId: string;
      try {
        sessionId = decodeURIComponent(encodedId);
      } catch {
        continue;
      }
      const record = await this.delegate.load(sessionId).catch(() => undefined);
      if (record) {
        records.push(record);
      }
    }
    return records;
  }
}

export function mapAcpxRecordToThread(
  record: AcpSessionRecord,
  options: { includeTurns?: boolean; activeTurnId?: string | null } = {},
): ThreadRecord {
  const activeTurnId = options.activeTurnId ?? null;
  const preview = recordPreview(record);
  return {
    id: record.acpxRecordId,
    name: record.name ?? record.title ?? null,
    preview,
    createdAt: secondsFromIso(record.createdAt),
    updatedAt: secondsFromIso(recordUpdatedIso(record)),
    cwd: record.cwd,
    source: "acpx",
    path: null,
    status: record.closed
      ? { type: "closed", phase: "closed" }
      : activeTurnId
        ? { type: "running", phase: "running", activeFlags: ["inProgress"] }
        : { type: "idle", phase: "idle" },
    turns: options.includeTurns
      ? activeTurnId
        ? [{ id: activeTurnId, status: "inProgress", startedAt: null, completedAt: null }]
        : []
      : undefined,
  };
}

export function mapAcpxRecordToSessionLog(
  record: AcpSessionRecord,
  options: AgentSessionLogOptions = {},
): SessionLogSnapshot {
  const messages: SessionMessage[] = [];
  const activities: SessionActivity[] = [];
  let seq = 0;
  for (const [messageIndex, message] of record.messages.entries()) {
    if (typeof message === "string") {
      continue;
    }
    if ("User" in message) {
      messages.push({
        id: message.User.id || `acpx-user-${messageIndex}`,
        role: "user",
        text: userContentText(message.User.content),
        content: userContentBlocks(message.User.content),
        attachments: userContentAttachments(message.User.content),
        createdAt: millisFromIso(record.createdAt) + seq,
        seq: seq++,
      });
      continue;
    }
    if ("Agent" in message) {
      const contentBlocks: SessionMessageContentBlock[] = [];
      const textParts: string[] = [];
      for (const [contentIndex, content] of message.Agent.content.entries()) {
        if ("Text" in content) {
          textParts.push(content.Text);
          contentBlocks.push({ type: "text", text: content.Text });
        } else if ("Thinking" in content) {
          contentBlocks.push({
            type: "thinking",
            thinking: content.Thinking.text,
            reasoningId: content.Thinking.signature ?? undefined,
          });
        } else if ("RedactedThinking" in content) {
          contentBlocks.push({
            type: "thinking",
            thinking: content.RedactedThinking,
            summary: true,
          });
        } else if ("ToolUse" in content) {
          const activity = toolActivityFromRecordContent({
            record,
            messageIndex,
            contentIndex,
            toolUse: content.ToolUse,
            result: message.Agent.tool_results[content.ToolUse.id],
            seq: seq++,
          });
          activities.push(activity);
        }
      }
      if (contentBlocks.length > 0) {
        const text = textParts.join("\n").trim();
        messages.push({
          id: `acpx-agent-${messageIndex}`,
          role: "assistant",
          text,
          content: contentBlocks,
          attachments: [],
          createdAt: millisFromIso(record.createdAt) + seq,
          seq: seq++,
          phase: text ? "final_answer" : "commentary",
        });
      }
    }
  }
  const limitedMessages = limitTail(messages, options.messageLimit ?? null);
  const limitedActivities = limitTail(activities, options.activityLimit ?? null);
  return {
    messages: limitedMessages,
    activities: limitedActivities,
    runtime: runtimeSummaryFromRecord(record),
    totalMessages: messages.length,
    totalActivities: activities.length,
    nextSeq: seq,
  };
}

function toolActivityFromRecordContent(input: {
  record: AcpSessionRecord;
  messageIndex: number;
  contentIndex: number;
  toolUse: {
    id: string;
    name: string;
    raw_input: string;
    input: unknown;
    is_input_complete: boolean;
  };
  result?: {
    tool_use_id: string;
    tool_name: string;
    is_error: boolean;
    content: unknown;
    output?: unknown;
  };
  seq: number;
}): SessionActivity {
  const output = toolResultText(input.result?.content) ?? stringifyShort(input.result?.output);
  return {
    id: input.toolUse.id || `acpx-tool-${input.messageIndex}-${input.contentIndex}`,
    type: "tool",
    turnId: null,
    createdAt: millisFromIso(input.record.createdAt) + input.seq,
    seq: input.seq,
    status: input.result ? (input.result.is_error ? "failed" : "completed") : "in_progress",
    toolName: input.toolUse.name,
    title: input.toolUse.name,
    args: input.toolUse.input ?? safeJsonParse(input.toolUse.raw_input) ?? input.toolUse.raw_input,
    output: output ?? null,
    result: input.result?.output ?? input.result?.content ?? null,
    isError: input.result?.is_error ?? null,
    semantic: semanticFromTool(input.toolUse.name, input.toolUse.input),
  };
}

function toolActivityFromRuntimeEvent(
  active: ActiveAcpxTurn,
  event: Extract<AcpRuntimeEvent, { type: "tool_call" }>,
): AgentSessionActivityDraft {
  const id = event.toolCallId
    ? `acpx-tool-${event.toolCallId}`
    : `acpx-tool-${active.turnId}-${active.toolFallbackIndex++}`;
  const status = activityStatusFromAcp(event.status);
  const output = summarizeToolRuntimeOutput(event);
  return {
    id,
    type: "tool",
    turnId: active.turnId,
    status,
    toolName: toolNameFromRuntimeEvent(event),
    title: event.title ?? event.text,
    args: event.rawInput ?? null,
    output,
    result: event.rawOutput ?? event.content ?? null,
    isError: status === "failed" ? true : status === "completed" ? false : null,
    semantic: semanticFromTool(event.title ?? event.text, event.rawInput, event.kind),
  };
}

function runtimeSummaryFromRecord(record: AcpSessionRecord): SessionRuntimeSummary | null {
  const usage = record.cumulative_token_usage;
  const hasUsage = [
    usage.input_tokens,
    usage.output_tokens,
    usage.cache_creation_input_tokens,
    usage.cache_read_input_tokens,
  ].some((value) => typeof value === "number");
  return {
    model: record.acpx?.current_model_id,
    mode: record.acpx?.current_mode_id,
    telemetry: hasUsage
      ? {
          lastUsage: {
            inputTokens: usage.input_tokens,
            outputTokens: usage.output_tokens,
            cacheWriteTokens: usage.cache_creation_input_tokens,
            cacheReadTokens: usage.cache_read_input_tokens,
            updatedAt: recordUpdatedMillis(record),
          },
        }
      : undefined,
    updatedAt: recordUpdatedMillis(record),
  };
}

function runtimeSummaryFromUsageEvent(
  event: Extract<AcpRuntimeEvent, { type: "status" }>,
): SessionRuntimeSummary | null {
  if (event.used == null && event.size == null) {
    return null;
  }
  return {
    telemetry: {
      contextWindow: {
        currentTokens: event.used ?? null,
        tokenLimit: event.size ?? event.used ?? 0,
        messagesLength: 0,
        updatedAt: Date.now(),
      },
    },
    updatedAt: Date.now(),
  };
}

function sessionOptionsFromOverrides(
  overrides: AgentCreateSessionRequest["overrides"],
): { model?: string } | undefined {
  const model = overrides.model?.trim();
  return model ? { model } : undefined;
}

function promptTextFromInput(input: AgentSessionInputItem[]): string {
  const parts = input.flatMap((item) => {
    switch (item.type) {
      case "text":
        return item.text;
      case "file":
        return item.isDirectory ? `Directory: ${item.path}` : `File: ${item.path}`;
      case "skill":
        return `Skill: ${item.name} (${item.path})`;
      case "image":
      case "localImage":
        throw new Error("acpx provider does not support image input yet");
    }
  });
  const text = parts.join("\n\n").trim();
  if (!text) {
    throw new Error("Input text is required.");
  }
  return text;
}

function attachmentsFromInput(input: AgentSessionInputItem[]): AcpRuntimeTurnAttachment[] | undefined {
  const attachments: AcpRuntimeTurnAttachment[] = [];
  for (const item of input) {
    if (item.type === "image" || item.type === "localImage") {
      throw new Error("acpx provider does not support image input yet");
    }
  }
  return attachments.length > 0 ? attachments : undefined;
}

function previewFromInput(input: AgentSessionInputItem[]): string | null {
  try {
    return truncate(promptTextFromInput(input).replace(/\s+/g, " "), 160) || null;
  } catch {
    return null;
  }
}

function isReadOnlyPermission(request: AcpPermissionRequest): boolean {
  return request.inferredKind === "read" || request.inferredKind === "search";
}

function pendingActionKindForPermission(request: AcpPermissionRequest): PendingActionKind {
  switch (request.inferredKind) {
    case "execute":
      return "command";
    case "edit":
    case "delete":
    case "move":
      return "file_change";
    default:
      return "tool";
  }
}

function approvalFromPermissionRequest(
  request: AcpPermissionRequest,
  cwd: string | undefined,
): PendingActionApproval {
  const category = approvalCategoryForPermission(request);
  return {
    category,
    operation: request.inferredKind ?? "tool",
    summary: permissionTitle(request),
    detail: permissionDetail(request),
    cwd,
    targets: permissionTargets(request, cwd),
    supportedScopes: ["once", "session"],
    suggestedScope: "once",
  };
}

function approvalCategoryForPermission(
  request: AcpPermissionRequest,
): PendingActionApprovalCategory {
  switch (request.inferredKind) {
    case "execute":
      return "command";
    case "edit":
    case "delete":
    case "move":
      return "file_change";
    case "read":
    case "search":
      return "filesystem";
    case "fetch":
      return "network";
    default:
      return "tool";
  }
}

function permissionTargets(
  request: AcpPermissionRequest,
  cwd: string | undefined,
): PendingActionApprovalTarget[] {
  const targets: PendingActionApprovalTarget[] = [];
  const command = commandFromRawInput(request.raw.toolCall.rawInput);
  if (request.inferredKind === "execute" && command) {
    targets.push({ type: "command", command, cwd });
  }
  const access = fileAccessForKind(request.inferredKind);
  for (const path of pathsFromPermission(request)) {
    targets.push({ type: "file", path, access });
  }
  const url = stringProperty(request.raw.toolCall.rawInput, ["url", "uri"]);
  if (url) {
    targets.push({ type: "url", url });
  }
  if (targets.length === 0) {
    targets.push({
      type: "tool",
      name: toolNameFromPermission(request),
      title: request.raw.toolCall.title ?? undefined,
      readOnly: isReadOnlyPermission(request),
      args: request.raw.toolCall.rawInput,
    });
  }
  return targets;
}

function pathsFromPermission(request: AcpPermissionRequest): string[] {
  const paths = new Set<string>();
  const rawPath = stringProperty(request.raw.toolCall.rawInput, [
    "path",
    "file",
    "filePath",
    "filepath",
    "target",
  ]);
  if (rawPath) {
    paths.add(rawPath);
  }
  for (const location of request.raw.toolCall.locations ?? []) {
    if (location && typeof location === "object" && "path" in location) {
      const value = (location as { path?: unknown }).path;
      if (typeof value === "string" && value.trim()) {
        paths.add(value.trim());
      }
    }
  }
  return [...paths];
}

function permissionTitle(request: AcpPermissionRequest): string {
  return request.raw.toolCall.title?.trim() || `${toolNameFromPermission(request)} permission`;
}

function permissionDetail(request: AcpPermissionRequest): string {
  const fragments = [
    request.inferredKind ? `Kind: ${request.inferredKind}` : null,
    request.raw.toolCall.rawInput !== undefined
      ? `Input: ${stringifyShort(request.raw.toolCall.rawInput)}`
      : null,
  ].filter((fragment): fragment is string => Boolean(fragment));
  return fragments.join("\n");
}

function toolNameFromPermission(request: AcpPermissionRequest): string {
  return (
    stringProperty(request.raw.toolCall.rawInput, ["name", "tool", "toolName"]) ||
    request.raw.toolCall.title?.split(/[:\s]/, 1)[0]?.trim() ||
    request.inferredKind ||
    "tool"
  );
}

function commandFromRawInput(rawInput: unknown): string | undefined {
  if (typeof rawInput === "string" && rawInput.trim()) {
    return rawInput.trim();
  }
  if (!isRecord(rawInput)) {
    return undefined;
  }
  const command = stringProperty(rawInput, ["command", "cmd", "program"]);
  if (!command) {
    return undefined;
  }
  const args = rawInput.args;
  if (!Array.isArray(args) || args.length === 0) {
    return command;
  }
  return [command, ...args.map(String)].join(" ");
}

function fileAccessForKind(kind: AcpPermissionRequest["inferredKind"]): "read" | "write" {
  return kind === "edit" || kind === "delete" || kind === "move" ? "write" : "read";
}

function toolNameFromRuntimeEvent(event: Extract<AcpRuntimeEvent, { type: "tool_call" }>): string {
  return stringProperty(event.rawInput, ["name", "tool", "toolName"]) || event.title || "tool";
}

function semanticFromTool(
  name: string,
  input: unknown,
  kind?: Extract<AcpRuntimeEvent, { type: "tool_call" }>["kind"],
): ToolActivitySemantic {
  const category = semanticCategory(kind, name);
  const action = semanticAction(kind, name);
  const targets = semanticTargets(input, kind);
  return { category, action, targets };
}

function semanticCategory(
  kind: string | undefined,
  name: string,
): ToolActivitySemanticCategory {
  const normalized = `${kind ?? ""} ${name}`.toLowerCase();
  if (kind === "execute" || /bash|shell|command|terminal/.test(normalized)) return "command";
  if (kind === "fetch" || /http|url|web|fetch/.test(normalized)) return "network";
  if (kind === "read" || kind === "edit" || kind === "delete" || kind === "move" || kind === "search") return "filesystem";
  if (/memory/.test(normalized)) return "memory";
  if (/task|todo/.test(normalized)) return "task";
  return "unknown";
}

function semanticAction(
  kind: string | undefined,
  name: string,
): ToolActivitySemanticAction {
  const normalized = `${kind ?? ""} ${name}`.toLowerCase();
  if (kind === "read" || /read|cat|open/.test(normalized)) return "read";
  if (kind === "edit" || /write|edit|patch/.test(normalized)) return "write";
  if (kind === "search" || /search|grep|find/.test(normalized)) return "search";
  if (kind === "fetch" || /fetch|http/.test(normalized)) return "fetch";
  if (kind === "execute" || /run|bash|shell|command/.test(normalized)) return "invoke";
  return "unknown";
}

function semanticTargets(
  input: unknown,
  kind?: string,
): ToolActivitySemanticTarget[] {
  const targets: ToolActivitySemanticTarget[] = [];
  const command = commandFromRawInput(input);
  if (kind === "execute" && command) {
    targets.push({ type: "command", command });
  }
  const path = stringProperty(input, ["path", "file", "filePath", "filepath", "target"]);
  if (path) {
    targets.push({
      type: "file",
      path,
      access: kind === "edit" || kind === "delete" || kind === "move" ? "write" : "read",
    });
  }
  const url = stringProperty(input, ["url", "uri"]);
  if (url) {
    targets.push({ type: "url", url });
  }
  const query = stringProperty(input, ["query", "pattern", "search"]);
  if (query) {
    targets.push({ type: "query", value: query });
  }
  if (targets.length === 0) {
    targets.push({ type: "unknown", label: stringifyShort(input) ?? "tool" });
  }
  return targets;
}

function summarizeToolRuntimeOutput(event: Extract<AcpRuntimeEvent, { type: "tool_call" }>): string | null {
  if (event.rawOutput !== undefined) {
    return truncate(stringifyShort(event.rawOutput) ?? "", TOOL_OUTPUT_MAX_CHARS) || null;
  }
  if (event.content && event.content.length > 0) {
    return truncate(stringifyShort(event.content) ?? "", TOOL_OUTPUT_MAX_CHARS) || null;
  }
  return event.text || null;
}

function activityStatusFromAcp(status: string | undefined): AgentSessionActivityDraft["status"] {
  const normalized = status?.toLowerCase() ?? "";
  if (/fail|error/.test(normalized)) return "failed";
  if (/declin|den/.test(normalized)) return "declined";
  if (/complete|success|done/.test(normalized)) return "completed";
  return "in_progress";
}

function recordPreview(record: AcpSessionRecord): string {
  return (
    record.title?.trim() ||
    record.name?.trim() ||
    firstUserText(record) ||
    lastAssistantText(record) ||
    `${record.agentCommand} session`
  );
}

function firstUserText(record: AcpSessionRecord): string | null {
  for (const message of record.messages) {
    if (typeof message !== "string" && "User" in message) {
      const text = userContentText(message.User.content).trim();
      if (text) return truncate(text, 160);
    }
  }
  return null;
}

function lastAssistantText(record: AcpSessionRecord): string | null {
  for (const message of [...record.messages].reverse()) {
    if (typeof message !== "string" && "Agent" in message) {
      const parts = message.Agent.content
        .map((content) => "Text" in content ? content.Text : "")
        .filter(Boolean);
      const text = parts.join("\n").trim();
      if (text) return truncate(text, 160);
    }
  }
  return null;
}

function userContentText(content: AcpxUserContent): string {
  return content
    .map((entry) => {
      if ("Text" in entry) return entry.Text;
      if ("Mention" in entry) return `${entry.Mention.uri}\n${entry.Mention.content}`;
      if ("Image" in entry) return `[image: ${entry.Image.source}]`;
      return "";
    })
    .filter(Boolean)
    .join("\n\n");
}

function userContentBlocks(content: AcpxUserContent): SessionMessageContentBlock[] {
  const text = userContentText(content);
  return text ? [{ type: "text", text }] : [];
}

function userContentAttachments(content: AcpxUserContent): SessionMessageAttachment[] {
  return content
    .map((entry): SessionMessageAttachment | null => {
      if (!("Image" in entry)) return null;
      const source = entry.Image.source;
      return source.startsWith("http://") || source.startsWith("https://")
        ? { type: "image", url: source }
        : { type: "localImage", path: source };
    })
    .filter((entry): entry is SessionMessageAttachment => entry != null);
}

function toolResultText(content: unknown): string | null {
  if (!content) {
    return null;
  }
  if (typeof content === "object" && !Array.isArray(content)) {
    const record = content as Record<string, unknown>;
    if (typeof record.Text === "string") {
      return record.Text;
    }
    if (record.Image && typeof record.Image === "object") {
      return `[image: ${stringProperty(record.Image, ["source"]) ?? "image"}]`;
    }
  }
  return stringifyShort(content) ?? null;
}

function recordUpdatedIso(record: AcpSessionRecord): string {
  return record.updated_at || record.lastUsedAt || record.createdAt;
}

function recordUpdatedMillis(record: AcpSessionRecord): number {
  return millisFromIso(recordUpdatedIso(record));
}

function secondsFromIso(value: string): number {
  return Math.floor(millisFromIso(value) / 1000);
}

function millisFromIso(value: string): number {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Date.now();
}

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (limit == null || limit < 0 || items.length <= limit) {
    return items;
  }
  return items.slice(items.length - limit);
}

function defaultAcpxStateDir(agent: string): string {
  return nodePath.join(homedir(), ".sidemesh", "acpx-provider", sanitizePathSegment(agent));
}

function normalizeAgent(value: string): string {
  return value.trim().toLowerCase() || DEFAULT_ACPX_AGENT;
}

function sanitizePathSegment(value: string): string {
  return value.replace(/[^A-Za-z0-9._-]+/g, "-") || "agent";
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function hashId(value: string): string {
  return createHash("sha256").update(value).digest("base64url").slice(0, 18);
}

function stringifyShort(value: unknown): string | undefined {
  if (value == null) {
    return undefined;
  }
  if (typeof value === "string") {
    return truncate(value, TOOL_OUTPUT_MAX_CHARS);
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  try {
    return truncate(JSON.stringify(value), TOOL_OUTPUT_MAX_CHARS);
  } catch {
    return String(value);
  }
}

function truncate(value: string, maxChars: number): string {
  return value.length > maxChars ? `${value.slice(0, maxChars - 1)}…` : value;
}

function stringProperty(value: unknown, keys: string[]): string | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  for (const key of keys) {
    const entry = value[key];
    if (typeof entry === "string" && entry.trim()) {
      return entry.trim();
    }
  }
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeJsonParse(value: string): unknown {
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return undefined;
  }
}

export function acpxProviderDefaultAgent(): string {
  return DEFAULT_ACPX_AGENT;
}
