import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { homedir } from "node:os";
import { resolve, join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import type { RpcSessionState } from "@earendil-works/pi-coding-agent";
import { z } from "zod";
import { AgentProviderRequestError, materializeAgentActivityDraft, type AgentProvider, type AgentProviderEvents,
  type AgentProviderCapabilities, type AgentCreateSessionRequest, type AgentCreateSessionResult,
  type AgentSubmitInputRequest, type AgentSubmitInputResult, type AgentSessionListOptions,
  type AgentSessionLogOptions, type AgentSessionSnapshot, type AgentSessionResumeOptions, type AgentModelListOptions,
  type AgentSkillListOptions, type AgentPendingAction, type AgentSessionActivityDraft } from "./agent-provider.js";
import { parsePendingActionDecision, parsePendingActionUserInputResponse, type PendingActionResponseInput } from "./approvals.js";
import { PiRpc, type PiRpcEvent } from "./pi-rpc.js";
import { importPiHistory, listPiHistory, readPiHistory, piSdk } from "./pi-history.js";
import { parsePiSessionHistory, piBranch, preparePiInput, runtimeFromAssistantMessage,
  persistedPiToolResultActivity, toolExecutionStartDraft, fileChangeFromPiTool, extractPiMessageText,
  extractPiMessageContentBlocks, customPiMessageText, detectPiAssistantPhase,
  activityIdForToolCall, extractPiPartialToolText, formatPiModelRef, resolvePiModel,
  describePiModelLookupFailure, isPiThinkingLevel, piSkillToSummary, type PiSessionSummary } from "./pi-mapping.js";
import { SessionStore, type StoredProviderSession, type StoredSessionItem } from "./session-store.js";
import { reconcileSessionHistory, confirmedSessionInputIds } from "./session-history.js";
import { extractSessionAttachments } from "./session-attachments.js";
import type { ThreadRecord, SessionLogSnapshot, SessionRuntimeSummary, SessionMessage, SessionActivity,
  ModelSummary, SkillCatalogEntry } from "./types.js";

export interface PiAgentProviderOptions {
  agentDir?: string | null;
  stateDir?: string | null;
  providerId?: string;
  sessionStore?: SessionStore;
  rpcEntry?: string;
}
interface PiMetadata {
  nativePath?: string | null;
  runtime?: SessionRuntimeSummary | null;
  leafId?: string | null;
}
interface ConnectedPiSession {
  rpc: PiRpc;
  ready: Promise<void>;
  native?: RpcSessionState;
  active?: { id: string; status: string; started: boolean };
  draft?: { id: string; indexes: number[] };
  pendingInputIds: string[];
  compactionId?: string;
  finishing?: Promise<void>;
  disconnecting?: Promise<void>;
  reading?: Promise<Set<string> | null>;
  idleTimer?: NodeJS.Timeout;
  stopping: boolean;
  pending: Map<string, { action: AgentPendingAction; requestId: string; method: string; timer?: NodeJS.Timeout }>;
}
const stateSchema = z.object({ sessionId: z.string().min(1), sessionFile: z.string().optional(), sessionName: z.string().optional(),
  isStreaming: z.boolean(), isCompacting: z.boolean(), thinkingLevel: z.string(), pendingMessageCount: z.number(),
  messageCount: z.number(), autoCompactionEnabled: z.boolean() }).passthrough();

export const PI_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
  sessions: {
    create: true,
    resume: true,
    rename: true,
    archive: true,
    compact: true,
    interrupt: true,
    history: true,
    recentFallback: true,
    searchSessions: false,
  },
  input: {
    text: true,
    imageUrl: true,
    localImage: true,
    skills: true,
    fileMentions: true,
  },
  interaction: {
    userInput: true,
    elicitation: false,
  },
  approvals: {
    command: false,
    tool: false,
    fileChange: false,
    permissions: false,
    approveForSession: false,
  },
  configuration: {
    models: true,
    profiles: false,
    accessModes: false,
    skills: true,
    skillManagement: false,
  },
  runtimeControls: {
    model: true,
    mode: false,
    reasoningEffort: true,
    fastMode: false,
    approvalPolicy: false,
    sandboxMode: false,
    networkAccess: false,
    webSearch: false,
    accessMode: false,
  },
  lifecycle: {
    restart: false,
  },
  usage: {
    accountLimits: false,
    localTelemetry: false,
    credits: false,
    resetWindows: false,
  },
};

export class PiAgentProvider extends EventEmitter<AgentProviderEvents> implements AgentProvider {
  readonly kind = "pi";
  readonly displayName = "Pi";
  readonly capabilities = PI_PROVIDER_CAPABILITIES;
  private readonly agentDir: string;
  private readonly stateDir: string;
  private readonly providerId: string;
  private readonly connections = new Map<string, ConnectedPiSession>();
  private store?: SessionStore;
  private starting?: Promise<void>;
  private closed = false;

  constructor(private readonly options: PiAgentProviderOptions = {}) {
    super();
    this.agentDir = resolve(options.agentDir || join(homedir(), ".pi", "agent"));
    this.stateDir = resolve(options.stateDir || join(homedir(), ".sidemesh", "pi-provider"));
    this.providerId = options.providerId ?? "pi";
    this.store = options.sessionStore;
  }

  async start(): Promise<void> {
    if (this.closed) throw new Error("Pi provider is closed");
    this.starting ??= (async () => {
      this.store ??= await SessionStore.open(this.stateDir);
      await importPiHistory(this.db, this.providerId, this.stateDir);
    })();
    await this.starting;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.starting?.catch(() => {});
    await Promise.all([...this.connections].map(([id, state]) => this.disconnect(id, state)));
    if (!this.options.sessionStore) this.store?.close();
    this.store = undefined;
  }

