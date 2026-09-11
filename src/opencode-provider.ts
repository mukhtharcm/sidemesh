import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, extname, join } from "node:path";
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { setTimeout as sleep } from "node:timers/promises";
import { createOpencodeClient, type OpencodeClient, type OpencodeClientConfig,
  type Session as OpenCodeSessionInfo, type SessionStatus as OpenCodeSessionStatus,
  type SessionMessageResponse as OpenCodeMessage, type TextPart as OpenCodeMessageTextPart,
  type ReasoningPart as OpenCodeMessageReasoningPart, type FilePart as OpenCodeMessageFilePart,
  type ToolPart as OpenCodeMessageToolPart, type CompactionPart as OpenCodeMessageCompactionPart,
  type Part as OpenCodeMessagePart, type ToolState as OpenCodeMessageToolState,
  type UserMessage as OpenCodeUserMessageInfo, type AssistantMessage as OpenCodeAssistantMessageInfo,
  type TextPartInput, type FilePartInput, type PermissionRequest as OpenCodePermissionRequest,
  type QuestionRequest as OpenCodeQuestionRequest, type QuestionInfo as OpenCodeQuestionInfo,
  type Model as OpenCodeProviderModel, type GlobalEvent } from "@opencode-ai/sdk/v2/client";
import { AgentProviderRequestError, materializeAgentActivityDraft, type AgentCreateSessionRequest,
  type AgentCreateSessionResult, type AgentModelListOptions, type AgentModeListOptions, type AgentPendingAction,
  type AgentProvider, type AgentProviderCapabilities, type AgentProviderEvents, type AgentSessionActivityDraft,
  type AgentSessionInputItem, type AgentSessionListOptions, type AgentSessionLogOptions,
  type AgentSessionResumeOptions, type AgentSubmitInputRequest, type AgentSubmitInputResult,
  type AgentSkillListOptions } from "./agent-provider.js";
import { parsePendingActionDecision, parsePendingActionProviderOptionResponse, parsePendingActionElicitationResponse,
  parsePendingActionUserInputResponse, type PendingActionResponseInput } from "./approvals.js";
import { SessionStore, type StoredProviderSession, type StoredSessionItem } from "./session-store.js";
import { reconcileSessionHistory } from "./session-history.js";
import { extractSessionAttachments } from "./session-attachments.js";
import { terminatePipeProcess } from "./terminal.js";
import type { LiveThreadStatus, LivePlanStep, ModelSummary, PendingActionApproval, PendingActionApprovalTarget,
  PendingActionElicitationField, ProviderModeCatalog, SessionActivity, SessionLogSnapshot, SessionMessage,
  SessionMessageAttachment, SessionMessageContentBlock, SessionSubAgentInfo, SessionRuntimeSummary,
  SkillCatalogEntry, SkillSummary, ThreadRecord, TurnRecord } from "./types.js";

type OpenCodeModelRef = OpenCodeUserMessageInfo["model"] & { variant?: string };
type OpenCodePromptPart = TextPartInput | FilePartInput;
interface OpenCodeMetadata { info: OpenCodeSessionInfo; runtime: SessionRuntimeSummary | null; }
interface ActiveOpenCodeTurn { id: string; status: string; started: boolean; submitting: boolean; }
export interface OpenCodeServerHandle { baseUrl: URL; headers?: Record<string, string>; close(): Promise<void>; }
export interface OpenCodeServerFactoryOptions {
  bin: string; stateDir: string | null; signal?: AbortSignal; readyTimeoutMs?: number;
  onOutput(line: string): void; onExit(code: number | null): void;
}
export type OpenCodeServerFactory = (options: OpenCodeServerFactoryOptions) => Promise<OpenCodeServerHandle>;
export interface OpenCodeAgentProviderOptions {
  bin?: string; stateDir?: string | null; defaultDirectory?: string | null;
  providerId?: string; sessionStore?: SessionStore; hostStateDir?: string;
  serverFactory?: OpenCodeServerFactory;
  clientFactory?: (options: OpencodeClientConfig) => OpencodeClient;
}
const REASONING_EFFORTS = [
  {
    reasoningEffort: "low",
    description: "Faster reasoning with a smaller internal budget.",
  },
  {
    reasoningEffort: "medium",
    description: "Balanced reasoning depth.",
  },
  {
    reasoningEffort: "high",
    description: "Deeper reasoning when the upstream model supports it.",
  },
] as const;

const GENERIC_MODE_LABELS: Record<string, string> = {
  interactive: "Interactive",
  plan: "Plan",
  autopilot: "Autopilot",
};

export const OPENCODE_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
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
    steer: false,
    imageUrl: true,
    localImage: true,
    skills: true,
    fileMentions: true,
  },
  interaction: {
    userInput: true,
    elicitation: true,
  },
  approvals: {
    command: false,
    tool: false,
    fileChange: false,
    permissions: true,
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
    mode: true,
    reasoningEffort: false,
    fastMode: false,
    approvalPolicy: false,
    sandboxMode: false,
    networkAccess: false,
    webSearch: false,
    accessMode: false,
  },
  lifecycle: {
    restart: true,
  },
  usage: {
    accountLimits: false,
    localTelemetry: false,
    credits: false,
    resetWindows: false,
  },
};

export class OpenCodeAgentProvider extends EventEmitter<AgentProviderEvents> implements AgentProvider {
  readonly kind = "opencode";
  readonly displayName = "OpenCode";
  readonly capabilities = OPENCODE_PROVIDER_CAPABILITIES;
  private readonly providerId: string;
  private readonly directory: string;
  private store?: SessionStore;
  private client?: OpencodeClient;
  private server?: OpenCodeServerHandle;
  private starting?: Promise<void>;
  private closing?: Promise<void>;
  private closed = false;
  private abort = new AbortController();
  private eventTask?: Promise<void>;
  private readonly active = new Map<string, ActiveOpenCodeTurn>();
  private readonly loaded = new Set<string>();
  private readonly parts = new Map<string, { sessionId: string; messageId: string; type: "text" | "reasoning" }>();
  private readonly pending = new Map<string, { action: AgentPendingAction; responding: boolean }>();

  constructor(private readonly options: OpenCodeAgentProviderOptions = {}) {
    super();
    this.providerId = options.providerId ?? "opencode";
    this.directory = options.defaultDirectory?.trim() || process.cwd();
    this.store = options.sessionStore;
  }

