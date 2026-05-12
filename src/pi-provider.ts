import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { constants as fsConstants } from "node:fs";
import { access, mkdir, open, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import nodePath from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import {
  SessionManager,
  VERSION as PI_VERSION,
  createAgentSessionFromServices,
  createAgentSessionServices,
  type AgentSession,
  type AgentSessionEvent,
  type AgentSessionServices,
  type ResourceDiagnostic,
  type Skill as PiSkill,
} from "@mariozechner/pi-coding-agent";

import { mergeActivity, normalizeStoredSessionActivity } from "./activity.js";
import {
  materializeAgentActivityDraft,
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
  type AgentModelListOptions,
  type AgentProvider,
  type AgentProviderCapabilities,
  type AgentProviderEvents,
  type AgentSessionActivityDraft,
  type AgentSessionInputItem,
  type AgentSessionListOptions,
  type AgentSessionLogOptions,
  type AgentSessionResumeOptions,
  type AgentSubmitInputRequest,
  type AgentSubmitInputResult,
  type AgentSkillListOptions,
} from "./agent-provider.js";
import type {
  ModelSummary,
  SessionActivity,
  SessionActivityChange,
  SessionLogSnapshot,
  SessionMessage,
  SessionMessageAttachment,
  SessionRuntimeSummary,
  SkillCatalogEntry,
  SkillSummary,
  ThreadRecord,
  ToolActivity,
  ToolActivitySemantic,
  ToolActivitySemanticTarget,
  TurnRecord,
  SessionMessageContentBlock,
  SessionMessageContentBlockText,
} from "./types.js";
import { textToBlocks } from "./types.js";

type PiThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

interface PiImageInput {
  type: "image";
  data: string;
  mimeType: string;
}

interface PiModelLike {
  id: string;
  name: string;
  provider: string;
  reasoning: boolean;
  input: string[];
  contextWindow?: number;
}

interface PiSessionSummary {
  id: string;
  path: string;
  cwd: string;
  name: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
}

interface PiPreparedInput {
  text: string;
  preview: string;
  attachments: SessionMessageAttachment[];
  images: PiImageInput[];
  warnings: string[];
}

interface PiSessionState {
  thread: ThreadRecord;
  messages: SessionMessage[];
  activities: Map<string, SessionActivity>;
  turns: TurnRecord[];
  runtime: SessionRuntimeSummary | null;
  historyFingerprint: string | null;
  archived: boolean;
  nextSeq: number;
  draftAssistantMessage?: PiDraftAssistantMessage | null;
  session?: AgentSession | null;
  services?: AgentSessionServices | null;
  sessionManager?: SessionManager | null;
  unsubscribe?: (() => void) | null;
  pendingCompactionActivityId?: string | null;
  preservedSidecarMessages?: PiPreservedSidecarMessage[];
  preservedSidecarUserMessages?: PiPreservedSidecarUserMessage[];
}

interface ActivePiTurn {
  turnId: string;
  status: string | null;
}

interface PiDraftAssistantMessage {
  id: string;
  turnId: string;
  text: string;
  content: SessionMessageContentBlock[];
  phase?: SessionMessage["phase"];
  createdAt: number;
}

interface PiPreservedSidecarMessage {
  message: SessionMessage;
  previousUserText: string | null;
  previousUserOccurrence: number | null;
  previousUserMessage: SessionMessage | null;
}

interface PiPreservedSidecarUserMessage {
  message: SessionMessage;
  previousUserText: string;
  previousUserOccurrence: number;
}

export interface PiAgentProviderOptions {
  agentDir?: string | null;
  stateDir?: string | null;
  createServices?: typeof createAgentSessionServices;
  createSessionFromServices?: typeof createAgentSessionFromServices;
}

const DEFAULT_PI_AGENT_DIR = nodePath.join(homedir(), ".pi", "agent");
const DEFAULT_PI_STATE_DIR = nodePath.join(
  homedir(),
  ".sidemesh",
  "pi-provider",
);
const PI_PROMPT_COMPLETION_FALLBACK_DELAY_MS = 100;
const PI_EVENT_QUEUE_DRAIN_TIMEOUT_MS = 1_000;
const PI_SIDECAR_USER_MATCH_TOLERANCE_MS = 2_000;
const PI_MODEL_REASONING_LEVELS = [
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
] as const satisfies readonly PiThinkingLevel[];

export const PI_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
  sessions: {
    create: true,
    resume: true,
    rename: true,
    archive: true,
    compact: true,
    interrupt: true,
    history: true,
    eventReplay: true,
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
    userInput: false,
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
  },
  workspace: {
    remoteGitDiff: false,
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

export class PiAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  public readonly kind = "pi";
  public readonly displayName = "Pi";
  public readonly capabilities = PI_PROVIDER_CAPABILITIES;

  private readonly agentDir: string;
  private readonly stateDir: string;
  private readonly createServicesFactory: typeof createAgentSessionServices;
  private readonly createSessionFromServicesFactory: typeof createAgentSessionFromServices;
  private readonly sessions = new Map<string, PiSessionState>();
  private readonly archivedSessionIds = new Set<string>();
  private readonly loadedSessionIds = new Set<string>();
  private readonly activeTurns = new Map<string, ActivePiTurn>();
  private readonly sessionSummariesById = new Map<string, PiSessionSummary>();
  private readonly sessionSummariesByPath = new Map<string, PiSessionSummary>();
  private readonly sessionSummaryFingerprints = new Map<string, string>();
  private sessionSummaryRefresh: Promise<void> | null = null;
  private saveChain: Promise<void> = Promise.resolve();

  public constructor(options: PiAgentProviderOptions = {}) {
    super();
    this.agentDir = nodePath.resolve(
      options.agentDir?.trim() || DEFAULT_PI_AGENT_DIR,
    );
    this.stateDir = nodePath.resolve(
      options.stateDir?.trim() || DEFAULT_PI_STATE_DIR,
    );
    this.createServicesFactory =
      options.createServices ?? createAgentSessionServices;
    this.createSessionFromServicesFactory =
      options.createSessionFromServices ?? createAgentSessionFromServices;
  }

  public async start(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true });
    await this.loadState();
  }

  public async close(): Promise<void> {
    this.activeTurns.clear();
    for (const session of this.sessions.values()) {
      this.unloadSession(session);
    }
  }

  public async getVersion(): Promise<string> {
    return `Pi ${PI_VERSION}`;
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    const summaries = await this.listPiSessionSummaries();
    const summaryIds = new Set(summaries.map((summary) => summary.id));
    const threads = summaries
      .filter((summary) => this.isArchived(summary.id) === options.archived)
      .map((summary) =>
        cloneThreadRecord(
          mergeThreadWithSummary(
            summary,
            this.sessions.get(summary.id),
            false,
          ),
        ),
      );
    for (const state of this.sessions.values()) {
      if (summaryIds.has(state.thread.id)) {
        continue;
      }
      if (state.archived !== options.archived) {
        continue;
      }
      threads.push(cloneThread(state, false));
    }
    return threads
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, options.limit);
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
    const existing = this.sessions.get(threadId);
    if (existing) {
      const summary = await this.findPiSessionSummary(threadId);
      if (!summary) {
        return cloneThread(existing, includeTurns);
      }
      return cloneThreadRecord(
        mergeThreadWithSummary(summary, existing, includeTurns),
      );
    }
    const summary = await this.findPiSessionSummary(threadId);
    if (!summary) {
      throw new Error(`Unknown Pi session: ${threadId}`);
    }
    return cloneThreadRecord(
      mergeThreadWithSummary(summary, undefined, includeTurns),
    );
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    const state = await this.readableSessionState(thread.id);
    const messages = limitTail(state.messages, options.messageLimit ?? null);
    const activities = limitTail(
      [...state.activities.values()].sort((left, right) => left.seq - right.seq),
      options.activityLimit ?? null,
    );
    return {
      messages: messages.map(cloneMessage),
      activities: activities.map(cloneActivity),
      runtime: cloneRuntime(state.runtime),
      totalMessages: state.messages.length,
      totalActivities: state.activities.size,
      nextSeq: state.nextSeq,
    };
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    const state = await this.readableSessionState(thread.id);
    return cloneRuntime(state.runtime);
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    return [...this.loadedSessionIds];
  }

  private async readableSessionState(threadId: string): Promise<PiSessionState> {
    if (this.activeTurns.has(threadId)) {
      return this.ensureLoadedSession(threadId);
    }
    const existing = this.sessions.get(threadId);
    const hasPreservedSidecar =
      (existing?.preservedSidecarMessages?.length ?? 0) > 0 ||
      (existing?.preservedSidecarUserMessages?.length ?? 0) > 0;
    if (existing && hasPreservedSidecar) {
      const summary = await this.findPiSessionSummary(threadId);
      const fingerprint = summary
        ? this.sessionSummaryFingerprints.get(summary.path) ?? null
        : null;
      if (!summary) {
        return existing;
      }
      if (
        existing.historyFingerprint !== null &&
        existing.historyFingerprint === fingerprint
      ) {
        return existing;
      }
    }
    return this.loadSessionStateFromHistory(threadId);
  }

  public async resumeSessionThread(
    threadId: string,
    _options?: AgentSessionResumeOptions,
  ): Promise<unknown> {
    await this.ensureLoadedSession(threadId);
    this.loadedSessionIds.add(threadId);
    return { resumed: true };
  }

  public async setSessionName(
    threadId: string,
    name: string,
  ): Promise<unknown> {
    const session = await this.ensureSessionState(threadId);
    const normalized = name.trim();
    if (session.session) {
      session.session.setSessionName(normalized);
    } else if (session.thread.path) {
      const manager = SessionManager.open(
        session.thread.path,
        nodePath.dirname(session.thread.path),
        session.thread.cwd,
      );
      manager.appendSessionInfo(normalized);
    } else {
      throw new Error(`Pi session ${threadId} is missing a session path.`);
    }
    session.thread.name = normalized || null;
    session.thread.updatedAt = nowSeconds();
    await this.persistSoon();
    return { renamed: true };
  }

  public async archiveSession(threadId: string): Promise<unknown> {
    this.archivedSessionIds.add(threadId);
    const session = await this.ensureSessionState(threadId);
    session.archived = true;
    const active = this.activeTurns.get(threadId);
    if (active) {
      await this.interruptTurn(threadId, active.turnId);
    }
    this.unloadSession(session);
    await this.persistSoon();
    return { archived: true };
  }

  public async unarchiveSession(threadId: string): Promise<unknown> {
    this.archivedSessionIds.delete(threadId);
    const session = await this.ensureSessionState(threadId);
    session.archived = false;
    session.thread.updatedAt = nowSeconds();
    await this.persistSoon();
    return { unarchived: true };
  }

  public async compactSession(threadId: string): Promise<unknown> {
    const session = await this.ensureLoadedSession(threadId);
    const result = await session.session!.compact();
    await this.persistSoon();
    return result;
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    const session = await this.createLoadedSession(request.cwd);
    await this.applyOverrides(session, request.overrides);
    let activeTurnId: string | null = null;
    if (request.input.length > 0) {
      activeTurnId = await this.startTurn(session, request.input);
    }
    await this.persistSoon();
    return {
      thread: cloneThread(session, false),
      activeTurnId,
      runtime: cloneRuntime(session.runtime),
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    const session = await this.ensureLoadedSession(request.sessionId);
    await this.applyOverrides(session, request.overrides);
    const active = this.activeTurns.get(request.sessionId);
    if (active) {
      const prepared = await preparePiInput(request.input);
      this.reportPreparedInputWarnings(prepared);
      this.appendUserMessage(session, prepared);
      try {
        await session.session!.steer(prepared.text, prepared.images);
      } catch (error) {
        this.emit(
          "stderr",
          error instanceof Error
            ? `Pi steer failed: ${error.message}`
            : "Pi steer failed.",
        );
        throw error;
      }
      this.touch(session);
      await this.persistSoon();
      return { mode: "steer", turnId: active.turnId };
    }
    const turnId = await this.startTurn(session, request.input);
    await this.persistSoon();
    return { mode: "turn", turnId };
  }

  public async interruptTurn(
    threadId: string,
    turnId: string,
  ): Promise<unknown> {
    const active = this.activeTurns.get(threadId);
    if (!active || active.turnId !== turnId) {
      return { interrupted: false };
    }
    const session = await this.ensureLoadedSession(threadId);
    await session.session!.abort().catch(() => undefined);
    if (this.activeTurns.get(threadId)?.turnId === turnId) {
      this.completeActiveTurn(threadId, "interrupted");
    }
    await this.persistSoon();
    return { interrupted: true };
  }

  public async listModels(
    options: AgentModelListOptions,
  ): Promise<ModelSummary[]> {
    const services = await this.createServices(options.cwd ?? process.cwd());
    const models = services.modelRegistry.getAvailable()
      .filter(isPiModelLike)
      .sort((left, right) =>
        formatPiModelRef(left.provider, left.id).localeCompare(
          formatPiModelRef(right.provider, right.id),
        ),
      );
    const defaultProvider = services.settingsManager.getDefaultProvider();
    const defaultModel = services.settingsManager.getDefaultModel();
    const defaultRef =
      defaultProvider && defaultModel
        ? formatPiModelRef(defaultProvider, defaultModel)
        : null;
    const defaultThinking =
      services.settingsManager.getDefaultThinkingLevel() ?? "medium";
    return models.map((model, index) => {
      const ref = formatPiModelRef(model.provider, model.id);
      const reasoningEfforts = model.reasoning
        ? PI_MODEL_REASONING_LEVELS.map((reasoningEffort) => ({
            reasoningEffort,
            description: `Pi ${reasoningEffort} reasoning effort.`,
          }))
        : [];
      return {
        id: `pi:${ref}`,
        model: ref,
        displayName: model.name || titleCaseModelName(model.id),
        description: `Pi model via ${services.modelRegistry.getProviderDisplayName(model.provider)}.`,
        defaultReasoningEffort: model.reasoning ? defaultThinking : "off",
        supportedReasoningEfforts: reasoningEfforts,
        reasoningEffortControl: model.reasoning ? "client" : "provider",
        supportsPersonality: false,
        additionalSpeedTiers: [],
        inputModalities: model.input.includes("image") ? ["text", "image"] : ["text"],
        isDefault: defaultRef ? ref === defaultRef : index === 0,
        sortOrder: index,
        source: "pi",
      };
    });
  }

  public async listSkills(
    options: AgentSkillListOptions,
  ): Promise<SkillCatalogEntry> {
    const services = await this.createServices(options.cwd);
    const { skills, diagnostics } = services.resourceLoader.getSkills();
    return {
      cwd: options.cwd,
      skills: skills.map((skill) => piSkillToSummary(skill, options.cwd, this.agentDir)),
      errors: diagnostics.map(resourceDiagnosticToSkillError),
    };
  }

  private async createServices(cwd: string): Promise<AgentSessionServices> {
    return this.createServicesFactory({
      cwd,
      agentDir: this.agentDir,
    });
  }

  private async createLoadedSession(cwd: string): Promise<PiSessionState> {
    const services = await this.createServices(cwd);
    const sessionManager = SessionManager.create(
      cwd,
      piSessionDirForCwd(cwd, this.agentDir),
    );
    const { session } = await this.createSessionFromServicesFactory({
      services,
      sessionManager,
    });
    const thread: ThreadRecord = {
      id: session.sessionId,
      name: sessionManager.getSessionName() ?? null,
      preview: "Pi session",
      createdAt: nowSeconds(),
      updatedAt: nowSeconds(),
      cwd,
      source: "pi",
      path: session.sessionFile ?? null,
      status: { type: "idle" },
      turns: [],
    };
    const state: PiSessionState = {
      thread,
      messages: [],
      activities: new Map(),
      turns: [],
      runtime: runtimeFromLoadedSession(session, null, null),
      historyFingerprint: null,
      archived: false,
      nextSeq: 0,
      draftAssistantMessage: null,
      session,
      services,
      sessionManager,
      unsubscribe: null,
      pendingCompactionActivityId: null,
      preservedSidecarMessages: [],
      preservedSidecarUserMessages: [],
    };
    this.sessions.set(thread.id, state);
    if (thread.path) {
      this.cacheSessionSummary({
        id: thread.id,
        path: thread.path,
        cwd,
        name: thread.name,
        preview: thread.preview,
        createdAt: thread.createdAt,
        updatedAt: thread.updatedAt,
      });
    }
    this.attachSession(state);
    this.loadedSessionIds.add(thread.id);
    return state;
  }

  private async ensureSessionState(threadId: string): Promise<PiSessionState> {
    const existing = this.sessions.get(threadId);
    if (existing) {
      return existing;
    }
    return this.loadSessionStateFromHistory(threadId);
  }

  private async ensureLoadedSession(threadId: string): Promise<PiSessionState> {
    const existing = await this.ensureSessionState(threadId);
    if (existing.session) {
      this.loadedSessionIds.add(threadId);
      return existing;
    }
    const summary =
      existing.thread.path && existing.thread.cwd
        ? null
        : await this.findPiSessionSummary(threadId);
    const path = existing.thread.path ?? summary?.path ?? null;
    if (!path) {
      throw new Error(`Unknown Pi session: ${threadId}`);
    }
    const threadCwd = existing.thread.cwd || summary?.cwd || process.cwd();
    const services = await this.createServices(threadCwd);
    const sessionManager = SessionManager.open(path, nodePath.dirname(path), threadCwd);
    const { session } = await this.createSessionFromServicesFactory({
      services,
      sessionManager,
    });
    existing.thread.path = session.sessionFile ?? existing.thread.path;
    existing.session = session;
    existing.services = services;
    existing.sessionManager = sessionManager;
    existing.runtime = runtimeFromLoadedSession(session, existing.runtime, this.activeTurns.get(threadId)?.turnId ?? null);
    existing.pendingCompactionActivityId = null;
    this.attachSession(existing);
    this.loadedSessionIds.add(threadId);
    return existing;
  }

  private attachSession(state: PiSessionState): void {
    state.unsubscribe?.();
    state.unsubscribe = state.session?.subscribe((event) => {
      this.handleSessionEvent(state, event);
    }) ?? null;
  }

  private unloadSession(state: PiSessionState): void {
    state.unsubscribe?.();
    state.unsubscribe = null;
    state.session?.dispose();
    state.session = null;
    state.services = null;
    state.sessionManager = null;
    this.loadedSessionIds.delete(state.thread.id);
  }

  private async loadSessionStateFromHistory(
    threadId: string,
  ): Promise<PiSessionState> {
    const summary = await this.findPiSessionSummary(threadId);
    const summaryFingerprint =
      summary ? (this.sessionSummaryFingerprints.get(summary.path) ?? null) : null;
    const existing = this.sessions.get(threadId);
    if (!summary) {
      if (existing) {
        return existing;
      }
      throw new Error(`Unknown Pi session: ${threadId}`);
    }
    if (existing && canReusePiHistoryState(existing, summary, summaryFingerprint)) {
      existing.archived = this.isArchived(threadId);
      normalizeInactivePiSessionState(existing);
      return existing;
    }
    const manager = SessionManager.open(
      summary.path,
      nodePath.dirname(summary.path),
      summary.cwd,
    );
    const parsed = parsePiSessionHistory(manager, summary);
    const state: PiSessionState = existing ?? {
      thread: buildThreadFromSummary(summary, false),
      messages: [],
      activities: new Map(),
      turns: [],
      runtime: null,
      historyFingerprint: null,
      archived: this.isArchived(threadId),
      nextSeq: 0,
      draftAssistantMessage: null,
      pendingCompactionActivityId: null,
      preservedSidecarMessages: [],
      preservedSidecarUserMessages: [],
    };
    state.thread = mergeThreadWithSummary(summary, state, false);
    const merged = mergePreservedSidecarMessages(
      parsed.messages,
      parsed.activities,
      parsed.nonFinalAssistantMessageIds,
      state.preservedSidecarMessages ?? [],
      state.preservedSidecarUserMessages ?? [],
    );
    state.messages = merged.messages;
    state.activities = new Map(
      merged.activities.map((activity) => [
        activity.id,
        normalizeStoredSessionActivity(activity),
      ]),
    );
    state.runtime = mergeRuntime(state.runtime, parsed.runtime);
    if (!state.runtime?.telemetry?.contextWindow && state.runtime?.modelProvider && state.runtime?.model) {
      try {
        const services = await this.createServices(summary.cwd);
        const models = services.modelRegistry.getAvailable();
        const resolved = resolvePiModel(models, state.runtime.model);
        if (resolved && typeof resolved.contextWindow === "number" && resolved.contextWindow > 0) {
          state.runtime = {
            ...state.runtime,
            telemetry: {
              ...(state.runtime.telemetry ?? {}),
              contextWindow: {
                currentTokens: null,
                tokenLimit: resolved.contextWindow,
                messagesLength: state.messages.length,
                updatedAt: Date.now(),
              },
            },
          };
        }
      } catch {
        // Ignore missing services or registry lookup failures for history-only sessions
      }
    }
    state.nextSeq = Math.max(parsed.nextSeq, merged.nextSeq);
    state.thread.name = parsed.threadName ?? state.thread.name;
    state.thread.preview =
      latestPreviewMessage(state.messages) ?? (parsed.preview || state.thread.preview);
    state.thread.path = summary.path;
    state.thread.updatedAt = latestThreadUpdatedAt(
      summary.updatedAt,
      state.thread.updatedAt,
      state.messages,
    );
    state.historyFingerprint = summaryFingerprint;
    state.preservedSidecarMessages = merged.preservedSidecarMessages;
    state.preservedSidecarUserMessages = merged.preservedSidecarUserMessages;
    state.archived = this.isArchived(threadId);
    normalizeInactivePiSessionState(state);
    this.sessions.set(threadId, state);
    this.persistEventually();
    return state;
  }

  private async startTurn(
    session: PiSessionState,
    input: AgentSessionInputItem[],
  ): Promise<string> {
    const loadedSession = session.session;
    if (!loadedSession) {
      throw new Error(`Pi session ${session.thread.id} is not loaded.`);
    }
    const prepared = await preparePiInput(input);
    this.reportPreparedInputWarnings(prepared);
    this.appendUserMessage(session, prepared);
    const turnId = `pi-turn-${randomUUID()}`;
    session.turns.push({
      id: turnId,
      status: "in_progress",
      startedAt: nowSeconds(),
      completedAt: null,
    });
    session.thread.status = { type: "running", activeFlags: ["streaming"] };
    this.activeTurns.set(session.thread.id, { turnId, status: null });
    this.replaceRuntime(
      session,
      runtimeWithTurnId(
        runtimeFromLoadedSession(loadedSession, session.runtime, turnId),
        turnId,
      ),
    );
    this.touch(session);
    this.emit("liveEvent", {
      type: "turn_started",
      sessionId: session.thread.id,
      turnId,
    });
    void this.runPrompt(session, loadedSession, turnId, prepared);
    return turnId;
  }

  private async runPrompt(
    session: PiSessionState,
    loadedSession: AgentSession,
    turnId: string,
    prepared: PiPreparedInput,
  ): Promise<void> {
    try {
      if (this.activeTurns.get(session.thread.id)?.turnId !== turnId) {
        return;
      }
      const options =
        prepared.images.length > 0
          ? ({
              images: prepared.images,
            } as Parameters<AgentSession["prompt"]>[1])
          : undefined;
      await loadedSession.prompt(prepared.text, options);
      await this.completeResolvedPromptTurn(
        session.thread.id,
        turnId,
        loadedSession,
      );
    } catch (error) {
      if (this.activeTurns.get(session.thread.id)?.turnId !== turnId) {
        return;
      }
      const message =
        error instanceof Error ? error.message : "Pi prompt failed.";
      this.emit("stderr", `Pi prompt failed: ${message}`);
      this.appendAssistantMessage(session, {
        text: message,
        phase: "final_answer",
        createdAt: Date.now(),
      });
      this.completeActiveTurn(session.thread.id, "failed");
    } finally {
      this.persistEventually();
    }
  }

  private async completeResolvedPromptTurn(
    threadId: string,
    turnId: string,
    loadedSession: AgentSession,
  ): Promise<void> {
    const eventQueue = piEventQueueFor(loadedSession);
    if (!eventQueue) {
      await sleep(PI_PROMPT_COMPLETION_FALLBACK_DELAY_MS);
      await this.finishResolvedPromptTurn(threadId, turnId);
      return;
    }
    const drained = await waitForPiEventQueueToDrain(eventQueue);
    if (!drained) {
      void this.completeResolvedPromptTurnAfterQueueDrain(
        threadId,
        turnId,
        eventQueue,
      );
      return;
    }
    await this.finishResolvedPromptTurn(threadId, turnId);
  }

  private async completeResolvedPromptTurnAfterQueueDrain(
    threadId: string,
    turnId: string,
    eventQueue: Promise<unknown>,
  ): Promise<void> {
    try {
      await settlePiEventQueue(eventQueue);
      await this.finishResolvedPromptTurn(threadId, turnId);
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "unknown completion error";
      this.emit("stderr", `Pi prompt completion fallback failed: ${message}`);
    }
  }

  private async finishResolvedPromptTurn(
    threadId: string,
    turnId: string,
  ): Promise<void> {
    const active = this.activeTurns.get(threadId);
    const session = this.sessions.get(threadId);
    if (!active || active.turnId !== turnId || !session) {
      return;
    }
    this.completeActiveTurn(threadId, active.status ?? "completed");
    this.persistEventually();
  }

  private async applyOverrides(
    session: PiSessionState,
    overrides: AgentCreateSessionRequest["overrides"],
  ): Promise<void> {
    const activeTurnId = this.activeTurns.get(session.thread.id)?.turnId ?? null;
    const loaded = session.session;
    const services = session.services;
    if (!loaded || !services) {
      return;
    }

    if (overrides.model?.trim()) {
      const availableModels = services.modelRegistry
        .getAvailable()
        .filter(isPiModelLike);
      const model = resolvePiModel(availableModels, overrides.model);
      if (!model) {
        throw new Error(
          describePiModelLookupFailure(availableModels, overrides.model),
        );
      }
      await loaded.setModel(model);
    }

    if (isPiThinkingLevel(overrides.reasoningEffort)) {
      loaded.setThinkingLevel(overrides.reasoningEffort);
    }

    this.replaceRuntime(
      session,
      runtimeFromLoadedSession(loaded, session.runtime, activeTurnId),
    );
  }

  private handleSessionEvent(
    session: PiSessionState,
    event: AgentSessionEvent,
  ): void {
    switch (event.type) {
      case "session_info_changed":
        session.thread.name = event.name?.trim() || null;
        session.thread.updatedAt = nowSeconds();
        this.persistEventually();
        return;
      case "thinking_level_changed":
        this.replaceRuntime(
          session,
          runtimeFromLoadedSession(
            session.session!,
            session.runtime,
            this.activeTurns.get(session.thread.id)?.turnId ?? null,
          ),
        );
        this.persistEventually();
        return;
      case "queue_update":
        this.emitPiQueueUpdated(session, event);
        return;
      case "auto_retry_start":
        this.emitPiAutoRetryStarted(session, event);
        return;
      case "auto_retry_end":
        this.emitPiAutoRetryEnded(session, event);
        return;
      case "compaction_start": {
        const createdAt = Date.now();
        const activityId = `pi-compaction:${createdAt}`;
        session.pendingCompactionActivityId = activityId;
        this.upsertActivity(session, {
          id: activityId,
          type: "context_compaction",
          turnId: this.activeTurns.get(session.thread.id)?.turnId ?? null,
          status: "in_progress",
        }, createdAt);
        this.replaceRuntime(session, {
          ...(session.runtime ?? {}),
          telemetry: {
            ...(session.runtime?.telemetry ?? {}),
            compaction: {
              ...(session.runtime?.telemetry?.compaction ?? {}),
              status: "running",
              startedAt: createdAt,
              updatedAt: createdAt,
            },
          },
          updatedAt: createdAt,
        });
        this.persistEventually();
        return;
      }
      case "compaction_end": {
        const completedAt = Date.now();
        const activityId =
          session.pendingCompactionActivityId ?? `pi-compaction:${completedAt}`;
        session.pendingCompactionActivityId = null;
        this.upsertActivity(session, {
          id: activityId,
          type: "context_compaction",
          turnId: this.activeTurns.get(session.thread.id)?.turnId ?? null,
          status:
            event.aborted || event.errorMessage
              ? "failed"
              : "completed",
        }, completedAt);
        this.replaceRuntime(session, {
          ...(session.runtime ?? {}),
          telemetry: {
            ...(session.runtime?.telemetry ?? {}),
            compaction: {
              ...(session.runtime?.telemetry?.compaction ?? {}),
              status:
                event.aborted || event.errorMessage
                  ? "failed"
                  : "completed",
              completedAt,
              updatedAt: completedAt,
              error: event.errorMessage,
            },
          },
          updatedAt: completedAt,
        });
        if (event.errorMessage) {
          this.emit("liveEvent", {
            type: "provider_warning",
            sessionId: session.thread.id,
            level: "error",
            code: "pi_compaction_failed",
            message: event.errorMessage,
            source: "pi/compaction",
          });
        }
        this.persistEventually();
        return;
      }
      case "message_update":
        this.handleMessageUpdate(session, event);
        return;
      case "message_end":
        this.handleMessageEnd(session, event);
        return;
      case "tool_execution_start":
        this.handleToolExecutionStart(session, event);
        return;
      case "tool_execution_update":
        this.handleToolExecutionUpdate(session, event);
        return;
      case "agent_end": {
        const active = this.activeTurns.get(session.thread.id);
        if (!active) {
          return;
        }
        this.completeActiveTurn(session.thread.id, active.status ?? "completed");
        this.persistEventually();
        return;
      }
      default:
        return;
    }
  }

  private emitPiQueueUpdated(
    session: PiSessionState,
    event: Extract<AgentSessionEvent, { type: "queue_update" }>,
  ): void {
    this.emit("liveEvent", {
      type: "queue_updated",
      sessionId: session.thread.id,
      steeringCount: event.steering.length,
      followUpCount: event.followUp.length,
      steeringPreview: previewPiQueue(event.steering),
      followUpPreview: previewPiQueue(event.followUp),
    });
  }

  private emitPiAutoRetryStarted(
    session: PiSessionState,
    event: Extract<AgentSessionEvent, { type: "auto_retry_start" }>,
  ): void {
    this.emit("liveEvent", {
      type: "auto_retry_updated",
      sessionId: session.thread.id,
      phase: "started",
      attempt: event.attempt,
      maxAttempts: event.maxAttempts,
      delayMs: event.delayMs,
      errorMessage: event.errorMessage,
    });
  }

  private emitPiAutoRetryEnded(
    session: PiSessionState,
    event: Extract<AgentSessionEvent, { type: "auto_retry_end" }>,
  ): void {
    this.emit("liveEvent", {
      type: "auto_retry_updated",
      sessionId: session.thread.id,
      phase: "ended",
      attempt: event.attempt,
      success: event.success,
      finalError: event.finalError,
    });
    if (!event.success) {
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId: session.thread.id,
        level: "error",
        code: "pi_auto_retry_failed",
        message:
          event.finalError ??
          `Pi auto-retry failed on attempt ${event.attempt}.`,
        source: "pi/retry",
      });
    }
  }

  private handleMessageUpdate(
    session: PiSessionState,
    event: Extract<AgentSessionEvent, { type: "message_update" }>,
  ): void {
    const active = this.activeTurns.get(session.thread.id);
    const msgEvent = event.assistantMessageEvent;
    const partialMessage =
      "partial" in msgEvent ? msgEvent.partial : undefined;
    this.syncDraftAssistantMessage(
      session,
      active?.turnId ?? null,
      partialMessage ?? event.message,
    );
    if (msgEvent.type === "text_delta") {
      this.emit("liveEvent", {
        type: "assistant_delta",
        sessionId: session.thread.id,
        turnId: active?.turnId,
        delta: msgEvent.delta,
      });
      return;
    }
    if (msgEvent.type === "thinking_delta") {
      this.emit("liveEvent", {
        type: "reasoning_delta",
        sessionId: session.thread.id,
        turnId: active?.turnId,
        delta: msgEvent.delta,
        summary: false,
      });
      return;
    }
  }

  private handleMessageEnd(
    session: PiSessionState,
    event: Extract<AgentSessionEvent, { type: "message_end" }>,
  ): void {
    const message = event.message as unknown as Record<string, unknown>;
    const role = stringValue(message.role);
    if (!role) {
      return;
    }

    if (role === "assistant") {
      const createdAt = numberValue(message.timestamp) ?? Date.now();
      const text = extractPiMessageText(message);
      const content = extractPiMessageContentBlocks(message);
      const errorMessage = stringValue(message.errorMessage);
      const phase = detectPiAssistantPhase(message);
      let completedMessage: SessionMessage | null = null;
      if (text || errorMessage || content.length > 0) {
        const blocks = content.length > 0
          ? content
          : [{ type: "text" as const, text: text || errorMessage || "" }];
        completedMessage = this.appendAssistantMessage(session, {
          text: text || errorMessage || "",
          content: blocks,
          phase,
          createdAt,
        });
        session.draftAssistantMessage = null;
      }
      const active = this.activeTurns.get(session.thread.id);
      const stopReason = stringValue(message.stopReason);
      if (active && (stopReason === "error" || stopReason === "aborted")) {
        active.status = stopReason === "aborted" ? "interrupted" : "failed";
      }
      const assistantRuntime = runtimeFromAssistantMessage(session.runtime, message, active?.turnId ?? null);
      this.replaceRuntime(
        session,
        runtimeFromLoadedSession(session.session ?? null, assistantRuntime, active?.turnId ?? null),
      );
      if (active && isTerminalPiAssistantStopReason(stopReason)) {
        const finalStatus = active.status ?? "completed";
        if (
          !completedMessage &&
          session.draftAssistantMessage?.turnId === active.turnId
        ) {
          completedMessage = materializeInterruptedPiDraftAssistantMessage(session);
          if (completedMessage && finalStatus === "completed") {
            this.preserveMaterializedSidecarLog(session, completedMessage);
          }
          if (completedMessage) {
            this.emit("liveEvent", {
              type: "assistant_message_completed",
              sessionId: session.thread.id,
              turnId: active.turnId,
              message: {
                id: completedMessage.id,
                text: completedMessage.text,
                phase: completedMessage.phase,
              },
            });
          }
        }
        this.completeActiveTurn(session.thread.id, finalStatus);
      }
      this.persistEventually();
      return;
    }

    if (role === "toolResult") {
      const createdAt = numberValue(message.timestamp) ?? Date.now();
      this.finalizeToolResultActivity(session, message, createdAt);
      this.persistEventually();
      return;
    }

    if (role === "custom" || role === "branchSummary" || role === "compactionSummary") {
      const text = customPiMessageText(message);
      if (text) {
        this.appendSystemMessage(session, text, numberValue(message.timestamp) ?? Date.now());
        this.persistEventually();
      }
      return;
    }

    if (role === "bashExecution") {
      const createdAt = numberValue(message.timestamp) ?? Date.now();
      const activity = bashExecutionToActivity(message, {
        turnId: this.activeTurns.get(session.thread.id)?.turnId ?? null,
        createdAt,
        seq: session.nextSeq++,
      });
      session.activities.set(activity.id, activity);
      this.emit("liveEvent", {
        type: "activity_updated",
        sessionId: session.thread.id,
        turnId: activity.turnId ?? undefined,
        activity,
      });
      this.persistEventually();
    }
  }

  private handleToolExecutionStart(
    session: PiSessionState,
    event: Extract<AgentSessionEvent, { type: "tool_execution_start" }>,
  ): void {
    const createdAt = Date.now();
    const draft = toolExecutionStartDraft(event, session.thread.cwd, this.activeTurns.get(session.thread.id)?.turnId ?? null);
    this.upsertActivity(session, draft, createdAt);
    this.persistEventually();
  }

  private handleToolExecutionUpdate(
    session: PiSessionState,
    event: Extract<AgentSessionEvent, { type: "tool_execution_update" }>,
  ): void {
    const activityId = activityIdForToolCall(event.toolName, event.toolCallId);
    const existing = session.activities.get(activityId);
    if (!existing) {
      return;
    }
    const nextOutput = extractPiPartialToolText(event.partialResult);
    if (!nextOutput) {
      return;
    }
    if (existing.type === "command") {
      const previous = existing.output ?? "";
      const delta = appendOutputDelta(previous, nextOutput);
      if (!delta) {
        return;
      }
      const updated: SessionActivity = {
        ...existing,
        output: previous + delta,
      };
      session.activities.set(activityId, updated);
      this.emit("liveEvent", {
        type: "activity_output_delta",
        sessionId: session.thread.id,
        turnId: updated.turnId ?? undefined,
        activityId,
        delta,
      });
      return;
    }
    if (existing.type === "tool") {
      const previous = existing.output ?? "";
      const delta = appendOutputDelta(previous, nextOutput);
      if (!delta) {
        return;
      }
      const updated: SessionActivity = {
        ...existing,
        output: previous + delta,
      };
      session.activities.set(activityId, updated);
      this.emit("liveEvent", {
        type: "activity_output_delta",
        sessionId: session.thread.id,
        turnId: updated.turnId ?? undefined,
        activityId,
        delta,
      });
    }
  }

  private appendUserMessage(
    session: PiSessionState,
    prepared: PiPreparedInput,
  ): void {
    const message: SessionMessage = {
      id: `pi-user:${randomUUID()}`,
      role: "user",
      text: prepared.text,
      content: [{ type: "text", text: prepared.text }],
      attachments: prepared.attachments,
      createdAt: Date.now(),
      seq: session.nextSeq++,
    };
    session.messages.push(message);
    this.touch(session);
  }

  private appendAssistantMessage(
    session: PiSessionState,
    options: {
      text: string;
      content?: SessionMessageContentBlock[];
      phase?: SessionMessage["phase"];
      createdAt: number;
    },
  ): SessionMessage {
    const blocks = options.content && options.content.length > 0
      ? options.content
      : [{ type: "text", text: options.text }] as SessionMessageContentBlock[];
    const message: SessionMessage = {
      id: `pi-assistant:${randomUUID()}`,
      role: "assistant",
      text: options.text,
      content: blocks,
      attachments: [],
      createdAt: options.createdAt,
      seq: session.nextSeq++,
      phase: options.phase ?? "final_answer",
    };
    session.messages.push(message);
    this.touch(session);
    this.emit("liveEvent", {
      type: "assistant_message_completed",
      sessionId: session.thread.id,
      turnId: this.activeTurns.get(session.thread.id)?.turnId,
      message: {
        id: message.id,
        text: message.text,
        phase: message.phase,
      },
    });
    return message;
  }

  private syncDraftAssistantMessage(
    session: PiSessionState,
    turnId: string | null,
    message: unknown,
  ): void {
    if (!turnId) {
      return;
    }
    const typed = asRecord(message);
    if (!typed || stringValue(typed.role) !== "assistant") {
      return;
    }
    const text = extractPiMessageText(typed) || stringValue(typed.errorMessage) || "";
    const content = extractPiMessageContentBlocks(typed);
    if (text.trim().length === 0 && content.length === 0) {
      return;
    }
    const existing = session.draftAssistantMessage;
    const next: PiDraftAssistantMessage = {
      id:
        existing?.turnId === turnId
          ? existing.id
          : `pi-assistant-draft:${turnId}`,
      turnId,
      text,
      content: cloneSessionMessageContentBlocks(
        content.length > 0 ? content : textToBlocks(text),
      ),
      phase: detectPiAssistantPhase(typed),
      createdAt: existing?.turnId === turnId
        ? existing.createdAt
        : numberValue(typed.timestamp) ?? Date.now(),
    };
    if (piDraftAssistantMessageEquals(existing, next)) {
      return;
    }
    session.draftAssistantMessage = next;
    this.persistEventually();
  }

  private reportPreparedInputWarnings(prepared: PiPreparedInput): void {
    for (const warning of prepared.warnings) {
      this.emit("stderr", warning);
    }
  }

  private appendSystemMessage(
    session: PiSessionState,
    text: string,
    createdAt: number,
  ): void {
    session.messages.push({
      id: `pi-system:${randomUUID()}`,
      role: "system",
      text,
      content: [{ type: "text", text }],
      attachments: [],
      createdAt,
      seq: session.nextSeq++,
    });
    this.touch(session);
  }

  private finalizeToolResultActivity(
    session: PiSessionState,
    message: Record<string, unknown>,
    createdAt: number,
  ): void {
    const toolCallId = stringValue(message.toolCallId);
    const toolName = stringValue(message.toolName) || "tool";
    const activityId = activityIdForToolCall(toolName, toolCallId ?? randomUUID());
    const existing = session.activities.get(activityId);
    const output = extractPiContentText(message.content);
    const isError = booleanValue(message.isError) ?? false;
    const details = message.details;
    if (existing?.type === "command") {
      const updated: SessionActivity = {
        ...existing,
        status: isError ? "failed" : "completed",
        output,
        exitCode: parseExitCode(output),
      };
      session.activities.set(activityId, updated);
      this.emit("liveEvent", {
        type: "activity_updated",
        sessionId: session.thread.id,
        turnId: updated.turnId ?? undefined,
        activity: updated,
      });
      return;
    }

    const args = existing?.type === "tool" ? existing.args : null;
    const draft: AgentSessionActivityDraft = {
      id: activityId,
      type: "tool",
      turnId: existing?.turnId ?? this.activeTurns.get(session.thread.id)?.turnId ?? null,
      status: isError ? "failed" : "completed",
      toolName,
      title: existing?.type === "tool" ? existing.title : toolName,
      args,
      output,
      result: details ?? { content: message.content ?? null },
      isError,
      semantic: inferPiToolSemantic(toolName, args, details),
    };
    const activity = this.upsertActivity(session, draft, createdAt);
    if (existing?.type !== "tool") {
      this.emit("liveEvent", {
        type: "activity_updated",
        sessionId: session.thread.id,
        turnId: activity.turnId ?? undefined,
        activity,
      });
    }

    const fileChange = fileChangeFromPiTool(toolName, args, details, activity);
    if (!fileChange) {
      return;
    }
    this.upsertActivity(session, fileChange, createdAt);
  }

  private upsertActivity(
    session: PiSessionState,
    draft: AgentSessionActivityDraft,
    createdAt: number,
  ): SessionActivity {
    const existing = session.activities.get(draft.id);
    const materialized = existing
      ? mergeActivity(
          existing,
          materializeAgentActivityDraft(draft, {
            createdAt: existing.createdAt,
            seq: existing.seq,
          }),
        )
      : materializeAgentActivityDraft(draft, {
          createdAt,
          seq: session.nextSeq++,
        });
    session.activities.set(materialized.id, materialized);
    this.emit("liveEvent", {
      type: "activity_updated",
      sessionId: session.thread.id,
      turnId: materialized.turnId ?? undefined,
      activity: materialized,
    });
    return materialized;
  }

  private replaceRuntime(
    session: PiSessionState,
    runtime: SessionRuntimeSummary | null,
  ): void {
    if (runtimeSummaryEquals(session.runtime, runtime)) {
      return;
    }
    session.runtime = runtime ? { ...runtime } : null;
    this.emit("liveEvent", {
      type: "runtime_updated",
      sessionId: session.thread.id,
      runtime: cloneRuntime(session.runtime),
    });
  }

  private completeActiveTurn(threadId: string, status: string): void {
    const active = this.activeTurns.get(threadId);
    const session = this.sessions.get(threadId);
    if (!active || !session) {
      return;
    }
    const draftMessage =
      session.draftAssistantMessage?.turnId === active.turnId
        ? materializeInterruptedPiDraftAssistantMessage(session)
        : null;
    if (draftMessage && status === "completed") {
      this.preserveMaterializedSidecarLog(session, draftMessage);
    } else if (status === "completed") {
      const userMessage = latestUserMessageWithoutAssistantResponse(
        session.messages,
      );
      if (userMessage) {
        this.preserveUserSidecarLog(session, userMessage);
      }
    }
    const turn = session.turns.find((candidate) => candidate.id === active.turnId);
    if (turn) {
      turn.status = status;
      turn.completedAt = nowSeconds();
    }
    session.thread.status = { type: "idle" };
    this.activeTurns.delete(threadId);
    this.replaceRuntime(
      session,
      runtimeWithTurnId(
        runtimeFromLoadedSession(session.session ?? null, session.runtime, null),
        null,
      ),
    );
    if (draftMessage) {
      this.emit("liveEvent", {
        type: "assistant_message_completed",
        sessionId: threadId,
        turnId: active.turnId,
        message: {
          id: draftMessage.id,
          text: draftMessage.text,
          phase: draftMessage.phase,
        },
      });
    }
    this.emit("liveEvent", {
      type: "turn_completed",
      sessionId: threadId,
      turnId: active.turnId,
      status,
    });
    this.touch(session);
  }

  private preserveMaterializedSidecarLog(
    session: PiSessionState,
    message: SessionMessage,
  ): void {
    const shouldInitializeFingerprint =
      (session.preservedSidecarMessages?.length ?? 0) === 0;
    if (shouldInitializeFingerprint) {
      session.historyFingerprint = null;
    }
    const records = session.preservedSidecarMessages ?? [];
    if (records.some((record) => record.message.id === message.id)) {
      return;
    }
    session.preservedSidecarMessages = [
      ...records,
      {
        message: cloneMessage(message),
        ...previousUserAnchorForMessage(session.messages, message.id),
      },
    ];
  }

  private preserveUserSidecarLog(
    session: PiSessionState,
    message: SessionMessage,
  ): void {
    const record = preservedSidecarUserRecordForMessage(
      session.messages,
      message.id,
    );
    if (!record) {
      return;
    }
    if ((session.preservedSidecarUserMessages?.length ?? 0) === 0) {
      session.historyFingerprint = null;
    }
    const records = session.preservedSidecarUserMessages ?? [];
    if (records.some((candidate) => candidate.message.id === message.id)) {
      return;
    }
    session.preservedSidecarUserMessages = [...records, record];
  }

  private touch(session: PiSessionState): void {
    session.thread.updatedAt = nowSeconds();
    const preview = latestPreviewMessage(session.messages);
    if (preview) {
      session.thread.preview = preview;
    }
  }

  private isArchived(threadId: string): boolean {
    return (
      this.archivedSessionIds.has(threadId) ||
      this.sessions.get(threadId)?.archived === true
    );
  }

  private get statePath(): string {
    return nodePath.join(this.stateDir, "sessions.json");
  }

  private get sessionsRoot(): string {
    return nodePath.join(this.agentDir, "sessions");
  }

  private async loadState(): Promise<void> {
    try {
      const raw = await readFile(this.statePath, "utf8");
      const parsed = JSON.parse(raw) as {
        archivedSessionIds?: string[];
        sessions?: Array<{
          thread: ThreadRecord;
          messages?: SessionMessage[];
          activities?: SessionActivity[];
          turns?: TurnRecord[];
          runtime?: SessionRuntimeSummary | null;
          historyFingerprint?: string | null;
          archived?: boolean;
          nextSeq?: number;
          draftAssistantMessage?: PiDraftAssistantMessage | null;
          preservedSidecarMessages?: Array<{
            message?: SessionMessage;
            previousUserText?: string | null;
            previousUserOccurrence?: number | null;
            previousUserMessage?: SessionMessage | null;
          }>;
          preservedSidecarUserMessages?: Array<{
            message?: SessionMessage;
            previousUserText?: string | null;
            previousUserOccurrence?: number | null;
          }>;
        }>;
      };
      const archivedSessionIds = new Set<string>();
      const restoredSessions = new Map<string, PiSessionState>();
      for (const id of parsed.archivedSessionIds ?? []) {
        archivedSessionIds.add(id);
      }
      for (const item of parsed.sessions ?? []) {
        const state: PiSessionState = {
          thread: item.thread,
          messages: item.messages ?? [],
          activities: new Map(
            (item.activities ?? []).map((activity) => [
              activity.id,
              normalizeStoredSessionActivity(activity),
            ]),
          ),
          turns: item.turns ?? [],
          runtime: item.runtime ?? null,
          historyFingerprint: typeof item.historyFingerprint === "string"
            ? item.historyFingerprint
            : null,
          archived: item.archived === true,
          nextSeq:
            item.nextSeq ??
            Math.max(
              ...[
                ...((item.messages ?? []).map((message) => message.seq)),
                ...((item.activities ?? []).map((activity) => activity.seq)),
                -1,
              ],
            ) + 1,
          draftAssistantMessage: normalizeStoredPiDraftAssistantMessage(
            item.draftAssistantMessage ?? null,
          ),
          pendingCompactionActivityId: null,
          preservedSidecarMessages: Array.isArray(item.preservedSidecarMessages)
            ? item.preservedSidecarMessages.flatMap((record) => {
                if (!record.message) {
                  return [];
                }
                return [{
                  message: cloneMessage(record.message),
                  previousUserText:
                    typeof record.previousUserText === "string"
                      ? record.previousUserText
                      : null,
                  previousUserOccurrence:
                    typeof record.previousUserOccurrence === "number"
                      ? record.previousUserOccurrence
                      : null,
                  previousUserMessage: record.previousUserMessage
                    ? cloneMessage(record.previousUserMessage)
                    : null,
                }];
              })
            : [],
          preservedSidecarUserMessages: Array.isArray(
            item.preservedSidecarUserMessages,
          )
            ? item.preservedSidecarUserMessages.flatMap((record) => {
                if (
                  !record.message ||
                  typeof record.previousUserText !== "string" ||
                  typeof record.previousUserOccurrence !== "number"
                ) {
                  return [];
                }
                return [{
                  message: cloneMessage(record.message),
                  previousUserText: record.previousUserText,
                  previousUserOccurrence: record.previousUserOccurrence,
                }];
              })
            : [],
        };
        normalizeInactivePiSessionState(state);
        restoredSessions.set(state.thread.id, state);
      }
      this.archivedSessionIds.clear();
      this.sessions.clear();
      this.loadedSessionIds.clear();
      this.activeTurns.clear();
      for (const id of archivedSessionIds) {
        this.archivedSessionIds.add(id);
      }
      for (const [threadId, state] of restoredSessions) {
        this.sessions.set(threadId, state);
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
        return;
      }
      this.emit(
        "stderr",
        error instanceof Error
          ? `Pi provider state reset after failing to load ${this.statePath}: ${error.message}`
          : `Pi provider state reset after failing to load ${this.statePath}.`,
      );
    }
  }

  private async persistSoon(): Promise<void> {
    const previous = this.saveChain;
    const next = (async () => {
      try {
        await previous;
      } catch {
        // Keep the persistence queue moving after an earlier failure.
      }
      await this.saveState();
    })();
    this.saveChain = next;
    await next;
  }

  private persistEventually(): void {
    void this.persistSoon().catch((error: unknown) => {
      this.emit(
        "stderr",
        error instanceof Error
          ? `Pi provider state persistence failed: ${error.message}`
          : "Pi provider state persistence failed.",
      );
    });
  }

  private async saveState(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true });
    const payload = {
      archivedSessionIds: [...this.archivedSessionIds],
      sessions: [...this.sessions.values()].map((session) => ({
        thread: cloneThread(session, true),
        messages: session.messages.map(cloneMessage),
        activities: [...session.activities.values()].map(cloneActivity),
        turns: session.turns.map(cloneTurn),
        runtime: cloneRuntime(session.runtime),
        historyFingerprint: session.historyFingerprint,
        archived: session.archived,
        nextSeq: session.nextSeq,
        draftAssistantMessage: clonePiDraftAssistantMessage(
          session.draftAssistantMessage ?? null,
        ),
        preservedSidecarMessages: (session.preservedSidecarMessages ?? []).map(
          (record) => ({
            message: cloneMessage(record.message),
            previousUserText: record.previousUserText,
            previousUserOccurrence: record.previousUserOccurrence,
            previousUserMessage: record.previousUserMessage
              ? cloneMessage(record.previousUserMessage)
              : null,
          }),
        ),
        preservedSidecarUserMessages: (
          session.preservedSidecarUserMessages ?? []
        ).map((record) => ({
          message: cloneMessage(record.message),
          previousUserText: record.previousUserText,
          previousUserOccurrence: record.previousUserOccurrence,
        })),
      })),
    };
    await writeFile(this.statePath, JSON.stringify(payload, null, 2));
  }

  private async listPiSessionSummaries(): Promise<PiSessionSummary[]> {
    await this.refreshSessionSummaries();
    return [...this.sessionSummariesById.values()];
  }

  private async findPiSessionSummary(
    threadId: string,
  ): Promise<PiSessionSummary | null> {
    await this.refreshSessionSummaries();
    return this.sessionSummariesById.get(threadId) ?? null;
  }

  private async refreshSessionSummaries(): Promise<void> {
    if (!this.sessionSummaryRefresh) {
      this.sessionSummaryRefresh = this.scanSessionSummaries().finally(() => {
        this.sessionSummaryRefresh = null;
      });
    }
    await this.sessionSummaryRefresh;
  }

  private async scanSessionSummaries(): Promise<void> {
    const filePaths = await collectPiSessionFiles(this.sessionsRoot);
    const seenPaths = new Set(filePaths);
    for (const [filePath, summary] of this.sessionSummariesByPath) {
      if (seenPaths.has(filePath)) {
        continue;
      }
      this.sessionSummariesByPath.delete(filePath);
      this.sessionSummaryFingerprints.delete(filePath);
      if (this.sessionSummariesById.get(summary.id)?.path === filePath) {
        this.sessionSummariesById.delete(summary.id);
      }
    }
    await Promise.all(
      filePaths.map(async (filePath) => {
        const fileStats = await stat(filePath).catch(() => null);
        if (!fileStats?.isFile()) {
          return;
        }
        const fingerprint = `${fileStats.size}:${fileStats.mtimeMs}`;
        if (this.sessionSummaryFingerprints.get(filePath) === fingerprint) {
          return;
        }
        const summary = await readPiSessionSummary(filePath, fileStats);
        this.sessionSummaryFingerprints.set(filePath, fingerprint);
        const previous = this.sessionSummariesByPath.get(filePath);
        if (previous && this.sessionSummariesById.get(previous.id)?.path === filePath) {
          this.sessionSummariesById.delete(previous.id);
        }
        if (!summary) {
          this.sessionSummariesByPath.delete(filePath);
          return;
        }
        this.cacheSessionSummary(summary);
      }),
    );
  }

  private cacheSessionSummary(summary: PiSessionSummary): void {
    this.sessionSummariesByPath.set(summary.path, summary);
    this.sessionSummariesById.set(summary.id, summary);
  }
}