  async health(): Promise<boolean> { return !this.closed; }
  async getVersion(): Promise<string> { return "Pi 0.85.1 (RPC)"; }

  async listSessionThreads(options: AgentSessionListOptions): Promise<ThreadRecord[]> {
    await this.start();
    const known = new Map(this.db.listProviderSessions(this.providerId).map((record) => [record.nativeId, record]));
    for (const summary of await listPiHistory(this.agentDir)) {
      const previous = known.get(summary.id);
      this.db.saveProviderSession(this.providerId, { id: previous?.id ?? summary.id, nativeId: summary.id,
        cwd: summary.cwd, name: summary.name, preview: summary.preview, createdAt: summary.createdAt,
        updatedAt: Math.max(summary.updatedAt, previous?.updatedAt ?? 0), archived: previous?.archived ?? false,
        metadata: { ...this.metadata(previous), nativePath: summary.path } });
    }
    return this.db.listProviderSessions(this.providerId).filter((record) => record.archived === options.archived)
      .slice(0, options.limit).map((record) => this.thread(record, false));
  }

  async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> {
    return this.listSessionThreads({ limit, archived: false });
  }

  async readSessionThread(id: string, includeTurns: boolean): Promise<ThreadRecord> {
    await this.findRecord(id);
    const state = this.connections.get(id);
    if (state?.native && !state.stopping) {
      await this.readState(id, state);
    }
    return this.thread(this.record(id), includeTurns);
  }

  async readSessionLog(thread: ThreadRecord, options: AgentSessionLogOptions = {}): Promise<SessionLogSnapshot> {
    return this.readSessionSnapshot(thread.id, options);
  }

  async readSessionSnapshot(id: string, options: AgentSessionLogOptions = {}): Promise<AgentSessionSnapshot> {
    await this.findRecord(id);
    const state = this.connections.get(id);
    const branch = await this.refreshHistory(id, state);
    const native = state?.native && !state.stopping ? await this.readState(id, state) : null;
    const busy = Boolean(native && (native.isStreaming || native.isCompacting || native.pendingMessageCount));
    const items = this.db.readSessionItems(this.providerId, id).filter((item) => !branch || !item.anchorId || branch.has(item.anchorId));
    const messages = items.flatMap((item) => item.kind === "message" ? [item.value] : []);
    const activities = items.flatMap((item) => item.kind === "activity" ? [item.value] : []);
    const record = this.record(id);
    const thread = this.thread(record, true);
    thread.status = { type: record.archived ? "closed" : busy ? "running" : "idle" };
    if (!busy) thread.turns = [];
    return { thread, busy, activeTurnId: busy ? state?.active?.id ?? null : null, confirmedInputIds: confirmedSessionInputIds(items),
      messages: tail(messages, options.messageLimit), activities: tail(activities, options.activityLimit),
      totalMessages: messages.length, totalActivities: activities.length,
      nextSeq: this.db.nextSessionSequence(this.providerId, id), runtime: this.metadata(record).runtime ?? null };
  }

  async readSessionRuntime(thread: ThreadRecord): Promise<SessionRuntimeSummary | null> {
    await this.findRecord(thread.id);
    const state = this.connections.get(thread.id);
    if (state?.native && !state.stopping) await this.readState(thread.id, state);
    return this.metadata(this.record(thread.id)).runtime ?? null;
  }

  async listLoadedSessionIds(): Promise<string[]> { return [...this.connections.keys()]; }

  async createSession(request: AgentCreateSessionRequest): Promise<AgentCreateSessionResult> {
    await this.start();
    const id = `pi-${randomUUID()}`;
    this.db.saveProviderSession(this.providerId, { id, nativeId: null, cwd: resolve(request.cwd), name: null, preview: "Pi session",
      createdAt: Date.now(), updatedAt: Date.now(), archived: false, metadata: {} });
    const state = await this.connect(id);
    await this.applyOverrides(id, state, request.overrides);
    const submitted = request.input.length ? await this.submitInput({ ...request, sessionId: id, activeTurnId: null }) : null;
    return { thread: this.thread(this.record(id), false), activeTurnId: submitted?.turnId ?? null,
      runtime: this.metadata(this.record(id)).runtime ?? null };
  }

  async resumeSessionThread(id: string, options?: AgentSessionResumeOptions): Promise<unknown> {
    const state = await this.connect(id);
    if (options?.model) await this.applyOverrides(id, state, { model: options.model });
    return { resumed: true };
  }