  async start(): Promise<void> {
    if (this.closed) throw new Error("OpenCode provider is closed");
    this.starting ??= this.startInternal();
    await this.starting;
  }
  private async startInternal(): Promise<void> {
    this.store ??= await SessionStore.open(this.options.hostStateDir ?? process.env.SIDEMESH_STATE_DIR ?? join(homedir(), ".sidemesh"));
    try {
      this.server = await (this.options.serverFactory ?? createOpenCodeServer)({
        bin: this.options.bin?.trim() || "opencode", stateDir: this.options.stateDir ?? null, signal: this.abort.signal,
        onOutput: (line) => this.emit("stderr", line), onExit: (code) => { if (!this.closed) this.emit("exit", code); },
      });
      if (this.closed) throw new Error("OpenCode provider is closing");
      const factory = this.options.clientFactory ?? createOpencodeClient;
      let lastError: unknown;
      for (const baseUrl of [this.server.baseUrl.href, new URL("api/", this.server.baseUrl).href]) {
        const client = factory({ baseUrl: baseUrl.replace(/\/$/, ""), headers: this.server.headers });
        try { await client.global.health(this.requestOptions()); this.client = client; break; }
        catch (error) { lastError = error; }
      }
      if (!this.client) throw new Error("OpenCode did not expose a supported headless HTTP API", { cause: lastError });
      let connected!: () => void;
      let failed!: (error: unknown) => void;
      const ready = new Promise<void>((resolve, reject) => { connected = resolve; failed = reject; });
      const timeout = setTimeout(() => failed(new Error("OpenCode event stream did not become ready")), 30_000);
      this.eventTask = this.readEvents(connected, failed);
      try { await ready; } finally { clearTimeout(timeout); }
    } catch (error) {
      this.abort.abort();
      await this.eventTask;
      await this.server?.close();
      this.server = undefined;
      this.client = undefined;
      throw error;
    }
  }

  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closed = true;
    this.abort.abort();
    this.closing = (async () => {
      await this.starting?.catch(() => {});
      await this.eventTask;
      await this.server?.close();
      for (const [id, turn] of this.active) if (turn.started) this.emit("liveEvent", { type: "turn_completed", sessionId: id, turnId: turn.id, status: "interrupted" });
      this.active.clear();
      for (const id of [...this.pending.keys()]) this.resolveAction(id);
      this.parts.clear();
      this.server = undefined;
      this.client = undefined;
      if (!this.options.sessionStore) this.store?.close();
      this.store = undefined;
    })();
    return this.closing;
  }
  async restart(): Promise<void> {
    await this.close();
    this.closed = false;
    this.closing = undefined;
    this.starting = undefined;
    this.abort = new AbortController();
    this.store = this.options.sessionStore;
    await this.start();
  }
  async health(): Promise<boolean> {
    if (this.closed || !this.client) return false;
    try { return (await this.client.global.health(this.requestOptions())).data.healthy; } catch { return false; }
  }
  async getVersion(): Promise<string> { await this.start(); return `OpenCode ${(await this.sdk.global.health(this.requestOptions())).data.version}`; }

  async listSessionThreads(options: AgentSessionListOptions): Promise<ThreadRecord[]> {
    await this.start();
    const sessions = await this.listNativeSessions(options);
    const statuses = new Map<string, Record<string, OpenCodeSessionStatus>>();
    await Promise.all([...new Set(sessions.map((session) => session.directory))].map(async (directory) => {
      statuses.set(directory, (await this.sdk.session.status({ directory }, this.requestOptions())).data);
    }));
    return sessions.map((info) => this.thread(info, statuses.get(info.directory)?.[info.id] ?? { type: "idle" }, false));
  }
  async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> { return this.listSessionThreads({ limit, archived: false }); }
  async listLoadedSessionIds(): Promise<string[]> { return [...this.loaded]; }
  async readSessionThread(id: string, includeTurns: boolean): Promise<ThreadRecord> {
    const info = await this.info(id);
    const messages = includeTurns ? (await this.sdk.session.messages({ sessionID: id, directory: info.directory }, this.requestOptions())).data : [];
    const status = (await this.sdk.session.status({ directory: info.directory }, this.requestOptions())).data[id] ?? { type: "idle" };
    const thread = this.thread(info, status, includeTurns);
    if (includeTurns) thread.turns = buildTurns(messages, status);
    return thread;
  }
  async readSessionLog(thread: ThreadRecord, options: AgentSessionLogOptions = {}): Promise<SessionLogSnapshot> {
    const info = await this.info(thread.id, thread.cwd);
    const messages = (await this.sdk.session.messages({ sessionID: thread.id, directory: info.directory }, this.requestOptions())).data;
    const [permissions, questions] = await Promise.all([
      this.sdk.permission.list({ directory: info.directory }, this.requestOptions()),
      this.sdk.question.list({ directory: info.directory }, this.requestOptions()),
    ]);
    this.syncActions(info, permissions.data, questions.data);
    const snapshot = this.saveHistory(info, messages);
    this.loaded.add(thread.id);
    return { ...snapshot, messages: limitTail(snapshot.messages, options.messageLimit ?? null),
      activities: limitTail(snapshot.activities, options.activityLimit ?? null) };
  }
  async readSessionRuntime(thread: ThreadRecord): Promise<SessionRuntimeSummary | null> {
    await this.info(thread.id, thread.cwd);
    return this.metadata(this.record(thread.id)).runtime;
  }
  async resumeSessionThread(id: string, _options?: AgentSessionResumeOptions): Promise<unknown> {
    const info = await this.info(id);
    this.loaded.add(id);
    await this.readSessionLog(this.thread(info, { type: "idle" }, false));
    return { resumed: true };
  }
  async setSessionName(id: string, name: string): Promise<unknown> {
    const info = await this.info(id);
    this.saveInfo((await this.sdk.session.update({ sessionID: id, directory: info.directory, title: name }, this.requestOptions())).data);
    return { renamed: true };
  }
  async archiveSession(id: string): Promise<unknown> {
    const info = await this.info(id);
    await this.interruptTurn(id, this.active.get(id)?.id ?? id);
    this.saveInfo((await this.sdk.session.update({ sessionID: id, directory: info.directory, time: { archived: Date.now() } }, this.requestOptions())).data);
    return { archived: true };
  }
  async unarchiveSession(id: string): Promise<unknown> {
    const info = await this.info(id);
    this.saveInfo((await this.sdk.session.update({ sessionID: id, directory: info.directory, time: { archived: 0 } }, this.requestOptions())).data);
    return { unarchived: true };
  }
  async compactSession(id: string): Promise<unknown> {
    const info = await this.info(id);
    await this.sdk.session.summarize({ sessionID: id, directory: info.directory }, this.requestOptions(120_000));
    this.invalidate(id);
    return { compacted: true };
  }
  async createSession(request: AgentCreateSessionRequest): Promise<AgentCreateSessionResult> {
    await this.start();
    const controls = await this.controls(request.cwd, request.overrides);
    const info = (await this.sdk.session.create({ directory: request.cwd, title: deriveSessionTitle(request.input) ?? undefined,
      agent: controls.agent, ...(controls.model ? { model: { id: controls.model.modelID, providerID: controls.model.providerID, variant: controls.variant } } : {}) }, this.requestOptions())).data;
    this.saveInfo(info);
    this.loaded.add(info.id);
    const input = request.input.length ? await this.submitInput({ ...request, sessionId: info.id, activeTurnId: null }) : null;
    return { thread: this.thread(info, input ? { type: "busy" } : { type: "idle" }, false), activeTurnId: input?.turnId ?? null,
      runtime: this.metadata(this.record(info.id)).runtime };
  }
  async submitInput(request: AgentSubmitInputRequest): Promise<AgentSubmitInputResult> {
    let info: OpenCodeSessionInfo;
    let controls: Awaited<ReturnType<OpenCodeAgentProvider["controls"]>>;
    let prepared: ReturnType<typeof preparePromptInput>;
    try {
      info = await this.info(request.sessionId);
      if (info.time.archived) throw new Error("OpenCode session is archived");
      const status = (await this.sdk.session.status({ directory: info.directory }, this.requestOptions())).data[info.id];
      if (this.active.has(info.id) || status?.type === "busy" || status?.type === "retry") throw new Error("OpenCode is busy; the host must queue this input");
      controls = await this.controls(info.directory, request.overrides);
      prepared = preparePromptInput(request.input);
      if (this.closed) throw new Error("OpenCode is closing");
    } catch (error) { throw new AgentProviderRequestError(formatError(error), 409, true); }
    const messageID = `msg_${createHash("sha256").update(`${this.providerId}:${info.id}:${request.clientMessageId ?? randomUUID()}`).digest("hex").slice(0, 32)}`;
    const value: SessionMessage = { id: request.clientMessageId ?? messageID, role: "user",
      text: prepared.parts.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n"),
      content: prepared.parts.flatMap((part) => part.type === "text" ? [{ type: "text" as const, text: part.text }] : []),
      attachments: request.input.flatMap((item): SessionMessageAttachment[] => item.type === "image" ? [{ type: "image", url: item.url }]
        : item.type === "localImage" ? [{ type: "localImage", path: item.path }] : item.type === "file" ? [{ type: "file", path: item.path }] : []),
      createdAt: Date.now(), seq: this.db.nextSessionSequence(this.providerId, info.id) };
    this.db.putSessionItem(this.providerId, info.id, { kind: "message", value, nativeId: messageID, authority: "recovery" });
    const turn: ActiveOpenCodeTurn = { id: messageID, status: "completed", started: false, submitting: true };
    this.active.set(info.id, turn);
    this.loaded.add(info.id);
    try {
      await this.sdk.session.promptAsync({ sessionID: info.id, directory: info.directory, messageID, ...controls, parts: prepared.parts }, this.requestOptions());
      turn.submitting = false;
      await this.finishTurn(info.id).catch((error) => this.warning(info.id, "opencode_refresh_failed", formatError(error)));
      return { mode: "turn", turnId: messageID };
    } catch (error) {
      turn.submitting = false;
      this.warning(info.id, "opencode_input_uncertain", formatError(error));
      await this.finishTurn(info.id).catch(() => {});
      this.invalidate(info.id);
      throw error;
    }
  }
  async interruptTurn(id: string, _turnId: string): Promise<unknown> {
    const info = await this.info(id);
    const active = this.active.get(id);
    if (active) active.status = "interrupted";
    await this.sdk.session.abort({ sessionID: id, directory: info.directory }, this.requestOptions());
    await this.finishTurn(id);
    return { interrupted: true };
  }

  async listModels(options: AgentModelListOptions): Promise<ModelSummary[]> {
    await this.start();
    const result = (await this.sdk.provider.list({ directory: options.cwd ?? this.directory }, this.requestOptions())).data;
    const models = result.all.flatMap((provider) => Object.values(provider.models).flatMap((model) => {
      if (options.provider && provider.id !== options.provider) return [];
      return [undefined, ...Object.keys(model.variants ?? {})].map((variant) => buildModelSummary(provider.name, model,
        { providerID: provider.id, modelID: model.id, variant }, { isDefault: !variant && result.default[provider.id] === model.id }));
    }));
    return models.sort((a, b) => Number(b.isDefault) - Number(a.isDefault) || a.displayName.localeCompare(b.displayName));
  }
  async listModes(options: AgentModeListOptions): Promise<ProviderModeCatalog> {
    await this.start();
    const agents = (await this.sdk.app.agents({ directory: options.cwd ?? this.directory }, this.requestOptions())).data;
    return { defaultMode: null, modes: agents.filter((agent) => !agent.hidden && agent.mode !== "subagent")
      .map((agent) => ({ id: agent.name, label: prettifyModeName(agent.name) })).sort((a, b) => a.label.localeCompare(b.label)) };
  }
  async listSkills(options: AgentSkillListOptions): Promise<SkillCatalogEntry> {
    await this.start();
    const skills = (await this.sdk.app.skills({ directory: options.cwd }, this.requestOptions())).data;
    return { cwd: options.cwd, skills: skills.map((skill): SkillSummary => ({ name: skill.name, description: skill.description ?? "",
      path: skill.location, scope: inferSkillScope(options.cwd, skill.location), enabled: true })), errors: [] };
  }

  respondToPendingAction(action: AgentPendingAction, input: PendingActionResponseInput): boolean {
    const pending = this.pending.get(action.id);
    if (!pending || pending.responding || this.closed) return false;
    const offered = pending.action;
    let respond: () => Promise<unknown>;
    const parameters = { requestID: String(offered.providerRequestId), directory: offered.cwd ?? undefined };
    if (offered.providerRequestKind === "opencode/permission") {
      const option = parsePendingActionProviderOptionResponse(input)?.providerOptionId;
      const decision = parsePendingActionDecision(input);
      const reply = option ?? (decision ? decision.decision === "approve" ? decision.scope === "once" ? "once" : "always" : "reject" : null);
      if ((reply !== "once" && reply !== "always" && reply !== "reject") || !offered.approval?.providerOptions?.some((item) => item.id === reply)) return false;
      respond = () => this.sdk.permission.reply({ ...parameters, reply }, this.requestOptions());
    } else {
      const decision = parsePendingActionDecision(input)?.decision;
      const elicitation = parsePendingActionElicitationResponse(input);
      if (decision === "cancel" || decision === "decline" || elicitation?.action === "cancel" || elicitation?.action === "decline") {
        respond = () => this.sdk.question.reject(parameters, this.requestOptions());
      } else {
        const user = parsePendingActionUserInputResponse(input);
        const questions = (offered.providerPayload as OpenCodeQuestionRequest).questions;
        const answers = user ? [[user.answer]] : elicitation?.action === "accept" ? buildQuestionAnswersFromElicitation(questions, elicitation.content ?? {}) : null;
        if (!answers || !validQuestionAnswers(questions, answers)) return false;
        respond = () => this.sdk.question.reply({ ...parameters, answers }, this.requestOptions());
      }
    }
    pending.responding = true;
    void respond().then(() => this.resolveAction(offered.id)).catch((error) => {
      if (this.pending.get(offered.id) !== pending || this.closed) return;
      pending.responding = false;
      this.emit("liveEvent", { type: "action_opened", action: offered });
      this.warning(offered.sessionId, "opencode_action_failed", formatError(error));
    });
    return true;
  }

  private async controls(directory: string, overrides: AgentSubmitInputRequest["overrides"]) {
    let model: OpenCodeModelRef | undefined;
    const agent = normalizeAgentName(overrides.mode) ?? undefined;
    if (overrides.model) {
      const providers = (await this.sdk.provider.list({ directory }, this.requestOptions())).data;
      // Model IDs can contain slashes. Match the catalog before considering variants.
      const offered = providers.all.flatMap((provider) => Object.values(provider.models).flatMap((item) =>
        [undefined, ...Object.keys(item.variants ?? {})].map((variant) => ({ providerID: provider.id, modelID: item.id, variant }))));
      model = offered.sort((a, b) => Number(Boolean(a.variant)) - Number(Boolean(b.variant)))
        .find((item) => encodeModelRef(item) === overrides.model?.trim());
      if (!model) throw new Error("OpenCode model or variant is not available");
    }
    if (agent) {
      const agents = (await this.sdk.app.agents({ directory }, this.requestOptions())).data;
      if (!agents.some((item) => item.name === agent && !item.hidden && item.mode !== "subagent")) throw new Error("OpenCode mode is not available");
    }
    return { agent, model: model ? { providerID: model.providerID, modelID: model.modelID } : undefined, variant: model?.variant };
  }

  private async readEvents(connected: () => void, failed: (error: unknown) => void): Promise<void> {
    let everConnected = false;
    let backoff = 250;
    while (!this.abort.signal.aborted) {
      try {
        const events = await this.sdk.global.event({ signal: this.abort.signal, sseMaxRetryAttempts: 1,
          onSseError: (error) => { if (!everConnected) failed(error); } });
        for await (const event of events.stream) {
          if (this.abort.signal.aborted) break;
          if (event.payload.type === "server.connected") {
            const reconnect = everConnected;
            everConnected = true;
            backoff = 250;
            connected();
            if (reconnect) {
              for (const id of this.loaded) this.invalidate(id);
              for (const id of [...this.active.keys()]) await this.finishTurn(id);
              for (const id of new Set([...this.loaded, ...[...this.pending.values()].map((item) => item.action.sessionId)])) {
                const info = await this.info(id);
                const [permissions, questions] = await Promise.all([
                  this.sdk.permission.list({ directory: info.directory }, this.requestOptions()),
                  this.sdk.question.list({ directory: info.directory }, this.requestOptions()),
                ]);
                this.syncActions(info, permissions.data, questions.data);
              }
            }
            continue;
          }
          await this.onEvent(event);
        }
      } catch (error) {
        if (!everConnected) failed(error);
        else if (!this.closed) this.warning(undefined, "opencode_event_error", formatError(error));
      }
      if (!this.abort.signal.aborted) {
        try { await sleep(backoff, undefined, { signal: this.abort.signal }); } catch { break; }
        backoff = Math.min(backoff * 2, 10_000);
      }
    }
  }
  private async onEvent(event: GlobalEvent): Promise<void> {
    const payload = event.payload;
    switch (payload.type) {
      case "session.created": case "session.updated": this.saveInfo(payload.properties.info); return;
      case "session.deleted": {
        const id = payload.properties.info.id;
        const turn = this.active.get(id);
        this.active.delete(id);
        this.loaded.delete(id);
        for (const [key, part] of this.parts) if (part.sessionId === id) this.parts.delete(key);
        for (const [key, pending] of this.pending) if (pending.action.sessionId === id) this.resolveAction(key);
        if (turn?.started) this.emit("liveEvent", { type: "turn_completed", sessionId: id, turnId: turn.id, status: "interrupted" });
        this.invalidate(id); return;
      }
      case "message.updated": {
        const message = payload.properties.info;
        if (message.role === "user") this.beginTurn(message.sessionID, message.id);
        if (message.role === "assistant" && message.time.completed != null) {
          const info = await this.info(message.sessionID, event.directory);
          const native = (await this.sdk.session.message({ sessionID: message.sessionID, messageID: message.id, directory: info.directory }, this.requestOptions())).data;
          const value = toSessionMessage(native);
          if (value.text || value.content.length || value.attachments.length) {
            this.saveItem(info.id, { kind: "message", value, nativeId: message.id, authority: "recovery" });
            this.emit("liveEvent", { type: "assistant_message_completed", sessionId: info.id, turnId: this.active.get(info.id)?.id, message: value });
          }
          for (const part of native.parts) this.emitActivity(info.id, part, message.parentID, message.time.created);
          for (const [key, part] of this.parts) if (part.messageId === message.id) this.parts.delete(key);
        }
        return;
      }
      case "message.part.updated": {
        const part = payload.properties.part;
        if (part.type === "text" || part.type === "reasoning") this.parts.set(part.id, { sessionId: part.sessionID, messageId: part.messageID, type: part.type });
        this.emitActivity(part.sessionID, part, this.active.get(part.sessionID)?.id ?? null, Date.now());
        return;
      }
      case "message.part.delta": {
        const delta = payload.properties;
        if (delta.field !== "text") return;
        let part = this.parts.get(delta.partID);
        if (!part) {
          const native = (await this.sdk.session.message({ sessionID: delta.sessionID, messageID: delta.messageID, directory: event.directory }, this.requestOptions())).data;
          const found = native.parts.find((item) => item.id === delta.partID);
          if (!found || (found.type !== "text" && found.type !== "reasoning")) return;
          part = { sessionId: delta.sessionID, messageId: delta.messageID, type: found.type };
          this.parts.set(delta.partID, part);
        }
        this.emit("liveEvent", part.type === "reasoning"
          ? { type: "reasoning_delta", sessionId: delta.sessionID, itemId: delta.messageID, reasoningId: delta.partID, turnId: this.active.get(delta.sessionID)?.id, delta: delta.delta, summary: false }
          : { type: "assistant_delta", sessionId: delta.sessionID, itemId: delta.messageID, turnId: this.active.get(delta.sessionID)?.id, delta: delta.delta });
        return;
      }
      case "permission.asked": case "question.asked": {
        const id = payload.properties.sessionID;
        const info = await this.info(id, event.directory);
        this.openAction(payload.type === "permission.asked" ? permissionToPendingAction(payload.properties, info.title, info.directory)
          : questionToPendingAction(payload.properties, info.title, info.directory));
        return;
      }
      case "permission.replied": this.resolveAction(`permission:${payload.properties.requestID}`); return;
      case "question.replied": case "question.rejected": this.resolveAction(`question:${payload.properties.requestID}`); return;
      case "session.status": {
        const { sessionID: id, status } = payload.properties;
        if (status.type === "idle") await this.finishTurn(id);
        else this.emit("liveEvent", { type: "thread_status_changed", sessionId: id, status: "running" });
        return;
      }
      case "session.idle": await this.finishTurn(payload.properties.sessionID); return;
      case "session.error": {
        const id = payload.properties.sessionID;
        const active = id ? this.active.get(id) : null;
        if (active) active.status = "failed";
        this.warning(id, "opencode_session_error", formatError(payload.properties.error));
        return;
      }
      case "todo.updated":
        this.emit("liveEvent", { type: "plan_updated", sessionId: payload.properties.sessionID,
          plan: payload.properties.todos.map((item): LivePlanStep => ({ step: item.content, status: item.status === "completed" ? "completed" : item.status === "in_progress" ? "in_progress" : "pending" })) }); return;
      case "session.diff": {
        const id = payload.properties.sessionID;
        const diff = payload.properties.diff.flatMap((file) => file.patch ? [file.patch] : []).join("\n");
        if (diff) {
          const value: SessionActivity = { id: `opencode-diff:${id}`, type: "turn_diff", turnId: this.active.get(id)?.id ?? null,
            diff, status: "completed", seq: 0, createdAt: Date.now() };
          if (this.db.getProviderSession(this.providerId, id)) this.saveItem(id, { kind: "activity", value, nativeId: null, authority: "recovery" });
          this.emit("liveEvent", { type: "activity_updated", sessionId: id, activity: value });
        }
        this.invalidate(id); return;
      }
      case "message.removed": case "message.part.removed": case "session.compacted":
        this.invalidate(payload.properties.sessionID); return;
      default: return;
    }
  }

  private beginTurn(id: string, turnId: string): void {
    if (this.closed) return;
    const current = this.active.get(id);
    if (current?.started) return;
    if (current) current.started = true;
    else this.active.set(id, { id: turnId, status: "completed", started: true, submitting: false });
    this.emit("liveEvent", { type: "turn_started", sessionId: id, turnId });
  }
  private async finishTurn(id: string): Promise<void> {
    const currentTurn = this.active.get(id);
    if (currentTurn?.submitting) return;
    const info = await this.info(id);
    const native = (await this.sdk.session.messages({ sessionID: id, directory: info.directory }, this.requestOptions())).data;
    const status = (await this.sdk.session.status({ directory: info.directory }, this.requestOptions())).data[id];
    if ((status && status.type !== "idle") || this.active.get(id) !== currentTurn) return;
    const snapshot = this.saveHistory(info, native);
    const active = this.active.get(id);
    if (active) {
      this.active.delete(id);
      this.emit("liveEvent", { type: "runtime_updated", sessionId: id, runtime: snapshot.runtime ?? null });
      if (active.started) this.emit("liveEvent", { type: "turn_completed", sessionId: id, turnId: active.id, status: active.status });
    }
    for (const [key, part] of this.parts) if (part.sessionId === id) this.parts.delete(key);
    this.emit("liveEvent", { type: "thread_status_changed", sessionId: id, status: "idle" });
    this.invalidate(id);
  }
  private emitActivity(id: string, part: OpenCodeMessagePart, turnId: string | null, createdAt: number): void {
    const value = materializeActivity(part, turnId, createdAt);
    if (!value) return;
    if (this.db.getProviderSession(this.providerId, id)) this.saveItem(id, { kind: "activity", value, nativeId: part.id, authority: "recovery" });
    this.emit("liveEvent", { type: "activity_updated", sessionId: id, turnId: this.active.get(id)?.id, activity: value });
  }
  private openAction(action: AgentPendingAction): void {
    if (this.pending.has(action.id)) return;
    this.pending.set(action.id, { action, responding: false });
    this.emit("liveEvent", { type: "action_opened", action });
  }
  private resolveAction(id: string): void {
    const item = this.pending.get(id);
    if (!item) return;
    this.pending.delete(id);
    this.emit("liveEvent", { type: "action_resolved", sessionId: item.action.sessionId, actionId: id });
  }
  private syncActions(info: OpenCodeSessionInfo, permissions: OpenCodePermissionRequest[], questions: OpenCodeQuestionRequest[]): void {
    const actions = [...permissions.filter((item) => item.sessionID === info.id).map((item) => permissionToPendingAction(item, info.title, info.directory)),
      ...questions.filter((item) => item.sessionID === info.id).map((item) => questionToPendingAction(item, info.title, info.directory))];
    const ids = new Set(actions.map((item) => item.id));
    for (const [id, pending] of this.pending) if (pending.action.sessionId === info.id && !ids.has(id)) this.resolveAction(id);
    for (const action of actions) this.openAction(action);
  }
  private async listNativeSessions(options: AgentSessionListOptions): Promise<OpenCodeSessionInfo[]> {
    const matches: OpenCodeSessionInfo[] = [];
    let cursor: number | undefined;
    const cursors = new Set<number>();
    while (matches.length < options.limit) {
      const page = await this.sdk.experimental.session.list({ archived: options.archived, limit: Math.max(50, options.limit), cursor }, this.requestOptions());
      for (const info of page.data) {
        this.saveInfo(info);
        if (Boolean(info.time.archived) === options.archived && (options.subAgentParentId ? info.parentID === options.subAgentParentId
          : options.includeSubAgents || !info.parentID)) matches.push(info);
      }
      const next = parseIntegerHeader(page.response.headers.get("x-next-cursor"));
      if (next == null || page.data.length === 0) break;
      if (cursors.has(next)) throw new Error("OpenCode session pagination did not advance");
      cursors.add(next);
      cursor = next;
    }
    return matches.slice(0, options.limit);
  }
  private async info(id: string, directory?: string): Promise<OpenCodeSessionInfo> {
    await this.start();
    const previous = this.db.getProviderSession(this.providerId, id);
    const native = (await this.sdk.session.get({ sessionID: id, directory: previous?.cwd || directory || this.directory }, this.requestOptions())).data;
    if (native.id !== id) throw new Error("OpenCode returned a different session identity");
    this.saveInfo(native);
    return native;
  }
  private saveInfo(info: OpenCodeSessionInfo): void {
    const previous = this.db.getProviderSession(this.providerId, info.id);
    this.db.saveProviderSession(this.providerId, { id: info.id, nativeId: info.id, cwd: info.directory, name: info.title,
      preview: previous?.preview || info.title, createdAt: info.time.created, updatedAt: info.time.updated,
      archived: Boolean(info.time.archived), metadata: { info, runtime: this.metadata(previous)?.runtime ?? buildSessionRuntime(info, []) } });
  }
  private saveItem(id: string, item: StoredSessionItem): void {
    const previous = this.db.getSessionItem(this.providerId, id, item.value.id);
    this.db.putSessionItem(this.providerId, id, { ...item, value: { ...item.value, seq: previous?.value.seq ?? this.db.nextSessionSequence(this.providerId, id), createdAt: previous?.value.createdAt ?? item.value.createdAt } } as StoredSessionItem);
  }
  private saveHistory(info: OpenCodeSessionInfo, native: OpenCodeMessage[]): SessionLogSnapshot {
    const snapshot = buildSessionLogSnapshot(native, info);
    const items: StoredSessionItem[] = [...snapshot.messages.map((value): StoredSessionItem => ({ kind: "message", value, nativeId: value.id, authority: "cache" })),
      ...snapshot.activities.map((value): StoredSessionItem => ({ kind: "activity", value, nativeId: value.id, authority: "cache" }))].sort((a, b) => a.value.seq - b.value.seq);
    const merged = reconcileSessionHistory(this.db.readSessionItems(this.providerId, info.id), items);
    const record = this.record(info.id);
    this.db.replaceProviderHistory(this.providerId, { ...record, preview: buildPreview(native, record.preview),
      metadata: { ...this.metadata(record), runtime: snapshot.runtime ?? null } }, merged);
    const messages = merged.flatMap((item) => item.kind === "message" ? [item.value] : []);
    const activities = merged.flatMap((item) => item.kind === "activity" ? [item.value] : []);
    return { ...snapshot, messages, activities, totalMessages: messages.length, totalActivities: activities.length,
      nextSeq: this.db.nextSessionSequence(this.providerId, info.id) };
  }
  private thread(info: OpenCodeSessionInfo, status: OpenCodeSessionStatus, includeTurns: boolean): ThreadRecord {
    return { id: info.id, cwd: info.directory, name: info.title, preview: this.db.getProviderSession(this.providerId, info.id)?.preview ?? info.title,
      createdAt: info.time.created / 1000, updatedAt: info.time.updated / 1000, source: "opencode", path: info.path ?? null,
      subAgent: subAgentInfoForOpenCodeSession(info), status: { type: status.type, phase: statusToLiveThreadStatus(status) },
      ...(includeTurns ? { turns: this.active.has(info.id) ? [{ id: this.active.get(info.id)!.id, status: "inProgress", startedAt: null, completedAt: null }] : [] } : {}) };
  }
  private requestOptions(timeout = 30_000) { return { throwOnError: true as const, signal: AbortSignal.any([this.abort.signal, AbortSignal.timeout(timeout)]) }; }
  private get sdk(): OpencodeClient { if (!this.client) throw new Error("OpenCode has not started"); return this.client; }
  private get db(): SessionStore { if (!this.store) throw new Error("OpenCode has not started"); return this.store; }
  private record(id: string): StoredProviderSession { const record = this.db.getProviderSession(this.providerId, id); if (!record) throw new Error("OpenCode session not found"); return record; }
  private metadata(record?: StoredProviderSession | null): OpenCodeMetadata { return (record?.metadata ?? {}) as OpenCodeMetadata; }
  private warning(sessionId: string | undefined, code: string, message: string): void {
    this.emit("liveEvent", { type: "provider_warning", sessionId, code, level: "warning", message, source: "opencode/sdk" });
  }
  private invalidate(sessionId: string): void { this.emit("liveEvent", { type: "history_invalidated", sessionId }); }
}