function piEventQueueFor(session: AgentSession): Promise<unknown> | null {
  const queue = (session as unknown as { _agentEventQueue?: Promise<unknown> })
    ._agentEventQueue;
  if (!queue || typeof queue.then !== "function") {
    return null;
  }
  return queue;
}

async function waitForPiEventQueueToDrain(
  eventQueue: Promise<unknown>,
): Promise<boolean> {
  return Promise.race([
    settlePiEventQueue(eventQueue).then(() => true),
    sleep(PI_EVENT_QUEUE_DRAIN_TIMEOUT_MS).then(() => false),
  ]);
}

async function settlePiEventQueue(eventQueue: Promise<unknown>): Promise<void> {
  await eventQueue.catch(() => undefined);
}

function runtimeFromLoadedSession(
  session: AgentSession | null,
  existing: SessionRuntimeSummary | null,
  turnId: string | null,
): SessionRuntimeSummary | null {
  const base = existing ? { ...existing } : {};
  if (!session) {
    return runtimeWithTurnId(base, turnId);
  }
  const model = session.model;
  const runtime: SessionRuntimeSummary = {
    ...base,
    updatedAt: Date.now(),
    ...(model
      ? {
          model: formatPiModelRef(model.provider, model.id),
          modelProvider: model.provider,
        }
      : {}),
    ...(session.thinkingLevel
      ? {
          reasoningEffort: session.thinkingLevel,
        }
      : {}),
  };

  const contextUsage = session.getContextUsage?.();
  if (contextUsage && contextUsage.contextWindow != null) {
    runtime.telemetry = {
      ...(existing?.telemetry ?? {}),
      contextWindow: {
        currentTokens: contextUsage.tokens ?? null,
        tokenLimit: contextUsage.contextWindow,
        messagesLength: session.messages?.length ?? 0,
        updatedAt: Date.now(),
      },
    };
  }

  return runtimeWithTurnId(runtime, turnId);
}

