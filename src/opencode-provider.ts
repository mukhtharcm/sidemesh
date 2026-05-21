import {
  spawn,
  type ChildProcessByStdio,
} from "node:child_process";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { mkdir } from "node:fs/promises";
import { basename, extname } from "node:path";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
import { pathToFileURL } from "node:url";

import type {
  AgentCreateSessionRequest,
  AgentCreateSessionResult,
  AgentModelListOptions,
  AgentModeListOptions,
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
  AgentSkillListOptions,
} from "./agent-provider.js";
import {
  normalizePendingActionDecision,
  parsePendingActionElicitationResponse,
  parsePendingActionUserInputResponse,
  type PendingActionResponseInput,
} from "./approvals.js";
import type {
  LiveThreadStatus,
  ModelSummary,
  PendingActionApproval,
  PendingActionApprovalTarget,
  PendingActionElicitationField,
  ProviderModeCatalog,
  SessionActivity,
  SessionLogSnapshot,
  SessionMessage,
  SessionMessageAttachment,
  SessionMessageContentBlock,
  SessionSubAgentInfo,
  SessionRuntimeSummary,
  SkillCatalogEntry,
  SkillSummary,
  ThreadRecord,
  TurnRecord,
  ToolActivity,
} from "./types.js";

const DEFAULT_REQUEST_TIMEOUT_MS = 30_000;
const DEFAULT_POLL_INTERVAL_MS = 500;
const DEFAULT_SERVER_READY_TIMEOUT_MS = 30_000;
const READY_LINE_PREFIX = "opencode server listening on ";

interface OpenCodeModelRef {
  providerID: string;
  modelID: string;
  variant?: string;
}

interface OpenCodeSessionInfo {
  id: string;
  directory: string;
  path?: string;
  parentID?: string;
  title: string;
  agent?: string;
  model?: OpenCodeModelRef;
  time: {
    created: number;
    updated: number;
    archived?: number;
  };
}

type OpenCodeSessionStatus =
  | { type: "idle" }
  | { type: "busy" }
  | { type: "retry"; attempt: number; message: string; next: number };

interface OpenCodeMessageTextPart {
  id: string;
  type: "text";
  text: string;
  time?: { start?: number; end?: number };
}

interface OpenCodeMessageReasoningPart {
  id: string;
  type: "reasoning";
  text: string;
  time?: { start?: number; end?: number };
}

interface OpenCodeMessageFilePart {
  id: string;
  type: "file";
  mime: string;
  filename?: string;
  url: string;
  source?: {
    type?: string;
    path?: string;
  };
}

interface OpenCodeMessageToolStatePending {
  status: "pending";
  input: Record<string, unknown>;
  raw?: string;
}

interface OpenCodeMessageToolStateRunning {
  status: "running";
  input: Record<string, unknown>;
  title?: string;
  metadata?: Record<string, unknown>;
  time: { start: number };
}

interface OpenCodeMessageToolStateCompleted {
  status: "completed";
  input: Record<string, unknown>;
  output: string;
  title: string;
  metadata: Record<string, unknown>;
  time: { start: number; end: number };
}

interface OpenCodeMessageToolStateError {
  status: "error";
  input: Record<string, unknown>;
  error: string;
  metadata?: Record<string, unknown>;
  time: { start: number; end: number };
}

type OpenCodeMessageToolState =
  | OpenCodeMessageToolStatePending
  | OpenCodeMessageToolStateRunning
  | OpenCodeMessageToolStateCompleted
  | OpenCodeMessageToolStateError;

interface OpenCodeMessageToolPart {
  id: string;
  type: "tool";
  tool: string;
  callID: string;
  state: OpenCodeMessageToolState;
  metadata?: Record<string, unknown>;
}

interface OpenCodeMessageCompactionPart {
  id: string;
  type: "compaction";
}

type OpenCodeMessagePart =
  | OpenCodeMessageTextPart
  | OpenCodeMessageReasoningPart
  | OpenCodeMessageFilePart
  | OpenCodeMessageToolPart
  | OpenCodeMessageCompactionPart
  | { id: string; type: string; [key: string]: unknown };

type OpenCodeChildProcess = ChildProcessByStdio<null, Readable, Readable>;

interface OpenCodeUserMessageInfo {
  id: string;
  sessionID: string;
  role: "user";
  time: { created: number };
  agent: string;
  model: OpenCodeModelRef & { variant?: string };
}

interface OpenCodeAssistantMessageInfo {
  id: string;
  sessionID: string;
  role: "assistant";
  parentID: string;
  providerID: string;
  modelID: string;
  agent: string;
  mode: string;
  time: { created: number; completed?: number };
  cost: number;
  finish?: string;
  error?: { name?: string; data?: { message?: string } };
  tokens?: {
    total?: number;
    input: number;
    output: number;
    reasoning: number;
    cache: { read: number; write: number };
  };
}

type OpenCodeMessageInfo =
  | OpenCodeUserMessageInfo
  | OpenCodeAssistantMessageInfo;

interface OpenCodeMessage {
  info: OpenCodeMessageInfo;
  parts: OpenCodeMessagePart[];
}

interface OpenCodePromptPartText {
  type: "text";
  text: string;
}

interface OpenCodePromptPartFile {
  type: "file";
  mime: string;
  filename?: string;
  url: string;
  source?: {
    type?: "file";
    path?: string;
    text?: { start: number; end: number; value: string };
  };
}

type OpenCodePromptPart = OpenCodePromptPartText | OpenCodePromptPartFile;

type OpenCodeHeaders = Record<string, string>;

interface OpenCodePromptInput {
  agent?: string;
  model?: OpenCodeModelRef;
  variant?: string;
  parts: OpenCodePromptPart[];
}

interface OpenCodePermissionRequest {
  id: string;
  sessionID: string;
  permission: string;
  patterns: string[];
  metadata: Record<string, unknown>;
  always?: string[];
}

interface OpenCodeQuestionOption {
  label: string;
  description: string;
}

interface OpenCodeQuestionInfo {
  question: string;
  header: string;
  options: OpenCodeQuestionOption[];
  multiple?: boolean;
  custom?: boolean;
}

interface OpenCodeQuestionRequest {
  id: string;
  sessionID: string;
  questions: OpenCodeQuestionInfo[];
}

interface OpenCodeProviderModel {
  id: string;
  name: string;
  providerID: string;
  variants?: Record<string, Record<string, unknown>>;
  capabilities?: {
    reasoning?: boolean;
    input?: {
      text?: boolean;
      image?: boolean;
      pdf?: boolean;
      audio?: boolean;
      video?: boolean;
    };
  };
}