  async submitInput(request: AgentSubmitInputRequest): Promise<AgentSubmitInputResult> {
    let state: ConnectedPiSession;
    let prepared: Awaited<ReturnType<typeof preparePiInput>>;
    try {
      state = await this.connect(request.sessionId);
      prepared = await preparePiInput(request.input);
      if (!prepared.text && !prepared.images.length) throw new Error("Input is required");
      await this.applyOverrides(request.sessionId, state, request.overrides);
      if (this.closed || state.stopping) throw new Error("Pi session is stopping");
    } catch (error) { throw new AgentProviderRequestError(errorText(error), 409, true); }
    const active = state.active ?? { id: `pi-turn-${randomUUID()}`, status: "completed", started: false };
    const mode = state.active ? "steer" : "turn";
    const message: SessionMessage = { id: request.clientMessageId ?? `pi-user-${randomUUID()}`, role: "user", text: prepared.text,
      content: [{ type: "text", text: prepared.text }], attachments: prepared.attachments,
      createdAt: Date.now(), seq: this.db.nextSessionSequence(this.providerId, request.sessionId) };
    this.put(request.sessionId, { kind: "message", value: message, nativeId: null, clientInputId: request.clientMessageId, authority: "recovery",
      anchorId: this.metadata(this.record(request.sessionId)).leafId ?? undefined });
    state.pendingInputIds.push(message.id);
    state.active = active;
    clearTimeout(state.idleTimer);
    try {
      await state.rpc.request({ type: mode === "steer" ? "steer" : "prompt", message: prepared.text, images: prepared.images }, 120_000);
      const native = await this.readState(request.sessionId, state);
      // Extension commands and intercepted input can complete without an agent run.
      if (!native.isStreaming && !native.isCompacting && native.pendingMessageCount === 0 && !active.started) {
        await this.finishTurn(request.sessionId, state);
      }
      return { mode, turnId: active.id };
    } catch (error) {
      active.status = "failed";
      await this.disconnect(request.sessionId, state);
      throw error;
    }
  }

  async interruptTurn(id: string, turnId: string | null): Promise<unknown> {
    const state = await this.connect(id);
    if (turnId !== null && state.active?.id !== turnId) return { interrupted: false };
    if (!state.active) {
      const native = await this.readState(id, state);
      if (!native.isStreaming && !native.isCompacting && native.pendingMessageCount === 0) return { interrupted: false };
    }
    state.stopping = true;
    if (state.active) state.active.status = "interrupted";
    this.cancelActions(id, state);
    try {
      await state.rpc.request({ type: "clear_queue" });
      await state.rpc.request({ type: "abort" });
      await this.finishTurn(id, state);
    } catch (error) { await this.disconnect(id, state); throw error; }
    finally { state.stopping = false; }
    return { interrupted: true };
  }

  async setSessionName(id: string, name: string): Promise<unknown> {
    const state = await this.connect(id);
    await state.rpc.request({ type: "set_session_name", name: name.trim() });
    const record = this.record(id);
    this.db.saveProviderSession(this.providerId, { ...record, name: name.trim() || null, updatedAt: Date.now() });
    return { renamed: true };
  }

  async archiveSession(id: string): Promise<unknown> {
    await this.findRecord(id);
    const state = this.connections.get(id);
    if (state) await this.disconnect(id, state);
    this.db.saveProviderSession(this.providerId, { ...this.record(id), archived: true, updatedAt: Date.now() });
    return { archived: true };
  }
  async unarchiveSession(id: string): Promise<unknown> {
    await this.findRecord(id);
    this.db.saveProviderSession(this.providerId, { ...this.record(id), archived: false, updatedAt: Date.now() });
    return { unarchived: true };
  }
  async compactSession(id: string): Promise<unknown> {
    const state = await this.connect(id);
    const result = await state.rpc.request({ type: "compact" }, 120_000);
    await this.refreshHistory(id, state);
    return result;
  }

  async listModels(options: AgentModelListOptions): Promise<ModelSummary[]> {
    const services = await (await piSdk()).createAgentSessionServices({ cwd: options.cwd ?? process.cwd(), agentDir: this.agentDir });
    const models = await services.modelRuntime.getAvailable(options.provider ?? undefined);
    const defaultRef = `${services.settingsManager.getDefaultProvider()}/${services.settingsManager.getDefaultModel()}`;
    return models.map((model, index) => ({ id: `pi:${model.provider}/${model.id}`, model: `${model.provider}/${model.id}`,
      displayName: model.name, description: `Pi model via ${model.provider}.`, source: "pi", sortOrder: index,
      defaultReasoningEffort: model.reasoning ? services.settingsManager.getDefaultThinkingLevel() ?? "medium" : "off",
      supportedReasoningEfforts: model.reasoning ? ["minimal", "low", "medium", "high", "xhigh"].map((reasoningEffort) => ({ reasoningEffort, description: `Pi ${reasoningEffort} reasoning.` })) : [],
      reasoningEffortControl: model.reasoning ? "client" : "provider", supportsPersonality: false,
      additionalSpeedTiers: [], inputModalities: model.input.includes("image") ? ["text", "image"] : ["text"],
      isDefault: `${model.provider}/${model.id}` === defaultRef }));
  }
  async listSkills(options: AgentSkillListOptions): Promise<SkillCatalogEntry> {
    const services = await (await piSdk()).createAgentSessionServices({ cwd: options.cwd, agentDir: this.agentDir });
    const catalog = services.resourceLoader.getSkills();
    return { cwd: options.cwd, skills: catalog.skills.map((skill) => piSkillToSummary(skill, options.cwd, this.agentDir)),
      errors: catalog.diagnostics.map((item) => ({ path: item.path ?? "", message: item.message })) };
  }

  async setSessionConfiguration(id: string, optionId: string, value: string | boolean): Promise<SessionRuntimeSummary | null> {
    const state = await this.connect(id);
    if (optionId === "pi:auto-compaction" && typeof value === "boolean") await state.rpc.request({ type: "set_auto_compaction", enabled: value });
    else if (optionId === "pi:thinking" && typeof value === "string") await this.applyOverrides(id, state, { reasoningEffort: value });
    else if (optionId === "pi:model" && typeof value === "string") await this.applyOverrides(id, state, { model: value });
    else throw new AgentProviderRequestError("Unknown Pi configuration option", 400, true);
    await this.readState(id, state);
    return this.metadata(this.record(id)).runtime ?? null;
  }