function runtimeFromAssistantMessage(
  existing: SessionRuntimeSummary | null,
  message: Record<string, unknown>,
  turnId: string | null,
): SessionRuntimeSummary {
  const provider = stringValue(message.provider);
  const model = stringValue(message.model);
  const usage = asRecord(message.usage);
  const next: SessionRuntimeSummary = {
    ...(existing ?? {}),
    updatedAt: numberValue(message.timestamp) ?? Date.now(),
    ...(provider && model
      ? {
          model: formatPiModelRef(provider, model),
          modelProvider: provider,
        }
      : {}),
  };
  next.telemetry = {
    ...(existing?.telemetry ?? {}),
    lastUsage: {
      model:
        provider && model ? formatPiModelRef(provider, model) : undefined,
      inputTokens: numberValue(usage?.input),
      outputTokens: numberValue(usage?.output),
      cacheReadTokens: numberValue(usage?.cacheRead),
      cacheWriteTokens: numberValue(usage?.cacheWrite),
      cost: numberValue(asRecord(usage?.cost)?.total),
      updatedAt: numberValue(message.timestamp) ?? Date.now(),
    },
  };
  return runtimeWithTurnId(next, turnId) ?? next;
}

function runtimeWithTurnId(
  runtime: SessionRuntimeSummary | null,
  turnId: string | null,
): SessionRuntimeSummary | null {
  if (!runtime) {
    return null;
  }
  if (!turnId) {
    const { turnId: _turnId, ...rest } = runtime;
    return rest;
  }
  return {
    ...runtime,
    turnId,
  };
}