interface OpenCodeProviderInfo {
  id: string;
  name: string;
  models: Record<string, OpenCodeProviderModel>;
}

interface OpenCodeProviderListResult {
  all: OpenCodeProviderInfo[];
  default: Record<string, string>;
  connected: string[];
}

interface OpenCodeAgentInfo {
  name: string;
  mode: "primary" | "subagent" | "all";
  hidden?: boolean;
}

interface OpenCodeSkillInfo {
  name: string;
  description: string;
  location: string;
}

interface OpenCodeGlobalSessionPage {
  sessions: OpenCodeSessionInfo[];
  nextCursor: number | null;
}

interface OpenCodeClient {
  getHealth(directory: string): Promise<{ healthy: true; version: string }>;
  listGlobalSessions(options: {
    directory: string;
    archived: boolean;
    limit: number;
    cursor?: number | null;
  }): Promise<OpenCodeGlobalSessionPage>;
  getSession(options: {
    directory: string;
    sessionID: string;
  }): Promise<OpenCodeSessionInfo>;
  getSessionStatuses(
    directory: string,
  ): Promise<Record<string, OpenCodeSessionStatus>>;
  listMessages(options: {
    directory: string;
    sessionID: string;
  }): Promise<OpenCodeMessage[]>;
  createSession(options: {
    directory: string;
    title?: string | null;
    agent?: string | null;
    model?: OpenCodeModelRef | null;
  }): Promise<OpenCodeSessionInfo>;
  setSessionName(options: {
    directory: string;
    sessionID: string;
    title: string;
  }): Promise<OpenCodeSessionInfo>;
  promptAsync(options: {
    directory: string;
    sessionID: string;
    input: OpenCodePromptInput;
  }): Promise<void>;
  abortSession(options: {
    directory: string;
    sessionID: string;
  }): Promise<boolean>;
  listPermissions(directory: string): Promise<OpenCodePermissionRequest[]>;
  replyPermission(options: {
    directory: string;
    requestID: string;
    reply: "once" | "always" | "reject";
  }): Promise<boolean>;
  listQuestions(directory: string): Promise<OpenCodeQuestionRequest[]>;
  replyQuestion(options: {
    directory: string;
    requestID: string;
    answers: string[][];
  }): Promise<boolean>;
  rejectQuestion(options: {
    directory: string;
    requestID: string;
  }): Promise<boolean>;
  listProviders(directory: string): Promise<OpenCodeProviderListResult>;
  listAgents(directory: string): Promise<OpenCodeAgentInfo[]>;
  listSkills(directory: string): Promise<OpenCodeSkillInfo[]>;
}

interface OpenCodeServerHandle {
  baseUrl: URL;
  close(): Promise<void>;
}

export interface OpenCodeServerFactoryOptions {
  bin: string;
  stateDir: string | null;
  readyTimeoutMs?: number;
  onOutput(line: string): void;
  onExit(code: number | null): void;
}

export type OpenCodeServerFactory = (
  options: OpenCodeServerFactoryOptions,
) => Promise<OpenCodeServerHandle>;

export interface OpenCodeClientFactoryOptions {
  baseUrl: URL;
  defaultDirectory: string;
}

export type OpenCodeClientFactory = (
  options: OpenCodeClientFactoryOptions,
) => OpenCodeClient;

interface ActiveOpenCodeTurn {
  sessionId: string;
  cwd: string;
  turnId: string;
  baselineMessageIds: Set<string>;
  assistantMessageId: string | null;
  emittedAssistantText: string;
  emittedReasoningText: string;
  emittedActivityFingerprints: Map<string, string>;
  lastStatus: LiveThreadStatus | null;
  aborted: boolean;
}

interface OpenCodeSessionCache {
  info: OpenCodeSessionInfo;
  preview: string;
  runtime: SessionRuntimeSummary | null;
  pendingActions: Map<string, AgentPendingAction>;
}

export interface OpenCodeAgentProviderOptions {
  bin?: string;
  stateDir?: string | null;
  defaultDirectory?: string | null;
  pollIntervalMs?: number;
  serverFactory?: OpenCodeServerFactory;
  clientFactory?: OpenCodeClientFactory;
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
    archive: false,
    compact: false,
    interrupt: true,
    history: true,
    eventReplay: false,
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

export class OpenCodeAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  public readonly kind = "opencode";
  public readonly displayName = "OpenCode";
  public readonly capabilities = OPENCODE_PROVIDER_CAPABILITIES;

  private readonly bin: string;
  private readonly stateDir: string | null;
  private readonly defaultDirectory: string;
  private readonly pollIntervalMs: number;
  private readonly serverFactory: OpenCodeServerFactory;
  private readonly clientFactory: OpenCodeClientFactory;
  private readonly usesDefaultClientFactory: boolean;
  private readonly sessionCache = new Map<string, OpenCodeSessionCache>();
  private readonly loadedSessionIds = new Set<string>();
  private readonly activeTurns = new Map<string, ActiveOpenCodeTurn>();

  private server: OpenCodeServerHandle | null = null;
  private client: OpenCodeClient | null = null;
  private startPromise: Promise<void> | null = null;

  public constructor(options: OpenCodeAgentProviderOptions = {}) {
    super();
    this.bin = options.bin?.trim() || "opencode";
    this.stateDir = options.stateDir?.trim() || null;
    this.defaultDirectory = options.defaultDirectory?.trim() || process.cwd();
    this.pollIntervalMs = Math.max(50, options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS);
    this.serverFactory = options.serverFactory ?? createOpenCodeServer;
    this.clientFactory = options.clientFactory ?? createOpenCodeClient;
    this.usesDefaultClientFactory = options.clientFactory == null;
  }

  public async start(): Promise<void> {
    if (this.client) {
      return;
    }
    if (this.startPromise) {
      return this.startPromise;
    }
    this.startPromise = this.startInternal();
    try {
      await this.startPromise;
    } catch (error) {
      await this.close().catch(() => undefined);
      throw error;
    } finally {
      this.startPromise = null;
    }
  }

  public async close(): Promise<void> {
    this.activeTurns.clear();
    this.client = null;
    const server = this.server;
    this.server = null;
    if (server) {
      await server.close();
    }
  }

  public async restart(): Promise<void> {
    await this.close();
    await this.start();
  }

  public async health(): Promise<boolean> {
    try {
      await this.start();
      const health = await this.requireClient().getHealth(this.defaultDirectory);
      return health.healthy === true;
    } catch {
      return false;
    }
  }