  respondToPendingAction(action: AgentPendingAction, input: PendingActionResponseInput): boolean {
    const state = this.connections.get(action.sessionId);
    const pending = state?.pending.get(action.id);
    if (!state || !pending) return false;
    const response = parsePendingActionUserInputResponse(input);
    const decision = parsePendingActionDecision(input)?.decision;
    const cancelled = decision === "cancel" || decision === "decline";
    if (!cancelled && (!response || (pending.action.userInput?.choices.length && !pending.action.userInput.allowFreeform && !pending.action.userInput.choices.includes(response.answer)))) return false;
    state.rpc.respond(cancelled ? { type: "extension_ui_response", id: pending.requestId, cancelled: true } : pending.method === "confirm"
      ? { type: "extension_ui_response", id: pending.requestId, confirmed: response!.answer === "Yes" }
      : { type: "extension_ui_response", id: pending.requestId, value: response!.answer });
    clearTimeout(pending.timer);
    state.pending.delete(action.id);
    this.emit("liveEvent", { type: "action_resolved", sessionId: action.sessionId, actionId: action.id });
    return true;
  }

  private async connect(id: string): Promise<ConnectedPiSession> {
    await this.findRecord(id);
    const existing = this.connections.get(id);
    if (existing) {
      if (existing.stopping) throw new Error("Pi session is stopping");
      await existing.ready;
      return existing;
    }
    if (this.closed || this.record(id).archived) throw new Error("Pi session is closed or archived");
    const record = this.record(id);
    const rpc = new PiRpc({ cwd: record.cwd, agentDir: this.agentDir, sessionFile: this.metadata(record).nativePath,
      entry: this.options.rpcEntry });
    const state: ConnectedPiSession = { rpc, ready: Promise.resolve(), pendingInputIds: [], pending: new Map(), stopping: false };
    this.connections.set(id, state);
    rpc.on("stderr", (line) => this.emit("stderr", line));
    rpc.on("event", (event) => {
      try { this.onEvent(id, state, event); }
      catch (error) { this.warning(id, "pi_event_failed", errorText(error)); void this.disconnect(id, state); }
    });
    rpc.on("exit", (error) => {
      if (!state.stopping && !this.closed) this.warning(id, "pi_disconnected", error.message);
      if (state.active) state.active.status = state.stopping || this.closed ? "interrupted" : "failed";
      void this.disconnect(id, state);
    });
    state.ready = (async () => {
      await this.readState(id, state);
      const [models, commands, thinking] = await Promise.all([
        rpc.request({ type: "get_available_models" }), rpc.request({ type: "get_commands" }),
        rpc.request({ type: "get_available_thinking_levels" }),
      ]);
      this.runtime(id, { commands: commands.commands.map((command) => ({ name: command.name, description: command.description ?? "" })),
        configurationOptions: [
          { id: "pi:model", label: "Model", category: "model", value: this.metadata(this.record(id)).runtime?.model ?? "",
            options: models.models.map((model) => ({ value: formatPiModelRef(model.provider, model.id), label: model.name })) },
          { id: "pi:thinking", label: "Reasoning", category: "thought_level", value: state.native?.thinkingLevel ?? "off",
            options: thinking.levels.map((level) => ({ value: level, label: level })) },
          { id: "pi:auto-compaction", label: "Automatic compaction", value: state.native?.autoCompactionEnabled ?? true },
        ] });
      await this.refreshHistory(id, state);
      this.scheduleIdleClose(id, state);
    })();
    try { await state.ready; return state; }
    catch (error) { await this.disconnect(id, state); throw error; }
  }

  private async readState(id: string, state: ConnectedPiSession): Promise<RpcSessionState> {
    const native = stateSchema.parse(await state.rpc.request({ type: "get_state" })) as unknown as RpcSessionState;
    const record = this.record(id);
    if (record.nativeId && native.sessionId !== record.nativeId) throw new Error("Pi changed the native session identity; the saved history was kept");
    state.native = native;
    this.db.saveProviderSession(this.providerId, { ...record, nativeId: native.sessionId,
      name: native.sessionName ?? record.name, metadata: { ...this.metadata(record), nativePath: native.sessionFile ?? this.metadata(record).nativePath } });
    const current = this.metadata(this.record(id)).runtime;
    const model = native.model ? formatPiModelRef(native.model.provider, native.model.id) : current?.model;
    this.runtime(id, { model, modelProvider: native.model?.provider, reasoningEffort: native.thinkingLevel,
      turnId: state.active?.id,
      configurationOptions: current?.configurationOptions?.map((option) => ({ ...option,
        value: option.id === "pi:model" ? model ?? "" : option.id === "pi:thinking" ? native.thinkingLevel
          : option.id === "pi:auto-compaction" ? native.autoCompactionEnabled : option.value })),
      ...(native.model?.contextWindow ? { telemetry: { ...current?.telemetry,
        contextWindow: { currentTokens: current?.telemetry?.contextWindow?.currentTokens ?? null,
          tokenLimit: native.model.contextWindow, messagesLength: native.messageCount, updatedAt: Date.now() } } } : {}) });
    return native;
  }