function mergeRuntime(
  existing: SessionRuntimeSummary | null,
  parsed: SessionRuntimeSummary | null,
): SessionRuntimeSummary | null {
  if (!parsed) {
    return existing ? { ...existing } : null;
  }
  if (!existing) {
    return { ...parsed };
  }
  return {
    ...parsed,
    telemetry: {
      ...(parsed.telemetry ?? {}),
      contextWindow: parsed.telemetry?.contextWindow ?? existing.telemetry?.contextWindow,
    },
  };
}

function parsePiSessionHistory(
  sessionManager: SessionManager,
  summary: PiSessionSummary,
): {
  messages: SessionMessage[];
  activities: SessionActivity[];
  nonFinalAssistantMessageIds: Set<string>;
  runtime: SessionRuntimeSummary | null;
  nextSeq: number;
  threadName: string | null;
  preview: string;
} {
  const branch = sessionManager.getBranch();
  const messages: SessionMessage[] = [];
  const activities = new Map<string, SessionActivity>();
  const toolCalls = new Map<string, { toolName: string; args: unknown }>();
  const nonFinalAssistantMessageIds = new Set<string>();
  let runtime: SessionRuntimeSummary | null = null;
  let seq = 0;
  let threadName = sessionManager.getSessionName() ?? null;
  let preview = summary.preview;

  for (const entry of branch) {
    const createdAt = entryTimestampMillis(entry.timestamp);
    if (entry.type === "session_info") {
      threadName = entry.name?.trim() || null;
      continue;
    }
    if (entry.type === "thinking_level_change") {
      runtime = {
        ...(runtime ?? {}),
        reasoningEffort: entry.thinkingLevel,
        updatedAt: createdAt,
      };
      continue;
    }
    if (entry.type === "model_change") {
      runtime = {
        ...(runtime ?? {}),
        model: formatPiModelRef(entry.provider, entry.modelId),
        modelProvider: entry.provider,
        updatedAt: createdAt,
      };
      continue;
    }
    if (entry.type === "compaction") {
      activities.set(entry.id, {
        id: entry.id,
        type: "context_compaction",
        turnId: null,
        createdAt,
        seq: seq++,
        status: "completed",
      });
      runtime = {
        ...(runtime ?? {}),
        telemetry: {
          ...(runtime?.telemetry ?? {}),
          compaction: {
            ...(runtime?.telemetry?.compaction ?? {}),
            status: "completed",
            preCompactionTokens: entry.tokensBefore,
            completedAt: createdAt,
            updatedAt: createdAt,
          },
        },
        updatedAt: createdAt,
      };
      continue;
    }
    if (entry.type === "branch_summary") {
      const text = entry.summary.trim();
      if (text) {
        messages.push({
          id: entry.id,
          role: "system",
          text,
          content: [{ type: "text", text }],
          attachments: [],
          createdAt,
          seq: seq++,
        });
        preview = text;
      }
      continue;
    }
    if (entry.type === "custom_message") {
      if (entry.display) {
        const text = extractPiContentText(entry.content);
        const blocks = extractPiContentBlocks(entry.content);
        if (text) {
          messages.push({
            id: entry.id,
            role: "system",
            text,
            content: blocks.length > 0 ? blocks : [{ type: "text", text }],
            attachments: [],
            createdAt,
            seq: seq++,
          });
          preview = text;
        }
      }
      continue;
    }
    if (entry.type !== "message") {
      continue;
    }
    const message = entry.message as unknown as Record<string, unknown>;
    const role = stringValue(message.role);
    if (!role) {
      continue;
    }
    if (role === "user") {
      toolCalls.clear();
      const text = extractPiMessageText(message);
      const blocks = extractPiMessageContentBlocks(message);
      messages.push({
        id: entry.id,
        role: "user",
        text,
        content: blocks.length > 0 ? blocks : [{ type: "text", text }],
        attachments: [],
        createdAt,
        seq: seq++,
      });
      if (text) {
        preview = text;
      }
      continue;
    }
    if (role === "assistant") {
      for (const toolCall of extractPiToolCalls(message.content)) {
        toolCalls.set(toolCall.id, {
          toolName: toolCall.name,
          args: toolCall.arguments,
        });
      }
      const text = extractPiMessageText(message);
      const blocks = extractPiMessageContentBlocks(message);
      const errorMessage = stringValue(message.errorMessage);
      const stopReason = stringValue(message.stopReason);
      if (errorMessage || isNonFinalPiAssistantStopReason(stopReason)) {
        nonFinalAssistantMessageIds.add(entry.id);
      }
      if (text || errorMessage || blocks.length > 0) {
        const derivedBlocks = blocks.length > 0
          ? blocks
          : [{ type: "text" as const, text: text || errorMessage || "" }];
        messages.push({
          id: entry.id,
          role: "assistant",
          text: text || errorMessage || "",
          content: derivedBlocks,
          attachments: [],
          createdAt,
          seq: seq++,
          phase: detectPiAssistantPhase(message) ?? "final_answer",
        });
        preview = text || errorMessage || preview;
      }
      runtime = runtimeFromAssistantMessage(runtime, message, null);
      continue;
    }
    if (role === "toolResult") {
      const toolCallId = stringValue(message.toolCallId);
      const resolved = toolCallId ? toolCalls.get(toolCallId) : null;
      if (toolCallId) {
        toolCalls.delete(toolCallId);
      }
      const toolName = stringValue(message.toolName) || resolved?.toolName || "tool";
      const args = resolved?.args ?? null;
      const activity = persistedPiToolResultActivity(
        toolName,
        toolCallId ?? entry.id,
        args,
        message,
        createdAt,
        seq++,
      );
      activities.set(activity.id, activity);
      const fileChange = fileChangeFromPiTool(
        toolName,
        args,
        message.details,
        activity,
      );
      if (fileChange) {
        activities.set(
          fileChange.id,
          materializeAgentActivityDraft(fileChange, {
            createdAt,
            seq: seq++,
          }),
        );
      }
      continue;
    }
    if (role === "bashExecution") {
      activities.set(
        entry.id,
        bashExecutionToActivity(message, {
          turnId: null,
          createdAt,
          seq: seq++,
        }),
      );
      continue;
    }
    if (role === "custom" || role === "branchSummary" || role === "compactionSummary") {
      const text = customPiMessageText(message);
      if (text) {
        messages.push({
          id: entry.id,
          role: "system",
          text,
          content: textToBlocks(text),
          attachments: [],
          createdAt,
          seq: seq++,
        });
        preview = text;
      }
    }
  }

  return {
    messages,
    activities: [...activities.values()].sort((left, right) => left.seq - right.seq),
    nonFinalAssistantMessageIds,
    runtime,
    nextSeq: seq,
    threadName,
    preview,
  };
}