  public async getVersion(): Promise<string> {
    await this.start();
    const health = await this.requireClient().getHealth(this.defaultDirectory);
    return `OpenCode ${health.version}`;
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    await this.start();
    const sessions = await this.listAllSessions(options.limit, options.archived);
    const statusesByDirectory = await this.loadStatusesForDirectories(
      sessions.map((session) => session.directory),
    );
    return sessions
      .map((session) =>
        this.threadFromSession(
          session,
          statusesByDirectory.get(session.directory)?.[session.id] ?? { type: "idle" },
          false,
        ),
      )
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, options.limit)
      .map(cloneThreadRecord);
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    return this.listSessionThreads({ limit, archived: false });
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    await this.start();
    const info = await this.ensureSessionInfo(threadId);
    const status =
      (await this.requireClient().getSessionStatuses(info.directory))[threadId] ??
      { type: "idle" as const };
    if (!includeTurns) {
      return cloneThreadRecord(this.threadFromSession(info, status, false));
    }
    const messages = await this.requireClient().listMessages({
      directory: info.directory,
      sessionID: threadId,
    });
    const turns = buildTurns(messages, status);
    const thread = this.threadFromSession(info, status, true);
    thread.turns = turns;
    this.cacheSession(threadId, info, messages);
    return cloneThreadRecord(thread);
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    await this.start();
    const info = await this.ensureSessionInfo(thread.id, thread.cwd);
    const messages = await this.requireClient().listMessages({
      directory: info.directory,
      sessionID: info.id,
    });
    const snapshot = buildSessionLogSnapshot(messages, info);
    this.cacheSession(thread.id, info, messages, snapshot.runtime);
    const limitedMessages = limitTail(snapshot.messages, options.messageLimit ?? null);
    const limitedActivities = limitTail(
      snapshot.activities,
      options.activityLimit ?? null,
    );
    return {
      messages: limitedMessages.map(cloneMessage),
      activities: limitedActivities.map(cloneActivity),
      runtime: snapshot.runtime ? { ...snapshot.runtime } : null,
      totalMessages: snapshot.messages.length,
      totalActivities: snapshot.activities.length,
      nextSeq: snapshot.nextSeq,
    };
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    await this.start();
    const info = await this.ensureSessionInfo(thread.id, thread.cwd);
    const messages = await this.requireClient().listMessages({
      directory: info.directory,
      sessionID: info.id,
    });
    const runtime = buildSessionRuntime(info, messages);
    this.cacheSession(thread.id, info, messages, runtime);
    return runtime ? { ...runtime } : null;
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    return [...this.loadedSessionIds];
  }

  public async resumeSessionThread(
    threadId: string,
    _options?: AgentSessionResumeOptions,
  ): Promise<unknown> {
    await this.start();
    const info = await this.ensureSessionInfo(threadId);
    this.loadedSessionIds.add(threadId);
    this.touchCache(info);
    return { resumed: true };
  }

  public async setSessionName(threadId: string, name: string): Promise<unknown> {
    await this.start();
    const info = await this.ensureSessionInfo(threadId);
    const updated = await this.requireClient().setSessionName({
      directory: info.directory,
      sessionID: threadId,
      title: name,
    });
    this.touchCache(updated);
    return { renamed: true };
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    await this.start();
    const model = parseModelRef(request.overrides.model);
    const agent = normalizeAgentName(request.overrides.mode);
    const created = await this.requireClient().createSession({
      directory: request.cwd,
      title: deriveSessionTitle(request.input),
      agent,
    });
    const sessionInfo =
      model == null
        ? created
        : {
            ...created,
            model,
          };
    this.loadedSessionIds.add(created.id);
    this.touchCache(sessionInfo);
    let activeTurnId: string | null = null;
    let runtime = buildSessionRuntime(sessionInfo, []);
    if (request.input.length > 0) {
      const started = await this.startPromptTurn({
        sessionId: created.id,
        cwd: request.cwd,
        input: request.input,
        overrides: request.overrides,
        mode: "turn",
      });
      activeTurnId = started.turnId;
      runtime = {
        ...(runtime ?? {}),
        turnId: started.turnId,
        updatedAt: Date.now(),
      };
      this.updateRuntimeCache(created.id, runtime);
    }
    return {
      thread: this.threadFromSession(sessionInfo, { type: "idle" }, false),
      activeTurnId,
      runtime,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    await this.start();
    const info = await this.ensureSessionInfo(request.sessionId);
    const mode = request.activeTurnId ? "steer" : "turn";
    if (request.activeTurnId) {
      await this.interruptTurn(request.sessionId, request.activeTurnId).catch(
        () => undefined,
      );
    }
    return this.startPromptTurn({
      sessionId: request.sessionId,
      cwd: info.directory,
      input: request.input,
      overrides: request.overrides,
      mode,
    });
  }

  public async interruptTurn(
    threadId: string,
    turnId: string,
  ): Promise<unknown> {
    await this.start();
    const info = await this.ensureSessionInfo(threadId);
    const active = this.activeTurns.get(threadId);
    if (active && active.turnId === turnId) {
      active.aborted = true;
    }
    await this.requireClient().abortSession({
      directory: info.directory,
      sessionID: threadId,
    });
    return { interrupted: true };
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean {
    const cache = this.sessionCache.get(action.sessionId);
    const existing = cache?.pendingActions.get(action.id);
    if (!existing) {
      return false;
    }
    if (action.providerRequestKind === "opencode/permission") {
      const normalized = normalizePendingActionDecision(decision as any);
      if (!normalized) {
        return false;
      }
      const reply =
        normalized.decision === "approve"
          ? normalized.scope === "location"
            ? "always"
            : "once"
          : "reject";
      cache?.pendingActions.delete(action.id);
      void this.respondToPermission(existing, reply);
      return true;
    }

    if (action.providerRequestKind === "opencode/question:user-input") {
      const parsed = parsePendingActionUserInputResponse(decision);
      if (!parsed) {
        return false;
      }
      cache?.pendingActions.delete(action.id);
      void this.respondToQuestion(existing, [[parsed.answer]]);
      return true;
    }

    if (action.providerRequestKind === "opencode/question:elicitation") {
      const parsed = parsePendingActionElicitationResponse(decision);
      if (!parsed) {
        return false;
      }
      if (parsed.action === "decline" || parsed.action === "cancel") {
        cache?.pendingActions.delete(action.id);
        void this.rejectQuestion(existing);
        return true;
      }
      const payload = existing.providerPayload;
      if (!payload || typeof payload !== "object") {
        return false;
      }
      const question = payload as { questions?: OpenCodeQuestionInfo[] };
      const answers = buildQuestionAnswersFromElicitation(
        question.questions ?? [],
        parsed.content ?? {},
      );
      if (!answers) {
        return false;
      }
      cache?.pendingActions.delete(action.id);
      void this.respondToQuestion(existing, answers);
      return true;
    }

    return false;
  }

  public async listModels(options: AgentModelListOptions): Promise<ModelSummary[]> {
    await this.start();
    const result = await this.requireClient().listProviders(
      options.cwd ?? this.defaultDirectory,
    );
    const providerFilter = options.provider?.trim() || null;
    const models: ModelSummary[] = [];
    for (const provider of result.all) {
      for (const model of Object.values(provider.models)) {
        const providerId = model.providerID || provider.id;
        if (providerFilter && providerId !== providerFilter) {
          continue;
        }
        models.push(
          buildModelSummary(provider.name, model, {
            providerID: providerId,
            modelID: model.id,
          }, {
            isDefault: result.default[provider.id] === model.id,
          }),
        );
        for (const variant of Object.keys(model.variants ?? {})) {
          models.push(
            buildModelSummary(provider.name, model, {
              providerID: providerId,
              modelID: model.id,
              variant,
            }),
          );
        }
      }
    }
    models.sort((left, right) => {
      if (left.isDefault !== right.isDefault) {
        return left.isDefault ? -1 : 1;
      }
      return left.displayName.localeCompare(right.displayName);
    });
    return models;
  }

  public async listModes(options: AgentModeListOptions): Promise<ProviderModeCatalog> {
    await this.start();
    const agents = await this.requireClient().listAgents(
      options.cwd ?? this.defaultDirectory,
    );
    return {
      defaultMode: null,
      modes: agents
        .filter((agent) => agent.hidden !== true && agent.mode !== "subagent")
        .map((agent) => ({
          id: agent.name,
          label: prettifyModeName(agent.name),
        }))
        .sort((left, right) => left.label.localeCompare(right.label)),
    };
  }

  public async listSkills(options: AgentSkillListOptions): Promise<SkillCatalogEntry> {
    await this.start();
    const skills = await this.requireClient().listSkills(options.cwd);
    return {
      cwd: options.cwd,
      skills: skills.map((skill): SkillSummary => ({
        name: skill.name,
        description: skill.description,
        path: skill.location,
        scope: inferSkillScope(options.cwd, skill.location),
        enabled: true,
      })),
      errors: [],
    };
  }

  private async startInternal(): Promise<void> {
    if (this.stateDir) {
      await mkdir(this.stateDir, { recursive: true });
    }
    const server = await this.serverFactory({
      bin: this.bin,
      stateDir: this.stateDir,
      onOutput: (line) => this.emit("stderr", `${line}\n`),
      onExit: (code) => this.emit("exit", code),
    });
    this.server = server;
    const resolvedBaseUrl = this.usesDefaultClientFactory
      ? await resolveOpenCodeApiBaseUrl(server.baseUrl)
      : server.baseUrl;
    this.client = this.clientFactory({
      baseUrl: resolvedBaseUrl,
      defaultDirectory: this.defaultDirectory,
    });
  }

  private requireClient(): OpenCodeClient {
    if (!this.client) {
      throw new Error("OpenCode provider has not been started.");
    }
    return this.client;
  }

  private async startPromptTurn(input: {
    sessionId: string;
    cwd: string;
    input: AgentSessionInputItem[];
    overrides: AgentSubmitInputRequest["overrides"];
    mode: "turn" | "steer";
  }): Promise<{ mode: "turn" | "steer"; turnId: string }> {
    const prepared = preparePromptInput(input.input);
    const promptInput: OpenCodePromptInput = {
      parts: prepared.parts,
    };
    const agent = normalizeAgentName(input.overrides.mode);
    if (agent) {
      promptInput.agent = agent;
    }
    const model = parseModelRef(input.overrides.model);
    if (model) {
      promptInput.model = {
        providerID: model.providerID,
        modelID: model.modelID,
      };
      if (model.variant) {
        promptInput.variant = model.variant;
      }
    }

    const baseline = await this.requireClient().listMessages({
      directory: input.cwd,
      sessionID: input.sessionId,
    });
    const turnId = randomUUID();
    const turn: ActiveOpenCodeTurn = {
      sessionId: input.sessionId,
      cwd: input.cwd,
      turnId,
      baselineMessageIds: new Set(baseline.map((message) => message.info.id)),
      assistantMessageId: null,
      emittedAssistantText: "",
      emittedReasoningText: "",
      emittedActivityFingerprints: new Map(),
      lastStatus: null,
      aborted: false,
    };

    if (prepared.warnings.length > 0) {
      for (const warning of prepared.warnings) {
        this.emit("liveEvent", {
          type: "provider_warning",
          sessionId: input.sessionId,
          level: "warning",
          message: warning,
          source: "opencode/input",
        });
      }
    }

    await this.requireClient().promptAsync({
      directory: input.cwd,
      sessionID: input.sessionId,
      input: promptInput,
    });
    this.activeTurns.set(input.sessionId, turn);
    this.loadedSessionIds.add(input.sessionId);
    this.emit("liveEvent", {
      type: "turn_started",
      sessionId: input.sessionId,
      turnId,
    });
    this.emitThreadStatusIfChanged(turn, "running");
    void this.monitorTurn(turn);
    return { mode: input.mode, turnId };
  }

  private async monitorTurn(turn: ActiveOpenCodeTurn): Promise<void> {
    try {
      while (this.activeTurns.get(turn.sessionId) === turn) {
        const [messages, statuses, permissions, questions] = await Promise.all([
          this.requireClient().listMessages({
            directory: turn.cwd,
            sessionID: turn.sessionId,
          }),
          this.requireClient().getSessionStatuses(turn.cwd),
          this.requireClient().listPermissions(turn.cwd),
          this.requireClient().listQuestions(turn.cwd),
        ]);

        const sessionInfo = await this.ensureSessionInfo(turn.sessionId, turn.cwd);
        this.cacheSession(turn.sessionId, sessionInfo, messages);

        const status = statuses[turn.sessionId] ?? { type: "idle" as const };
        const pendingKind = this.emitPendingActions(turn, permissions, questions);
        if (pendingKind === "permissions") {
          this.emitThreadStatusIfChanged(turn, "waiting_for_approval");
        } else if (pendingKind) {
          this.emitThreadStatusIfChanged(turn, "waiting_for_input");
        } else {
          this.emitThreadStatusIfChanged(turn, statusToLiveThreadStatus(status));
        }

        const userMessage = findLastItem(
          messages,
          (
            message,
          ): message is OpenCodeMessage & { info: OpenCodeUserMessageInfo } =>
            message.info.role === "user" &&
            !turn.baselineMessageIds.has(message.info.id),
        );
        const assistantMessage =
          userMessage == null
            ? undefined
            : findLastItem(
                messages,
                (
                  message,
                ): message is OpenCodeMessage & {
                  info: OpenCodeAssistantMessageInfo;
                } =>
                  message.info.role === "assistant" &&
                  message.info.parentID === userMessage.info.id,
              );
        if (assistantMessage && assistantMessage.info.role === "assistant") {
          turn.assistantMessageId = assistantMessage.info.id;
          this.emitAssistantDeltas(turn, assistantMessage);
          this.emitActivityDeltas(turn, assistantMessage);
          if (assistantMessage.info.time.completed) {
            const runtime = buildSessionRuntime(sessionInfo, messages);
            const completedMessage = toSessionMessage(assistantMessage);
            this.emit("liveEvent", {
              type: "assistant_message_completed",
              sessionId: turn.sessionId,
              turnId: turn.turnId,
              message: {
                id: completedMessage.id,
                text: completedMessage.text,
                content: completedMessage.content,
                phase: completedMessage.phase,
              },
            });
            this.emit("liveEvent", {
              type: "runtime_updated",
              sessionId: turn.sessionId,
              runtime,
            });
            this.updateRuntimeCache(turn.sessionId, runtime);
            this.emitThreadStatusIfChanged(
              turn,
              assistantMessage.info.error ? "errored" : "idle",
            );
            this.emit("liveEvent", {
              type: "turn_completed",
              sessionId: turn.sessionId,
              turnId: turn.turnId,
              status: assistantMessage.info.error ? "failed" : "completed",
            });
            this.activeTurns.delete(turn.sessionId);
            return;
          }
        }

        if (turn.aborted && status.type === "idle") {
          this.emitThreadStatusIfChanged(turn, "idle");
          this.emit("liveEvent", {
            type: "turn_completed",
            sessionId: turn.sessionId,
            turnId: turn.turnId,
            status: "cancelled",
          });
          this.activeTurns.delete(turn.sessionId);
          return;
        }

        await delay(this.pollIntervalMs);
      }
    } catch (error) {
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId: turn.sessionId,
        level: "error",
        message: formatError(error),
        source: "opencode/monitor",
      });
      this.emitThreadStatusIfChanged(turn, "errored");
      this.emit("liveEvent", {
        type: "turn_completed",
        sessionId: turn.sessionId,
        turnId: turn.turnId,
        status: "failed",
      });
      this.activeTurns.delete(turn.sessionId);
    }
  }

  private emitAssistantDeltas(
    turn: ActiveOpenCodeTurn,
    message: OpenCodeMessage,
  ): void {
    const reasoningText = message.parts
      .filter(isReasoningPart)
      .map((part) => part.text)
      .join("");
    if (reasoningText.length > turn.emittedReasoningText.length) {
      const delta = reasoningText.slice(turn.emittedReasoningText.length);
      turn.emittedReasoningText = reasoningText;
      if (delta) {
        this.emit("liveEvent", {
          type: "reasoning_delta",
          sessionId: turn.sessionId,
          turnId: turn.turnId,
          itemId: message.info.id,
          reasoningId: `${message.info.id}:reasoning`,
          delta,
          summary: false,
        });
      }
    }

    const text = message.parts
      .filter(isTextPart)
      .map((part) => part.text)
      .join("");
    if (text.length > turn.emittedAssistantText.length) {
      const delta = text.slice(turn.emittedAssistantText.length);
      turn.emittedAssistantText = text;
      if (delta) {
        this.emit("liveEvent", {
          type: "assistant_delta",
          sessionId: turn.sessionId,
          turnId: turn.turnId,
          itemId: message.info.id,
          delta,
        });
      }
    }
  }

  private emitActivityDeltas(
    turn: ActiveOpenCodeTurn,
    message: OpenCodeMessage,
  ): void {
    for (const part of message.parts) {
      const activity = activityFromOpenCodePart(part, turn.turnId);
      if (!activity) {
        continue;
      }
      const fingerprint = JSON.stringify(activity);
      if (turn.emittedActivityFingerprints.get(activity.id) === fingerprint) {
        continue;
      }
      turn.emittedActivityFingerprints.set(activity.id, fingerprint);
      this.emit("liveEvent", {
        type: "activity_updated",
        sessionId: turn.sessionId,
        turnId: turn.turnId,
        activity,
      });
    }
  }

  private emitPendingActions(
    turn: ActiveOpenCodeTurn,
    permissions: OpenCodePermissionRequest[],
    questions: OpenCodeQuestionRequest[],
  ): "permissions" | "user_input" | "elicitation" | null {
    const cache = this.sessionCache.get(turn.sessionId);
    let pendingKind: "permissions" | "user_input" | "elicitation" | null = null;

    for (const permission of permissions) {
      if (permission.sessionID !== turn.sessionId) {
        continue;
      }
      const action = permissionToPendingAction(
        permission,
        cache?.info.title ?? "OpenCode session",
        cache?.info.directory ?? turn.cwd,
      );
      if (!cache?.pendingActions.has(action.id)) {
        cache?.pendingActions.set(action.id, action);
        this.emit("liveEvent", { type: "action_opened", action });
      }
      pendingKind = "permissions";
    }

    for (const question of questions) {
      if (question.sessionID !== turn.sessionId) {
        continue;
      }
      const action = questionToPendingAction(
        question,
        cache?.info.title ?? "OpenCode session",
        cache?.info.directory ?? turn.cwd,
      );
      if (!cache?.pendingActions.has(action.id)) {
        cache?.pendingActions.set(action.id, action);
        this.emit("liveEvent", { type: "action_opened", action });
      }
      if (action.kind === "user_input" || action.kind === "elicitation") {
        pendingKind = action.kind;
      }
    }

    return pendingKind;
  }

  private emitThreadStatusIfChanged(
    turn: ActiveOpenCodeTurn,
    status: LiveThreadStatus,
  ): void {
    if (turn.lastStatus === status) {
      return;
    }
    turn.lastStatus = status;
    this.emit("liveEvent", {
      type: "thread_status_changed",
      sessionId: turn.sessionId,
      status,
    });
  }

  private async listAllSessions(
    limit: number,
    archived: boolean,
  ): Promise<OpenCodeSessionInfo[]> {
    const sessions: OpenCodeSessionInfo[] = [];
    let cursor: number | null = null;
    while (sessions.length < limit) {
      const page = await this.requireClient().listGlobalSessions({
        directory: this.defaultDirectory,
        archived,
        limit: Math.max(limit, 50),
        cursor,
      });
      sessions.push(...page.sessions);
      if (page.nextCursor == null || page.sessions.length === 0) {
        break;
      }
      cursor = page.nextCursor;
    }
    for (const session of sessions) {
      this.touchCache(session);
    }
    return sessions
      .filter((session) => archived === Boolean(session.time.archived))
      .slice(0, limit);
  }

  private async loadStatusesForDirectories(
    directories: string[],
  ): Promise<Map<string, Record<string, OpenCodeSessionStatus>>> {
    const result = new Map<string, Record<string, OpenCodeSessionStatus>>();
    const unique = [...new Set(directories.filter(Boolean))];
    await Promise.all(
      unique.map(async (directory) => {
        try {
          result.set(directory, await this.requireClient().getSessionStatuses(directory));
        } catch {
          result.set(directory, {});
        }
      }),
    );
    return result;
  }

  private async ensureSessionInfo(
    sessionId: string,
    cwd?: string | null,
  ): Promise<OpenCodeSessionInfo> {
    const cached = this.sessionCache.get(sessionId)?.info;
    if (cached) {
      return cached;
    }
    if (cwd) {
      const info = await this.requireClient().getSession({
        directory: cwd,
        sessionID: sessionId,
      });
      this.touchCache(info);
      return info;
    }

    const match =
      (await this.findSessionInfoById(sessionId, false)) ??
      (await this.findSessionInfoById(sessionId, true));
    if (!match) {
      throw new Error(`OpenCode session "${sessionId}" was not found.`);
    }
    this.touchCache(match);
    return match;
  }

  private async findSessionInfoById(
    sessionId: string,
    archived: boolean,
  ): Promise<OpenCodeSessionInfo | null> {
    let cursor: number | null = null;
    while (true) {
      const page = await this.requireClient().listGlobalSessions({
        directory: this.defaultDirectory,
        archived,
        limit: 200,
        cursor,
      });
      for (const session of page.sessions) {
        this.touchCache(session);
        if (session.id === sessionId) {
          return session;
        }
      }
      if (page.nextCursor == null || page.sessions.length === 0) {
        return null;
      }
      cursor = page.nextCursor;
    }
  }

  private threadFromSession(
    session: OpenCodeSessionInfo,
    status: OpenCodeSessionStatus,
    includeTurns: boolean,
  ): ThreadRecord {
    const cached = this.sessionCache.get(session.id);
    const preview = cached?.preview?.trim() || session.title;
    const activeFlags: string[] = [];
    if (status.type === "busy") {
      activeFlags.push("busy");
    }
    if (status.type === "retry") {
      activeFlags.push("retry");
    }
    return {
      id: session.id,
      name: session.title,
      preview,
      createdAt: session.time.created,
      updatedAt: session.time.updated,
      cwd: session.directory,
      source: "opencode",
      subAgent: subAgentInfoForOpenCodeSession(session),
      path: session.path ?? null,
      status: {
        type: status.type,
        phase: statusToLiveThreadStatus(status),
        ...(activeFlags.length > 0 ? { activeFlags } : {}),
      },
      ...(includeTurns ? { turns: [] } : {}),
    };
  }

  private touchCache(info: OpenCodeSessionInfo): void {
    const existing = this.sessionCache.get(info.id);
    this.sessionCache.set(info.id, {
      info,
      preview: existing?.preview ?? info.title,
      runtime: existing?.runtime ?? buildSessionRuntime(info, []),
      pendingActions: existing?.pendingActions ?? new Map(),
    });
  }

  private cacheSession(
    sessionId: string,
    info: OpenCodeSessionInfo,
    messages: OpenCodeMessage[],
    runtime?: SessionRuntimeSummary | null,
  ): void {
    const existing = this.sessionCache.get(sessionId);
    this.sessionCache.set(sessionId, {
      info,
      preview: buildPreview(messages, info.title),
      runtime: runtime ?? buildSessionRuntime(info, messages),
      pendingActions: existing?.pendingActions ?? new Map(),
    });
  }

  private updateRuntimeCache(
    sessionId: string,
    runtime: SessionRuntimeSummary | null,
  ): void {
    const existing = this.sessionCache.get(sessionId);
    if (!existing) {
      return;
    }
    this.sessionCache.set(sessionId, {
      ...existing,
      runtime,
    });
  }

  private async respondToPermission(
    action: AgentPendingAction,
    reply: "once" | "always" | "reject",
  ): Promise<void> {
    try {
      const info = await this.ensureSessionInfo(action.sessionId);
      await this.requireClient().replyPermission({
        directory: info.directory,
        requestID: String(action.providerRequestId),
        reply,
      });
    } catch (error) {
      this.reopenPendingAction(action);
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId: action.sessionId,
        level: "error",
        message: formatError(error),
        source: "opencode/permission",
      });
    }
  }

  private async respondToQuestion(
    action: AgentPendingAction,
    answers: string[][],
  ): Promise<void> {
    try {
      const info = await this.ensureSessionInfo(action.sessionId);
      await this.requireClient().replyQuestion({
        directory: info.directory,
        requestID: String(action.providerRequestId),
        answers,
      });
    } catch (error) {
      this.reopenPendingAction(action);
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId: action.sessionId,
        level: "error",
        message: formatError(error),
        source: "opencode/question",
      });
    }
  }

  private async rejectQuestion(action: AgentPendingAction): Promise<void> {
    try {
      const info = await this.ensureSessionInfo(action.sessionId);
      await this.requireClient().rejectQuestion({
        directory: info.directory,
        requestID: String(action.providerRequestId),
      });
    } catch (error) {
      this.reopenPendingAction(action);
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId: action.sessionId,
        level: "error",
        message: formatError(error),
        source: "opencode/question",
      });
    }
  }

  private reopenPendingAction(action: AgentPendingAction): void {
    const cache = this.sessionCache.get(action.sessionId);
    if (!cache || cache.pendingActions.has(action.id)) {
      return;
    }
    cache.pendingActions.set(action.id, action);
    this.emit("liveEvent", { type: "action_opened", action });
  }
}