function validQuestionAnswers(questions: OpenCodeQuestionInfo[], answers: string[][]): boolean {
  return questions.length === answers.length && questions.every((question, index) => {
    const values = answers[index];
    return values && values.length > 0 && (question.multiple || values.length === 1)
      && (question.custom !== false || values.every((value) => question.options.some((option) => option.label === value)));
  });
}

export async function createOpenCodeServer(options: OpenCodeServerFactoryOptions): Promise<OpenCodeServerHandle> {
  const env: NodeJS.ProcessEnv = { ...process.env, OPENCODE_SERVER_USERNAME: "opencode", OPENCODE_SERVER_PASSWORD: randomUUID() };
  delete env.SIDEMESH_TOKEN;
  if (options.stateDir) {
    for (const [variable, name] of [["XDG_DATA_HOME", "data"], ["XDG_CONFIG_HOME", "config"], ["XDG_STATE_HOME", "state"], ["XDG_CACHE_HOME", "cache"]]) {
      env[variable!] = join(options.stateDir, name!);
      await mkdir(env[variable!]!, { recursive: true });
    }
  }
  options.signal?.throwIfAborted();
  const child = spawn(options.bin, ["serve", "--hostname", "127.0.0.1", "--port", "0"],
    { env, detached: process.platform !== "win32", stdio: "pipe" });
  let exited = false;
  let stopping = false;
  const done = new Promise<void>((resolve) => child.once("close", (code) => { exited = true; options.onExit(code); resolve(); }));
  const close = () => { if (!stopping) { stopping = true; if (!exited) terminatePipeProcess(child, () => exited); } return done; };
  const abort = () => { void close(); };
  options.signal?.addEventListener("abort", abort, { once: true });
  const stdout = createInterface({ input: child.stdout });
  const stderr = createInterface({ input: child.stderr });
  stderr.on("line", options.onOutput);
  try {
    const baseUrl = await new Promise<URL>((resolve, reject) => {
      let ready = false;
      const timeout = options.readyTimeoutMs ?? 30_000;
      const timer = setTimeout(() => reject(new Error(`OpenCode did not become ready within ${timeout}ms`)), timeout);
      child.once("error", reject);
      child.once("close", () => { clearTimeout(timer); if (!ready) reject(new Error("OpenCode exited before it became ready")); });
      stdout.on("line", (line) => {
        if (!ready && line.startsWith("opencode server listening on ")) {
          try {
            const url = new URL(line.slice("opencode server listening on ".length).trim());
            if (url.protocol !== "http:" || url.hostname !== "127.0.0.1") throw new Error("OpenCode returned an unexpected server address");
            ready = true; clearTimeout(timer); resolve(url);
          } catch (error) { clearTimeout(timer); reject(error); }
        } else if (line.trim()) options.onOutput(line);
      });
    });
    return { baseUrl, headers: { Authorization: `Basic ${Buffer.from(`opencode:${env.OPENCODE_SERVER_PASSWORD}`).toString("base64")}` },
      close: async () => { await close(); options.signal?.removeEventListener("abort", abort); stdout.close(); stderr.close(); } };
  } catch (error) { await close(); options.signal?.removeEventListener("abort", abort); stdout.close(); stderr.close(); throw error; }
}
function preparePromptInput(input: AgentSessionInputItem[]): {
  parts: OpenCodePromptPart[];
  warnings: string[];
} {
  const parts: OpenCodePromptPart[] = [];
  const warnings: string[] = [];
  const skillCommands: string[] = [];

  for (const item of input) {
    switch (item.type) {
      case "text":
        if (item.text.trim()) {
          parts.push({ type: "text", text: item.text });
        }
        break;
      case "skill":
        if (item.name.trim()) {
          skillCommands.push(`/${item.name.trim()}`);
        }
        break;
      case "file":
        if (!item.path.trim()) {
          continue;
        }
        if (item.isDirectory) {
          parts.push({
            type: "text",
            text: `Directory context: ${item.path}`,
          });
          break;
        }
        parts.push({
          type: "file",
          mime: mimeTypeFromPath(item.path),
          filename: basename(item.path),
          url: pathToFileURL(item.path).href,
          source: {
            type: "file",
            path: item.path,
            text: { start: 0, end: 0, value: "" },
          },
        });
        break;
      case "image":
        parts.push({
          type: "file",
          mime: mimeTypeFromRemoteUrl(item.url),
          filename: filenameFromUrl(item.url),
          url: item.url,
        });
        break;
      case "localImage":
        parts.push({
          type: "file",
          mime: mimeTypeFromPath(item.path),
          filename: basename(item.path),
          url: pathToFileURL(item.path).href,
          source: {
            type: "file",
            path: item.path,
            text: { start: 0, end: 0, value: "" },
          },
        });
        break;
      default:
        warnings.push("OpenCode provider ignored an unsupported input item.");
        break;
    }
  }

  if (skillCommands.length > 0) {
    parts.unshift({
      type: "text",
      text: skillCommands.join("\n"),
    });
  }
  if (parts.length === 0) {
    parts.push({ type: "text", text: "" });
  }
  return { parts, warnings };
}

