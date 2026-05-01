import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import nodePath from "node:path";

import {
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
  type AgentSessionLogOptions,
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
import { mergeActivity, normalizeStoredSessionActivity } from "./activity.js";
import type {
  ModelSummary,
  PendingActionElicitationField,
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
} from "./types.js";

export interface CopilotAgentProviderOptions {
  bin?: string;
  stateDir?: string | null;
  allowAll?: boolean;
  configuredModel?: string | null;
  sdkClientFactory?: CopilotSdkClientFactory;
}

interface CopilotSessionState {
  thread: ThreadRecord;
  messages: SessionMessage[];
  activities: Map<string, SessionActivity>;
  turns: TurnRecord[];
  runtime: SessionRuntimeSummary | null;
  archived: boolean;
  nextSeq: number;
  copilotSessionId: string | null;
  copilotSessionCreated: boolean;
  toolRequests: Map<string, CopilotToolRequestMetadata>;
  hiddenToolCallIds: Set<string>;
  reasoningBuffers: Map<string, string>;
  sdkSession?: CopilotSdkSession | null;
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
    copilotSessionId?: string | null;
    copilotSessionCreated?: boolean;
  }>;
}

interface ActiveCopilotTurn {
  turnId: string;
  sdkSession: CopilotSdkSession;
  assistantBuffers: Map<string, string>;
  completedAssistantMessageIds: Set<string>;
  resolve(status: string): void;
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

interface CopilotToolRequestMetadata {
  toolName: string;
  toolTitle: string | null;
  intentionSummary: string | null;
  mcpServerName: string | null;
  type: string | null;
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
const COPILOT_HIDDEN_TOOL_KEYS = new Set([
  "ask_user",
  "request_user_input",
  "user_input",
  "elicitation",
  "request_elicitation",
]);
const COPILOT_COMMENTARY_TOOL_KEYS = new Set([
  "report_intent",
  "assistant_intent",
  "report_progress",
]);
const COPILOT_TASK_TOOL_KEYS = new Set([
  "update_plan",
  "todo_write",
  "todo_update",
  "write_todo",
  "write_todos",
]);
const COPILOT_SESSION_MODES = [
  "interactive",
  "plan",
  "autopilot",
] as const satisfies readonly CopilotSdkSessionMode[];
const COPILOT_APPROVAL_POLICIES = ["on-request", "never"] as const;

export const COPILOT_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
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
  },
  input: {
    text: true,
    imageUrl: true,
    localImage: true,
    skills: true,
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
  },
  workspace: {
    filesystem: false,
    remoteGitDiff: false,
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
  private sdkClient: CopilotSdkClient | null = null;
  private saveChain: Promise<void> = Promise.resolve();

  public constructor(options: CopilotAgentProviderOptions = {}) {
    super();
    this.bin = options.bin?.trim() || "copilot";
    this.stateDir = nodePath.resolve(
      options.stateDir || DEFAULT_COPILOT_STATE_DIR,
    );
    this.allowAll = options.allowAll === true;
    this.configuredModel = options.configuredModel?.trim() || null;
    this.sdkClientFactory = options.sdkClientFactory ?? createCopilotSdkClient;
  }

  public async start(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true });
    await this.ensureSdkClient();
    await this.loadState();
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
    const existing = this.sessions.get(threadId);
    if (existing) {
      return cloneThread(existing, includeTurns);
    }
    const sdkSession = await this.readSdkSessionMetadata(threadId);
    if (sdkSession) {
      return sdkSessionToThread(sdkSession, null, includeTurns);
    }
    return cloneThread(this.requireSession(threadId), includeTurns);
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    const session =
      this.sessions.get(thread.id) ??
      (await this.loadSdkSessionStateFromHistory(thread.id));
    const messages = limitTail(session.messages, options.messageLimit ?? null);
    const activities = limitTail(
      [...session.activities.values()].sort(
        (left, right) => left.seq - right.seq,
      ),
      options.activityLimit ?? null,
    );
    return {
      messages: messages.map(cloneMessage),
      activities: activities.map(cloneActivity),
      runtime: session.runtime ? { ...session.runtime } : null,
      totalMessages: session.messages.length,
      totalActivities: session.activities.size,
      nextSeq: session.nextSeq,
    };
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    const session =
      this.sessions.get(thread.id) ??
      (await this.loadSdkSessionStateFromHistory(thread.id));
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
    session.thread.name = name;
    this.touch(session);
    await this.persistSoon();
    return { renamed: true };
  }

  public async archiveSession(threadId: string): Promise<unknown> {
    this.archivedSessionIds.add(threadId);
    const session = this.sessions.get(threadId);
    if (session) {
      session.archived = true;
      this.touch(session);
    }
    await this.interruptTurn(
      threadId,
      this.activeTurns.get(threadId)?.turnId ?? "",
    );
    this.loadedSessionIds.delete(threadId);
    await this.persistSoon();
    return { archived: true };
  }

  public async unarchiveSession(threadId: string): Promise<unknown> {
    this.archivedSessionIds.delete(threadId);
    const session = this.sessions.get(threadId);
    if (session) {
      session.archived = false;
      this.touch(session);
    }
    await this.persistSoon();
    return { unarchived: true };
  }

  public async compactSession(threadId: string): Promise<unknown> {
    const session = await this.getWritableSession(threadId);
    const sdkSession = await this.ensureSdkSession(session);
    if (!sdkSession.rpc?.compaction?.compact) {
      throw new Error("Copilot SDK does not expose manual compaction.");
    }
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
      const result = await sdkSession.rpc.compaction.compact();
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
      await this.persistSoon();
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
    const session = this.createSessionState(request);
    let activeTurnId: string | null = null;
    if (request.input.length > 0) {
      activeTurnId = this.startTurn(session, request.input);
    }
    await this.persistSoon();
    return {
      thread: cloneThread(session, false),
      activeTurnId,
      runtime: session.runtime,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    const session = await this.getWritableSession(request.sessionId);
    session.runtime = mergeRuntime(
      session.runtime,
      request.overrides,
      this.configuredModel,
      this.allowAll,
    );

    const active = this.activeTurns.get(session.thread.id);
    if (active) {
      await active.sdkSession.send({
        prompt: inputPromptText(request.input),
        attachments: await sdkAttachments(request.input),
        mode: "immediate",
      });
      this.appendUserMessage(session, request.input);
      await this.persistSoon();
      return {
        mode: "steer",
        turnId: active.turnId,
      };
    }

    const turnId = this.startTurn(session, request.input);
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
    await this.persistSoon();
    return { interrupted: true };
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean {
    const pending = this.pendingPermissions.get(action.id);
    if (pending) {
      const normalized = normalizePendingActionDecision(
        decision as PendingActionDecisionInput,
      );
      if (!normalized) {
        return false;
      }
      const result = buildCopilotPermissionResult(
        normalized,
        pending.action.providerPayload,
      );
      if (!result) {
        return false;
      }
      this.pendingPermissions.delete(action.id);
      pending.resolve(result);
      return true;
    }

    const inputRequest = this.pendingUserInputs.get(action.id);
    if (inputRequest) {
      if (!isCopilotUserInputResponse(decision)) {
        return false;
      }
      this.pendingUserInputs.delete(action.id);
      inputRequest.resolve(decision);
      return true;
    }

    const elicitation = this.pendingElicitations.get(action.id);
    if (elicitation) {
      if (!isCopilotElicitationResponse(decision)) {
        return false;
      }
      this.pendingElicitations.delete(action.id);
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
      (session) => session.thread.cwd === cwd,
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
      messages: [],
      activities: new Map(),
      turns: [],
      runtime: mergeRuntime(
        null,
        request.overrides,
        this.configuredModel,
        this.allowAll,
      ),
      archived: false,
      nextSeq: 0,
      copilotSessionId: id,
      copilotSessionCreated: false,
      toolRequests: new Map(),
      hiddenToolCallIds: new Set(),
      reasoningBuffers: new Map(),
    };
    this.sessions.set(id, session);
    this.loadedSessionIds.add(id);
    return session;
  }

  private startTurn(
    session: CopilotSessionState,
    input: AgentSessionInputItem[],
  ): string {
    this.appendUserMessage(session, input);
    const turnId = `copilot-turn-${randomUUID()}`;
    const turn: TurnRecord = {
      id: turnId,
      status: "inProgress",
      startedAt: nowSeconds(),
      completedAt: null,
      items: [],
    };
    session.turns.push(turn);
    session.thread.status = { type: "running", activeFlags: ["inProgress"] };
    this.touch(session);
    void this.runTurn(session.thread.id, turnId, input);
    return turnId;
  }

  private async runTurn(
    sessionId: string,
    turnId: string,
    input: AgentSessionInputItem[],
  ): Promise<void> {
    const session = this.sessions.get(sessionId);
    if (!session) return;

    this.emit("liveEvent", { type: "turn_started", sessionId, turnId });

    try {
      const sdkSession = await this.ensureSdkSession(session);
      await this.applyRuntimeControls(session, sdkSession);
      const completed = new Promise<string>((resolve) => {
        this.activeTurns.set(sessionId, {
          turnId,
          sdkSession,
          assistantBuffers: new Map(),
          completedAssistantMessageIds: new Set(),
          resolve,
        });
      });
      await sdkSession.send({
        prompt: inputPromptText(input),
        attachments: await sdkAttachments(input),
        mode: "enqueue",
      });
      await completed;
    } catch (error) {
      const current = this.sessions.get(sessionId);
      if (!current) {
        return;
      }
      const text =
        error instanceof Error ? error.message : "Copilot SDK turn failed.";
      this.failTurn(current, turnId, `Copilot SDK error: ${text}`);
      await this.persistSoon();
    }
  }

  private async ensureSdkClient(): Promise<CopilotSdkClient> {
    if (this.sdkClient) {
      return this.sdkClient;
    }
    const client = await this.sdkClientFactory({
      bin: this.bin,
      cwd: process.cwd(),
      env: { ...process.env, NO_COLOR: "1" },
    });
    await client.start();
    this.sdkClient = client;
    return client;
  }

  private async ensureSdkSession(
    session: CopilotSessionState,
  ): Promise<CopilotSdkSession> {
    if (session.sdkSession) {
      return session.sdkSession;
    }

    const client = await this.ensureSdkClient();
    const config = this.buildSdkSessionConfig(session);
    const sdkSession = session.copilotSessionCreated
      ? await client.resumeSession(
          session.copilotSessionId ?? session.thread.id,
          {
            ...config,
            disableResume: true,
          },
        )
      : await client.createSession({
          ...config,
          sessionId: session.copilotSessionId ?? session.thread.id,
        });
    session.sdkSession = sdkSession;
    session.copilotSessionId = sdkSession.sessionId;
    session.copilotSessionCreated = true;
    await this.persistSoon();
    return sdkSession;
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
    const session = this.sessions.get(sessionId);
    if (!session) {
      return;
    }
    const active = this.activeTurns.get(sessionId);

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
      rememberCopilotToolRequests(session.toolRequests, event.data.toolRequests);
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
      this.persistEventually();
      return;
    }

    if (event.type === "assistant.intent") {
      if (active) {
        this.appendCopilotCommentaryMessage(
          session,
          active.turnId,
          event.data.intent,
          `copilot-intent:${event.id}`,
        );
      }
      return;
    }

    if (event.type === "session.plan_changed") {
      this.upsertAndEmitActivity(
        session,
        active?.turnId ?? null,
        buildCopilotPlanChangedActivity({
          activityId: `copilot-plan:${event.id}`,
          turnId: active?.turnId ?? null,
          operation: event.data.operation,
        }),
      );
      return;
    }

    if (event.type === "session.task_complete") {
      this.upsertAndEmitActivity(
        session,
        active?.turnId ?? null,
        buildCopilotTaskCompleteActivity({
          activityId: `copilot-task-complete:${event.id}`,
          turnId: active?.turnId ?? null,
          success: event.data.success,
          summary: event.data.summary,
        }),
      );
      return;
    }

    if (event.type === "assistant.reasoning_delta") {
      const reasoningId = stringValue(event.data.reasoningId) ?? null;
      const activityId = copilotReasoningActivityId(event);
      const delta = event.data.deltaContent;
      const existing = session.activities.get(activityId);
      const existingContent =
        existing?.type === "reasoning" ? existing.content ?? "" : "";
      const content = `${session.reasoningBuffers.get(activityId) ?? existingContent}${delta}`;
      session.reasoningBuffers.set(activityId, content);
      this.upsertAndEmitActivity(
        session,
        active?.turnId ?? null,
        buildCopilotReasoningActivity({
          activityId,
          turnId: active?.turnId ?? null,
          reasoningId,
          content,
          status: "in_progress",
          agentId: stringValue((event as { agentId?: unknown }).agentId) ?? null,
        }),
      );
      return;
    }

    if (event.type === "assistant.reasoning") {
      const reasoningId = stringValue(event.data.reasoningId) ?? null;
      const activityId = copilotReasoningActivityId(event);
      const content =
        stringValue(event.data.content) ??
        session.reasoningBuffers.get(activityId) ??
        null;
      if (content) {
        session.reasoningBuffers.set(activityId, content);
      }
      this.upsertAndEmitActivity(
        session,
        active?.turnId ?? null,
        buildCopilotReasoningActivity({
          activityId,
          turnId: active?.turnId ?? null,
          reasoningId,
          content,
          status: "completed",
          agentId: stringValue((event as { agentId?: unknown }).agentId) ?? null,
        }),
      );
      return;
    }

    const subagentActivity = buildCopilotSubagentActivity(
      event,
      active?.turnId ?? null,
    );
    if (subagentActivity) {
      this.upsertAndEmitActivity(session, active?.turnId ?? null, subagentActivity);
      return;
    }

    const notificationActivity = buildCopilotSystemNotificationActivity(
      event,
      active?.turnId ?? null,
    );
    if (notificationActivity) {
      this.upsertAndEmitActivity(
        session,
        active?.turnId ?? null,
        notificationActivity,
      );
      return;
    }

    const planReviewActivity = buildCopilotPlanReviewActivity(
      event,
      active?.turnId ?? null,
    );
    if (planReviewActivity) {
      this.upsertAndEmitActivity(
        session,
        active?.turnId ?? null,
        planReviewActivity,
      );
      return;
    }

    const systemActivity = buildCopilotSystemEventFromEvent(
      event,
      active?.turnId ?? null,
    );
    if (systemActivity) {
      this.upsertAndEmitActivity(session, active?.turnId ?? null, systemActivity);
      return;
    }

    if (event.type === "user_input.requested") {
      rememberHiddenCopilotToolCall(
        session.hiddenToolCallIds,
        event.data.toolCallId,
      );
      return;
    }

    if (event.type === "elicitation.requested") {
      rememberHiddenCopilotToolCall(
        session.hiddenToolCallIds,
        event.data.toolCallId,
      );
      return;
    }

    if (event.type === "assistant.turn_end" || event.type === "session.idle") {
      if (active) {
        this.completeActiveTurn(sessionId, "completed");
      }
      return;
    }

    if (event.type === "session.error") {
      if (active) {
        this.appendAndEmitAssistantMessage(
          session,
          active.turnId,
          event.data.message,
          "final_answer",
          `copilot-assistant-error-${active.turnId}`,
        );
        this.completeActiveTurn(sessionId, "failed");
      }
      return;
    }

    if (event.type === "tool.execution_start") {
      const metadata = session.toolRequests.get(event.data.toolCallId) ?? null;
      const presentation = describeCopilotToolPresentation({
        toolCallId: event.data.toolCallId,
        toolName: event.data.toolName,
        args: event.data.arguments,
        metadata,
        hiddenToolCallIds: session.hiddenToolCallIds,
      });
      if (presentation.kind === "hidden" || presentation.kind === "commentary") {
        return;
      }
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId,
        type: "tool",
        turnId: active?.turnId ?? null,
        status: "in_progress",
        toolName: copilotToolName(event.data.toolName),
        title: presentation.title,
        args: event.data.arguments ?? null,
        output: null,
        result: null,
        isError: null,
        semantic:
          presentation.kind === "task"
            ? taskToolSemantic()
            : inferCopilotToolSemantic(
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
      const existing = session.activities.get(event.data.toolCallId);
      const existingTool = existing?.type === "tool" ? existing : null;
      const metadata = session.toolRequests.get(event.data.toolCallId) ?? null;
      const presentation = describeCopilotToolPresentation({
        toolCallId: event.data.toolCallId,
        toolName: completeData.toolName,
        args: existingTool?.args ?? completeData.arguments,
        result: event.data.result ?? event.data.error ?? null,
        metadata,
        hiddenToolCallIds: session.hiddenToolCallIds,
      });
      if (presentation.kind === "hidden") {
        return;
      }
      if (presentation.kind === "commentary") {
        if (active) {
          this.appendCopilotCommentaryMessage(
            session,
            active.turnId,
            presentation.commentary,
            `copilot-commentary:${event.data.toolCallId}`,
          );
        }
        return;
      }
      const output =
        (presentation.kind === "task"
          ? presentation.output
          : null) ??
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
        title: existingTool?.title ?? presentation.title,
        args: existingTool?.args ?? completeData.arguments ?? null,
        output,
        result: event.data.result ?? event.data.error ?? null,
        isError: event.data.success ? false : true,
        semantic:
          presentation.kind === "task"
            ? taskToolSemantic()
            : mergeCopilotToolSemantic(
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
    active.resolve(status);
    this.persistEventually();
  }

  private failTurn(
    session: CopilotSessionState,
    turnId: string,
    text: string,
  ): void {
    const active = this.activeTurns.get(session.thread.id);
    if (active?.turnId === turnId) {
      this.appendAndEmitAssistantMessage(
        session,
        turnId,
        text,
        "final_answer",
        `copilot-assistant-error-${turnId}`,
      );
      this.completeActiveTurn(session.thread.id, "failed");
      return;
    }

    const turn = session.turns.find((candidate) => candidate.id === turnId);
    if (turn?.status !== "inProgress") {
      return;
    }
    this.appendAndEmitAssistantMessage(
      session,
      turnId,
      text,
      "final_answer",
      `copilot-assistant-error-${turnId}`,
    );
    this.finishTurn(session, turn, "failed");
    this.persistEventually();
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

  private appendCopilotCommentaryMessage(
    session: CopilotSessionState,
    turnId: string,
    text: string | null,
    id: string,
  ): void {
    const normalized = normalizeCopilotCommentaryText(text);
    if (!normalized) {
      return;
    }
    const latest = session.messages.at(-1);
    if (
      latest?.role === "assistant" &&
      latest.phase === "commentary" &&
      normalizeCopilotCommentaryText(latest.text) === normalized
    ) {
      return;
    }
    this.appendAndEmitAssistantMessage(
      session,
      turnId,
      normalized,
      "commentary",
      id,
    );
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
    const existing = session.activities.get(activity.id);
    const incoming = {
      ...activity,
      createdAt: existing?.createdAt ?? Date.now(),
      seq: existing?.seq ?? session.nextSeq++,
    } as SessionActivity;
    const next = mergeActivity(existing, incoming);
    session.activities.set(activity.id, next);
    this.touch(session);
    this.persistEventually();
    return next;
  }

  private appendActivityOutput(
    session: CopilotSessionState,
    turnId: string | null,
    activityId: string,
    delta: string,
  ): void {
    const existing = session.activities.get(activityId);
    if (existing?.type === "command" || existing?.type === "tool") {
      session.activities.set(activityId, {
        ...existing,
        output: `${existing.output ?? ""}${delta}`,
      });
      this.touch(session);
      this.persistEventually();
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
    this.persistEventually();
  }

  private async handlePermissionRequest(
    sessionId: string,
    request: CopilotSdkPermissionRequest,
  ): Promise<CopilotSdkPermissionResult> {
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
    });
  }

  private async handleUserInputRequest(
    sessionId: string,
    request: CopilotSdkUserInputRequest,
  ): Promise<CopilotSdkUserInputResponse> {
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
    });
  }

  private async handleElicitationRequest(
    sessionId: string,
    request: CopilotSdkElicitationContext,
  ): Promise<CopilotSdkElicitationResult> {
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
    });
  }

  private resolvePendingPermissionsForSession(
    sessionId: string,
    result: CopilotSdkPermissionResult,
  ): void {
    for (const [actionId, pending] of this.pendingPermissions) {
      if (pending.action.sessionId !== sessionId) {
        continue;
      }
      this.pendingPermissions.delete(actionId);
      pending.resolve(result);
    }
  }

  private resolvePendingUserInputsForSession(
    sessionId: string,
    result: CopilotSdkUserInputResponse,
  ): void {
    for (const [actionId, pending] of this.pendingUserInputs) {
      if (pending.action.sessionId !== sessionId) {
        continue;
      }
      this.pendingUserInputs.delete(actionId);
      pending.resolve(result);
    }
  }

  private resolvePendingElicitationsForSession(
    sessionId: string,
    result: CopilotSdkElicitationResult,
  ): void {
    for (const [actionId, pending] of this.pendingElicitations) {
      if (pending.action.sessionId !== sessionId) {
        continue;
      }
      this.pendingElicitations.delete(actionId);
      pending.resolve(result);
    }
  }

  private appendUserMessage(
    session: CopilotSessionState,
    input: AgentSessionInputItem[],
  ): void {
    this.appendMessage(session, {
      role: "user",
      text: inputDisplayText(input),
      attachments: inputAttachments(input),
    });
  }

  private appendAssistantMessage(
    session: CopilotSessionState,
    turnId: string,
    text: string,
    phase: "commentary" | "final_answer",
    id = `copilot-assistant-${randomUUID()}`,
  ): void {
    this.appendMessage(session, {
      id,
      role: "assistant",
      text,
      attachments: [],
      phase,
    });
    const turn = this.requireTurn(session, turnId);
    turn.items = [
      ...(turn.items ?? []),
      { id, type: "agentMessage", text, phase },
    ];
  }

  private appendMessage(
    session: CopilotSessionState,
    message: {
      id?: string;
      role: SessionMessage["role"];
      text: string;
      attachments: SessionMessageAttachment[];
      phase?: "commentary" | "final_answer";
    },
  ): SessionMessage {
    const next: SessionMessage = {
      id: message.id ?? `copilot-message-${randomUUID()}`,
      role: message.role,
      text: message.text,
      attachments: message.attachments,
      phase: message.phase,
      createdAt: Date.now(),
      seq: session.nextSeq++,
    };
    session.messages.push(next);
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

  private requireSession(threadId: string): CopilotSessionState {
    const session = this.sessions.get(threadId);
    if (!session) {
      throw new Error(`Unknown Copilot session: ${threadId}`);
    }
    return session;
  }

  private async getWritableSession(
    threadId: string,
  ): Promise<CopilotSessionState> {
    const existing = this.sessions.get(threadId);
    if (existing) return existing;
    return this.loadSdkSessionStateFromHistory(threadId);
  }

  private requireTurn(
    session: CopilotSessionState,
    turnId: string,
  ): TurnRecord {
    const turn = session.turns.find((candidate) => candidate.id === turnId);
    if (!turn) {
      throw new Error(`Unknown Copilot turn: ${turnId}`);
    }
    return turn;
  }

  private touch(session: CopilotSessionState): void {
    session.thread.updatedAt = nowSeconds();
    if (session.messages.length > 0) {
      session.thread.preview =
        session.messages[session.messages.length - 1]!.text;
    }
  }

  private async loadState(): Promise<void> {
    try {
      const raw = await readFile(this.statePath, "utf8");
      const parsed = JSON.parse(raw) as CopilotStateFile;
      for (const id of parsed.archivedSessionIds ?? []) {
        this.archivedSessionIds.add(id);
      }
      for (const item of parsed.sessions ?? []) {
        const state: CopilotSessionState = {
          thread: item.thread,
          messages: item.messages ?? [],
          activities: new Map(
            normalizeStoredCopilotActivities(item.activities ?? []).map(
              (activity) => [activity.id, activity],
            ),
          ),
          turns: item.turns ?? [],
          runtime: normalizeStoredRuntime(item.runtime ?? null),
          archived: item.archived === true,
          nextSeq: item.nextSeq ?? item.messages?.length ?? 0,
          copilotSessionId: item.copilotSessionId ?? null,
          copilotSessionCreated:
            item.copilotSessionCreated ?? item.copilotSessionId != null,
          toolRequests: new Map(),
          hiddenToolCallIds: new Set(),
          reasoningBuffers: new Map(),
        };
        this.sessions.set(state.thread.id, state);
      }
    } catch {
      // Missing or corrupt provider state should not block daemon startup.
    }
  }

  private async persistSoon(): Promise<void> {
    this.saveChain = this.saveChain
      .catch(() => undefined)
      .then(() => this.saveState());
    await this.saveChain;
  }

  private persistEventually(): void {
    void this.persistSoon().catch((error: unknown) => {
      this.emit(
        "stderr",
        error instanceof Error
          ? `Copilot state persistence failed: ${error.message}`
          : "Copilot state persistence failed.",
      );
    });
  }

  private async saveState(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true });
    const payload: CopilotStateFile = {
      archivedSessionIds: [...this.archivedSessionIds],
      sessions: [...this.sessions.values()].map((session) => ({
        thread: cloneThread(session, true),
        messages: session.messages.map(cloneMessage),
        activities: [...session.activities.values()].map(cloneActivity),
        turns: session.turns.map(cloneTurn),
        runtime: session.runtime ? { ...session.runtime } : null,
        archived: session.archived,
        nextSeq: session.nextSeq,
        copilotSessionId: session.copilotSessionId,
        copilotSessionCreated: session.copilotSessionCreated,
      })),
    };
    await writeFile(this.statePath, JSON.stringify(payload, null, 2));
  }

  private get statePath(): string {
    return nodePath.join(this.stateDir, "sessions.json");
  }

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

  private async loadSdkSessionStateFromHistory(
    sessionId: string,
  ): Promise<CopilotSessionState> {
    const metadata = await this.readSdkSessionMetadata(sessionId);
    if (!metadata) {
      return this.requireSession(sessionId);
    }
    const thread = sdkSessionToThread(metadata, null, false);
    const state: CopilotSessionState = {
      thread,
      messages: [],
      activities: new Map(),
      turns: [],
      runtime: null,
      archived: this.archivedSessionIds.has(sessionId),
      nextSeq: 0,
      copilotSessionId: sessionId,
      copilotSessionCreated: true,
      toolRequests: new Map(),
      hiddenToolCallIds: new Set(),
      reasoningBuffers: new Map(),
    };
    const sdkSession = await (
      await this.ensureSdkClient()
    ).resumeSession(sessionId, {
      ...this.buildSdkSessionConfig(state),
      disableResume: true,
    });
    state.sdkSession = sdkSession;
    const events = await sdkSession.getMessages?.();
    if (events) {
      const parsed = parseSdkSessionEvents(events, thread.cwd);
      state.messages = parsed.messages;
      state.activities = new Map(
        parsed.activities.map((activity) => [activity.id, activity]),
      );
      state.runtime = parsed.runtime;
      state.nextSeq = parsed.nextSeq;
    }
    this.sessions.set(sessionId, state);
    await this.persistSoon();
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
  const response = await fetch(parsed);
  if (!response.ok) {
    throw new Error(
      `Failed to fetch Copilot image URL: ${response.status} ${response.statusText}`,
    );
  }
  const mimeType =
    response.headers.get("content-type")?.split(";")[0]?.trim() || "image/png";
  const bytes = Buffer.from(await response.arrayBuffer());
  return {
    type: "blob",
    data: bytes.toString("base64"),
    mimeType,
    displayName:
      nodePath.basename(parsed.pathname) || suggestedInlineImageName(mimeType),
  };
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
  const fields = normalizeCopilotElicitationFields(request.requestedSchema);
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

function normalizeCopilotElicitationFields(
  schema: CopilotSdkElicitationContext["requestedSchema"],
): PendingActionElicitationField[] {
  if (!schema || schema.type !== "object" || !schema.properties) {
    return [];
  }
  const required = new Set(schema.required ?? []);
  return Object.entries(schema.properties)
    .map(([key, field]) => normalizeCopilotElicitationField(key, field, required))
    .filter((field): field is PendingActionElicitationField => field !== null);
}

function normalizeCopilotElicitationField(
  key: string,
  field: NonNullable<CopilotSdkElicitationContext["requestedSchema"]>["properties"][string],
  required: Set<string>,
): PendingActionElicitationField | null {
  const title =
    ("title" in field && typeof field.title === "string" && field.title.trim()) ||
    key;
  const description =
    "description" in field && typeof field.description === "string"
      ? field.description
      : undefined;
  const isRequired = required.has(key);

  if (field.type === "boolean") {
    return {
      key,
      type: "boolean",
      title,
      description,
      required: isRequired,
      ...(typeof field.default === "boolean"
        ? { defaultValue: field.default }
        : {}),
    };
  }
  if (field.type === "number" || field.type === "integer") {
    return {
      key,
      type: "number",
      title,
      description,
      required: isRequired,
      integer: field.type === "integer",
      ...(typeof field.default === "number"
        ? { defaultValue: field.default }
        : {}),
      ...(typeof field.minimum === "number" ? { minimum: field.minimum } : {}),
      ...(typeof field.maximum === "number" ? { maximum: field.maximum } : {}),
    };
  }
  if (field.type === "array") {
    const options = "enum" in field.items
      ? field.items.enum.map((value) => ({ value, label: value }))
      : "anyOf" in field.items
        ? field.items.anyOf
            .filter((item) => typeof item.const === "string")
            .map((item) => ({ value: item.const, label: item.title || item.const }))
        : [];
    return {
      key,
      type: "string[]",
      title,
      description,
      required: isRequired,
      options,
      ...(Array.isArray(field.default) ? { defaultValue: field.default } : {}),
      ...(typeof field.minItems === "number" ? { minItems: field.minItems } : {}),
      ...(typeof field.maxItems === "number" ? { maxItems: field.maxItems } : {}),
    };
  }
  const options =
    "enum" in field
      ? field.enum.map((value, index) => ({
          value,
          label:
            Array.isArray(field.enumNames) &&
            typeof field.enumNames[index] === "string" &&
            field.enumNames[index].trim().length > 0
              ? field.enumNames[index]
              : value,
        }))
      : "oneOf" in field
        ? field.oneOf
            .filter((item) => typeof item.const === "string")
            .map((item) => ({ value: item.const, label: item.title || item.const }))
        : undefined;
  return {
    key,
    type: "string",
    title,
    description,
    required: isRequired,
    ...(typeof field.default === "string" ? { defaultValue: field.default } : {}),
    ...(("minLength" in field && typeof field.minLength === "number")
      ? { minLength: field.minLength }
      : {}),
    ...(("maxLength" in field && typeof field.maxLength === "number")
      ? { maxLength: field.maxLength }
      : {}),
    ...(("format" in field && field.format) ? { format: field.format } : {}),
    ...(options && options.length > 0 ? { options } : {}),
  };
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
  decision: NormalizedPendingActionDecision,
  request: unknown,
): CopilotSdkPermissionResult | null {
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
  const cwd = session.context?.cwd ?? local?.thread.cwd ?? process.cwd();
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
    },
    turns: includeTurns ? (local?.turns.map(cloneTurn) ?? []) : undefined,
  };
}