class HttpOpenCodeClient implements OpenCodeClient {
  public constructor(
    private readonly baseUrl: URL,
    private readonly defaultDirectory: string,
  ) {}

  public getHealth(directory: string): Promise<{ healthy: true; version: string }> {
    return this.requestJson("/global/health", { directory });
  }

  public async listGlobalSessions(options: {
    directory: string;
    archived: boolean;
    limit: number;
    cursor?: number | null;
  }): Promise<OpenCodeGlobalSessionPage> {
    const url = this.buildUrl("/experimental/session");
    url.searchParams.set("archived", options.archived ? "true" : "false");
    url.searchParams.set("limit", String(options.limit));
    if (options.cursor != null) {
      url.searchParams.set("cursor", String(options.cursor));
    }
    const response = await this.request(url, {
      headers: this.headers(options.directory),
    });
    const sessions = (await response.json()) as OpenCodeSessionInfo[];
    return {
      sessions,
      nextCursor: parseIntegerHeader(response.headers.get("x-next-cursor")),
    };
  }

  public getSession(options: {
    directory: string;
    sessionID: string;
  }): Promise<OpenCodeSessionInfo> {
    return this.requestJson(`/session/${encodeURIComponent(options.sessionID)}`, {
      directory: options.directory,
    });
  }

