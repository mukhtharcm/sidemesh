import { elicitationFields } from "./elicitation.js";
import { randomUUID } from "node:crypto";
import { lookup } from "node:dns/promises";
import { EventEmitter } from "node:events";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { BlockList, isIP } from "node:net";
import nodePath from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { SessionStore, type StoredProviderSession, type StoredSessionItem } from "./session-store.js";
import { reconcileSessionHistory, confirmedSessionInputIds } from "./session-history.js";
import { stripSessionAttachments } from "./session-attachments.js";

import {
  AgentProviderRequestError,
  materializeAgentActivityDraft,
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
  type AgentSkillConfigWriteRequest,
  type AgentSkillListOptions,
  type AgentModelListOptions,
  type AgentPendingAction,
  type AgentProvider,
  type AgentProviderCapabilities,
  type AgentProviderEvents,
  type AgentSessionActivityDraft,
  type AgentSessionInputItem,
  type AgentSessionListOptions,
  type AgentSessionLogOptions, type AgentSessionSnapshot,
  type AgentSessionResumeOptions,
  type AgentSubmitInputRequest,
  type AgentSubmitInputResult,
} from "./agent-provider.js";
import {
  type NormalizedPendingActionDecision,
  type PendingActionDecisionInput,
  type PendingActionElicitationResponse,
  type PendingActionResponseInput,
  type PendingActionUserInputResponse,
  normalizePendingActionDecision,
  parsePendingActionProviderOptionResponse,
} from "./approvals.js";
import {
  approveOnce,
  createCopilotSdkClient,
  rejectPermission,
  type CopilotSdkClient,
  type CopilotSdkClientFactory,
  type CopilotSdkElicitationContext,
  type CopilotSdkElicitationResult,
  type CopilotSdkModelInfo,
  type CopilotSdkPermissionRequest,
  type CopilotSdkPermissionResult,
  type CopilotSdkReasoningEffort,
  type CopilotSdkSession,
  type CopilotSdkSessionConfig,
  type CopilotSdkSessionEvent,
  type CopilotSdkSessionMode,
  type CopilotSdkSessionMetadata,
  type CopilotSdkUserInputRequest,
  type CopilotSdkUserInputResponse,
} from "./copilot-sdk-client.js";
import { normalizeStoredSessionActivity } from "./activity.js";
import type {
  LivePlanStep,
  ModelSummary,
  SessionActivity,
  SkillCatalogEntry,
  SkillSummary,
  SessionLogSnapshot,
  SessionMessage,
  SessionMessageAttachment,
  SessionRuntimeSummary,
  ToolActivitySemantic,
  ToolActivitySemanticTarget,
  ToolActivity,
  ThreadRecord,
  TurnRecord,
  SessionMessageContentBlock,
  SessionMessageContentBlockThinking,
} from "./types.js";

export interface CopilotAgentProviderOptions {
  bin?: string;
  stateDir?: string | null;
  allowAll?: boolean;
  configuredModel?: string | null;
  sdkClientFactory?: CopilotSdkClientFactory;
  providerId?: string;
  sessionStore?: SessionStore;
  hostStateDir?: string;
}

interface CopilotSessionState {
  thread: ThreadRecord;
  turns: TurnRecord[];
  runtime: SessionRuntimeSummary | null;
  archived: boolean;
  copilotSessionId: string | null;
  copilotSessionCreated: boolean;
  sdkSession?: CopilotSdkSession | null;
}

interface LegacyCopilotSessionState extends CopilotSessionState {
  messages: SessionMessage[];
  activities: Map<string, SessionActivity>;
  nextSeq: number;
  draftAssistantMessages: Map<string, CopilotDraftAssistantMessage>;
}

interface CopilotDraftAssistantMessage {
  id: string;
  turnId: string;
  text: string;
  content: SessionMessageContentBlock[];
  phase: "commentary" | "final_answer";
  createdAt: number;
}

interface CopilotStateFile {
  archivedSessionIds?: string[];
  sessions: Array<{
    thread: ThreadRecord;
    messages: SessionMessage[];
    activities?: SessionActivity[];
    turns: TurnRecord[];
    runtime: SessionRuntimeSummary | null;
    archived?: boolean;
    nextSeq: number;
    draftAssistantMessages?: CopilotDraftAssistantMessage[];
    pendingActions?: AgentPendingAction[];
    copilotSessionId?: string | null;
    copilotSessionCreated?: boolean;
  }>;
}

interface ActiveCopilotTurn {
  turnId: string;
  started: boolean;
  sdkSession: CopilotSdkSession;
  assistantBuffers: Map<string, string>;
  reasoningBlocks: SessionMessageContentBlock[];
  completedAssistantMessageIds: Set<string>;
}

interface PendingCopilotPermission {
  action: AgentPendingAction;
  resolve(result: CopilotSdkPermissionResult): void;
}

interface PendingCopilotUserInput {
  action: AgentPendingAction;
  resolve(result: CopilotSdkUserInputResponse): void;
}

interface PendingCopilotElicitation {
  action: AgentPendingAction;
  resolve(result: CopilotSdkElicitationResult): void;
}

type CopilotSessionApproval = Extract<
  CopilotSdkPermissionResult,
  { kind: "approve-for-session" }
>["approval"];

const DEFAULT_COPILOT_STATE_DIR = nodePath.join(
  homedir(),
  ".sidemesh",
  "copilot-provider",
);
const DEFAULT_SIDEMESH_COPILOT_MODEL = "auto";
const COPILOT_SESSION_MODES = [
  "interactive",
  "plan",
  "autopilot",
] as const satisfies readonly CopilotSdkSessionMode[];
const COPILOT_PLAN_READ_RETRY_DELAYS_MS = [25, 75, 150] as const;
const COPILOT_APPROVAL_POLICIES = ["on-request", "never"] as const;
const COPILOT_STATE_LOAD_RETRY_DELAYS_MS = [10, 25, 50] as const;