function parseSdkSessionEvents(
  events: CopilotSdkSessionEvent[],
  cwd: string,
): {
  messages: SessionMessage[];
  activities: import("./types.js").SessionActivity[];
  runtime: SessionRuntimeSummary | null;
  nextSeq: number;
} {
  const messages: SessionMessage[] = [];
  const activities = new Map<string, import("./types.js").SessionActivity>();
  const toolRequests = new Map<string, CopilotToolRequestMetadata>();
  const hiddenToolCallIds = new Set<string>();
  const reasoningBuffers = new Map<string, string>();
  let seq = 0;
  let runtime: SessionRuntimeSummary | null = null;
  let updatedAt: number | undefined;
  const upsertParsedActivity = (
    activity: AgentSessionActivityDraft,
    timestamp: number,
  ) => {
    const existing = activities.get(activity.id);
    const incoming = {
      ...activity,
      createdAt: existing?.createdAt ?? timestamp,
      seq: existing?.seq ?? seq++,
    } as SessionActivity;
    activities.set(activity.id, mergeActivity(existing, incoming));
  };

  for (const event of events) {
    const timestamp = millisFromDateLike(event.timestamp) ?? Date.now();
    updatedAt = timestamp;
    const data = (event.data ?? {}) as Record<string, any>;

    if (
      event.type === "session.model_change" &&
      typeof data.newModel === "string"
    ) {
      runtime = withRuntimeMetadata(runtime, {
        model: data.newModel,
        updatedAt: timestamp,
      });
      continue;
    }

    if (event.type === "session.mode_changed") {
      const nextMode = normalizeCopilotSessionMode(data.newMode);
      if (nextMode) {
        runtime = withRuntimeMetadata(runtime, {
          mode: nextMode,
          updatedAt: timestamp,
        });
        const activity = buildCopilotModeChangeActivity({
          activityId: copilotModeActivityId(event, seq),
          turnId: null,
          newMode: nextMode,
          previousMode: data.previousMode,
        });
        activities.set(activity.id, {
          ...activity,
          createdAt: timestamp,
          seq: seq++,
        });
      }
      continue;
    }

    if (
      event.type === "session.usage_info" ||
      event.type === "assistant.usage" ||
      event.type === "session.compaction_start" ||
      event.type === "session.compaction_complete"
    ) {
      runtime = applyCopilotRuntimeEvent(runtime, event, timestamp);
      continue;
    }

    if (event.type === "user.message" && typeof data.content === "string") {
      messages.push({
        id: typeof event.id === "string" ? event.id : `copilot-user-${seq}`,
        role: "user",
        text: data.content,
        attachments: [],
        createdAt: timestamp,
        seq: seq++,
      });
      continue;
    }

    if (event.type === "assistant.intent") {
      const text = normalizeCopilotCommentaryText(data.intent);
      if (text) {
        const latest = messages.at(-1);
        if (
          latest?.role !== "assistant" ||
          latest.phase !== "commentary" ||
          normalizeCopilotCommentaryText(latest.text) !== text
        ) {
          messages.push({
            id:
              typeof event.id === "string"
                ? `copilot-intent:${event.id}`
                : `copilot-intent-${seq}`,
            role: "assistant",
            text,
            attachments: [],
            createdAt: timestamp,
            seq: seq++,
            phase: "commentary",
          });
        }
      }
      continue;
    }

    if (
      event.type === "assistant.message" &&
      typeof data.content === "string"
    ) {
      rememberCopilotToolRequests(toolRequests, data.toolRequests);
      if (typeof data.model === "string") {
        runtime = withRuntimeMetadata(runtime, {
          model: data.model,
          updatedAt: timestamp,
        });
      }
      const text = data.content.trim();
      if (text.length > 0) {
        messages.push({
          id:
            typeof data.messageId === "string"
              ? data.messageId
              : typeof event.id === "string"
                ? event.id
                : `copilot-assistant-${seq}`,
          role: "assistant",
          text,
          attachments: [],
          createdAt: timestamp,
          seq: seq++,
          phase: "final_answer",
        });
      }
      continue;
    }

    if (event.type === "session.plan_changed") {
      const activity = buildCopilotPlanChangedActivity({
        activityId:
          typeof event.id === "string"
            ? `copilot-plan:${event.id}`
            : `copilot-plan:${timestamp}`,
        turnId: null,
        operation: data.operation,
      });
      activities.set(activity.id, {
        ...activity,
        createdAt: timestamp,
        seq: seq++,
      });
      continue;
    }

    if (event.type === "session.task_complete") {
      const activity = buildCopilotTaskCompleteActivity({
        activityId:
          typeof event.id === "string"
            ? `copilot-task-complete:${event.id}`
            : `copilot-task-complete:${timestamp}`,
        turnId: null,
        success: data.success,
        summary: data.summary,
      });
      activities.set(activity.id, {
        ...activity,
        createdAt: timestamp,
        seq: seq++,
      });
      continue;
    }

    if (event.type === "assistant.reasoning_delta") {
      const activityId = copilotReasoningActivityId(event, seq);
      const existing = activities.get(activityId);
      const existingContent =
        existing?.type === "reasoning" ? existing.content ?? "" : "";
      const content = `${reasoningBuffers.get(activityId) ?? existingContent}${data.deltaContent ?? ""}`;
      reasoningBuffers.set(activityId, content);
      upsertParsedActivity(
        buildCopilotReasoningActivity({
          activityId,
          turnId: null,
          reasoningId: stringValue(data.reasoningId) ?? null,
          content,
          status: "in_progress",
          agentId: stringValue((event as { agentId?: unknown }).agentId) ?? null,
        }),
        timestamp,
      );
      continue;
    }

    if (event.type === "assistant.reasoning") {
      const activityId = copilotReasoningActivityId(event, seq);
      const content =
        stringValue(data.content) ?? reasoningBuffers.get(activityId) ?? null;
      if (content) {
        reasoningBuffers.set(activityId, content);
      }
      upsertParsedActivity(
        buildCopilotReasoningActivity({
          activityId,
          turnId: null,
          reasoningId: stringValue(data.reasoningId) ?? null,
          content,
          status: "completed",
          agentId: stringValue((event as { agentId?: unknown }).agentId) ?? null,
        }),
        timestamp,
      );
      continue;
    }

    const subagentActivity = buildCopilotSubagentActivity(event, null, seq);
    if (subagentActivity) {
      upsertParsedActivity(subagentActivity, timestamp);
      continue;
    }

    const notificationActivity = buildCopilotSystemNotificationActivity(
      event,
      null,
      seq,
    );
    if (notificationActivity) {
      upsertParsedActivity(notificationActivity, timestamp);
      continue;
    }

    const planReviewActivity = buildCopilotPlanReviewActivity(event, null, seq);
    if (planReviewActivity) {
      upsertParsedActivity(planReviewActivity, timestamp);
      continue;
    }

    const systemActivity = buildCopilotSystemEventFromEvent(event, null, seq);
    if (systemActivity) {
      upsertParsedActivity(systemActivity, timestamp);
      continue;
    }

    if (event.type === "user_input.requested") {
      rememberHiddenCopilotToolCall(hiddenToolCallIds, data.toolCallId);
      continue;
    }

    if (event.type === "elicitation.requested") {
      rememberHiddenCopilotToolCall(hiddenToolCallIds, data.toolCallId);
      continue;
    }

    if (
      event.type === "tool.execution_start" &&
      typeof data.toolCallId === "string"
    ) {
      const metadata = toolRequests.get(data.toolCallId) ?? null;
      const presentation = describeCopilotToolPresentation({
        toolCallId: data.toolCallId,
        toolName: data.toolName,
        args: data.arguments,
        metadata,
        hiddenToolCallIds,
      });
      if (presentation.kind === "hidden" || presentation.kind === "commentary") {
        continue;
      }
      activities.set(data.toolCallId, {
        id: data.toolCallId,
        type: "tool",
        turnId: null,
        createdAt: timestamp,
        seq: seq++,
        status: "in_progress",
        toolName: copilotToolName(data.toolName),
        title: presentation.title,
        args: data.arguments ?? null,
        output: null,
        result: null,
        isError: null,
        semantic:
          presentation.kind === "task"
            ? taskToolSemantic()
            : inferCopilotToolSemantic(data.toolName, data.arguments, null),
      });
      continue;
    }

    if (
      event.type === "tool.execution_complete" &&
      typeof data.toolCallId === "string"
    ) {
      if (typeof data.model === "string") {
        runtime = withRuntimeMetadata(runtime, {
          model: data.model,
          updatedAt: timestamp,
        });
      }
      const metadata = toolRequests.get(data.toolCallId) ?? null;
      const presentation = describeCopilotToolPresentation({
        toolCallId: data.toolCallId,
        toolName: data.toolName,
        args: data.arguments,
        result: data.result ?? data.error ?? null,
        metadata,
        hiddenToolCallIds,
      });
      if (presentation.kind === "hidden") {
        continue;
      }
      if (presentation.kind === "commentary") {
        const text = normalizeCopilotCommentaryText(presentation.commentary);
        if (text) {
          const latest = messages.at(-1);
          if (
            latest?.role !== "assistant" ||
            latest.phase !== "commentary" ||
            normalizeCopilotCommentaryText(latest.text) !== text
          ) {
            messages.push({
              id: `copilot-commentary:${data.toolCallId}`,
              role: "assistant",
              text,
              attachments: [],
              createdAt: timestamp,
              seq: seq++,
              phase: "commentary",
            });
          }
        }
        continue;
      }
      const existing = activities.get(data.toolCallId);
      const existingTool = existing?.type === "tool" ? existing : null;
      const output =
        (presentation.kind === "task" ? presentation.output : null) ??
        extractCopilotToolOutput(data.result ?? data.error) ??
        (existing?.type === "tool" || existing?.type === "command"
          ? existing.output
          : null);
      activities.set(data.toolCallId, {
        id: data.toolCallId,
        type: "tool",
        turnId: existingTool?.turnId ?? null,
        createdAt: existingTool?.createdAt ?? timestamp,
        seq: existingTool?.seq ?? seq++,
        status: data.success === false ? "failed" : "completed",
        toolName: existingTool?.toolName ?? copilotToolName(data.toolName),
        title: existingTool?.title ?? presentation.title,
        args: existingTool?.args ?? data.arguments ?? null,
        output,
        result: data.result ?? data.error ?? null,
        isError: data.success === false,
        semantic:
          presentation.kind === "task"
            ? taskToolSemantic()
            : mergeCopilotToolSemantic(
                existingTool,
                inferCopilotToolSemantic(
                  data.toolName,
                  existingTool?.args ?? data.arguments,
                  data.result ?? data.error ?? null,
                ),
              ),
      });
    }
  }

  if (runtime && updatedAt != null) {
    runtime = {
      ...runtime,
      updatedAt,
    };
  }

  return {
    messages,
    activities: [...activities.values()].sort(
      (left, right) => left.seq - right.seq,
    ),
    runtime,
    nextSeq: seq,
  };
}