  public getSessionStatuses(
    directory: string,
  ): Promise<Record<string, OpenCodeSessionStatus>> {
    return this.requestJson("/session/status", { directory });
  }

  public listMessages(options: {
    directory: string;
    sessionID: string;
  }): Promise<OpenCodeMessage[]> {
    return this.requestJson(
      `/session/${encodeURIComponent(options.sessionID)}/message`,
      { directory: options.directory },
    );
  }

  public createSession(options: {
    directory: string;
    title?: string | null;
    agent?: string | null;
    model?: OpenCodeModelRef | null;
  }): Promise<OpenCodeSessionInfo> {
    return this.requestJson("/session", {
      method: "POST",
      directory: options.directory,
      body: {
        ...(options.title ? { title: options.title } : {}),
        ...(options.agent ? { agent: options.agent } : {}),
        ...(options.model ? { model: options.model } : {}),
      },
    });
  }

  public setSessionName(options: {
    directory: string;
    sessionID: string;
    title: string;
  }): Promise<OpenCodeSessionInfo> {
    return this.requestJson(`/session/${encodeURIComponent(options.sessionID)}`, {
      method: "PATCH",
      directory: options.directory,
      body: { title: options.title },
    });
  }

  public async promptAsync(options: {
    directory: string;
    sessionID: string;
    input: OpenCodePromptInput;
  }): Promise<void> {
    const response = await this.request(
      this.buildUrl(`/session/${encodeURIComponent(options.sessionID)}/prompt_async`),
      {
        method: "POST",
        headers: this.jsonHeaders(options.directory),
        body: JSON.stringify(options.input),
      },
    );
    if (response.status !== 204) {
      throw new Error(`OpenCode prompt_async returned ${response.status}`);
    }
  }