export const COPILOT_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
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
    steer: true,
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
    command: true,
    tool: true,
    fileChange: true,
    permissions: true,
    approveForSession: true,
  },
  configuration: {
    models: true,
    profiles: false,
    accessModes: false,
    skills: true,
    skillManagement: true,
  },
  runtimeControls: {
    model: true,
    mode: true,
    reasoningEffort: true,
    fastMode: false,
    approvalPolicy: true,
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

export class CopilotAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  public readonly kind = "copilot";
  public readonly displayName = "GitHub Copilot";
  public readonly capabilities = COPILOT_PROVIDER_CAPABILITIES;

  private readonly bin: string;
  private readonly stateDir: string;
  private readonly providerId: string;
  private store?: SessionStore;
  private storeStarting?: Promise<void>;
  private readonly allowAll: boolean;
  private readonly configuredModel: string | null;
  private readonly sdkClientFactory: CopilotSdkClientFactory;
  private readonly sessions = new Map<string, CopilotSessionState>();
  private readonly archivedSessionIds = new Set<string>();
  private readonly loadedSessionIds = new Set<string>();
  private readonly activeTurns = new Map<string, ActiveCopilotTurn>();
  private readonly pendingPermissions = new Map<
    string,
    PendingCopilotPermission
  >();
  private readonly pendingUserInputs = new Map<string, PendingCopilotUserInput>();
  private readonly pendingElicitations = new Map<
    string,
    PendingCopilotElicitation
  >();
  private readonly planUpdateVersions = new Map<string, number>();
  private sdkClient: CopilotSdkClient | null = null;
  private clientStarting: Promise<CopilotSdkClient> | null = null;
  private closed = false;
  private readonly turnTasks = new Set<Promise<void>>();
  private readonly sessionStarting = new Map<string, Promise<CopilotSdkSession>>();
  private closing: Promise<void> | null = null;

  public constructor(private readonly options: CopilotAgentProviderOptions = {}) {
    super();
    this.bin = options.bin?.trim() || "copilot";
    this.stateDir = nodePath.resolve(
      options.stateDir || DEFAULT_COPILOT_STATE_DIR,
    );
    this.allowAll = options.allowAll === true;
    this.configuredModel = options.configuredModel?.trim() || null;
    this.sdkClientFactory = options.sdkClientFactory ?? createCopilotSdkClient;
    this.providerId = options.providerId ?? "copilot";
    this.store = options.sessionStore;
  }

  public async start(): Promise<void> {
    await this.ensureStore();
    await this.ensureSdkClient();
  }

  public close(): Promise<void> {
    return this.closing ??= this.closeRuntime();
  }

  private async closeRuntime(): Promise<void> {
    this.closed = true;
    await this.storeStarting?.catch(() => {});
    const client = this.sdkClient ?? await this.clientStarting?.catch(() => null);
    try {
      for (const [sessionId, active] of this.activeTurns) {
        this.resolvePendingPermissionsForSession(sessionId, { kind: "denied-interactively-by-user" });
        this.resolvePendingUserInputsForSession(sessionId, { answer: "", wasFreeform: true });
        this.resolvePendingElicitationsForSession(sessionId, { action: "cancel" });
        this.completeActiveTurn(sessionId, "interrupted");
        await active.sdkSession.abort().catch(() => undefined);
      }
      const errors = await client?.stop?.();
      if (Array.isArray(errors) && errors.length > 0) {
        throw new AggregateError(errors, "Copilot SDK shutdown failed.");
      }
    } catch (error) {
      await client?.forceStop?.();
      throw error;
    } finally {
      await Promise.allSettled(this.sessionStarting.values());
      await Promise.allSettled(this.turnTasks);
      this.sdkClient = null;
      this.loadedSessionIds.clear();
      this.planUpdateVersions.clear();
      for (const session of this.sessions.values()) session.sdkSession = null;
      await this.persistSoon();
      if (!this.options.sessionStore) this.store?.close();
      this.store = undefined;
    }
  }

  public async getVersion(): Promise<string> {
    try {
      const status = await (await this.ensureSdkClient()).getStatus?.();
      if (status?.version) {
        return `GitHub Copilot SDK ${status.version}`;
      }
    } catch (error) {
      this.emit(
        "stderr",
        error instanceof Error
          ? `Copilot SDK status failed: ${error.message}`
          : "Copilot SDK status failed.",
      );
    }
    return "unknown";
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    const sdkSessions = await this.listSdkSessionMetadata();
    const sdkIds = new Set(sdkSessions.map((session) => session.sessionId));
    const sdkThreads = sdkSessions
      .filter((session) =>
        options.archived
          ? this.archivedSessionIds.has(session.sessionId)
          : !this.archivedSessionIds.has(session.sessionId),
      )
      .map((session) =>
        sdkSessionToThread(
          session,
          this.sessions.get(session.sessionId),
          false,
        ),
      );
    const sidemeshThreads = [...this.sessions.values()]
      .filter((session) => !sdkIds.has(session.thread.id))
      .filter((session) => session.archived === options.archived)
      .map((session) => cloneThread(session, false));
    return [...sdkThreads, ...sidemeshThreads]
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, options.limit)
      .map(cloneThreadRecord);
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    const sdkSessions = await this.listSdkSessionMetadata();
    const sdkIds = new Set(sdkSessions.map((session) => session.sessionId));
    const sdkThreads = sdkSessions
      .filter((session) => !this.archivedSessionIds.has(session.sessionId))
      .map((session) =>
        sdkSessionToThread(
          session,
          this.sessions.get(session.sessionId),
          false,
        ),
      );
    const sidemeshThreads = [...this.sessions.values()]
      .filter((session) => !sdkIds.has(session.thread.id))
      .filter((session) => !session.archived)
      .map((session) => cloneThread(session, false));
    return [...sdkThreads, ...sidemeshThreads]
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, limit)
      .map(cloneThreadRecord);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    const session = await this.getWritableSession(threadId);
    const sdkSession = await this.ensureSdkSession(session);
    const [activity, name] = await Promise.all([sdkSession.rpc.metadata.activity(), sdkSession.rpc.name.get()]);
    session.thread.status = { type: activity.hasActiveWork ? "running" : "idle" };
    session.thread.name = name.name ?? session.thread.name;
    return cloneThread(session, includeTurns);
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    return this.readSessionSnapshot(thread.id, options);
  }

  public async readSessionSnapshot(id: string, options: AgentSessionLogOptions = {}): Promise<AgentSessionSnapshot> {
    await this.ensureStore();
    const session = await this.getWritableSession(id);
    const sdkSession = await this.ensureSdkSession(session);
    const beforeRuntime = session.runtime;
    const [events, name, mode] = await Promise.all([sdkSession.getEvents(), sdkSession.rpc.name.get(), sdkSession.rpc.mode.get()]);
    const nativeActivity = await sdkSession.rpc.metadata.activity();
    const parsed = parseSdkSessionEvents(events, session.thread.cwd);
    const replay: StoredSessionItem[] = [
      ...parsed.messages.map((value): StoredSessionItem => ({ kind: "message", value, nativeId: value.id, authority: "cache" })),
      ...parsed.activities.map((value): StoredSessionItem => ({ kind: "activity", value: nativeActivity.hasActiveWork ? value : normalizeInactiveCopilotActivity(value), nativeId: value.id, authority: "cache" })),
    ].sort((a, b) => a.value.seq - b.value.seq);
    const items = reconcileSessionHistory(this.db.readSessionItems(this.providerId, id), replay);
    if (session.runtime === beforeRuntime) {
      session.runtime = withRuntimeMetadata({ ...session.runtime, ...parsed.runtime }, { mode, updatedAt: Date.now() });
    }
    session.thread.name = name.name ?? session.thread.name;
    if (!nativeActivity.hasActiveWork) session.runtime = normalizeInactiveCopilotRuntime(session.runtime, session.thread.updatedAt);
    session.thread.status = { type: nativeActivity.hasActiveWork ? "running" : "idle" };
    this.db.replaceProviderHistory(this.providerId, this.storedSession(session), items);
    const messages = items.flatMap((item) => item.kind === "message" ? [item.value] : []);
    const activities = items.flatMap((item) => item.kind === "activity" ? [item.value] : []);
    const thread = cloneThread(session, true);
    if (!nativeActivity.hasActiveWork) thread.turns = thread.turns?.filter((turn) => turn.status !== "inProgress");
    return { thread, busy: nativeActivity.hasActiveWork,
      activeTurnId: nativeActivity.hasActiveWork ? this.activeTurns.get(id)?.turnId ?? null : null,
      confirmedInputIds: confirmedSessionInputIds(items), messages: limitTail(messages, options.messageLimit ?? null), activities: limitTail(activities, options.activityLimit ?? null),
      runtime: session.runtime, totalMessages: messages.length, totalActivities: activities.length,
      nextSeq: this.db.nextSessionSequence(this.providerId, id) };
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    const session =
      this.sessions.get(thread.id) ??
      (await this.loadSessionMetadata(thread.id));
    const mode = await (await this.ensureSdkSession(session)).rpc.mode.get();
    session.runtime = withRuntimeMetadata(session.runtime, { mode, updatedAt: Date.now() });
    const runtime = session.runtime;
    return runtime ? { ...runtime } : null;
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    return [...this.loadedSessionIds];
  }

  public async resumeSessionThread(
    threadId: string,
    _options?: AgentSessionResumeOptions,
  ): Promise<unknown> {
    await this.getWritableSession(threadId);
    this.loadedSessionIds.add(threadId);
    return { resumed: true };
  }

  public async setSessionName(
    threadId: string,
    name: string,
  ): Promise<unknown> {
    const session = await this.getWritableSession(threadId);
    await (await this.ensureSdkSession(session)).rpc.name.set({ name });
    session.thread.name = name;
    this.touch(session);
    await this.persistSoon(session);
    return { renamed: true };
  }

  public async archiveSession(threadId: string): Promise<unknown> {
    const session = await this.getWritableSession(threadId);
    this.archivedSessionIds.add(threadId);
    this.planUpdateVersions.delete(threadId);
    if (session) {
      session.archived = true;
      this.touch(session);
    }
    await this.interruptTurn(
      threadId,
      this.activeTurns.get(threadId)?.turnId ?? "",
    );
    this.loadedSessionIds.delete(threadId);
    await this.persistSoon(session);
    return { archived: true };
  }

  public async unarchiveSession(threadId: string): Promise<unknown> {
    const session = await this.getWritableSession(threadId);
    this.archivedSessionIds.delete(threadId);
    if (session) {
      session.archived = false;
      this.touch(session);
    }
    await this.persistSoon(session);
    return { unarchived: true };
  }

  public async compactSession(threadId: string): Promise<unknown> {
    const session = await this.getWritableSession(threadId);
    const sdkSession = await this.ensureSdkSession(session);
    const startedAt = Date.now();
    this.replaceRuntime(
      session,
      withRuntimeMetadata(session.runtime, {
        telemetry: {
          ...(session.runtime?.telemetry ?? {}),
          compaction: {
            ...(session.runtime?.telemetry?.compaction ?? {}),
            status: "running",
            startedAt,
            updatedAt: startedAt,
          },
        },
        updatedAt: startedAt,
      }),
    );
    try {
      const result = await sdkSession.rpc.history.compact();
      const completedAt = Date.now();
      this.replaceRuntime(
        session,
        withRuntimeMetadata(session.runtime, {
          telemetry: {
            ...(session.runtime?.telemetry ?? {}),
            compaction: {
              ...(session.runtime?.telemetry?.compaction ?? {}),
              status: result.success ? "completed" : "failed",
              completedAt,
              updatedAt: completedAt,
              tokensRemoved: result.tokensRemoved,
              messagesRemoved: result.messagesRemoved,
            },
          },
          updatedAt: completedAt,
        }),
      );
      await this.persistSoon(session);
      return result;
    } catch (error) {
      const completedAt = Date.now();
      this.replaceRuntime(
        session,
        withRuntimeMetadata(session.runtime, {
          telemetry: {
            ...(session.runtime?.telemetry ?? {}),
            compaction: {
              ...(session.runtime?.telemetry?.compaction ?? {}),
              status: "failed",
              completedAt,
              updatedAt: completedAt,
              error:
                error instanceof Error
                  ? error.message
                  : "Copilot SDK compaction failed.",
            },
          },
          updatedAt: completedAt,
        }),
      );
      throw error;
    }
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    if (this.closed) throw new Error("Copilot provider is closed.");
    await this.ensureStore();
    const session = this.createSessionState(request);
    await this.ensureSdkSession(session);
    const input = request.input.length > 0 ? await this.submitInput({ sessionId: session.thread.id,
      input: request.input, overrides: request.overrides, activeTurnId: null }) : null;
    return {
      thread: cloneThread(session, false),
      activeTurnId: input?.turnId ?? null,
      runtime: session.runtime,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    let session: CopilotSessionState;
    let sdkSession: CopilotSdkSession;
    let attachments: Awaited<ReturnType<typeof sdkAttachments>>;
    let nativeBusy: boolean;
    try {
      if (this.closed) throw new Error("Copilot provider is closed.");
      session = await this.getWritableSession(request.sessionId);
      if (session.archived) throw new Error("Copilot session is archived.");
      if (request.overrides.mode && !normalizeCopilotSessionMode(request.overrides.mode)) throw new Error("Copilot mode is not available.");
      attachments = await sdkAttachments(request.input);
      session.runtime = mergeRuntime(session.runtime, request.overrides, this.configuredModel, this.allowAll);
      sdkSession = await this.ensureSdkSession(session);
      await this.applyRuntimeControls(session, sdkSession);
      const before = this.activeTurns.get(session.thread.id);
      nativeBusy = (await sdkSession.rpc.metadata.activity()).hasActiveWork;
      if (!nativeBusy && before && this.activeTurns.get(session.thread.id) === before) this.completeActiveTurn(session.thread.id, "completed");
      if (this.closed) throw new Error("Copilot provider is closed.");
    } catch (error) { throw new AgentProviderRequestError(error instanceof Error ? error.message : String(error), 409, true); }
    const existing = this.activeTurns.get(session.thread.id);
    const message = this.appendUserMessage(session, request.input, request.clientMessageId);
    const turnId = existing?.turnId ?? message.id;
    if (!existing) {
      session.turns.push({ id: turnId, status: "inProgress", startedAt: nowSeconds(), completedAt: null });
      session.thread.status = { type: "running", activeFlags: ["inProgress"] };
      this.activeTurns.set(session.thread.id, { turnId, started: false, sdkSession, assistantBuffers: new Map(), reasoningBlocks: [], completedAssistantMessageIds: new Set() });
    }
    this.saveSession(session);
    const sent = (async () => {
      try {
        const nativeId = await sdkSession.send({ prompt: inputPromptText(request.input), displayPrompt: inputDisplayText(request.input), attachments, mode: nativeBusy ? "immediate" : "enqueue" });
        const recovery = this.db.getSessionItem(this.providerId, session.thread.id, message.id);
        if (recovery) this.db.putSessionItem(this.providerId, session.thread.id, { ...recovery, nativeId });
      } catch (error) {
        if (!this.closed) {
          this.emit("liveEvent", { type: "provider_warning", sessionId: session.thread.id, code: "copilot_input_uncertain",
            level: "warning", source: "copilot/sdk", message: error instanceof Error ? error.message : String(error) });
          this.emit("liveEvent", { type: "history_invalidated", sessionId: session.thread.id });
        }
        throw error;
      }
    })();
    this.turnTasks.add(sent);
    try { await sent; } finally { this.turnTasks.delete(sent); }
    return { mode: nativeBusy ? "steer" : "turn", turnId };
  }

  public async interruptTurn(
    threadId: string,
    turnId: string,
  ): Promise<unknown> {
    const active = this.activeTurns.get(threadId);
    if (!active || active.turnId !== turnId) {
      return { interrupted: false };
    }
    await active.sdkSession.abort().catch(() => undefined);
    this.resolvePendingPermissionsForSession(threadId, rejectPermission());
    this.resolvePendingUserInputsForSession(threadId, {
      answer: "",
      wasFreeform: true,
    });
    this.resolvePendingElicitationsForSession(threadId, {
      action: "cancel",
    });
    this.completeActiveTurn(threadId, "interrupted");
    await this.persistSoon(this.sessions.get(threadId));
    return { interrupted: true };
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean {
    const pending = this.pendingPermissions.get(action.id);
    if (pending) {
      const providerOption = parsePendingActionProviderOptionResponse(decision);
      const result = providerOption
        ? buildCopilotProviderOptionResult(
            pending.action,
            providerOption.providerOptionId,
          )
        : buildCopilotPermissionResult(
            normalizePendingActionDecision(
              decision as PendingActionDecisionInput,
            ),
            pending.action.providerPayload,
          );
      if (!result) {
        return false;
      }
      this.pendingPermissions.delete(action.id);
      this.persistEventually(this.sessions.get(action.sessionId));
      pending.resolve(result);
      return true;
    }

    const inputRequest = this.pendingUserInputs.get(action.id);
    if (inputRequest) {
      if (!isCopilotUserInputResponse(decision)) {
        return false;
      }
      this.pendingUserInputs.delete(action.id);
      this.persistEventually(this.sessions.get(action.sessionId));
      inputRequest.resolve(decision);
      return true;
    }

    const elicitation = this.pendingElicitations.get(action.id);
    if (elicitation) {
      if (!isCopilotElicitationResponse(decision)) {
        return false;
      }
      this.pendingElicitations.delete(action.id);
      this.persistEventually(this.sessions.get(action.sessionId));
      elicitation.resolve(decision);
      return true;
    }
    return false;
  }

  public async listModels(
    _options: AgentModelListOptions,
  ): Promise<ModelSummary[]> {
    const configuredModel =
      this.configuredModel ?? readEnvironmentConfiguredCopilotModel();
    const sdkModels = await this.safeListSdkModels();
    const defaultModel = configuredModel ?? DEFAULT_SIDEMESH_COPILOT_MODEL;
    const summaries: ModelSummary[] = [
      copilotModel(DEFAULT_SIDEMESH_COPILOT_MODEL, {
        isDefault: defaultModel === DEFAULT_SIDEMESH_COPILOT_MODEL,
        sortOrder: 0,
        source: "sdk",
      }),
    ];
    const seen = new Set(summaries.map((model) => model.model));
    if (configuredModel && !seen.has(configuredModel)) {
      summaries.push(
        copilotModel(configuredModel, {
          isDefault: configuredModel === defaultModel,
          sortOrder: summaries.length,
          source: "config",
        }),
      );
      seen.add(configuredModel);
    }
    for (const sdkModel of sdkModels) {
      if (!isAvailableSdkModel(sdkModel) || seen.has(sdkModel.id)) {
        continue;
      }
      summaries.push(
        sdkCopilotModel(sdkModel, {
          isDefault: sdkModel.id === defaultModel,
          sortOrder: summaries.length,
        }),
      );
      seen.add(sdkModel.id);
    }
    return summaries;
  }

  public async listSkills(
    options: AgentSkillListOptions,
  ): Promise<SkillCatalogEntry> {
    if (options.forceReload) {
      await this.reloadSkillsForWorkspace(options.cwd);
    }
    const discovered = await (
      await this.ensureSdkClient()
    ).rpc?.skills.discover({
      projectPaths: [options.cwd],
    });
    return {
      cwd: options.cwd,
      skills: (discovered?.skills ?? [])
        .map((skill) => normalizeCopilotSkill(skill, options.cwd))
        .filter((skill): skill is SkillSummary => skill !== null),
      errors: [],
    };
  }

  public async writeSkillConfig(
    request: AgentSkillConfigWriteRequest,
  ): Promise<unknown> {
    const sdkClient = await this.ensureSdkClient();
    const rpc = sdkClient.rpc?.skills;
    if (!rpc) {
      throw new Error("GitHub Copilot SDK skill configuration is unavailable.");
    }
    const discovered = await rpc.discover({});
    const skillName = resolveCopilotSkillName(discovered.skills, request);
    if (!skillName) {
      throw new Error("Unable to resolve Copilot skill to update.");
    }
    const disabledSkills = new Set(
      discovered.skills
        .filter((skill) => skill.enabled === false)
        .map((skill) => skill.name),
    );
    if (request.enabled) {
      disabledSkills.delete(skillName);
    } else {
      disabledSkills.add(skillName);
    }
    await rpc.config.setDisabledSkills({
      disabledSkills: [...disabledSkills].sort((left, right) =>
        left.localeCompare(right),
      ),
    });
    await this.reloadSkillsForLoadedSessions();
    this.emit("liveEvent", { type: "skills_changed" });
    return {
      ok: true,
      path: request.path,
      name: skillName,
      enabled: request.enabled,
    };
  }

  private async reloadSkillsForWorkspace(cwd: string): Promise<void> {
    const sessions = [...this.sessions.values()].filter(
      (session) => session.thread.cwd === cwd && session.sdkSession != null,
    );
    await Promise.all(
      sessions.map(async (session) => {
        const sdkSession = await this.ensureSdkSession(session);
        await sdkSession.rpc?.skills.reload();
      }),
    );
  }

  private async reloadSkillsForLoadedSessions(): Promise<void> {
    await Promise.all(
      [...this.sessions.values()].map(async (session) => {
        if (!session.sdkSession) {
          return;
        }
        await session.sdkSession.rpc?.skills.reload();
      }),
    );
  }

  private createSessionState(
    request: AgentCreateSessionRequest,
  ): CopilotSessionState {
    const now = nowSeconds();
    const id = randomUUID();
    const preview = previewFromInput(request.input) || "Copilot session";
    const thread: ThreadRecord = {
      id,
      name: null,
      preview,
      cwd: request.cwd,
      createdAt: now,
      updatedAt: now,
      source: "copilot",
      path: null,
      status: { type: "idle" },
      turns: [],
    };
    const session: CopilotSessionState = {
      thread,
      turns: [],
      runtime: mergeRuntime(
        null,
        request.overrides,
        this.configuredModel,
        this.allowAll,
      ),
      archived: false,
      copilotSessionId: id,
      copilotSessionCreated: false,
    };
    this.sessions.set(id, session);
    this.saveSession(session);
    this.loadedSessionIds.add(id);
    return session;
  }

  private async ensureSdkClient(): Promise<CopilotSdkClient> {
    await this.ensureStore();
    if (this.closed) throw new Error("Copilot provider is closed.");
    if (this.sdkClient) return this.sdkClient;
    if (!this.clientStarting) {
      this.clientStarting = (async () => {
        const client = await this.sdkClientFactory({
          bin: this.bin, cwd: process.cwd(), env: { ...process.env, SIDEMESH_TOKEN: undefined, NO_COLOR: "1" },
        });
        try {
          await client.start();
          this.sdkClient = client;
          return client;
        } catch (error) {
          await client.forceStop?.();
          throw error;
        }
      })();
    }
    try { return await this.clientStarting; }
    finally { this.clientStarting = null; }
  }

  private async ensureSdkSession(session: CopilotSessionState): Promise<CopilotSdkSession> {
    if (this.closed) throw new Error("Copilot provider is closed.");
    if (session.sdkSession) return session.sdkSession;
    const pending = this.sessionStarting.get(session.thread.id);
    if (pending) return pending;
    const opening = (async () => {
      const client = await this.ensureSdkClient();
      const config = this.buildSdkSessionConfig(session);
      const sdkSession = session.copilotSessionCreated
        ? await client.resumeSession(session.copilotSessionId ?? session.thread.id, { ...config, suppressResumeEvent: true })
        : await client.createSession({ ...config, sessionId: session.copilotSessionId ?? session.thread.id });
      if (this.closed) { await sdkSession.disconnect?.(); throw new Error("Copilot provider is closed."); }
      session.sdkSession = sdkSession;
      session.copilotSessionId = sdkSession.sessionId;
      session.copilotSessionCreated = true;
      this.saveSession(session);
      return sdkSession;
    })();
    this.sessionStarting.set(session.thread.id, opening);
    try { return await opening; } finally { this.sessionStarting.delete(session.thread.id); }
  }

  private buildSdkSessionConfig(
    session: CopilotSessionState,
  ): Omit<CopilotSdkSessionConfig, "sessionId"> {
    const sdkModel = modelForSdk(session.runtime?.model);
    return {
      clientName: "sidemesh",
      model: sdkModel,
      reasoningEffort: reasoningEffortForSdk(
        session.runtime?.reasoningEffort,
        sdkModel,
      ),
      workingDirectory: session.thread.cwd || process.cwd(),
      streaming: true,
      includeSubAgentStreamingEvents: true,
      enableConfigDiscovery: true,
      onPermissionRequest: (request) =>
        this.handlePermissionRequest(session.thread.id, request),
      onUserInputRequest: (request) =>
        this.handleUserInputRequest(session.thread.id, request),
      onElicitationRequest: (request) =>
        this.handleElicitationRequest(session.thread.id, request),
      onEvent: (event) => this.handleSdkEvent(session.thread.id, event),
    };
  }

  private async applyRuntimeControls(
    session: CopilotSessionState,
    sdkSession: CopilotSdkSession,
  ): Promise<void> {
    const mode = normalizeCopilotSessionMode(session.runtime?.mode);
    if (mode) {
      await sdkSession.rpc?.mode.set({ mode });
    }
    const model = modelForSdk(session.runtime?.model);
    if (!model || !sdkSession.setModel) {
      return;
    }
    await sdkSession.setModel(model, {
      reasoningEffort: reasoningEffortForSdk(
        session.runtime?.reasoningEffort,
        model,
      ),
    });
  }

  private async safeListSdkModels(): Promise<CopilotSdkModelInfo[]> {
    try {
      return await (await this.ensureSdkClient()).listModels();
    } catch (error) {
      this.emit(
        "stderr",
        error instanceof Error
          ? `Copilot SDK model listing failed: ${error.message}`
          : "Copilot SDK model listing failed.",
      );
      return [];
    }
  }

  private handleSdkEvent(
    sessionId: string,
    event: CopilotSdkSessionEvent,
  ): void {
    if (this.closed) return;
    const session = this.sessions.get(sessionId);
    if (!session) {
      return;
    }
    if (event.agentId && event.type === "session.error") {
      this.emit("liveEvent", { type: "provider_warning", sessionId, code: "copilot_subagent_error", level: "warning",
        source: "copilot/sdk", message: event.data.message });
      return;
    }
    if (event.agentId && (event.type.startsWith("assistant.") || event.type === "user.message")) return;
    let active = this.activeTurns.get(sessionId);
    if (!active && session.sdkSession && (event.type === "user.message" || event.type === "assistant.turn_start")) {
      active = { turnId: event.id, started: false, sdkSession: session.sdkSession,
        assistantBuffers: new Map(), reasoningBlocks: [], completedAssistantMessageIds: new Set() };
      this.activeTurns.set(sessionId, active);
      session.turns.push({ id: active.turnId, status: "inProgress", startedAt: nowSeconds(), completedAt: null });
      session.thread.status = { type: "running" };
      if (event.type === "user.message") {
        this.appendMessage(session, { id: event.id, nativeId: event.id, role: "user", text: event.data.content,
          attachments: copilotHistoryAttachments(event.data.attachments) });
        this.emit("liveEvent", { type: "history_invalidated", sessionId });
      }
      this.saveSession(session);
    }
    if (active && !active.started && !event.agentId && (event.type === "user.message" || event.type === "assistant.turn_start"
      || event.type === "assistant.message_delta" || event.type === "assistant.message" || event.type === "assistant.reasoning_delta")) {
      active.started = true;
      this.emit("liveEvent", { type: "turn_started", sessionId, turnId: active.turnId });
    }

    if (event.type === "session.model_change") {
      this.replaceRuntime(
        session,
        withRuntimeMetadata(session.runtime, {
          model: event.data.newModel,
          updatedAt: Date.now(),
        }),
      );
      return;
    }

    if (event.type === "session.mode_changed") {
      const mode = normalizeCopilotSessionMode(event.data.newMode);
      if (!mode) {
        return;
      }
      this.replaceRuntime(
        session,
        withRuntimeMetadata(session.runtime, {
          mode,
          updatedAt: Date.now(),
        }),
      );
      this.upsertAndEmitActivity(
        session,
        active?.turnId ?? null,
        buildCopilotModeChangeActivity({
          activityId: copilotModeActivityId(event),
          turnId: active?.turnId ?? null,
          newMode: mode,
          previousMode: event.data.previousMode,
        }),
      );
      return;
    }

    if (event.type === "session.plan_changed") {
      const sdkSession = session.sdkSession ?? active?.sdkSession ?? null;
      if (sdkSession) {
        const version = (this.planUpdateVersions.get(sessionId) ?? 0) + 1;
        this.planUpdateVersions.set(sessionId, version);
        const task = this.emitCopilotPlanUpdated(
          sessionId,
          sdkSession,
          active?.turnId ?? null,
          copilotPlanChangedOperation(event),
          version,
        );
        this.turnTasks.add(task);
        void task.then(() => this.turnTasks.delete(task), (error) => {
          this.turnTasks.delete(task);
          if (!this.closed) this.emit("stderr", `Copilot plan read failed: ${String(error)}`);
        });
      }
      return;
    }

    if (event.type === "subagent.started") {
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId ?? event.id,
        type: "tool",
        turnId: active?.turnId ?? null,
        status: "in_progress",
        toolName: event.data.agentName ?? "subagent",
        title: event.data.agentDisplayName ?? event.data.agentName ?? "Subagent",
        args: null,
        output: null,
        result: null,
        isError: false,
        semantic: null,
      });
      return;
    }

    if (event.type === "subagent.completed") {
      const duration = typeof event.data.durationMs === "number"
        ? ` (${Math.round(event.data.durationMs / 1000)}s)`
        : "";
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId ?? event.id,
        type: "tool",
        turnId: active?.turnId ?? null,
        status: "completed",
        toolName: event.data.agentName ?? "subagent",
        title: `${event.data.agentDisplayName ?? event.data.agentName ?? "Subagent"}${duration}`,
        args: null,
        output: null,
        result: { type: "success", summary: "Subagent completed" },
        isError: false,
        semantic: null,
      });
      return;
    }

    if (event.type === "subagent.failed") {
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId ?? event.id,
        type: "tool",
        turnId: active?.turnId ?? null,
        status: "failed",
        toolName: event.data.agentName ?? "subagent",
        title: event.data.agentDisplayName ?? event.data.agentName ?? "Subagent",
        args: null,
        output: null,
        result: {
          type: "error",
          summary: event.data.error ?? "Subagent failed",
        },
        isError: true,
        semantic: null,
      });
      return;
    }

    const warning = buildCopilotProviderWarningEvent(sessionId, event);
    if (warning) {
      this.emit("liveEvent", warning);
      return;
    }

    if (event.type === "assistant.reasoning") {
      if (!active) {
        return;
      }
      const delta = event.data.content.trim();
      if (!delta) {
        return;
      }
      const reasoningId = event.data.reasoningId ?? event.id;
      const existing = active.reasoningBlocks.find(
        (b): b is SessionMessageContentBlockThinking =>
          b.type === "thinking" && b.reasoningId === reasoningId,
      );
      const previous = existing?.thinking ?? "";
      if (existing) {
        existing.thinking = delta;
      } else {
        active.reasoningBlocks.push({
          type: "thinking",
          thinking: delta,
          reasoningId,
          summary: false,
        });
      }
      this.syncDraftAssistantMessages(session, active);
      if (!delta.startsWith(previous)) {
        this.emit("liveEvent", { type: "history_invalidated", sessionId });
        return;
      }
      this.emit("liveEvent", {
        type: "reasoning_delta",
        sessionId,
        turnId: active.turnId,
        itemId: event.id,
        reasoningId,
        delta: delta.slice(previous.length),
        summary: false,
      });
      return;
    }

    if (event.type === "assistant.reasoning_delta") {
      if (!active) {
        return;
      }
      const delta = event.data.deltaContent;
      if (!delta) {
        return;
      }
      const reasoningId = event.data.reasoningId ?? event.id;
      const existing = active.reasoningBlocks.find(
        (b): b is SessionMessageContentBlockThinking =>
          b.type === "thinking" && b.reasoningId === reasoningId,
      );
      if (existing) {
        existing.thinking += delta;
      } else {
        active.reasoningBlocks.push({
          type: "thinking",
          thinking: delta,
          reasoningId,
          summary: false,
        });
      }
      this.syncDraftAssistantMessages(session, active);
      this.emit("liveEvent", {
        type: "reasoning_delta",
        sessionId,
        turnId: active.turnId,
        itemId: event.id,
        reasoningId,
        delta,
        summary: false,
      });
      return;
    }

    if (
      event.type === "session.usage_info" ||
      event.type === "assistant.usage" ||
      event.type === "session.compaction_start" ||
      event.type === "session.compaction_complete"
    ) {
      this.replaceRuntime(
        session,
        applyCopilotRuntimeEvent(
          session.runtime,
          event,
          millisFromDateLike(event.timestamp) ?? Date.now(),
        ),
      );
      const compaction = copilotCompactionActivity(session.runtime, event);
      if (compaction) this.upsertAndEmitActivity(session, active?.turnId ?? null, compaction);
      return;
    }

    if (event.type === "assistant.message_delta") {
      if (!active) {
        return;
      }
      const delta = event.data.deltaContent;
      const messageId =
        event.data.messageId || `copilot-assistant-${active.turnId}`;
      active.assistantBuffers.set(
        messageId,
        `${active.assistantBuffers.get(messageId) ?? ""}${delta}`,
      );
      this.syncDraftAssistantMessages(session, active);
      this.emit("liveEvent", {
        type: "assistant_delta",
        sessionId,
        turnId: active.turnId,
        itemId: messageId,
        delta,
      });
      return;
    }

    if (event.type === "assistant.message") {
      if (!active) {
        return;
      }
      const turnId = active.turnId;
      const messageId = event.data.messageId || event.id;
      if (active.completedAssistantMessageIds.has(messageId)) {
        return;
      }
      const text = event.data.content.trim();
      if (text.length > 0) {
        this.appendAndEmitAssistantMessage(
          session,
          turnId,
          text,
          assistantPhase(event.data.phase),
          messageId,
        );
      }
      active.completedAssistantMessageIds.add(messageId);
      active.assistantBuffers.delete(messageId);
      active.reasoningBlocks = [];
      this.persistEventually(session);
      return;
    }

    if (event.type === "session.idle") {
      if (active) {
        this.completeActiveTurn(sessionId, "completed");
      }
      this.emit("liveEvent", { type: "history_invalidated", sessionId });
      return;
    }

    if (event.type === "session.error") {
      this.appendMessage(session, { id: event.id, nativeId: event.id, role: "system", text: event.data.message, attachments: [] });
      this.emit("liveEvent", { type: "provider_warning", sessionId, code: "copilot_session_error", level: "error", source: "copilot/sdk", message: event.data.message });
      if (active) this.completeActiveTurn(sessionId, "failed");
      this.emit("liveEvent", { type: "history_invalidated", sessionId });
      return;
    }

    if (event.type === "tool.execution_start") {
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId,
        type: "tool",
        turnId: active?.turnId ?? null,
        status: "in_progress",
        toolName: copilotToolName(event.data.toolName),
        title: formatCopilotToolCommand(
          event.data.toolName,
          event.data.arguments,
        ),
        args: event.data.arguments ?? null,
        output: null,
        result: null,
        isError: null,
        semantic: inferCopilotToolSemantic(
          event.data.toolName,
          event.data.arguments,
          null,
        ),
      });
      return;
    }

    if (event.type === "tool.execution_partial_result") {
      this.appendActivityOutput(
        session,
        active?.turnId ?? null,
        event.data.toolCallId,
        event.data.partialOutput,
      );
      return;
    }

    if (event.type === "tool.execution_progress") {
      this.appendActivityOutput(
        session,
        active?.turnId ?? null,
        event.data.toolCallId,
        `${event.data.progressMessage}\n`,
      );
      return;
    }

    if (event.type === "tool.execution_complete") {
      const completeData = event.data as unknown as Record<string, unknown>;
      const existing = this.activity(session, event.data.toolCallId);
      const existingTool = existing?.type === "tool" ? existing : null;
      const output =
        extractCopilotToolOutput(event.data.result ?? event.data.error) ??
        (existing?.type === "tool" || existing?.type === "command"
          ? existing.output
          : null);
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId,
        type: "tool",
        turnId: active?.turnId ?? null,
        status: event.data.success ? "completed" : "failed",
        toolName: existingTool?.toolName ?? copilotToolName(completeData.toolName),
        title:
          existingTool?.title ??
          formatCopilotToolCommand(
            completeData.toolName,
            completeData.arguments ?? event.data.result ?? event.data.error,
          ),
        args: existingTool?.args ?? completeData.arguments ?? null,
        output,
        result: event.data.result ?? event.data.error ?? null,
        isError: event.data.success ? false : true,
        semantic: mergeCopilotToolSemantic(
          existingTool,
          inferCopilotToolSemantic(
            completeData.toolName,
            existingTool?.args ?? completeData.arguments,
            event.data.result ?? event.data.error ?? null,
          ),
        ),
      });
    }
  }

  private async emitCopilotPlanUpdated(
    sessionId: string,
    sdkSession: CopilotSdkSession,
    turnId: string | null,
    operation: CopilotPlanChangedOperation | null,
    version: number,
  ): Promise<void> {
    if (operation === "delete") {
      if (this.planUpdateVersions.get(sessionId) !== version) {
        return;
      }
      this.emit("liveEvent", {
        type: "plan_updated",
        sessionId,
        turnId: turnId ?? undefined,
        plan: [],
      });
      return;
    }
    const planRpc = sdkSession.rpc?.plan;
    if (!planRpc) {
      return;
    }
    let plan = await planRpc.read().catch(() => null);
    for (const delayMs of COPILOT_PLAN_READ_RETRY_DELAYS_MS) {
      if (this.closed) return;
      if (plan?.exists && plan.content) {
        break;
      }
      await sleep(delayMs);
      plan = await planRpc.read().catch(() => null);
    }
    if (this.closed || this.planUpdateVersions.get(sessionId) !== version) {
      return;
    }
    if (!plan?.exists || !plan.content) {
      return;
    }
    const normalized = parseCopilotPlanContent(plan.content);
    if (normalized.plan.length === 0) {
      return;
    }
    this.emit("liveEvent", {
      type: "plan_updated",
      sessionId,
      turnId: turnId ?? undefined,
      explanation: normalized.explanation,
      plan: normalized.plan,
    });
  }

  private completeActiveTurn(sessionId: string, status: string): void {
    const active = this.activeTurns.get(sessionId);
    const session = this.sessions.get(sessionId);
    if (!active || !session) {
      return;
    }

    for (const [messageId, text] of active.assistantBuffers) {
      const trimmed = text.trim();
      if (
        trimmed.length > 0 &&
        !active.completedAssistantMessageIds.has(messageId)
      ) {
        this.appendAndEmitAssistantMessage(
          session,
          active.turnId,
          trimmed,
          "final_answer",
          messageId,
        );
        active.completedAssistantMessageIds.add(messageId);
      }
    }
    this.activeTurns.delete(sessionId);
    const turn = session.turns.find(
      (candidate) => candidate.id === active.turnId,
    );
    if (turn?.status === "inProgress") {
      this.finishTurn(session, turn, status);
    }
    this.persistEventually(session);
  }

  private appendAndEmitAssistantMessage(
    session: CopilotSessionState,
    turnId: string,
    text: string,
    phase: "commentary" | "final_answer",
    id: string,
  ): void {
    this.appendAssistantMessage(session, turnId, text, phase, id);
    this.emit("liveEvent", {
      type: "assistant_message_completed",
      sessionId: session.thread.id,
      turnId,
      message: { id, text, phase },
    });
  }

  private upsertAndEmitActivity(
    session: CopilotSessionState,
    turnId: string | null,
    activity: AgentSessionActivityDraft,
  ): void {
    const stored = this.upsertActivity(session, activity);
    const { createdAt: _createdAt, seq: _seq, ...draft } = stored;
    this.emit("liveEvent", {
      type: "activity_updated",
      sessionId: session.thread.id,
      turnId: turnId ?? undefined,
      activity: draft,
    });
  }

  private upsertActivity(
    session: CopilotSessionState,
    activity: AgentSessionActivityDraft,
  ): SessionActivity {
    const existing = this.activity(session, activity.id);
    const next = materializeAgentActivityDraft(activity, { createdAt: existing?.createdAt ?? Date.now(),
      seq: existing?.seq ?? this.db.nextSessionSequence(this.providerId, session.thread.id) });
    this.db.putSessionItem(this.providerId, session.thread.id, { kind: "activity", value: next, nativeId: activity.id, authority: "recovery" });
    this.touch(session);
    this.persistEventually(session);
    return next;
  }

  private appendActivityOutput(
    session: CopilotSessionState,
    turnId: string | null,
    activityId: string,
    delta: string,
  ): void {
    const existing = this.activity(session, activityId);
    if (existing?.type === "command" || existing?.type === "tool") {
      this.db.putSessionItem(this.providerId, session.thread.id, { kind: "activity", nativeId: activityId, authority: "recovery",
        value: { ...existing, output: `${existing.output ?? ""}${delta}` } });
      this.touch(session);
      this.persistEventually(session);
    }
    this.emit("liveEvent", {
      type: "activity_output_delta",
      sessionId: session.thread.id,
      turnId: turnId ?? undefined,
      activityId,
      delta,
    });
  }

  private replaceRuntime(
    session: CopilotSessionState,
    next: SessionRuntimeSummary | null,
  ): void {
    if (runtimeSummaryEquals(session.runtime, next)) {
      return;
    }
    session.runtime = next;
    this.touch(session);
    this.emit("liveEvent", {
      type: "runtime_updated",
      sessionId: session.thread.id,
      runtime: next ? { ...next } : null,
    });
    this.persistEventually(session);
  }

  private async handlePermissionRequest(
    sessionId: string,
    request: CopilotSdkPermissionRequest,
  ): Promise<CopilotSdkPermissionResult> {
    if (this.closed) return { kind: "denied-interactively-by-user" };
    if (
      approvalPolicyForSession(this.sessions.get(sessionId), this.allowAll) ===
      "never"
    ) {
      return approveOnce();
    }

    const session = this.sessions.get(sessionId);
    if (!session) {
      return { kind: "user-not-available" };
    }

    const action = buildCopilotPendingAction(session, request);
    this.emit("liveEvent", {
      type: "action_opened",
      action,
    });
    return new Promise<CopilotSdkPermissionResult>((resolve) => {
      this.pendingPermissions.set(action.id, { action, resolve });
      this.persistEventually(session);
    });
  }

  private async handleUserInputRequest(
    sessionId: string,
    request: CopilotSdkUserInputRequest,
  ): Promise<CopilotSdkUserInputResponse> {
    if (this.closed) return { answer: "", wasFreeform: true };
    const session = this.sessions.get(sessionId);
    if (!session) {
      return { answer: "", wasFreeform: true };
    }

    const action = buildCopilotUserInputAction(session, request);
    this.emit("liveEvent", {
      type: "action_opened",
      action,
    });
    return new Promise<CopilotSdkUserInputResponse>((resolve) => {
      this.pendingUserInputs.set(action.id, { action, resolve });
      this.persistEventually(session);
    });
  }

  private async handleElicitationRequest(
    sessionId: string,
    request: CopilotSdkElicitationContext,
  ): Promise<CopilotSdkElicitationResult> {
    if (this.closed) return { action: "cancel" };
    const session = this.sessions.get(sessionId);
    if (!session) {
      return { action: "cancel" };
    }

    const action = buildCopilotElicitationAction(session, request);
    this.emit("liveEvent", {
      type: "action_opened",
      action,
    });
    return new Promise<CopilotSdkElicitationResult>((resolve) => {
      this.pendingElicitations.set(action.id, { action, resolve });
      this.persistEventually(session);
    });
  }

  private resolvePendingPermissionsForSession(
    sessionId: string,
    result: CopilotSdkPermissionResult,
  ): void {
    let resolved = false;
    for (const [actionId, pending] of this.pendingPermissions) {
      if (pending.action.sessionId !== sessionId) {
        continue;
      }
      this.pendingPermissions.delete(actionId);
      this.emit("liveEvent", { type: "action_resolved", sessionId, actionId });
      resolved = true;
      pending.resolve(result);
    }
    if (resolved) {
      this.persistEventually(this.sessions.get(sessionId));
    }
  }

  private resolvePendingUserInputsForSession(
    sessionId: string,
    result: CopilotSdkUserInputResponse,
  ): void {
    let resolved = false;
    for (const [actionId, pending] of this.pendingUserInputs) {
      if (pending.action.sessionId !== sessionId) {
        continue;
      }
      this.pendingUserInputs.delete(actionId);
      this.emit("liveEvent", { type: "action_resolved", sessionId, actionId });
      resolved = true;
      pending.resolve(result);
    }
    if (resolved) {
      this.persistEventually(this.sessions.get(sessionId));
    }
  }

  private resolvePendingElicitationsForSession(
    sessionId: string,
    result: CopilotSdkElicitationResult,
  ): void {
    let resolved = false;
    for (const [actionId, pending] of this.pendingElicitations) {
      if (pending.action.sessionId !== sessionId) {
        continue;
      }
      this.pendingElicitations.delete(actionId);
      this.emit("liveEvent", { type: "action_resolved", sessionId, actionId });
      resolved = true;
      pending.resolve(result);
    }
    if (resolved) {
      this.persistEventually(this.sessions.get(sessionId));
    }
  }

  private appendUserMessage(
    session: CopilotSessionState,
    input: AgentSessionInputItem[],
    id?: string,
  ): SessionMessage {
    return this.appendMessage(session, {
      id,
      clientInputId: id,
      role: "user",
      text: inputDisplayText(input),
      attachments: inputAttachments(input),
    });
  }

  private appendSystemMessage(
    session: CopilotSessionState,
    text: string,
  ): void {
    this.appendMessage(session, {
      role: "system",
      text,
      attachments: [],
    });
  }

  private appendAssistantMessage(
    session: CopilotSessionState,
    turnId: string,
    text: string,
    phase: "commentary" | "final_answer",
    id = `copilot-assistant-${randomUUID()}`,
  ): void {
    const active = this.activeTurns.get(session.thread.id);
    const content = cloneSessionMessageContentBlocks(
      active?.reasoningBlocks ?? [],
    );
    this.appendMessage(session, {
      id,
      role: "assistant",
      text,
      content,
      attachments: [],
      phase,
    });
  }

  private syncDraftAssistantMessages(session: CopilotSessionState, active: ActiveCopilotTurn): void {
    for (const [id, text] of active.assistantBuffers) {
      const previous = this.db.getSessionItem(this.providerId, session.thread.id, id);
      const value: SessionMessage = { id, role: "assistant", text, content: buildAssistantMessageContent(text, active.reasoningBlocks),
        attachments: [], phase: "final_answer", createdAt: previous?.value.createdAt ?? Date.now(),
        seq: previous?.value.seq ?? this.db.nextSessionSequence(this.providerId, session.thread.id) };
      this.db.putSessionItem(this.providerId, session.thread.id, { kind: "message", value, nativeId: id, authority: "recovery" });
    }
  }

  private appendMessage(
    session: CopilotSessionState,
    message: {
      id?: string;
      nativeId?: string;
      clientInputId?: string;
      role: SessionMessage["role"];
      text: string;
      content?: SessionMessageContentBlock[];
      attachments: SessionMessageAttachment[];
      phase?: "commentary" | "final_answer";
    },
  ): SessionMessage {
    const blocks = message.content && message.content.length > 0
      ? message.content
      : [{ type: "text" as const, text: message.text }];
    const next: SessionMessage = {
      id: message.id ?? `copilot-message-${randomUUID()}`,
      role: message.role,
      text: message.text,
      content: blocks,
      attachments: message.attachments,
      phase: message.phase,
      createdAt: Date.now(),
      seq: this.db.nextSessionSequence(this.providerId, session.thread.id),
    };
    const previous = this.db.getSessionItem(this.providerId, session.thread.id, next.id);
    if (previous) { next.seq = previous.value.seq; next.createdAt = previous.value.createdAt; }
    this.db.putSessionItem(this.providerId, session.thread.id, { kind: "message", value: next,
      nativeId: message.nativeId ?? (message.role === "assistant" ? next.id : null), clientInputId: message.clientInputId ?? previous?.clientInputId, authority: "recovery" });
    session.thread.preview = next.text || session.thread.preview;
    this.touch(session);
    return next;
  }

  private finishTurn(
    session: CopilotSessionState,
    turn: TurnRecord,
    status: string,
  ): void {
    turn.status = status;
    turn.completedAt = nowSeconds();
    session.thread.status = { type: status === "completed" ? "idle" : status };
    this.touch(session);
    this.emit("liveEvent", {
      type: "turn_completed",
      sessionId: session.thread.id,
      turnId: turn.id,
      status,
    });
  }

  private async getWritableSession(
    threadId: string,
  ): Promise<CopilotSessionState> {
    await this.ensureStore();
    const existing = this.sessions.get(threadId);
    if (existing) return existing;
    return this.loadSessionMetadata(threadId);
  }

  private touch(session: CopilotSessionState): void {
    session.thread.updatedAt = nowSeconds();
  }

  private async ensureStore(): Promise<void> {
    if (this.closed) throw new Error("Copilot provider is closed.");
    this.storeStarting ??= (async () => {
      this.store ??= await SessionStore.open(this.options.hostStateDir ?? this.options.stateDir
        ?? process.env.SIDEMESH_STATE_DIR ?? nodePath.join(homedir(), ".sidemesh"));
      await this.importLegacyState();
      for (const record of this.db.listProviderSessions(this.providerId)) {
        if (record.archived) this.archivedSessionIds.add(record.id);
        const metadata = record.metadata as Partial<CopilotStateFile["sessions"][number]>;
        if (!metadata.thread) continue;
        const state: CopilotSessionState = { thread: { ...metadata.thread, status: { type: "idle" } },
          turns: (metadata.turns ?? []).map((turn) => ({ ...turn, items: undefined,
            status: isActiveCopilotTurnStatus(turn.status) ? "interrupted" : turn.status })),
          runtime: runtimeWithoutTurnId(normalizeInactiveCopilotRuntime(normalizeStoredRuntime(metadata.runtime ?? null), record.updatedAt / 1000)),
          archived: record.archived, copilotSessionId: record.nativeId,
          copilotSessionCreated: metadata.copilotSessionCreated ?? record.nativeId != null };
        this.sessions.set(record.id, state);
        for (const item of this.db.readSessionItems(this.providerId, record.id)) {
          if (item.kind === "activity" && item.value.status === "in_progress") {
            this.db.putSessionItem(this.providerId, record.id, { ...item, value: normalizeInactiveCopilotActivity(item.value) });
          }
        }
        if (metadata.pendingActions?.length) this.appendSystemMessage(state, interruptedPendingActionMessage(metadata.pendingActions));
        this.saveSession(state);
      }
    })();
    await this.storeStarting;
  }

  private async importLegacyState(): Promise<void> {
    const migration = `copilot-json-v1:${this.providerId}:${this.stateDir}`;
    if (this.db.hasMigration(migration)) return;
    let parsed: CopilotStateFile | undefined;
    for (let attempt = 0; ; attempt++) {
      try {
        parsed = JSON.parse(await readFile(nodePath.join(this.stateDir, "sessions.json"), "utf8")) as CopilotStateFile;
        if (!Array.isArray(parsed.sessions)) throw new Error("Invalid Copilot session migration file");
        break;
      } catch (error) {
        if (isMissingFileError(error)) break;
        if (attempt >= COPILOT_STATE_LOAD_RETRY_DELAYS_MS.length) throw error;
        await sleep(COPILOT_STATE_LOAD_RETRY_DELAYS_MS[attempt]!);
      }
    }
    const archived = new Set(parsed?.archivedSessionIds ?? []);
    const entries: Array<{ session: StoredProviderSession; items: StoredSessionItem[] }> = [];
    for (const item of parsed?.sessions ?? []) {
      if (!item.thread?.id || typeof item.thread.cwd !== "string") throw new Error("Invalid Copilot session identity in migration");
      const state: LegacyCopilotSessionState = { thread: item.thread, messages: item.messages ?? [],
        activities: new Map((item.activities ?? []).map((value) => [value.id, normalizeStoredSessionActivity(value)])),
        turns: item.turns ?? [], runtime: normalizeStoredRuntime(item.runtime ?? null),
        archived: item.archived === true || archived.has(item.thread.id), nextSeq: item.nextSeq ?? 0,
        draftAssistantMessages: new Map((item.draftAssistantMessages ?? []).map((value) => [value.id, normalizeStoredCopilotDraftAssistantMessage(value)])),
        copilotSessionId: item.copilotSessionId ?? null, copilotSessionCreated: item.copilotSessionCreated ?? item.copilotSessionId != null };
      normalizeInactiveCopilotSessionState(state);
      if (item.pendingActions?.length) {
        const text = interruptedPendingActionMessage(item.pendingActions);
        state.messages.push({ id: `copilot-recovery-${randomUUID()}`, role: "system", text, content: [{ type: "text", text }],
          attachments: [], seq: state.nextSeq++, createdAt: Date.now() });
      }
      const items: StoredSessionItem[] = [
        ...state.messages.map((value): StoredSessionItem => ({ kind: "message", value, nativeId: value.role === "assistant" ? value.id : null, authority: "recovery" })),
        ...[...state.activities.values()].map((value): StoredSessionItem => ({ kind: "activity", value, nativeId: value.id, authority: "recovery" })),
      ].sort((a, b) => a.value.seq - b.value.seq);
      entries.push({ session: this.storedSession(state), items });
      archived.delete(state.thread.id);
    }
    for (const id of archived) entries.push({ session: { id, nativeId: id, cwd: "", name: null, preview: "", createdAt: 0, updatedAt: 0, archived: true, metadata: {} }, items: [] });
    this.db.importProviderSessions(migration, this.providerId, entries);
  }

  private storedSession(session: CopilotSessionState): StoredProviderSession {
    const { turns: _turns, ...thread } = session.thread;
    return { id: thread.id, nativeId: session.copilotSessionId, cwd: thread.cwd, name: thread.name ?? null,
      preview: thread.preview, createdAt: thread.createdAt * 1000, updatedAt: thread.updatedAt * 1000,
      archived: session.archived, metadata: { thread, turns: session.turns.map(({ items: _items, ...turn }) => turn),
        runtime: session.runtime, copilotSessionCreated: session.copilotSessionCreated,
        pendingActions: pendingActionsForSession(thread.id, this.pendingPermissions, this.pendingUserInputs, this.pendingElicitations) } };
  }
  private saveSession(session: CopilotSessionState): void {
    this.db.saveProviderSession(this.providerId, this.storedSession(session));
  }
  private async persistSoon(session?: CopilotSessionState): Promise<void> {
    if (session) this.saveSession(session);
    else if (this.store) for (const state of this.sessions.values()) this.saveSession(state);
  }
  private persistEventually(session?: CopilotSessionState): void {
    void this.persistSoon(session).catch((error: unknown) => this.emit("stderr", `Copilot state persistence failed: ${String(error)}`));
  }
  private activity(session: CopilotSessionState, id: string): SessionActivity | undefined {
    const item = this.db.getSessionItem(this.providerId, session.thread.id, id);
    return item?.kind === "activity" ? item.value : undefined;
  }
  private get db(): SessionStore { if (!this.store) throw new Error("Copilot storage has not started"); return this.store; }

  private async listSdkSessionMetadata(): Promise<CopilotSdkSessionMetadata[]> {
    try {
      return (await this.ensureSdkClient()).listSessions?.() ?? [];
    } catch (error) {
      this.emit(
        "stderr",
        error instanceof Error
          ? `Copilot SDK session listing failed: ${error.message}`
          : "Copilot SDK session listing failed.",
      );
      return [];
    }
  }

  private async readSdkSessionMetadata(
    sessionId: string,
  ): Promise<CopilotSdkSessionMetadata | null> {
    const client = await this.ensureSdkClient();
    try {
      const direct = await client.getSessionMetadata?.(sessionId);
      if (direct) {
        return direct;
      }
    } catch {
      // Fall back to listSessions below for SDK versions without direct lookup.
    }
    return (
      (await this.listSdkSessionMetadata()).find(
        (session) => session.sessionId === sessionId,
      ) ?? null
    );
  }

  private async loadSessionMetadata(sessionId: string): Promise<CopilotSessionState> {
    await this.ensureStore();
    const existing = this.sessions.get(sessionId);
    if (existing) return existing;
    const metadata = await this.readSdkSessionMetadata(sessionId);
    if (!metadata) throw new Error(`Unknown Copilot session: ${sessionId}`);
    const state: CopilotSessionState = { thread: sdkSessionToThread(metadata, null, false), turns: [], runtime: null,
      archived: this.archivedSessionIds.has(sessionId), copilotSessionId: sessionId, copilotSessionCreated: true };
    this.sessions.set(sessionId, state);
    this.saveSession(state);
    return state;
  }

}