function formatCopilotToolCommand(toolName: unknown, args: unknown): string {
  const name = copilotToolName(toolName);
  if (!args || typeof args !== "object") return name;
  return `${name} ${JSON.stringify(args)}`;
}

function rememberCopilotToolRequests(
  target: Map<string, CopilotToolRequestMetadata>,
  raw: unknown,
): void {
  if (!Array.isArray(raw)) {
    return;
  }
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") {
      continue;
    }
    const typed = entry as Record<string, unknown>;
    const toolCallId = stringValue(typed.toolCallId);
    if (!toolCallId) {
      continue;
    }
    target.set(toolCallId, {
      toolName: stringValue(typed.name) ?? "",
      toolTitle: stringValue(typed.toolTitle) ?? null,
      intentionSummary: stringValue(typed.intentionSummary) ?? null,
      mcpServerName: stringValue(typed.mcpServerName) ?? null,
      type: stringValue(typed.type) ?? null,
    });
  }
}

function rememberHiddenCopilotToolCall(
  target: Set<string>,
  toolCallId: unknown,
): void {
  if (typeof toolCallId === "string" && toolCallId.trim().length > 0) {
    target.add(toolCallId.trim());
  }
}

function normalizeStoredCopilotActivities(
  activities: SessionActivity[],
): SessionActivity[] {
  const normalized: SessionActivity[] = [];
  for (const activity of activities) {
    const stored = normalizeStoredSessionActivity(activity);
    if (stored.type !== "tool") {
      normalized.push(stored);
      continue;
    }

    const storedToolName = copilotStoredToolPresentationName(stored);
    const presentation = describeCopilotToolPresentation({
      toolCallId: stored.id,
      toolName: storedToolName,
      args: stored.args,
      result: stored.result,
      metadata: null,
    });
    if (
      presentation.kind === "hidden" ||
      presentation.kind === "commentary"
    ) {
      continue;
    }
    if (presentation.kind === "task") {
      const plan = buildCopilotPlanChangedActivity({
        activityId: stored.id,
        turnId: stored.turnId,
        operation: "update",
      });
      if (plan.type === "plan") {
        normalized.push({
          ...plan,
          createdAt: stored.createdAt,
          seq: stored.seq,
          summary: presentation.output ?? plan.summary,
        });
      }
      continue;
    }
    normalized.push(stored);
  }
  return normalized;
}