  public async abortSession(options: {
    directory: string;
    sessionID: string;
  }): Promise<boolean> {
    const result = await this.requestJson<boolean>(
      `/session/${encodeURIComponent(options.sessionID)}/abort`,
      {
        method: "POST",
        directory: options.directory,
      },
    );
    return result === true;
  }

  public listPermissions(directory: string): Promise<OpenCodePermissionRequest[]> {
    return this.requestJson("/permission", { directory });
  }

  public replyPermission(options: {
    directory: string;
    requestID: string;
    reply: "once" | "always" | "reject";
  }): Promise<boolean> {
    return this.requestJson(
      `/permission/${encodeURIComponent(options.requestID)}/reply`,
      {
        method: "POST",
        directory: options.directory,
        body: { reply: options.reply },
      },
    );
  }

  public listQuestions(directory: string): Promise<OpenCodeQuestionRequest[]> {
    return this.requestJson("/question", { directory });
  }

  public replyQuestion(options: {
    directory: string;
    requestID: string;
    answers: string[][];
  }): Promise<boolean> {
    return this.requestJson(`/question/${encodeURIComponent(options.requestID)}/reply`, {
      method: "POST",
      directory: options.directory,
      body: { answers: options.answers },
    });
  }

  public rejectQuestion(options: {
    directory: string;
    requestID: string;
  }): Promise<boolean> {
    return this.requestJson(`/question/${encodeURIComponent(options.requestID)}/reject`, {
      method: "POST",
      directory: options.directory,
    });
  }