  private async applyOverrides(id: string, state: ConnectedPiSession, overrides: Partial<AgentSubmitInputRequest["overrides"]>): Promise<void> {
    if (overrides.model?.trim()) {
      const { models } = await state.rpc.request({ type: "get_available_models" });
      const model = resolvePiModel(models, overrides.model);
      if (!model) throw new Error(describePiModelLookupFailure(models, overrides.model));
      await state.rpc.request({ type: "set_model", provider: model.provider, modelId: model.id });
    }
    if (overrides.reasoningEffort && overrides.reasoningEffort !== "auto") {
      const { levels } = await state.rpc.request({ type: "get_available_thinking_levels" });
      if (!isPiThinkingLevel(overrides.reasoningEffort) || !levels.includes(overrides.reasoningEffort)) throw new Error("Pi does not support this reasoning level");
      await state.rpc.request({ type: "set_thinking_level", level: overrides.reasoningEffort });
    }
    if (overrides.model || overrides.reasoningEffort) await this.readState(id, state);
  }

  private async refreshHistory(id: string, state?: ConnectedPiSession): Promise<Set<string> | null> {
    if (state?.reading) return state.reading;
    const read = async (): Promise<Set<string> | null> => {
      const record = this.record(id);
      const metadata = this.metadata(record);
      const native = state?.native && !state.stopping ? await state.rpc.request({ type: "get_entries" }) : null;
      // RPC entries can exist before Pi writes its first assistant message. Only
      // the native file can confirm those recovery records are durable.
      const disk = await readPiHistory(metadata.nativePath ?? null, record.nativeId);
      const source = native ?? disk;
      if (!source) return null;
      const summary: PiSessionSummary = { id: record.nativeId ?? id, path: metadata.nativePath ?? "", cwd: record.cwd,
        name: disk?.name ?? record.name, preview: record.preview, createdAt: record.createdAt, updatedAt: record.updatedAt };
      const parsed = parsePiSessionHistory(source.entries, source.leafId, summary);
      const durable = new Map(disk?.entries.map((entry) => [entry.id, entry]) ?? []);
      const entries = new Map(source.entries.map((entry) => [entry.id, entry]));
      const branch = new Set(piBranch(source.entries, source.leafId).map((entry) => entry.id));
      const history: StoredSessionItem[] = [
        ...parsed.messages.map((value): StoredSessionItem => ({ kind: "message", value, nativeId: value.id,
          authority: entries.has(value.id) && isDeepStrictEqual(entries.get(value.id), durable.get(value.id)) ? "cache" : "recovery", anchorId: value.id })),
        ...parsed.activities.map((value): StoredSessionItem => {
          const sourceId = parsed.sourceEntryIds.get(value.id) ?? value.id;
          return { kind: "activity", value: materializeAgentActivityDraft(value, { createdAt: value.createdAt, seq: value.seq }),
            nativeId: value.id, authority: entries.has(sourceId) && isDeepStrictEqual(entries.get(sourceId), durable.get(sourceId)) ? "cache" : "recovery", anchorId: sourceId };
        }),
      ].sort((a, b) => a.value.seq - b.value.seq);
      // Capture recovery after all upstream reads, so updates received during
      // the snapshot cannot be deleted by an older native response.
      const latest = this.record(id);
      const merged = reconcileSessionHistory(this.db.readSessionItems(this.providerId, id), history, true);
      this.db.replaceProviderHistory(this.providerId, { ...latest, name: parsed.threadName ?? latest.name,
        preview: parsed.preview || latest.preview, metadata: { ...this.metadata(latest), leafId: source.leafId } }, merged);
      if (parsed.runtime) this.runtime(id, { ...parsed.runtime, ...this.metadata(this.record(id)).runtime,
        telemetry: { ...this.metadata(this.record(id)).runtime?.telemetry, ...parsed.runtime.telemetry } });
      return branch;
    };
    const pending = read();
    if (state) state.reading = pending;
    try { return await pending; }
    finally { if (state?.reading === pending) state.reading = undefined; }
  }

  private async finishTurn(id: string, state: ConnectedPiSession): Promise<void> {
    if (state.finishing) return state.finishing;
    const active = state.active;
    if (!active) return;
    state.finishing = (async () => {
      this.finishMessage(id, state);
      try { await this.refreshHistory(id, state); }
      catch (error) { this.warning(id, "pi_history_unconfirmed", errorText(error)); }
      if (state.active !== active) return;
      state.active = undefined;
      if (state.native) state.native = { ...state.native, isStreaming: false, isCompacting: false };
      this.cancelActions(id, state);
      this.runtime(id, { turnId: undefined });
      this.emit("liveEvent", { type: "turn_completed", sessionId: id, turnId: active.id, status: active.status });
      this.scheduleIdleClose(id, state);
    })();
    try { await state.finishing; } finally { state.finishing = undefined; }
  }

  private async disconnect(id: string, state: ConnectedPiSession): Promise<void> {
    if (state.disconnecting) return state.disconnecting;
    if (state.idleTimer) clearTimeout(state.idleTimer);
    state.stopping = true;
    if (state.active && state.active.status === "completed") state.active.status = "interrupted";
    this.cancelActions(id, state);
    state.disconnecting = Promise.resolve().then(async () => {
      await state.rpc.close();
      await state.ready.catch(() => {});
      await this.finishTurn(id, state);
      if (this.connections.get(id) === state) this.connections.delete(id);
    });
    return state.disconnecting;
  }

  private scheduleIdleClose(id: string, state: ConnectedPiSession): void {
    clearTimeout(state.idleTimer);
    if (this.closed || state.stopping || state.active) return;
    state.idleTimer = setTimeout(() => { void this.disconnect(id, state); }, 10 * 60_000);
    state.idleTimer.unref();
  }

