import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import {
  cp,
  mkdir,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { hostname } from "node:os";
import nodePath from "node:path";

import {
  normalizePendingActionDecision,
  type PendingActionDecisionInput,
  type PendingActionResponseInput,
} from "./approvals.js";
import {
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
  type AgentFsDirectoryListing,
  type AgentFsFile,
  type AgentFsMetadata,
  type AgentFsWatchResult,
  type AgentModelListOptions,
  type AgentPendingAction,
  type AgentProfileListOptions,
  type AgentProvider,
  type AgentProviderCapabilities,
  type AgentProviderEvents,
  type AgentRemoteGitDiff,
  type AgentSessionActivityDraft,
  type AgentSessionInputItem,
  type AgentSessionListOptions,
  type AgentSessionLogOptions,
  type AgentSessionResumeOptions,
  type AgentSkillConfigWriteRequest,
  type AgentSkillListOptions,
  type AgentSubmitInputRequest,
  type AgentSubmitInputResult,
} from "./agent-provider.js";
import type {
  FakeCapabilityProfile,
  ModelSummary,
  ProviderProfileCatalog,
  ProviderProfileSummary,
  SessionActivity,
  SessionActivityChange,
  SessionLogSnapshot,
  SessionMessage,
  SessionMessageAttachment,
  SessionRuntimeSummary,
  SkillCatalogEntry,
  SkillSummary,
  ThreadRecord,
  TurnRecord,
} from "./types.js";

export interface FakeAgentProviderOptions {
  latencyMs?: number;
  seedSessions?: boolean;
  workspaceRoot?: string | null;
  capabilityProfile?: FakeCapabilityProfile;
}

interface FakeSessionState {
  thread: ThreadRecord;
  messages: SessionMessage[];
  activities: Map<string, SessionActivity>;
  turns: TurnRecord[];
  runtime: SessionRuntimeSummary | null;
  archived: boolean;
  nextSeq: number;
}

interface PendingFakeApproval {
  action: AgentPendingAction;
  resolve(decision: string): void;
}

interface FakeWatch {
  path: string;
}

type FakeApprovalKind = "command" | "tool" | "file_change" | "permissions";
type FakeTurnStatus = "completed" | "failed" | "interrupted";

const DEFAULT_FAKE_WORKSPACE = nodePath.resolve(process.cwd());

export const FAKE_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
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
    fileMentions: true,
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
    profiles: true,
    skills: true,
    skillManagement: true,
  },
  runtimeControls: {
    model: true,
    mode: false,
    reasoningEffort: true,
    fastMode: true,
    approvalPolicy: true,
    sandboxMode: true,
    networkAccess: true,
    webSearch: true,
  },
  workspace: {
    filesystem: true,
    remoteGitDiff: true,
  },
};

function capabilitiesForFakeProfile(
  profile: FakeCapabilityProfile,
): AgentProviderCapabilities {
  const capabilities = cloneCapabilities(FAKE_PROVIDER_CAPABILITIES);
  switch (profile) {
    case "full":
      return capabilities;
    case "chat-only":
      disableInputAttachments(capabilities);
      disableApprovals(capabilities);
      disableConfiguration(capabilities);
      disableRuntimeControls(capabilities);
      disableWorkspace(capabilities);
      return capabilities;
    case "no-files":
      capabilities.input.localImage = false;
      disableWorkspace(capabilities);
      return capabilities;
    case "no-model-controls":
      capabilities.configuration.models = false;
      capabilities.configuration.profiles = false;
      capabilities.runtimeControls.model = false;
      capabilities.runtimeControls.mode = false;
      capabilities.runtimeControls.reasoningEffort = false;
      capabilities.runtimeControls.fastMode = false;
      return capabilities;
    case "no-approvals":
      disableApprovals(capabilities);
      capabilities.runtimeControls.approvalPolicy = false;
      return capabilities;
    case "minimal":
      capabilities.sessions.resume = false;
      capabilities.sessions.rename = false;
      capabilities.sessions.archive = false;
      capabilities.sessions.compact = false;
      capabilities.sessions.interrupt = false;
      capabilities.sessions.eventReplay = false;
      capabilities.sessions.recentFallback = false;
      disableInputAttachments(capabilities);
      disableApprovals(capabilities);
      disableConfiguration(capabilities);
      disableRuntimeControls(capabilities);
      disableWorkspace(capabilities);
      return capabilities;
  }
}

function cloneCapabilities(
  capabilities: AgentProviderCapabilities,
): AgentProviderCapabilities {
  return {
    sessions: { ...capabilities.sessions },
    input: { ...capabilities.input },
    interaction: { ...capabilities.interaction },
    approvals: { ...capabilities.approvals },
    configuration: { ...capabilities.configuration },
    runtimeControls: { ...capabilities.runtimeControls },
    workspace: { ...capabilities.workspace },
  };
}

function disableInputAttachments(capabilities: AgentProviderCapabilities): void {
  capabilities.input.imageUrl = false;
  capabilities.input.localImage = false;
  capabilities.input.skills = false;
}

function disableApprovals(capabilities: AgentProviderCapabilities): void {
  capabilities.approvals.command = false;
  capabilities.approvals.tool = false;
  capabilities.approvals.fileChange = false;
  capabilities.approvals.permissions = false;
  capabilities.approvals.approveForSession = false;
}

function disableConfiguration(capabilities: AgentProviderCapabilities): void {
  capabilities.configuration.models = false;
  capabilities.configuration.profiles = false;
  capabilities.configuration.skills = false;
  capabilities.configuration.skillManagement = false;
}