function copilotStoredToolPresentationName(
  activity: ToolActivity,
): string {
  const toolName = activity.toolName.trim();
  const toolKey = normalizeCopilotToolKey(toolName);
  if (
    toolKey &&
    toolKey !== "tool" &&
    toolKey !== "unknown" &&
    toolKey !== "tool_execution"
  ) {
    return toolName;
  }
  const titleToolName = copilotToolNameFromTitle(activity.title);
  return titleToolName ?? toolName;
}

function copilotToolNameFromTitle(title: string | null): string | null {
  const firstToken = title?.trim().split(/\s+/)[0];
  if (!firstToken) {
    return null;
  }
  const key = normalizeCopilotToolKey(firstToken);
  if (
    COPILOT_HIDDEN_TOOL_KEYS.has(key) ||
    COPILOT_COMMENTARY_TOOL_KEYS.has(key) ||
    COPILOT_TASK_TOOL_KEYS.has(key)
  ) {
    return firstToken;
  }
  return null;
}

function normalizeCopilotToolKey(value: unknown): string {
  return copilotToolName(value)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");
}

function normalizeCopilotCommentaryText(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim().replace(/\s+/g, " ");
  return normalized.length > 0 ? normalized : null;
}

function taskToolSemantic(): ToolActivitySemantic {
  return {
    category: "task",
    action: "invoke",
    targets: [],
  };
}