  private put(id: string, item: StoredSessionItem): void {
    this.db.putSessionItem(this.providerId, id, item);
    const record = this.record(id);
    this.db.saveProviderSession(this.providerId, { ...record, updatedAt: Date.now(),
      preview: item.kind === "message" && item.value.text ? item.value.text.slice(0, 160) : record.preview });
  }
  private runtime(id: string, patch: Partial<SessionRuntimeSummary>): void {
    const record = this.record(id);
    const metadata = this.metadata(record);
    const runtime = { ...metadata.runtime, ...patch, updatedAt: Date.now() };
    this.db.saveProviderSession(this.providerId, { ...record, metadata: { ...metadata, runtime } });
    this.emit("liveEvent", { type: "runtime_updated", sessionId: id, runtime });
  }
  private warning(id: string, code: string, message: string): void {
    this.emit("liveEvent", { type: "provider_warning", sessionId: id, level: "warning", code, message, source: "pi/rpc" });
  }
  private async findRecord(id: string): Promise<StoredProviderSession> {
    await this.start();
    if (!this.db.getProviderSession(this.providerId, id)) await this.listSessionThreads({ limit: 1, archived: false });
    return this.record(id);
  }
  private get db(): SessionStore { if (!this.store) throw new Error("Pi provider has not started"); return this.store; }
  private record(id: string): StoredProviderSession {
    const record = this.db.getProviderSession(this.providerId, id);
    if (!record) throw new AgentProviderRequestError("Pi session not found", 404, true);
    return record;
  }
  private metadata(record?: StoredProviderSession | null): PiMetadata { return (record?.metadata ?? {}) as PiMetadata; }
  private thread(record: StoredProviderSession, includeTurns: boolean): ThreadRecord {
    const state = this.connections.get(record.id);
    const active = state?.active;
    const status = record.archived ? "closed" : active || state?.native?.isStreaming || state?.native?.isCompacting ? "running" : "idle";
    return { id: record.id, cwd: record.cwd, name: record.name, preview: record.preview, source: "pi",
      runtime: this.metadata(record).runtime ?? null,
      path: this.metadata(record).nativePath ?? null, createdAt: record.createdAt / 1000, updatedAt: record.updatedAt / 1000,
      status: { type: status, ...(status === "running" ? { activeFlags: ["inProgress"] } : {}) },
      ...(includeTurns ? { turns: active ? [{ id: active.id, status: "inProgress", startedAt: null, completedAt: null }] : [] } : {}) };
  }

