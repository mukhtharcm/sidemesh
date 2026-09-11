import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { homedir } from "node:os";
import { resolve, join } from "node:path";
import { Readable, Writable } from "node:stream";
import {
  methods, ndJsonStream, PROTOCOL_VERSION, RequestError,
  type ClientApp, type ClientConnection, type InitializeResponse, type SessionNotification,
  type SessionUpdate, type LoadSessionResponse, type SessionConfigOption,
  type SetSessionConfigOptionRequest,
} from "@agentclientprotocol/sdk";

import { AgentProviderRequestError, type AgentProvider, type AgentProviderEvents,
  type AgentProviderCapabilities, type AgentCreateSessionRequest, type AgentCreateSessionResult,
  type AgentSessionListOptions, type AgentSessionLogOptions, type AgentSessionSnapshot, type AgentSubmitInputRequest,
  type AgentSubmitInputResult, type AgentPendingAction, type AgentSessionResumeOptions,
  type AgentSessionInputItem, type AgentModelListOptions } from "./agent-provider.js";
import type { PendingActionResponseInput } from "./approvals.js";
import { AcpHost } from "./acp-host.js";
import { importAcpxHistory } from "./acp-history.js";
import { AcpTranscript } from "./acp-transcript.js";
import { reconcileSessionHistory } from "./session-history.js";
import { SessionStore, type StoredProviderSession, type StoredSessionItem } from "./session-store.js";
import { terminatePipeProcess } from "./terminal.js";
import type { AcpxPermissionMode, ThreadRecord, SessionLogSnapshot, SessionRuntimeSummary,
  SessionConfigurationOption, ModelSummary, LatestPlanUpdate } from "./types.js";

export const ACP_DEFAULT_AGENT = "gemini";
// These launch entries preserve the former ACPx choices. Native providers stay the preferred path.
const ACP_COMMANDS: Record<string, string> = {
  gemini: "gemini --acp", claude: "npx -y @agentclientprotocol/claude-agent-acp@^0.37.0",
  codex: "npx -y @agentclientprotocol/codex-acp@^0.0.44", pi: "npx pi-acp@^0.0.26",
  openclaw: "openclaw acp", cursor: "cursor-agent acp", copilot: "copilot --acp --stdio",
  droid: "droid exec --output-format acp", "fast-agent": "uvx fast-agent-mcp acp",
  "grok-build": "grok agent stdio", iflow: "iflow --experimental-acp", kilocode: "npx -y @kilocode/cli acp",
  kimi: "kimi acp", kiro: "kiro-cli-chat acp", mux: "npx -y mux@^0.27.0 acp",
  opencode: "npx -y opencode-ai acp", qoder: "qodercli --acp", qwen: "qwen --acp", trae: "traecli acp serve",
};

export function resolveAcpCommand(agent: string, command?: string | null): string {
  return command?.trim() || ACP_COMMANDS[agent.trim().toLowerCase()] || agent;
}

export interface AcpAgentProviderOptions {
  agent: string;
  command?: string | null;
  stateDir?: string | null;
  providerId?: string;
  permissionMode?: AcpxPermissionMode;
  cwd?: string | null;
  timeoutMs?: number;
}
interface AcpTransport {
  connection: ClientConnection;
  close(): Promise<void>;
}
interface AcpProviderDependencies {
  sessionStore?: SessionStore;
  connect?: (app: ClientApp, cwd: string) => Promise<AcpTransport>;
}
interface AcpSessionMetadata {
  runtime?: SessionRuntimeSummary | null;
  latestPlanUpdate?: LatestPlanUpdate | null;
  localName?: boolean;
}
interface ConnectedSession {
  host: AcpHost;
  transport: AcpTransport;
  initialized: InitializeResponse;
  transcript: AcpTranscript;
  active?: { turnId: string; clientInputId?: string; done: Promise<void>; interrupted: boolean };
  loading?: Promise<void>;
  disconnecting?: Promise<void>;
  replay?: { writer: AcpTranscript; items: Map<string, StoredSessionItem>; updates: SessionUpdate[] };
  earlyUpdates: SessionNotification[];
}

