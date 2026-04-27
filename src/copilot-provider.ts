import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import nodePath from "node:path";

import {
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
  type AgentModelListOptions,
  type AgentProvider,
  type AgentProviderCapabilities,
  type AgentProviderEvents,
  type AgentSessionInputItem,
  type AgentSessionListOptions,
  type AgentSessionLogOptions,
  type AgentSessionResumeOptions,
  type AgentSubmitInputRequest,
  type AgentSubmitInputResult,
} from "./agent-provider.js";
import type {
  ModelSummary,
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
  sessionStateDir?: string | null;
  allowAll?: boolean;
}

interface CopilotSessionState {
  thread: ThreadRecord;
  messages: SessionMessage[];
  turns: TurnRecord[];
  runtime: SessionRuntimeSummary | null;
  archived: boolean;
  nextSeq: number;
  copilotSessionId: string | null;
}

interface CopilotStateFile {
  nativeArchivedSessionIds?: string[];
  sessions: Array<{
    thread: ThreadRecord;
    messages: SessionMessage[];
    turns: TurnRecord[];
    runtime: SessionRuntimeSummary | null;
    archived?: boolean;
    nextSeq: number;
    copilotSessionId?: string | null;
  }>;
}

interface CopilotNativeSessionMetadata {
  id: string;
  dir: string;
  cwd: string;
  summary: string | null;
  createdAt: number;
  updatedAt: number;
  branch: string | null;
  repository: string | null;
  eventsPath: string;
}