function displayNameFromModel(model: string): string {
  if (model === "auto") return "Auto";
  return model
    .split(/[-_:\s]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function isMissingFileError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === "ENOENT"
  );
}

function copilotModel(
  model: string,
  options: { isDefault: boolean; sortOrder: number; source: string },
): ModelSummary {
  const auto = model === DEFAULT_SIDEMESH_COPILOT_MODEL;
  return {
    id: `copilot:${model}`,
    model,
    displayName: displayNameFromModel(model),
    description: copilotModelDescription(model),
    defaultReasoningEffort: "medium",
    supportedReasoningEfforts: auto
      ? []
      : [
          {
            reasoningEffort: "low",
            description: "Lower Copilot reasoning effort.",
          },
          {
            reasoningEffort: "medium",
            description: "Default Copilot reasoning effort.",
          },
          {
            reasoningEffort: "high",
            description: "Higher Copilot reasoning effort.",
          },
          {
            reasoningEffort: "xhigh",
            description: "Extra-high Copilot reasoning effort.",
          },
        ],
    reasoningEffortControl: auto ? "provider" : "client",
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: ["text"],
    isDefault: options.isDefault,
    sortOrder: options.sortOrder,
    source: options.source,
  };
}

function sdkCopilotModel(
  model: CopilotSdkModelInfo,
  options: { isDefault: boolean; sortOrder: number },
): ModelSummary {
  const supportsReasoning =
    model.capabilities?.supports?.reasoningEffort === true;
  const reasoningEfforts = supportsReasoning
    ? model.supportedReasoningEfforts?.length
      ? model.supportedReasoningEfforts
      : (["low", "medium", "high", "xhigh"] as CopilotSdkReasoningEffort[])
    : [];
  const multiplier = model.billing?.multiplier;
  const policy = model.policy?.state;
  return {
    id: `copilot:${model.id}`,
    model: model.id,
    displayName: model.name || displayNameFromModel(model.id),
    description: [
      "GitHub Copilot SDK model.",
      multiplier != null ? `Premium multiplier: ${multiplier}x.` : null,
      policy ? `Policy: ${policy}.` : null,
    ]
      .filter((part): part is string => Boolean(part))
      .join(" "),
    defaultReasoningEffort: model.defaultReasoningEffort ?? "medium",
    supportedReasoningEfforts: reasoningEfforts.map((reasoningEffort) => ({
      reasoningEffort,
      description: `${displayNameFromModel(reasoningEffort)} Copilot reasoning effort.`,
    })),
    reasoningEffortControl: supportsReasoning ? "client" : "provider",
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: model.capabilities?.supports?.vision
      ? ["text", "image"]
      : ["text"],
    isDefault: options.isDefault,
    sortOrder: options.sortOrder,
    source: "sdk",
  };
}