export const ACP_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
  sessions: { create: true, resume: true, rename: true, archive: true, compact: false,
    interrupt: true, history: true, recentFallback: true, searchSessions: true },
  input: { text: true, imageUrl: false, localImage: false, skills: false, fileMentions: true, steer: false },
  interaction: { userInput: true, elicitation: true },
  approvals: { command: true, tool: true, fileChange: true, permissions: true, approveForSession: true },
  configuration: { models: true, profiles: false, accessModes: false, skills: false, skillManagement: false },
  runtimeControls: { model: true, mode: true, reasoningEffort: false, fastMode: false,
    approvalPolicy: false, sandboxMode: false, networkAccess: false, webSearch: false, accessMode: false },
  lifecycle: { restart: false },
  usage: { accountLimits: false, localTelemetry: true, credits: false, resetWindows: false },
};

export class AcpAgentProvider extends EventEmitter<AgentProviderEvents> implements AgentProvider {
  // Keep the stored kind and existing public IDs compatible with old installations.
  readonly kind = "acpx";
  readonly displayName: string;
  readonly capabilities = structuredClone(ACP_PROVIDER_CAPABILITIES);
  private readonly providerId: string;
  private readonly command: string;
  private readonly stateDir: string;
  private readonly cwd: string;
  private readonly permissionMode: AcpxPermissionMode;
  private readonly timeoutMs: number;
  private store: SessionStore | null = null;
  private starting?: Promise<void>;
  private closed = false;
  private readonly sessions = new Map<string, ConnectedSession>();
  private readonly connecting = new Map<string, Promise<ConnectedSession>>();

  constructor(options: AcpAgentProviderOptions, private readonly dependencies: AcpProviderDependencies = {}) {
    super();
    const agent = options.agent.trim().toLowerCase() || ACP_DEFAULT_AGENT;
    this.providerId = options.providerId ?? "acpx";
    this.command = resolveAcpCommand(agent, options.command);
    this.cwd = resolve(options.cwd || process.cwd());
    this.stateDir = resolve(options.stateDir || join(homedir(), ".sidemesh", "acpx-provider", agent.replace(/[^A-Za-z0-9._-]/g, "-")));
    this.permissionMode = options.permissionMode ?? "approve-reads";
    this.timeoutMs = Math.max(1000, options.timeoutMs ?? 10 * 60 * 1000);
    this.displayName = `ACP (${agent})`;
  }

  async start(): Promise<void> {
    if (this.closed) throw new Error("ACP provider is closed");
    this.starting ??= (async () => {
      this.store = this.dependencies.sessionStore ?? await SessionStore.open(this.stateDir);
      try { await importAcpxHistory(this.store, this.providerId, this.stateDir); }
      catch (error) {
        if (!this.dependencies.sessionStore) this.store.close();
        this.store = null;
        throw error;
      }
    })();
    await this.starting;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    for (const state of this.sessions.values()) state.host.cancelPending();
    await Promise.all([...this.sessions.values()].map((state) => this.disconnect(state)));
    await Promise.allSettled(this.connecting.values());
    await this.starting?.catch(() => {});
    if (!this.dependencies.sessionStore) this.store?.close();
    this.store = null;
  }

  async health(): Promise<boolean> { return !this.closed; }
  async getVersion(): Promise<string> {
    const info = this.sessions.values().next().value?.initialized.agentInfo;
    return info ? `${info.name} ${info.version} (ACP ${PROTOCOL_VERSION})` : `ACP ${PROTOCOL_VERSION}`;
  }