function deriveSessionTitle(input: AgentSessionInputItem[]): string | null {
  const firstText = input.find(
    (item): item is Extract<AgentSessionInputItem, { type: "text" }> =>
      item.type === "text" && item.text.trim().length > 0,
  );
  if (!firstText) {
    return null;
  }
  const line = firstText.text.trim().replace(/\s+/g, " ");
  return line.length > 80 ? `${line.slice(0, 77)}...` : line;
}

function buildSessionLogSnapshot(
  messages: OpenCodeMessage[],
  session: OpenCodeSessionInfo,
): SessionLogSnapshot {
  const normalizedMessages = messages.map(toSessionMessage);
  const activities = messages.flatMap((message) => {
    const turnId =
      message.info.role === "assistant" ? message.info.parentID : null;
    return message.parts
      .map((part) =>
        materializeActivity(
          part,
          turnId,
          message.info.role === "assistant"
            ? message.info.time.completed ?? message.info.time.created
            : message.info.time.created,
        ),
      )
      .filter((activity): activity is SessionActivity => activity != null);
  });

  const timeline: Array<{
    key: string;
    createdAt: number;
    type: "message" | "activity";
  }> = [];
  for (const message of normalizedMessages) {
    timeline.push({
      key: message.id,
      createdAt: message.createdAt,
      type: "message",
    });
  }
  for (const activity of activities) {
    timeline.push({
      key: activity.id,
      createdAt: activity.createdAt,
      type: "activity",
    });
  }
  timeline.sort((left, right) => {
    if (left.createdAt !== right.createdAt) {
      return left.createdAt - right.createdAt;
    }
    if (left.type !== right.type) {
      return left.type === "activity" ? -1 : 1;
    }
    return left.key.localeCompare(right.key);
  });

  const messageSeq = new Map<string, number>();
  const activitySeq = new Map<string, number>();
  let seq = 1;
  for (const item of timeline) {
    if (item.type === "message") {
      messageSeq.set(item.key, seq++);
    } else {
      activitySeq.set(item.key, seq++);
    }
  }

  const sequencedMessages = normalizedMessages.map((message) => ({
    ...message,
    seq: messageSeq.get(message.id) ?? seq++,
  }));
  const sequencedActivities = activities.map((activity) => ({
    ...activity,
    seq: activitySeq.get(activity.id) ?? seq++,
  }));
  return {
    messages: sequencedMessages,
    activities: sequencedActivities.sort((left, right) => left.seq - right.seq),
    runtime: buildSessionRuntime(session, messages),
    totalMessages: sequencedMessages.length,
    totalActivities: sequencedActivities.length,
    nextSeq: seq,
  };
}