function buildCopilotPlanChangedActivity(options: {
  activityId: string;
  turnId: string | null;
  operation: unknown;
}): AgentSessionActivityDraft {
  const operation =
    options.operation === "create" ||
    options.operation === "update" ||
    options.operation === "delete"
      ? options.operation
      : "update";
  const output = {
    create: "Copilot created or initialized the working plan for this session.",
    update: "Copilot updated the working plan or todo list for this session.",
    delete: "Copilot cleared the working plan for this session.",
  }[operation];
  const action = {
    create: "created",
    update: "updated",
    delete: "cleared",
  }[operation] as "created" | "updated" | "cleared";
  return {
    id: options.activityId,
    type: "plan",
    turnId: options.turnId,
    status: "completed",
    action,
    title: {
      create: "Created session plan",
      update: "Updated session plan",
      delete: "Cleared session plan",
    }[operation],
    summary: output,
    content: null,
  };
}

function buildCopilotTaskCompleteActivity(options: {
  activityId: string;
  turnId: string | null;
  success: unknown;
  summary: unknown;
}): AgentSessionActivityDraft {
  const summary = stringValue(options.summary)?.trim() || null;
  const success = options.success !== false;
  return {
    id: options.activityId,
    type: "task",
    turnId: options.turnId,
    status: success ? "completed" : "failed",
    action: success ? "completed" : "failed",
    title: summary || (success ? "Completed task" : "Task failed"),
    summary:
      summary ||
      (success
        ? "Copilot marked the current task as complete."
        : "Copilot marked the current task as failed."),
  };
}