function disableRuntimeControls(capabilities: AgentProviderCapabilities): void {
  capabilities.runtimeControls.model = false;
  capabilities.runtimeControls.mode = false;
  capabilities.runtimeControls.reasoningEffort = false;
  capabilities.runtimeControls.fastMode = false;
  capabilities.runtimeControls.approvalPolicy = false;
  capabilities.runtimeControls.sandboxMode = false;
  capabilities.runtimeControls.networkAccess = false;
  capabilities.runtimeControls.webSearch = false;
}

function disableWorkspace(capabilities: AgentProviderCapabilities): void {
  capabilities.workspace.filesystem = false;
  capabilities.workspace.remoteGitDiff = false;
}

export class FakeAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  public readonly kind = "fake";
  public readonly displayName = "Fake Test Provider";
  public readonly capabilities: AgentProviderCapabilities;

  private readonly latencyMs: number;
  private readonly workspaceRoot: string;
  private readonly capabilityProfile: FakeCapabilityProfile;
  private readonly sessions = new Map<string, FakeSessionState>();
  private readonly loadedSessionIds = new Set<string>();
  private readonly activeTurnIds = new Map<string, string>();
  private readonly pendingApprovals = new Map<string, PendingFakeApproval>();
  private readonly watches = new Map<string, FakeWatch>();
  private readonly skillEnabled = new Map<string, boolean>();
  private watchCounter = 0;

  public constructor(options: FakeAgentProviderOptions = {}) {
    super();
    this.latencyMs = Math.max(0, Math.trunc(options.latencyMs ?? 15));
    this.workspaceRoot = nodePath.resolve(
      options.workspaceRoot || DEFAULT_FAKE_WORKSPACE,
    );
    this.capabilityProfile = options.capabilityProfile ?? "full";
    this.capabilities = capabilitiesForFakeProfile(this.capabilityProfile);

    if (options.seedSessions !== false) {
      this.seedWelcomeSession();
    }
  }

  public async start(): Promise<void> {
    await mkdir(this.workspaceRoot, { recursive: true });
  }

  public async getVersion(): Promise<string> {
    return `fake-provider 1.0.0 (${this.capabilityProfile})`;
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    return [...this.sessions.values()]
      .filter((session) => session.archived === options.archived)
      .sort((left, right) => right.thread.updatedAt - left.thread.updatedAt)
      .slice(0, options.limit)
      .map((session) => this.cloneThread(session, false));
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    return this.cloneThread(this.requireSession(threadId), includeTurns);
  }

  public async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> {
    return [...this.sessions.values()]
      .filter((session) => !session.archived)
      .sort((left, right) => right.thread.updatedAt - left.thread.updatedAt)
      .slice(0, limit)
      .map((session) => this.cloneThread(session, false));
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    const session = this.requireSession(thread.id);
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

  public async readSessionRuntime(thread: ThreadRecord): Promise<SessionRuntimeSummary | null> {
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
    this.requireSession(threadId);
    this.loadedSessionIds.add(threadId);
    return { resumed: true };
  }

  public async setSessionName(threadId: string, name: string): Promise<unknown> {
    const session = this.requireSession(threadId);
    session.thread.name = name;
    this.touch(session);
    return { renamed: true };
  }

  public async archiveSession(threadId: string): Promise<unknown> {
    const session = this.requireSession(threadId);
    session.archived = true;
    this.interruptActiveTurn(session);
    this.loadedSessionIds.delete(threadId);
    this.touch(session);
    return { archived: true };
  }

  public async unarchiveSession(threadId: string): Promise<unknown> {
    const session = this.requireSession(threadId);
    session.archived = false;
    this.touch(session);
    return { unarchived: true };
  }

  public async compactSession(threadId: string): Promise<unknown> {
    const session = this.requireSession(threadId);
    const startedAt = Date.now();
    const messagesRemoved = Math.max(0, session.messages.length - 4);
    const tokensRemoved = messagesRemoved * 128;
    session.runtime = {
      ...(session.runtime ?? buildRuntime(emptyOverrides())),
      telemetry: {
        ...(session.runtime?.telemetry ?? {}),
        compaction: {
          status: "completed",
          startedAt,
          completedAt: startedAt,
          updatedAt: startedAt,
          preCompactionTokens: session.messages.length * 128,
          postCompactionTokens: Math.min(session.messages.length, 4) * 128,
          tokensRemoved,
          messagesRemoved,
          durationMs: 0,
          model: session.runtime?.model ?? "fake-balanced",
        },
      },
      updatedAt: startedAt,
    };
    this.touch(session);
    this.emit("liveEvent", {
      type: "runtime_updated",
      sessionId: session.thread.id,
      runtime: { ...session.runtime },
    });
    return { compacted: true, tokensRemoved, messagesRemoved };
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    const session = this.createSessionState({
      cwd: request.cwd,
      preview: previewFromInput(request.input) || "Fake provider session",
      name: null,
      runtime: buildRuntime(request.overrides),
    });

    let activeTurnId: string | null = null;
    if (request.input.length > 0) {
      activeTurnId = this.startFakeTurn(session, request.input);
    }

    return {
      thread: this.cloneThread(session, false),
      activeTurnId,
      runtime: session.runtime,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    const session = this.requireSession(request.sessionId);
    session.runtime = mergeRuntime(session.runtime, request.overrides);

    if (request.activeTurnId) {
      this.appendUserMessage(session, request.input);
      this.touch(session);
      return {
        mode: "steer",
        turnId: request.activeTurnId,
      };
    }

    const turnId = this.startFakeTurn(session, request.input);
    return {
      mode: "turn",
      turnId,
    };
  }

  public async interruptTurn(threadId: string, turnId: string): Promise<unknown> {
    const session = this.requireSession(threadId);
    const turn = session.turns.find((candidate) => candidate.id === turnId);
    if (!turn || turn.status !== "inProgress") {
      return { interrupted: false };
    }
    this.resolvePendingApprovalsForSession(threadId, "cancel");
    this.finishTurn(session, turn, "interrupted");
    return { interrupted: true };
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean {
    const normalized = normalizePendingActionDecision(
      decision as PendingActionDecisionInput,
    );
    if (!normalized || !isSupportedDecision(normalized.legacyDecision)) {
      return false;
    }
    const pending = this.pendingApprovals.get(action.id);
    if (!pending) {
      return false;
    }
    this.pendingApprovals.delete(action.id);
    pending.resolve(normalized.legacyDecision);
    return true;
  }

  public async readRemoteGitDiff(cwd: string): Promise<AgentRemoteGitDiff> {
    return {
      sha: "fake-remote-sha",
      diff: [
        "diff --git a/fake-remote.md b/fake-remote.md",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/fake-remote.md",
        "@@ -0,0 +1,2 @@",
        "+# Fake remote diff",
        `+cwd: ${cwd}`,
        "",
      ].join("\n"),
    };
  }

  public async listSkills(options: AgentSkillListOptions): Promise<SkillCatalogEntry> {
    const workspacePath = nodePath.join(options.cwd, "skills", "fake-workspace", "SKILL.md");
    const skills: SkillSummary[] = [
      buildSkill({
        name: "fake code review",
        description: "Exercises skill mention UI and provider-neutral skill inputs.",
        path: "fake://skills/code-review/SKILL.md",
        scope: "system",
        enabled: this.isSkillEnabled("fake code review", true),
      }),
      buildSkill({
        name: "fake debugging",
        description: "Creates deterministic tool, approval, and transcript scenarios.",
        path: "fake://skills/debugging/SKILL.md",
        scope: "admin",
        enabled: this.isSkillEnabled("fake debugging", true),
      }),
      buildSkill({
        name: "fake workspace skill",
        description: "Represents a workspace-local skill for the current cwd.",
        path: workspacePath,
        scope: "repo",
        enabled: this.isSkillEnabled(workspacePath, true),
      }),
    ];
    return {
      cwd: options.cwd,
      skills,
      errors: [],
    };
  }

  public async writeSkillConfig(
    request: AgentSkillConfigWriteRequest,
  ): Promise<unknown> {
    this.skillEnabled.set(request.path ?? request.name ?? "", request.enabled);
    this.emit("liveEvent", { type: "skills_changed" });
    return {
      ok: true,
      path: request.path,
      name: request.name,
      enabled: request.enabled,
    };
  }

  public async listModels(_options: AgentModelListOptions): Promise<ModelSummary[]> {
    return [
      {
        id: "fake:balanced",
        model: "fake-balanced",
        displayName: "Fake Balanced",
        description: "Deterministic fake model for normal chat, tools, and approvals.",
        defaultReasoningEffort: "medium",
        supportedReasoningEfforts: [
          { reasoningEffort: "low", description: "Short fake reasoning." },
          { reasoningEffort: "medium", description: "Default fake reasoning." },
          { reasoningEffort: "high", description: "Verbose fake reasoning." },
        ],
        reasoningEffortControl: "client",
        supportsPersonality: true,
        additionalSpeedTiers: ["fast"],
        inputModalities: ["text", "image"],
        isDefault: true,
        sortOrder: 0,
        source: "builtin",
        profileName: null,
      },
      {
        id: "fake:auto",
        model: "fake-auto",
        displayName: "Fake Auto",
        description: "Provider-managed fake model for testing auto-reasoning UI.",
        defaultReasoningEffort: "medium",
        supportedReasoningEfforts: [
          { reasoningEffort: "medium", description: "Fake provider decides." },
        ],
        reasoningEffortControl: "provider",
        supportsPersonality: true,
        additionalSpeedTiers: ["fast"],
        inputModalities: ["text"],
        isDefault: false,
        sortOrder: 1,
        source: "builtin",
        profileName: null,
      },
      {
        id: "fake:vision",
        model: "fake-vision",
        displayName: "Fake Vision",
        description: "Exercises image attachment and generated image UI flows.",
        defaultReasoningEffort: "low",
        supportedReasoningEfforts: [
          { reasoningEffort: "low", description: "Vision smoke test." },
        ],
        reasoningEffortControl: "client",
        supportsPersonality: false,
        additionalSpeedTiers: [],
        inputModalities: ["text", "image"],
        isDefault: false,
        sortOrder: 2,
        source: "builtin",
        profileName: null,
      },
    ];
  }

  public async listProfiles(
    _options: AgentProfileListOptions,
  ): Promise<ProviderProfileCatalog> {
    const profiles: ProviderProfileSummary[] = [
      {
        name: "balanced",
        isDefault: true,
        model: "fake-balanced",
        modelProvider: "fake",
        modelProviderName: "Fake Test Provider",
        modelProviderBaseUrl: null,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        serviceTier: "standard",
        reasoningEffort: "medium",
        reasoningSummary: "auto",
        verbosity: "normal",
        webSearch: "cached",
        personality: "deterministic",
      },
      {
        name: "locked-down",
        isDefault: false,
        model: "fake-balanced",
        modelProvider: "fake",
        modelProviderName: "Fake Test Provider",
        modelProviderBaseUrl: null,
        approvalPolicy: "never",
        sandboxMode: "read-only",
        serviceTier: "standard",
        reasoningEffort: "low",
        reasoningSummary: "none",
        verbosity: "brief",
        webSearch: "disabled",
        personality: "strict",
      },
    ];
    return {
      defaultProfile: "balanced",
      profiles,
    };
  }

  public async fsReadDirectory(path: string): Promise<AgentFsDirectoryListing> {
    const entries = await readdir(path, { withFileTypes: true });
    return {
      entries: entries.map((entry) => ({
        fileName: entry.name,
        isDirectory: entry.isDirectory(),
        isFile: entry.isFile(),
      })),
    };
  }

  public async fsGetMetadata(path: string): Promise<AgentFsMetadata> {
    const metadata = await stat(path);
    return {
      isDirectory: metadata.isDirectory(),
      isFile: metadata.isFile(),
      isSymlink: metadata.isSymbolicLink(),
      createdAtMs: metadata.birthtimeMs,
      modifiedAtMs: metadata.mtimeMs,
    };
  }

  public async fsReadFile(path: string): Promise<AgentFsFile> {
    return {
      dataBase64: (await readFile(path)).toString("base64"),
    };
  }

  public async fsWriteFile(path: string, dataBase64: string): Promise<unknown> {
    await mkdir(nodePath.dirname(path), { recursive: true });
    await writeFile(path, Buffer.from(dataBase64, "base64"));
    this.notifyWatch(path);
    return { path };
  }

  public async fsCreateDirectory(path: string, recursive: boolean): Promise<unknown> {
    await mkdir(path, { recursive });
    this.notifyWatch(path);
    return { path };
  }

  public async fsRemove(
    path: string,
    options: { recursive: boolean; force: boolean },
  ): Promise<unknown> {
    await rm(path, options);
    this.notifyWatch(path);
    return { path };
  }

  public async fsCopy(params: {
    sourcePath: string;
    destinationPath: string;
    recursive: boolean;
  }): Promise<unknown> {
    await cp(params.sourcePath, params.destinationPath, {
      recursive: params.recursive,
      force: true,
    });
    this.notifyWatch(params.destinationPath);
    return params;
  }

  public async fsWatch(path: string): Promise<AgentFsWatchResult> {
    const watchId = `fake-watch-${++this.watchCounter}`;
    this.watches.set(watchId, { path });
    return { watchId };
  }

  public async fsUnwatch(watchId: string): Promise<unknown> {
    this.watches.delete(watchId);
    return { watchId };
  }

  private seedWelcomeSession(): void {
    const session = this.createSessionState({
      cwd: this.workspaceRoot,
      name: "Fake provider walkthrough",
      preview: "Fake provider walkthrough",
      runtime: buildRuntime({
        model: "fake-balanced",
        mode: null,
        reasoningEffort: "medium",
        fastMode: false,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        networkAccess: true,
        webSearch: "cached",
        profile: "balanced",
      }),
    });
    this.appendMessage(session, {
      role: "assistant",
      text: [
        "This is a deterministic fake provider session.",
        "",
        "Try prompts containing `tools`, `approval:command`, `approval:tool`, `approval:file`,",
        "`approval:permissions`, `image`, `slow`, or `fail` to exercise UI states.",
      ].join("\n"),
      attachments: [],
      phase: "final_answer",
    });
    this.upsertActivity(session, {
      id: "fake-seed-diff",
      type: "turn_diff",
      turnId: null,
      status: "completed",
      diff: "diff --git a/README.md b/README.md\n@@ -1 +1 @@\n-Fake\n+Fake provider seed\n",
    });
    this.touch(session);
  }

  private createSessionState(options: {
    cwd: string;
    preview: string;
    name: string | null;
    runtime: SessionRuntimeSummary | null;
  }): FakeSessionState {
    const now = nowSeconds();
    const thread: ThreadRecord = {
      id: `fake-${randomUUID()}`,
      name: options.name,
      preview: options.preview || "Fake provider session",
      createdAt: now,
      updatedAt: now,
      cwd: nodePath.resolve(options.cwd || this.workspaceRoot),
      source: "fake",
      path: null,
      status: { type: "loaded" },
      gitInfo: {
        sha: "fake-sha",
        branch: "fake/main",
        originUrl: "https://example.invalid/fake/sidemesh.git",
      },
    };
    const state: FakeSessionState = {
      thread,
      messages: [],
      activities: new Map(),
      turns: [],
      runtime: options.runtime,
      archived: false,
      nextSeq: 0,
    };
    this.sessions.set(thread.id, state);
    this.loadedSessionIds.add(thread.id);
    return state;
  }

  private startFakeTurn(
    session: FakeSessionState,
    input: AgentSessionInputItem[],
  ): string {
    this.appendUserMessage(session, input);
    const turnId = `fake-turn-${randomUUID()}`;
    const turn: TurnRecord = {
      id: turnId,
      status: "inProgress",
      startedAt: nowSeconds(),
      completedAt: null,
      items: [],
    };
    session.turns.push(turn);
    session.thread.status = {
      type: "running",
      activeFlags: ["inProgress"],
    };
    this.activeTurnIds.set(session.thread.id, turnId);
    this.touch(session);
    void this.runFakeTurn(session.thread.id, turnId, input);
    return turnId;
  }

  private async runFakeTurn(
    sessionId: string,
    turnId: string,
    input: AgentSessionInputItem[],
  ): Promise<void> {
    await sleep(this.delayFor(input));
    const session = this.sessions.get(sessionId);
    if (!session || this.activeTurnIds.get(sessionId) !== turnId) {
      return;
    }

    this.emit("liveEvent", {
      type: "turn_started",
      sessionId,
      turnId,
    });

    const text = inputText(input);
    if (scenarioRequested(text, "tools") && this.supportsToolingScenario()) {
      await this.emitToolingScenario(session, turnId);
    }

    const approvalKinds = requestedApprovalKinds(text);
    for (const kind of approvalKinds) {
      if (!this.supportsApprovalKind(kind)) {
        this.appendAssistantMessage(
          session,
          turnId,
          `Fake ${kind} approval skipped by ${this.capabilityProfile} capability profile.`,
          "commentary",
        );
        continue;
      }
      const decision = await this.openApproval(session, turnId, kind);
      if (!this.isTurnActive(session.thread.id, turnId)) {
        return;
      }
      if (decision === "decline" || decision === "cancel") {
        this.appendAssistantMessage(
          session,
          turnId,
          `Fake ${kind} approval was ${decision}.`,
          "final_answer",
        );
        this.finishTurn(session, this.requireTurn(session, turnId), "failed");
        return;
      }
      this.appendAssistantMessage(
        session,
        turnId,
        `Fake ${kind} approval accepted with \`${decision}\`.`,
        "commentary",
      );
    }

    if (scenarioRequested(text, "image") && this.supportsGeneratedImageScenario()) {
      this.upsertAndEmitActivity(session, turnId, {
        id: `fake-image-${turnId}`,
        type: "image_generation",
        turnId,
        status: "completed",
        revisedPrompt: "A deterministic fake image artifact for UI testing.",
        savedPath: nodePath.join(session.thread.cwd, "fake-generated-image.png"),
      });
    }

    const answer = buildAssistantAnswer(input);
    const streamed = await this.streamAssistantMessage(session, turnId, answer);
    if (!streamed) {
      return;
    }
    this.finishTurn(
      session,
      this.requireTurn(session, turnId),
      scenarioRequested(text, "fail") ? "failed" : "completed",
    );
  }

  private async emitToolingScenario(
    session: FakeSessionState,
    turnId: string,
  ): Promise<void> {
    const toolId = `fake-tool-${turnId}`;
    this.upsertAndEmitActivity(session, turnId, {
      id: toolId,
      type: "tool",
      turnId,
      status: "in_progress",
      toolName: "fake_inspect",
      title: "Inspect fake workspace",
      args: { path: session.thread.cwd, depth: 1 },
      output: "Inspecting fake workspace...\n",
      result: null,
      isError: null,
      semantic: {
        category: "filesystem",
        action: "read",
        targets: [
          { type: "file", path: session.thread.cwd, access: "read", role: "target" },
        ],
      },
    });
    await sleep(this.latencyMs);
    this.upsertAndEmitActivity(session, turnId, {
      id: toolId,
      type: "tool",
      turnId,
      status: "completed",
      toolName: "fake_inspect",
      title: "Inspect fake workspace",
      args: { path: session.thread.cwd, depth: 1 },
      output: "Inspecting fake workspace...\nFound fake-provider.md\n",
      result: { files: ["fake-provider.md"], provider: "fake" },
      isError: false,
      semantic: {
        category: "filesystem",
        action: "read",
        targets: [
          { type: "file", path: session.thread.cwd, access: "read", role: "target" },
        ],
      },
    });

    if (this.capabilityProfile !== "chat-only" && this.capabilityProfile !== "minimal") {
      const commandId = `fake-command-${turnId}`;
      this.upsertAndEmitActivity(session, turnId, {
        id: commandId,
        type: "command",
        turnId,
        status: "in_progress",
        command: "printf 'fake provider tooling\\n'",
        cwd: session.thread.cwd,
        output: "",
        exitCode: null,
        durationMs: null,
        source: "fake",
        processId: `fake-pid-${Date.now()}`,
        commandActions: [{ kind: "unknown", label: "fake command" }],
        terminalStatus: "input",
        terminalInput: null,
      });
      await sleep(this.latencyMs);
      this.appendCommandOutput(session, commandId, "fake provider tooling\n");
      this.emit("liveEvent", {
        type: "activity_output_delta",
        sessionId: session.thread.id,
        turnId,
        activityId: commandId,
        delta: "fake provider tooling\n",
      });
      this.applyTerminalInput(session, commandId, "y\n");
      this.emit("liveEvent", {
        type: "activity_terminal_input",
        sessionId: session.thread.id,
        turnId,
        activityId: commandId,
        stdin: "y\n",
      });
      this.upsertAndEmitActivity(session, turnId, {
        id: commandId,
        type: "command",
        turnId,
        status: "completed",
        command: "printf 'fake provider tooling\\n'",
        cwd: session.thread.cwd,
        output: "fake provider tooling\n",
        exitCode: 0,
        durationMs: 42,
        source: "fake",
        processId: `fake-pid-${Date.now()}`,
        commandActions: [{ kind: "unknown", label: "fake command" }],
        terminalStatus: null,
        terminalInput: "y\n",
      });
    }

    const change: SessionActivityChange = {
      path: "fake-provider.md",
      kind: "update",
      diff: [
        "diff --git a/fake-provider.md b/fake-provider.md",
        "--- a/fake-provider.md",
        "+++ b/fake-provider.md",
        "@@ -1 +1,2 @@",
        " # Fake Provider",
        "+tooling scenario completed",
        "",
      ].join("\n"),
    };
    if (this.capabilities.workspace.filesystem) {
      this.upsertAndEmitActivity(session, turnId, {
        id: `fake-file-change-${turnId}`,
        type: "file_change",
        turnId,
        status: "completed",
        changes: [change],
      });
      this.upsertAndEmitActivity(session, turnId, {
        id: `fake-turn-diff-${turnId}`,
        type: "turn_diff",
        turnId,
        status: "completed",
        diff: change.diff,
      });
    }
    if (this.capabilities.runtimeControls.webSearch) {
      this.upsertAndEmitActivity(session, turnId, {
        id: `fake-web-search-${turnId}`,
        type: "web_search",
        turnId,
        status: "completed",
        query: "fake provider deterministic web search",
        queries: ["fake provider deterministic web search"],
        targetUrl: "https://example.invalid/fake-provider",
        pattern: "deterministic",
      });
    }
  }

  private async openApproval(
    session: FakeSessionState,
    turnId: string,
    kind: FakeApprovalKind,
  ): Promise<string> {
    const actionId = `fake-approval-${kind}-${turnId}`;
    const action: AgentPendingAction = {
      id: actionId,
      sessionId: session.thread.id,
      kind,
      title: fakeApprovalTitle(kind),
      detail: fakeApprovalDetail(kind, session.thread.cwd),
      requestedAt: Date.now(),
      canApprove: true,
      canApproveForSession: this.capabilities.approvals.approveForSession,
      canDecline: true,
      sessionTitle: session.thread.name ?? session.thread.preview,
      cwd: session.thread.cwd,
      approval: fakeApproval(kind, session.thread.cwd),
      providerRequestId: actionId,
      providerRequestKind: `fake/${kind}/requestApproval`,
      providerPayload: { kind, cwd: session.thread.cwd },
    };
    this.emit("liveEvent", {
      type: "action_opened",
      action,
    });
    return new Promise<string>((resolve) => {
      this.pendingApprovals.set(actionId, { action, resolve });
    });
  }

  private async streamAssistantMessage(
    session: FakeSessionState,
    turnId: string,
    text: string,
  ): Promise<boolean> {
    const messageId = `fake-assistant-${turnId}`;
    for (const delta of chunkText(text)) {
      await sleep(this.latencyMs);
      if (!this.isTurnActive(session.thread.id, turnId)) {
        return false;
      }
      this.emit("liveEvent", {
        type: "assistant_delta",
        sessionId: session.thread.id,
        turnId,
        itemId: messageId,
        delta,
      });
    }
    this.appendAssistantMessage(session, turnId, text, "final_answer", messageId);
    this.emit("liveEvent", {
      type: "assistant_message_completed",
      sessionId: session.thread.id,
      turnId,
      message: {
        id: messageId,
        text,
        phase: "final_answer",
      },
    });
    return true;
  }

  private appendUserMessage(
    session: FakeSessionState,
    input: AgentSessionInputItem[],
  ): void {
    this.appendMessage(session, {
      role: "user",
      text: inputText(input),
      attachments: inputAttachments(input),
    });
  }

  private appendAssistantMessage(
    session: FakeSessionState,
    turnId: string,
    text: string,
    phase: "commentary" | "final_answer",
    id = `fake-assistant-${randomUUID()}`,
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
    session: FakeSessionState,
    message: {
      id?: string;
      role: SessionMessage["role"];
      text: string;
      attachments: SessionMessageAttachment[];
      phase?: "commentary" | "final_answer";
    },
  ): SessionMessage {
    const next: SessionMessage = {
      id: message.id ?? `fake-message-${randomUUID()}`,
      role: message.role,
      text: message.text,
      attachments: message.attachments,
      createdAt: Date.now(),
      seq: session.nextSeq++,
      phase: message.phase,
    };
    session.messages.push(next);
    session.thread.preview = message.text || session.thread.preview;
    this.touch(session);
    return next;
  }

  private upsertAndEmitActivity(
    session: FakeSessionState,
    turnId: string,
    activity: AgentSessionActivityDraft,
  ): void {
    const stored = this.upsertActivity(session, activity);
    const { createdAt: _createdAt, seq: _seq, ...draft } = stored;
    this.emit("liveEvent", {
      type: "activity_updated",
      sessionId: session.thread.id,
      turnId,
      activity: draft,
    });
  }

  private upsertActivity(
    session: FakeSessionState,
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
    return next;
  }

  private appendCommandOutput(
    session: FakeSessionState,
    activityId: string,
    delta: string,
  ): void {
    const activity = session.activities.get(activityId);
    if (!activity || activity.type !== "command") {
      return;
    }
    session.activities.set(activityId, {
      ...activity,
      output: `${activity.output ?? ""}${delta}`,
    });
  }

  private applyTerminalInput(
    session: FakeSessionState,
    activityId: string,
    stdin: string,
  ): void {
    const activity = session.activities.get(activityId);
    if (!activity || activity.type !== "command") {
      return;
    }
    session.activities.set(activityId, {
      ...activity,
      terminalInput: `${activity.terminalInput ?? ""}${stdin}`,
    });
  }

  private finishTurn(
    session: FakeSessionState,
    turn: TurnRecord,
    status: FakeTurnStatus,
  ): void {
    this.resolvePendingApprovalsForSession(session.thread.id, "cancel");
    turn.status =
      status === "completed"
        ? "completed"
        : status === "interrupted"
          ? "interrupted"
          : "failed";
    turn.completedAt = nowSeconds();
    this.activeTurnIds.delete(session.thread.id);
    session.thread.status = { type: session.archived ? "archived" : "loaded" };
    this.touch(session);
    this.emit("liveEvent", {
      type: "turn_completed",
      sessionId: session.thread.id,
      turnId: turn.id,
      status: turn.status,
    });
  }

  private interruptActiveTurn(session: FakeSessionState): void {
    const turnId = this.activeTurnIds.get(session.thread.id);
    if (!turnId) {
      return;
    }
    const turn = session.turns.find((candidate) => candidate.id === turnId);
    this.resolvePendingApprovalsForSession(session.thread.id, "cancel");
    if (turn?.status === "inProgress") {
      this.finishTurn(session, turn, "interrupted");
    }
  }

  private resolvePendingApprovalsForSession(sessionId: string, decision: string): void {
    for (const [actionId, pending] of this.pendingApprovals) {
      if (pending.action.sessionId !== sessionId) {
        continue;
      }
      this.pendingApprovals.delete(actionId);
      pending.resolve(decision);
    }
  }

  private isTurnActive(sessionId: string, turnId: string): boolean {
    return this.activeTurnIds.get(sessionId) === turnId;
  }

  private notifyWatch(changedPath: string): void {
    for (const [watchId, watch] of this.watches) {
      if (changedPath === watch.path || changedPath.startsWith(`${watch.path}${nodePath.sep}`)) {
        this.emit("liveEvent", {
          type: "fs_changed",
          watchId,
          changedPaths: [changedPath],
        });
      }
    }
  }

  private requireSession(threadId: string): FakeSessionState {
    const session = this.sessions.get(threadId);
    if (!session) {
      throw new Error(`Fake session not found: ${threadId}`);
    }
    return session;
  }

  private requireTurn(session: FakeSessionState, turnId: string): TurnRecord {
    const turn = session.turns.find((candidate) => candidate.id === turnId);
    if (!turn) {
      throw new Error(`Fake turn not found: ${turnId}`);
    }
    return turn;
  }

  private cloneThread(session: FakeSessionState, includeTurns: boolean): ThreadRecord {
    return {
      ...session.thread,
      status: { ...session.thread.status },
      gitInfo: session.thread.gitInfo ? { ...session.thread.gitInfo } : null,
      turns: includeTurns
        ? session.turns.map((turn) => ({
            ...turn,
            items: turn.items ? turn.items.map((item) => ({ ...item })) : undefined,
          }))
        : undefined,
    };
  }

  private touch(session: FakeSessionState): void {
    session.thread.updatedAt = nowSeconds();
  }

  private isSkillEnabled(key: string, fallback: boolean): boolean {
    return this.skillEnabled.get(key) ?? this.skillEnabled.get(skillNameKey(key)) ?? fallback;
  }

  private supportsToolingScenario(): boolean {
    return this.capabilityProfile !== "chat-only" && this.capabilityProfile !== "minimal";
  }

  private supportsGeneratedImageScenario(): boolean {
    return this.capabilityProfile !== "chat-only" && this.capabilityProfile !== "minimal";
  }

  private supportsApprovalKind(kind: FakeApprovalKind): boolean {
    switch (kind) {
      case "command":
        return this.capabilities.approvals.command;
      case "tool":
        return this.capabilities.approvals.tool;
      case "file_change":
        return this.capabilities.approvals.fileChange;
      case "permissions":
        return this.capabilities.approvals.permissions;
    }
  }

  private delayFor(input: AgentSessionInputItem[]): number {
    const text = inputText(input);
    return scenarioRequested(text, "slow") ? Math.max(this.latencyMs, 100) : this.latencyMs;
  }
}

function buildRuntime(
  overrides: AgentCreateSessionRequest["overrides"],
): SessionRuntimeSummary {
  return {
    model: overrides.model ?? "fake-balanced",
    modelProvider: "fake",
    serviceTier: overrides.fastMode ? "fast" : "standard",
    reasoningEffort: overrides.reasoningEffort ?? "medium",
    approvalPolicy: overrides.approvalPolicy ?? "on-request",
    sandboxMode: overrides.sandboxMode ?? "workspace-write",
    networkAccess: overrides.networkAccess ?? true,
    summaryMode: "fake",
    personality: overrides.profile ?? "deterministic",
    updatedAt: Date.now(),
  };
}

function emptyOverrides(): AgentCreateSessionRequest["overrides"] {
  return {
    model: null,
    mode: null,
    reasoningEffort: null,
    fastMode: null,
    approvalPolicy: null,
    sandboxMode: null,
    networkAccess: null,
    webSearch: null,
    profile: null,
  };
}

function mergeRuntime(
  runtime: SessionRuntimeSummary | null,
  overrides: AgentSubmitInputRequest["overrides"],
): SessionRuntimeSummary {
  return {
    ...(runtime ?? buildRuntime(emptyOverrides())),
    model: overrides.model ?? runtime?.model ?? "fake-balanced",
    serviceTier:
      overrides.fastMode === null
        ? runtime?.serviceTier
        : overrides.fastMode
          ? "fast"
          : "standard",
    reasoningEffort: overrides.reasoningEffort ?? runtime?.reasoningEffort,
    approvalPolicy: overrides.approvalPolicy ?? runtime?.approvalPolicy,
    sandboxMode: overrides.sandboxMode ?? runtime?.sandboxMode,
    networkAccess: overrides.networkAccess ?? runtime?.networkAccess,
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
          return `[image:${item.url}]`;
        case "localImage":
          return `[local-image:${item.path}]`;
        case "skill":
          return `$${item.name}`;
      }
    })
    .filter(Boolean)
    .join("\n");
}