function buildTurns(
  messages: OpenCodeMessage[],
  sessionStatus: OpenCodeSessionStatus = { type: "idle" },
): TurnRecord[] {
  const assistantsByParent = new Map<string, OpenCodeAssistantMessageInfo[]>();
  for (const message of messages) {
    if (message.info.role !== "assistant") {
      continue;
    }
    const list = assistantsByParent.get(message.info.parentID);
    if (list) {
      list.push(message.info);
    } else {
      assistantsByParent.set(message.info.parentID, [message.info]);
    }
  }
  const userMessages = messages.filter(
    (message): message is OpenCodeMessage & { info: OpenCodeUserMessageInfo } =>
      message.info.role === "user",
  );
  const latestUserMessageId = userMessages.at(-1)?.info.id ?? null;
  return userMessages.map((message) => {
      const assistants = assistantsByParent.get(message.info.id) ?? [];
      const isLatestActiveTurn =
        latestUserMessageId === message.info.id && sessionStatus.type !== "idle";
      const hasIncompleteAssistant = assistants.some(
        (assistant) => assistant.error == null && assistant.time.completed == null,
      );
      const status = assistants.some((assistant) => assistant.error)
        ? "failed"
        : hasIncompleteAssistant
          ? sessionStatus.type === "idle"
            ? "interrupted"
            : "in_progress"
          : assistants.length === 0 && isLatestActiveTurn
            ? "in_progress"
            : "completed";
      const completedAt =
        status === "in_progress"
          ? null
          : assistants
              .map((assistant) => assistant.time.completed ?? assistant.time.created)
              .reduce<number | null>(
                (max, value) => (max == null || value > max ? value : max),
                null,
              );
      return {
        id: message.info.id,
        status,
        startedAt: message.info.time.created,
        completedAt,
      };
    });
}