function persistedPiToolResultActivity(
  toolName: string,
  toolCallId: string,
  args: unknown,
  message: Record<string, unknown>,
  createdAt: number,
  seq: number,
): SessionActivity {
  const output = extractPiContentText(message.content);
  const isError = booleanValue(message.isError) ?? false;
  if (toolName === "bash") {
    return {
      id: activityIdForToolCall(toolName, toolCallId),
      type: "command",
      turnId: null,
      createdAt,
      seq,
      status: isError ? "failed" : "completed",
      command: stringValue(asRecord(args)?.command) || "",
      cwd: "",
      output,
      exitCode: parseExitCode(output),
      durationMs: null,
      source: "tool",
      processId: null,
      commandActions: [],
      terminalStatus: null,
      terminalInput: null,
    };
  }
  return {
    id: activityIdForToolCall(toolName, toolCallId),
    type: "tool",
    turnId: null,
    createdAt,
    seq,
    status: isError ? "failed" : "completed",
    toolName,
    title: toolName,
    args,
    output,
    result: message.details ?? { content: message.content ?? null },
    isError,
    semantic: inferPiToolSemantic(toolName, args, message.details),
  };
}

function toolExecutionStartDraft(
  event: Extract<AgentSessionEvent, { type: "tool_execution_start" }>,
  cwd: string,
  turnId: string | null,
): AgentSessionActivityDraft {
  if (event.toolName === "bash") {
    return {
      id: activityIdForToolCall(event.toolName, event.toolCallId),
      type: "command",
      turnId,
      status: "in_progress",
      command: stringValue(asRecord(event.args)?.command) || "",
      cwd,
      output: null,
      exitCode: null,
      durationMs: null,
      source: "tool",
      processId: null,
      commandActions: [],
      terminalStatus: null,
      terminalInput: null,
    };
  }
  return {
    id: activityIdForToolCall(event.toolName, event.toolCallId),
    type: "tool",
    turnId,
    status: "in_progress",
    toolName: event.toolName,
    title: event.toolName,
    args: event.args ?? null,
    output: null,
    result: null,
    isError: null,
    semantic: inferPiToolSemantic(event.toolName, event.args, null),
  };
}

function fileChangeFromPiTool(
  toolName: string,
  args: unknown,
  details: unknown,
  parent: SessionActivity,
): AgentSessionActivityDraft | null {
  if (toolName !== "edit") {
    return null;
  }
  const typedArgs = asRecord(args);
  const typedDetails = asRecord(details);
  const path = stringValue(typedArgs?.path);
  const diff = stringValue(typedDetails?.diff);
  if (!path || !diff) {
    return null;
  }
  const changes: SessionActivityChange[] = [
    {
      path,
      kind: "update",
      diff,
    },
  ];
  return {
    id: `${parent.id}:file-change`,
    type: "file_change",
    turnId: parent.turnId,
    status: parent.status,
    changes,
  };
}