function isAvailableSdkModel(model: CopilotSdkModelInfo): boolean {
  return !model.policy?.state || model.policy.state === "enabled";
}

function copilotModelDescription(model: string): string {
  if (model === "auto") {
    return "GitHub Copilot chooses an eligible model for the task through the SDK.";
  }
  if (model.includes("opus")) {
    return "Premium GitHub Copilot model. Use intentionally; Opus-class models can have high premium request multipliers.";
  }
  return "GitHub Copilot model configured for this Sidemesh server.";
}

function readEnvironmentConfiguredCopilotModel(): string | null {
  const envModel =
    process.env.COPILOT_MODEL?.trim() ||
    process.env.COPILOT_PROVIDER_MODEL_ID?.trim() ||
    process.env.COPILOT_PROVIDER_WIRE_MODEL?.trim();
  return envModel || null;
}

function modelForSdk(model: string | null | undefined): string | undefined {
  const trimmed = model?.trim();
  if (!trimmed || trimmed === DEFAULT_SIDEMESH_COPILOT_MODEL) {
    return undefined;
  }
  return trimmed;
}

function reasoningEffortForSdk(
  effort: string | null | undefined,
  model: string | undefined,
): CopilotSdkReasoningEffort | undefined {
  if (!model) {
    return undefined;
  }
  if (
    effort === "low" ||
    effort === "medium" ||
    effort === "high" ||
    effort === "xhigh"
  ) {
    return effort;
  }
  return undefined;
}

type CopilotPlanChangedOperation = "create" | "update" | "delete";