  private onEvent(id: string, state: ConnectedPiSession, event: PiRpcEvent): void {
    switch (event.type) {
      case "agent_start":
        state.active ??= { id: `pi-turn-${randomUUID()}`, status: "completed", started: false };
        if (!state.active.started) this.emit("liveEvent", { type: "turn_started", sessionId: id, turnId: state.active.id });
        state.active.started = true;
        if (state.native) state.native = { ...state.native, isStreaming: true };
        clearTimeout(state.idleTimer);
        return;
      case "agent_settled": void this.finishTurn(id, state); return;
      case "agent_end": return; // Retry and follow-up handling belong to Pi until agent_settled.
      case "session_info_changed": {
        const record = this.record(id);
        this.db.saveProviderSession(this.providerId, { ...record, name: event.name ?? null, updatedAt: Date.now() });
        return;
      }
      case "thinking_level_changed": this.runtime(id, { reasoningEffort: event.level }); return;
      case "queue_update":
        this.emit("liveEvent", { type: "queue_updated", sessionId: id,
          steeringCount: event.steering.length, followUpCount: event.followUp.length,
          steeringPreview: [...event.steering], followUpPreview: [...event.followUp] });
        return;
      case "auto_retry_start":
        this.emit("liveEvent", { type: "auto_retry_updated", sessionId: id, phase: "started",
          attempt: event.attempt, maxAttempts: event.maxAttempts, delayMs: event.delayMs, errorMessage: event.errorMessage });
        return;
      case "auto_retry_end":
        this.emit("liveEvent", { type: "auto_retry_updated", sessionId: id, phase: "ended",
          attempt: event.attempt, success: event.success, finalError: event.finalError });
        if (!event.success) this.warning(id, "pi_auto_retry_failed", event.finalError ?? "Pi could not complete the request");
        return;
      case "compaction_start":
        state.compactionId = `pi-compaction-${randomUUID()}`;
        this.activity(id, state, { id: state.compactionId, type: "context_compaction", status: "in_progress", turnId: state.active?.id ?? null });
        this.runtime(id, { telemetry: { ...this.metadata(this.record(id)).runtime?.telemetry,
          compaction: { status: "running", startedAt: Date.now(), updatedAt: Date.now() } } });
        return;
      case "compaction_end":
        this.activity(id, state, { id: state.compactionId ?? `pi-compaction-${randomUUID()}`, type: "context_compaction",
          status: event.aborted || event.errorMessage ? "failed" : "completed", turnId: state.active?.id ?? null,
          ...(event.result?.summary ? { summary: event.result.summary } : {}) });
        this.runtime(id, { telemetry: { ...this.metadata(this.record(id)).runtime?.telemetry,
          contextWindow: state.native?.model?.contextWindow ? { currentTokens: null, tokenLimit: state.native.model.contextWindow,
            messagesLength: state.native.messageCount, updatedAt: Date.now() } : undefined,
          compaction: { status: event.aborted || event.errorMessage ? "failed" : "completed",
            preCompactionTokens: event.result?.tokensBefore, completedAt: Date.now(), updatedAt: Date.now(), error: event.errorMessage } } });
        if (event.errorMessage) this.warning(id, "pi_compaction_failed", event.errorMessage);
        return;
      case "message_start":
        if (event.message.role === "assistant") {
          this.finishMessage(id, state);
          state.draft = { id: `pi-message-${randomUUID()}`, indexes: [] };
        }
        return;
      case "message_update": {
        const delta = event.assistantMessageEvent;
        if (delta.type !== "text_delta" && delta.type !== "thinking_delta") return;
        state.draft ??= { id: `pi-message-${randomUUID()}`, indexes: [] };
        const previous = this.db.getSessionItem(this.providerId, id, "message", state.draft.id);
        const value: SessionMessage = previous?.kind === "message" ? previous.value : {
          id: state.draft.id, role: "assistant", text: "", content: [], attachments: [], createdAt: Date.now(),
          seq: this.db.nextSessionSequence(this.providerId, id), phase: "commentary" };
        const content = [...value.content];
        let index = state.draft.indexes.indexOf(delta.contentIndex);
        if (index < 0) { index = state.draft.indexes.length; state.draft.indexes.push(delta.contentIndex); }
        const previousBlock = content[index];
        content[index] = delta.type === "text_delta"
          ? { type: "text", text: (previousBlock?.type === "text" ? previousBlock.text : "") + delta.delta }
          : { type: "thinking", thinking: (previousBlock?.type === "thinking" ? previousBlock.thinking : "") + delta.delta };
        this.put(id, { kind: "message", value: { ...value, content,
          text: content.flatMap((block) => block.type === "text" ? [block.text] : []).join("\n") },
          nativeId: null, authority: "recovery", anchorId: this.metadata(this.record(id)).leafId ?? undefined });
        this.emit("liveEvent", delta.type === "text_delta"
          ? { type: "assistant_delta", sessionId: id, turnId: state.active?.id, itemId: value.id, delta: delta.delta }
          : { type: "reasoning_delta", sessionId: id, turnId: state.active?.id, itemId: value.id, delta: delta.delta, summary: false });
        return;
      }
      case "message_end": {
        const message = event.message as unknown as Record<string, unknown>;
        const createdAt = typeof message.timestamp === "number" ? message.timestamp : Date.now();
        if (message.role === "toolResult") { this.toolResult(id, state, message, createdAt); return; }
        if (message.role === "assistant") {
          const draft = state.draft ? this.db.getSessionItem(this.providerId, id, "message", state.draft.id) : null;
          const content = extractPiMessageContentBlocks(message);
          const text = extractPiMessageText(message) || (typeof message.errorMessage === "string" ? message.errorMessage : "");
          const value: SessionMessage = { id: state.draft?.id ?? `pi-message-${randomUUID()}`, role: "assistant",
            text: text || (draft?.kind === "message" ? draft.value.text : ""),
            content: content.length ? content : draft?.kind === "message" ? draft.value.content : text ? [{ type: "text", text }] : [],
            attachments: extractSessionAttachments(message.content), createdAt,
            seq: draft?.value.seq ?? this.db.nextSessionSequence(this.providerId, id), phase: detectPiAssistantPhase(message) ?? "final_answer" };
          if (value.text || value.content.length || value.attachments.length) {
            this.put(id, { kind: "message", value, nativeId: null, authority: "recovery", anchorId: this.metadata(this.record(id)).leafId ?? undefined });
            state.draft = { id: value.id, indexes: [] };
            this.finishMessage(id, state);
          } else state.draft = undefined;
          if (state.active) {
            if (message.stopReason === "aborted") state.active.status = "interrupted";
            else state.active.status = message.stopReason === "error" ? "failed" : "completed";
          }
          this.runtime(id, runtimeFromAssistantMessage(this.metadata(this.record(id)).runtime ?? null, message, state.active?.id ?? null));
          return;
        }
        const role = message.role === "user" ? "user" : "system";
        const text = (role === "user" ? extractPiMessageText(message) : customPiMessageText(message)) ?? "";
        const pendingId = role === "user" ? state.pendingInputIds.find((key) => {
          const item = this.db.getSessionItem(this.providerId, id, "message", key);
          return item?.kind === "message" && item.value.text === text
            && isDeepStrictEqual(item.value.attachments, extractSessionAttachments(message.content));
        }) : undefined;
        const previous = pendingId ? this.db.getSessionItem(this.providerId, id, "message", pendingId) : null;
        if (pendingId) state.pendingInputIds.splice(state.pendingInputIds.indexOf(pendingId), 1);
        this.put(id, { kind: "message", nativeId: null, authority: "recovery", anchorId: this.metadata(this.record(id)).leafId ?? undefined,
          clientInputId: previous?.clientInputId, nativeInputTimestamp: previous?.clientInputId ? createdAt : undefined,
          value: { id: pendingId ?? `pi-message-${randomUUID()}`, role, text, content: extractPiMessageContentBlocks(message),
            attachments: extractSessionAttachments(message.content), createdAt,
            seq: previous?.value.seq ?? this.db.nextSessionSequence(this.providerId, id) } });
        return;
      }
      case "tool_execution_start":
        this.finishMessage(id, state);
        this.activity(id, state, toolExecutionStartDraft(event, this.record(id).cwd, state.active?.id ?? null));
        return;
      case "tool_execution_update": {
        const previous = this.db.getSessionItem(this.providerId, id, "activity", activityIdForToolCall(event.toolName, event.toolCallId));
        if (previous?.kind !== "activity" || (previous.value.type !== "command" && previous.value.type !== "tool")) return;
        this.activity(id, state, { ...previous.value, output: extractPiPartialToolText(event.partialResult) ?? previous.value.output,
          ...(previous.value.type === "tool" ? { result: event.partialResult } : {}) });
        return;
      }
      case "tool_execution_end":
        this.toolResult(id, state, { ...event.result, toolName: event.toolName, toolCallId: event.toolCallId, isError: event.isError }, Date.now());
        return;
      case "extension_ui_request": this.extensionRequest(id, state, event); return;
      case "extension_error": this.warning(id, "pi_extension_error", event.error); return;
      default: return;
    }
  }