  async listSessionThreads(options: AgentSessionListOptions): Promise<ThreadRecord[]> {
    await this.start();
    await this.discoverSessions();
    return this.db.listProviderSessions(this.providerId).filter((session) => session.archived === options.archived)
      .slice(0, options.limit).map((session) => this.thread(session, false));
  }
  async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> {
    return this.listSessionThreads({ limit, archived: false });
  }
  async readSessionThread(id: string, includeTurns: boolean): Promise<ThreadRecord> {
    await this.start();
    return this.thread(this.record(id), includeTurns);
  }
  async readSessionLog(thread: ThreadRecord, options: AgentSessionLogOptions = {}): Promise<SessionLogSnapshot> {
    return this.readSessionSnapshot(thread.id, options);
  }
  async readSessionSnapshot(id: string, options: AgentSessionLogOptions = {}): Promise<AgentSessionSnapshot> {
    await this.start();
    const state = this.sessions.get(id) ?? (this.record(id).nativeId && this.db.nextSessionSequence(this.providerId, id) === 0
      ? await this.ensureConnection(id) : undefined);
    if (state && !state.active) await this.refreshHistory(id, state);
    const record = this.record(id);
    const items = this.db.readSessionItems(this.providerId, id);
    const messages = items.flatMap((item) => item.kind === "message" ? [item.value] : []);
    const activities = items.flatMap((item) => item.kind === "activity" ? [item.value] : []);
    return { thread: this.thread(record, true), busy: Boolean(state?.active), activeTurnId: state?.active?.turnId ?? null, messages: tail(messages, options.messageLimit), activities: tail(activities, options.activityLimit),
      totalMessages: messages.length, totalActivities: activities.length, nextSeq: this.db.nextSessionSequence(this.providerId, id),
      runtime: this.metadata(record).runtime ?? null, latestPlanUpdate: this.metadata(record).latestPlanUpdate };
  }
  async readSessionRuntime(thread: ThreadRecord): Promise<SessionRuntimeSummary | null> {
    return this.metadata(this.record(thread.id)).runtime ?? null;
  }
  async listLoadedSessionIds(): Promise<string[]> { return [...this.sessions.keys()]; }
  async resumeSessionThread(id: string, options?: AgentSessionResumeOptions): Promise<unknown> {
    await this.start();
    const state = await this.ensureConnection(id);
    if (options?.model) await this.applyControls(id, state, { model: options.model });
    return { resumed: true };
  }
  async setSessionName(id: string, name: string): Promise<unknown> {
    const record = this.record(id);
    this.db.saveProviderSession(this.providerId, { ...record, name: name.trim(), updatedAt: Date.now(),
      metadata: { ...this.metadata(record), localName: true } });
    return { renamed: true };
  }
  async archiveSession(id: string): Promise<unknown> {
    this.record(id);
    const state = this.sessions.get(id);
    if (state?.active) await this.interruptTurn(id, state.active.turnId);
    if (state) await this.disconnect(state);
    this.db.saveProviderSession(this.providerId, { ...this.record(id), archived: true, updatedAt: Date.now() });
    return { archived: true };
  }
  async unarchiveSession(id: string): Promise<unknown> {
    this.db.saveProviderSession(this.providerId, { ...this.record(id), archived: false, updatedAt: Date.now() });
    return { unarchived: true };
  }

  async createSession(request: AgentCreateSessionRequest): Promise<AgentCreateSessionResult> {
    await this.start();
    const id = `acp-${randomUUID()}`;
    this.db.saveProviderSession(this.providerId, { id, nativeId: null, cwd: resolve(request.cwd || this.cwd),
      name: null, preview: inputText(request.input).slice(0, 160), createdAt: Date.now(), updatedAt: Date.now(), archived: false, metadata: {} });
    const state = await this.ensureConnection(id);
    await this.applyControls(id, state, request.overrides);
    const started = request.input.length ? await this.submitInput({ sessionId: id, input: request.input, activeTurnId: null, overrides: request.overrides }) : null;
    const record = this.record(id);
    return { thread: this.thread(record, false), activeTurnId: started?.turnId ?? null, runtime: this.metadata(record).runtime ?? null };
  }

  async submitInput(request: AgentSubmitInputRequest): Promise<AgentSubmitInputResult> {
    let state: ConnectedSession;
    let text: string;
    try {
      await this.start();
      state = await this.ensureConnection(request.sessionId);
      await state.loading;
      if (state.active) throw new Error("Session is busy; the host must queue this input");
      text = inputText(request.input);
      if (!text.trim()) throw new Error("Input text is required");
      await this.applyControls(request.sessionId, state, request.overrides);
      if (this.closed || state.active) throw new Error("Session is busy or closed");
    } catch (error) {
      throw new AgentProviderRequestError(errorMessage(error), 409, true);
    }
    const turnId = `acp-turn-${randomUUID()}`;
    const active = { turnId, clientInputId: request.clientMessageId, interrupted: false, done: Promise.resolve() };
    state.active = active;
    state.transcript.beginTurn(turnId, { id: request.clientMessageId || `acp-user-${randomUUID()}`,
      role: "user", text, content: [{ type: "text", text }], attachments: [], createdAt: Date.now() });
    active.done = this.finishPrompt(request.sessionId, state, active,
      this.requestWithTimeout(state, state.transport.connection.agent.request(methods.agent.session.prompt, {
        sessionId: state.host.nativeSessionId!, prompt: [{ type: "text", text }],
      }), this.timeoutMs));
    this.updateRuntime(request.sessionId, { turnId });
    this.emit("liveEvent", { type: "turn_started", sessionId: request.sessionId, turnId });
    return { mode: "turn", turnId };
  }