function buildPreview(messages: OpenCodeMessage[], fallback: string): string {
  const candidate = messages
    .slice()
    .reverse()
    .map((message) => previewTextFromMessage(message))
    .find((text) => text.trim().length > 0);
  return candidate ?? fallback;
}

function previewTextFromMessage(message: OpenCodeMessage): string {
  const text = message.parts
    .filter((part): part is OpenCodeMessageTextPart | OpenCodeMessageReasoningPart => {
      return isTextPart(part) || isReasoningPart(part);
    })
    .map((part) => part.text.trim())
    .find(Boolean);
  if (text) {
    return text;
  }
  const file = message.parts.find(
    isFilePart,
  );
  if (file?.source && "path" in file.source) return file.source.path;
  return "";
}

function buildSessionRuntime(
  session: OpenCodeSessionInfo,
  messages: OpenCodeMessage[],
): SessionRuntimeSummary | null {
  const lastUser = messages
    .slice()
    .reverse()
    .find(
      (message): message is OpenCodeMessage & { info: OpenCodeUserMessageInfo } =>
        message.info.role === "user",
    );
  const lastAssistant = messages
    .slice()
    .reverse()
    .find(
      (message): message is OpenCodeMessage & { info: OpenCodeAssistantMessageInfo } =>
        message.info.role === "assistant",
    );
  const model = lastUser?.info.model ?? (session.model ? { providerID: session.model.providerID, modelID: session.model.id, variant: session.model.variant } : undefined);
  const mode = lastAssistant?.info.agent ?? lastUser?.info.agent ?? session.agent;
  if (!model && !mode && !lastAssistant) {
    return null;
  }
  return {
    ...(model ? { model: encodeModelRef(model), modelProvider: model.providerID } : {}),
    ...(mode ? { mode } : {}),
    ...(lastAssistant
      ? {
          telemetry: {
            lastUsage: {
              model: encodeModelRef({
                providerID: lastAssistant.info.providerID,
                modelID: lastAssistant.info.modelID,
              }),
              inputTokens: lastAssistant.info.tokens?.input,
              outputTokens: lastAssistant.info.tokens?.output,
              reasoningTokens: lastAssistant.info.tokens?.reasoning,
              cacheReadTokens: lastAssistant.info.tokens?.cache.read,
              cacheWriteTokens: lastAssistant.info.tokens?.cache.write,
              cost: lastAssistant.info.cost,
              durationMs:
                lastAssistant.info.time.completed != null
                  ? lastAssistant.info.time.completed -
                    lastAssistant.info.time.created
                  : undefined,
              updatedAt:
                lastAssistant.info.time.completed ??
                lastAssistant.info.time.created,
            },
          },
        }
      : {}),
    updatedAt: session.time.updated,
  };
}