  public listProviders(directory: string): Promise<OpenCodeProviderListResult> {
    return this.requestJson("/provider", { directory });
  }

  public listAgents(directory: string): Promise<OpenCodeAgentInfo[]> {
    return this.requestJson("/agent", { directory });
  }

  public listSkills(directory: string): Promise<OpenCodeSkillInfo[]> {
    return this.requestJson("/skill", { directory });
  }

  private async requestJson<T>(
    path: string,
    options: {
      method?: string;
      directory?: string | null;
      body?: unknown;
    } = {},
  ): Promise<T> {
    const response = await this.request(this.buildUrl(path), {
      method: options.method ?? (options.body === undefined ? "GET" : "POST"),
      headers:
        options.body === undefined
          ? this.headers(options.directory)
          : this.jsonHeaders(options.directory),
      ...(options.body === undefined
        ? {}
        : { body: JSON.stringify(options.body) }),
    });
    return (await response.json()) as T;
  }

  private async request(url: URL, init: RequestInit): Promise<Response> {
    const response = await fetch(url, {
      ...init,
      signal: AbortSignal.timeout(DEFAULT_REQUEST_TIMEOUT_MS),
    });
    if (response.ok) {
      return response;
    }

    let message = `${response.status} ${response.statusText}`;
    try {
      const text = await response.text();
      if (text.trim()) {
        message = `${message}: ${text.trim()}`;
      }
    } catch {
      // Ignore body parsing failures.
    }
    throw new Error(`OpenCode request failed for ${url.pathname}: ${message}`);
  }

  private buildUrl(path: string): URL {
    return resolveOpenCodeUrl(this.baseUrl, path);
  }

  private headers(directory?: string | null): OpenCodeHeaders {
    return {
      "x-opencode-directory": directory?.trim() || this.defaultDirectory,
    };
  }

  private jsonHeaders(directory?: string | null): OpenCodeHeaders {
    return {
      ...this.headers(directory),
      "content-type": "application/json",
    };
  }
}

export function createOpenCodeClient(
  options: OpenCodeClientFactoryOptions,
): OpenCodeClient {
  return new HttpOpenCodeClient(options.baseUrl, options.defaultDirectory);
}

async function resolveOpenCodeApiBaseUrl(baseUrl: URL): Promise<URL> {
  for (const candidate of [baseUrl, resolveOpenCodeUrl(baseUrl, "/api/")]) {
    try {
      const response = await fetch(resolveOpenCodeUrl(candidate, "/global/health"), {
        signal: AbortSignal.timeout(DEFAULT_REQUEST_TIMEOUT_MS),
      });
      if (response.ok) {
        return candidate;
      }
    } catch {
      // Try the next candidate.
    }
  }
  throw new Error(
    "OpenCode server did not expose a supported headless HTTP API at /global/health or /api/global/health. The installed OpenCode build may be too old for the Sidemesh provider.",
  );
}

