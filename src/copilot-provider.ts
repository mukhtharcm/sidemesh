import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import nodePath from "node:path";

import {
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
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
  approveOnce,
  createCopilotSdkClient,
  rejectPermission,
  type CopilotSdkClient,
  type CopilotSdkClientFactory,
  type CopilotSdkModelInfo,
  type CopilotSdkPermissionRequest,
  type CopilotSdkPermissionResult,
  type CopilotSdkReasoningEffort,
  type CopilotSdkSession,
  type CopilotSdkSessionConfig,
  type CopilotSdkSessionEvent,
  type CopilotSdkSessionMetadata,
} from "./copilot-sdk-client.js";
import type {
  ModelSummary,
  SessionActivity,
  SessionLogSnapshot,
  SessionMessage,
  SessionMessageAttachment,
  SessionRuntimeSummary,
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

export const COPILOT_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
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
    imageUrl: false,
    localImage: false,
    skills: false,
  },
  approvals: {
    command: true,
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
    reasoningEffort: true,
    fastMode: false,
    approvalPolicy: false,
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
  private readonly pendingPermissions = new Map<string, PendingCopilotPermission>();
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
        sdkSessionToThread(session, this.sessions.get(session.sessionId), false),
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
        sdkSessionToThread(session, this.sessions.get(session.sessionId), false),
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
    const session = this.sessions.get(thread.id) ??
      (await this.loadSdkSessionStateFromHistory(thread.id));
    const messages = limitTail(session.messages, options.messageLimit ?? null);
    const activities = limitTail(
      [...session.activities.values()].sort((left, right) => left.seq - right.seq),
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
    const session = this.sessions.get(thread.id) ??
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
    );

    if (this.activeTurns.has(session.thread.id)) {
      // Copilot's non-interactive prompt mode cannot accept steering input
      // mid-turn, so acknowledge the steer without adding unprocessed history.
      return {
        mode: "steer",
        turnId: this.activeTurns.get(session.thread.id)?.turnId ?? null,
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
    this.completeActiveTurn(threadId, "interrupted");
    await this.persistSoon();
    return { interrupted: true };
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: string | null,
  ): boolean {
    if (!decision) {
      return false;
    }
    const pending = this.pendingPermissions.get(action.id);
    if (!pending) {
      return false;
    }
    const result = buildCopilotPermissionResult(
      decision,
      pending.action.providerPayload,
    );
    if (!result) {
      return false;
    }
    this.pendingPermissions.delete(action.id);
    pending.resolve(result);
    return true;
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
      runtime: mergeRuntime(null, request.overrides, this.configuredModel),
      archived: false,
      nextSeq: 0,
      copilotSessionId: id,
      copilotSessionCreated: false,
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
        prompt: inputText(input),
        attachments: sdkAttachments(input),
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
      this.failTurn(
        current,
        turnId,
        `Copilot SDK error: ${text}`,
      );
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
      ? await client.resumeSession(session.copilotSessionId ?? session.thread.id, {
          ...config,
          disableResume: true,
        })
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
      onEvent: (event) => this.handleSdkEvent(session.thread.id, event),
    };
  }

  private async applyRuntimeControls(
    session: CopilotSessionState,
    sdkSession: CopilotSdkSession,
  ): Promise<void> {
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

  private handleSdkEvent(sessionId: string, event: CopilotSdkSessionEvent): void {
    const session = this.sessions.get(sessionId);
    if (!session) {
      return;
    }
    const active = this.activeTurns.get(sessionId);

    if (event.type === "session.model_change") {
      session.runtime = {
        ...(session.runtime ?? {}),
        modelProvider: "copilot",
        model: event.data.newModel,
        updatedAt: Date.now(),
      };
      void this.persistSoon();
      return;
    }

    if (event.type === "assistant.message_delta") {
      if (!active) {
        return;
      }
      const delta = event.data.deltaContent;
      const messageId = event.data.messageId || `copilot-assistant-${active.turnId}`;
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
      void this.persistSoon();
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
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId,
        type: "command",
        turnId: active?.turnId ?? null,
        status: "in_progress",
        command: formatCopilotToolCommand(
          event.data.toolName,
          event.data.arguments,
        ),
        cwd: session.thread.cwd,
        output: null,
        exitCode: null,
        durationMs: null,
        source: "copilot",
        processId: null,
        commandActions: [
          { kind: "unknown", label: event.data.toolName ?? "tool" },
        ],
        terminalStatus: null,
        terminalInput: null,
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
      const existing = session.activities.get(event.data.toolCallId);
      this.upsertAndEmitActivity(session, active?.turnId ?? null, {
        id: event.data.toolCallId,
        type: "command",
        turnId: active?.turnId ?? null,
        status: event.data.success ? "completed" : "failed",
        command:
          existing?.type === "command"
            ? existing.command
            : formatCopilotToolCommand("tool", null),
        cwd: session.thread.cwd,
        output: extractCopilotToolOutput(event.data.result ?? event.data.error),
        exitCode: event.data.success ? 0 : 1,
        durationMs: null,
        source: "copilot",
        processId: null,
        commandActions:
          existing?.type === "command"
            ? existing.commandActions
            : [{ kind: "unknown", label: "tool" }],
        terminalStatus: null,
        terminalInput: null,
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
    const turn = session.turns.find((candidate) => candidate.id === active.turnId);
    if (turn?.status === "inProgress") {
      this.finishTurn(session, turn, status);
    }
    active.resolve(status);
    void this.persistSoon();
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
    void this.persistSoon();
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
    const existing = session.activities.get(activity.id);
    const next = {
      ...activity,
      createdAt: existing?.createdAt ?? Date.now(),
      seq: existing?.seq ?? session.nextSeq++,
    } as SessionActivity;
    session.activities.set(activity.id, next);
    this.touch(session);
    void this.persistSoon();
    return next;
  }

  private appendActivityOutput(
    session: CopilotSessionState,
    turnId: string | null,
    activityId: string,
    delta: string,
  ): void {
    const existing = session.activities.get(activityId);
    if (existing?.type === "command") {
      session.activities.set(activityId, {
        ...existing,
        output: `${existing.output ?? ""}${delta}`,
      });
      this.touch(session);
      void this.persistSoon();
    }
    this.emit("liveEvent", {
      type: "activity_output_delta",
      sessionId: session.thread.id,
      turnId: turnId ?? undefined,
      activityId,
      delta,
    });
  }

  private async handlePermissionRequest(
    sessionId: string,
    request: CopilotSdkPermissionRequest,
  ): Promise<CopilotSdkPermissionResult> {
    if (this.allowAll) {
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

  private appendUserMessage(
    session: CopilotSessionState,
    input: AgentSessionInputItem[],
  ): void {
    this.appendMessage(session, {
      role: "user",
      text: inputText(input),
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
            (item.activities ?? []).map((activity) => [activity.id, activity]),
          ),
          turns: item.turns ?? [],
          runtime: normalizeStoredRuntime(item.runtime ?? null),
          archived: item.archived === true,
          nextSeq: item.nextSeq ?? item.messages?.length ?? 0,
          copilotSessionId: item.copilotSessionId ?? null,
          copilotSessionCreated:
            item.copilotSessionCreated ?? item.copilotSessionId != null,
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
    return (await this.listSdkSessionMetadata()).find(
      (session) => session.sessionId === sessionId,
    ) ?? null;
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
    };
    const sdkSession = await (await this.ensureSdkClient()).resumeSession(
      sessionId,
      {
        ...this.buildSdkSessionConfig(state),
        disableResume: true,
      },
    );
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

function assistantPhase(phase: string | undefined): "commentary" | "final_answer" {
  return phase === "thinking" || phase === "reasoning"
    ? "commentary"
    : "final_answer";
}

function sdkAttachments(
  input: AgentSessionInputItem[],
): import("./copilot-sdk-client.js").CopilotSdkMessageOptions["attachments"] {
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
    }
  }
  return attachments.length > 0 ? attachments : undefined;
}

function buildCopilotPendingAction(
  session: CopilotSessionState,
  request: CopilotSdkPermissionRequest,
): AgentPendingAction {
  const typed = request as Record<string, any>;
  const actionId = `copilot-permission-${randomUUID()}`;
  return {
    id: actionId,
    sessionId: session.thread.id,
    kind: copilotPendingActionKind(request.kind),
    title: copilotPermissionTitle(request.kind),
    detail: copilotPermissionDetail(typed),
    requestedAt: Date.now(),
    canApprove: true,
    canApproveForSession: canApproveCopilotPermissionForSession(typed),
    canDecline: true,
    sessionTitle: session.thread.name ?? session.thread.preview,
    cwd: session.thread.cwd,
    providerRequestId: actionId,
    providerRequestKind: `copilot/${request.kind}/requestPermission`,
    providerPayload: request,
  };
}

function copilotPendingActionKind(
  kind: CopilotSdkPermissionRequest["kind"],
): AgentPendingAction["kind"] {
  if (kind === "shell") return "command";
  if (kind === "write") return "file_change";
  return "permissions";
}

function copilotPermissionTitle(kind: CopilotSdkPermissionRequest["kind"]): string {
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
  }
}

function copilotPermissionDetail(request: Record<string, any>): string {
  if (typeof request.fullCommandText === "string") {
    return request.fullCommandText;
  }
  if (typeof request.diff === "string" && typeof request.fileName === "string") {
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

function canApproveCopilotPermissionForSession(
  request: Record<string, any>,
): boolean {
  if (request.kind === "shell" || request.kind === "write") {
    return request.canOfferSessionApproval === true;
  }
  return ["read", "mcp", "custom-tool", "memory"].includes(request.kind);
}

function buildCopilotPermissionResult(
  decision: string,
  request: unknown,
): CopilotSdkPermissionResult | null {
  if (decision === "accept") {
    return approveOnce();
  }
  if (decision === "acceptForSession") {
    const approval = copilotSessionApproval(request);
    return approval ? { kind: "approve-for-session", approval } : approveOnce();
  }
  if (decision === "decline" || decision === "cancel") {
    return rejectPermission();
  }
  return null;
}

function copilotSessionApproval(request: unknown): CopilotSessionApproval | null {
  if (!request || typeof request !== "object") {
    return null;
  }
  const typed = request as Record<string, any>;
  switch (typed.kind) {
    case "shell": {
      const commandIdentifiers = Array.isArray(typed.commands)
        ? typed.commands
            .map((command: Record<string, unknown>) => command.identifier)
            .filter((identifier: unknown): identifier is string =>
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
      return {
        kind: "mcp",
        serverName: String(typed.serverName ?? ""),
        toolName: typeof typed.toolName === "string" ? typed.toolName : null,
      };
    case "memory":
      return { kind: "memory" };
    case "custom-tool":
      return {
        kind: "custom-tool",
        toolName: String(typed.toolName ?? ""),
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
    status: local?.thread.status ? { ...local.thread.status } : { type: "idle" },
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
  const activities = new Map<string, import("./types.js").CommandActivity>();
  let seq = 0;
  let model: string | undefined;
  let updatedAt: number | undefined;

  for (const event of events) {
    const timestamp = millisFromDateLike(event.timestamp) ?? Date.now();
    updatedAt = timestamp;
    const data = (event.data ?? {}) as Record<string, any>;

    if (event.type === "session.model_change" && typeof data.newModel === "string") {
      model = data.newModel;
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

    if (event.type === "assistant.message" && typeof data.content === "string") {
      if (typeof data.model === "string") model = data.model;
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

    if (
      event.type === "tool.execution_start" &&
      typeof data.toolCallId === "string"
    ) {
      activities.set(data.toolCallId, {
        id: data.toolCallId,
        type: "command",
        turnId: null,
        createdAt: timestamp,
        seq: seq++,
        status: "in_progress",
        command: formatCopilotToolCommand(data.toolName, data.arguments),
        cwd,
        output: null,
        exitCode: null,
        durationMs: null,
        source: "copilot",
        processId: null,
        commandActions: [{ kind: "unknown", label: data.toolName ?? "tool" }],
        terminalStatus: null,
        terminalInput: null,
      });
      continue;
    }

    if (
      event.type === "tool.execution_complete" &&
      typeof data.toolCallId === "string"
    ) {
      if (typeof data.model === "string") model = data.model;
      const existing = activities.get(data.toolCallId);
      activities.set(data.toolCallId, {
        ...(existing ?? {
          id: data.toolCallId,
          type: "command",
          turnId: null,
          createdAt: timestamp,
          seq: seq++,
          command: formatCopilotToolCommand(data.toolName, null),
          cwd,
          output: null,
          exitCode: null,
          durationMs: null,
          source: "copilot",
          processId: null,
          commandActions: [{ kind: "unknown", label: data.toolName ?? "tool" }],
          terminalStatus: null,
          terminalInput: null,
        }),
        status: data.success === false ? "failed" : "completed",
        output: extractCopilotToolOutput(data.result),
        exitCode: data.success === false ? 1 : 0,
      });
    }
  }

  const runtime: SessionRuntimeSummary | null = model
    ? {
        model,
        modelProvider: "copilot",
        updatedAt: updatedAt ?? Date.now(),
      }
    : null;

  return {
    messages,
    activities: [...activities.values()].sort((left, right) => left.seq - right.seq),
    runtime,
    nextSeq: seq,
  };
}

function formatCopilotToolCommand(toolName: unknown, args: unknown): string {
  const name = typeof toolName === "string" ? toolName : "tool";
  if (!args || typeof args !== "object") return name;
  return `${name} ${JSON.stringify(args)}`;
}

function extractCopilotToolOutput(result: unknown): string | null {
  if (!result || typeof result !== "object") return null;
  const data = result as Record<string, unknown>;
  const content = data.detailedContent ?? data.content ?? data.message;
  return typeof content === "string" ? content : JSON.stringify(result);
}

function secondsFromDate(value: Date | string | undefined, fallback: number): number {
  const millis = millisFromDateLike(value);
  return millis == null ? fallback : millis / 1000;
}

function millisFromDateLike(value: Date | string | undefined): number | null {
  if (!value) return null;
  const millis = value instanceof Date ? value.getTime() : Date.parse(value);
  return Number.isFinite(millis) ? millis : null;
}

function mergeRuntime(
  runtime: SessionRuntimeSummary | null,
  overrides: {
    model: string | null;
    reasoningEffort: string | null;
  },
  configuredModel: string | null,
): SessionRuntimeSummary {
  const model =
    overrides.model ??
    runtime?.model ??
    configuredModel ??
    DEFAULT_SIDEMESH_COPILOT_MODEL;
  const reasoningEffort =
    overrides.reasoningEffort ?? runtime?.reasoningEffort ?? null;
  return {
    ...(runtime ?? {}),
    modelProvider: "copilot",
    ...(model ? { model } : {}),
    ...(reasoningEffort ? { reasoningEffort } : {}),
    updatedAt: Date.now(),
  };
}

function normalizeStoredRuntime(
  runtime: SessionRuntimeSummary | null,
): SessionRuntimeSummary | null {
  if (!runtime) return null;
  if (runtime.model === "gpt-5.2" && runtime.modelProvider === "copilot") {
    const { model: _model, ...rest } = runtime;
    return {
      ...rest,
      modelProvider: "copilot",
    };
  }
  return {
    ...runtime,
    modelProvider: "copilot",
  };
}

function previewFromInput(input: AgentSessionInputItem[]): string {
  const text = inputText(input).trim();
  return text.length > 80 ? `${text.slice(0, 77)}...` : text;
}

function inputText(input: AgentSessionInputItem[]): string {
  return input
    .map((item) => {
      switch (item.type) {
        case "text":
          return item.text;
        case "image":
          return `[unsupported image:${item.url}]`;
        case "localImage":
          return `[unsupported local image:${item.path}]`;
        case "skill":
          return `$${item.name}`;
      }
    })
    .filter(Boolean)
    .join("\n");
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