function buildCopilotReasoningActivity(options: {
  activityId: string;
  turnId: string | null;
  reasoningId: string | null;
  content: string | null;
  status: "in_progress" | "completed";
  agentId?: string | null;
}): AgentSessionActivityDraft {
  return {
    id: options.activityId,
    type: "reasoning",
    turnId: options.turnId,
    status: options.status,
    reasoningId: options.reasoningId,
    title: options.agentId ? "Subagent reasoning" : "Reasoning",
    content: options.content,
  };
}

function buildCopilotSubagentActivity(
  event: CopilotSdkSessionEvent,
  turnId: string | null,
  fallbackSeq?: number,
): AgentSessionActivityDraft | null {
  if (
    event.type !== "subagent.started" &&
    event.type !== "subagent.completed" &&
    event.type !== "subagent.failed" &&
    event.type !== "subagent.selected" &&
    event.type !== "subagent.deselected"
  ) {
    return null;
  }

  const data = asRecord(event.data) ?? {};
  const agentId =
    stringValue((event as { agentId?: unknown }).agentId) ??
    stringValue(data.agentId) ??
    null;
  const agentName = stringValue(data.agentName) ?? null;
  const agentDisplayName = stringValue(data.agentDisplayName) ?? null;
  const description =
    stringValue(data.agentDescription) ?? stringValue(data.description) ?? null;
  const toolCallId = stringValue(data.toolCallId);
  const lifecycleId =
    agentId ?? toolCallId ?? stringValue(event.id) ?? String(fallbackSeq ?? Date.now());
  const eventId = stringValue(event.id) ?? String(fallbackSeq ?? Date.now());
  const id =
    event.type === "subagent.selected" || event.type === "subagent.deselected"
      ? `copilot-subagent-selection:${eventId}`
      : `copilot-subagent:${lifecycleId}`;
  const action = {
    "subagent.started": "started",
    "subagent.completed": "completed",
    "subagent.failed": "failed",
    "subagent.selected": "selected",
    "subagent.deselected": "deselected",
  }[event.type] as
    | "started"
    | "completed"
    | "failed"
    | "selected"
    | "deselected";
  const status =
    action === "started"
      ? "in_progress"
      : action === "failed"
        ? "failed"
        : "completed";
  const tools = Array.isArray(data.tools)
    ? data.tools
        .map((tool) => (typeof tool === "string" ? tool.trim() : ""))
        .filter(Boolean)
    : null;
  return {
    id,
    type: "subagent",
    turnId,
    status,
    action,
    agentId,
    agentName,
    agentDisplayName,
    description,
    summary: copilotSubagentSummary(action, data, tools),
    durationMs: numericValue(data.durationMs) ?? null,
    model: stringValue(data.model) ?? null,
    totalTokens: numericValue(data.totalTokens) ?? null,
    totalToolCalls: numericValue(data.totalToolCalls) ?? null,
    error: stringValue(data.error) ?? null,
  };
}