function subAgentInfoForOpenCodeSession(
  session: OpenCodeSessionInfo,
): SessionSubAgentInfo | null {
  if (!session.parentID) {
    return null;
  }
  const agentName = session.agent?.trim() || null;
  return {
    parentSessionId: session.parentID,
    sourceKind: "child_session",
    agentName,
    agentDisplayName: agentName ? prettifyModeName(agentName) : null,
  };
}

function isTextPart(part: OpenCodeMessagePart): part is OpenCodeMessageTextPart {
  return part.type === "text" && typeof (part as { text?: unknown }).text === "string";
}

function isReasoningPart(
  part: OpenCodeMessagePart,
): part is OpenCodeMessageReasoningPart {
  return part.type === "reasoning" && typeof (part as { text?: unknown }).text === "string";
}

function isFilePart(part: OpenCodeMessagePart): part is OpenCodeMessageFilePart {
  return (
    part.type === "file" &&
    typeof (part as { mime?: unknown }).mime === "string" &&
    typeof (part as { url?: unknown }).url === "string"
  );
}

function isToolPart(part: OpenCodeMessagePart): part is OpenCodeMessageToolPart {
  return (
    part.type === "tool" &&
    typeof (part as { tool?: unknown }).tool === "string" &&
    typeof (part as { state?: unknown }).state === "object" &&
    (part as { state?: unknown }).state != null
  );
}

function isCompactionPart(
  part: OpenCodeMessagePart,
): part is OpenCodeMessageCompactionPart {
  return part.type === "compaction";
}

function toSessionMessage(message: OpenCodeMessage): SessionMessage {
  const content: SessionMessageContentBlock[] = [];
  for (const part of message.parts) {
    if (isTextPart(part)) {
      content.push({ type: "text", text: part.text });
      continue;
    }
    if (isReasoningPart(part)) {
      content.push({
        type: "thinking",
        thinking: part.text,
        summary: false,
        reasoningId: `${message.info.id}:reasoning`,
      });
    }
  }

  const text = content
    .filter((block): block is Extract<SessionMessageContentBlock, { type: "text" }> => block.type === "text")
    .map((block) => block.text)
    .join("\n")
    .trim();
  const attachments = message.parts
    .map(attachmentFromPart)
    .filter((attachment): attachment is SessionMessageAttachment => attachment != null);
  const errorText =
    message.info.role === "assistant"
      ? (typeof message.info.error?.data?.message === "string" ? message.info.error.data.message.trim() : "")
      : "";
  return {
    id: message.info.id,
    role: message.info.role,
    text: text || errorText,
    content,
    attachments,
    createdAt:
      message.info.role === "assistant"
        ? message.info.time.completed ?? message.info.time.created
        : message.info.time.created,
    seq: 0,
    ...(message.info.role === "assistant" ? { phase: "final_answer" as const } : {}),
  };
}

function attachmentFromPart(
  part: OpenCodeMessagePart,
): SessionMessageAttachment | null {
  if (!isFilePart(part)) {
    return null;
  }
  const sourcePath = part.source && "path" in part.source ? part.source.path : undefined;
  if (sourcePath) {
    return {
      type: part.mime.startsWith("image/") ? "localImage" : "file",
      path: sourcePath,
    };
  }
  return {
    type: part.mime.startsWith("image/") ? "image" : "file",
    url: part.url,
  };
}

function materializeActivity(
  part: OpenCodeMessagePart,
  turnId: string | null,
  fallbackCreatedAt: number,
): SessionActivity | null {
  const draft = activityFromOpenCodePart(part, turnId);
  if (!draft) {
    return null;
  }
  return materializeAgentActivityDraft(draft, { createdAt: activityCreatedAt(part, fallbackCreatedAt), seq: 0 });
}

function activityFromOpenCodePart(
  part: OpenCodeMessagePart,
  turnId: string | null,
): AgentSessionActivityDraft | null {
  if (isToolPart(part)) {
    return {
      id: part.id,
      type: "tool",
      turnId,
      status: toolStateToStatus(part.state.status),
      toolName: part.tool,
      title: toolStateTitle(part.state),
      args: part.state.input,
      output:
        part.state.status === "completed"
          ? part.state.output
          : part.state.status === "error"
            ? part.state.error
            : part.state.status === "running" && typeof part.state.metadata?.output === "string" ? part.state.metadata.output : null,
      result:
        part.state.status === "completed"
          ? { ...part.state.metadata, time: part.state.time }
          : part.state.status === "error"
            ? { ...(part.state.metadata ?? {}), error: part.state.error, time: part.state.time }
            : part.state.status === "running" ? part.state.metadata ?? null : null,
      ...(part.state.status === "completed" && part.state.attachments?.length
        ? { attachments: part.state.attachments.map(attachmentFromPart).filter((item): item is SessionMessageAttachment => item != null) } : {}),
      isError: part.state.status === "error" ? true : null,
      semantic: null,
    } satisfies AgentSessionActivityDraft;
  }
  if (isCompactionPart(part)) {
    return {
      id: part.id,
      type: "context_compaction",
      turnId,
      status: "completed",
    };
  }
  return null;
}

function activityCreatedAt(
  part: OpenCodeMessagePart,
  fallbackCreatedAt: number,
): number {
  if (isToolPart(part)) {
    if ("time" in part.state && typeof part.state.time.start === "number") {
      return part.state.time.start;
    }
  }
  return fallbackCreatedAt;
}

function toolStateToStatus(
  status: OpenCodeMessageToolState["status"],
): SessionActivity["status"] {
  switch (status) {
    case "pending":
    case "running":
      return "in_progress";
    case "completed":
      return "completed";
    case "error":
      return "failed";
  }
}

function toolStateTitle(state: OpenCodeMessageToolState): string | null {
  if (state.status === "running" || state.status === "completed") {
    return state.title ?? null;
  }
  return null;
}

function permissionToPendingAction(
  request: OpenCodePermissionRequest,
  sessionTitle: string,
  cwd: string,
): AgentPendingAction {
  const targets = buildPermissionTargets(request);
  const approval: PendingActionApproval = {
    category: "permissions",
    operation: request.permission,
    summary: request.patterns.join(", ") || request.permission,
    detail:
      Object.keys(request.metadata ?? {}).length > 0
        ? safeJsonStringify(request.metadata)
        : undefined,
    cwd,
    targets,
    supportedScopes: ["once", "session"],
    suggestedScope: "once",
    providerOptions: [
      { id: "once", label: "Allow once", kind: "allow_once" },
      {
        id: "always",
        label: "Allow matching requests",
        kind: "allow_always",
        description: "Remember the suggested patterns for this OpenCode session.",
      },
      { id: "reject", label: "Reject", kind: "reject_once" },
    ],
  };
  return {
    id: `permission:${request.id}`,
    sessionId: request.sessionID,
    sessionTitle,
    cwd,
    kind: "permissions",
    title: `Allow ${request.permission}`,
    detail: request.patterns.join(", ") || request.permission,
    requestedAt: Date.now(),
    canApprove: true,
    canApproveForSession: true,
    canDecline: true,
    approval,
    providerRequestId: request.id,
    providerRequestKind: "opencode/permission",
    providerPayload: request,
  };
}

function buildPermissionTargets(
  request: OpenCodePermissionRequest,
): PendingActionApprovalTarget[] {
  if (request.patterns.length === 0) {
    return [{ type: "unknown", label: request.permission }];
  }
  if (looksLikeFilesystemPermission(request.permission)) {
    const access = request.permission.includes("read") ? "read" : "write";
    return request.patterns.map((path) => ({
      type: "file",
      path,
      access,
    }));
  }
  return request.patterns.map((label) => ({
    type: "unknown",
    label,
  }));
}