function inferPiToolSemantic(
  toolName: string,
  args: unknown,
  _result: unknown,
): ToolActivitySemantic {
  const typedArgs = asRecord(args);
  const path = stringValue(typedArgs?.path);
  const query = stringValue(typedArgs?.query) ?? stringValue(typedArgs?.pattern);
  switch (toolName) {
    case "read":
      return {
        category: "filesystem",
        action: "read",
        targets: path
          ? [{ type: "file", path, access: "read", role: "target" }]
          : [],
      };
    case "grep":
      return {
        category: "filesystem",
        action: "search",
        targets: [
          ...(query ? [{ type: "query", value: query } as const] : []),
          ...(path
            ? [{ type: "file", path, role: "target" } as const]
            : []),
        ],
      };
    case "find":
    case "ls":
      return {
        category: "filesystem",
        action: "list",
        targets: path
          ? [{ type: "file", path, role: "target" }]
          : [],
      };
    case "edit":
    case "write":
      return {
        category: "filesystem",
        action: "write",
        targets: path
          ? [{ type: "file", path, access: "write", role: "target" }]
          : [],
      };
    case "bash":
      return {
        category: "command",
        action: "invoke",
        targets: stringValue(typedArgs?.command)
          ? [{ type: "command", command: stringValue(typedArgs?.command)! }]
          : [],
      };
    default:
      return {
        category: "unknown",
        action: "invoke",
        targets: [],
      };
  }
}

function isNonFinalPiAssistantStopReason(
  stopReason: string | null | undefined,
): boolean {
  return (
    stopReason === "toolUse" ||
    stopReason === "error" ||
    stopReason === "aborted"
  );
}

function bashExecutionToActivity(
  message: Record<string, unknown>,
  context: { turnId: string | null; createdAt: number; seq: number },
): SessionActivity {
  const command = stringValue(message.command) || "";
  const output = stringValue(message.output) ?? null;
  const cancelled = booleanValue(message.cancelled) ?? false;
  const exitCode = numberValue(message.exitCode) ?? null;
  return {
    id: `pi-bash:${context.createdAt}:${context.seq}`,
    type: "command",
    turnId: context.turnId,
    createdAt: context.createdAt,
    seq: context.seq,
    status:
      cancelled || (typeof exitCode === "number" && exitCode !== 0)
        ? "failed"
        : "completed",
    command,
    cwd: "",
    output,
    exitCode,
    durationMs: null,
    source: "shell",
    processId: null,
    commandActions: [],
    terminalStatus: null,
    terminalInput: null,
  };
}

function mergeThreadWithSummary(
  summary: PiSessionSummary,
  state: PiSessionState | undefined,
  includeTurns: boolean,
): ThreadRecord {
  if (!state) {
    return buildThreadFromSummary(summary, includeTurns);
  }
  const preferState = state.thread.updatedAt >= summary.updatedAt;
  const base = preferState ? state.thread : buildThreadFromSummary(summary, includeTurns);
  return {
    ...base,
    name: preferState ? state.thread.name : (summary.name ?? state.thread.name),
    preview: preferState ? state.thread.preview : summary.preview,
    createdAt: summary.createdAt,
    updatedAt: preferState ? state.thread.updatedAt : summary.updatedAt,
    cwd: summary.cwd,
    source: "pi",
    path: state.thread.path ?? summary.path,
    status: preferState ? { ...state.thread.status } : { ...base.status },
    turns: includeTurns ? state.turns.map(cloneTurn) : undefined,
  };
}

function normalizeInactivePiSessionState(state: PiSessionState): void {
  const restoredAt = state.thread.updatedAt;
  const hadDraftAssistantMessage = state.draftAssistantMessage != null;
  if (hadDraftAssistantMessage) {
    materializeInterruptedPiDraftAssistantMessage(state);
  }
  const hadActiveTurn = state.turns.some((turn) => {
    if (!isActivePiTurnStatus(turn.status)) {
      return false;
    }
    turn.status = "interrupted";
    turn.completedAt ??= restoredAt;
    return true;
  });
  let hadActiveActivity = false;
  state.activities = new Map(
    [...state.activities.entries()].map(([id, activity]) => {
      const normalized = normalizeInactivePiActivity(activity);
      if (normalized.status !== activity.status) {
        hadActiveActivity = true;
      }
      return [id, normalized];
    }),
  );
  const hadRunningCompaction =
    state.runtime?.telemetry?.compaction?.status === "running";
  state.runtime = normalizeInactivePiRuntime(state.runtime, restoredAt);
  if (
    hadDraftAssistantMessage ||
    hadActiveTurn ||
    hadActiveActivity ||
    hadRunningCompaction ||
    isActivePiThreadStatus(state.thread.status)
  ) {
    state.thread.status = { type: "idle" };
    state.runtime = runtimeWithTurnId(state.runtime, null);
  }
}

function normalizeInactivePiActivity(activity: SessionActivity): SessionActivity {
  if (activity.status !== "in_progress") {
    return activity;
  }
  if (activity.type === "command") {
    return {
      ...activity,
      status: "failed",
      terminalStatus: null,
    };
  }
  return {
    ...activity,
    status: "failed",
  };
}

function normalizeInactivePiRuntime(
  runtime: SessionRuntimeSummary | null,
  restoredAt: number,
): SessionRuntimeSummary | null {
  if (runtime?.telemetry?.compaction?.status !== "running") {
    return runtime;
  }
  const restoredAtMs = restoredAt * 1000;
  return {
    ...runtime,
    telemetry: {
      ...(runtime.telemetry ?? {}),
      compaction: {
        ...runtime.telemetry.compaction,
        status: "failed",
        completedAt: runtime.telemetry.compaction.completedAt ?? restoredAtMs,
        updatedAt: restoredAtMs,
        error:
          runtime.telemetry.compaction.error ??
          "Interrupted by provider restart.",
      },
    },
  };
}

function materializeInterruptedPiDraftAssistantMessage(
  state: PiSessionState,
): SessionMessage | null {
  const draft = state.draftAssistantMessage;
  if (!draft) {
    return null;
  }
  let materialized: SessionMessage | null = null;
  if (
    !state.messages.some((message) => message.id === draft.id) &&
    hasPiDraftAssistantContent(draft)
  ) {
    materialized = {
      id: draft.id,
      role: "assistant",
      text: draft.text,
      content: cloneSessionMessageContentBlocks(draft.content),
      attachments: [],
      createdAt: draft.createdAt,
      seq: state.nextSeq++,
      phase: draft.phase ?? "final_answer",
    };
    state.messages.push(materialized);
    if (draft.text.trim().length > 0) {
      state.thread.preview = draft.text;
    }
  }
  const turn = state.turns.find((candidate) => candidate.id === draft.turnId);
  if (turn) {
    const items = turn.items ?? [];
    if (!items.some((item) => item.id === draft.id)) {
      turn.items = [
        ...items,
        {
          id: draft.id,
          type: "agentMessage",
          text: draft.text,
          phase: draft.phase ?? "final_answer",
        },
      ];
    }
  }
  state.draftAssistantMessage = null;
  return materialized;
}

function hasPiDraftAssistantContent(draft: PiDraftAssistantMessage): boolean {
  if (draft.text.trim().length > 0) {
    return true;
  }
  return draft.content.some(
    (block) =>
      (block.type === "text" && block.text.trim().length > 0) ||
      (block.type === "thinking" && block.thinking.trim().length > 0),
  );
}

function previousUserAnchorForMessage(
  messages: SessionMessage[],
  messageId: string,
): Pick<
  PiPreservedSidecarMessage,
  "previousUserText" | "previousUserOccurrence" | "previousUserMessage"
> {
  const index = messages.findIndex((message) => message.id === messageId);
  if (index === -1) {
    return {
      previousUserText: null,
      previousUserOccurrence: null,
      previousUserMessage: null,
    };
  }
  for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
    const message = messages[cursor];
    if (message?.role === "user") {
      const text = message.text.trim();
      let occurrence = 0;
      for (let prior = 0; prior < cursor; prior += 1) {
        const priorMessage = messages[prior];
        if (priorMessage?.role === "user" && priorMessage.text.trim() === text) {
          occurrence += 1;
        }
      }
      return {
        previousUserText: text,
        previousUserOccurrence: occurrence,
        previousUserMessage: cloneMessage(message),
      };
    }
  }
  return {
    previousUserText: null,
    previousUserOccurrence: null,
    previousUserMessage: null,
  };
}

function latestUserMessageWithoutAssistantResponse(
  messages: SessionMessage[],
): SessionMessage | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message) {
      continue;
    }
    if (message.role === "assistant") {
      return null;
    }
    if (message.role === "user") {
      return message;
    }
  }
  return null;
}

function preservedSidecarUserRecordForMessage(
  messages: SessionMessage[],
  messageId: string,
): PiPreservedSidecarUserMessage | null {
  const index = messages.findIndex((message) => message.id === messageId);
  const message = messages[index];
  if (!message || message.role !== "user") {
    return null;
  }
  const text = message.text.trim();
  let occurrence = 0;
  for (let prior = 0; prior < index; prior += 1) {
    const priorMessage = messages[prior];
    if (priorMessage?.role === "user" && priorMessage.text.trim() === text) {
      occurrence += 1;
    }
  }
  return {
    message: cloneMessage(message),
    previousUserText: text,
    previousUserOccurrence: occurrence,
  };
}

function mergePreservedSidecarMessages(
  parsedMessages: SessionMessage[],
  parsedActivities: SessionActivity[],
  nonFinalAssistantMessageIds: ReadonlySet<string>,
  preservedSidecarMessages: PiPreservedSidecarMessage[],
  preservedSidecarUserMessages: PiPreservedSidecarUserMessage[],
): {
  messages: SessionMessage[];
  activities: SessionActivity[];
  preservedSidecarMessages: PiPreservedSidecarMessage[];
  preservedSidecarUserMessages: PiPreservedSidecarUserMessage[];
  nextSeq: number;
} {
  const messages = parsedMessages.map(cloneMessage);
  const activities = parsedActivities.map(cloneActivity);
  const preservedUsers = mergePreservedSidecarUserMessages(
    messages,
    activities,
    preservedSidecarUserMessages,
  );
  const preserved: PiPreservedSidecarMessage[] = [];
  for (const record of preservedSidecarMessages) {
    const anchoredRecord = ensurePreservedSidecarUser(
      messages,
      activities,
      record,
    );
    if (
      hasPiAssistantReplacement(
        messages,
        nonFinalAssistantMessageIds,
        anchoredRecord,
      )
    ) {
      continue;
    }
    const insertion = preservedSidecarInsertion(
      messages,
      activities,
      anchoredRecord,
    );
    const seq = insertion.seq;
    for (const message of messages) {
      if (message.seq >= seq) {
        message.seq += 1;
      }
    }
    for (const activity of activities) {
      if (activity.seq >= seq) {
        activity.seq += 1;
      }
    }
    const message = {
      ...cloneMessage(record.message),
      seq,
    };
    messages.splice(insertion.insertAt, 0, message);
    preserved.push({
      message: cloneMessage(message),
      previousUserText: record.previousUserText,
      previousUserOccurrence: record.previousUserOccurrence,
      previousUserMessage: record.previousUserMessage
        ? cloneMessage(record.previousUserMessage)
        : null,
    });
  }
  const nextSeq = Math.max(
    0,
    ...messages.map((message) => message.seq + 1),
    ...activities.map((activity) => activity.seq + 1),
  );
  return {
    messages,
    activities,
    preservedSidecarMessages: preserved,
    preservedSidecarUserMessages: preservedUsers,
    nextSeq,
  };
}

function mergePreservedSidecarUserMessages(
  messages: SessionMessage[],
  activities: SessionActivity[],
  records: PiPreservedSidecarUserMessage[],
): PiPreservedSidecarUserMessage[] {
  const preserved: PiPreservedSidecarUserMessage[] = [];
  for (const record of records) {
    if (findPreservedSidecarUserIndex(messages, record) !== -1) {
      continue;
    }
    preserved.push(
      insertPreservedSidecarUserMessage(messages, activities, record),
    );
  }
  return preserved;
}

function ensurePreservedSidecarUser(
  messages: SessionMessage[],
  activities: SessionActivity[],
  record: PiPreservedSidecarMessage,
): PiPreservedSidecarMessage {
  if (
    findPreservedSidecarUserIndex(messages, record) !== -1 ||
    !record.previousUserMessage
  ) {
    return record;
  }
  const inserted = insertPreservedSidecarUserMessage(messages, activities, {
    message: record.previousUserMessage,
    previousUserText: record.previousUserMessage.text.trim(),
    previousUserOccurrence: 0,
  });
  return {
    ...record,
    previousUserText: inserted.previousUserText,
    previousUserOccurrence: inserted.previousUserOccurrence,
    previousUserMessage: cloneMessage(inserted.message),
  };
}

function insertPreservedSidecarUserMessage(
  messages: SessionMessage[],
  activities: SessionActivity[],
  record: PiPreservedSidecarUserMessage,
): PiPreservedSidecarUserMessage {
  const seq = preservedSidecarUserInsertionSeq(
    messages,
    activities,
    record.message,
  );
  shiftTranscriptSeqsAtOrAfter(messages, activities, seq);
  const message = {
    ...cloneMessage(record.message),
    seq,
  };
  const insertAt = messages.findIndex((candidate) => candidate.seq >= seq);
  messages.splice(insertAt === -1 ? messages.length : insertAt, 0, message);
  return (
    preservedSidecarUserRecordForMessage(messages, message.id) ?? {
      message: cloneMessage(message),
      previousUserText: record.previousUserText,
      previousUserOccurrence: record.previousUserOccurrence,
    }
  );
}