function copilotPlanChangedOperation(
  event: CopilotSdkSessionEvent,
): CopilotPlanChangedOperation | null {
  const data = event.data && typeof event.data === "object"
    ? (event.data as Record<string, unknown>)
    : null;
  const operation = typeof data?.operation === "string"
    ? data.operation
    : null;
  return operation === "create" ||
    operation === "update" ||
    operation === "delete"
    ? operation
    : null;
}

function parseCopilotPlanContent(content: string): {
  explanation?: string;
  plan: LivePlanStep[];
} {
  const explanationParts: string[] = [];
  const plan: LivePlanStep[] = [];

  for (const rawLine of content.split(/\r?\n/u)) {
    const trimmed = rawLine.trim();
    if (!trimmed) {
      continue;
    }

    const checkboxMatch =
      /^\s*(?:[-*+]|	*\d+\.)\s+\[( |x|X|~|-)\]\s+(.+?)\s*$/u.exec(rawLine);
    if (checkboxMatch) {
      const marker = checkboxMatch[1] ?? " ";
      const step = normalizeCopilotPlanLine(checkboxMatch[2] ?? "");
      if (step) {
        plan.push({
          step,
          status:
            marker === "x" || marker === "X"
              ? "completed"
              : marker === "~" || marker === "-"
                ? "in_progress"
                : "pending",
        });
      }
      continue;
    }

    const bulletMatch = /^\s*(?:[-*+]|	*\d+\.)\s+(.+?)\s*$/u.exec(rawLine);
    if (bulletMatch) {
      const normalized = normalizeCopilotPlanStep(bulletMatch[1] ?? "");
      const step = normalized.step;
      if (step) {
        plan.push({ step, status: normalized.status });
      }
      continue;
    }

    if (plan.length === 0) {
      const text = normalizeCopilotPlanLine(trimmed.replace(/^#+\s*/u, ""));
      if (text) {
        explanationParts.push(text);
      }
    }
  }

  const explanation = explanationParts.length > 0
    ? explanationParts.join(" ")
    : undefined;
  return { explanation, plan };
}

function normalizeCopilotPlanStep(value: string): LivePlanStep {
  let step = normalizeCopilotPlanLine(value);
  let status: LivePlanStep["status"] = "pending";

  const leadingMarker =
    /^(?<marker>\u2705|\u2713|\u2714|\u2611|\u2612|\u2717|\u2715|\u23f3|\u231b|\u{1f504}|\u25b6|\u25cb|\u25ef|\u2610)\s+(?<text>.+)$/u.exec(step);
  const marker = leadingMarker?.groups?.marker;
  if (marker) {
    step = normalizeCopilotPlanLine(leadingMarker.groups?.text ?? step);
    status =
      marker === "\u2705" ||
        marker === "\u2713" ||
        marker === "\u2714" ||
        marker === "\u2611"
        ? "completed"
        : marker === "\u23f3" ||
            marker === "\u231b" ||
            marker === "\u{1f504}" ||
            marker === "\u25b6"
          ? "in_progress"
          : "pending";
  }

  const strikethroughMatch = /^~~(?<text>.+?)~~$/u.exec(step);
  if (strikethroughMatch?.groups?.text) {
    step = normalizeCopilotPlanLine(strikethroughMatch.groups.text);
    status = "completed";
  }

  const statusMatch =
    /^(?<text>.+?)\s*(?:[-\u2013\u2014:]|\(|\[)\s*(?<status>done|complete|completed|in progress|started|active|pending|todo|to do|blocked)\s*(?:\)|\])?$/iu.exec(step);
  if (statusMatch?.groups?.text && statusMatch.groups.status) {
    step = normalizeCopilotPlanLine(statusMatch.groups.text);
    const rawStatus = statusMatch.groups.status.toLowerCase();
    status =
      rawStatus === "done" ||
      rawStatus === "complete" ||
      rawStatus === "completed"
        ? "completed"
        : rawStatus === "in progress" ||
            rawStatus === "started" ||
            rawStatus === "active"
          ? "in_progress"
          : "pending";
  }

  return { step, status };
}

function normalizeCopilotPlanLine(value: string): string {
  return value
    .replace(/\*\*/gu, "")
    .replace(/__+/gu, "")
    .replace(/`/gu, "")
    .trim();
}

function buildCopilotProviderWarningEvent(
  sessionId: string,
  event: CopilotSdkSessionEvent,
): {
  type: "provider_warning";
  sessionId: string;
  level: "info" | "warning" | "error";
  code?: string;
  message: string;
  source?: string;
} | null {
  if (event.type === "session.warning") {
    const message = event.data.message.trim();
    if (!message) {
      return null;
    }
    return {
      type: "provider_warning",
      sessionId,
      level: "warning",
      code: event.data.warningType,
      message,
      source: "copilot",
    };
  }
  if (event.type === "session.info") {
    const message = event.data.message.trim();
    if (!message) {
      return null;
    }
    return {
      type: "provider_warning",
      sessionId,
      level: "info",
      code: event.data.infoType,
      message,
      source: "copilot",
    };
  }
  if (event.type === "session.background_tasks_changed") {
    return {
      type: "provider_warning",
      sessionId,
      level: "info",
      code: "background_tasks_changed",
      message: "Background tasks changed",
      source: "copilot",
    };
  }
  if (event.type === "mcp.oauth_required") {
    const serverName = typeof event.data.serverName === "string"
      ? event.data.serverName
      : "unknown";
    return {
      type: "provider_warning",
      sessionId,
      level: "info",
      code: "mcp_oauth_required",
      message: `MCP server "${serverName}" requires OAuth`,
      source: "copilot/mcp",
    };
  }
  if (event.type === "mcp.oauth_completed") {
    const requestId = typeof event.data.requestId === "string"
      ? event.data.requestId
      : "unknown";
    return {
      type: "provider_warning",
      sessionId,
      level: "info",
      code: "mcp_oauth_completed",
      message: `MCP OAuth completed (request ${requestId})`,
      source: "copilot/mcp",
    };
  }
  if (event.type === "session.mcp_servers_loaded") {
    const servers = Array.isArray(event.data.servers) ? event.data.servers : [];
    const errors = servers
      .filter(
        (s: any): s is { name: string; error: string } =>
          typeof s?.error === "string" && s.error.trim().length > 0,
      )
      .map((s) => `${s.name}: ${s.error}`);
    if (errors.length === 0) {
      return null;
    }
    return {
      type: "provider_warning",
      sessionId,
      level: "warning",
      code: "mcp_servers_loaded",
      message: errors.join("\n"),
      source: "copilot/mcp",
    };
  }
  if (event.type === "session.mcp_server_status_changed") {
    const serverName =
      typeof event.data.serverName === "string" ? event.data.serverName : "unknown";
    const status =
      typeof event.data.status === "string" ? event.data.status : "unknown";
    const level = status === "failed" ? "error" : "info";
    return {
      type: "provider_warning",
      sessionId,
      level,
      code: "mcp_server_status_changed",
      message: `MCP server "${serverName}" status: ${status}`,
      source: "copilot/mcp",
    };
  }
  if (event.type === "capabilities.changed") {
    const ui = event.data.ui;
    if (ui && typeof ui === "object") {
      const elicitation = (ui as any).elicitation;
      if (typeof elicitation === "boolean") {
        return {
          type: "provider_warning",
          sessionId,
          level: "info",
          code: "capabilities_changed",
          message: `Elicitation ${elicitation ? "enabled" : "disabled"}`,
          source: "copilot",
        };
      }
    }
    return null;
  }
  return null;
}

function assistantPhase(
  phase: string | undefined,
): "commentary" | "final_answer" {
  return phase === "thinking" || phase === "reasoning"
    ? "commentary"
    : "final_answer";
}

async function sdkAttachments(
  input: AgentSessionInputItem[],
): Promise<
  import("./copilot-sdk-client.js").CopilotSdkMessageOptions["attachments"]
> {
  const attachments: NonNullable<
    import("./copilot-sdk-client.js").CopilotSdkMessageOptions["attachments"]
  > = [];
  for (const item of input) {
    if (item.type === "localImage") {
      attachments.push({
        type: "file",
        path: item.path,
        displayName: nodePath.basename(item.path),
      });
      continue;
    }
    if (item.type === "image") {
      attachments.push(await sdkAttachmentForImage(item.url));
    }
    if (item.type === "file") {
      attachments.push({
        type: item.isDirectory ? "directory" : "file",
        path: item.path,
        displayName: nodePath.basename(item.path),
      });
    }
  }
  return attachments.length > 0 ? attachments : undefined;
}

async function sdkAttachmentForImage(
  url: string,
): Promise<
  NonNullable<
    import("./copilot-sdk-client.js").CopilotSdkMessageOptions["attachments"]
  >[number]
> {
  const inline = inlineImageAttachment(url);
  if (inline) {
    return inline;
  }
  return fetchImageAttachment(url);
}

function inlineImageAttachment(
  url: string,
):
  | NonNullable<
      import("./copilot-sdk-client.js").CopilotSdkMessageOptions["attachments"]
    >[number]
  | null {
  const trimmed = url.trim();
  const match = /^data:([^;,]+)(?:;[^,]*)?;base64,([\s\S]+)$/i.exec(trimmed);
  if (!match) {
    return null;
  }
  const mimeType = match[1]?.trim() || "image/png";
  const data = match[2]?.trim();
  if (!data) {
    throw new Error("Copilot image attachment data URL is missing payload.");
  }
  return {
    type: "blob",
    data,
    mimeType,
    displayName: suggestedInlineImageName(mimeType),
  };
}

async function fetchImageAttachment(
  url: string,
): Promise<
  NonNullable<
    import("./copilot-sdk-client.js").CopilotSdkMessageOptions["attachments"]
  >[number]
> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error(`Unsupported Copilot image URL: ${url}`);
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error(
      `Unsupported Copilot image URL protocol: ${parsed.protocol}`,
    );
  }
  const { response, bytes, finalUrl } = await fetchPublicImage(parsed);
  const mimeType = response.headers
    .get("content-type")!
    .split(";")[0]!
    .trim()
    .toLowerCase();
  return {
    type: "blob",
    data: bytes.toString("base64"),
    mimeType,
    displayName:
      nodePath.basename(finalUrl.pathname) || suggestedInlineImageName(mimeType),
  };
}

const REMOTE_IMAGE_MAX_BYTES = 10 * 1024 * 1024;
const REMOTE_IMAGE_TIMEOUT_MS = 10_000;
const REMOTE_IMAGE_MAX_REDIRECTS = 3;
const blockedImageAddresses = createBlockedImageAddressList();

async function fetchPublicImage(parsed: URL): Promise<{
  response: Response;
  bytes: Buffer;
  finalUrl: URL;
}> {
  let current = parsed;
  for (let redirects = 0; redirects <= REMOTE_IMAGE_MAX_REDIRECTS; redirects += 1) {
    await assertPublicImageUrl(current);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REMOTE_IMAGE_TIMEOUT_MS);
    try {
      const response = await fetch(current, {
        redirect: "manual",
        signal: controller.signal,
      });
      if (isRedirectStatus(response.status)) {
        const location = response.headers.get("location");
        if (!location) {
          throw new Error("Copilot image redirect is missing a Location header.");
        }
        if (redirects === REMOTE_IMAGE_MAX_REDIRECTS) {
          throw new Error("Copilot image URL exceeded the redirect limit.");
        }
        current = new URL(location, current);
        if (current.protocol !== "http:" && current.protocol !== "https:") {
          throw new Error(
            `Unsupported Copilot image URL protocol: ${current.protocol}`,
          );
        }
        continue;
      }
      if (!response.ok) {
        throw new Error(
          `Failed to fetch Copilot image URL: ${response.status} ${response.statusText}`,
        );
      }
      const mimeType = response.headers
        .get("content-type")
        ?.split(";")[0]
        ?.trim()
        .toLowerCase();
      if (!mimeType?.startsWith("image/")) {
        throw new Error("Copilot image URL did not return an image content type.");
      }
      const declaredLength = Number(response.headers.get("content-length"));
      if (
        Number.isFinite(declaredLength) &&
        declaredLength > REMOTE_IMAGE_MAX_BYTES
      ) {
        throw new Error("Copilot image URL exceeds 10 MiB.");
      }
      const bytes = await readBoundedResponseBody(
        response,
        REMOTE_IMAGE_MAX_BYTES,
      );
      return { response, bytes, finalUrl: current };
    } catch (error) {
      if (controller.signal.aborted) {
        throw new Error("Copilot image URL timed out.", { cause: error });
      }
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error("Copilot image URL exceeded the redirect limit.");
}

async function assertPublicImageUrl(url: URL): Promise<void> {
  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  if (
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local")
  ) {
    throw new Error("Copilot image URL must resolve to a public network address.");
  }
  const literalVersion = isIP(hostname);
  const addresses = literalVersion
    ? [{ address: hostname, family: literalVersion }]
    : await lookup(hostname, { all: true, verbatim: true });
  if (
    addresses.length === 0 ||
    addresses.some(({ address, family }) =>
      blockedImageAddresses.check(
        address,
        family === 6 ? "ipv6" : "ipv4",
      ),
    )
  ) {
    throw new Error("Copilot image URL must resolve to a public network address.");
  }
}

async function readBoundedResponseBody(
  response: Response,
  maxBytes: number,
): Promise<Buffer> {
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const result = await reader.read();
    if (result.done) break;
    total += result.value.byteLength;
    if (total > maxBytes) {
      await reader.cancel("response exceeds size limit");
      throw new Error("Copilot image URL exceeds 10 MiB.");
    }
    chunks.push(result.value);
  }
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total);
}

function isRedirectStatus(status: number): boolean {
  return [301, 302, 303, 307, 308].includes(status);
}

function createBlockedImageAddressList(): BlockList {
  const list = new BlockList();
  const ipv4Subnets: Array<[string, number]> = [
    ["0.0.0.0", 8],
    ["10.0.0.0", 8],
    ["100.64.0.0", 10],
    ["127.0.0.0", 8],
    ["169.254.0.0", 16],
    ["172.16.0.0", 12],
    ["192.0.0.0", 24],
    ["192.0.2.0", 24],
    ["192.168.0.0", 16],
    ["198.18.0.0", 15],
    ["198.51.100.0", 24],
    ["203.0.113.0", 24],
    ["224.0.0.0", 4],
    ["240.0.0.0", 4],
  ];
  for (const [address, prefix] of ipv4Subnets) {
    list.addSubnet(address, prefix, "ipv4");
  }
  const ipv6Subnets: Array<[string, number]> = [
    ["::", 128],
    ["::1", 128],
    ["100::", 64],
    ["2001:db8::", 32],
    ["fc00::", 7],
    ["fe80::", 10],
    ["ff00::", 8],
  ];
  for (const [address, prefix] of ipv6Subnets) {
    list.addSubnet(address, prefix, "ipv6");
  }
  return list;
}

function suggestedInlineImageName(mimeType: string): string {
  const normalized = mimeType.trim().toLowerCase();
  const extension = inlineImageExtension(normalized);
  return extension ? `pasted-image.${extension}` : "pasted-image";
}

function inlineImageExtension(mimeType: string): string | null {
  switch (mimeType) {
    case "image/png":
      return "png";
    case "image/jpeg":
      return "jpg";
    case "image/gif":
      return "gif";
    case "image/webp":
      return "webp";
    case "image/bmp":
      return "bmp";
    case "image/tiff":
      return "tiff";
    case "image/avif":
      return "avif";
    case "image/heic":
      return "heic";
    case "image/heif":
      return "heif";
    default:
      return null;
  }
}

function buildCopilotPendingAction(
  session: CopilotSessionState,
  request: CopilotSdkPermissionRequest,
): AgentPendingAction {
  const typed = request as Record<string, any>;
  const actionId = `copilot-permission-${randomUUID()}`;
  const detail = copilotPermissionDetail(typed);
  const canApproveForSession = canApproveCopilotPermissionForSession(typed);
  return {
    id: actionId,
    sessionId: session.thread.id,
    kind: copilotPendingActionKind(request.kind),
    title: copilotPermissionTitle(request.kind),
    detail,
    requestedAt: Date.now(),
    canApprove: true,
    canApproveForSession,
    canDecline: true,
    sessionTitle: session.thread.name ?? session.thread.preview,
    cwd: session.thread.cwd,
    approval: {
      category: copilotApprovalCategory(request.kind),
      operation: `copilot.${String(request.kind ?? "unknown")}`,
      summary: copilotPermissionSummary(typed),
      detail,
      cwd: session.thread.cwd,
      supportedScopes: canApproveForSession ? ["once", "session"] : ["once"],
      suggestedScope: "once",
      targets: copilotApprovalTargets(typed),
      providerOptions: [
        { id: "approve-once", label: "Allow once", kind: "allow_once" },
        ...(canApproveForSession
          ? [{
              id: "approve-for-session",
              label: "Allow for session",
              kind: "allow_always" as const,
            }]
          : []),
        { id: "reject", label: "Reject", kind: "reject_once" },
      ],
    },
    providerRequestId: actionId,
    providerRequestKind: `copilot/${request.kind}/requestPermission`,
    providerPayload: request,
  };
}

function buildCopilotUserInputAction(
  session: CopilotSessionState,
  request: CopilotSdkUserInputRequest,
): AgentPendingAction {
  const actionId = `copilot-user-input-${randomUUID()}`;
  const question = request.question?.trim() || "Agent question";
  const choices = (request.choices ?? []).filter(
    (choice: string | undefined): choice is string =>
      typeof choice === "string" && choice.trim().length > 0,
  );
  return {
    id: actionId,
    sessionId: session.thread.id,
    kind: "user_input",
    title: "Agent question",
    detail: question,
    requestedAt: Date.now(),
    canApprove: false,
    canApproveForSession: false,
    canDecline: false,
    sessionTitle: session.thread.name ?? session.thread.preview,
    cwd: session.thread.cwd,
    userInput: {
      question,
      choices,
      allowFreeform: request.allowFreeform !== false,
    },
    providerRequestId: actionId,
    providerRequestKind: "copilot/ask_user",
    providerPayload: request,
  };
}

function buildCopilotElicitationAction(
  session: CopilotSessionState,
  request: CopilotSdkElicitationContext,
): AgentPendingAction {
  const actionId = `copilot-elicitation-${randomUUID()}`;
  const fields = elicitationFields(request.requestedSchema);
  const message = request.message?.trim() || "Structured input requested";
  return {
    id: actionId,
    sessionId: session.thread.id,
    kind: "elicitation",
    title: request.mode === "url" ? "Browser sign-in required" : "Structured input requested",
    detail: message,
    requestedAt: Date.now(),
    canApprove: false,
    canApproveForSession: false,
    canDecline: request.mode !== "url" || Boolean(request.url),
    sessionTitle: session.thread.name ?? session.thread.preview,
    cwd: session.thread.cwd,
    elicitation: {
      mode: request.mode === "url" ? "url" : "form",
      message,
      ...(request.elicitationSource ? { source: request.elicitationSource } : {}),
      ...(request.url ? { url: request.url } : {}),
      fields,
    },
    providerRequestId: actionId,
    providerRequestKind: "copilot/elicitation",
    providerPayload: request,
  };
}

function copilotPendingActionKind(kind: unknown): AgentPendingAction["kind"] {
  if (kind === "shell") return "command";
  if (kind === "write") return "file_change";
  return "permissions";
}

function copilotApprovalCategory(
  kind: unknown,
): NonNullable<AgentPendingAction["approval"]>["category"] {
  switch (kind) {
    case "shell":
      return "command";
    case "write":
      return "file_change";
    case "read":
      return "filesystem";
    case "url":
      return "network";
    case "mcp":
    case "custom-tool":
      return "tool";
    case "memory":
      return "memory";
    case "hook":
      return "hook";
    default:
      return "permissions";
  }
}

function copilotPermissionTitle(kind: unknown): string {
  switch (kind) {
    case "shell":
      return "Command approval";
    case "write":
      return "File change approval";
    case "read":
      return "File read approval";
    case "url":
      return "Network approval";
    case "mcp":
      return "MCP tool approval";
    case "custom-tool":
      return "Tool approval";
    case "memory":
      return "Memory approval";
    case "hook":
      return "Hook approval";
    default:
      return "Permission request";
  }
}

function copilotPermissionDetail(request: Record<string, any>): string {
  if (typeof request.fullCommandText === "string") {
    return request.fullCommandText;
  }
  if (
    typeof request.diff === "string" &&
    typeof request.fileName === "string"
  ) {
    return `${request.intention ?? "Copilot wants to edit a file."}\n\n${request.fileName}\n\n${request.diff}`;
  }
  if (typeof request.path === "string") {
    return `${request.intention ?? "Copilot wants to read a path."}\n\n${request.path}`;
  }
  if (typeof request.url === "string") {
    return `${request.intention ?? "Copilot wants network access."}\n\n${request.url}`;
  }
  if (typeof request.toolTitle === "string") {
    return `${request.toolTitle}\n\n${JSON.stringify(request.args ?? {}, null, 2)}`;
  }
  if (typeof request.toolName === "string") {
    return `${request.toolName}\n\n${JSON.stringify(request.args ?? request.toolArgs ?? {}, null, 2)}`;
  }
  if (typeof request.fact === "string") {
    return request.fact;
  }
  return JSON.stringify(request, null, 2);
}

function copilotPermissionSummary(request: Record<string, any>): string {
  if (typeof request.intention === "string" && request.intention.length > 0) {
    return request.intention;
  }
  if (typeof request.toolTitle === "string" && request.toolTitle.length > 0) {
    return request.toolTitle;
  }
  if (
    typeof request.toolDescription === "string" &&
    request.toolDescription.length > 0
  ) {
    return request.toolDescription;
  }
  if (
    typeof request.hookMessage === "string" &&
    request.hookMessage.length > 0
  ) {
    return request.hookMessage;
  }
  return copilotPermissionTitle(request.kind);
}

function copilotApprovalTargets(
  request: Record<string, any>,
): NonNullable<AgentPendingAction["approval"]>["targets"] {
  switch (request.kind) {
    case "shell": {
      const command =
        typeof request.fullCommandText === "string"
          ? request.fullCommandText
          : "";
      if (!command) {
        return unknownApprovalTarget("Copilot shell request");
      }
      return [
        {
          type: "command",
          command,
          identifiers: copilotCommandIdentifiers(request),
          possiblePaths: stringArray(request.possiblePaths),
          possibleUrls: copilotPossibleUrls(request),
          intention:
            typeof request.intention === "string"
              ? request.intention
              : undefined,
          warning:
            typeof request.warning === "string" ? request.warning : undefined,
        },
      ];
    }
    case "write": {
      const path = typeof request.fileName === "string" ? request.fileName : "";
      if (!path) {
        return unknownApprovalTarget("Copilot file write request");
      }
      return [
        {
          type: "file",
          path,
          access: "write",
          diff: typeof request.diff === "string" ? request.diff : undefined,
          intention:
            typeof request.intention === "string"
              ? request.intention
              : undefined,
        },
      ];
    }
    case "read": {
      const path = typeof request.path === "string" ? request.path : "";
      if (!path) {
        return unknownApprovalTarget("Copilot file read request");
      }
      return [
        {
          type: "file",
          path,
          access: "read",
          intention:
            typeof request.intention === "string"
              ? request.intention
              : undefined,
        },
      ];
    }
    case "url": {
      const url = typeof request.url === "string" ? request.url : "";
      if (!url) {
        return unknownApprovalTarget("Copilot network request");
      }
      return [
        {
          type: "url",
          url,
          intention:
            typeof request.intention === "string"
              ? request.intention
              : undefined,
        },
      ];
    }
    case "mcp": {
      const name = typeof request.toolName === "string" ? request.toolName : "";
      if (!name) {
        return unknownApprovalTarget("Copilot MCP tool request");
      }
      return [
        {
          type: "tool",
          name,
          title:
            typeof request.toolTitle === "string"
              ? request.toolTitle
              : undefined,
          serverName:
            typeof request.serverName === "string"
              ? request.serverName
              : undefined,
          readOnly:
            typeof request.readOnly === "boolean"
              ? request.readOnly
              : undefined,
          args: request.args,
        },
      ];
    }
    case "custom-tool": {
      const name = typeof request.toolName === "string" ? request.toolName : "";
      if (!name) {
        return unknownApprovalTarget("Copilot custom tool request");
      }
      return [
        {
          type: "tool",
          name,
          description:
            typeof request.toolDescription === "string"
              ? request.toolDescription
              : undefined,
          args: request.args,
        },
      ];
    }
    case "memory":
      return [
        {
          type: "memory",
          fact: typeof request.fact === "string" ? request.fact : undefined,
          subject:
            typeof request.subject === "string" ? request.subject : undefined,
          action:
            typeof request.action === "string" ? request.action : undefined,
          direction:
            typeof request.direction === "string"
              ? request.direction
              : undefined,
          reason:
            typeof request.reason === "string" ? request.reason : undefined,
          citations:
            typeof request.citations === "string"
              ? request.citations
              : undefined,
        },
      ];
    case "hook":
      return [
        {
          type: "hook",
          toolName:
            typeof request.toolName === "string" ? request.toolName : undefined,
          message:
            typeof request.hookMessage === "string"
              ? request.hookMessage
              : undefined,
          args: request.toolArgs,
        },
      ];
    default:
      return unknownApprovalTarget(String(request.kind ?? "unknown"));
  }
}

function unknownApprovalTarget(
  label: string,
): NonNullable<AgentPendingAction["approval"]>["targets"] {
  return [{ type: "unknown", label }];
}

function copilotCommandIdentifiers(request: Record<string, any>): string[] {
  if (!Array.isArray(request.commands)) {
    return [];
  }
  return request.commands
    .map((command) =>
      command && typeof command === "object"
        ? (command as Record<string, unknown>).identifier
        : null,
    )
    .filter(
      (identifier): identifier is string =>
        typeof identifier === "string" && identifier.length > 0,
    );
}

function copilotPossibleUrls(request: Record<string, any>): string[] {
  if (!Array.isArray(request.possibleUrls)) {
    return [];
  }
  return request.possibleUrls
    .map((entry) => {
      if (typeof entry === "string") {
        return entry;
      }
      if (entry && typeof entry === "object") {
        const url = (entry as Record<string, unknown>).url;
        return typeof url === "string" ? url : null;
      }
      return null;
    })
    .filter((url): url is string => typeof url === "string" && url.length > 0);
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter(
        (item): item is string => typeof item === "string" && item.length > 0,
      )
    : [];
}

function canApproveCopilotPermissionForSession(
  request: Record<string, any>,
): boolean {
  if (request.kind === "shell" || request.kind === "write") {
    return request.canOfferSessionApproval === true;
  }
  if (request.kind === "mcp") {
    return (
      typeof request.serverName === "string" && request.serverName.length > 0
    );
  }
  if (request.kind === "custom-tool") {
    return typeof request.toolName === "string" && request.toolName.length > 0;
  }
  return ["read", "memory"].includes(request.kind);
}

function buildCopilotPermissionResult(
  decision: NormalizedPendingActionDecision | null,
  request: unknown,
): CopilotSdkPermissionResult | null {
  if (!decision) {
    return null;
  }
  if (decision.decision === "approve" && decision.scope === "once") {
    return approveOnce();
  }
  if (decision.decision === "approve" && decision.scope === "session") {
    const approval = copilotSessionApproval(request);
    return approval ? { kind: "approve-for-session", approval } : approveOnce();
  }
  if (decision.decision === "decline" || decision.decision === "cancel") {
    return rejectPermission();
  }
  return null;
}

function buildCopilotProviderOptionResult(
  action: AgentPendingAction,
  optionId: string,
): CopilotSdkPermissionResult | null {
  if (!action.approval?.providerOptions?.some((option) => option.id === optionId)) {
    return null;
  }
  if (optionId === "approve-once") {
    return approveOnce();
  }
  if (optionId === "approve-for-session") {
    const approval = copilotSessionApproval(action.providerPayload);
    return approval ? { kind: "approve-for-session", approval } : approveOnce();
  }
  return optionId === "reject" ? rejectPermission() : null;
}

function isCopilotUserInputResponse(
  value: PendingActionResponseInput,
): value is PendingActionUserInputResponse {
  return (
    !!value &&
    typeof value === "object" &&
    "answer" in value &&
    typeof value.answer === "string" &&
    "wasFreeform" in value &&
    typeof value.wasFreeform === "boolean"
  );
}

function isCopilotElicitationResponse(
  value: PendingActionResponseInput,
): value is PendingActionElicitationResponse {
  if (!value || typeof value !== "object" || !("action" in value)) {
    return false;
  }
  return (
    value.action === "accept" ||
    value.action === "decline" ||
    value.action === "cancel"
  );
}

function copilotSessionApproval(
  request: unknown,
): CopilotSessionApproval | null {
  if (!request || typeof request !== "object") {
    return null;
  }
  const typed = request as Record<string, any>;
  switch (typed.kind) {
    case "shell": {
      const commandIdentifiers = Array.isArray(typed.commands)
        ? typed.commands
            .map((command: Record<string, unknown>) => command.identifier)
            .filter(
              (identifier: unknown): identifier is string =>
                typeof identifier === "string" && identifier.length > 0,
            )
        : [];
      return commandIdentifiers.length > 0
        ? { kind: "commands", commandIdentifiers }
        : null;
    }
    case "read":
      return { kind: "read" };
    case "write":
      return { kind: "write" };
    case "mcp":
      if (
        typeof typed.serverName !== "string" ||
        typed.serverName.length === 0
      ) {
        return null;
      }
      return {
        kind: "mcp",
        serverName: typed.serverName,
        toolName: typeof typed.toolName === "string" ? typed.toolName : null,
      };
    case "memory":
      return { kind: "memory" };
    case "custom-tool":
      if (typeof typed.toolName !== "string" || typed.toolName.length === 0) {
        return null;
      }
      return {
        kind: "custom-tool",
        toolName: typed.toolName,
      };
    default:
      return null;
  }
}

function sdkSessionToThread(
  session: CopilotSdkSessionMetadata,
  local: CopilotSessionState | null | undefined,
  includeTurns: boolean,
): ThreadRecord {
  const cwd =
    session.context?.workingDirectory ?? local?.thread.cwd ?? process.cwd();
  return {
    id: session.sessionId,
    name: local?.thread.name ?? session.summary ?? null,
    preview: local?.thread.preview ?? session.summary ?? cwd,
    cwd,
    createdAt: secondsFromDate(session.startTime, nowSeconds()),
    updatedAt: secondsFromDate(session.modifiedTime, nowSeconds()),
    source: "copilot",
    path: null,
    status: local?.thread.status
      ? { ...local.thread.status }
      : { type: "idle" },
    gitInfo: {
      sha: null,
      branch: session.context?.branch ?? null,
      originUrl: session.context?.repository
        ? `https://github.com/${session.context.repository}`
        : null,
      gitCommonDir: null,
    },
    turns: includeTurns ? (local?.turns.map(cloneTurn) ?? []) : undefined,
  };
}

function parseSdkSessionEvents(events: CopilotSdkSessionEvent[], _cwd: string): {
  messages: SessionMessage[]; activities: SessionActivity[]; runtime: SessionRuntimeSummary | null; nextSeq: number;
} {
  const messages: SessionMessage[] = [];
  const activities = new Map<string, SessionActivity>();
  const thoughts = new Map<string, SessionMessageContentBlockThinking>();
  let seq = 0;
  let runtime: SessionRuntimeSummary | null = null;
  for (const event of events) {
    const timestamp = millisFromDateLike(event.timestamp) ?? Date.now();
    const data = asRecord(event.data) ?? {};
    if (event.agentId && (event.type.startsWith("assistant.") || event.type === "user.message" || event.type === "session.error")) continue;
    if (event.type === "session.model_change") {
      runtime = withRuntimeMetadata(runtime, { model: event.data.newModel, updatedAt: timestamp });
    } else if (event.type === "session.mode_changed") {
      const mode = normalizeCopilotSessionMode(event.data.newMode);
      if (mode) {
        runtime = withRuntimeMetadata(runtime, { mode, updatedAt: timestamp });
        const draft = buildCopilotModeChangeActivity({ activityId: copilotModeActivityId(event), turnId: null, newMode: mode, previousMode: event.data.previousMode });
        activities.set(draft.id, materializeAgentActivityDraft(draft, { createdAt: timestamp, seq: seq++ }));
      }
    } else if (event.type === "session.usage_info" || event.type === "assistant.usage"
      || event.type === "session.compaction_start" || event.type === "session.compaction_complete") {
      runtime = applyCopilotRuntimeEvent(runtime, event, timestamp);
      const draft = copilotCompactionActivity(runtime, event);
      if (draft) activities.set(draft.id, materializeAgentActivityDraft(draft,
        { createdAt: activities.get(draft.id)?.createdAt ?? timestamp, seq: activities.get(draft.id)?.seq ?? seq++ }));
    } else if (event.type === "user.message") {
      messages.push({ id: event.id, role: "user", text: event.data.content, content: [{ type: "text", text: event.data.content }],
        attachments: copilotHistoryAttachments(event.data.attachments), createdAt: timestamp, seq: seq++ });
    } else if (event.type === "session.error") {
      messages.push({ id: event.id, role: "system", text: event.data.message, content: [{ type: "text", text: event.data.message }], attachments: [], createdAt: timestamp, seq: seq++ });
    } else if (event.type === "assistant.reasoning" || event.type === "assistant.reasoning_delta") {
      const id = event.data.reasoningId ?? event.id;
      const previous = thoughts.get(id)?.thinking ?? "";
      thoughts.set(id, { type: "thinking", thinking: event.type === "assistant.reasoning" ? event.data.content : previous + event.data.deltaContent,
        reasoningId: id, summary: false });
    } else if (event.type === "assistant.message") {
      const text = event.data.content.trim();
      const reasoning = [...thoughts.values()];
      if (!reasoning.length && event.data.reasoningText) reasoning.push({ type: "thinking", thinking: event.data.reasoningText, summary: false });
      if (text || reasoning.length) messages.push({ id: event.data.messageId || event.id, role: "assistant", text,
        content: buildAssistantMessageContent(text, reasoning), attachments: [], createdAt: timestamp, seq: seq++, phase: assistantPhase(event.data.phase) });
      thoughts.clear();
      if (event.data.model) runtime = withRuntimeMetadata(runtime, { model: event.data.model, updatedAt: timestamp });
    } else if (event.type === "tool.execution_start") {
      const draft: AgentSessionActivityDraft = { id: event.data.toolCallId, type: "tool", turnId: null, status: "in_progress",
        toolName: copilotToolName(event.data.toolName), title: formatCopilotToolCommand(event.data.toolName, event.data.arguments),
        args: event.data.arguments ?? null, output: null, result: null, isError: null,
        semantic: inferCopilotToolSemantic(event.data.toolName, event.data.arguments, null) };
      activities.set(draft.id, materializeAgentActivityDraft(draft, { createdAt: timestamp, seq: seq++ }));
    } else if (event.type === "tool.execution_partial_result" || event.type === "tool.execution_progress") {
      const previous = activities.get(event.data.toolCallId);
      if (previous?.type === "tool" || previous?.type === "command") activities.set(previous.id, { ...previous,
        output: (previous.output ?? "") + (event.type === "tool.execution_partial_result" ? event.data.partialOutput : `${event.data.progressMessage}\n`) });
    } else if (event.type === "tool.execution_complete") {
      const previous = activities.get(event.data.toolCallId);
      const tool = previous?.type === "tool" ? previous : null;
      const draft: AgentSessionActivityDraft = { id: event.data.toolCallId, type: "tool", turnId: null,
        status: event.data.success ? "completed" : "failed", toolName: tool?.toolName ?? copilotToolName(data.toolName),
        title: tool?.title ?? formatCopilotToolCommand(data.toolName, data.arguments ?? event.data.result ?? event.data.error),
        args: tool?.args ?? data.arguments ?? null, output: extractCopilotToolOutput(event.data.result ?? event.data.error) ?? tool?.output ?? null,
        result: event.data.result ?? event.data.error ?? null, isError: !event.data.success,
        semantic: mergeCopilotToolSemantic(tool, inferCopilotToolSemantic(data.toolName, tool?.args ?? data.arguments, event.data.result ?? event.data.error ?? null)) };
      activities.set(draft.id, materializeAgentActivityDraft(draft, { createdAt: previous?.createdAt ?? timestamp, seq: previous?.seq ?? seq++ }));
    } else if (event.type === "subagent.started" || event.type === "subagent.completed" || event.type === "subagent.failed") {
      const id = event.data.toolCallId ?? event.id;
      const previous = activities.get(id);
      const duration = event.type === "subagent.completed" && typeof event.data.durationMs === "number" ? ` (${Math.round(event.data.durationMs / 1000)}s)` : "";
      const draft: AgentSessionActivityDraft = { id, type: "tool", turnId: null,
        status: event.type === "subagent.started" ? "in_progress" : event.type === "subagent.failed" ? "failed" : "completed",
        toolName: event.data.agentName ?? "subagent", title: `${event.data.agentDisplayName ?? event.data.agentName ?? "Subagent"}${duration}`,
        args: null, output: null, result: event.type === "subagent.failed" ? { type: "error", summary: event.data.error ?? "Subagent failed" }
          : event.type === "subagent.completed" ? { type: "success", summary: "Subagent completed" } : null,
        isError: event.type === "subagent.failed", semantic: null };
      activities.set(id, materializeAgentActivityDraft(draft, { createdAt: previous?.createdAt ?? timestamp, seq: previous?.seq ?? seq++ }));
    }
  }
  return { messages, activities: [...activities.values()].sort((a, b) => a.seq - b.seq), runtime, nextSeq: seq };
}

function copilotHistoryAttachments(attachments: Extract<CopilotSdkSessionEvent, { type: "user.message" }>["data"]["attachments"]): SessionMessageAttachment[] {
  return (attachments ?? []).flatMap((item): SessionMessageAttachment[] => {
    if (item.type === "file") return [{ type: item.mimeType?.startsWith("image/") || /\.(png|jpe?g|gif|webp)$/i.test(item.path) ? "localImage" : "file", path: item.path }];
    if (item.type === "directory") return [{ type: "file", path: item.path }];
    if (item.type === "selection") return [{ type: "file", path: item.filePath }];
    if (item.type === "blob" && item.data) return [{ type: item.mimeType.startsWith("image/") ? "image" : "file", url: `data:${item.mimeType};base64,${item.data}` }];
    if (item.type === "github_reference") return [{ type: "file", url: item.url }];
    return [];
  });
}

function copilotCompactionActivity(runtime: SessionRuntimeSummary | null, event: CopilotSdkSessionEvent): AgentSessionActivityDraft | null {
  if (event.type !== "session.compaction_start" && event.type !== "session.compaction_complete") return null;
  return { id: `copilot-compaction:${runtime?.telemetry?.compaction?.startedAt ?? event.id}`, type: "context_compaction", turnId: null,
    status: event.type === "session.compaction_start" ? "in_progress" : event.data.success ? "completed" : "failed",
    ...(event.type === "session.compaction_complete" && event.data.summaryContent ? { summary: event.data.summaryContent } : {}) };
}

function formatCopilotToolCommand(toolName: unknown, args: unknown): string {
  const name = copilotToolName(toolName);
  if (!args || typeof args !== "object") return name;
  return `${name} ${JSON.stringify(args)}`;
}

function copilotToolName(value: unknown): string {
  return typeof value === "string" && value.length > 0 ? value : "tool";
}

function extractCopilotToolOutput(result: unknown): string | null {
  const clean = stripSessionAttachments(result);
  if (!clean || typeof clean !== "object") return null;
  const data = clean as Record<string, unknown>;
  const content = data.detailedContent ?? data.content ?? data.message;
  return typeof content === "string" ? content : JSON.stringify(clean);
}

function copilotModeActivityId(
  event: CopilotSdkSessionEvent,
  fallbackSeq?: number,
): string {
  if (typeof event.id === "string" && event.id.trim().length > 0) {
    return `copilot-mode:${event.id.trim()}`;
  }
  if (typeof fallbackSeq === "number") {
    return `copilot-mode:${fallbackSeq}`;
  }
  const stamp = millisFromDateLike(event.timestamp) ?? Date.now();
  return `copilot-mode:${stamp}`;
}

function buildCopilotModeChangeActivity(options: {
  activityId: string;
  turnId: string | null;
  newMode: CopilotSdkSessionMode;
  previousMode: unknown;
}): AgentSessionActivityDraft {
  const previousMode = normalizeCopilotSessionMode(options.previousMode);
  return {
    id: options.activityId,
    type: "tool",
    turnId: options.turnId,
    status: "completed",
    toolName: "session.mode",
    title: `Switched to ${formatCopilotModeLabel(options.newMode)} mode`,
    args: {
      previousMode,
      newMode: options.newMode,
    },
    output: null,
    result: {
      mode: options.newMode,
    },
    isError: false,
    semantic: {
      category: "session",
      action: "mode_change",
      targets: [{ type: "mode", value: options.newMode }],
    },
  };
}

function inferCopilotToolSemantic(
  toolName: unknown,
  args: unknown,
  result: unknown,
): ToolActivitySemantic {
  const normalizedName = copilotToolName(toolName).toLowerCase();
  const typedArgs = asRecord(args);
  const typedResult = asRecord(result);
  const fileTargets = collectFileTargets(typedArgs, typedResult);
  const url = readFirstString(
    typedArgs,
    ["url", "uri", "href", "targetUrl"],
    typedResult,
  );
  const query = readFirstString(
    typedArgs,
    ["query", "pattern", "text", "needle"],
    typedResult,
  );
  const command = readFirstString(
    typedArgs,
    ["command", "cmd", "fullCommandText", "shellCommand"],
    typedResult,
  );

  if (
    normalizedName === "view" ||
    normalizedName === "read" ||
    normalizedName === "open" ||
    normalizedName === "cat" ||
    normalizedName === "read_file"
  ) {
    return {
      category: "filesystem",
      action: "read",
      targets: fileTargets.map((path) => ({
        type: "file",
        path,
        access: "read",
        role: "target",
      })),
    };
  }

  if (
    normalizedName === "glob" ||
    normalizedName === "ls" ||
    normalizedName === "list" ||
    normalizedName === "dir" ||
    normalizedName === "find"
  ) {
    return {
      category: "filesystem",
      action: "list",
      targets: [
        ...fileTargets.map((path) => ({
          type: "file" as const,
          path,
          role: "target" as const,
        })),
        ...(query ? [{ type: "query" as const, value: query }] : []),
      ],
    };
  }

  if (
    normalizedName === "grep" ||
    normalizedName === "search" ||
    normalizedName === "rg" ||
    normalizedName === "find_in_files"
  ) {
    return {
      category: "filesystem",
      action: "search",
      targets: [
        ...(query ? [{ type: "query" as const, value: query }] : []),
        ...fileTargets.map((path) => ({
          type: "file" as const,
          path,
          role: "target" as const,
        })),
      ],
    };
  }

  if (
    normalizedName === "edit" ||
    normalizedName === "write" ||
    normalizedName === "replace" ||
    normalizedName === "create" ||
    normalizedName === "delete" ||
    normalizedName === "move" ||
    normalizedName === "rename" ||
    normalizedName === "apply_patch"
  ) {
    return {
      category: "filesystem",
      action: "write",
      targets: fileTargets.map((path) => ({
        type: "file",
        path,
        access: "write",
        role: "target",
      })),
    };
  }

  if (
    normalizedName === "fetch" ||
    normalizedName === "open_url" ||
    normalizedName === "openurl" ||
    normalizedName === "request" ||
    normalizedName === "browse"
  ) {
    return {
      category: "network",
      action: "fetch",
      targets: url ? [{ type: "url", url, role: "target" }] : [],
    };
  }

  if (normalizedName === "web_search" || normalizedName === "search_web") {
    return {
      category: "network",
      action: "search",
      targets: [
        ...(query ? [{ type: "query" as const, value: query }] : []),
        ...(url ? [{ type: "url" as const, url, role: "target" as const }] : []),
      ],
    };
  }

  if (
    normalizedName === "run" ||
    normalizedName === "shell" ||
    normalizedName === "bash" ||
    normalizedName === "terminal" ||
    normalizedName === "exec" ||
    normalizedName === "command"
  ) {
    return {
      category: "command",
      action: "invoke",
      targets: command ? [{ type: "command", command }] : [],
    };
  }

  return {
    category: "unknown",
    action: "invoke",
    targets: [
      ...(query ? [{ type: "query" as const, value: query }] : []),
      ...(url ? [{ type: "url" as const, url, role: "target" as const }] : []),
      ...fileTargets.map((path) => ({
        type: "file" as const,
        path,
        role: "target" as const,
      })),
    ],
  };
}

function mergeCopilotToolSemantic(
  existing: ToolActivity | null,
  inferred: ToolActivitySemantic,
): ToolActivitySemantic {
  const inferredCategory =
    inferred.category === "unknown" && existing?.semantic
      ? existing.semantic.category
      : inferred.category;
  const inferredAction =
    inferred.category === "unknown" &&
    inferred.action === "invoke" &&
    existing?.semantic
      ? existing.semantic.action
      : inferred.action;
  return {
    category: inferredCategory,
    action: inferredAction,
    targets: mergeSemanticTargets(existing?.semantic?.targets ?? [], inferred.targets),
  };
}

function formatCopilotModeLabel(mode: CopilotSdkSessionMode): string {
  switch (mode) {
    case "interactive":
      return "interactive";
    case "plan":
      return "plan";
    case "autopilot":
      return "autopilot";
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function collectFileTargets(
  args: Record<string, unknown> | null,
  result: Record<string, unknown> | null,
): string[] {
  const values = new Set<string>();
  for (const source of [args, result]) {
    if (!source) {
      continue;
    }
    for (const key of [
      "path",
      "paths",
      "file",
      "fileName",
      "filename",
      "targetPath",
      "cwd",
      "directory",
      "dir",
    ]) {
      const raw = source[key];
      if (typeof raw === "string" && raw.trim().length > 0) {
        values.add(raw.trim());
        continue;
      }
      if (Array.isArray(raw)) {
        for (const entry of raw) {
          if (typeof entry === "string" && entry.trim().length > 0) {
            values.add(entry.trim());
          }
        }
      }
    }
  }
  return [...values];
}

function readFirstString(
  first: Record<string, unknown> | null,
  keys: string[],
  second?: Record<string, unknown> | null,
): string | null {
  for (const source of [first, second ?? null]) {
    if (!source) {
      continue;
    }
    for (const key of keys) {
      const value = source[key];
      if (typeof value === "string" && value.trim().length > 0) {
        return value.trim();
      }
    }
  }
  return null;
}

function mergeSemanticTargets(
  existing: ToolActivitySemanticTarget[],
  incoming: ToolActivitySemanticTarget[],
): ToolActivitySemanticTarget[] {
  if (incoming.length === 0) {
    return existing;
  }
  const merged = new Map<string, ToolActivitySemanticTarget>();
  for (const target of existing) {
    merged.set(semanticTargetKey(target), target);
  }
  for (const target of incoming) {
    const key = semanticTargetKey(target);
    merged.set(key, mergeSemanticTarget(merged.get(key), target));
  }
  return [...merged.values()];
}

function mergeSemanticTarget(
  existing: ToolActivitySemanticTarget | undefined,
  incoming: ToolActivitySemanticTarget,
): ToolActivitySemanticTarget {
  if (!existing || existing.type !== incoming.type) {
    return incoming;
  }
  switch (incoming.type) {
    case "file":
      if (existing.type !== "file") {
        return incoming;
      }
      return {
        ...incoming,
        access: incoming.access ?? existing.access,
        role: incoming.role ?? existing.role,
      };
    case "url":
      if (existing.type !== "url") {
        return incoming;
      }
      return {
        ...incoming,
        role: incoming.role ?? existing.role,
      };
    default:
      return incoming;
  }
}

function semanticTargetKey(target: ToolActivitySemanticTarget): string {
  switch (target.type) {
    case "file":
      return `file:${target.path}`;
    case "url":
      return `url:${target.url}`;
    case "query":
      return `query:${target.value}`;
    case "mode":
      return `mode:${target.value}`;
    case "command":
      return `command:${target.command}`;
    case "unknown":
      return `unknown:${target.label}`;
  }
}

function secondsFromDate(
  value: Date | string | undefined,
  fallback: number,
): number {
  const millis = millisFromDateLike(value);
  return millis == null ? fallback : millis / 1000;
}

function millisFromDateLike(value: Date | string | undefined): number | null {
  if (!value) return null;
  const millis = value instanceof Date ? value.getTime() : Date.parse(value);
  return Number.isFinite(millis) ? millis : null;
}

function withRuntimeMetadata(
  runtime: SessionRuntimeSummary | null,
  patch: Partial<SessionRuntimeSummary>,
): SessionRuntimeSummary {
  return {
    ...(runtime ?? {}),
    modelProvider: "copilot",
    ...patch,
  };
}

function applyCopilotRuntimeEvent(
  runtime: SessionRuntimeSummary | null,
  event: CopilotSdkSessionEvent,
  updatedAt: number,
): SessionRuntimeSummary {
  const next = withRuntimeMetadata(runtime, { updatedAt });
  const data = (event.data ?? {}) as Record<string, unknown>;
  const telemetry = { ...(next.telemetry ?? {}) };

  if (event.type === "session.usage_info") {
    telemetry.contextWindow = {
      currentTokens: numericValue(data.currentTokens) ?? 0,
      tokenLimit: numericValue(data.tokenLimit) ?? 0,
      messagesLength: numericValue(data.messagesLength) ?? 0,
      conversationTokens: numericValue(data.conversationTokens),
      systemTokens: numericValue(data.systemTokens),
      toolDefinitionsTokens: numericValue(data.toolDefinitionsTokens),
      updatedAt,
    };
    return {
      ...next,
      telemetry,
    };
  }

  if (event.type === "assistant.usage") {
    const copilotUsage = asRecord(data.copilotUsage);
    telemetry.lastUsage = {
      model: stringValue(data.model),
      inputTokens: numericValue(data.inputTokens),
      outputTokens: numericValue(data.outputTokens),
      reasoningTokens: numericValue(data.reasoningTokens),
      cacheReadTokens: numericValue(data.cacheReadTokens),
      cacheWriteTokens: numericValue(data.cacheWriteTokens),
      durationMs: numericValue(data.duration),
      ttftMs: numericValue(data.ttftMs),
      interTokenLatencyMs: numericValue(data.interTokenLatencyMs),
      cost: typeof data.cost === "number" ? data.cost : undefined,
      reasoningEffort: stringValue(data.reasoningEffort),
      totalNanoAiu: numericValue(copilotUsage?.totalNanoAiu),
      updatedAt,
    };
    if (telemetry.lastUsage.model) {
      next.model = telemetry.lastUsage.model;
    }
    if (telemetry.lastUsage.reasoningEffort) {
      next.reasoningEffort = telemetry.lastUsage.reasoningEffort;
    }
    return {
      ...next,
      telemetry,
    };
  }

  if (event.type === "session.compaction_start") {
    const preCompactionTokens =
      sumNumbers(
        numericValue(data.conversationTokens),
        numericValue(data.systemTokens),
        numericValue(data.toolDefinitionsTokens),
      ) ?? telemetry.compaction?.preCompactionTokens;
    telemetry.compaction = {
      ...(telemetry.compaction ?? {}),
      status: "running",
      startedAt: updatedAt,
      updatedAt,
      preCompactionTokens,
    };
    return {
      ...next,
      telemetry,
    };
  }

  if (event.type === "session.compaction_complete") {
    const usage = asRecord(data.compactionTokensUsed);
    const copilotUsage = asRecord(usage?.copilotUsage);
    telemetry.compaction = {
      ...(telemetry.compaction ?? {}),
      status: data.success === false ? "failed" : "completed",
      completedAt: updatedAt,
      updatedAt,
      preCompactionTokens:
        numericValue(data.preCompactionTokens) ??
        telemetry.compaction?.preCompactionTokens,
      postCompactionTokens: numericValue(data.postCompactionTokens),
      tokensRemoved: numericValue(data.tokensRemoved),
      messagesRemoved: numericValue(data.messagesRemoved),
      inputTokens: numericValue(usage?.inputTokens),
      outputTokens: numericValue(usage?.outputTokens),
      cacheReadTokens: numericValue(usage?.cacheReadTokens),
      cacheWriteTokens: numericValue(usage?.cacheWriteTokens),
      durationMs: numericValue(usage?.duration),
      model: stringValue(usage?.model),
      totalNanoAiu: numericValue(copilotUsage?.totalNanoAiu),
      error: stringValue(data.error),
    };
    return {
      ...next,
      telemetry,
    };
  }

  return next;
}

function runtimeSummaryEquals(
  left: SessionRuntimeSummary | null,
  right: SessionRuntimeSummary | null,
): boolean {
  return JSON.stringify(left ?? null) === JSON.stringify(right ?? null);
}

function numericValue(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return undefined;
  }
  return Math.trunc(value);
}

function stringValue(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const normalized = value.trim();
  return normalized.length > 0 ? normalized : undefined;
}

function sumNumbers(...values: Array<number | undefined>): number | undefined {
  const defined = values.filter((value): value is number => value != null);
  if (defined.length === 0) {
    return undefined;
  }
  return defined.reduce((total, value) => total + value, 0);
}

function mergeRuntime(
  runtime: SessionRuntimeSummary | null,
  overrides: {
    model: string | null;
    mode: string | null;
    reasoningEffort: string | null;
    approvalPolicy?: string | null;
  },
  configuredModel: string | null,
  allowAll = false,
): SessionRuntimeSummary {
  const model =
    overrides.model ??
    runtime?.model ??
    configuredModel ??
    DEFAULT_SIDEMESH_COPILOT_MODEL;
  const reasoningEffort =
    overrides.reasoningEffort ?? runtime?.reasoningEffort ?? null;
  const approvalPolicy =
    normalizeCopilotApprovalPolicy(overrides.approvalPolicy) ??
    normalizeCopilotApprovalPolicy(runtime?.approvalPolicy) ??
    (allowAll ? "never" : "on-request");
  const mode =
    normalizeCopilotSessionMode(overrides.mode) ?? runtime?.mode ?? null;
  return {
    ...(runtime ?? {}),
    modelProvider: "copilot",
    ...(model ? { model } : {}),
    ...(mode ? { mode } : {}),
    ...(reasoningEffort ? { reasoningEffort } : {}),
    ...(approvalPolicy ? { approvalPolicy } : {}),
    updatedAt: Date.now(),
  };
}

function normalizeStoredRuntime(
  runtime: SessionRuntimeSummary | null,
): SessionRuntimeSummary | null {
  if (!runtime) return null;
  const normalizedMode = normalizeCopilotSessionMode(runtime.mode);
  const normalizedApprovalPolicy = normalizeCopilotApprovalPolicy(
    runtime.approvalPolicy,
  );
  if (runtime.model === "gpt-5.2" && runtime.modelProvider === "copilot") {
    const {
      model: _model,
      mode: _mode,
      approvalPolicy: _approvalPolicy,
      ...rest
    } = runtime;
    return {
      ...rest,
      modelProvider: "copilot",
      ...(normalizedMode ? { mode: normalizedMode } : {}),
      ...(normalizedApprovalPolicy
        ? { approvalPolicy: normalizedApprovalPolicy }
        : {}),
    };
  }
  const { mode: _mode, approvalPolicy: _approvalPolicy, ...rest } = runtime;
  return {
    ...rest,
    modelProvider: "copilot",
    ...(normalizedMode ? { mode: normalizedMode } : {}),
    ...(normalizedApprovalPolicy
      ? {
          approvalPolicy: normalizedApprovalPolicy,
        }
      : {}),
  };
}

function normalizeInactiveCopilotSessionState(
  session: LegacyCopilotSessionState,
): boolean {
  const restoredAt = session.thread.updatedAt;
  const hadDraftAssistantMessages = session.draftAssistantMessages.size > 0;
  if (hadDraftAssistantMessages) {
    materializeInterruptedCopilotDraftMessages(session);
  }
  const hadActiveTurn = session.turns.some((turn) => {
    if (!isActiveCopilotTurnStatus(turn.status)) {
      return false;
    }
    turn.status = "interrupted";
    turn.completedAt ??= restoredAt;
    return true;
  });
  let hadActiveActivity = false;
  session.activities = new Map(
    [...session.activities.entries()].map(([id, activity]) => {
      const normalized = normalizeInactiveCopilotActivity(activity);
      if (normalized.status !== activity.status) {
        hadActiveActivity = true;
      }
      return [id, normalized];
    }),
  );
  const hadRunningCompaction =
    session.runtime?.telemetry?.compaction?.status === "running";
  session.runtime = normalizeInactiveCopilotRuntime(session.runtime, restoredAt);
  if (
    hadDraftAssistantMessages ||
    hadActiveTurn ||
    hadActiveActivity ||
    hadRunningCompaction ||
    isActiveCopilotThreadStatus(session.thread.status)
  ) {
    session.thread.status = { type: "idle" };
    session.runtime = runtimeWithoutTurnId(session.runtime);
    return true;
  }
  return false;
}

function normalizeInactiveCopilotActivity(
  activity: SessionActivity,
): SessionActivity {
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

function normalizeInactiveCopilotRuntime(
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

function isActiveCopilotTurnStatus(
  status: string | null | undefined,
): boolean {
  return status === "in_progress" || status === "inProgress";
}

function isActiveCopilotThreadStatus(
  status: ThreadRecord["status"] | null | undefined,
): boolean {
  const type = status?.phase ?? status?.type;
  return (
    type === "running" ||
    type === "active" ||
    type === "waiting_for_input" ||
    type === "waiting_for_approval"
  );
}

function runtimeWithoutTurnId(
  runtime: SessionRuntimeSummary | null,
): SessionRuntimeSummary | null {
  if (!runtime) {
    return null;
  }
  const { turnId: _turnId, ...rest } = runtime;
  return rest;
}

function materializeInterruptedCopilotDraftMessages(
  session: LegacyCopilotSessionState,
): void {
  const drafts = [...session.draftAssistantMessages.values()].sort(
    (left, right) => left.createdAt - right.createdAt,
  );
  for (const draft of drafts) {
    if (!hasCopilotDraftAssistantContent(draft)) {
      continue;
    }
    if (!session.messages.some((message) => message.id === draft.id)) {
      session.messages.push({
        id: draft.id,
        role: "assistant",
        text: draft.text,
        content: cloneSessionMessageContentBlocks(draft.content),
        attachments: [],
        createdAt: draft.createdAt,
        seq: session.nextSeq++,
        phase: draft.phase,
      });
      if (draft.text.trim().length > 0) {
        session.thread.preview = draft.text;
      }
    }
    const turn = session.turns.find((candidate) => candidate.id === draft.turnId);
    if (!turn) {
      continue;
    }
    const items = turn.items ?? [];
    if (!items.some((item) => item.id === draft.id)) {
      turn.items = [
        ...items,
        {
          id: draft.id,
          type: "agentMessage",
          text: draft.text,
          phase: draft.phase,
        },
      ];
    }
  }
  session.draftAssistantMessages.clear();
}

function hasCopilotDraftAssistantContent(
  draft: CopilotDraftAssistantMessage,
): boolean {
  if (draft.text.trim().length > 0) {
    return true;
  }
  return draft.content.some(
    (block) =>
      (block.type === "thinking" && block.thinking.trim().length > 0) ||
      (block.type === "text" && block.text.trim().length > 0),
  );
}

function cloneSessionMessageContentBlocks(
  blocks: SessionMessageContentBlock[],
): SessionMessageContentBlock[] {
  return blocks.map((block) => ({ ...block }));
}

function buildAssistantMessageContent(
  text: string,
  reasoningBlocks: SessionMessageContentBlock[],
): SessionMessageContentBlock[] {
  const blocks = cloneSessionMessageContentBlocks(reasoningBlocks);
  if (text.trim().length > 0) {
    blocks.push({ type: "text", text });
  }
  return blocks;
}

function normalizeStoredCopilotDraftAssistantMessage(
  draft: CopilotDraftAssistantMessage,
): CopilotDraftAssistantMessage {
  return {
    ...draft,
    content: cloneSessionMessageContentBlocks(draft.content ?? []),
    phase: draft.phase === "commentary" ? "commentary" : "final_answer",
  };
}

function normalizeCopilotSessionMode(
  value: unknown,
): CopilotSdkSessionMode | null {
  if (typeof value !== "string") {
    return null;
  }
  return COPILOT_SESSION_MODES.includes(value as CopilotSdkSessionMode)
    ? (value as CopilotSdkSessionMode)
    : null;
}

function normalizeCopilotApprovalPolicy(
  value: unknown,
): "on-request" | "never" | null {
  if (typeof value !== "string") {
    return null;
  }
  return COPILOT_APPROVAL_POLICIES.includes(value as "on-request" | "never")
    ? (value as "on-request" | "never")
    : null;
}

function approvalPolicyForSession(
  session: CopilotSessionState | undefined,
  allowAll: boolean,
): "on-request" | "never" {
  return (
    normalizeCopilotApprovalPolicy(session?.runtime?.approvalPolicy) ??
    (allowAll ? "never" : "on-request")
  );
}

function normalizeCopilotSkill(
  skill: {
    name: string;
    description: string;
    source: string;
    enabled: boolean;
    path?: string;
    projectPath?: string;
  },
  cwd: string,
): SkillSummary | null {
  const name = skill.name.trim();
  if (!name) {
    return null;
  }
  const scope = copilotSkillScope(skill.source, skill.projectPath, cwd);
  return {
    name,
    description: skill.description?.trim() || name,
    shortDescription: null,
    interface: null,
    path: skill.path?.trim() || `${skill.source}:${name}`,
    scope,
    enabled: skill.enabled !== false,
  };
}

function copilotSkillScope(
  source: string,
  projectPath: string | undefined,
  cwd: string,
): SkillSummary["scope"] {
  const normalized = source.trim().toLowerCase();
  if (
    normalized === "project" ||
    normalized === "inherited" ||
    (projectPath != null && projectPath.length > 0 && projectPath === cwd)
  ) {
    return "repo";
  }
  if (normalized === "personal" || normalized === "personal-copilot") {
    return "user";
  }
  if (normalized === "builtin" || normalized === "plugin") {
    return "system";
  }
  return normalized || "system";
}

function resolveCopilotSkillName(
  skills: Array<{ name: string; path?: string }>,
  request: AgentSkillConfigWriteRequest,
): string | null {
  const requestedName = request.name?.trim();
  if (requestedName) {
    return requestedName;
  }
  const requestedPath = request.path?.trim();
  if (!requestedPath) {
    return null;
  }
  const match = skills.find((skill) => skill.path?.trim() === requestedPath);
  return match?.name?.trim() || null;
}

function previewFromInput(input: AgentSessionInputItem[]): string {
  const text = inputDisplayText(input).trim();
  if (!text) {
    return hasImageInput(input) ? "Image prompt" : "";
  }
  return text.length > 80 ? `${text.slice(0, 77)}...` : text;
}

function inputPromptText(input: AgentSessionInputItem[]): string {
  const text = inputDisplayText(input).trim();
  if (text) {
    return text;
  }
  const imageCount = countImageInput(input);
  if (imageCount === 1) {
    return "Please inspect the attached image.";
  }
  if (imageCount > 1) {
    return `Please inspect the ${imageCount} attached images.`;
  }
  return "";
}

function inputDisplayText(input: AgentSessionInputItem[]): string {
  return input
    .map((item) => {
      switch (item.type) {
        case "text":
          return item.text;
        case "image":
          return "";
        case "localImage":
          return "";
        case "skill":
          return copilotSkillInvocation(item.name);
      }
    })
    .filter(Boolean)
    .join("\n");
}

function countImageInput(input: AgentSessionInputItem[]): number {
  return input.filter(
    (item) => item.type === "image" || item.type === "localImage",
  ).length;
}

function hasImageInput(input: AgentSessionInputItem[]): boolean {
  return countImageInput(input) > 0;
}

function copilotSkillInvocation(name: string): string {
  const trimmed = name.trim();
  return trimmed.startsWith("/") ? trimmed : `/${trimmed}`;
}

function inputAttachments(
  input: AgentSessionInputItem[],
): SessionMessageAttachment[] {
  return input.flatMap((item): SessionMessageAttachment[] => {
    switch (item.type) {
      case "image":
        return [{ type: "image", url: item.url }];
      case "localImage":
        return [{ type: "localImage", path: item.path }];
      case "file":
        return [{ type: "file", path: item.path }];
      default:
        return [];
    }
  });
}

function pendingActionsForSession(
  sessionId: string,
  pendingPermissions: Map<string, PendingCopilotPermission>,
  pendingUserInputs: Map<string, PendingCopilotUserInput>,
  pendingElicitations: Map<string, PendingCopilotElicitation>,
): AgentPendingAction[] {
  const actions: AgentPendingAction[] = [];
  for (const pending of pendingPermissions.values()) {
    if (pending.action.sessionId === sessionId) {
      actions.push(pending.action);
    }
  }
  for (const pending of pendingUserInputs.values()) {
    if (pending.action.sessionId === sessionId) {
      actions.push(pending.action);
    }
  }
  for (const pending of pendingElicitations.values()) {
    if (pending.action.sessionId === sessionId) {
      actions.push(pending.action);
    }
  }
  return actions.sort((left, right) => left.requestedAt - right.requestedAt);
}

function interruptedPendingActionMessage(
  actions: AgentPendingAction[],
): string {
  const kinds = new Set(actions.map((action) => action.kind));
  let waitingFor = "approval or input";
  if (kinds.size === 1 && kinds.has("user_input")) {
    waitingFor = "your answer";
  } else if (kinds.size === 1 && kinds.has("elicitation")) {
    waitingFor = "structured input";
  } else if (kinds.size === 1) {
    waitingFor = "approval";
  }
  return `Sidemesh restarted while Copilot was waiting for ${waitingFor}. That turn was interrupted. Re-run your last request to continue.`;
}

function cloneThread(
  session: CopilotSessionState,
  includeTurns: boolean,
): ThreadRecord {
  return {
    ...session.thread,
    status: { ...session.thread.status },
    gitInfo: session.thread.gitInfo ? { ...session.thread.gitInfo } : null,
    turns: includeTurns ? session.turns.map(cloneTurn) : undefined,
  };
}

function cloneThreadRecord(thread: ThreadRecord): ThreadRecord {
  return {
    ...thread,
    status: { ...thread.status },
    gitInfo: thread.gitInfo ? { ...thread.gitInfo } : null,
    turns: thread.turns ? thread.turns.map(cloneTurn) : undefined,
  };
}

function cloneTurn(turn: TurnRecord): TurnRecord {
  return {
    ...turn,
    items: turn.items ? turn.items.map((item) => ({ ...item })) : undefined,
  };
}

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (limit == null || limit <= 0 || items.length <= limit) {
    return [...items];
  }
  return items.slice(items.length - limit);
}

function nowSeconds(): number {
  return Date.now() / 1000;
}