function buildCopilotSystemNotificationActivity(
  event: CopilotSdkSessionEvent,
  turnId: string | null,
  fallbackSeq?: number,
): AgentSessionActivityDraft | null {
  if (event.type !== "system.notification") {
    return null;
  }
  const data = asRecord(event.data) ?? {};
  const kind = asRecord(data.kind) ?? {};
  const kindType = stringValue(kind.type);
  if (kindType === "agent_completed") {
    const agentId = stringValue(kind.agentId) ?? null;
    const status = stringValue(kind.status) === "failed" ? "failed" : "completed";
    return {
      id: `copilot-background-agent:${agentId ?? stringValue(event.id) ?? fallbackSeq ?? Date.now()}`,
      type: "subagent",
      turnId,
      status,
      action: status === "failed" ? "failed" : "completed",
      agentId,
      agentName: stringValue(kind.agentType) ?? null,
      agentDisplayName: stringValue(kind.agentType) ?? null,
      description: stringValue(kind.description) ?? stringValue(kind.prompt) ?? null,
      summary: stripCopilotSystemTags(stringValue(data.content) ?? "") || null,
      durationMs: null,
      model: null,
      totalTokens: null,
      totalToolCalls: null,
      error: status === "failed" ? stripCopilotSystemTags(stringValue(data.content) ?? "") || null : null,
    };
  }
  if (kindType === "agent_idle") {
    return {
      id: `copilot-background-agent:${stringValue(kind.agentId) ?? stringValue(event.id) ?? fallbackSeq ?? Date.now()}`,
      type: "subagent",
      turnId,
      status: "in_progress",
      action: "started",
      agentId: stringValue(kind.agentId) ?? null,
      agentName: stringValue(kind.agentType) ?? null,
      agentDisplayName: stringValue(kind.agentType) ?? null,
      description: stringValue(kind.description) ?? null,
      summary: stripCopilotSystemTags(stringValue(data.content) ?? "") || null,
      durationMs: null,
      model: null,
      totalTokens: null,
      totalToolCalls: null,
      error: null,
    };
  }
  return buildCopilotSystemEventActivity({
    activityId: `copilot-system-notification:${stringValue(event.id) ?? fallbackSeq ?? Date.now()}`,
    turnId,
    level: "info",
    title: copilotSystemNotificationTitle(kindType),
    detail:
      stripCopilotSystemTags(stringValue(data.content) ?? "") ||
      copilotCompactJson(kind),
  });
}

function buildCopilotPlanReviewActivity(
  event: CopilotSdkSessionEvent,
  turnId: string | null,
  fallbackSeq?: number,
): AgentSessionActivityDraft | null {
  if (
    event.type !== "exit_plan_mode.requested" &&
    event.type !== "exit_plan_mode.completed"
  ) {
    return null;
  }
  const data = asRecord(event.data) ?? {};
  const requestId =
    stringValue(data.requestId) ?? stringValue(event.id) ?? String(fallbackSeq ?? Date.now());
  const activityId = `copilot-plan-review:${requestId}`;
  if (event.type === "exit_plan_mode.requested") {
    return {
      id: activityId,
      type: "plan",
      turnId,
      status: "in_progress",
      action: "review_requested",
      title: "Plan review requested",
      summary:
        stringValue(data.summary) ??
        copilotPlanReviewActionsSummary(data) ??
        "The provider requested a plan review.",
      content: stringValue(data.planContent) ?? null,
    };
  }
  const approved = data.approved !== false;
  return {
    id: activityId,
    type: "plan",
    turnId,
    status: "completed",
    action: approved ? "approved" : "rejected",
    title: approved ? "Plan approved" : "Plan changes requested",
    summary:
      stringValue(data.feedback) ??
      (stringValue(data.selectedAction)
        ? `Selected action: ${stringValue(data.selectedAction)}`
        : approved
          ? "The plan review was approved."
          : "The plan review was rejected or sent back for changes."),
    content: null,
  };
}