function preservedSidecarUserInsertionSeq(
  messages: SessionMessage[],
  activities: SessionActivity[],
  message: SessionMessage,
): number {
  const nextSeq = maxTranscriptNextSeq(messages, activities);
  if (!Number.isFinite(message.seq)) {
    return nextSeq;
  }
  return Math.min(Math.max(0, Math.trunc(message.seq)), nextSeq);
}

function maxTranscriptNextSeq(
  messages: SessionMessage[],
  activities: SessionActivity[],
): number {
  return Math.max(
    0,
    ...messages.map((message) => message.seq + 1),
    ...activities.map((activity) => activity.seq + 1),
  );
}

function shiftTranscriptSeqsAtOrAfter(
  messages: SessionMessage[],
  activities: SessionActivity[],
  seq: number,
): void {
  for (const message of messages) {
    if (message.seq >= seq) {
      message.seq += 1;
    }
  }
  for (const activity of activities) {
    if (activity.seq >= seq) {
      activity.seq += 1;
    }
  }
}

function hasPiAssistantReplacement(
  messages: SessionMessage[],
  nonFinalAssistantMessageIds: ReadonlySet<string>,
  record: PiPreservedSidecarMessage,
): boolean {
  const userIndex = findPreservedSidecarUserIndex(
    messages,
    record,
  );
  if (userIndex === -1) {
    return false;
  }
  const nextUserSeq = nextUserMessageSeq(messages, userIndex);
  for (let index = userIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    if (!message || message.role === "user") {
      return false;
    }
    if (
      message.role === "assistant" &&
      message.text.trim().length > 0 &&
      !nonFinalAssistantMessageIds.has(message.id)
    ) {
      return true;
    }
  }
  return false;
}

function preservedSidecarInsertion(
  messages: SessionMessage[],
  activities: SessionActivity[],
  record: PiPreservedSidecarMessage,
): { insertAt: number; seq: number } {
  const userIndex = findPreservedSidecarUserIndex(messages, record);
  if (userIndex === -1) {
    const seq = Math.max(
      0,
      ...messages.map((message) => message.seq + 1),
      ...activities.map((activity) => activity.seq + 1),
    );
    return {
      insertAt: messages.length,
      seq,
    };
  }
  const userSeq = messages[userIndex]?.seq ?? -1;
  const nextUserSeq = nextUserMessageSeq(messages, userIndex);
  let lastTurnSeq = userSeq;
  for (const message of messages) {
    if (
      message.seq > userSeq &&
      (nextUserSeq === null || message.seq < nextUserSeq)
    ) {
      lastTurnSeq = Math.max(lastTurnSeq, message.seq);
    }
  }
  for (const activity of activities) {
    if (
      activity.seq > userSeq &&
      (nextUserSeq === null || activity.seq < nextUserSeq)
    ) {
      lastTurnSeq = Math.max(lastTurnSeq, activity.seq);
    }
  }
  const seq = lastTurnSeq + 1;
  const insertAt = messages.findIndex((message) => message.seq >= seq);
  return {
    insertAt: insertAt === -1 ? messages.length : insertAt,
    seq,
  };
}

function findPreservedSidecarUserIndex(
  messages: SessionMessage[],
  record: {
    previousUserText: string | null;
    previousUserOccurrence: number | null;
    previousUserMessage?: SessionMessage | null;
    message?: SessionMessage;
  },
): number {
  if (record.previousUserText === null) {
    return -1;
  }
  const anchorCreatedAt =
    record.previousUserMessage?.createdAt ?? record.message?.createdAt ?? null;
  let occurrence = 0;
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index];
    if (
      message?.role !== "user" ||
      message.text.trim() !== record.previousUserText
    ) {
      continue;
    }
    if (!isPlausiblePreservedSidecarUserMatch(message, anchorCreatedAt)) {
      continue;
    }
    if (
      record.previousUserOccurrence === null ||
      occurrence === record.previousUserOccurrence
    ) {
      return index;
    }
    occurrence += 1;
  }
  return -1;
}

function isPlausiblePreservedSidecarUserMatch(
  message: SessionMessage,
  anchorCreatedAt: number | null,
): boolean {
  if (anchorCreatedAt == null) {
    return true;
  }
  return (
    message.createdAt <=
    anchorCreatedAt + PI_SIDECAR_USER_MATCH_TOLERANCE_MS
  );
}

function nextUserMessageSeq(
  messages: SessionMessage[],
  userIndex: number,
): number | null {
  for (let index = userIndex + 1; index < messages.length; index += 1) {
    const message = messages[index];
    if (message?.role === "user") {
      return message.seq;
    }
  }
  return null;
}

function cloneSessionMessageContentBlocks(
  content: SessionMessageContentBlock[],
): SessionMessageContentBlock[] {
  return content.map((block) => ({ ...block }));
}

function normalizeStoredPiDraftAssistantMessage(
  draft: PiDraftAssistantMessage | null | undefined,
): PiDraftAssistantMessage | null {
  if (!draft) {
    return null;
  }
  return {
    ...draft,
    content: cloneSessionMessageContentBlocks(draft.content ?? []),
    phase:
      draft.phase === "commentary" || draft.phase === "final_answer"
        ? draft.phase
        : "final_answer",
  };
}

function clonePiDraftAssistantMessage(
  draft: PiDraftAssistantMessage | null | undefined,
): PiDraftAssistantMessage | null {
  if (!draft) {
    return null;
  }
  return {
    ...draft,
    content: cloneSessionMessageContentBlocks(draft.content),
  };
}

function piDraftAssistantMessageEquals(
  left: PiDraftAssistantMessage | null | undefined,
  right: PiDraftAssistantMessage,
): boolean {
  if (!left) {
    return false;
  }
  return JSON.stringify(left) === JSON.stringify(right);
}

function isActivePiTurnStatus(status: string | null | undefined): boolean {
  return status === "in_progress" || status === "inProgress";
}

function isActivePiThreadStatus(status: ThreadRecord["status"] | null | undefined): boolean {
  const type = status?.phase ?? status?.type;
  return (
    type === "running" ||
    type === "active" ||
    type === "waiting_for_input" ||
    type === "waiting_for_approval"
  );
}

function isTerminalPiAssistantStopReason(
  stopReason: string | null | undefined,
): boolean {
  return (
    stopReason === "stop" ||
    stopReason === "error" ||
    stopReason === "aborted"
  );
}

function canReusePiHistoryState(
  state: PiSessionState,
  summary: PiSessionSummary,
  summaryFingerprint: string | null,
): boolean {
  return (
    state.session == null &&
    state.historyFingerprint !== null &&
    state.historyFingerprint === summaryFingerprint &&
    state.thread.path === summary.path &&
    state.thread.cwd === summary.cwd &&
    state.thread.createdAt === summary.createdAt &&
    state.thread.updatedAt === summary.updatedAt &&
    state.thread.name === summary.name
  );
}

function buildThreadFromSummary(
  summary: PiSessionSummary,
  includeTurns: boolean,
): ThreadRecord {
  return {
    id: summary.id,
    name: summary.name,
    preview: summary.preview,
    createdAt: summary.createdAt,
    updatedAt: summary.updatedAt,
    cwd: summary.cwd,
    source: "pi",
    path: summary.path,
    status: { type: "idle" },
    turns: includeTurns ? [] : undefined,
  };
}

async function collectPiSessionFiles(root: string): Promise<string[]> {
  if (!(await pathExists(root))) {
    return [];
  }
  const files: string[] = [];
  const entries = await readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = nodePath.join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await collectPiSessionFiles(fullPath)));
      continue;
    }
    if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      files.push(fullPath);
    }
  }
  return files;
}

async function readPiSessionSummary(
  filePath: string,
  fileStats?: { size: number; mtimeMs: number },
): Promise<PiSessionSummary | null> {
  try {
    const raw = await readFile(filePath, "utf8");
    const entries = raw
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .map((line) => {
        try {
          return JSON.parse(line) as Record<string, unknown>;
        } catch {
          return null;
        }
      })
      .filter((entry): entry is Record<string, unknown> => entry !== null);
    const header = entries[0];
    if (!header || header.type !== "session" || typeof header.id !== "string") {
      return null;
    }
    const cwd = stringValue(header.cwd) || "";
    const createdAtMs = Date.parse(stringValue(header.timestamp) || "") || Date.now();
    let updatedAtMs = createdAtMs;
    let name: string | null = null;
    let preview: string | null = null;
    for (const entry of entries.slice(1)) {
      const role = stringValue(asRecord(entry.message)?.role);
      if (entry.type === "session_info") {
        name = stringValue(entry.name) || null;
      }
      const text =
        entry.type === "message"
          ? role === "assistant" || role === "user"
            ? extractPiMessageText(asRecord(entry.message))
            : role === "custom" || role === "branchSummary" || role === "compactionSummary"
              ? customPiMessageText(asRecord(entry.message))
              : null
          : entry.type === "branch_summary"
            ? stringValue(entry.summary)
            : null;
      if (text && text.trim().length > 0 && preview === null) {
        preview = text.trim();
      }
      updatedAtMs = Math.max(
        updatedAtMs,
        numberValue(asRecord(entry.message)?.timestamp) ??
          entryTimestampMillis(stringValue(entry.timestamp)),
      );
    }
    return {
      id: header.id,
      path: filePath,
      cwd,
      name,
      preview: summarizePreview(preview ?? cwd ?? "Pi session"),
      createdAt: Math.trunc(createdAtMs / 1000),
      updatedAt: Math.trunc(
        Math.max(updatedAtMs, fileStats?.mtimeMs ?? updatedAtMs) / 1000,
      ),
    };
  } catch {
    return null;
  }
}

function entryTimestampMillis(value: string | undefined): number {
  const parsed = value ? Date.parse(value) : NaN;
  return Number.isFinite(parsed) ? parsed : Date.now();
}

async function preparePiInput(
  input: AgentSessionInputItem[],
): Promise<PiPreparedInput> {
  const promptParts: string[] = [];
  const images: PiImageInput[] = [];
  const attachments: SessionMessageAttachment[] = [];
  const warnings: string[] = [];
  let ignoredImageUrlCount = 0;

  for (const item of input) {
    switch (item.type) {
      case "text":
        if (item.text.trim()) {
          promptParts.push(item.text.trim());
        }
        break;
      case "skill":
        promptParts.push(await inlinePiSkill(item.name, item.path));
        break;
      case "localImage": {
        const image = await readLocalImage(item.path);
        images.push(image);
        attachments.push({ type: "localImage", path: item.path });
        break;
      }
      case "image": {
        // Mobile clients send images as base64 data URLs.  Pi's own wire
        // format (PiImageInput) already stores images as { data, mimeType }
        // so we can parse the data URL inline — no temp-file round-trip.
        const url = item.url ?? "";
        const match = url.match(/^data:([^;,]+);base64,(.+)$/s);
        if (match) {
          const mimeType = match[1].trim();
          const base64Data = match[2].trim();
          images.push({ type: "image", data: base64Data, mimeType });
        } else {
          // Non-data-URL (e.g. http:// link) — Pi can't fetch it.
          ignoredImageUrlCount += 1;
        }
        break;
      }
      case "file": {
        const fileContent = await inlinePiFile(item.path, item.isDirectory ?? false);
        if (fileContent) {
          promptParts.push(fileContent);
        }
        break;
      }
    }
  }

  if (ignoredImageUrlCount > 0) {
    warnings.push(
      ignoredImageUrlCount === 1
        ? "Ignoring 1 image URL attachment because Pi only supports local image attachments."
        : `Ignoring ${ignoredImageUrlCount} image URL attachments because Pi only supports local image attachments.`,
    );
  }

  const preview = previewFromInput(input);
  let text = promptParts.join("\n\n").trim();
  if (!text && images.length === 1) {
    text = "Please inspect the attached image.";
  } else if (!text && images.length > 1) {
    text = `Please inspect the ${images.length} attached images.`;
  } else if (!text && ignoredImageUrlCount > 0) {
    text =
      ignoredImageUrlCount === 1
        ? "The request only included an unsupported image URL attachment. Tell the user that Pi only supports local image attachments."
        : "The request only included unsupported image URL attachments. Tell the user that Pi only supports local image attachments.";
  }

  return {
    text,
    preview,
    attachments,
    images,
    warnings,
  };
}

async function inlinePiSkill(name: string, filePath: string): Promise<string> {
  const content = await readFile(filePath, "utf8");
  const body = stripFrontmatter(content).trim();
  const baseDir = nodePath.dirname(filePath);
  return `<skill name="${name}" location="${filePath}">\nReferences are relative to ${baseDir}.\n\n${body}\n</skill>`;
}

const FILE_CONTENT_CAP_BYTES = 100_000;
const DIRECTORY_LISTING_MAX_ENTRIES = 100;

async function inlinePiFile(filePath: string, isDirectory: boolean): Promise<string | null> {
  try {
    if (isDirectory) {
      const entries = await readdir(filePath, { withFileTypes: true });
      const lines = entries
        .slice(0, DIRECTORY_LISTING_MAX_ENTRIES)
        .map((e) => (e.isDirectory() ? `${e.name}/` : e.name));
      const truncated = entries.length > DIRECTORY_LISTING_MAX_ENTRIES;
      const suffix = truncated ? String.raw`
... (${entries.length - DIRECTORY_LISTING_MAX_ENTRIES} more entries)` : "";
      return `--- Directory: ${filePath} ---
${lines.join("\n")}${suffix}`;
    }

    const stats = await stat(filePath);
    const isBinaryFile = await checkBinaryFile(filePath);
    if (isBinaryFile) {
      return `--- File: ${filePath} ---
[binary file]`;
    }

    const handle = await open(filePath, "r");
    try {
      const buffer = Buffer.allocUnsafe(Math.min(stats.size, FILE_CONTENT_CAP_BYTES + 1));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      const text = buffer.subarray(0, bytesRead).toString("utf8");
      const truncated = stats.size > FILE_CONTENT_CAP_BYTES;
      const suffix = truncated ? String.raw`
... (truncated, ${stats.size} bytes total)` : "";
      return `--- File: ${filePath} ---
\`\`\`
${text}${suffix}
\`\`\``;
    } finally {
      await handle.close();
    }
  } catch {
    return `--- File: ${filePath} ---
[unable to read file]`;
  }
}