  private finishMessage(id: string, state: ConnectedPiSession): void {
    const item = state.draft ? this.db.getSessionItem(this.providerId, id, "message", state.draft.id) : null;
    state.draft = undefined;
    if (item?.kind !== "message") return;
    this.emit("liveEvent", { type: "assistant_message_completed", sessionId: id, turnId: state.active?.id, message: item.value });
  }

  private activity(id: string, state: ConnectedPiSession, draft: AgentSessionActivityDraft): SessionActivity {
    const previous = this.db.getSessionItem(this.providerId, id, "activity", draft.id);
    const value = materializeAgentActivityDraft(draft, { seq: previous?.value.seq ?? this.db.nextSessionSequence(this.providerId, id),
      createdAt: previous?.value.createdAt ?? Date.now() });
    this.put(id, { kind: "activity", value, nativeId: value.id, authority: "recovery",
      anchorId: previous?.anchorId ?? this.metadata(this.record(id)).leafId ?? undefined });
    this.emit("liveEvent", { type: "activity_updated", sessionId: id, turnId: state.active?.id, activity: value });
    return value;
  }

  private toolResult(id: string, state: ConnectedPiSession, message: Record<string, unknown>, createdAt: number): void {
    if (typeof message.toolName !== "string" || typeof message.toolCallId !== "string") throw new Error("Pi tool result has no identity");
    const previous = this.db.getSessionItem(this.providerId, id, "activity", activityIdForToolCall(message.toolName, message.toolCallId));
    const args = previous?.kind === "activity" ? previous.value.type === "tool" ? previous.value.args
      : previous.value.type === "command" ? { command: previous.value.command } : null : null;
    const value = this.activity(id, state, { ...persistedPiToolResultActivity(message.toolName, message.toolCallId, args, message,
      createdAt, previous?.value.seq ?? this.db.nextSessionSequence(this.providerId, id), this.record(id).cwd), turnId: state.active?.id ?? null });
    const change = fileChangeFromPiTool(message.toolName, args, message.details, value);
    if (change) this.activity(id, state, change);
  }

  private extensionRequest(id: string, state: ConnectedPiSession, request: Extract<PiRpcEvent, { type: "extension_ui_request" }>): void {
    if (request.method === "notify") { this.warning(id, "pi_extension_notice", request.message); return; }
    if (request.method === "setStatus") { if (request.statusText) this.warning(id, `pi_status:${request.statusKey}`, request.statusText); return; }
    if (request.method === "setWidget") { if (request.widgetLines?.length) this.warning(id, `pi_widget:${request.widgetKey}`, request.widgetLines.join("\n")); return; }
    if (request.method === "set_editor_text") { if (request.text) this.warning(id, "pi_suggested_input", request.text); return; }
    if (request.method === "setTitle") return;
    if (this.closed || state.stopping) { state.rpc.respond({ type: "extension_ui_response", id: request.id, cancelled: true }); return; }
    const actionId = `pi-action-${randomUUID()}`;
    const record = this.record(id);
    const action: AgentPendingAction = { id: actionId, sessionId: id, kind: "user_input", requestedAt: Date.now(),
      title: request.title, detail: request.method === "confirm" ? request.message : request.method === "editor" ? request.prefill ?? "" : request.title,
      canApprove: false, canApproveForSession: false, canDecline: true, sessionTitle: record.name ?? record.preview, cwd: record.cwd,
      providerRequestId: request.id, providerRequestKind: `pi/${request.method}`,
      userInput: { question: request.title, choices: request.method === "select" ? request.options : request.method === "confirm" ? ["Yes", "No"] : [],
        allowFreeform: request.method === "input" || request.method === "editor" } };
    const pending: ConnectedPiSession["pending"] extends Map<string, infer P> ? P : never = {
      action, requestId: request.id, method: request.method,
    };
    if ("timeout" in request && request.timeout && request.timeout > 0) pending.timer = setTimeout(() => {
      state.pending.delete(actionId);
      this.emit("liveEvent", { type: "action_resolved", sessionId: id, actionId });
    }, request.timeout);
    state.pending.set(actionId, pending);
    this.emit("liveEvent", { type: "action_opened", action });
  }

  private cancelActions(id: string, state: ConnectedPiSession): void {
    for (const [actionId, pending] of state.pending) {
      clearTimeout(pending.timer);
      try { state.rpc.respond({ type: "extension_ui_response", id: pending.requestId, cancelled: true }); } catch { /* Connection already closed. */ }
      this.emit("liveEvent", { type: "action_resolved", sessionId: id, actionId });
    }
    state.pending.clear();
  }
}

function errorText(error: unknown): string { return error instanceof Error ? error.message : String(error); }
function tail<T>(items: T[], limit?: number | null): T[] { return limit && limit > 0 ? items.slice(-limit) : items; }