  async interruptTurn(id: string, turnId: string): Promise<unknown> {
    const state = this.sessions.get(id);
    if (!state?.active || state.active.turnId !== turnId) return { interrupted: false };
    state.active.interrupted = true;
    state.host.cancelPending();
    const done = state.active.done;
    const timer = setTimeout(() => { void this.disconnect(state); }, 1500);
    timer.unref();
    try {
      await state.transport.connection.agent.notify(methods.agent.session.cancel, { sessionId: state.host.nativeSessionId! }).catch(() => {});
      await done;
    } finally { clearTimeout(timer); }
    return { interrupted: true };
  }

  respondToPendingAction(action: AgentPendingAction, input: PendingActionResponseInput): boolean {
    return this.sessions.get(action.sessionId)?.host.respond(action.id, input) ?? false;
  }

  async setSessionConfiguration(id: string, optionId: string, value: string | boolean): Promise<SessionRuntimeSummary | null> {
    const state = await this.ensureConnection(id);
    await state.loading;
    const option = this.metadata(this.record(id)).runtime?.configurationOptions?.find((option) => option.id === optionId);
    if (!option || typeof option.value !== typeof value || (option.options && !option.options.some((entry) => entry.value === value))) {
      throw new AgentProviderRequestError("Unsupported session configuration value");
    }
    if (option.id === "acp:mode") {
      await this.requestWithTimeout(state, state.transport.connection.agent.request(methods.agent.session.setMode,
        { sessionId: state.host.nativeSessionId!, modeId: String(value) }));
      this.updateRuntime(id, { mode: String(value), configurationOptions:
        this.metadata(this.record(id)).runtime?.configurationOptions?.map((entry) => entry.id === optionId ? { ...entry, value } : entry) });
    } else {
      const params: SetSessionConfigOptionRequest = { sessionId: state.host.nativeSessionId!, configId: optionId,
        ...(typeof value === "boolean" ? { type: "boolean", value } : { value }) };
      const response = await this.requestWithTimeout(state, state.transport.connection.agent.request(methods.agent.session.setConfigOption, params));
      this.applySessionOptions(id, response);
    }
    return this.metadata(this.record(id)).runtime ?? null;
  }

  async listModels(_options: AgentModelListOptions): Promise<ModelSummary[]> {
    await this.start();
    const models = new Map<string, ModelSummary>();
    for (const record of this.db.listProviderSessions(this.providerId)) {
      const runtime = this.metadata(record).runtime;
      const model = runtime?.configurationOptions?.find((option) => option.category === "model");
      const options = model?.options ?? (runtime?.model ? [{ value: runtime.model, label: runtime.model }] : []);
      for (const option of options) models.set(option.value, { id: option.value, model: option.value, displayName: option.label,
        description: "Model supplied by the ACP agent", defaultReasoningEffort: "auto", supportedReasoningEfforts: [],
        reasoningEffortControl: "provider", supportsPersonality: false, additionalSpeedTiers: [], inputModalities: ["text"],
        isDefault: runtime?.model === option.value, source: "acpx" });
    }
    return [...models.values()];
  }

  private async ensureConnection(id: string): Promise<ConnectedSession> {
    if (this.closed) throw new Error("ACP provider is closed");
    const pending = this.connecting.get(id);
    if (pending) return pending;
    const existing = this.sessions.get(id);
    if (existing && !existing.transport.connection.signal.aborted) return existing;
    if (existing) await this.disconnect(existing);
    if (this.closed) throw new Error("ACP provider is closed");
    const promise = this.connectSession(id);
    this.connecting.set(id, promise);
    try { return await promise; }
    finally { this.connecting.delete(id); }
  }