export async function createOpenCodeServer(
  options: OpenCodeServerFactoryOptions,
): Promise<OpenCodeServerHandle> {
  if (options.stateDir) {
    await mkdir(options.stateDir, { recursive: true });
    await mkdir(`${options.stateDir}/data`, { recursive: true });
    await mkdir(`${options.stateDir}/config`, { recursive: true });
    await mkdir(`${options.stateDir}/state`, { recursive: true });
    await mkdir(`${options.stateDir}/cache`, { recursive: true });
  }

  const child: OpenCodeChildProcess = spawn(
    options.bin,
    ["serve", "--hostname", "127.0.0.1", "--port", "0"],
    {
      detached: process.platform !== "win32",
      env: {
        ...process.env,
        ...(options.stateDir
          ? {
              XDG_DATA_HOME: `${options.stateDir}/data`,
              XDG_CONFIG_HOME: `${options.stateDir}/config`,
              XDG_STATE_HOME: `${options.stateDir}/state`,
              XDG_CACHE_HOME: `${options.stateDir}/cache`,
            }
          : {}),
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );

  const baseUrl = await waitForOpenCodeReady(child, options);
  let closed = false;
  return {
    baseUrl,
    async close() {
      if (closed) {
        return;
      }
      closed = true;
      await terminateChild(child);
    },
  };
}

async function waitForOpenCodeReady(
  child: OpenCodeChildProcess,
  options: OpenCodeServerFactoryOptions,
): Promise<URL> {
  return new Promise<URL>((resolve, reject) => {
    let settled = false;
    const readyTimeoutMs = options.readyTimeoutMs ?? DEFAULT_SERVER_READY_TIMEOUT_MS;
    const stdout = createInterface({ input: child.stdout });
    const stderr = createInterface({ input: child.stderr });
    const readyTimer = setTimeout(() => {
      finish(() => {
        void terminateChild(child).catch(() => undefined);
        reject(new Error(`OpenCode did not become ready within ${readyTimeoutMs}ms.`));
      });
    }, readyTimeoutMs);

    const finish = (fn: () => void) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(readyTimer);
      stdout.close();
      stderr.close();
      fn();
    };

    const onLine = (line: string) => {
      if (line.startsWith(READY_LINE_PREFIX)) {
        const raw = line.slice(READY_LINE_PREFIX.length).trim();
        finish(() => resolve(new URL(raw)));
        return;
      }
      if (line.trim()) {
        options.onOutput(line);
      }
    };

    stdout.on("line", onLine);
    stderr.on("line", (line) => {
      if (line.trim()) {
        options.onOutput(line);
      }
    });
    child.once("error", (error) => {
      finish(() => reject(error));
    });
    child.once("exit", (code) => {
      options.onExit(code);
      finish(() =>
        reject(
          new Error(
            `OpenCode exited before it became ready (code ${code ?? "unknown"}).`,
          ),
        ),
      );
    });
  });
}

async function terminateChild(
  child: OpenCodeChildProcess,
): Promise<void> {
  if (child.exitCode != null) {
    return;
  }
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      signalChild(child, "SIGKILL");
    }, 5_000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
    signalChild(child, "SIGTERM");
  });
}

function signalChild(
  child: OpenCodeChildProcess,
  signal: NodeJS.Signals,
): void {
  const pid = child.pid;
  if (!pid) {
    return;
  }
  if (process.platform !== "win32") {
    try {
      process.kill(-pid, signal);
      return;
    } catch {
      // Fall back to the direct child signal below.
    }
  }
  child.kill(signal);
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
  if (file?.source?.path) {
    return file.source.path;
  }
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
  const model = lastUser?.info.model ?? session.model;
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
      ? message.info.error?.data?.message?.trim() ?? ""
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
  const sourcePath = part.source?.path;
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
  return {
    ...draft,
    createdAt: activityCreatedAt(part, fallbackCreatedAt),
    seq: 0,
  } as SessionActivity;
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
            : null,
      result:
        part.state.status === "completed"
          ? { ...part.state.metadata, time: part.state.time }
          : part.state.status === "error"
            ? { ...(part.state.metadata ?? {}), error: part.state.error, time: part.state.time }
            : null,
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
    supportedScopes: ["once", "location"],
    suggestedScope: "once",
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
    canApproveForSession: false,
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

function parseModelRef(value: string | null | undefined): OpenCodeModelRef | null {
  const trimmed = value?.trim();
  if (!trimmed) {
    return null;
  }
  const parts = trimmed.split("/");
  if (parts.length < 2) {
    return null;
  }
  const [providerID, modelID, ...variantParts] = parts;
  if (!providerID || !modelID) {
    return null;
  }
  const variant = normalizeVariantName(variantParts.join("/"));
  return {
    providerID,
    modelID,
    ...(variant ? { variant } : {}),
  };
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

function resolveOpenCodeUrl(baseUrl: URL, path: string): URL {
  const resolved = new URL(baseUrl.href);
  const basePath = resolved.pathname.endsWith("/")
    ? resolved.pathname
    : `${resolved.pathname}/`;
  const normalizedPath = path.startsWith("/") ? path.slice(1) : path;
  resolved.pathname = `${basePath}${normalizedPath}`.replace(/\/{2,}/g, "/");
  resolved.search = "";
  resolved.hash = "";
  return resolved;
}

function cloneThreadRecord(thread: ThreadRecord): ThreadRecord {
  return JSON.parse(JSON.stringify(thread)) as ThreadRecord;
}

function cloneMessage(message: SessionMessage): SessionMessage {
  return JSON.parse(JSON.stringify(message)) as SessionMessage;
}

function cloneActivity(activity: SessionActivity): SessionActivity {
  return JSON.parse(JSON.stringify(activity)) as SessionActivity;
}

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (limit == null || limit < 0 || items.length <= limit) {
    return items;
  }
  return items.slice(-limit);
}

function formatError(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function findLastItem<T, S extends T>(
  items: readonly T[],
  predicate: (item: T, index: number, array: readonly T[]) => item is S,
): S | undefined;
function findLastItem<T>(
  items: readonly T[],
  predicate: (item: T, index: number, array: readonly T[]) => boolean,
): T | undefined;
function findLastItem<T>(
  items: readonly T[],
  predicate: (item: T, index: number, array: readonly T[]) => boolean,
): T | undefined {
  for (let index = items.length - 1; index >= 0; index -= 1) {
    const item = items[index]!;
    if (predicate(item, index, items)) {
      return item;
    }
  }
  return undefined;
}