const DEFAULT_COPILOT_STATE_DIR = nodePath.join(
  homedir(),
  ".sidemesh",
  "copilot-provider",
);
const DEFAULT_COPILOT_SESSION_STATE_DIR = nodePath.join(
  homedir(),
  ".copilot",
  "session-state",
);

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
    command: false,
    fileChange: false,
    permissions: false,
    approveForSession: false,
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
  private readonly sessionStateDir: string;
  private readonly allowAll: boolean;
  private readonly sessions = new Map<string, CopilotSessionState>();
  private readonly nativeArchivedSessionIds = new Set<string>();
  private readonly loadedSessionIds = new Set<string>();
  private readonly activeTurns = new Map<
    string,
    { turnId: string; child: ChildProcessWithoutNullStreams }
  >();
  private saveChain: Promise<void> = Promise.resolve();

  public constructor(options: CopilotAgentProviderOptions = {}) {
    super();
    this.bin = options.bin?.trim() || "copilot";
    this.stateDir = nodePath.resolve(
      options.stateDir || DEFAULT_COPILOT_STATE_DIR,
    );
    this.sessionStateDir = nodePath.resolve(
      options.sessionStateDir || DEFAULT_COPILOT_SESSION_STATE_DIR,
    );
    this.allowAll = options.allowAll === true;
  }

  public async start(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true });
    await this.loadState();
  }

  public async getVersion(): Promise<string> {
    const output = await runProcess(this.bin, ["--version"], process.cwd());
    return output
      .trim()
      .split(/\r?\n/)
      .find((line) => line.trim().length > 0)
      ?.trim() || "unknown";
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    const native = await this.listNativeSessionMetadata();
    const nativeIds = new Set(native.map((session) => session.id));
    const nativeThreads = native
      .filter((session) =>
        options.archived
          ? this.nativeArchivedSessionIds.has(session.id)
          : !this.nativeArchivedSessionIds.has(session.id),
      )
      .map((session) => nativeSessionToThread(session, false));
    const sidemeshThreads = [...this.sessions.values()]
      .filter((session) => !nativeIds.has(session.thread.id))
      .filter((session) => session.archived === options.archived)
      .map((session) => cloneThread(session, false));
    return [...nativeThreads, ...sidemeshThreads]
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, options.limit)
      .map(cloneThreadRecord);
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    const native = await this.listNativeSessionMetadata();
    const nativeIds = new Set(native.map((session) => session.id));
    const nativeThreads = native
      .filter((session) => !this.nativeArchivedSessionIds.has(session.id))
      .map((session) => nativeSessionToThread(session, false));
    const sidemeshThreads = [...this.sessions.values()]
      .filter((session) => !nativeIds.has(session.thread.id))
      .filter((session) => !session.archived)
      .map((session) => cloneThread(session, false));
    return [...nativeThreads, ...sidemeshThreads]
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, limit)
      .map(cloneThreadRecord);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    const native = await this.readNativeSessionMetadata(threadId);
    if (native) {
      return nativeSessionToThread(native, includeTurns);
    }
    return cloneThread(this.requireSession(threadId), includeTurns);
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    const native = await this.readNativeSessionMetadata(thread.id);
    if (native) {
      const nativeLog = await readNativeSessionLog(native, options);
      const imported = this.sessions.get(thread.id);
      if (imported && imported.messages.length > nativeLog.totalMessages) {
        const messages = limitTail(
          imported.messages,
          options.messageLimit ?? null,
        );
        return {
          ...nativeLog,
          messages: messages.map(cloneMessage),
          totalMessages: imported.messages.length,
          nextSeq: Math.max(nativeLog.nextSeq, imported.nextSeq),
        };
      }
      return nativeLog;
    }
    const session = this.requireSession(thread.id);
    const messages = limitTail(session.messages, options.messageLimit ?? null);
    return {
      messages: messages.map(cloneMessage),
      activities: [],
      runtime: session.runtime ? { ...session.runtime } : null,
      totalMessages: session.messages.length,
      totalActivities: 0,
      nextSeq: session.nextSeq,
    };
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    const native = await this.readNativeSessionMetadata(thread.id);
    if (native) {
      return readNativeRuntime(native);
    }
    const runtime = this.requireSession(thread.id).runtime;
    return runtime ? { ...runtime } : null;
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    return [...this.loadedSessionIds];
  }

  public async resumeSessionThread(
    threadId: string,
    _options?: AgentSessionResumeOptions,
  ): Promise<unknown> {
    if (!(await this.readNativeSessionMetadata(threadId))) {
      this.requireSession(threadId);
    }
    this.loadedSessionIds.add(threadId);
    return { resumed: true };
  }

  public async setSessionName(
    threadId: string,
    name: string,
  ): Promise<unknown> {
    const native = await this.readNativeSessionMetadata(threadId);
    if (native) {
      await writeNativeSummary(native, name);
      return { renamed: true };
    }
    const session = this.requireSession(threadId);
    session.thread.name = name;
    this.touch(session);
    await this.persistSoon();
    return { renamed: true };
  }

  public async archiveSession(threadId: string): Promise<unknown> {
    const native = await this.readNativeSessionMetadata(threadId);
    if (native) {
      this.nativeArchivedSessionIds.add(threadId);
      await this.interruptTurn(
        threadId,
        this.activeTurns.get(threadId)?.turnId ?? "",
      );
      this.loadedSessionIds.delete(threadId);
      await this.persistSoon();
      return { archived: true };
    }
    const session = this.requireSession(threadId);
    session.archived = true;
    await this.interruptTurn(
      threadId,
      this.activeTurns.get(threadId)?.turnId ?? "",
    );
    this.loadedSessionIds.delete(threadId);
    this.touch(session);
    await this.persistSoon();
    return { archived: true };
  }

  public async unarchiveSession(threadId: string): Promise<unknown> {
    if (this.nativeArchivedSessionIds.delete(threadId)) {
      await this.persistSoon();
      return { unarchived: true };
    }
    const session = this.requireSession(threadId);
    session.archived = false;
    this.touch(session);
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
    session.runtime = mergeRuntime(session.runtime, request.overrides);

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
    active.child.kill("SIGTERM");
    this.activeTurns.delete(threadId);
    const session = this.sessions.get(threadId);
    if (!session) {
      return { interrupted: true };
    }
    const turn = session.turns.find((candidate) => candidate.id === turnId);
    if (turn && turn.status === "inProgress") {
      this.finishTurn(session, turn, "interrupted");
      await this.persistSoon();
    }
    return { interrupted: true };
  }

  public async listModels(
    _options: AgentModelListOptions,
  ): Promise<ModelSummary[]> {
    return [
      copilotModel("gpt-5.2", "GPT-5.2", true, 0),
      copilotModel("gpt-5.1", "GPT-5.1", false, 1),
      copilotModel("claude-sonnet-4-5", "Claude Sonnet 4.5", false, 2),
      copilotModel("sonnet", "Claude Sonnet", false, 3),
    ];
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
      path: nodePath.join(this.sessionStateDir, id),
      status: { type: "idle" },
      turns: [],
    };
    const session: CopilotSessionState = {
      thread,
      messages: [],
      turns: [],
      runtime: mergeRuntime(null, request.overrides),
      archived: false,
      nextSeq: 0,
      copilotSessionId: id,
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

    const prompt = inputText(input);
    const args = this.buildCopilotArgs(session, prompt);
    const child = spawn(this.bin, args, {
      cwd: session.thread.cwd || process.cwd(),
      env: { ...process.env, NO_COLOR: "1" },
    });
    this.activeTurns.set(sessionId, { turnId, child });

    const chunks: string[] = [];
    child.stdout.on("data", (chunk: Buffer) => {
      const delta = chunk.toString("utf8");
      chunks.push(delta);
      this.emit("liveEvent", {
        type: "assistant_delta",
        sessionId,
        turnId,
        itemId: `copilot-assistant-${turnId}`,
        delta,
      });
    });
    child.stderr.on("data", (chunk: Buffer) => {
      this.emit("stderr", chunk.toString("utf8"));
    });

    const exitCode = await waitForChild(child);
    const current = this.sessions.get(sessionId);
    if (!current || this.activeTurns.get(sessionId)?.turnId !== turnId) {
      return;
    }
    this.activeTurns.delete(sessionId);

    const output = chunks.join("").trim();
    const turn = this.requireTurn(current, turnId);
    if (output.length > 0) {
      this.appendAssistantMessage(
        current,
        turnId,
        output,
        "final_answer",
        `copilot-assistant-${turnId}`,
      );
      this.emit("liveEvent", {
        type: "assistant_message_completed",
        sessionId,
        turnId,
        message: {
          id: `copilot-assistant-${turnId}`,
          text: output,
          phase: "final_answer",
        },
      });
    } else if (exitCode !== 0) {
      const text = `Copilot exited with code ${exitCode}.`;
      this.appendAssistantMessage(current, turnId, text, "final_answer");
      this.emit("liveEvent", {
        type: "assistant_message_completed",
        sessionId,
        turnId,
        message: {
          id: `copilot-assistant-error-${turnId}`,
          text,
          phase: "final_answer",
        },
      });
    }

    this.finishTurn(current, turn, exitCode === 0 ? "completed" : "failed");
    await this.persistSoon();
  }

  private buildCopilotArgs(
    session: CopilotSessionState,
    prompt: string,
  ): string[] {
    const args = [
      "-p",
      prompt,
      "--silent",
      "--stream",
      "on",
      "--no-color",
      "--no-ask-user",
      "--name",
      session.thread.name ?? session.thread.preview,
      `--resume=${session.copilotSessionId ?? session.thread.id}`,
    ];
    if (session.runtime?.model) {
      args.push("--model", session.runtime.model);
    }
    if (session.runtime?.reasoningEffort) {
      args.push("--effort", session.runtime.reasoningEffort);
    }
    if (this.allowAll) {
      args.push("--allow-all");
    }
    return args;
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
    const native = await this.readNativeSessionMetadata(threadId);
    if (!native) return this.requireSession(threadId);
    const log = await readNativeSessionLog(native, {});
    const state: CopilotSessionState = {
      thread: nativeSessionToThread(native, false),
      messages: log.messages,
      turns: [],
      runtime: log.runtime,
      archived: this.nativeArchivedSessionIds.has(threadId),
      nextSeq: log.nextSeq,
      copilotSessionId: native.id,
    };
    this.sessions.set(threadId, state);
    return state;
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
      for (const id of parsed.nativeArchivedSessionIds ?? []) {
        this.nativeArchivedSessionIds.add(id);
      }
      for (const item of parsed.sessions ?? []) {
        const state: CopilotSessionState = {
          thread: item.thread,
          messages: item.messages ?? [],
          turns: item.turns ?? [],
          runtime: item.runtime ?? null,
          archived: item.archived === true,
          nextSeq: item.nextSeq ?? item.messages?.length ?? 0,
          copilotSessionId: item.copilotSessionId ?? null,
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
      nativeArchivedSessionIds: [...this.nativeArchivedSessionIds],
      sessions: [...this.sessions.values()].map((session) => ({
        thread: cloneThread(session, true),
        messages: session.messages.map(cloneMessage),
        turns: session.turns.map(cloneTurn),
        runtime: session.runtime ? { ...session.runtime } : null,
        archived: session.archived,
        nextSeq: session.nextSeq,
        copilotSessionId: session.copilotSessionId,
      })),
    };
    await writeFile(this.statePath, JSON.stringify(payload, null, 2));
  }

  private get statePath(): string {
    return nodePath.join(this.stateDir, "sessions.json");
  }

  private async listNativeSessionMetadata(): Promise<CopilotNativeSessionMetadata[]> {
    let entries: string[];
    try {
      entries = await readdir(this.sessionStateDir);
    } catch {
      return [];
    }
    const sessions = await Promise.all(
      entries.map((entry) => this.readNativeSessionMetadata(entry)),
    );
    return sessions.filter(
      (session): session is CopilotNativeSessionMetadata => session !== null,
    );
  }

  private async readNativeSessionMetadata(
    sessionId: string,
  ): Promise<CopilotNativeSessionMetadata | null> {
    if (!isUuid(sessionId)) return null;
    const dir = nodePath.join(this.sessionStateDir, sessionId);
    const workspacePath = nodePath.join(dir, "workspace.yaml");
    try {
      const [workspaceRaw, dirStat] = await Promise.all([
        readFile(workspacePath, "utf8"),
        stat(dir),
      ]);
      const workspace = parseSimpleYaml(workspaceRaw);
      const id = workspace.id || sessionId;
      const cwd = workspace.cwd || this.sessions.get(id)?.thread.cwd || dir;
      const createdAt =
        secondsFromIso(workspace.created_at) ?? dirStat.birthtimeMs / 1000;
      const updatedAt =
        secondsFromIso(workspace.updated_at) ?? dirStat.mtimeMs / 1000;
      return {
        id,
        dir,
        cwd,
        summary: workspace.summary || null,
        createdAt,
        updatedAt,
        branch: workspace.branch || null,
        repository: workspace.repository || null,
        eventsPath: nodePath.join(dir, "events.jsonl"),
      };
    } catch {
      return null;
    }
  }
}