async function checkBinaryFile(filePath: string): Promise<boolean> {
  const handle = await open(filePath, "r");
  try {
    const buffer = Buffer.allocUnsafe(8192);
    const { bytesRead } = await handle.read(buffer, 0, 8192, 0);
    const sample = buffer.subarray(0, bytesRead);
    if (sample.length === 0) return false;
    for (let i = 0; i < sample.length; i++) {
      if (sample[i] === 0) return true;
    }
    return false;
  } finally {
    await handle.close();
  }
}

async function readLocalImage(path: string): Promise<PiImageInput> {
  const absolutePath = nodePath.resolve(path);
  const mimeType = imageMimeTypeFromPath(absolutePath);
  if (!mimeType) {
    throw new Error(`Unsupported image type for "${path}".`);
  }
  const buffer = await readFile(absolutePath);
  return {
    type: "image",
    data: buffer.toString("base64"),
    mimeType,
  };
}

function piSessionDirForCwd(cwd: string, agentDir: string): string {
  const safePath = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
  return nodePath.join(agentDir, "sessions", safePath);
}

function imageMimeTypeFromPath(path: string): string | null {
  switch (nodePath.extname(path).toLowerCase()) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    case ".svg":
      return "image/svg+xml";
    default:
      return null;
  }
}

function previewFromInput(input: AgentSessionInputItem[]): string {
  const text = input
    .map((item) => {
      switch (item.type) {
        case "text":
          return item.text.trim();
        case "skill":
          return `/skill:${item.name.trim()}`;
        default:
          return "";
      }
    })
    .filter(Boolean)
    .join("\n")
    .trim();
  if (!text) {
    return input.some((item) => item.type === "localImage") ? "Image prompt" : "Pi session";
  }
  return summarizePreview(text);
}

function summarizePreview(text: string): string {
  return text.length > 80 ? `${text.slice(0, 77)}...` : text;
}

function extractPiToolCalls(
  content: unknown,
): Array<{ id: string; name: string; arguments: unknown }> {
  if (!Array.isArray(content)) {
    return [];
  }
  return content.flatMap((block) => {
    const typed = asRecord(block);
    if (!typed || typed.type !== "toolCall") {
      return [];
    }
    const id = stringValue(typed.id);
    const name = stringValue(typed.name);
    if (!id || !name) {
      return [];
    }
    return [{ id, name, arguments: typed.arguments ?? null }];
  });
}

function extractPiMessageText(
  message: Record<string, unknown> | null | undefined,
): string {
  return extractPiContentText(message?.content);
}

function extractPiContentBlocks(
  content: unknown,
): SessionMessageContentBlock[] {
  if (typeof content === "string") {
    const text = content.trim();
    return text ? [{ type: "text", text }] : [];
  }
  if (!Array.isArray(content)) {
    return [];
  }
  const blocks: SessionMessageContentBlock[] = [];
  for (const block of content) {
    const typed = asRecord(block);
    if (!typed) continue;
    const blockType = stringValue(typed.type);
    if (blockType === "text") {
      const text = stringValue(typed.text);
      if (text) {
        blocks.push({ type: "text", text });
      }
    } else if (blockType === "thinking") {
      const thinking = stringValue(typed.thinking);
      if (thinking) {
        blocks.push({ type: "thinking", thinking });
      }
    }
  }
  return blocks;
}

function extractPiMessageContentBlocks(
  message: Record<string, unknown> | null | undefined,
): SessionMessageContentBlock[] {
  return extractPiContentBlocks(message?.content);
}

function extractPiContentText(content: unknown): string {
  const blocks = extractPiContentBlocks(content);
  return blocks
    .filter((b): b is SessionMessageContentBlockText => b.type === "text")
    .map((b) => b.text)
    .join("\n")
    .trim();
}

function customPiMessageText(
  message: Record<string, unknown> | null | undefined,
): string | null {
  if (!message) {
    return null;
  }
  const role = stringValue(message.role);
  if (role === "branchSummary" || role === "compactionSummary") {
    return stringValue(message.summary) ?? null;
  }
  return extractPiMessageText(message) || null;
}

function detectPiAssistantPhase(
  message: Record<string, unknown>,
): SessionMessage["phase"] | undefined {
  const content = Array.isArray(message.content) ? message.content : [];
  let detected: SessionMessage["phase"] | undefined;
  for (const block of content) {
    const typed = asRecord(block);
    if (!typed || typed.type !== "text") {
      continue;
    }
    const rawSignature = stringValue(typed.textSignature);
    if (!rawSignature) {
      continue;
    }
    try {
      const parsed = JSON.parse(rawSignature) as { phase?: unknown };
      if (parsed.phase === "commentary" || parsed.phase === "final_answer") {
        detected = parsed.phase;
      }
    } catch {
      // Ignore legacy non-JSON signatures.
    }
  }
  return detected;
}

function extractPiPartialToolText(partialResult: unknown): string | null {
  if (typeof partialResult === "string") {
    return partialResult;
  }
  const typed = asRecord(partialResult);
  if (!typed) {
    return null;
  }
  const contentText = extractPiContentText(typed.content);
  if (contentText) {
    return contentText;
  }
  return stringValue(typed.text) ?? stringValue(typed.output) ?? null;
}

function appendOutputDelta(previous: string, nextOutput: string): string | null {
  if (!nextOutput) {
    return null;
  }
  if (!previous) {
    return nextOutput;
  }
  if (nextOutput.startsWith(previous)) {
    return nextOutput.slice(previous.length);
  }
  if (previous.endsWith(nextOutput)) {
    return null;
  }
  return nextOutput;
}

function previewPiQueue(
  values: readonly string[],
): string[] | undefined {
  const preview = values
    .slice(0, 3)
    .map((value) => value.trim())
    .filter((value) => value.length > 0)
    .map((value) => value.length > 160 ? `${value.slice(0, 159)}…` : value);
  return preview.length > 0 ? preview : undefined;
}

function activityIdForToolCall(toolName: string, toolCallId: string): string {
  const prefix = toolName === "bash" ? "pi-command" : "pi-tool";
  return `${prefix}:${toolCallId}`;
}

function formatPiModelRef(provider: string, modelId: string): string {
  return `${provider}/${modelId}`;
}

function resolvePiModel<T extends PiModelLike>(
  models: T[],
  requested: string,
): T | null {
  const normalized = requested.trim();
  if (!normalized) {
    return null;
  }
  const typedModels = models.filter(isPiModelLike) as T[];
  if (normalized.includes("/")) {
    const [provider, ...rest] = normalized.split("/");
    const modelId = rest.join("/");
    return (
      typedModels.find(
        (model) => model.provider === provider && model.id === modelId,
      ) ?? null
    );
  }
  const exactMatches = typedModels.filter((model) => model.id === normalized);
  if (exactMatches.length === 1) {
    return exactMatches[0]!;
  }
  return null;
}

function describePiModelLookupFailure(
  models: PiModelLike[],
  requested: string,
): string {
  const normalized = requested.trim();
  if (!normalized) {
    return "Pi model cannot be empty.";
  }
  if (normalized.includes("/")) {
    return `Unknown or unavailable Pi model "${requested}".`;
  }
  const exactMatches = models.filter((model) => model.id === normalized);
  if (exactMatches.length > 1) {
    return `Ambiguous Pi model "${requested}". Use one of: ${exactMatches
      .map((model) => formatPiModelRef(model.provider, model.id))
      .join(", ")}.`;
  }
  return `Unknown or unavailable Pi model "${requested}".`;
}

function piSkillToSummary(
  skill: PiSkill,
  cwd: string,
  agentDir: string,
): SkillSummary {
  const userSkillRoot = nodePath.join(agentDir, "skills");
  const repoSkillRoot = nodePath.join(cwd, ".pi", "skills");
  const normalizedPath = nodePath.resolve(skill.filePath);
  const scope = normalizedPath.startsWith(nodePath.resolve(repoSkillRoot))
    ? "repo"
    : normalizedPath.startsWith(nodePath.resolve(userSkillRoot))
      ? "user"
      : "system";
  return {
    name: skill.name,
    description: skill.description,
    shortDescription: null,
    interface: null,
    path: normalizedPath,
    scope,
    enabled: true,
  };
}

function resourceDiagnosticToSkillError(
  diagnostic: ResourceDiagnostic,
): { path: string; message: string } {
  return {
    path: diagnostic.path ?? diagnostic.collision?.loserPath ?? "<unknown>",
    message: diagnostic.message,
  };
}

function isPiModelLike(value: unknown): value is PiModelLike {
  const typed = asRecord(value);
  return (
    !!typed &&
    typeof typed.id === "string" &&
    typeof typed.name === "string" &&
    typeof typed.provider === "string" &&
    typeof typed.reasoning === "boolean" &&
    Array.isArray(typed.input)
  );
}

function isPiThinkingLevel(value: unknown): value is PiThinkingLevel {
  return (
    value === "off" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh"
  );
}

function titleCaseModelName(value: string): string {
  return value
    .split(/[-_:/\s]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function latestPreviewMessage(messages: SessionMessage[]): string | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const text = messages[index]?.text.trim();
    if (text) {
      return summarizePreview(text);
    }
  }
  return null;
}

function latestThreadUpdatedAt(
  summaryUpdatedAt: number,
  currentUpdatedAt: number,
  messages: SessionMessage[],
): number {
  let latest = Math.max(summaryUpdatedAt, currentUpdatedAt);
  for (const message of messages) {
    latest = Math.max(latest, messageCreatedAtSeconds(message.createdAt));
  }
  return latest;
}

function messageCreatedAtSeconds(createdAt: number): number {
  const timestamp = Math.trunc(createdAt);
  return timestamp >= 1_000_000_000_000
    ? Math.trunc(timestamp / 1000)
    : timestamp;
}

function parseExitCode(output: string | null): number | null {
  if (!output) {
    return null;
  }
  const match = output.match(/Command exited with code (\d+)/);
  if (!match) {
    return null;
  }
  const parsed = Number.parseInt(match[1]!, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function stripFrontmatter(content: string): string {
  if (!content.startsWith("---\n")) {
    return content;
  }
  const end = content.indexOf("\n---\n", 4);
  if (end === -1) {
    return content;
  }
  return content.slice(end + 5);
}

function runtimeSummaryEquals(
  left: SessionRuntimeSummary | null,
  right: SessionRuntimeSummary | null,
): boolean {
  return JSON.stringify(left ?? null) === JSON.stringify(right ?? null);
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

function nowSeconds(): number {
  return Math.trunc(Date.now() / 1000);
}

function cloneThread(session: PiSessionState, includeTurns: boolean): ThreadRecord {
  return {
    ...session.thread,
    status: { ...session.thread.status },
    turns: includeTurns ? session.turns.map(cloneTurn) : undefined,
  };
}

function cloneThreadRecord(thread: ThreadRecord): ThreadRecord {
  return {
    ...thread,
    status: { ...thread.status },
    turns: thread.turns?.map(cloneTurn),
  };
}

function cloneTurn(turn: TurnRecord): TurnRecord {
  return {
    ...turn,
    items: turn.items?.map((item) => ({ ...item })),
  };
}

function cloneMessage(message: SessionMessage): SessionMessage {
  return {
    ...message,
    attachments: message.attachments.map((attachment) => ({ ...attachment })),
    content: message.content.map((block) => ({ ...block })),
  };
}

function cloneActivity(activity: SessionActivity): SessionActivity {
  switch (activity.type) {
    case "command":
      return {
        ...activity,
        commandActions: activity.commandActions.map((action) => ({ ...action })),
      };
    case "tool":
      return {
        ...activity,
        args: cloneStructuredValue(activity.args),
        result: cloneStructuredValue(activity.result),
        semantic: activity.semantic ? cloneToolActivitySemantic(activity.semantic) : null,
      };
    case "file_change":
      return {
        ...activity,
        changes: activity.changes.map(cloneActivityChange),
      };
    case "turn_diff":
    case "web_search":
    case "image_generation":
    case "context_compaction":
      return { ...activity };
  }
}

function cloneRuntime(
  runtime: SessionRuntimeSummary | null,
): SessionRuntimeSummary | null {
  return runtime ? JSON.parse(JSON.stringify(runtime)) : null;
}

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (!limit || limit <= 0 || items.length <= limit) {
    return [...items];
  }
  return items.slice(items.length - limit);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.trunc(value)
    : undefined;
}

function booleanValue(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function asRecord(
  value: unknown,
): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function cloneActivityChange(change: SessionActivityChange): SessionActivityChange {
  return { ...change };
}

function cloneToolActivitySemantic(
  semantic: ToolActivitySemantic,
): ToolActivitySemantic {
  return {
    ...semantic,
    targets: semantic.targets.map(cloneToolActivitySemanticTarget),
  };
}

function cloneToolActivitySemanticTarget(
  target: ToolActivitySemanticTarget,
): ToolActivitySemanticTarget {
  return { ...target };
}

function cloneStructuredValue<T>(value: T): T {
  return value === undefined ? value : structuredClone(value);
}