function inputAttachments(input: AgentSessionInputItem[]): SessionMessageAttachment[] {
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

function buildAssistantAnswer(input: AgentSessionInputItem[]): string {
  const text = inputText(input);
  const imageCount = input.filter((item) => item.type === "image" || item.type === "localImage").length;
  const skillCount = input.filter((item) => item.type === "skill").length;
  return [
    "Fake provider response complete.",
    "",
    `Echo: ${text || "(empty input)"}`,
    `Images: ${imageCount}`,
    `Skills: ${skillCount}`,
  ].join("\n");
}

function requestedApprovalKinds(text: string): FakeApprovalKind[] {
  const lower = text.toLowerCase();
  const kinds: FakeApprovalKind[] = [];
  if (lower.includes("approval:command") || lower.includes("approval command")) {
    kinds.push("command");
  }
  if (lower.includes("approval:tool") || lower.includes("approval tool")) {
    kinds.push("tool");
  }
  if (lower.includes("approval:file") || lower.includes("approval file")) {
    kinds.push("file_change");
  }
  if (lower.includes("approval:permissions") || lower.includes("approval permissions")) {
    kinds.push("permissions");
  }
  if (kinds.length === 0 && lower.includes("approval")) {
    kinds.push("command");
  }
  return kinds;
}

function scenarioRequested(text: string, scenario: string): boolean {
  return new RegExp(`(^|\\W)${escapeRegExp(scenario)}(\\W|$)`, "i").test(text);
}

function chunkText(text: string): string[] {
  const chunks: string[] = [];
  for (let index = 0; index < text.length; index += 24) {
    chunks.push(text.slice(index, index + 24));
  }
  return chunks.length > 0 ? chunks : [""];
}

function fakeApprovalTitle(kind: FakeApprovalKind): string {
  switch (kind) {
    case "command":
      return "Fake command approval";
    case "tool":
      return "Fake tool approval";
    case "file_change":
      return "Fake file change approval";
    case "permissions":
      return "Fake permission request";
  }
}

function fakeApprovalDetail(kind: FakeApprovalKind, cwd: string): string {
  switch (kind) {
    case "command":
      return `Run fake command in ${cwd}: printf 'approval test'`;
    case "tool":
      return `Allow fake_inspect tool to inspect ${cwd}.`;
    case "file_change":
      return `Apply a fake patch under ${cwd}.`;
    case "permissions":
      return `Grant fake network and workspace-write permissions for ${hostname()}.`;
  }
}

function fakeApproval(
  kind: FakeApprovalKind,
  cwd: string,
): NonNullable<AgentPendingAction["approval"]> {
  const detail = fakeApprovalDetail(kind, cwd);
  switch (kind) {
    case "command":
      return {
        category: "command",
        operation: "fake.command",
        summary: detail,
        detail,
        cwd,
        supportedScopes: ["once", "session"],
        suggestedScope: "once",
        targets: [
          {
            type: "command",
            command: "printf 'approval test'",
            cwd,
          },
        ],
      };
    case "tool":
      return {
        category: "tool",
        operation: "fake.tool",
        summary: detail,
        detail,
        cwd,
        supportedScopes: ["once", "session"],
        suggestedScope: "once",
        targets: [
          {
            type: "tool",
            name: "fake_inspect",
            title: "Inspect fake workspace",
            args: { path: cwd, depth: 1 },
          },
        ],
      };
    case "file_change":
      return {
        category: "file_change",
        operation: "fake.fileChange",
        summary: detail,
        detail,
        cwd,
        supportedScopes: ["once", "session"],
        suggestedScope: "once",
        targets: [{ type: "file", path: cwd, access: "write", intention: detail }],
      };
    case "permissions":
      return {
        category: "permissions",
        operation: "fake.permissions",
        summary: detail,
        detail,
        cwd,
        supportedScopes: ["once", "session"],
        suggestedScope: "once",
        targets: [
          {
            type: "permission_profile",
            permissions: { network: true, filesystem: "workspace-write" },
            cwd,
            reason: detail,
          },
        ],
      };
  }
}

function isSupportedDecision(decision: string): boolean {
  return ["accept", "acceptForSession", "decline", "cancel"].includes(decision);
}

function buildSkill(options: {
  name: string;
  description: string;
  path: string;
  scope: SkillSummary["scope"];
  enabled: boolean;
}): SkillSummary {
  return {
    ...options,
    shortDescription: options.description,
    interface: {
      displayName: options.name,
      shortDescription: options.description,
      brandColor: "#2f7d5c",
      defaultPrompt: `Use $${options.name} in fake provider mode.`,
    },
  };
}

function skillNameKey(value: string): string {
  return value.toLowerCase().trim();
}

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (!limit || limit <= 0 || items.length <= limit) {
    return [...items];
  }
  return items.slice(items.length - limit);
}

function cloneMessage(message: SessionMessage): SessionMessage {
  return {
    ...message,
    attachments: message.attachments.map((attachment) => ({ ...attachment })),
  };
}

function cloneActivity(activity: SessionActivity): SessionActivity {
  return JSON.parse(JSON.stringify(activity)) as SessionActivity;
}

function nowSeconds(): number {
  return Date.now() / 1000;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