function copilotModel(
  model: string,
  displayName: string,
  isDefault: boolean,
  sortOrder: number,
): ModelSummary {
  return {
    id: `copilot:${model}`,
    model,
    displayName,
    description: "GitHub Copilot CLI model override.",
    defaultReasoningEffort: "medium",
    supportedReasoningEfforts: [
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
    reasoningEffortControl: "client",
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: ["text"],
    isDefault,
    sortOrder,
    source: "builtin",
  };
}

function nativeSessionToThread(
  session: CopilotNativeSessionMetadata,
  includeTurns: boolean,
): ThreadRecord {
  return {
    id: session.id,
    name: session.summary,
    preview: session.summary ?? session.cwd,
    cwd: session.cwd,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    source: "copilot",
    path: session.dir,
    status: { type: "idle" },
    gitInfo: {
      sha: null,
      branch: session.branch,
      originUrl: session.repository
        ? `https://github.com/${session.repository}`
        : null,
    },
    turns: includeTurns ? [] : undefined,
  };
}

async function readNativeSessionLog(
  session: CopilotNativeSessionMetadata,
  options: AgentSessionLogOptions,
): Promise<SessionLogSnapshot> {
  const parsed = await parseNativeEvents(session);
  const messages = limitTail(parsed.messages, options.messageLimit ?? null);
  const activities = limitTail(parsed.activities, options.activityLimit ?? null);
  return {
    messages,
    activities,
    runtime: parsed.runtime,
    totalMessages: parsed.messages.length,
    totalActivities: parsed.activities.length,
    nextSeq: parsed.nextSeq,
  };
}

async function readNativeRuntime(
  session: CopilotNativeSessionMetadata,
): Promise<SessionRuntimeSummary | null> {
  return (await parseNativeEvents(session)).runtime;
}

async function parseNativeEvents(session: CopilotNativeSessionMetadata): Promise<{
  messages: SessionMessage[];
  activities: import("./types.js").SessionActivity[];
  runtime: SessionRuntimeSummary | null;
  nextSeq: number;
}> {
  let raw = "";
  try {
    raw = await readFile(session.eventsPath, "utf8");
  } catch {
    return {
      messages: [],
      activities: [],
      runtime: null,
      nextSeq: 0,
    };
  }

  const messages: SessionMessage[] = [];
  const activities = new Map<string, import("./types.js").CommandActivity>();
  let seq = 0;
  let model: string | undefined;
  let updatedAt: number | undefined;

  for (const line of raw.split(/\n/)) {
    if (!line.trim()) continue;
    let event: Record<string, any>;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    const timestamp = millisFromIso(event.timestamp) ?? Date.now();
    updatedAt = timestamp;
    const data = event.data ?? {};

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
        cwd: session.cwd,
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
          cwd: session.cwd,
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

async function writeNativeSummary(
  session: CopilotNativeSessionMetadata,
  summary: string,
): Promise<void> {
  const workspacePath = nodePath.join(session.dir, "workspace.yaml");
  const raw = await readFile(workspacePath, "utf8");
  const lines = raw.split(/\r?\n/);
  let wrote = false;
  const next = lines.map((line) => {
    if (line.startsWith("summary:")) {
      wrote = true;
      return `summary: ${summary}`;
    }
    return line;
  });
  if (!wrote) next.push(`summary: ${summary}`);
  await writeFile(workspacePath, next.join("\n"));
}

function formatCopilotToolCommand(toolName: unknown, args: unknown): string {
  const name = typeof toolName === "string" ? toolName : "tool";
  if (!args || typeof args !== "object") return name;
  return `${name} ${JSON.stringify(args)}`;
}

function extractCopilotToolOutput(result: unknown): string | null {
  if (!result || typeof result !== "object") return null;
  const data = result as Record<string, unknown>;
  const content = data.detailedContent ?? data.content;
  return typeof content === "string" ? content : JSON.stringify(result);
}

function parseSimpleYaml(raw: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const line of raw.split(/\r?\n/)) {
    const index = line.indexOf(":");
    if (index <= 0) continue;
    const key = line.slice(0, index).trim();
    let value = line.slice(index + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    result[key] = value;
  }
  return result;
}

function secondsFromIso(value: string | undefined): number | null {
  const millis = millisFromIso(value);
  return millis == null ? null : millis / 1000;
}

function millisFromIso(value: string | undefined): number | null {
  if (!value) return null;
  const millis = Date.parse(value);
  return Number.isFinite(millis) ? millis : null;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function mergeRuntime(
  runtime: SessionRuntimeSummary | null,
  overrides: {
    model: string | null;
    reasoningEffort: string | null;
  },
): SessionRuntimeSummary {
  return {
    ...(runtime ?? {}),
    model: overrides.model ?? runtime?.model ?? "gpt-5.2",
    modelProvider: "copilot",
    reasoningEffort:
      overrides.reasoningEffort ?? runtime?.reasoningEffort ?? "medium",
    updatedAt: Date.now(),
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

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (limit == null || limit <= 0 || items.length <= limit) {
    return [...items];
  }
  return items.slice(items.length - limit);
}

function nowSeconds(): number {
  return Date.now() / 1000;
}

function waitForChild(
  child: ChildProcessWithoutNullStreams,
): Promise<number | null> {
  return new Promise((resolve) => {
    child.on("error", () => resolve(1));
    child.on("close", (code) => resolve(code));
  });
}

async function runProcess(
  command: string,
  args: string[],
  cwd: string,
): Promise<string> {
  const child = spawn(command, args, {
    cwd,
    env: { ...process.env, NO_COLOR: "1" },
  });
  const chunks: string[] = [];
  child.stdout.on("data", (chunk: Buffer) =>
    chunks.push(chunk.toString("utf8")),
  );
  child.stderr.resume();
  await waitForChild(child);
  return chunks.join("");
}