  private async connectSession(id: string): Promise<ConnectedSession> {
    const record = this.record(id);
    let state: ConnectedSession | undefined;
    const host = new AcpHost(id, record.cwd, this.permissionMode, (event) => this.emit("liveEvent", event), (params) => {
      if (!state) return;
      try {
        if (!state.host.nativeSessionId) state.earlyUpdates.push(params);
        else if (params.sessionId === state.host.nativeSessionId) this.handleUpdate(id, state, params.update);
      } catch (error) {
        this.emit("liveEvent", { type: "provider_warning", sessionId: id, level: "error",
          code: "acp_history_write_failed", message: errorMessage(error), source: "acp" });
        state.transport.connection.close(error);
      }
    });
    host.nativeSessionId = record.nativeId;
    const transport = this.dependencies.connect ? await this.dependencies.connect(host.app, record.cwd)
      : await this.spawnConnection(host.app, record.cwd);
    state = { host, transport, initialized: { protocolVersion: PROTOCOL_VERSION }, transcript: this.transcript(id), earlyUpdates: [] };
    this.sessions.set(id, state);
    const connectedState = state;
    void transport.connection.closed.then(() => this.disconnect(connectedState))
      .catch((error) => this.emit("stderr", `ACP cleanup failed: ${errorMessage(error)}`));
    try {
      if (this.closed) throw new Error("ACP provider is closed");
      state.initialized = await this.requestWithTimeout(state, transport.connection.agent.request(methods.agent.initialize, {
        protocolVersion: PROTOCOL_VERSION, clientInfo: { name: "sidemesh", version: "1" },
        clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: true,
          elicitation: { form: {}, url: {} }, session: { configOptions: { boolean: {} }, compaction: {} } },
      }));
      if (state.initialized.protocolVersion !== PROTOCOL_VERSION) throw new Error("Unsupported ACP protocol version");
      if (record.nativeId) {
        if (state.initialized.agentCapabilities?.loadSession) await this.refreshHistory(id, state);
        else if (state.initialized.agentCapabilities?.sessionCapabilities?.resume) {
          const response = await this.authenticated(state, () => transport.connection.agent.request(methods.agent.session.resume,
            { sessionId: record.nativeId!, cwd: record.cwd, mcpServers: [] }));
          this.applySessionOptions(id, response);
        } else throw new Error("This agent cannot resume the saved session; its display history is still available");
      } else {
        const response = await this.authenticated(state, () => transport.connection.agent.request(methods.agent.session.new,
          { cwd: record.cwd, mcpServers: [] }));
        host.nativeSessionId = response.sessionId;
        this.db.saveProviderSession(this.providerId, { ...this.record(id), nativeId: response.sessionId });
        this.applySessionOptions(id, response);
        for (const early of state.earlyUpdates) if (early.sessionId === response.sessionId) this.handleUpdate(id, state, early.update);
        state.earlyUpdates = [];
      }
      return state;
    } catch (error) { await this.disconnect(state); throw error; }
  }

  private async refreshHistory(id: string, state: ConnectedSession): Promise<void> {
    if (state.active || !state.initialized.agentCapabilities?.loadSession) return;
    if (state.loading) return state.loading;
    state.loading = (async () => {
      const items = new Map<string, StoredSessionItem>();
      const writer = new AcpTranscript(id, 0, (key) => items.get(key) ?? null, (item) => items.set(item.value.id, item));
      state.replay = { items, writer, updates: [] };
      try {
        const record = this.record(id);
        const response = await this.authenticated(state, () => state.transport.connection.agent.request(methods.agent.session.load,
          { sessionId: state.host.nativeSessionId!, cwd: record.cwd, mcpServers: [] }));
        writer.finish();
        const updates = state.replay.updates;
        const reconciled = reconcileSessionHistory(this.db.readSessionItems(this.providerId, id), [...items.values()].map((item) => ({ ...item, authority: "cache" })));
        this.db.replaceProviderHistory(this.providerId, this.record(id), reconciled);
        state.replay = undefined;
        this.applySessionOptions(id, response);
        for (const update of updates) this.handleMetadata(id, update);
        state.transcript = this.transcript(id);
        if (reconciled.some((item) => item.authority !== "cache")) this.emit("liveEvent", {
          type: "provider_warning", sessionId: id, level: "warning", code: "acp_history_unconfirmed",
          message: "Some local output is not in the agent history. Sidemesh kept it.", source: "acp",
        });
      } finally { state.replay = undefined; }
    })();
    try { await state.loading; } finally { state.loading = undefined; }
  }

  private handleUpdate(id: string, state: ConnectedSession, update: SessionUpdate): void {
    if (state.replay) {
      state.replay.writer.update(update);
      if (["config_option_update", "current_mode_update", "available_commands_update", "usage_update", "session_info_update", "plan"].includes(update.sessionUpdate)) {
        state.replay.updates.push(update);
      }
      return;
    }
    state.transcript.update(update);
    this.handleMetadata(id, update);
  }

  private handleMetadata(id: string, update: SessionUpdate): void {
    if (update.sessionUpdate === "config_option_update") this.applySessionOptions(id, { configOptions: update.configOptions });
    else if (update.sessionUpdate === "current_mode_update") this.updateRuntime(id, { mode: update.currentModeId,
      configurationOptions: this.metadata(this.record(id)).runtime?.configurationOptions?.map((option) =>
        option.category === "mode" ? { ...option, value: update.currentModeId } : option) });
    else if (update.sessionUpdate === "available_commands_update") this.updateRuntime(id, { commands:
      update.availableCommands.map((command) => ({ name: command.name, description: command.description, inputHint: command.input?.hint })) });
    else if (update.sessionUpdate === "usage_update") this.updateRuntime(id, { telemetry: { contextWindow:
      { currentTokens: update.used, tokenLimit: update.size, messagesLength: 0, updatedAt: Date.now() } } });
    else if (update.sessionUpdate === "session_info_update") {
      const record = this.record(id);
      this.db.saveProviderSession(this.providerId, { ...record,
        name: this.metadata(record).localName ? record.name : update.title ?? record.name,
        updatedAt: update.updatedAt ? Date.parse(update.updatedAt) || record.updatedAt : record.updatedAt });
    } else if (update.sessionUpdate === "plan") {
      const record = this.record(id);
      const plan: LatestPlanUpdate = { type: "plan_updated", sessionId: id,
        plan: update.entries.map((entry) => ({ step: entry.content, status: entry.status })) };
      this.db.saveProviderSession(this.providerId, { ...record, metadata: { ...this.metadata(record), latestPlanUpdate: plan } });
      this.emit("liveEvent", plan);
    }
  }

  private applySessionOptions(id: string, response: LoadSessionResponse): void {
    const runtime = this.metadata(this.record(id)).runtime ?? {};
    let configurationOptions = response.configOptions ? response.configOptions.map(configurationOption) : runtime.configurationOptions ?? [];
    if (response.configOptions && !configurationOptions.some((option) => option.category === "mode")) {
      configurationOptions.push(...runtime.configurationOptions?.filter((option) => option.id === "acp:mode") ?? []);
    }
    if (response.modes && !configurationOptions.some((option) => option.category === "mode" && option.id !== "acp:mode")) configurationOptions = [
      ...configurationOptions.filter((option) => option.id !== "acp:mode"),
      { id: "acp:mode", label: "Mode", category: "mode", value: response.modes.currentModeId,
        options: response.modes.availableModes.map((mode) => ({ value: mode.id, label: mode.name })) },
    ];
    const model = configurationOptions.find((option) => option.category === "model")?.value;
    const mode = response.modes?.currentModeId ?? configurationOptions.find((option) => option.category === "mode")?.value;
    this.updateRuntime(id, { configurationOptions, ...(typeof model === "string" ? { model } : {}), ...(typeof mode === "string" ? { mode } : {}) });
  }

  private async applyControls(id: string, state: ConnectedSession, overrides: { model?: string | null; mode?: string | null }): Promise<void> {
    await state.loading;
    for (const category of ["model", "mode"] as const) {
      const value = overrides[category];
      if (!value) continue;
      const option = this.metadata(this.record(id)).runtime?.configurationOptions?.find((option) => option.category === category);
      if (!option) throw new Error(`Agent does not offer a ${category} control`);
      if (option.value !== value) await this.setSessionConfiguration(id, option.id, value);
    }
  }

  private async finishPrompt(id: string, state: ConnectedSession, active: NonNullable<ConnectedSession["active"]>, prompt: Promise<{ stopReason: string }>): Promise<void> {
    let status = "completed";
    try {
      if ((await prompt).stopReason === "cancelled") status = "interrupted";
      if (active.clientInputId) this.emit("liveEvent", { type: "input_confirmed", sessionId: id, clientInputId: active.clientInputId });
    }
    catch (error) {
      status = active.interrupted || this.closed ? "interrupted" : "failed";
      if (status === "failed") this.emit("liveEvent", { type: "provider_warning", sessionId: id, level: "error",
        code: "acp_turn_failed", message: errorMessage(error), source: "acp" });
    } finally {
      state.transcript.finish();
      if (state.active === active) state.active = undefined;
      state.host.cancelPending();
      this.updateRuntime(id, { turnId: undefined });
      this.emit("liveEvent", { type: "turn_completed", sessionId: id, turnId: active.turnId,
        status: active.interrupted || this.closed ? "interrupted" : status });
    }
  }

  private transcript(id: string): AcpTranscript {
    return new AcpTranscript(id, this.db.nextSessionSequence(this.providerId, id),
      (key) => this.db.getSessionItem(this.providerId, id, key),
      (item) => {
        this.db.putSessionItem(this.providerId, id, item);
        const record = this.record(id);
        this.db.saveProviderSession(this.providerId, { ...record, updatedAt: Date.now(),
          preview: record.preview || (item.kind === "message" ? item.value.text.slice(0, 160) : "") });
      }, (event) => this.emit("liveEvent", event));
  }

  private async discoverSessions(): Promise<void> {
    const state = [...this.sessions.values()].find((state) => state.initialized.agentCapabilities?.sessionCapabilities?.list && !state.active && !state.loading);
    if (!state) return;
    try {
      let cursor: string | undefined;
      const seen = new Set<string>();
      do {
        const response = await this.requestWithTimeout(state, state.transport.connection.agent.request(methods.agent.session.list, { cursor }));
        const known = this.db.listProviderSessions(this.providerId);
        for (const session of response.sessions) {
          const previous = known.find((record) => record.nativeId === session.sessionId);
          if (previous) continue;
          const updatedAt = session.updatedAt ? Date.parse(session.updatedAt) || Date.now() : Date.now();
          this.db.saveProviderSession(this.providerId, { id: `acp-native-${Buffer.from(session.sessionId).toString("base64url")}`,
            nativeId: session.sessionId, cwd: session.cwd, name: session.title ?? null, preview: session.title ?? "ACP session",
            createdAt: updatedAt, updatedAt, archived: false, metadata: {} });
        }
        cursor = response.nextCursor ?? undefined;
        if (cursor && seen.has(cursor)) throw new Error("ACP session list repeated its cursor");
        if (cursor) seen.add(cursor);
      } while (cursor);
    } catch (error) {
      this.emit("stderr", `ACP session discovery failed: ${errorMessage(error)}`);
    }
  }

  private async authenticated<T>(state: ConnectedSession, operation: () => Promise<T>): Promise<T> {
    try { return await this.requestWithTimeout(state, operation()); }
    catch (error) {
      if (!(error instanceof RequestError) || error.code !== RequestError.authRequired().code) throw error;
      const methodId = await state.host.selectAuthentication(state.initialized.authMethods ?? [], state.transport.connection.signal);
      if (!methodId) throw error;
      await this.requestWithTimeout(state, state.transport.connection.agent.request(methods.agent.authenticate, { methodId }), this.timeoutMs);
      return await this.requestWithTimeout(state, operation());
    }
  }

  private async requestWithTimeout<T>(state: ConnectedSession, request: Promise<T>, timeoutMs = 30_000): Promise<T> {
    const timer = setTimeout(() => {
      state.transport.connection.close(new Error("ACP request timed out"));
      void this.disconnect(state);
    }, timeoutMs);
    timer.unref();
    try { return await request; } finally { clearTimeout(timer); }
  }

  private async disconnect(state: ConnectedSession): Promise<void> {
    state.disconnecting ??= (async () => {
      const id = state.host.sessionId;
      const done = state.active?.done;
      const hostClosed = state.host.close();
      if (state.host.nativeSessionId && state.initialized.agentCapabilities?.sessionCapabilities?.close && !state.transport.connection.signal.aborted) {
        await this.requestWithTimeout(state, state.transport.connection.agent.request(methods.agent.session.close,
          { sessionId: state.host.nativeSessionId }), 1000).catch(() => {});
      }
      state.transport.connection.close();
      try { await Promise.all([hostClosed, state.transport.close(), done]); }
      finally { if (this.sessions.get(id) === state) this.sessions.delete(id); }
    })();
    await state.disconnecting;
  }

  private async spawnConnection(app: ClientApp, cwd: string): Promise<AcpTransport> {
    const env = { ...process.env };
    delete env.SIDEMESH_TOKEN;
    const child = spawn(this.command, { cwd, env, shell: true, stdio: "pipe", detached: process.platform !== "win32" });
    let exited = false;
    const done = new Promise<void>((resolve) => child.once("close", () => { exited = true; resolve(); }));
    const connection = app.connect(ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout)));
    child.stderr.on("data", (chunk: Buffer) => this.emit("stderr", chunk.toString()));
    child.on("error", (error) => connection.close(error));
    child.once("close", () => connection.close());
    return { connection, close: async () => {
      connection.close();
      if (!exited) terminatePipeProcess(child, () => exited);
      await done;
    } };
  }

  private updateRuntime(id: string, patch: Partial<SessionRuntimeSummary>): void {
    const record = this.record(id);
    const metadata = this.metadata(record);
    const runtime = { ...metadata.runtime, ...patch, updatedAt: Date.now() };
    this.db.saveProviderSession(this.providerId, { ...record, metadata: { ...metadata, runtime } });
    this.emit("liveEvent", { type: "runtime_updated", sessionId: id, runtime });
  }
  private get db(): SessionStore {
    if (!this.store) throw new Error("ACP provider has not started");
    return this.store;
  }
  private record(id: string): StoredProviderSession {
    const record = this.db.getProviderSession(this.providerId, id);
    if (!record) throw new AgentProviderRequestError("ACP session not found", 404);
    return record;
  }
  private metadata(record: StoredProviderSession): AcpSessionMetadata {
    return (record.metadata ?? {}) as AcpSessionMetadata;
  }
  private thread(record: StoredProviderSession, includeTurns: boolean): ThreadRecord {
    const active = this.sessions.get(record.id)?.active;
    const phase = record.archived ? "closed" : active ? "running" : "idle";
    return { id: record.id, name: record.name, preview: record.preview, cwd: record.cwd, source: "acpx", path: null,
      createdAt: Math.floor(record.createdAt / 1000), updatedAt: Math.floor(record.updatedAt / 1000),
      status: { type: phase, phase, ...(active ? { activeFlags: ["inProgress"] } : {}) },
      ...(includeTurns ? { turns: active ? [{ id: active.turnId, status: "inProgress", startedAt: null, completedAt: null }] : [] } : {}) };
  }
}

function configurationOption(option: SessionConfigOption): SessionConfigurationOption {
  return { id: option.id, label: option.name, description: option.description ?? undefined, category: option.category ?? undefined,
    value: option.currentValue, ...(option.type === "select" ? { options: option.options.flatMap((entry) => "options" in entry
      ? entry.options.map((value) => ({ value: value.value, label: value.name, group: entry.name }))
      : [{ value: entry.value, label: entry.name }]) } : {}) };
}
function inputText(input: AgentSessionInputItem[]): string {
  return input.map((item) => {
    if (item.type === "text") return item.text;
    if (item.type === "file") return `${item.isDirectory ? "Directory" : "File"}: ${item.path}`;
    throw new Error(`ACP ${item.type} input is not supported`);
  }).join("\n\n");
}
function tail<T>(items: T[], limit?: number | null): T[] {
  return limit == null || limit < 0 ? items : items.slice(Math.max(0, items.length - limit));
}
function errorMessage(error: unknown): string { return error instanceof Error ? error.message : String(error); }