function buildCopilotSystemEventFromEvent(
  event: CopilotSdkSessionEvent,
  turnId: string | null,
  fallbackSeq?: number,
): AgentSessionActivityDraft | null {
  const data = asRecord(event.data) ?? {};
  const eventId = stringValue(event.id) ?? String(fallbackSeq ?? Date.now());
  switch (event.type) {
    case "session.warning":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-warning:${eventId}`,
        turnId,
        level: "warning",
        title: copilotTypedMessageTitle("Warning", data.warningType),
        detail: joinCopilotDetail([stringValue(data.message), stringValue(data.url)]),
      });
    case "session.info":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-info:${eventId}`,
        turnId,
        level: "info",
        title: copilotTypedMessageTitle("Info", data.infoType),
        detail: joinCopilotDetail([stringValue(data.message), stringValue(data.url)]),
      });
    case "session.handoff":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-handoff:${eventId}`,
        turnId,
        level: "info",
        title: "Session handoff",
        detail: joinCopilotDetail([
          stringValue(data.summary),
          stringValue(data.context),
          stringValue(data.sourceType),
          stringValue(data.remoteSessionId),
          stringValue(data.host),
        ]),
      });
    case "session.truncation":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-truncation:${eventId}`,
        turnId,
        level: "info",
        title: "Conversation truncated",
        detail: joinCopilotDetail([
          copilotNumberDetail("Tokens removed", data.tokensRemovedDuringTruncation),
          copilotNumberDetail("Messages removed", data.messagesRemovedDuringTruncation),
          stringValue(data.performedBy)
            ? `Performed by: ${stringValue(data.performedBy)}`
            : null,
        ]),
      });
    case "session.workspace_file_changed":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-workspace-file:${eventId}`,
        turnId,
        level: "info",
        title: "Workspace file changed",
        detail: joinCopilotDetail([
          stringValue(data.operation),
          stringValue(data.path),
        ]),
      });
    case "system.message":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-system-message:${eventId}`,
        turnId,
        level: "info",
        title: "System instruction loaded",
        detail: joinCopilotDetail([
          stringValue(data.role) ? `Role: ${stringValue(data.role)}` : null,
          stringValue(data.name) ? `Name: ${stringValue(data.name)}` : null,
        ]),
      });
    case "mcp.oauth_required":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-mcp-oauth:${stringValue(data.requestId) ?? eventId}`,
        turnId,
        level: "warning",
        title: "MCP authentication required",
        detail: joinCopilotDetail([
          stringValue(data.serverName),
          stringValue(data.serverUrl),
        ]),
        status: "in_progress",
      });
    case "mcp.oauth_completed":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-mcp-oauth:${stringValue(data.requestId) ?? eventId}`,
        turnId,
        level: "info",
        title: "MCP authentication completed",
        detail: stringValue(data.requestId) ?? null,
      });
    case "sampling.requested":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-sampling:${stringValue(data.requestId) ?? eventId}`,
        turnId,
        level: "info",
        title: "MCP sampling requested",
        detail: joinCopilotDetail([
          stringValue(data.serverName),
          stringValue(data.requestId),
        ]),
        status: "in_progress",
      });
    case "sampling.completed":
      return buildCopilotSystemEventActivity({
        activityId: `copilot-sampling:${stringValue(data.requestId) ?? eventId}`,
        turnId,
        level: "info",
        title: "MCP sampling completed",
        detail: stringValue(data.requestId) ?? null,
      });
    default:
      return null;
  }
}

function buildCopilotSystemEventActivity(options: {
  activityId: string;
  turnId: string | null;
  level: "info" | "warning" | "error";
  title: string;
  detail: string | null;
  status?: "in_progress" | "completed" | "failed" | "declined";
}): AgentSessionActivityDraft {
  return {
    id: options.activityId,
    type: "system_event",
    turnId: options.turnId,
    status: options.status ?? "completed",
    level: options.level,
    title: options.title,
    detail: options.detail,
  };
}

function copilotSubagentSummary(
  action: "started" | "completed" | "failed" | "selected" | "deselected",
  data: Record<string, unknown>,
  tools: string[] | null,
): string | null {
  if (action === "started") {
    return "A background or specialized agent started working.";
  }
  if (action === "selected") {
    return tools == null
      ? "A custom agent was selected with access to all tools."
      : tools.length > 0
        ? `A custom agent was selected with ${tools.length} tools.`
        : "A custom agent was selected.";
  }
  if (action === "deselected") {
    return "The session returned to the default agent.";
  }
  const parts = [
    copilotNumberDetail("Tokens", data.totalTokens),
    copilotNumberDetail("Tool calls", data.totalToolCalls),
    copilotNumberDetail("Duration ms", data.durationMs),
  ].filter((part): part is string => part != null);
  if (parts.length > 0) {
    return parts.join("\n");
  }
  return action === "failed"
    ? stringValue(data.error) ?? "The subagent failed."
    : "The subagent completed.";
}

function copilotPlanReviewActionsSummary(
  data: Record<string, unknown>,
): string | null {
  const recommended = stringValue(data.recommendedAction);
  const actions = Array.isArray(data.actions)
    ? data.actions
        .map((action) => (typeof action === "string" ? action.trim() : ""))
        .filter(Boolean)
    : [];
  if (!recommended && actions.length === 0) {
    return null;
  }
  return joinCopilotDetail([
    recommended ? `Recommended action: ${recommended}` : null,
    actions.length > 0 ? `Available actions: ${actions.join(", ")}` : null,
  ]);
}

function copilotTypedMessageTitle(prefix: string, type: unknown): string {
  const label = stringValue(type);
  if (!label) {
    return `Copilot ${prefix.toLowerCase()}`;
  }
  return `Copilot ${prefix.toLowerCase()}: ${label.replace(/_/g, " ")}`;
}

function copilotSystemNotificationTitle(kindType: string | undefined): string {
  switch (kindType) {
    case "new_inbox_message":
      return "New inbox message";
    case "shell_completed":
      return "Shell completed";
    case "shell_detached_completed":
      return "Detached shell completed";
    default:
      return "System notification";
  }
}

function stripCopilotSystemTags(value: string): string {
  return value
    .replace(/<\/?system_notification>/gi, "")
    .replace(/\s+/g, " ")
    .trim();
}

function joinCopilotDetail(
  parts: Array<string | null | undefined>,
): string | null {
  const text = parts
    .map((part) => part?.trim() ?? "")
    .filter(Boolean)
    .join("\n");
  return text.length > 0 ? text : null;
}

function copilotNumberDetail(label: string, value: unknown): string | null {
  const number = numericValue(value);
  return number == null ? null : `${label}: ${number}`;
}

function copilotCompactJson(value: unknown): string | null {
  if (value == null) {
    return null;
  }
  try {
    return JSON.stringify(value);
  } catch {
    return null;
  }
}

function describeCopilotToolPresentation(options: {
  toolCallId?: unknown;
  toolName: unknown;
  args?: unknown;
  result?: unknown;
  metadata?: CopilotToolRequestMetadata | null;
  hiddenToolCallIds?: Set<string>;
}):
  | {
      kind: "hidden";
    }
  | {
      kind: "commentary";
      commentary: string | null;
    }
  | {
      kind: "task" | "tool";
      title: string;
      output: string | null;
    } {
  const toolKey = normalizeCopilotToolKey(
    options.metadata?.toolName || options.toolName,
  );
  const toolCallId =
    typeof options.toolCallId === "string" ? options.toolCallId : null;
  if (
    (toolCallId && options.hiddenToolCallIds?.has(toolCallId)) ||
    COPILOT_HIDDEN_TOOL_KEYS.has(toolKey)
  ) {
    return { kind: "hidden" };
  }
  if (COPILOT_COMMENTARY_TOOL_KEYS.has(toolKey)) {
    return {
      kind: "commentary",
      commentary: extractCopilotNarrativeText(
        options.metadata,
        options.args,
        options.result,
      ),
    };
  }
  const title = copilotToolDisplayTitle(
    options.toolName,
    options.args,
    options.metadata,
  );
  if (COPILOT_TASK_TOOL_KEYS.has(toolKey)) {
    return {
      kind: "task",
      title,
      output:
        extractCopilotNarrativeText(options.metadata, options.args, options.result) ??
        title,
    };
  }
  return {
    kind: "tool",
    title,
    output: null,
  };
}

function copilotToolDisplayTitle(
  toolName: unknown,
  args: unknown,
  metadata?: CopilotToolRequestMetadata | null,
): string {
  const intention = metadata?.intentionSummary?.trim();
  if (intention) {
    return intention;
  }
  const title = metadata?.toolTitle?.trim();
  if (title) {
    return title;
  }
  return formatCopilotToolCommand(toolName, args);
}

function extractCopilotNarrativeText(
  metadata: CopilotToolRequestMetadata | null | undefined,
  args: unknown,
  result: unknown,
): string | null {
  const fromMetadata = normalizeCopilotCommentaryText(
    metadata?.intentionSummary ?? metadata?.toolTitle ?? null,
  );
  if (fromMetadata) {
    return fromMetadata;
  }
  const typedArgs = asRecord(args);
  const typedResult = asRecord(result);
  return (
    normalizeCopilotCommentaryText(
      readFirstString(
        typedResult,
        ["intent", "summary", "message", "content", "text", "title"],
        typedArgs,
      ),
    ) ??
    normalizeCopilotCommentaryText(extractCopilotToolOutput(result))
  );
}

function copilotToolName(value: unknown): string {
  return typeof value === "string" && value.length > 0 ? value : "tool";
}

function extractCopilotToolOutput(result: unknown): string | null {
  if (!result || typeof result !== "object") return null;
  const data = result as Record<string, unknown>;
  const content = data.detailedContent ?? data.content ?? data.message;
  return typeof content === "string" ? content : JSON.stringify(result);
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

function copilotReasoningActivityId(
  event: CopilotSdkSessionEvent,
  fallbackSeq?: number,
): string {
  const data = asRecord(event.data) ?? {};
  const reasoningId =
    stringValue(data.reasoningId) ??
    stringValue(event.id) ??
    String(fallbackSeq ?? Date.now());
  const agentId = stringValue((event as { agentId?: unknown }).agentId);
  return agentId
    ? `copilot-reasoning:${agentId}:${reasoningId}`
    : `copilot-reasoning:${reasoningId}`;
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
      default:
        return [];
    }
  });
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

function cloneMessage(message: SessionMessage): SessionMessage {
  return {
    ...message,
    attachments: message.attachments.map((attachment) => ({ ...attachment })),
  };
}

function cloneActivity(activity: SessionActivity): SessionActivity {
  if (activity.type === "command") {
    return {
      ...activity,
      commandActions: activity.commandActions.map((action) => ({ ...action })),
    };
  }
  if (activity.type === "file_change") {
    return {
      ...activity,
      changes: activity.changes.map((change) => ({ ...change })),
    };
  }
  return { ...activity };
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