function questionToPendingAction(
  request: OpenCodeQuestionRequest,
  sessionTitle: string,
  cwd: string,
): AgentPendingAction {
  if (request.questions.length === 1 && request.questions[0]?.multiple !== true) {
    const question = request.questions[0]!;
    return {
      id: `question:${request.id}`,
      sessionId: request.sessionID,
      sessionTitle,
      cwd,
      kind: "user_input",
      title: question.header || "OpenCode question",
      detail: question.question,
      requestedAt: Date.now(),
      canApprove: true,
      canApproveForSession: false,
      canDecline: true,
      userInput: {
        question: question.question,
        choices: question.options.map((option) => option.label),
        allowFreeform: question.custom !== false,
      },
      providerRequestId: request.id,
      providerRequestKind: "opencode/question:user-input",
      providerPayload: request,
    };
  }

  const fields: PendingActionElicitationField[] = request.questions.map(
    (question, index) => {
      const options = question.options.map((option) => ({
        value: option.label,
        label: option.label,
      }));
      if (question.multiple === true) {
        return {
          key: String(index),
          type: "string[]",
          title: question.header || `Question ${index + 1}`,
          description: question.question,
          required: true,
          options,
        };
      }
      return {
        key: String(index),
        type: "string",
        title: question.header || `Question ${index + 1}`,
        description: question.question,
        required: true,
        ...(options.length > 0 ? { options } : {}),
      };
    },
  );

  return {
    id: `question:${request.id}`,
    sessionId: request.sessionID,
    sessionTitle,
    cwd,
    kind: "elicitation",
    title: request.questions[0]?.header || "OpenCode questions",
    detail: request.questions.map((question) => question.question).join("\n"),
    requestedAt: Date.now(),
    canApprove: true,
    canApproveForSession: false,
    canDecline: true,
    elicitation: {
      mode: "form",
      message: request.questions.map((question) => question.question).join("\n"),
      fields,
    },
    providerRequestId: request.id,
    providerRequestKind: "opencode/question:elicitation",
    providerPayload: request,
  };
}

function buildQuestionAnswersFromElicitation(
  questions: OpenCodeQuestionInfo[],
  content: Record<string, unknown>,
): string[][] | null {
  const answers: string[][] = [];
  for (let index = 0; index < questions.length; index += 1) {
    const question = questions[index]!;
    const value = content[String(index)];
    if (value == null) {
      return null;
    }
    if (question.multiple === true) {
      if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
        return null;
      }
      answers.push([...value]);
      continue;
    }
    if (typeof value !== "string") {
      return null;
    }
    answers.push([value]);
  }
  return answers;
}

function buildModelSummary(
  providerName: string,
  model: OpenCodeProviderModel,
  ref: OpenCodeModelRef,
  options: {
    isDefault?: boolean;
  } = {},
): ModelSummary {
  const variant = normalizeVariantName(ref.variant);
  const variantSuffix = variant ? ` (${prettifyModeName(variant)})` : "";
  return {
    id: encodeModelRef(ref),
    model: encodeModelRef(ref),
    displayName: `${providerName} / ${model.name}${variantSuffix}`,
    description: buildModelDescription(providerName, model, variant),
    defaultReasoningEffort: "medium",
    supportedReasoningEfforts:
      model.capabilities?.reasoning === true
        ? [...REASONING_EFFORTS]
        : [],
    reasoningEffortControl: "provider",
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: buildInputModalities(model),
    isDefault: options.isDefault ?? false,
    sortOrder: variant ? 100 : 0,
    source: ref.providerID,
  };
}

function buildModelDescription(
  providerName: string,
  model: OpenCodeProviderModel,
  variant?: string | null,
): string {
  const capabilities: string[] = [];
  if (model.capabilities?.reasoning) {
    capabilities.push("reasoning");
  }
  if (model.capabilities?.input?.image) {
    capabilities.push("image input");
  }
  const detail = capabilities.length > 0
    ? `${providerName} model with ${capabilities.join(", ")}`
    : `${providerName} model`;
  if (!variant) {
    return detail;
  }
  return `${detail}. Variant: ${prettifyModeName(variant)}.`;
}

function buildInputModalities(model: OpenCodeProviderModel): string[] {
  const result = ["text"];
  if (model.capabilities?.input?.image) {
    result.push("image");
  }
  if (model.capabilities?.input?.pdf) {
    result.push("pdf");
  }
  if (model.capabilities?.input?.audio) {
    result.push("audio");
  }
  if (model.capabilities?.input?.video) {
    result.push("video");
  }
  return result;
}

function inferSkillScope(cwd: string, location: string): string {
  if (location.startsWith(cwd)) {
    return "repo";
  }
  if (location.includes("/.agents/")) {
    return "repo";
  }
  if (location.includes("/.opencode/") || location.includes("/opencode/skill")) {
    return "system";
  }
  return "user";
}

function normalizeAgentName(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function encodeModelRef(model: OpenCodeModelRef): string {
  return model.variant
    ? `${model.providerID}/${model.modelID}/${model.variant}`
    : `${model.providerID}/${model.modelID}`;
}

function statusToLiveThreadStatus(status: OpenCodeSessionStatus): LiveThreadStatus {
  switch (status.type) {
    case "idle":
      return "idle";
    case "busy":
    case "retry":
      return "running";
  }
}

function looksLikeFilesystemPermission(permission: string): boolean {
  return (
    permission.includes("read") ||
    permission.includes("edit") ||
    permission.includes("write") ||
    permission.includes("delete") ||
    permission.includes("directory") ||
    permission.includes("file")
  );
}

function normalizeVariantName(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function prettifyModeName(value: string): string {
  const generic = value.trim();
  if (!generic) {
    return value;
  }
  const builtin = GENERIC_MODE_LABELS[generic];
  if (builtin) {
    return builtin;
  }
  return generic
    .split(/[-_]+/g)
    .filter(Boolean)
    .map((part) => part[0]!.toUpperCase() + part.slice(1))
    .join(" ");
}

function filenameFromUrl(value: string): string | undefined {
  const dataUrlMime = mimeTypeFromDataUrl(value);
  if (dataUrlMime) {
    return `image${extensionForMimeType(dataUrlMime)}`;
  }
  try {
    const parsed = new URL(value);
    const name = basename(parsed.pathname);
    return name || undefined;
  } catch {
    return undefined;
  }
}

function mimeTypeFromRemoteUrl(value: string): string {
  const dataUrlMime = mimeTypeFromDataUrl(value);
  if (dataUrlMime) {
    return dataUrlMime;
  }
  const filename = filenameFromUrl(value);
  if (filename) {
    const inferred = mimeTypeFromPath(filename);
    if (inferred !== "application/octet-stream") {
      return inferred;
    }
  }
  return "image/*";
}

function mimeTypeFromDataUrl(value: string): string | null {
  const match = /^data:([^;,]+)[;,]/i.exec(value);
  return match?.[1]?.trim() || null;
}

function mimeTypeFromPath(path: string): string {
  switch (extname(path).toLowerCase()) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    case ".bmp":
      return "image/bmp";
    case ".svg":
      return "image/svg+xml";
    case ".ts":
    case ".tsx":
    case ".js":
    case ".jsx":
    case ".mjs":
    case ".cjs":
    case ".json":
    case ".md":
    case ".txt":
    case ".yaml":
    case ".yml":
    case ".dart":
    case ".sh":
    case ".py":
    case ".go":
    case ".rs":
    case ".java":
    case ".kt":
    case ".swift":
    case ".rb":
    case ".php":
    case ".html":
    case ".css":
    case ".scss":
      return "text/plain";
    default:
      return "application/octet-stream";
  }
}

function extensionForMimeType(mime: string): string {
  switch (mime.toLowerCase()) {
    case "image/png":
      return ".png";
    case "image/jpeg":
      return ".jpg";
    case "image/gif":
      return ".gif";
    case "image/webp":
      return ".webp";
    case "image/bmp":
      return ".bmp";
    case "image/svg+xml":
      return ".svg";
    default:
      return "";
  }
}

function safeJsonStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function parseIntegerHeader(value: string | null): number | null {
  if (!value) {
    return null;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (limit == null || limit < 0 || items.length <= limit) {
    return items;
  }
  return items.slice(-limit);
}

function formatError(error: unknown): string {
  if (error && typeof error === "object") {
    if ("message" in error && typeof error.message === "string") return error.message;
    if ("data" in error && error.data && typeof error.data === "object" && "message" in error.data && typeof error.data.message === "string") return error.data.message;
    if ("name" in error && typeof error.name === "string") return error.name;
  }
  return typeof error === "string" ? error : "OpenCode request failed";
}
