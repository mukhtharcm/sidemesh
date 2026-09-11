import { describe, it } from "node:test";
import assert from "node:assert/strict";
import type { SessionSummary } from "./types.js";
import { wrapProviderScopedId, unwrapProviderScopedId } from "./session-identity.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { EventEmitter } from "node:events";
import {
  appendFile,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import http from "node:http";
import { DatabaseSync } from "node:sqlite";
import { createServer as createNetServer } from "node:net";

import { WebSocket } from "ws";

import type { InstallInfo } from "./install-info.js";
import { startServer, type RunningServer } from "./server.js";
import {
  createQueuedUpdateStatus,
  UpdateAlreadyInProgressError,
  type UpdateStatus,
} from "./update-status.js";
import type { FakeCapabilityProfile, NodeConfig } from "./types.js";
import {
  FAKE_PROVIDER_CAPABILITIES,
  FakeAgentProvider,
  type FakeAgentProviderOptions,
} from "./fake-provider.js";
import {
  listAgentProviderDefinitionSummaries,
  summarizeAgentProviderConfig,
} from "./provider-registry.js";
import { createAgentProviderRuntime, AgentProviderRuntime } from "./provider-factory.js";
import { AgentProviderRequestError } from "./agent-provider.js";
import type {
  AgentCreateSessionRequest,
  AgentAccessModeListOptions,
  AgentCreateSessionResult,
  AgentPendingAction,
  AgentProvider,
  AgentProviderCore,
  AgentProviderCapabilities,
  AgentSessionListOptions,
  AgentSessionLogOptions,
  AgentSessionInputItem,
  AgentSubmitInputRequest,
  AgentSubmitInputResult,
} from "./agent-provider.js";
import type {
  ProviderAccessModeCatalog,
  ProviderModeCatalog,
  SessionLogSnapshot,
  ThreadRecord,
} from "./types.js";

const EMPTY_OVERRIDES = {
  model: null,
  mode: null,
  reasoningEffort: null,
  fastMode: null,
  approvalPolicy: null,
  sandboxMode: null,
  networkAccess: null,
  webSearch: null,
  profile: null,
} as const;

function makeConfig(
  stateDir: string,
  options: {
    capabilityProfile?: FakeCapabilityProfile;
    recommendedMobileClientVersion?: string | null;
    minimumMobileClientVersion?: string | null;
  } = {},
): NodeConfig {
  const token = "test-token-" + Math.random().toString(36).slice(2);
  const provider = {
    kind: "fake" as const,
    latencyMs: 0,
    seedSessions: false,
    workspaceRoot: null,
    capabilityProfile: options.capabilityProfile ?? "full",
  };
  return {
    label: "test",
    port: 0,
    token,
    tokenSource: "generated",
    provider,
    providers: [provider],
    defaultProviderKind: "fake",
    updateChannel: "stable",
    recommendedMobileClientVersion:
      options.recommendedMobileClientVersion ?? null,
    minimumMobileClientVersion: options.minimumMobileClientVersion ?? null,
    stateDir,
    workspaceRoots: [],
    terminal: { enabled: false, shell: null, requirePty: false },
    browserPreview: { enabled: false, chromePath: null, maxPreviews: 8, idleTtlMs: 3_600_000, frameIntervalMs: 900, quality: 55 },
    configPath: nodePath.join(stateDir, "config.json"),
    configExists: false,
  };
}

function makeInstallInfo(
  packageRoot: string,
  updateChannel: NodeConfig["updateChannel"] = "stable",
): InstallInfo {
  return {
    packageVersion: "0.1.0",
    latestVersion: "0.2.0",
    currentCommitSha: null,
    latestCommitSha: null,
    updateChannel,
    updateAvailable: true,
    packageRoot,
    installType: "git",
    updateSupported: true,
    updateCommand: "git pull && npm install && npm run build",
    restoreCommand: "git checkout HEAD",
    isManagedService: false,
    serviceName: null,
  };
}

function makeUpdateStatus(
  info: InstallInfo,
  id = "update-1",
): UpdateStatus {
  return createQueuedUpdateStatus(info, info.updateChannel, { id, now: 100 });
}

function request(options: http.RequestOptions & { body?: string }): Promise<{
  statusCode: number;
  body: unknown;
  headers: http.IncomingHttpHeaders;
}> {
  return new Promise((resolve, reject) => {
    const req = http.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => {
        try {
          resolve({
            statusCode: res.statusCode ?? 0,
            body: data ? JSON.parse(data) : null,
            headers: res.headers,
          });
        } catch {
          resolve({
            statusCode: res.statusCode ?? 0,
            body: data,
            headers: res.headers,
          });
        }
      });
    });
    req.on("error", reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}

async function withServer(config: NodeConfig, fn: (server: RunningServer, config: NodeConfig) => Promise<void>): Promise<void> {
  const server = await startServer(config);
  try {
    await fn(server, config);
  } finally {
    await server.close();
    await rm(config.stateDir, { recursive: true, force: true });
  }
}

async function withServerRuntime(
  config: NodeConfig,
  runtime: AgentProviderRuntime,
  fn: (server: RunningServer, config: NodeConfig) => Promise<void>,
): Promise<void> {
  const server = await startServer(config, runtime);
  try {
    await fn(server, config);
  } finally {
    await server.close();
    await rm(config.stateDir, { recursive: true, force: true });
  }
}

function makeMultiProviderRuntime(fakeOptions: FakeAgentProviderOptions, secondaryOptions: FakeAgentProviderOptions): AgentProviderRuntime {
  const defaultProvider = new FakeAgentProvider(fakeOptions);
  const secondaryProvider = new FakeAgentProvider(secondaryOptions);

  const defSummaries = listAgentProviderDefinitionSummaries();
  const fakeDef = defSummaries.find((d) => d.kind === "fake")!;
  const codexDef = defSummaries.find((d) => d.kind === "codex")!;

  const fakeConfig = { kind: "fake" as const, latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: fakeOptions.capabilityProfile ?? "full" };
  // The secondary entry uses "codex" as a kind label to keep kinds distinct; the
  // underlying provider is FakeAgentProvider so no external binary is needed.
  const codexConfig = { kind: "codex" as const, bin: "codex" };

  return new AgentProviderRuntime([
    { id: "fake", kind: "fake", create: () => defaultProvider,
      configSummary: summarizeAgentProviderConfig(fakeConfig), definitionSummary: { ...fakeDef, capabilities: defaultProvider.capabilities } },
    { id: "codex", kind: "codex", create: () => secondaryProvider,
      configSummary: summarizeAgentProviderConfig(codexConfig), definitionSummary: { ...codexDef, capabilities: secondaryProvider.capabilities } },
  ], "fake");
}

function makeCustomSingleProviderRuntime(provider: AgentProvider): AgentProviderRuntime {
  const definitionSummary = listAgentProviderDefinitionSummaries().find((summary) => summary.kind === "fake")!;
  const configSummary = summarizeAgentProviderConfig({ kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" });
  return new AgentProviderRuntime([{ id: "fake", kind: "fake", create: () => provider,
    configSummary, definitionSummary: { ...definitionSummary, capabilities: provider.capabilities } }], "fake");
}

class ModeCatalogOnlyProvider
  extends EventEmitter
  implements AgentProviderCore, Pick<AgentProvider, "listModes">
{
  public readonly kind = "fake";
  public readonly displayName = "Mode Catalog Provider";
  public readonly capabilities: AgentProviderCapabilities = {
    ...FAKE_PROVIDER_CAPABILITIES,
    runtimeControls: {
      ...FAKE_PROVIDER_CAPABILITIES.runtimeControls,
      mode: true,
    },
  };

  public async start(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "test-provider 1.0.0";
  }

  public async listModes(): Promise<ProviderModeCatalog> {
    return {
      defaultMode: null,
      modes: [
        { id: "build", label: "Build" },
        { id: "review", label: "Review" },
      ],
    };
  }
}

class AccessModeCatalogOnlyProvider
  extends EventEmitter
  implements AgentProviderCore, Pick<AgentProvider, "listAccessModes">
{
  public readonly kind = "fake";
  public readonly displayName = "Access Mode Catalog Provider";
  public readonly capabilities: AgentProviderCapabilities = {
    ...FAKE_PROVIDER_CAPABILITIES,
    configuration: {
      ...FAKE_PROVIDER_CAPABILITIES.configuration,
      accessModes: true,
    },
    runtimeControls: {
      ...FAKE_PROVIDER_CAPABILITIES.runtimeControls,
      accessMode: true,
    },
  };

  public requestedCwd: string | null = null;

  public async start(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "test-provider 1.0.0";
  }

  public async listAccessModes(
    options: AgentAccessModeListOptions,
  ): Promise<ProviderAccessModeCatalog> {
    this.requestedCwd = options.cwd;
    return {
      strategy: "modes",
      defaultMode: "guarded",
      modes: [
        {
          id: "guarded",
          label: "Guarded",
          description: "Ask before sensitive actions.",
          icon: "prompt",
          tone: "default",
          enabled: true,
          disabledReason: null,
          confirmation: null,
        },
      ],
    };
  }
}

const RESTARTABLE_FAKE_CAPABILITIES: AgentProviderCapabilities = {
  ...FAKE_PROVIDER_CAPABILITIES,
  lifecycle: {
    ...FAKE_PROVIDER_CAPABILITIES.lifecycle,
    restart: true,
  },
  runtimeControls: {
    ...FAKE_PROVIDER_CAPABILITIES.runtimeControls,
    accessMode: true,
  },
};

class SnapshotFixtureProvider extends EventEmitter {
  async readSessionSnapshot(this: AgentProvider, id: string, options?: AgentSessionLogOptions) {
    const thread = await this.readSessionThread!(id, true);
    const log = await this.readSessionLog!(thread, options);
    const busy = ["active", "running", "waiting_for_input", "waiting_for_approval"].includes(thread.status.phase ?? thread.status.type);
    return { ...log, thread, busy,
      activeTurnId: busy ? [...(thread.turns ?? [])].reverse().find((turn) => ["inProgress", "in_progress"].includes(turn.status))?.id ?? null : null };
  }
}

class RestartableFakeProvider
  extends SnapshotFixtureProvider
  implements AgentProvider
{
  public readonly kind = "fake";
  public readonly displayName: string = "Restartable Fake Test Provider";
  public readonly capabilities: AgentProviderCapabilities =
    RESTARTABLE_FAKE_CAPABILITIES;

  private readonly sessionId = "fake-restart-session";
  private readonly initialTurnId = "fake-restart-turn";
  private readonly actionId = "fake-restart-action";
  private cwd = "/tmp";
  private created = false;
  private restarted = false;
  private currentTurnId: string | null = null;
  private submitCount = 0;
  private createInput: AgentSessionInputItem[] | null = null;
  private submitInputItems: AgentSessionInputItem[] | null = null;

  public get submittedInputs(): number {
    return this.submitCount;
  }

  public get lastCreateInput(): AgentSessionInputItem[] | null {
    return this.createInput;
  }

  public get lastSubmitInput(): AgentSessionInputItem[] | null {
    return this.submitInputItems;
  }

  public async start(): Promise<void> {}

  public async close(): Promise<void> { await this.restart(); }

  public async restart(): Promise<void> {
    this.restarted = true;
    this.currentTurnId = null;
  }

  public async getVersion(): Promise<string> {
    return "restart-test";
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.created = true;
    this.restarted = false;
    this.cwd = request.cwd;
    this.createInput = request.input;
    this.currentTurnId = this.initialTurnId;
    const action: AgentPendingAction = {
      id: this.actionId,
      sessionId: this.sessionId,
      kind: "user_input",
      title: "Restart action",
      detail: "Answer before restart",
      requestedAt: Date.now(),
      canApprove: true,
      canApproveForSession: false,
      canDecline: true,
      sessionTitle: "Restart session",
      cwd: this.cwd,
      userInput: {
        question: "Continue?",
        choices: ["yes"],
        allowFreeform: true,
      },
      providerRequestId: this.actionId,
      providerRequestKind: "restartable-fake/user-input",
    };
    this.emit("liveEvent", {
      type: "action_opened",
      action,
    });
    return {
      thread: this.buildThread(false),
      activeTurnId: this.currentTurnId,
      runtime: null,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    assert.equal(request.sessionId, this.sessionId);
    this.submitInputItems = request.input;
    this.submitCount += 1;
    this.restarted = false;
    if (request.activeTurnId) {
      this.currentTurnId = request.activeTurnId;
      return {
        mode: "steer",
        turnId: request.activeTurnId,
      };
    }
    this.currentTurnId = `fake-restart-turn-${this.submitCount}`;
    return {
      mode: "turn",
      turnId: this.currentTurnId,
    };
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    if (!this.created || options.archived) {
      return [];
    }
    return [this.buildThread(false)].slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    assert.equal(threadId, this.sessionId);
    return this.buildThread(includeTurns);
  }

  public async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> {
    if (!this.created) {
      return [];
    }
    return [this.buildThread(false)].slice(0, limit);
  }

  public async readSessionLog(
    _thread: ThreadRecord,
    _options?: AgentSessionLogOptions,
  ): Promise<SessionLogSnapshot> {
    return {
      messages: [],
      activities: [],
      runtime: null,
      totalMessages: 0,
      totalActivities: 0,
      nextSeq: 1,
    };
  }

  public async readSessionRuntime(): Promise<null> {
    return null;
  }

  public respondToPendingAction(action: AgentPendingAction): boolean {
    return action.id === this.actionId;
  }

  private buildThread(includeTurns: boolean): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Restart session",
      preview: "Restart session",
      createdAt: 1,
      updatedAt: this.restarted ? 2 : 1,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: this.restarted
        ? { type: "idle" }
        : { type: "running", activeFlags: ["inProgress"] },
      ...(includeTurns
        ? {
            turns: this.restarted || !this.currentTurnId
              ? []
              : [
                  {
                    id: this.currentTurnId,
                    status: "in_progress",
                    startedAt: 1,
                    completedAt: null,
                  },
                ],
          }
        : {}),
    };
  }
}

class RejectingAccessModeProvider extends RestartableFakeProvider {
  public override async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    if (request.overrides.accessMode === "retired") {
      throw new AgentProviderRequestError(
        "The selected access mode is no longer available.",
      );
    }
    return super.createSession(request);
  }
}

const NO_FILE_MENTION_CAPABILITIES: AgentProviderCapabilities = {
  ...RESTARTABLE_FAKE_CAPABILITIES,
  input: {
    ...RESTARTABLE_FAKE_CAPABILITIES.input,
    fileMentions: false,
  },
};

class NoFileMentionProvider extends RestartableFakeProvider {
  public override readonly displayName = "No File Mention Provider";
  public override readonly capabilities = NO_FILE_MENTION_CAPABILITIES;
}

const LOCAL_IMAGE_FAKE_CAPABILITIES: AgentProviderCapabilities = {
  ...RESTARTABLE_FAKE_CAPABILITIES,
  input: {
    ...RESTARTABLE_FAKE_CAPABILITIES.input,
    localImage: true,
  },
};

class LocalImageFakeProvider extends RestartableFakeProvider {
  public override readonly displayName = "Local Image Fake Provider";
  public override readonly capabilities = LOCAL_IMAGE_FAKE_CAPABILITIES;
}

class SlowReadFakeProvider extends RestartableFakeProvider {
  public override async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    await new Promise((resolve) => setTimeout(resolve, 50));
    return super.readSessionThread(threadId, includeTurns);
  }
}

class ImmediateCompletionProvider extends SnapshotFixtureProvider implements AgentProvider {
  public readonly kind = "fake";
  public readonly displayName = "Immediate Completion Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;

  private readonly sessionId = "fake-immediate-session";
  private readonly createTurnId = "fake-immediate-create-turn";
  private cwd = "/tmp";
  private created = false;
  private lastTurnId: string | null = null;
  private submitCount = 0;
  private unreadableThreadReads: number;

  public constructor(unreadableThreadReads = 0) {
    super();
    this.unreadableThreadReads = unreadableThreadReads;
  }

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "immediate-completion-test";
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.created = true;
    this.cwd = request.cwd;
    const activeTurnId =
      request.input.length > 0 ? this.completeTurn(this.createTurnId) : null;
    return {
      thread: this.buildThread(false),
      activeTurnId,
      runtime: null,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    assert.equal(request.sessionId, this.sessionId);
    this.submitCount += 1;
    const turnId = this.completeTurn(`fake-immediate-submit-turn-${this.submitCount}`);
    return {
      mode: "turn",
      turnId,
    };
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    if (!this.created || options.archived) {
      return [];
    }
    return [this.buildThread(false)].slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    assert.equal(threadId, this.sessionId);
    if (!includeTurns && this.unreadableThreadReads > 0) {
      this.unreadableThreadReads -= 1;
      throw new Error(
        `failed to read thread ${threadId}: rollout file not found`,
      );
    }
    return this.buildThread(includeTurns);
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    if (!this.created) {
      return [];
    }
    return [this.buildThread(false)].slice(0, limit);
  }

  public async readSessionLog(): Promise<SessionLogSnapshot> {
    return {
      messages: [],
      activities: [],
      runtime: null,
      totalMessages: 0,
      totalActivities: 0,
      nextSeq: 1,
    };
  }

  public async readSessionRuntime(): Promise<null> {
    return null;
  }

  private completeTurn(turnId: string): string {
    this.lastTurnId = turnId;
    this.emit("liveEvent", {
      type: "turn_completed",
      sessionId: nativeSessionId(this.sessionId),
      turnId,
      status: "completed",
    });
    return turnId;
  }

  private buildThread(includeTurns: boolean): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Immediate completion session",
      preview: "Immediate completion session",
      createdAt: 1,
      updatedAt: 2,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: { type: "idle" },
      ...(includeTurns && this.lastTurnId
        ? {
            turns: [
              {
                id: this.lastTurnId,
                status: "completed",
                startedAt: 1,
                completedAt: 2,
              },
            ],
          }
        : {}),
    };
  }
}


class SplitFreshnessRecentProvider extends SnapshotFixtureProvider implements AgentProvider {
  public readonly kind = "fake";
  public readonly displayName = "Split Freshness Recent Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;
  public readonly sessionId = "fake-split-freshness-session";
  public readonly freshUpdatedAt = 1_700_000_200_000;
  public readonly staleUpdatedAt = 1_700_000_100_000;
  private readonly cwd = "/tmp/split-freshness";

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "split-freshness-recent-test";
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    if (options.archived) {
      return [];
    }
    return [this.buildThread(this.freshUpdatedAt)].slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    assert.equal(threadId, this.sessionId);
    return this.buildThread(this.staleUpdatedAt, includeTurns);
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    return [this.buildThread(this.freshUpdatedAt)].slice(0, limit);
  }

  public async readSessionLog(): Promise<SessionLogSnapshot> {
    return {
      messages: [],
      activities: [],
      runtime: null,
      totalMessages: 0,
      totalActivities: 0,
      nextSeq: 1,
    };
  }

  public async readSessionRuntime(): Promise<null> {
    return null;
  }

  private buildThread(updatedAt: number, includeTurns = false): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Split freshness recent session",
      preview: "Split freshness recent session",
      createdAt: 1,
      updatedAt,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: { type: "idle" },
      ...(includeTurns
        ? {
            turns: [],
          }
        : {}),
    };
  }
}


class SearchFixtureProvider extends SnapshotFixtureProvider implements AgentProvider {
  public readonly kind = "fake";
  public readonly displayName = "Search Fixture Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;

  private readonly archivedIds: Set<string>;
  private readonly logsById: Map<string, SessionLogSnapshot>;
  private readonly threads: ThreadRecord[];
  private readonly threadsById: Map<string, ThreadRecord>;

  constructor(
    fixtures: Array<{
      thread: ThreadRecord;
      archived: boolean;
      searchText: string;
    }>,
  ) {
    super();
    this.threads = fixtures.map((fixture) => ({
      ...fixture.thread,
      status: { ...fixture.thread.status },
    }));
    this.threadsById = new Map(this.threads.map((thread) => [thread.id, thread]));
    this.archivedIds = new Set(
      fixtures.filter((fixture) => fixture.archived).map((fixture) => fixture.thread.id),
    );
    this.logsById = new Map(
      fixtures.map((fixture) => [
        fixture.thread.id,
        {
          messages: [
            {
              id: `${fixture.thread.id}-msg-1`,
              role: "user",
              text: fixture.searchText,
              content: [],
              attachments: [],
              createdAt: Date.now(),
              seq: 1,
            },
          ],
          activities: [],
          runtime: null,
          totalMessages: 1,
          totalActivities: 0,
          nextSeq: 2,
        } satisfies SessionLogSnapshot,
      ]),
    );
  }

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "search-fixture";
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    return this.threads
      .filter((thread) => this.archivedIds.has(thread.id) === options.archived)
      .sort((left, right) => right.updatedAt - left.updatedAt)
      .slice(0, options.limit)
      .map((thread) => ({ ...thread, status: { ...thread.status } }));
  }

  public async readSessionThread(
    threadId: string,
    _includeTurns: boolean,
  ): Promise<ThreadRecord> {
    const thread = this.threadsById.get(threadId);
    if (!thread) {
      throw new Error(`Unknown fixture session: ${threadId}`);
    }
    return { ...thread, status: { ...thread.status } };
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    return this.listSessionThreads({ limit, archived: false });
  }

  public async readSessionLog(
    thread: ThreadRecord,
    _options?: AgentSessionLogOptions,
  ): Promise<SessionLogSnapshot> {
    const snapshot = this.logsById.get(thread.id);
    if (!snapshot) {
      throw new Error(`Missing fixture log for session: ${thread.id}`);
    }
    return {
      messages: snapshot.messages.map((message) => ({ ...message })),
      activities: snapshot.activities.map((activity) => ({ ...activity })),
      runtime: snapshot.runtime,
      totalMessages: snapshot.totalMessages,
      totalActivities: snapshot.totalActivities,
      nextSeq: snapshot.nextSeq,
    };
  }

  public async readSessionRuntime(): Promise<null> {
    return null;
  }
}

class ActivityReplayFixtureProvider extends SnapshotFixtureProvider implements AgentProvider {
  public readonly kind = "fake";
  public readonly displayName = "Activity Replay Fixture Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;
  public readonly sessionId = "fake-activity-replay-session";
  private updatedAt = 1;
  private output = "before";

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "activity-replay-fixture";
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    if (options.archived) {
      return [];
    }
    return [this.buildThread()].slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    _includeTurns: boolean,
  ): Promise<ThreadRecord> {
    assert.equal(threadId, this.sessionId);
    return this.buildThread();
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    return [this.buildThread()].slice(0, limit);
  }

  public async readSessionLog(
    thread: ThreadRecord,
    _options?: AgentSessionLogOptions,
  ): Promise<SessionLogSnapshot> {
    assert.equal(thread.id, this.sessionId);
    return {
      messages: [],
      activities: [
        {
          id: "cmd-1",
          type: "command",
          turnId: "turn-1",
          createdAt: 1,
          seq: 1,
          status: "completed",
          command: "npm test",
          cwd: "/repo",
          output: this.output,
          exitCode: 0,
          durationMs: 1,
          source: "agent",
          processId: "proc-1",
          commandActions: [],
          terminalStatus: null,
          terminalInput: null,
        },
      ],
      runtime: null,
      totalMessages: 0,
      totalActivities: 1,
      nextSeq: 2,
    };
  }

  public async readSessionRuntime(): Promise<null> {
    return null;
  }

  public mutatePersistedActivity(output: string): void {
    this.output = output;
    this.updatedAt += 1;
  }

  public mutatePersistedActivityWithoutTimestampChange(output: string): void {
    this.output = output;
  }

  private buildThread(): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Activity replay fixture",
      preview: "Activity replay fixture",
      createdAt: 1,
      updatedAt: this.updatedAt,
      cwd: "/repo",
      source: "fake",
      path: null,
      status: { type: "idle" },
    };
  }
}

function secondsForIso(value: string): number {
  return Math.trunc(Date.parse(value) / 1000);
}

function makeSearchFixtureThread(
  id: string,
  updatedAt: number,
  preview: string,
): ThreadRecord {
  return {
    id,
    name: preview,
    preview,
    createdAt: updatedAt - 60,
    updatedAt,
    cwd: "/repo",
    source: "fake",
    path: null,
    status: { type: "idle" },
  };
}

function makeSingleProviderRuntime(
  fakeOptions: FakeAgentProviderOptions,
): { runtime: AgentProviderRuntime; provider: FakeAgentProvider } {
  const provider = new FakeAgentProvider(fakeOptions);
  const defSummaries = listAgentProviderDefinitionSummaries();
  const fakeDef = defSummaries.find((d) => d.kind === "fake")!;
  const fakeConfig = {
    kind: "fake" as const,
    latencyMs: fakeOptions.latencyMs ?? 0,
    seedSessions: fakeOptions.seedSessions ?? false,
    workspaceRoot: fakeOptions.workspaceRoot ?? null,
    capabilityProfile: fakeOptions.capabilityProfile ?? "full",
  };
  return { provider, runtime: new AgentProviderRuntime([{ id: "fake", kind: "fake", create: () => provider,
    configSummary: summarizeAgentProviderConfig(fakeConfig), definitionSummary: { ...fakeDef, capabilities: provider.capabilities } }], "fake") };
}

async function openSessionLiveSocket(
  port: number,
  token: string,
  sessionId: string,
): Promise<{ socket: WebSocket; events: any[] }> {
  const events: any[] = [];
  const socket = await new Promise<WebSocket>((resolve, reject) => {
    const ws = new WebSocket(
      `ws://127.0.0.1:${port}/api/live?sessionId=${encodeURIComponent(sessionId)}`,
      {
        headers: { Authorization: `Bearer ${token}` },
      },
    );
    ws.on("message", (data) => {
      const raw = typeof data === "string" ? data : data.toString();
      events.push(JSON.parse(raw));
    });
    const handleError = (error: Error) => reject(error);
    ws.once("error", handleError);
    ws.once("open", () => {
      ws.off("error", handleError);
      resolve(ws);
    });
  });
  return { socket, events };
}

async function openRecentSessionsLiveSocket(
  port: number,
  token: string,
): Promise<{ socket: WebSocket; events: any[] }> {
  const events: any[] = [];
  const socket = await new Promise<WebSocket>((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/sessions/live`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    ws.on("message", (data) => {
      const raw = typeof data === "string" ? data : data.toString();
      events.push(JSON.parse(raw));
    });
    const handleError = (error: Error) => reject(error);
    ws.once("error", handleError);
    ws.once("open", () => {
      ws.off("error", handleError);
      resolve(ws);
    });
  });
  return { socket, events };
}

async function closeSessionLiveSocket(socket: WebSocket): Promise<void> {
  if (socket.readyState === socket.CLOSED) {
    return;
  }
  await new Promise<void>((resolve) => {
    socket.once("close", () => resolve());
    socket.close();
  });
}

async function waitFor<T>(
  getValue: () => T | null | undefined,
  label: string,
): Promise<NonNullable<T>> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const value = getValue();
    if (value !== null && value !== undefined) {
      return value;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Timed out waiting for ${label}`);
}

it("gates session deletion and clears host data only after native success", async () => {
  const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-delete-test-"));
  const { runtime, provider } = makeSingleProviderRuntime({ latencyMs: 0, seedSessions: false, workspaceRoot: stateDir });
  let deleted: string | null = null;
  let fail = true;
  Object.assign(provider, { deleteSession: async (id: string) => {
    if (fail) throw new AgentProviderRequestError("Deletion failed", 409);
    deleted = id;
  } });
  try {
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      await runtime.ensure(runtime.defaultProvider);
      const created = await provider.createSession({ cwd: stateDir, input: [], overrides: EMPTY_OVERRIDES });
      const nativeId = created.thread.id;
      const id = wrapProviderScopedId("fake", nativeId);
      provider.emit("liveEvent", { type: "assistant_message_completed", sessionId: nativeId,
        message: { id: "saved-answer", text: "Keep this until success" } });
      provider.emit("liveEvent", { type: "plan_updated", sessionId: nativeId, plan: [{ step: "Saved", status: "pending" }] });
      const send = () => request({ hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${encodeURIComponent(id)}`, method: "DELETE", headers: { Authorization: `Bearer ${config.token}` } });
      assert.equal((await send()).statusCode, 501);
      provider.capabilities.sessions.delete = true;
      assert.equal((await send()).statusCode, 409);
      const db = new DatabaseSync(nodePath.join(stateDir, "sessions-v1.db"));
      try {
        assert.ok(db.prepare("SELECT 1 FROM plans WHERE session_id = ?").get(id));
        assert.ok(db.prepare("SELECT 1 FROM session_recovery WHERE session_id = ?").get(id));
        fail = false;
        assert.equal((await send()).statusCode, 200);
        assert.equal(deleted, nativeId);
        assert.equal(db.prepare("SELECT 1 FROM plans WHERE session_id = ?").get(id), undefined);
        assert.equal(db.prepare("SELECT 1 FROM session_recovery WHERE session_id = ?").get(id), undefined);
      } finally { db.close(); }
    });
  } finally { await rm(stateDir, { recursive: true, force: true }); }
});

describe("/healthz", () => {
  it("returns 200 when provider is healthy", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server) => {
      const res = await request({ hostname: "127.0.0.1", port: server.port, path: "/healthz", method: "GET" });
      assert.equal(res.statusCode, 200);
      assert.equal((res.body as any).ok, true);
    });
  });

  it("keeps host controls available when one provider cannot start", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-provider-failure-"));
    const config = makeConfig(stateDir);
    config.terminal.enabled = true;
    const bad = new FakeAgentProvider({ seedSessions: false });
    bad.start = async () => { throw new Error("Missing executable"); };
    const good = new FakeAgentProvider({ seedSessions: false });
    const base = makeCustomSingleProviderRuntime(bad).defaultProvider;
    const runtime = new AgentProviderRuntime([
      { ...base, id: "broken", create: () => bad },
      { ...base, id: "working", create: () => good },
    ], "broken");
    await withServerRuntime(config, runtime, async (server) => {
      const headers = { Authorization: `Bearer ${config.token}`, "content-type": "application/json" };
      assert.ok(runtime.providers.every((entry) => entry.state === "idle"));
      const failed = await request({ hostname: "127.0.0.1", port: server.port, path: "/api/sessions/create", method: "POST", headers,
        body: JSON.stringify({ provider: "broken", cwd: stateDir, input: [] }) });
      assert.equal(failed.statusCode, 503);
      const created = await request({ hostname: "127.0.0.1", port: server.port, path: "/api/sessions/create", method: "POST", headers,
        body: JSON.stringify({ provider: "working", cwd: stateDir, input: [] }) });
      assert.equal(created.statusCode, 201);
      const health = await request({ hostname: "127.0.0.1", port: server.port, path: "/healthz" });
      assert.equal(health.statusCode, 200);
      const terminals = await request({ hostname: "127.0.0.1", port: server.port, path: "/api/terminals", headers });
      assert.equal(terminals.statusCode, 200);
      const node = await request({ hostname: "127.0.0.1", port: server.port, path: "/api/node", headers });
      assert.deepEqual((node.body as any).supportedProviders.map((entry: any) => entry.state), ["unavailable", "ready"]);
      await server.close();
      await server.close();
    });
  });

  it("keeps host health independent of a rejected provider health probe", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-provider-health-"));
    const provider = new FakeAgentProvider({ seedSessions: false });
    const runtime = makeCustomSingleProviderRuntime(provider);
    Object.assign(provider, { health: async () => { throw new Error("Connection failed"); } });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server) => {
      await runtime.ensure(runtime.defaultProvider);
      await runtime.checkHealth();
      assert.equal(runtime.defaultProvider.state, "unavailable");
      const res = await request({ hostname: "127.0.0.1", port: server.port, path: "/healthz" });
      assert.equal(res.statusCode, 200);
      assert.equal((res.body as any).ok, true);
    });
  });

});

describe("browser CORS", () => {
  it("allows loopback browser origins", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: {
          Authorization: `Bearer ${config.token}`,
          Origin: "http://localhost:3000",
        },
      });
      assert.equal(res.statusCode, 200);
      assert.equal(
        res.headers["access-control-allow-origin"],
        "http://localhost:3000",
      );
    });
  });

  it("allows the hosted Sidemesh web app origin", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: {
          Authorization: `Bearer ${config.token}`,
          Origin: "https://app.sidemesh.com",
        },
      });
      assert.equal(res.statusCode, 200);
      assert.equal(
        res.headers["access-control-allow-origin"],
        "https://app.sidemesh.com",
      );
    });
  });

  it("allows an explicitly configured browser origin", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    config.allowedBrowserOrigins = ["https://self-hosted.example"];
    await withServer(config, async (server) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: {
          Authorization: `Bearer ${config.token}`,
          Origin: "https://self-hosted.example",
        },
      });
      assert.equal(res.statusCode, 200);
      assert.equal(
        res.headers["access-control-allow-origin"],
        "https://self-hosted.example",
      );
    });
  });

  it("accepts browser WebSockets authenticated by subprotocol", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const encodedToken = Buffer.from(config.token, "utf8").toString("base64url");
      const socket = await new Promise<WebSocket>((resolve, reject) => {
        const ws = new WebSocket(
          `ws://127.0.0.1:${server.port}/api/sessions/live`,
          ["sidemesh", `sidemesh.auth.${encodedToken}`],
          { headers: { Origin: "https://app.sidemesh.com" } },
        );
        ws.once("open", () => resolve(ws));
        ws.once("error", reject);
      });
      assert.equal(socket.protocol, "sidemesh");
      await closeSessionLiveSocket(socket);
    });
  });

  it("rejects authenticated WebSockets from untrusted browser origins", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const encodedToken = Buffer.from(config.token, "utf8").toString("base64url");
      await assert.rejects(
        new Promise<WebSocket>((resolve, reject) => {
          const ws = new WebSocket(
            `ws://127.0.0.1:${server.port}/api/sessions/live`,
            ["sidemesh", `sidemesh.auth.${encodedToken}`],
            { headers: { Origin: "https://attacker.example" } },
          );
          ws.once("open", () => resolve(ws));
          ws.once("error", reject);
        }),
      );
    });
  });

  it("does not grant CORS to untrusted browser origins", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: {
          Authorization: `Bearer ${config.token}`,
          Origin: "https://attacker.example",
        },
      });
      assert.equal(res.statusCode, 200);
      assert.equal(res.headers["access-control-allow-origin"], undefined);
    });
  });
});

describe("session input item parsing", () => {
  it("saves initial input before dispatch and returns the session when its reply is lost", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-initial-input-"));
    const provider = new RestartableFakeProvider();
    let sends = 0;
    provider.submitInput = async (input) => {
      sends++;
      assert.deepEqual(provider.lastCreateInput, []);
      const db = new DatabaseSync(nodePath.join(stateDir, "sessions-v1.db"), { readOnly: true });
      try {
        const row = db.prepare("SELECT state, payload FROM inputs WHERE key = ?").get(`${input.sessionId}:first:one`) as { state: string; payload: string };
        assert.equal(row.state, "dispatching");
        assert.deepEqual(JSON.parse(row.payload).input, input.input);
      } finally { db.close(); }
      throw new Error("Initial reply lost");
    };
    await withServerRuntime(makeConfig(stateDir), makeCustomSingleProviderRuntime(provider), async (server, config) => {
      const headers = { Authorization: "Bearer " + config.token, "content-type": "application/json" };
      const body = { clientMessageId: "first:one", input: [{ type: "text", text: "first input" }] };
      const created = await request({ hostname: "127.0.0.1", port: server.port, path: "/api/sessions/create",
        method: "POST", headers, body: JSON.stringify({ ...body, cwd: stateDir }) });
      assert.equal(created.statusCode, 502);
      const result = created.body as { session: { id: string }; code: string; clientMessageId: string };
      assert.equal(result.session.id, wrapProviderScopedId("fake", "fake-restart-session"));
      assert.equal(result.code, "initial_input_failed");
      assert.equal(result.clientMessageId, body.clientMessageId);
      const retry = await request({ hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${result.session.id}/input`, method: "POST", headers, body: JSON.stringify(body) });
      assert.equal(retry.statusCode, 409);
      assert.equal((retry.body as { code: string }).code, "input_delivery_uncertain");
      assert.equal(sends, 1);
    });
  });

  async function prepareFileInputWorkspace(stateDir: string): Promise<string> {
    const cwd = nodePath.join(stateDir, "workspace");
    await mkdir(nodePath.join(cwd, "src"), { recursive: true });
    await writeFile(nodePath.join(cwd, "README.md"), "readme\n", "utf8");
    await writeFile(nodePath.join(cwd, "package.json"), "{}\n", "utf8");
    return realpath(cwd);
  }

  it("returns a request error when a provider rejects a stale access mode", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const runtime = makeCustomSingleProviderRuntime(
      new RejectingAccessModeProvider(),
    );
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const response = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd: "/tmp",
          input: [{ type: "text", text: "start", text_elements: [] }],
          accessMode: "retired",
        }),
      });

      assert.equal(response.statusCode, 400);
      assert.deepEqual(response.body, {
        error: "The selected access mode is no longer available.",
      });
    });
  });

  it("passes file input items through create and submit routes", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const created = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd,
          input: [
            { type: "file", path: "README.md" },
            { type: "file", path: "src", isDirectory: true },
            { type: "text", text: "inspect these files" },
          ],
        }),
      });
      assert.equal(created.statusCode, 201);
      assert.deepEqual(provider.lastSubmitInput, [
        { type: "file", path: nodePath.join(cwd, "README.md") },
        { type: "file", path: nodePath.join(cwd, "src"), isDirectory: true },
        { type: "text", text: "inspect these files", text_elements: [] },
      ]);

      const sessionId = (created.body as any).session.id as string;
      const submitted = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          input: [
            { type: "file", path: "package.json" },
            { type: "text", text: "now inspect this manifest" },
          ],
        }),
      });
      assert.equal(submitted.statusCode, 200);
      assert.deepEqual(provider.lastSubmitInput, [
        { type: "file", path: nodePath.join(cwd, "package.json") },
        { type: "text", text: "now inspect this manifest", text_elements: [] },
      ]);
    });
  });

  it("derives file input directory metadata from the filesystem", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd,
          input: [
            { type: "file", path: "README.md", isDirectory: true },
            { type: "file", path: "src" },
          ],
        }),
      });
      assert.equal(res.statusCode, 201);
      assert.deepEqual(provider.lastSubmitInput, [
        { type: "file", path: nodePath.join(cwd, "README.md") },
        { type: "file", path: nodePath.join(cwd, "src"), isDirectory: true },
      ]);
    });
  });

  it("replays deduped file input retries without resolving moved files", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const created = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd,
          input: [{ type: "text", text: "start", text_elements: [] }],
        }),
      });
      assert.equal(created.statusCode, 201);
      const sessionId = (created.body as any).session.id as string;
      const body = {
        clientMessageId: "file-retry-1",
        input: [
          { type: "file", path: "package.json" },
          { type: "text", text: "retry this file mention" },
        ],
      };

      const first = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      });
      assert.equal(first.statusCode, 200);
      assert.equal((first.body as any).replayed, false);
      assert.equal(provider.submittedInputs, 2);

      await rm(nodePath.join(cwd, "package.json"));
      const retry = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify(body),
      });
      assert.equal(retry.statusCode, 200);
      assert.equal((retry.body as any).replayed, true);
      assert.equal((retry.body as any).messageId, (first.body as any).messageId);
      assert.equal(provider.submittedInputs, 2);
    });
  });


  it("recovers queued input after restart and cancels the next queued input before stop", async () => {
    class QueueProvider extends RestartableFakeProvider {
      override readonly capabilities = { ...RESTARTABLE_FAKE_CAPABILITIES,
        input: { ...RESTARTABLE_FAKE_CAPABILITIES.input, steer: false } };
      async interruptTurn(sessionId: string, turnId: string): Promise<void> {
        await this.restart();
        this.emit("liveEvent", { type: "turn_completed", sessionId: nativeSessionId(sessionId), turnId, status: "interrupted" });
      }
    }
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-queue-"));
    const config = makeConfig(stateDir);
    const provider = new QueueProvider();
    let server: RunningServer | null = null;
    let sessionId = "";
    const send = (id: string) => request({ hostname: "127.0.0.1", port: server!.port,
      path: `/api/sessions/${sessionId}/input`, method: "POST",
      headers: { Authorization: "Bearer " + config.token, "content-type": "application/json" },
      body: JSON.stringify({ clientMessageId: id, input: [{ type: "text", text: id }] }),
    });
    try {
      server = await startServer(config, makeCustomSingleProviderRuntime(provider));
      const created = await provider.createSession({ cwd: stateDir, input: [], overrides: EMPTY_OVERRIDES });
      sessionId = created.thread.id;
      const queued = await send("queue-one");
      assert.equal(queued.statusCode, 200);
      assert.equal((queued.body as { mode: string }).mode, "queued");
      assert.equal(provider.submittedInputs, 0);
      await server.close();
      server = null;
      await provider.restart();
      server = await startServer(config, makeCustomSingleProviderRuntime(provider));
      await waitFor(() => provider.submittedInputs === 1 ? true : null, "queued input after daemon restart");
      assert.deepEqual(provider.lastSubmitInput, [{ type: "text", text: "queue-one", text_elements: [] }]);
      assert.equal((await send("queue-one")).statusCode, 200);
      assert.equal((await send("queue-two")).statusCode, 200);
      const stopped = await request({ hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${sessionId}/stop`, method: "POST",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(stopped.statusCode, 200);
      const cancelled = await send("queue-two");
      assert.equal(cancelled.statusCode, 409);
      assert.equal((cancelled.body as { code: string }).code, "input_cancelled");
      assert.equal(provider.submittedInputs, 1);
    } finally { await server?.close(); await rm(stateDir, { recursive: true, force: true }); }
  });

  it("closes the provider before waiting for an input request with a lost reply", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-close-input-"));
    const provider = new RestartableFakeProvider();
    const config = makeConfig(stateDir);
    let started!: () => void;
    let rejectSend!: (error: Error) => void;
    const sending = new Promise<void>((resolve) => { started = resolve; });
    provider.submitInput = async () => new Promise((_, reject) => { rejectSend = reject; started(); });
    provider.close = async () => { rejectSend?.(new Error("Provider closed before reply")); };
    const server = await startServer(config, makeCustomSingleProviderRuntime(provider));
    let closed = false;
    try {
      const created = await provider.createSession({ cwd: stateDir, input: [], overrides: EMPTY_OVERRIDES });
      const result = request({ hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${created.thread.id}/input`, method: "POST",
        headers: { Authorization: "Bearer " + config.token, "content-type": "application/json" },
        body: JSON.stringify({ clientMessageId: "close-input", input: [{ type: "text", text: "saved input" }] }) });
      await sending;
      await server.close();
      closed = true;
      assert.equal((await result).statusCode, 500);
      const db = new DatabaseSync(nodePath.join(stateDir, "sessions-v1.db"), { readOnly: true });
      try {
        const row = db.prepare("SELECT state, payload FROM inputs WHERE key = ?").get(`${wrapProviderScopedId("fake", created.thread.id)}:close-input`) as { state: string; payload: string };
        assert.equal(row.state, "uncertain");
        assert.equal(JSON.parse(row.payload).input[0].text, "saved input");
      } finally { db.close(); }
    } finally { if (!closed) { await provider.close(); await server.close(); } await rm(stateDir, { recursive: true, force: true }); }
  });

  it("blocks retries after an uncertain provider send, including after daemon restart", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const provider = new RestartableFakeProvider();
    const config = makeConfig(stateDir);
    const runtime = makeCustomSingleProviderRuntime(provider);
    let sessionId = "";
    let sends = 0;
    provider.submitInput = async () => {
      sends += 1;
      throw new Error("Connection lost after send");
    };
    const send = (server: RunningServer) => request({
      hostname: "127.0.0.1", port: server.port,
      path: `/api/sessions/${encodeURIComponent(sessionId)}/input`, method: "POST",
      headers: { Authorization: "Bearer " + config.token, "content-type": "application/json" },
      body: JSON.stringify({ clientMessageId: "uncertain-1", input: [{ type: "text", text: "send once" }] }),
    });
    let server: RunningServer | null = null;
    try {
      server = await startServer(config, runtime);
      const created = await provider.createSession({ cwd: stateDir, input: [], overrides: EMPTY_OVERRIDES });
      sessionId = created.thread.id;
      assert.equal((await send(server)).statusCode, 500);
      const retry = await send(server);
      assert.equal(retry.statusCode, 409);
      assert.equal((retry.body as { code: string }).code, "input_delivery_uncertain");
      await server.close();
      server = null;
      server = await startServer(config, makeCustomSingleProviderRuntime(provider));
      assert.equal((await send(server)).statusCode, 409);
      assert.equal(sends, 1);
    } finally {
      await server?.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });

  it("deduplicates concurrent file input retries before file resolution", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const provider = new SlowReadFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const created = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd,
          input: [{ type: "text", text: "start", text_elements: [] }],
        }),
      });
      assert.equal(created.statusCode, 201);
      const sessionId = (created.body as any).session.id as string;
      const body = JSON.stringify({
        clientMessageId: "file-concurrent-1",
        input: [
          { type: "file", path: "package.json" },
          { type: "text", text: "dedupe this concurrent file mention" },
        ],
      });
      const send = () =>
        request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "content-type": "application/json",
          },
          body,
        });

      const [first, second] = await Promise.all([send(), send()]);
      assert.equal(first.statusCode, 200);
      assert.equal(second.statusCode, 200);
      assert.deepEqual(
        [(first.body as any).replayed, (second.body as any).replayed].sort(),
        [false, true],
      );
      assert.equal((first.body as any).messageId, (second.body as any).messageId);
      assert.equal(provider.submittedInputs, 2);
    });
  });

  it("rejects non-regular file input targets inside the workspace", async () => {
    if (process.platform === "win32") {
      return;
    }
    // Darwin limits Unix-domain socket paths to roughly 104 bytes. Its
    // TMPDIR is much longer than /tmp, so keep this fixture intentionally
    // short while still placing the socket inside the workspace under test.
    const stateDir = await mkdtemp(nodePath.join("/tmp", "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const socketPath = nodePath.join(cwd, "agent.sock");
    const socketServer = createNetServer();
    await new Promise<void>((resolve, reject) => {
      socketServer.once("error", reject);
      socketServer.listen(socketPath, resolve);
    });
    let socketClosed = false;
    const closeSocket = async (): Promise<void> => {
      if (socketClosed) return;
      socketClosed = true;
      await new Promise<void>((resolve) => socketServer.close(() => resolve()));
    };
    try {
      const provider = new RestartableFakeProvider();
      const runtime = makeCustomSingleProviderRuntime(provider);
      await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
        try {
          const res = await request({
            hostname: "127.0.0.1",
            port: server.port,
            path: "/api/sessions/create",
            method: "POST",
            headers: {
              Authorization: "Bearer " + config.token,
              "content-type": "application/json",
            },
            body: JSON.stringify({
              cwd,
              input: [{ type: "file", path: "agent.sock" }],
            }),
          });
          assert.equal(res.statusCode, 400);
          assert.equal(
            (res.body as any).error,
            "file mention path must be a regular file or directory",
          );
          assert.equal(provider.lastCreateInput, null);
        } finally {
          await closeSocket();
        }
      });
    } finally {
      await closeSocket();
    }
  });

  it("rejects unsupported or malformed content without replacing it with fallback text", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const provider = new NoFileMentionProvider();
    await withServerRuntime(makeConfig(stateDir), makeCustomSingleProviderRuntime(provider), async (server, config) => {
      for (const [input, status] of [
        [{ type: "audio", mimeType: "audio/wav", data: "UklGRg==" }, 501],
        [{ type: "resource", uri: "attachment:///note", text: "content" }, 501],
        [{ type: "resourceLink", uri: "https://example.com", name: "Reference" }, 501],
        [{ type: "audio", mimeType: "audio/wav", data: "invalid" }, 400],
        [{ type: "resource", uri: "javascript:alert(1)", text: "content" }, 400],
      ] as const) {
        const response = await request({ hostname: "127.0.0.1", port: server.port, path: "/api/sessions/create", method: "POST",
          headers: { Authorization: "Bearer " + config.token, "content-type": "application/json" },
          body: JSON.stringify({ cwd, prompt: "fallback", input: [input] }) });
        assert.equal(response.statusCode, status);
      }
      assert.equal(provider.lastCreateInput, null);
    });
  });

  it("rejects file inputs when the selected provider lacks file mention support", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const provider = new NoFileMentionProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd,
          prompt: "fallback text must not hide unsupported file input",
          input: [{ type: "file", path: "README.md" }],
        }),
      });
      assert.equal(res.statusCode, 501);
      assert.equal(
        (res.body as any).error,
        "No File Mention Provider does not support file mentions",
      );
      assert.equal(provider.lastCreateInput, null);
    });
  });

  it("rejects file inputs outside the session workspace", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const outsidePath = nodePath.join(stateDir, "outside.txt");
    await writeFile(outsidePath, "outside\n", "utf8");
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd,
          input: [{ type: "file", path: outsidePath }],
        }),
      });
      assert.equal(res.statusCode, 403);
      assert.equal((res.body as any).error, "path is outside any workspace");
      assert.equal(provider.lastCreateInput, null);
    });
  });

  it("rejects local image inputs outside the session workspace", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const outsidePath = nodePath.join(stateDir, "outside.png");
    await writeFile(outsidePath, "outside\n", "utf8");
    const provider = new LocalImageFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd,
          input: [{ type: "localImage", path: outsidePath }],
        }),
      });
      assert.equal(res.statusCode, 403);
      assert.equal((res.body as any).error, "path is outside any workspace");
      assert.equal(provider.lastCreateInput, null);
    });
  });
});

describe("POST /api/admin/provider/:kind/logout", () => {
  it("requires authentication and declared support before calling the selected agent", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    class LogoutProvider extends RestartableFakeProvider {
      override readonly capabilities = structuredClone(FAKE_PROVIDER_CAPABILITIES);
      logouts = 0;
      async logout(): Promise<void> { this.logouts++; }
    }
    const provider = new LogoutProvider();
    await withServerRuntime(makeConfig(stateDir), makeCustomSingleProviderRuntime(provider), async (server, config) => {
      const send = (authenticated: boolean) => request({ hostname: "127.0.0.1", port: server.port,
        path: "/api/admin/provider/fake/logout", method: "POST",
        headers: authenticated ? { Authorization: "Bearer " + config.token } : {} });
      assert.equal((await send(false)).statusCode, 401);
      assert.notEqual((await send(true)).statusCode, 200);
      assert.equal(provider.logouts, 0);
      provider.capabilities.lifecycle.logout = true;
      assert.equal((await send(true)).statusCode, 200);
      assert.equal(provider.logouts, 1);
    });
  });
});

describe("POST /api/admin/provider/:kind/restart", () => {
  it("returns 400 for unknown provider kind", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/provider/unknown/restart",
        method: "POST",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(res.statusCode, 400);
      assert.equal((res.body as any).error, "unknown provider kind");
    });
  });

  it("can recreate a configured provider without a native restart method", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/provider/fake/restart",
        method: "POST",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(res.statusCode, 200);
    });
  });

  it("clears stale pending actions and active turns after provider restart", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const created = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd: "/tmp/restart-test",
          input: [{ type: "text", text: "start", text_elements: [] }],
        }),
      });
      assert.equal(created.statusCode, 201);
      const sessionId = (created.body as any).session.id as string;
      assert.equal((created.body as any).activeTurnId, "fake-restart-turn");

      const beforeStatus = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(beforeStatus.statusCode, 200);
      assert.equal((beforeStatus.body as any).isRunning, true);
      assert.equal((beforeStatus.body as any).pendingAction.id, wrapProviderScopedId("fake", "fake-restart-action"));

      const beforeActions = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/actions",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(beforeActions.statusCode, 200);
      assert.equal((beforeActions.body as any[]).length, 1);

      const sessionLive = await openSessionLiveSocket(server.port, config.token, sessionId);
      try {
        await waitFor(
          () => sessionLive.events.find((event) => event.type === "hello"),
          "restart session hello",
        );
        provider.emit("liveEvent", {
          type: "provider_warning",
          sessionId: nativeSessionId(sessionId),
          level: "warning",
          code: "restart-seed",
          message: "seed session seq",
        });
        const seeded = await waitFor(
          () =>
            sessionLive.events.find(
              (event) =>
                event.type === "provider_warning" && event.code === "restart-seed",
            ),
          "restart seed live event",
        );
        assert.equal(typeof seeded.seq, "number");
        assert.equal(typeof seeded.revision, "number");

        const restart = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/admin/provider/fake/restart",
          method: "POST",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(restart.statusCode, 200);

        const actionResolved = await waitFor(
          () =>
            sessionLive.events.find(
              (event) =>
                event.type === "action_resolved" &&
                event.actionId === wrapProviderScopedId("fake", "fake-restart-action"),
            ),
          "restart action resolved live event",
        );
        const invalidated = await waitFor(
          () => sessionLive.events.find((event) => event.type === "history_invalidated"),
          "restart snapshot invalidation",
        );
        assert.equal(actionResolved.seq, seeded.seq + 1);
        assert.equal(invalidated.seq, actionResolved.seq + 1);
        assert.equal(sessionLive.events.some((event) => event.type === "turn_completed"), false);
      } finally {
        await closeSessionLiveSocket(sessionLive.socket);
      }

      const afterStatus = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(afterStatus.statusCode, 200);
      assert.equal((afterStatus.body as any).isRunning, false);
      assert.equal((afterStatus.body as any).pendingAction, null);

      const afterActions = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/actions",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(afterActions.statusCode, 200);
      assert.deepEqual(afterActions.body, []);
    });
  });

  it("retains interrupted input and blocks an uncertain resend after provider restart", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const created = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd: "/tmp/restart-test",
          input: [{ type: "text", text: "start", text_elements: [] }],
        }),
      });
      assert.equal(created.statusCode, 201);
      const sessionId = (created.body as any).session.id as string;

      const firstSend = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          input: [{ type: "text", text: "retry me", text_elements: [] }],
          clientMessageId: "local-1",
        }),
      });
      assert.equal(firstSend.statusCode, 200);
      assert.equal((firstSend.body as any).replayed, false);
      assert.equal(provider.submittedInputs, 2);

      const duplicateBeforeRestart = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          input: [{ type: "text", text: "retry me", text_elements: [] }],
          clientMessageId: "local-1",
        }),
      });
      assert.equal(duplicateBeforeRestart.statusCode, 200);
      assert.equal((duplicateBeforeRestart.body as any).replayed, true);
      assert.equal(provider.submittedInputs, 2);

      const restart = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/provider/fake/restart",
        method: "POST",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(restart.statusCode, 200);

      const retryAfterRestart = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          input: [{ type: "text", text: "retry me", text_elements: [] }],
          clientMessageId: "local-1",
        }),
      });
      assert.equal(retryAfterRestart.statusCode, 409);
      assert.equal((retryAfterRestart.body as { code: string }).code, "input_delivery_uncertain");
      assert.equal(provider.submittedInputs, 2);
    });
  });
});

describe("GET /api/node", () => {
  it("exposes default-provider and per-provider capability maps", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });

      assert.equal(res.statusCode, 200);
      const body = res.body as any;
      assert.equal(body.provider, "fake");
      assert.equal(body.defaultProviderCapabilities.sessions.create, true);
      assert.equal(body.defaultProviderCapabilities.sessions.create, true);
      assert.equal(body.searchSessions, true);
      assert.equal(body.hostCapabilities.workspace.filesystem, true);
      assert.equal(body.supportedProviders.length, 1);
      assert.equal(body.supportedProviders[0].kind, "fake");
      assert.equal(body.supportedProviders[0].capabilities.sessions.create, true);
      assert.equal(body.updateChannel, "stable");
      assert.equal(body.latestCommitSha, null);
    });
  });

  it("exposes and selects each configured instance of the same provider kind", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    config.providers = [{ ...config.provider, id: "fake" }, { ...config.provider, id: "reviewer" }];
    config.defaultProviderId = "reviewer";
    await withServerRuntime(config, createAgentProviderRuntime(config), async (server) => {
      const headers = { Authorization: "Bearer " + config.token, "content-type": "application/json" };
      const node = await request({ hostname: "127.0.0.1", port: server.port, path: "/api/node", headers });
      const metadata = node.body as { providerId: string; supportedProviders: Array<{ id: string; kind: string; isDefault: boolean }> };
      assert.equal(metadata.providerId, "reviewer");
      assert.deepEqual(metadata.supportedProviders.map(({ id, kind, isDefault }) => ({ id, kind, isDefault })), [
        { id: "fake", kind: "fake", isDefault: false },
        { id: "reviewer", kind: "fake", isDefault: true },
      ]);
      for (const id of ["fake", "reviewer"]) {
        const created = await request({ hostname: "127.0.0.1", port: server.port,
          path: "/api/sessions/create", method: "POST", headers,
          body: JSON.stringify({ provider: id, cwd: stateDir, input: [] }),
        });
        assert.equal(created.statusCode, 201);
        const session = (created.body as { session: { id: string; provider: string; providerId: string } }).session;
        assert.ok(session.id.startsWith(`${id}:`));
        assert.equal(session.providerId, id);
        assert.equal(session.provider, "fake");
      }
    });
  });

  it("returns mobile client version hints when configured", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(
      makeConfig(stateDir, {
        recommendedMobileClientVersion: "1.2.0",
        minimumMobileClientVersion: "1.0.0",
      }),
      async (server, config) => {
        const res = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/node",
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });

        assert.equal(res.statusCode, 200);
        const body = res.body as any;
        assert.equal(body.recommendedMobileClientVersion, "1.2.0");
        assert.equal(body.minimumMobileClientVersion, "1.0.0");
      },
    );
  });

  it("with two providers: default capabilities and per-provider capabilities remain distinct", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    // Default provider: full profile (has models, skills, searchSessions, etc.)
    // Secondary provider: chat-only profile (no models, no skills, no searchSessions)
    const runtime = makeMultiProviderRuntime(
      { capabilityProfile: "full" },
      { capabilityProfile: "chat-only" },
    );
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });

      assert.equal(res.statusCode, 200);
      const body = res.body as any;

      assert.equal(body.provider, "fake");
      assert.equal(body.supportedProviders.length, 2);

      // Only the canonical field exposes the default provider's capabilities.
      assert.equal("providerCapabilities" in body, false);
      assert.equal("codexVersion" in body, false);
      assert.equal(body.defaultProviderCapabilities.configuration.models, true);

      // The secondary (chat-only) entry must retain its own distinct flags.
      const secondary = body.supportedProviders.find((p: any) => !p.isDefault);
      assert.ok(secondary, "secondary provider entry missing");
      assert.equal(secondary.capabilities.configuration.models, false);
      assert.equal(secondary.capabilities.configuration.skills, false);

      // The default entry must show full capabilities.
      const defaultEntry = body.supportedProviders.find((p: any) => p.isDefault);
      assert.ok(defaultEntry);
      assert.equal(defaultEntry.capabilities.configuration.models, true);
    });
  });
});

describe("GET /api/usage", () => {
  it("returns host usage observations from configured providers", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/usage",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });

      assert.equal(res.statusCode, 200);
      const body = res.body as any;
      assert.equal(body.host.label, "test");
      assert.equal(body.observations.length, 1);
      assert.equal(body.observations[0].hostLabel, "test");
      assert.equal(body.observations[0].provider.kind, "fake");
      assert.equal(body.observations[0].health, "ok");
      assert.equal(body.observations[0].windows[0].id, "primary");
    });
  });
});

describe("POST /api/admin/update", () => {
  it("rejects unknown channel overrides", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ channel: "nightly" }),
      });

      assert.equal(res.statusCode, 400);
      assert.equal(
        (res.body as any).error,
        "channel must be stable or bleeding-edge",
      );
    });
  });

  it("passes the requested channel into the spawned updater config", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    const packageDir = nodePath.join(stateDir, "package");
    const detectedChannels: NodeConfig["updateChannel"][] = [];
    const spawnedCalls: Array<{
      config: NodeConfig;
      options: { updateChannel?: NodeConfig["updateChannel"] | null };
    }> = [];
    let exitCalls = 0;

    const server = await startServer(config, undefined, {
      detectInstallInfo: async (packageRootOrOptions = {}) => {
        const options =
          typeof packageRootOrOptions === "string"
            ? { packageRoot: packageRootOrOptions }
            : packageRootOrOptions;
        const updateChannel = options.config?.updateChannel ?? "stable";
        detectedChannels.push(updateChannel);
        return makeInstallInfo(
          options.packageRoot ?? packageDir,
          updateChannel,
        );
      },
      spawnSelfUpdater: async (spawnConfig, options = {}) => {
        spawnedCalls.push({ config: spawnConfig, options });
        return makeUpdateStatus(
          makeInstallInfo(packageDir, spawnConfig.updateChannel),
        );
      },
      exitProcess: (code = 0) => {
        assert.equal(code, 0);
        exitCalls += 1;
        return undefined as never;
      },
    });

    try {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ channel: "bleeding-edge" }),
      });

      assert.equal(res.statusCode, 200);
      assert.deepEqual(res.body, {
        ok: true,
        message: "daemon is updating",
        update: makeUpdateStatus(
          makeInstallInfo(packageDir, "bleeding-edge"),
        ),
      });

      assert.deepEqual(detectedChannels, ["stable", "bleeding-edge"]);
      assert.equal(spawnedCalls.length, 1);
      assert.equal(spawnedCalls[0]?.config.updateChannel, "bleeding-edge");
      assert.deepEqual(spawnedCalls[0]?.options, {
        updateChannel: "bleeding-edge",
      });
      const persisted = JSON.parse(
        await readFile(config.configPath, "utf8"),
      ) as { updateChannel?: string };
      assert.equal(persisted.updateChannel, "bleeding-edge");
      assert.equal(exitCalls, 0);
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });

  it("returns 500 and keeps the daemon running when updater spawn fails", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    const server = await startServer(config, undefined, {
      detectInstallInfo: async (packageRootOrOptions = {}) => {
        const options =
          typeof packageRootOrOptions === "string"
            ? { packageRoot: packageRootOrOptions }
            : packageRootOrOptions;
        return makeInstallInfo(
          options.packageRoot ?? nodePath.join(stateDir, "package"),
          options.config?.updateChannel ?? "stable",
        );
      },
      spawnSelfUpdater: async () => {
        throw new Error("systemd-run failed");
      },
      exitProcess: () => {
        throw new Error("exit should not be called");
      },
    });

    try {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ channel: "bleeding-edge" }),
      });

      assert.equal(res.statusCode, 500);

      const health = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/healthz",
        method: "GET",
      });
      assert.equal(health.statusCode, 200);
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });

  it("returns 409 with the active update ID for concurrent requests", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    const server = await startServer(config, undefined, {
      detectInstallInfo: async () => makeInstallInfo(stateDir),
      spawnSelfUpdater: async () => {
        throw new UpdateAlreadyInProgressError("update-active");
      },
    });

    try {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "Content-Type": "application/json",
        },
        body: "{}",
      });

      assert.equal(res.statusCode, 409);
      assert.deepEqual(res.body, {
        error: "Update update-active is already in progress",
        updateId: "update-active",
      });
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });
});

describe("GET /api/admin/update-status", () => {
  it("returns the latest persistent update operation", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    const info = makeInstallInfo(stateDir, "bleeding-edge");
    const update = makeUpdateStatus(info, "update-status-1");
    const server = await startServer(config, undefined, {
      detectInstallInfo: async () => info,
      readUpdateStatus: async () => update,
    });

    try {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update-status",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });

      assert.equal(res.statusCode, 200);
      assert.deepEqual(res.body, { ok: true, update });
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });
});

describe("POST /api/admin/update-channel", () => {
  it("persists the selected channel and refreshes node install info", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    const server = await startServer(config, undefined, {
      detectInstallInfo: async (packageRootOrOptions = {}) => {
        const options =
          typeof packageRootOrOptions === "string"
            ? { packageRoot: packageRootOrOptions }
            : packageRootOrOptions;
        return makeInstallInfo(
          options.packageRoot ?? nodePath.join(stateDir, "package"),
          options.config?.updateChannel ?? "stable",
        );
      },
    });

    try {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update-channel",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ channel: "bleeding-edge" }),
      });

      assert.equal(res.statusCode, 200);
      assert.equal((res.body as any).ok, true);
      assert.equal((res.body as any).updateChannel, "bleeding-edge");
      assert.equal((res.body as any).updateAvailable, true);
      assert.equal((res.body as any).latestVersion, "0.2.0");
      assert.equal((res.body as any).currentCommitSha, null);
      assert.equal((res.body as any).latestCommitSha, null);

      const persisted = JSON.parse(
        await readFile(config.configPath, "utf8"),
      ) as { updateChannel?: string };
      assert.equal(persisted.updateChannel, "bleeding-edge");

      const node = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });

      assert.equal(node.statusCode, 200);
      assert.equal((node.body as any).updateChannel, "bleeding-edge");
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });
});

describe("POST /api/admin/update-check", () => {
  it("refreshes cached update info on demand", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    let detectCalls = 0;
    const server = await startServer(config, undefined, {
      detectInstallInfo: async (packageRootOrOptions = {}) => {
        detectCalls += 1;
        const options =
          typeof packageRootOrOptions === "string"
            ? { packageRoot: packageRootOrOptions }
            : packageRootOrOptions;
        return {
          ...makeInstallInfo(
            options.packageRoot ?? nodePath.join(stateDir, "package"),
            options.config?.updateChannel ?? "stable",
          ),
          latestVersion: detectCalls === 1 ? "0.2.0" : "0.3.0",
        };
      },
    });

    try {
      const before = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(before.statusCode, 200);
      assert.equal((before.body as any).latestVersion, "0.2.0");

      const refreshed = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update-check",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "Content-Type": "application/json",
        },
        body: "{}",
      });

      assert.equal(refreshed.statusCode, 200);
      assert.equal((refreshed.body as any).ok, true);
      assert.equal((refreshed.body as any).refreshed, true);
      assert.equal((refreshed.body as any).latestVersion, "0.3.0");

      const after = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(after.statusCode, 200);
      assert.equal((after.body as any).latestVersion, "0.3.0");
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });

  it("deduplicates concurrent refreshes", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    let detectCalls = 0;
    let releaseRefresh!: () => void;
    let refreshStarted: (() => void) | null = null;
    const refreshStartedPromise = new Promise<void>((resolve) => {
      refreshStarted = resolve;
    });
    const releaseRefreshPromise = new Promise<void>((resolve) => {
      releaseRefresh = resolve;
    });

    const server = await startServer(config, undefined, {
      detectInstallInfo: async (packageRootOrOptions = {}) => {
        detectCalls += 1;
        if (detectCalls === 2) {
          refreshStarted?.();
          await releaseRefreshPromise;
        }
        const options =
          typeof packageRootOrOptions === "string"
            ? { packageRoot: packageRootOrOptions }
            : packageRootOrOptions;
        return {
          ...makeInstallInfo(
            options.packageRoot ?? nodePath.join(stateDir, "package"),
            options.config?.updateChannel ?? "stable",
          ),
          latestVersion: detectCalls === 1 ? "0.2.0" : "0.3.0",
        };
      },
    });

    try {
      const requestRefresh = () =>
        request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/admin/update-check",
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "Content-Type": "application/json",
          },
          body: "{}",
        });

      const first = requestRefresh();
      const second = requestRefresh();
      await refreshStartedPromise;
      await new Promise((resolve) => setTimeout(resolve, 25));
      releaseRefresh();

      const [firstResult, secondResult] = await Promise.all([first, second]);
      assert.equal(firstResult.statusCode, 200);
      assert.equal(secondResult.statusCode, 200);
      assert.equal((firstResult.body as any).latestVersion, "0.3.0");
      assert.equal((secondResult.body as any).latestVersion, "0.3.0");
      assert.equal(detectCalls, 2);
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });

  it("keeps the last update info when refresh fails", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    let detectCalls = 0;
    const server = await startServer(config, undefined, {
      detectInstallInfo: async (packageRootOrOptions = {}) => {
        detectCalls += 1;
        if (detectCalls > 1) {
          throw new Error("remote unavailable");
        }
        const options =
          typeof packageRootOrOptions === "string"
            ? { packageRoot: packageRootOrOptions }
            : packageRootOrOptions;
        return makeInstallInfo(
          options.packageRoot ?? nodePath.join(stateDir, "package"),
          options.config?.updateChannel ?? "stable",
        );
      },
    });

    try {
      const refreshed = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/update-check",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "Content-Type": "application/json",
        },
        body: "{}",
      });

      assert.equal(refreshed.statusCode, 200);
      assert.equal((refreshed.body as any).ok, false);
      assert.equal((refreshed.body as any).error, "remote unavailable");
      assert.equal((refreshed.body as any).latestVersion, "0.2.0");

      const node = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/node",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(node.statusCode, 200);
      assert.equal((node.body as any).latestVersion, "0.2.0");
    } finally {
      await server.close();
      await rm(stateDir, { recursive: true, force: true });
    }
  });
});

describe("session live rich events", () => {
  it("broadcasts rich envelope events only to the matching session socket", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const primary = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const secondary = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const primaryLive = await openSessionLiveSocket(
        server.port,
        config.token,
        primary.thread.id,
      );
      const secondaryLive = await openSessionLiveSocket(
        server.port,
        config.token,
        secondary.thread.id,
      );
      try {
        await waitFor(
          () => primaryLive.events.find((event) => event.type === "hello"),
          "primary hello",
        );
        await waitFor(
          () => secondaryLive.events.find((event) => event.type === "hello"),
          "secondary hello",
        );

        provider.emit("liveEvent", {
          type: "provider_warning",
          sessionId: nativeSessionId(primary.thread.id),
          level: "warning",
          code: "warn-1",
          message: "Heads up",
          source: "fake/runtime",
        });
        provider.emit("liveEvent", {
          type: "thread_status_changed",
          sessionId: nativeSessionId(primary.thread.id),
          status: "running",
          message: "Working",
        });
        provider.emit("liveEvent", {
          type: "plan_updated",
          sessionId: nativeSessionId(primary.thread.id),
          turnId: "turn-1",
          explanation: "Follow the envelope plan.",
          plan: [
            { step: "Read docs", status: "completed" },
            { step: "Wire the server", status: "in_progress" },
          ],
        });
        provider.emit("liveEvent", {
          type: "reasoning_delta",
          sessionId: nativeSessionId(primary.thread.id),
          turnId: "turn-1",
          itemId: "item-1",
          reasoningId: "reason-1",
          delta: "Thinking...",
          summary: true,
        });
        provider.emit("liveEvent", {
          type: "queue_updated",
          sessionId: nativeSessionId(primary.thread.id),
          steeringCount: 1,
          followUpCount: 2,
          steeringPreview: ["Keep it provider-neutral"],
          followUpPreview: ["Add tests", "Run analyze"],
        });
        provider.emit("liveEvent", {
          type: "auto_retry_updated",
          sessionId: nativeSessionId(primary.thread.id),
          phase: "started",
          attempt: 2,
          maxAttempts: 3,
          delayMs: 2000,
          errorMessage: "Overloaded",
        });

        const richTypes = [
          "provider_warning",
          "thread_status_changed",
          "plan_updated",
          "reasoning_delta",
          "queue_updated",
          "auto_retry_updated",
        ];
        await waitFor(
          () =>
            richTypes.every((type) =>
              primaryLive.events.some((event) => event.type === type),
            )
              ? true
              : null,
          "primary rich live events",
        );

        for (const type of richTypes) {
          assert.equal(
            secondaryLive.events.some((event) => event.type === type),
            false,
            `unexpected ${type} on unrelated session socket`,
          );
        }

        const warning = primaryLive.events.find(
          (event) => event.type === "provider_warning",
        );
        assert.equal(warning?.code, "warn-1");
        const plan = primaryLive.events.find(
          (event) => event.type === "plan_updated",
        );
        assert.equal(plan?.plan?.[1]?.step, "Wire the server");
        const retry = primaryLive.events.find(
          (event) => event.type === "auto_retry_updated",
        );
        assert.equal(retry?.delayMs, 2000);
      } finally {
        await closeSessionLiveSocket(primaryLive.socket);
        await closeSessionLiveSocket(secondaryLive.socket);
      }
    });
  });

  it("includes the latest plan update in log responses and refreshes cache hits", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const created = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const sessionId = created.thread.id;
      const logPath = `/api/sessions/${encodeURIComponent(sessionId)}/log`;

      const initialLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(initialLog.statusCode, 200);
      assert.equal((initialLog.body as any).latestPlanUpdate, null);

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId: nativeSessionId(sessionId),
        turnId: "turn-1",
        explanation: "First plan.",
        plan: [{ step: "Inspect the daemon path", status: "completed" }],
      });

      const firstPlanLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(firstPlanLog.statusCode, 200);
      assert.equal(
        (firstPlanLog.body as any).latestPlanUpdate.explanation,
        "First plan.",
      );
      assert.equal(
        (firstPlanLog.body as any).latestPlanUpdate.plan[0].step,
        "Inspect the daemon path",
      );

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId: nativeSessionId(sessionId),
        turnId: "turn-2",
        explanation: "Second plan.",
        plan: [{ step: "Return the freshest plan", status: "in_progress" }],
      });

      const secondPlanLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(secondPlanLog.statusCode, 200);
      assert.equal(
        (secondPlanLog.body as any).latestPlanUpdate.turnId,
        "turn-2",
      );
      assert.equal(
        (secondPlanLog.body as any).latestPlanUpdate.plan[0].step,
        "Return the freshest plan",
      );
    });
  });

  it("refreshes the latest plan through the snapshot route", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      await runtime.ensure(runtime.defaultProvider);
      const created = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const sessionId = created.thread.id;

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId: nativeSessionId(sessionId),
        turnId: "turn-1",
        explanation: "Catch up on reconnect.",
        plan: [{ step: "Replay the latest plan", status: "in_progress" }],
      });

      const delta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(delta.statusCode, 200);
      assert.equal(
        (delta.body as any).latestPlanUpdate.plan[0].step,
        "Replay the latest plan",
      );
      const replayedSeq = (delta.body as any).latestPlanUpdate.seq as number;
      assert.equal(typeof replayedSeq, "number");

      const upToDate = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(upToDate.statusCode, 200);
      assert.deepEqual((upToDate.body as any).latestPlanUpdate, (delta.body as any).latestPlanUpdate);
    });
  });

  it("replays an empty plan update as a clear signal", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      await runtime.ensure(runtime.defaultProvider);
      const created = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const sessionId = created.thread.id;

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId: nativeSessionId(sessionId),
        turnId: "turn-1",
        explanation: "Create the plan card.",
        plan: [{ step: "Show the plan", status: "in_progress" }],
      });

      const firstDelta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(firstDelta.statusCode, 200);
      assert.equal(
        (firstDelta.body as any).latestPlanUpdate.plan[0].step,
        "Show the plan",
      );

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId: nativeSessionId(sessionId),
        turnId: "turn-1",
        plan: [],
      });

      const clearDelta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(clearDelta.statusCode, 200);
      assert.deepEqual((clearDelta.body as any).latestPlanUpdate.plan, []);

      const log = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(log.statusCode, 200);
      assert.deepEqual((log.body as any).latestPlanUpdate.plan, []);
    });
  });

  it("refreshes updated activities even when transcript order is unchanged", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const provider = new ActivityReplayFixtureProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const logPath = `/api/sessions/${encodeURIComponent(provider.sessionId)}/log`;
      const eventsPath = `/api/sessions/${encodeURIComponent(provider.sessionId)}/log`;

      const initialLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(initialLog.statusCode, 200);
      assert.equal((initialLog.body as any).activities[0].output, "before");

      provider.emit("liveEvent", {
        type: "activity_updated",
        sessionId: nativeSessionId(provider.sessionId),
        turnId: "turn-1",
        activity: {
          id: "cmd-1",
          type: "command",
          turnId: "turn-1",
          status: "completed",
          command: "npm test",
          cwd: "/repo",
          output: "before\nafter",
          exitCode: 0,
          durationMs: 2,
          source: "agent",
          processId: "proc-1",
          commandActions: [],
          terminalStatus: null,
          terminalInput: null,
        },
      });

      const delta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: eventsPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(delta.statusCode, 200);
      assert.equal((delta.body as any).activities.length, 1);
      assert.equal((delta.body as any).activities[0].id, "cmd-1");
      assert.equal((delta.body as any).activities[0].output, "before\nafter");


      const refreshedLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(refreshedLog.statusCode, 200);
      assert.equal((refreshedLog.body as any).activities[0].output, "before\nafter");
    });
  });

  it("releases provider listeners and timers when the server closes", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-close-"));
    const provider = new ActivityReplayFixtureProvider();
    await withServerRuntime(makeConfig(stateDir), makeCustomSingleProviderRuntime(provider), async (server, config) => {
      await request({ hostname: "127.0.0.1", port: server.port, path: `/api/sessions/${provider.sessionId}/log`, headers: { Authorization: `Bearer ${config.token}` } });
      assert.equal(provider.listenerCount("liveEvent"), 1);
      provider.emit("liveEvent", { type: "runtime_updated", sessionId: nativeSessionId(provider.sessionId), runtime: { model: "last model" } });
    });
    assert.equal(provider.listenerCount("liveEvent"), 0);
    assert.equal(provider.listenerCount("stderr"), 0);
  });

  it("snapshots include live replies and updates arriving during a provider read", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-snapshot-race-"));
    const provider = new ActivityReplayFixtureProvider();
    await withServerRuntime(makeConfig(stateDir), makeCustomSingleProviderRuntime(provider), async (server, config) => {
      let enter!: () => void;
      let release!: () => void;
      const entered = new Promise<void>((resolve) => { enter = resolve; });
      const reading = new Promise<void>((resolve) => { release = resolve; });
      const readLog = provider.readSessionLog.bind(provider);
      const readSnapshot = provider.readSessionSnapshot.bind(provider);
      let block = true;
      provider.readSessionSnapshot = async (id, options) => {
        const snapshot = await readSnapshot(id, options);
        if (block) { block = false; enter(); await reading; }
        return snapshot;
      };
      const snapshot = request({
        hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${provider.sessionId}/log?messageLimit=13`,
        headers: { Authorization: `Bearer ${config.token}` },
      });
      await entered;
      provider.emit("liveEvent", { type: "turn_started", sessionId: nativeSessionId(provider.sessionId), turnId: "turn-live" });
      provider.emit("liveEvent", { type: "assistant_delta", sessionId: nativeSessionId(provider.sessionId), delta: "Still writing" });
      provider.emit("liveEvent", { type: "reasoning_delta", sessionId: nativeSessionId(provider.sessionId), delta: "Checking", summary: false });
      provider.emit("liveEvent", { type: "runtime_updated", sessionId: nativeSessionId(provider.sessionId), runtime: { model: "live-model" } });
      provider.emit("liveEvent", {
        type: "activity_updated", sessionId: nativeSessionId(provider.sessionId),
        activity: { ...((await readLog({ id: provider.sessionId } as ThreadRecord)).activities[0]), output: "fresh output" },
      });
      provider.emit("liveEvent", { type: "plan_updated", sessionId: nativeSessionId(provider.sessionId), plan: [{ step: "Fresh plan", status: "in_progress" }] });
      release();
      const result = await snapshot;
      assert.equal(result.statusCode, 200);
      const body = result.body as any;
      assert.equal(body.liveAssistantText, "Still writing");
      assert.equal(body.liveAssistantReasoning, "Checking");
      assert.equal(body.session.runtime.model, "live-model");
      assert.equal(body.activities[0].output, "fresh output");
      assert.equal(body.latestPlanUpdate.plan[0].step, "Fresh plan");
      assert.equal(body.revision, 6);
    });
  });

  it("snapshots preserve finished tool output when a turn completes during a provider read", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-snapshot-race-"));
    const provider = new ActivityReplayFixtureProvider();
    await withServerRuntime(makeConfig(stateDir), makeCustomSingleProviderRuntime(provider), async (server, config) => {
      let enter!: () => void;
      let release!: () => void;
      const entered = new Promise<void>((resolve) => { enter = resolve; });
      const reading = new Promise<void>((resolve) => { release = resolve; });
      const readLog = provider.readSessionLog.bind(provider);
      const readSnapshot = provider.readSessionSnapshot.bind(provider);
      let block = true;
      provider.readSessionSnapshot = async (id, options) => {
        const snapshot = await readSnapshot(id, options);
        if (block) { block = false; enter(); await reading; }
        return snapshot;
      };
      const snapshot = request({
        hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${provider.sessionId}/log?messageLimit=13`,
        headers: { Authorization: `Bearer ${config.token}` },
      });
      await entered;
      provider.emit("liveEvent", { type: "turn_started", sessionId: nativeSessionId(provider.sessionId), turnId: "turn-live" });
      provider.emit("liveEvent", { type: "assistant_delta", sessionId: nativeSessionId(provider.sessionId), delta: "Still writing" });
      provider.emit("liveEvent", { type: "reasoning_delta", sessionId: nativeSessionId(provider.sessionId), delta: "Checking", summary: false });
      provider.emit("liveEvent", { type: "runtime_updated", sessionId: nativeSessionId(provider.sessionId), runtime: { model: "live-model" } });
      provider.emit("liveEvent", {
        type: "activity_updated", sessionId: nativeSessionId(provider.sessionId),
        activity: { ...((await readLog({ id: provider.sessionId } as ThreadRecord)).activities[0]), output: "fresh output" },
      });
      provider.emit("liveEvent", { type: "plan_updated", sessionId: nativeSessionId(provider.sessionId), plan: [{ step: "Fresh plan", status: "in_progress" }] });
      provider.emit("liveEvent", { type: "turn_completed", sessionId: nativeSessionId(provider.sessionId), turnId: "turn-live", status: "completed" });
      release();
      const result = await snapshot;
      assert.equal(result.statusCode, 200);
      const body = result.body as any;
      assert.equal(body.liveAssistantText, "");
      assert.equal(body.liveAssistantReasoning, "");
      assert.equal(body.session.runtime.model, "live-model");
      assert.equal(body.activities[0].output, "fresh output");
      assert.equal(body.latestPlanUpdate.plan[0].step, "Fresh plan");
      assert.equal(body.revision, 7);
      assert.equal(body.session.status, "idle");
      const fetchLog = () => request({
        hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${provider.sessionId}/log`,
        headers: { Authorization: `Bearer ${config.token}` },
      });
      assert.equal(((await fetchLog()).body as any).activities[0].output, "fresh output");
      provider.mutatePersistedActivity("fresh output");
      await fetchLog();
      provider.mutatePersistedActivity("updated later on disk");
      assert.equal(((await fetchLog()).body as any).activities[0].output, "updated later on disk");
    });
  });

  it("recovers Pi history through snapshots, including partial file appends and changed git branches", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-pi-snapshot-"));
    const cwd = nodePath.join(stateDir, "repo");
    const agentDir = nodePath.join(stateDir, "pi");
    const sessionDir = nodePath.join(agentDir, "sessions", "fixture");
    await mkdir(cwd);
    await mkdir(sessionDir, { recursive: true });
    const git = (args: string[]) => promisify(execFile)("git", args, { cwd });
    await git(["init", "--initial-branch=before"]);
    const record = (index: number) => JSON.stringify({
      type: "message", id: `m${index}`, parentId: index === 1 ? null : `m${index - 1}`,
      timestamp: new Date(1777629600000 + index * 1000).toISOString(),
      message: { role: index % 2 ? "user" : "assistant", content: [{ type: "text", text: `Message ${index}` }], timestamp: 1777629600000 + index * 1000 },
    });
    const historyPath = nodePath.join(sessionDir, "fixture.jsonl");
    await writeFile(historyPath, JSON.stringify({ type: "session", version: 3, id: "pi-fixture", timestamp: "2026-05-01T10:00:00.000Z", cwd }) + "\n" + record(1) + "\n" + record(2) + "\n");
    const piConfig = { kind: "pi" as const, agentDir, stateDir: nodePath.join(stateDir, "pi-state") };
    const config = { ...makeConfig(stateDir), provider: piConfig, providers: [piConfig], defaultProviderKind: "pi" as const };
    await withServer(config, async (server) => {
      const get = (path: string) => request({ hostname: "127.0.0.1", port: server.port, path, headers: { Authorization: `Bearer ${config.token}` } });
      const first = await get("/api/sessions/pi-fixture/log");
      assert.equal(first.statusCode, 200);
      assert.deepEqual((first.body as any).messages.map((message: any) => message.text), ["Message 1", "Message 2"]);
      const third = record(3);
      const split = Math.floor(third.length / 2);
      await appendFile(historyPath, third.slice(0, split));
      await get("/api/sessions/pi-fixture/log");
      await appendFile(historyPath, third.slice(split) + "\n");
      const simultaneous = await Promise.all(Array.from({ length: 3 }, () => get("/api/sessions/pi-fixture/log")));
      for (const result of simultaneous) {
        assert.equal(result.statusCode, 200);
        assert.deepEqual((result.body as any).messages.map((message: any) => message.text), ["Message 1", "Message 2", "Message 3"]);
      }
      await appendFile(historyPath, Array.from({ length: 210 }, (_, index) => record(index + 4)).join("\n") + "\n");
      const bounded = await get("/api/sessions/pi-fixture/log");
      assert.equal((bounded.body as any).messages.length, 200);
      assert.equal((bounded.body as any).history.totalMessages, 213);
      assert.equal((bounded.body as any).history.isTruncated, true);
      const older = await get("/api/sessions/pi-fixture/log?messageLimit=300");
      assert.equal((older.body as any).messages.length, 213);
      const before = await get("/api/sessions?runtime=none&limit=10");
      assert.equal((before.body as any)[0].gitInfo.branch, "before");
      await git(["symbolic-ref", "HEAD", "refs/heads/after"]);
      const after = await get("/api/sessions?runtime=none&limit=11");
      assert.equal((after.body as any)[0].gitInfo.branch, "after");
      assert.equal((await get("/api/sessions/pi-fixture/events?since=0")).statusCode, 404);
    });
  });

  it("refreshes changed persisted state directly", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const provider = new ActivityReplayFixtureProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const logPath = `/api/sessions/${encodeURIComponent(provider.sessionId)}/log`;

      const initialLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(initialLog.statusCode, 200);
      assert.equal((initialLog.body as any).session.updatedAt, 1000);

      provider.mutatePersistedActivity("after restart");

      const delta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path:
          `/api/sessions/${encodeURIComponent(provider.sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(delta.statusCode, 200);
      assert.equal((delta.body as any).activities[0].output, "after restart");
      assert.equal((delta.body as any).session.updatedAt, 2000);
    });
  });

  it("does not serve a stale full snapshot from the log cache when provider timestamps are coarse", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const provider = new ActivityReplayFixtureProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const logPath = `/api/sessions/${encodeURIComponent(provider.sessionId)}/log`;

      const initialLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(initialLog.statusCode, 200);
      assert.equal((initialLog.body as any).session.updatedAt, 1000);
      assert.equal((initialLog.body as any).activities[0].output, "before");

      provider.mutatePersistedActivityWithoutTimestampChange("same second update");

      const refreshedLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: logPath,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(refreshedLog.statusCode, 200);
      assert.equal((refreshedLog.body as any).session.updatedAt, 1000);
      assert.equal((refreshedLog.body as any).activities[0].output, "same second update");
    });
  });

  it("restores the latest plan after daemon restart", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    const config = makeConfig(stateDir);
    let firstServer: RunningServer | null = null;
    let secondServer: RunningServer | null = null;
    try {
      firstServer = await startServer(config, runtime);
      await runtime.ensure(runtime.defaultProvider);
      const created = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const sessionId = created.thread.id;

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId: nativeSessionId(sessionId),
        turnId: "turn-1",
        explanation: "Persist this plan.",
        plan: [{ step: "Reload after restart", status: "completed" }],
      });

      await firstServer.close();
      firstServer = null;

      secondServer = await startServer(config, makeCustomSingleProviderRuntime(provider));
      const restored = await request({
        hostname: "127.0.0.1",
        port: secondServer.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(restored.statusCode, 200);
      assert.equal(
        (restored.body as any).latestPlanUpdate.explanation,
        "Persist this plan.",
      );
      assert.equal(
        (restored.body as any).latestPlanUpdate.plan[0].step,
        "Reload after restart",
      );
      assert.equal((restored.body as any).latestPlanUpdate.seq, 0);

      const replay = await request({
        hostname: "127.0.0.1",
        port: secondServer.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(replay.statusCode, 200);
      assert.equal((replay.body as any).latestPlanUpdate.seq, 0);

      const live = await openSessionLiveSocket(
        secondServer.port,
        config.token,
        sessionId,
      );
      try {
        const hello = await waitFor(
          () => live.events.find((event) => event.type === "hello"),
          "restart hello after persisted plan restore",
        );
        assert.equal(hello.type, "hello");
      } finally {
        await closeSessionLiveSocket(live.socket);
      }
    } finally {
      if (secondServer) {
        await secondServer.close();
      }
      if (firstServer) {
        await firstServer.close();
      }
      await rm(stateDir, { recursive: true, force: true });
    }
  });

  it("fans out provider warnings without a session id to every open session room", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const primary = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const secondary = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const primaryLive = await openSessionLiveSocket(
        server.port,
        config.token,
        primary.thread.id,
      );
      const secondaryLive = await openSessionLiveSocket(
        server.port,
        config.token,
        secondary.thread.id,
      );
      try {
        await waitFor(
          () => primaryLive.events.find((event) => event.type === "hello"),
          "primary hello",
        );
        await waitFor(
          () => secondaryLive.events.find((event) => event.type === "hello"),
          "secondary hello",
        );

        provider.emit("liveEvent", {
          type: "provider_warning",
          level: "info",
          code: "global-1",
          message: "Global provider warning",
          source: "fake/config",
        });

        const primaryWarning = await waitFor(
          () =>
            primaryLive.events.find(
              (event) =>
                event.type === "provider_warning" && event.code === "global-1",
            ),
          "primary global warning",
        );
        const secondaryWarning = await waitFor(
          () =>
            secondaryLive.events.find(
              (event) =>
                event.type === "provider_warning" && event.code === "global-1",
            ),
          "secondary global warning",
        );

        assert.equal(primaryWarning.sessionId, primary.thread.id);
        assert.equal(secondaryWarning.sessionId, secondary.thread.id);
      } finally {
        await closeSessionLiveSocket(primaryLive.socket);
        await closeSessionLiveSocket(secondaryLive.socket);
      }
    });
  });

  it("ignores unknown provider live events without crashing the session stream", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const primary = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const primaryLive = await openSessionLiveSocket(
        server.port,
        config.token,
        primary.thread.id,
      );
      try {
        await waitFor(
          () => primaryLive.events.find((event) => event.type === "hello"),
          "primary hello",
        );

        provider.emit(
          "liveEvent",
          {
            type: "provider.custom_runtime_thing",
            sessionId: primary.thread.id,
          } as never,
        );
        provider.emit("liveEvent", {
          type: "queue_updated",
          sessionId: nativeSessionId(primary.thread.id),
          steeringCount: 1,
          followUpCount: 0,
          steeringPreview: ["Still alive"],
        });

        const queueEvent = await waitFor(
          () =>
            primaryLive.events.find((event) => event.type === "queue_updated"),
          "queue event after unknown event",
        );
        assert.equal(queueEvent.steeringCount, 1);
      } finally {
        await closeSessionLiveSocket(primaryLive.socket);
      }
    });
  });
});

describe("provider-scoped catalog routes", () => {
  it("uses the default provider when agentProvider is omitted", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const baseRequest = {
        hostname: "127.0.0.1",
        port: server.port,
        headers: { Authorization: "Bearer " + config.token },
      };

      assert.equal(
        (await request({ ...baseRequest, path: "/api/modes", method: "GET" })).statusCode,
        501,
      );
      assert.equal(
        (await request({ ...baseRequest, path: "/api/models", method: "GET" })).statusCode,
        200,
      );
      assert.equal(
        (await request({ ...baseRequest, path: "/api/profiles", method: "GET" })).statusCode,
        200,
      );
      assert.equal(
        (await request({
          ...baseRequest,
          path: "/api/access-modes",
          method: "GET",
        })).statusCode,
        501,
      );
      assert.equal(
        (await request({
          ...baseRequest,
          path: "/api/permission-profiles",
          method: "GET",
        })).statusCode,
        404,
      );
      assert.equal(
        (await request({
          ...baseRequest,
          path: `/api/skills?cwd=${encodeURIComponent("/tmp")}`,
          method: "GET",
        })).statusCode,
        200,
      );
      assert.equal(
        (await request({
          ...baseRequest,
          path: "/api/skills/config/write",
          method: "POST",
          headers: {
            ...baseRequest.headers,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            name: "fake code review",
            enabled: false,
          }),
        })).statusCode,
        200,
      );
    });
  });

  it("rejects unknown catalog providers", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const baseRequest = {
        hostname: "127.0.0.1",
        port: server.port,
        headers: { Authorization: "Bearer " + config.token },
      };

      for (const path of [
        "/api/modes?agentProvider=unknown",
        "/api/models?agentProvider=unknown",
        "/api/profiles?agentProvider=unknown",
        "/api/access-modes?agentProvider=unknown",
        `/api/skills?agentProvider=unknown&cwd=${encodeURIComponent("/tmp")}`,
      ]) {
        const res = await request({ ...baseRequest, path, method: "GET" });
        assert.equal(res.statusCode, 400, path);
        assert.equal((res.body as any).error, "unknown provider");
      }

      const writeRes = await request({
        ...baseRequest,
        path: "/api/skills/config/write",
        method: "POST",
        headers: {
          ...baseRequest.headers,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          agentProvider: "unknown",
          name: "fake code review",
          enabled: false,
        }),
      });
      assert.equal(writeRes.statusCode, 400);
      assert.equal((writeRes.body as any).error, "unknown provider");
    });
  });

  it("does not fall through when the selected provider lacks catalog capabilities", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(
      makeConfig(stateDir, { capabilityProfile: "chat-only" }),
      async (server, config) => {
        const baseRequest = {
          hostname: "127.0.0.1",
          port: server.port,
          headers: { Authorization: "Bearer " + config.token },
        };

        for (const path of [
          "/api/modes",
          "/api/models",
          "/api/profiles",
          "/api/access-modes",
          `/api/skills?cwd=${encodeURIComponent("/tmp")}`,
        ]) {
          const res = await request({ ...baseRequest, path, method: "GET" });
          assert.equal(res.statusCode, 501, path);
        }

        const writeRes = await request({
          ...baseRequest,
          path: "/api/skills/config/write",
          method: "POST",
          headers: {
            ...baseRequest.headers,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            name: "fake code review",
            enabled: false,
          }),
        });
        assert.equal(writeRes.statusCode, 501);
      },
    );
  });

  it("routes session configuration to the owning provider and preserves failures", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    const calls: unknown[] = [];
    const provider = Object.assign(new FakeAgentProvider({ seedSessions: false }), {
      async setSessionConfiguration(id: string, optionId: string, value: string | boolean) {
        calls.push([id, optionId, value]);
        if (optionId === "missing") throw new AgentProviderRequestError("Option is no longer available", 409);
        return { configurationOptions: [{ id: optionId, label: "Setting", value }] };
      },
    });
    provider.capabilities.configuration.sessionOptions = true;
    const created = await provider.createSession({ cwd: stateDir, input: [], overrides: EMPTY_OVERRIDES });
    await withServerRuntime(config, makeCustomSingleProviderRuntime(provider), async (server) => {
      const requestOptions = { hostname: "127.0.0.1", port: server.port,
        path: `/api/sessions/${wrapProviderScopedId("fake", created.thread.id)}/configuration`,
        headers: { Authorization: "Bearer " + config.token, "Content-Type": "application/json" } };
      assert.equal((await request({ ...requestOptions, method: "GET" })).statusCode, 200);
      for (const value of [false, "choice"]) {
        const response = await request({ ...requestOptions, method: "POST", body: JSON.stringify({ optionId: "setting", value }) });
        assert.equal(response.statusCode, 200);
        assert.deepEqual(calls.at(-1), [created.thread.id, "setting", value]);
        assert.deepEqual(response.body, { runtime: { configurationOptions: [{ id: "setting", label: "Setting", value }] } });
      }
      const malformed = await request({ ...requestOptions, method: "POST", body: JSON.stringify({ optionId: "setting", value: 3 }) });
      assert.equal(malformed.statusCode, 400);
      assert.equal(calls.length, 2);
      const rejected = await request({ ...requestOptions, method: "POST", body: JSON.stringify({ optionId: "missing", value: true }) });
      assert.equal(rejected.statusCode, 409);
      assert.deepEqual(rejected.body, { error: "Option is no longer available" });
      provider.capabilities.configuration.sessionOptions = false;
      assert.equal((await request({ ...requestOptions, method: "POST", body: JSON.stringify({ optionId: "setting", value: true }) })).statusCode, 501);
      assert.equal(calls.length, 3);
    });
  });

  it("returns provider-defined mode catalogs when the provider exposes them", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    await withServerRuntime(
      config,
      makeCustomSingleProviderRuntime(new ModeCatalogOnlyProvider()),
      async (server, runtimeConfig) => {
        const res = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/modes?cwd=${encodeURIComponent("/repo/app")}`,
          method: "GET",
          headers: { Authorization: "Bearer " + runtimeConfig.token },
        });
        assert.equal(res.statusCode, 200);
        assert.deepEqual(res.body, {
          defaultMode: null,
          modes: [
            { id: "build", label: "Build" },
            { id: "review", label: "Review" },
          ],
        });
      },
    );
  });

  it("returns provider-owned access modes without exposing provider internals", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const config = makeConfig(stateDir);
    const provider = new AccessModeCatalogOnlyProvider();
    await withServerRuntime(
      config,
      makeCustomSingleProviderRuntime(provider),
      async (server, runtimeConfig) => {
        const res = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/access-modes?cwd=${encodeURIComponent("/repo/app")}`,
          method: "GET",
          headers: { Authorization: "Bearer " + runtimeConfig.token },
        });
        assert.equal(res.statusCode, 200);
        assert.equal(provider.requestedCwd, "/repo/app");
        assert.deepEqual(res.body, {
          strategy: "modes",
          defaultMode: "guarded",
          modes: [
            {
              id: "guarded",
              label: "Guarded",
              description: "Ask before sensitive actions.",
              icon: "prompt",
              tone: "default",
              enabled: true,
              disabledReason: null,
              confirmation: null,
            },
          ],
        });
      },
    );
  });
});


describe("GET /api/sessions/:sessionId/status", () => {
  async function createRestartableSession(
    server: RunningServer,
    config: NodeConfig,
  ): Promise<string> {
    const createRes = await request({
      hostname: "127.0.0.1",
      port: server.port,
      path: "/api/sessions/create",
      method: "POST",
      headers: {
        Authorization: "Bearer " + config.token,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        cwd: "/tmp/restart-test",
        input: [{ type: "text", text: "start", text_elements: [] }],
      }),
    });
    assert.equal(createRes.statusCode, 201);
    return (createRes.body as any).session.id as string;
  }

  async function resumeRestartableSession(
    server: RunningServer,
    config: NodeConfig,
  ): Promise<void> {
    const respondRes = await request({
      hostname: "127.0.0.1",
      port: server.port,
      path: "/api/actions/fake-restart-action/respond",
      method: "POST",
      headers: {
        Authorization: "Bearer " + config.token,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        answer: "yes",
        wasFreeform: true,
      }),
    });
    assert.equal(respondRes.statusCode, 200);
  }

  async function readStatus(
    server: RunningServer,
    config: NodeConfig,
    sessionId: string,
  ): Promise<any> {
    const statusRes = await request({
      hostname: "127.0.0.1",
      port: server.port,
      path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
      method: "GET",
      headers: { Authorization: "Bearer " + config.token },
    });
    assert.equal(statusRes.statusCode, 200);
    return statusRes.body as any;
  }

  async function readRecentStatus(
    server: RunningServer,
    config: NodeConfig,
    sessionId: string,
  ): Promise<string | undefined> {
    const sessionsRes = await request({
      hostname: "127.0.0.1",
      port: server.port,
      path: "/api/sessions?limit=10",
      method: "GET",
      headers: { Authorization: "Bearer " + config.token },
    });
    assert.equal(sessionsRes.statusCode, 200);
    return (sessionsRes.body as any[]).find((item) => item.id === sessionId)?.status;
  }


  it("reports running for inProgress turns", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const createRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: { Authorization: "Bearer " + config.token, "Content-Type": "application/json" },
        body: JSON.stringify({ cwd: "/tmp", input: [{ type: "text", text: "hello" }] }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id;

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${sessionId}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "running");
      assert.equal((statusRes.body as any).isRunning, true);
      assert.ok((statusRes.body as any).activeTurnId);
    });
  });


  it("surfaces live waiting status in both /status and recent session rows", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const session = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const originalSnapshot = provider.readSessionSnapshot.bind(provider);
      provider.readSessionSnapshot = async (id, options) => {
        const snapshot = await originalSnapshot(id, options);
        return { ...snapshot, busy: true, thread: { ...snapshot.thread, status: { type: "waiting_for_approval" } } };
      };
      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId: nativeSessionId(session.thread.id),
        status: "waiting_for_approval",
        pendingActionKind: "permissions",
      });

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(session.thread.id)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "waiting_for_approval");
      assert.equal((statusRes.body as any).isRunning, true);

      const sessionsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions?limit=10",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(sessionsRes.statusCode, 200);
      const listed = (sessionsRes.body as any[]).find(
        (item) => item.id === wrapProviderScopedId("fake", session.thread.id),
      );
      assert.ok(listed);
      assert.equal(listed.status, "waiting_for_approval");
    });
  });

  it("keeps child sessions out of recents and exposes them under their parent", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new SearchFixtureProvider([
      {
        thread: {
          id: "thread-child",
          name: "Delegated explorer",
          preview: "Delegated explorer",
          createdAt: 1,
          updatedAt: 2,
          cwd: "/repo",
          source: {
            subAgent: {
              thread_spawn: {
                parent_thread_id: "thread-parent",
                agent_role: "explorer",
                agent_nickname: "scout",
                depth: 1,
              },
            },
          },
          path: null,
          status: { type: "idle" },
          subAgent: {
            parentSessionId: "thread-parent",
            sourceKind: "thread_spawn",
            agentRole: "explorer",
            agentNickname: "scout",
            depth: 1,
          },
        },
        archived: false,
        searchText: "delegated explorer",
      },
    ]);
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions?limit=10",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(sessionsRes.statusCode, 200);
      const listed = (sessionsRes.body as any[]).find(
        (item) => item.id === wrapProviderScopedId("fake", "thread-child"),
      );
      assert.equal(listed, undefined);

      const runsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/thread-parent/agent-runs",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(runsRes.statusCode, 200);
      assert.deepEqual(runsRes.body, [{
        id: wrapProviderScopedId("fake", "thread-child"),
        parentSessionId: "thread-parent",
        title: "Delegated explorer",
        preview: "Delegated explorer",
        cwd: "/repo",
        createdAt: 1000,
        updatedAt: 2000,
        provider: "fake",
        providerId: "fake",
        status: "idle",
        agentName: null,
        agentDisplayName: null,
        agentRole: "explorer",
        agentNickname: "scout",
        depth: 1,
      }]);
    });
  });


  it("preserves provider waiting status while an active turn is tracked", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionId = await createRestartableSession(server, config);
      await resumeRestartableSession(server, config);

      const originalSnapshot = provider.readSessionSnapshot.bind(provider);
      provider.readSessionSnapshot = async (id, options) => {
        const snapshot = await originalSnapshot(id, options);
        return { ...snapshot, busy: true, activeTurnId: snapshot.activeTurnId,
          thread: { ...snapshot.thread, status: { type: "waiting_for_input" } } };
      };
      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId: nativeSessionId(sessionId),
        status: "waiting_for_input",
      });

      const status = await readStatus(server, config, sessionId);
      assert.equal(status.status, "waiting_for_input");
      assert.equal(status.isRunning, true);
      assert.equal(await readRecentStatus(server, config, sessionId), "waiting_for_input");
    });
  });

  it("surfaces terminal live status instead of masking it with an active turn", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionId = await createRestartableSession(server, config);
      await resumeRestartableSession(server, config);

      const originalSnapshot = provider.readSessionSnapshot.bind(provider);
      provider.readSessionSnapshot = async (id, options) => {
        const snapshot = await originalSnapshot(id, options);
        return { ...snapshot, busy: false, activeTurnId: null,
          thread: { ...snapshot.thread, status: { type: "errored" } } };
      };
      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId: nativeSessionId(sessionId),
        status: "errored",
      });

      const status = await readStatus(server, config, sessionId);
      assert.equal(status.status, "errored");
      assert.equal(status.isRunning, false);
      assert.equal(status.activeTurnId, null);
      assert.equal(await readRecentStatus(server, config, sessionId), "errored");
    });
  });


  it("reconciles recent rows from per-session status reads", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const { runtime, provider } = makeSingleProviderRuntime({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: stateDir,
    });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const created = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const listedThread = {
        ...created.thread,
        status: { type: "idle" },
      } as ThreadRecord;
      const readThread = {
        ...created.thread,
        status: { type: "notLoaded" },
      } as ThreadRecord;
      provider.listSessionThreads = async () => [listedThread];
      provider.readSessionThread = async () => readThread;
      const originalSnapshot = provider.readSessionSnapshot.bind(provider);
      provider.readSessionSnapshot = async (id, options) => ({ ...await originalSnapshot(id, options), thread: readThread });

      const initialSessionsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions?limit=10",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(initialSessionsRes.statusCode, 200);
      assert.equal((initialSessionsRes.body as any[])[0]?.status, "idle");

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(created.thread.id)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "closed");

      const reconciledSessionsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions?limit=10",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(reconciledSessionsRes.statusCode, 200);
      assert.equal((reconciledSessionsRes.body as any[])[0]?.status, "closed");
    });
  });

  it("does not resurrect already-completed turns after create or input returns", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new ImmediateCompletionProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const createRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd: "/tmp/immediate-completion-test",
          input: [{ type: "text", text: "finish immediately", text_elements: [] }],
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal((createRes.body as any).session.status, "idle");
      assert.equal((createRes.body as any).activeTurnId, null);

      const createStatus = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(createStatus.statusCode, 200);
      assert.equal((createStatus.body as any).status, "idle");
      assert.equal((createStatus.body as any).isRunning, false);
      assert.equal((createStatus.body as any).activeTurnId, null);

      const inputRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          input: [{ type: "text", text: "finish immediately again", text_elements: [] }],
        }),
      });
      assert.equal(inputRes.statusCode, 200);
      assert.equal((inputRes.body as any).turnId, "fake-immediate-submit-turn-2");

      const inputStatus = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(inputStatus.statusCode, 200);
      assert.equal((inputStatus.body as any).status, "idle");
      assert.equal((inputStatus.body as any).isRunning, false);
      assert.equal((inputStatus.body as any).activeTurnId, null);
    });
  });


  it("clears synthetic waiting status after an action response resumes the turn", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const createRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/create",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          cwd: "/tmp/restart-test",
          input: [{ type: "text", text: "start", text_elements: [] }],
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId: nativeSessionId(sessionId),
        status: "waiting_for_approval",
        pendingActionKind: "user_input",
      });

      const waitingStatus = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(waitingStatus.statusCode, 200);
      assert.equal((waitingStatus.body as any).status, "waiting_for_approval");

      const respondRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/actions/fake-restart-action/respond",
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          answer: "yes",
          wasFreeform: true,
        }),
      });
      assert.equal(respondRes.statusCode, 200);

      const resumedStatus = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(resumedStatus.statusCode, 200);
      assert.equal((resumedStatus.body as any).status, "running");
      assert.equal((resumedStatus.body as any).isRunning, true);
      assert.equal((resumedStatus.body as any).pendingAction, null);
    });
  });

  it("keeps recent session live rows aligned when action state changes without provider status events", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const recentLive = await openRecentSessionsLiveSocket(
        server.port,
        config.token,
      );
      try {
        await waitFor(
          () => recentLive.events.find((event) => event.type === "snapshot"),
          "recent session live snapshot",
        );

        const createRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/sessions/create",
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            cwd: "/tmp/restart-test",
            input: [{ type: "text", text: "start", text_elements: [] }],
          }),
        });
        assert.equal(createRes.statusCode, 201);
        const sessionId = (createRes.body as any).session.id as string;

        const waitingUpsert = await waitFor(
          () =>
            recentLive.events.find(
              (event) =>
                event.type === "upsert" &&
                event.session?.id === sessionId &&
                event.session?.status === "waiting_for_approval",
            ),
          "recent waiting approval upsert",
        );
        assert.equal(waitingUpsert.session.status, "waiting_for_approval");

        const respondRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/actions/fake-restart-action/respond",
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            answer: "yes",
            wasFreeform: true,
          }),
        });
        assert.equal(respondRes.statusCode, 200);

        const runningUpsert = await waitFor(
          () =>
            recentLive.events.find(
              (event) =>
                event.type === "upsert" &&
                event.session?.id === sessionId &&
                event.session?.status === "running" &&
                recentLive.events.indexOf(event) >
                  recentLive.events.indexOf(waitingUpsert),
            ),
          "recent running upsert after action response",
        );
        assert.equal(runningUpsert.session.status, "running");
      } finally {
        await closeSessionLiveSocket(recentLive.socket);
      }
    });
  });

  it("keeps recent session live upserts aligned with snapshot freshness", async () => {
    const stateDir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-server-recent-upsert-test-"),
    );
    const provider = new SplitFreshnessRecentProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const recentLive = await openRecentSessionsLiveSocket(
        server.port,
        config.token,
      );
      try {
        const snapshot = await waitFor(
          () => recentLive.events.find((event) => event.type === "snapshot"),
          "recent session live snapshot",
        );
        const snapshotSession = (snapshot.sessions as Array<any>).find(
          (session) => session.id === wrapProviderScopedId("fake", provider.sessionId),
        );
        assert.equal(snapshotSession?.updatedAt, provider.freshUpdatedAt);

        provider.emit("liveEvent", {
          type: "thread_status_changed",
          sessionId: nativeSessionId(provider.sessionId),
          status: "running",
        });

        const upsert = await waitFor(
          () =>
            recentLive.events.find(
              (event) =>
                event.type === "upsert" &&
                event.session?.id === wrapProviderScopedId("fake", provider.sessionId),
            ),
          "recent upsert after status change",
        );
        assert.equal(upsert.session?.updatedAt, provider.freshUpdatedAt);
        assert.equal(upsert.session?.status, "running");
      } finally {
        await closeSessionLiveSocket(recentLive.socket);
      }
    });
  });

  it("discards a recent-session read invalidated while the native list was pending", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-recent-boundary-"));
    const { runtime, provider } = makeSingleProviderRuntime({ latencyMs: 0, seedSessions: false, workspaceRoot: stateDir });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const session = await provider.createSession({ cwd: stateDir, input: [], overrides: EMPTY_OVERRIDES });
      const original = provider.listSessionThreads.bind(provider);
      let started!: () => void;
      let release!: () => void;
      let reads = 0;
      const reading = new Promise<void>((resolve) => { started = resolve; });
      const blocked = new Promise<void>((resolve) => { release = resolve; });
      provider.listSessionThreads = async (options) => {
        const threads = await original(options);
        if (options.limit === 10 && ++reads === 1) { started(); await blocked; }
        return threads;
      };
      const result = request({ hostname: "127.0.0.1", port: server.port, path: "/api/sessions?limit=10",
        headers: { Authorization: "Bearer " + config.token } });
      try {
        await reading;
        await provider.setSessionName(session.thread.id, "Fresh title");
        provider.emit("liveEvent", { type: "thread_status_changed", sessionId: nativeSessionId(session.thread.id), status: "idle" });
        release();
        const response = await result;
        assert.equal(response.statusCode, 200);
        assert.equal((response.body as Array<{ title: string }>)[0]?.title, "Fresh title");
        assert.equal(reads, 2);
      } finally { release(); await result; }
    });
  });

  it("keeps rename live upserts aligned with canonical recent session summaries", async () => {
    const stateDir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-server-recent-rename-test-"),
    );
    const { runtime, provider } = makeSingleProviderRuntime({ latencyMs: 0, seedSessions: false, workspaceRoot: stateDir });
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const recentLive = await openRecentSessionsLiveSocket(
        server.port,
        config.token,
      );
      try {
        await waitFor(
          () => recentLive.events.find((event) => event.type === "snapshot"),
          "recent session live snapshot",
        );

        const completed = new Promise<void>((resolve) => {
          const onEvent = (event: import("./agent-provider.js").AgentProviderLiveEvent) => {
            if (event.type === "turn_completed") { provider.off("liveEvent", onEvent); resolve(); }
          };
          provider.on("liveEvent", onEvent);
        });
        const createRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/sessions/create",
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            cwd: "/tmp/recent-rename-test",
            input: [{ type: "text", text: "rename this recent session", text_elements: [] }],
          }),
        });
        assert.equal(createRes.statusCode, 201);
        const sessionId = (createRes.body as any).session.id as string;

        const createdUpsert = await waitFor(
          () =>
            recentLive.events.find(
              (event) =>
                event.type === "upsert" &&
                event.session?.id === sessionId,
            ),
          "recent create upsert",
        );
        assert.ok(createdUpsert.session?.runtime);

        await completed;

        const renameRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${encodeURIComponent(sessionId)}/name`,
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "content-type": "application/json",
          },
          body: JSON.stringify({
            name: "Renamed recent session",
          }),
        });
        assert.equal(renameRes.statusCode, 200);

        const renamedUpsert = await waitFor(
          () =>
            recentLive.events.find(
              (event) =>
                event.type === "upsert" &&
                event.session?.id === sessionId &&
                event.session?.title === "Renamed recent session" &&
                recentLive.events.indexOf(event) >
                  recentLive.events.indexOf(createdUpsert),
            ),
          "recent rename upsert",
        );

        const sessionsRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/sessions?limit=10",
          method: "GET",
          headers: {
            Authorization: "Bearer " + config.token,
          },
        });
        assert.equal(sessionsRes.statusCode, 200);
        const canonical = (sessionsRes.body as Array<any>).find(
          (session) => session.id === sessionId,
        );
        assert.ok(canonical);
        assert.deepEqual(renamedUpsert.session, canonical);
      } finally {
        await closeSessionLiveSocket(recentLive.socket);
      }
    });
  });
});

describe("session-scoped filesystem routes", () => {
  it("resolves namespaced multi-provider session workspaces", async () => {
    const stateDir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-server-fs-multi-test-"),
    );
    const runtime = makeMultiProviderRuntime(
      { seedSessions: true, workspaceRoot: stateDir, latencyMs: 0 },
      { seedSessions: true, workspaceRoot: stateDir, latencyMs: 0 },
    );
    await withServerRuntime(
      makeConfig(stateDir),
      runtime,
      async (server, config) => {
        const baseRequest = {
          hostname: "127.0.0.1",
          port: server.port,
          headers: { Authorization: "Bearer " + config.token },
        };
        const sessionsResponse = await request({
          ...baseRequest,
          path: "/api/sessions?limit=20",
          method: "GET",
        });
        assert.equal(sessionsResponse.statusCode, 200);
        const sessions = sessionsResponse.body as Array<{
          id: string;
          cwd: string;
        }>;
        const secondarySession = sessions.find((session) =>
          session.id.startsWith("codex:"),
        );
        assert.ok(secondarySession, "expected a namespaced secondary session");

        const listingResponse = await request({
          ...baseRequest,
          path:
            `/api/fs/list?path=${encodeURIComponent(secondarySession.cwd)}` +
            `&sessionId=${encodeURIComponent(secondarySession.id)}`,
          method: "GET",
        });

        assert.equal(listingResponse.statusCode, 200);
        assert.equal(
          (listingResponse.body as { path: string }).path,
          await realpath(secondarySession.cwd),
        );
      },
    );
  });
});

describe("GET /api/sessions/search", () => {
  it("returns created sessions by keyword", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-search-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const baseRequest = {
        hostname: "127.0.0.1",
        port: server.port,
        headers: { Authorization: "Bearer " + config.token },
      };

      const createRes = await request({
        ...baseRequest,
        path: "/api/sessions/create",
        method: "POST",
        headers: { ...baseRequest.headers, "Content-Type": "application/json" },
        body: JSON.stringify({ cwd: "/tmp", input: [{ type: "text", text: "nginx configuration help" }] }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id;

      // Wait for background turn completion and indexing
      await new Promise((r) => setTimeout(r, 150));

      const searchRes = await request({
        ...baseRequest,
        path: `/api/sessions/search?q=${encodeURIComponent("nginx")}`,
        method: "GET",
      });
      assert.equal(searchRes.statusCode, 200);
      const results = searchRes.body as any[];
      assert.ok(results.length >= 1, "expected at least one search result");
      assert.ok(results.some((s) => s.id === sessionId), "expected created session in results");
    });
  });

  it("rejects padded one-character queries without filters", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-search-short-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const searchRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        headers: { Authorization: "Bearer " + config.token },
        path: `/api/sessions/search?q=${encodeURIComponent(" n ")}`,
        method: "GET",
      });
      assert.equal(searchRes.statusCode, 400);
      assert.deepEqual(searchRes.body, { error: "Query must be at least 2 characters" });
    });
  });

  it("returns namespaced IDs in multi-provider mode", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-search-multi-test-"));
    const runtime = makeMultiProviderRuntime(
      { seedSessions: true, workspaceRoot: stateDir, latencyMs: 0 },
      { seedSessions: true, workspaceRoot: stateDir, latencyMs: 0 },
    );
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const baseRequest = {
        hostname: "127.0.0.1",
        port: server.port,
        headers: { Authorization: "Bearer " + config.token },
      };

      // Wait for background catch-up and indexing
      await new Promise((r) => setTimeout(r, 300));

      const searchRes = await request({
        ...baseRequest,
        path: `/api/sessions/search?q=${encodeURIComponent("walkthrough")}`,
        method: "GET",
      });
      assert.equal(searchRes.statusCode, 200);
      const results = searchRes.body as any[];
      assert.equal(results.length, 2);
      assert.ok(results.some((session) => String(session.id).startsWith("fake:")));
      assert.ok(results.some((session) => String(session.id).startsWith("codex:")));
      for (const session of results) {
        assert.ok(session.id.includes(":"), `expected namespaced ID: ${session.id}`);
      }
    });
  });

  it("hides archived sessions from search", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-search-archive-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const baseRequest = {
        hostname: "127.0.0.1",
        port: server.port,
        headers: { Authorization: "Bearer " + config.token },
      };

      const createRes = await request({
        ...baseRequest,
        path: "/api/sessions/create",
        method: "POST",
        headers: { ...baseRequest.headers, "Content-Type": "application/json" },
        body: JSON.stringify({ cwd: "/tmp", input: [{ type: "text", text: "archive search test" }] }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id;

      // Wait for turn completion and indexing
      await new Promise((r) => setTimeout(r, 150));

      let searchRes = await request({
        ...baseRequest,
        path: `/api/sessions/search?q=${encodeURIComponent("archive search")}`,
        method: "GET",
      });
      assert.equal(searchRes.statusCode, 200);
      let results = searchRes.body as any[];
      assert.ok(results.some((s) => s.id === sessionId), "expected session before archive");

      const archiveRes = await request({
        ...baseRequest,
        path: `/api/sessions/${sessionId}/archive`,
        method: "POST",
      });
      assert.equal(archiveRes.statusCode, 200);

      // Wait for removal to propagate
      await new Promise((r) => setTimeout(r, 150));

      searchRes = await request({
        ...baseRequest,
        path: `/api/sessions/search?q=${encodeURIComponent("archive search")}`,
        method: "GET",
      });
      assert.equal(searchRes.statusCode, 200);
      results = searchRes.body as any[];
      assert.ok(!results.some((s) => s.id === sessionId), "expected session hidden after archive");
    });
  });

  it("returns archived provider sessions from search backfill when requested", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-search-startup-archive-test-"));
    const provider = new SearchFixtureProvider([
      {
        thread: makeSearchFixtureThread(
          "fixture-active",
          secondsForIso("2026-01-02T11:45:00.000Z"),
          "Active fixture session",
        ),
        archived: false,
        searchText: "shared fixture search active",
      },
      {
        thread: makeSearchFixtureThread(
          "fixture-archived",
          secondsForIso("2026-01-02T12:00:00.000Z"),
          "Archived fixture session",
        ),
        archived: true,
        searchText: "shared fixture search archived",
      },
    ]);
    await withServerRuntime(
      makeConfig(stateDir),
      makeCustomSingleProviderRuntime(provider),
      async (server, config) => {
        await new Promise((r) => setTimeout(r, 300));

        const searchRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          headers: { Authorization: "Bearer " + config.token },
          path:
            `/api/sessions/search?q=${encodeURIComponent("shared fixture search")}` +
            "&archived=true",
          method: "GET",
        });
        assert.equal(searchRes.statusCode, 200);
        const results = searchRes.body as any[];
        assert.ok(
          results.some((session) => session.id === wrapProviderScopedId("fake", "fixture-archived")),
          "expected archived session from search backfill in archived search",
        );
        assert.ok(
          !results.some((session) => session.id === wrapProviderScopedId("fake", "fixture-active")),
          "expected active session excluded from archived-only search",
        );
      },
    );
  });

  it("applies updatedAfter filters to provider-backed search results using millisecond timestamps", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-search-date-filter-test-"));
    const updatedAtSeconds = secondsForIso("2026-01-02T12:00:00.000Z");
    const provider = new SearchFixtureProvider([
      {
        thread: makeSearchFixtureThread(
          "fixture-filter",
          updatedAtSeconds,
          "Filter fixture session",
        ),
        archived: false,
        searchText: "date filter fixture session",
      },
    ]);
    await withServerRuntime(
      makeConfig(stateDir),
      makeCustomSingleProviderRuntime(provider),
      async (server, config) => {
        await new Promise((r) => setTimeout(r, 300));

        const includeRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          headers: { Authorization: "Bearer " + config.token },
          path:
            `/api/sessions/search?q=${encodeURIComponent("date filter fixture")}` +
            `&updatedAfter=${encodeURIComponent("2026-01-02T11:59:00.000Z")}`,
          method: "GET",
        });
        assert.equal(includeRes.statusCode, 200);
        const included = includeRes.body as any[];
        assert.ok(
          included.some((session) => session.id === wrapProviderScopedId("fake", "fixture-filter")),
          "expected session newer than updatedAfter filter",
        );

        let nativeReads = 0;
        provider.readSessionThread = async () => { nativeReads += 1; throw new Error("Native reads unavailable"); };
        provider.readSessionSnapshot = async () => { nativeReads += 1; throw new Error("Native snapshots unavailable"); };
        const cached = await request({ hostname: "127.0.0.1", port: server.port,
          headers: { Authorization: "Bearer " + config.token },
          path: `/api/sessions/search?q=${encodeURIComponent("date filter fixture")}&providerId=fake`, method: "GET" });
        assert.equal(cached.statusCode, 200);
        assert.equal((cached.body as SessionSummary[])[0]?.id, wrapProviderScopedId("fake", "fixture-filter"));
        assert.equal(nativeReads, 0, "search results must use the indexed summary");

        const excludeRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          headers: { Authorization: "Bearer " + config.token },
          path:
            `/api/sessions/search?q=${encodeURIComponent("date filter fixture")}` +
            `&updatedAfter=${encodeURIComponent("2026-01-02T12:01:00.000Z")}`,
          method: "GET",
        });
        assert.equal(excludeRes.statusCode, 200);
        assert.equal(nativeReads, 0);
        const excluded = excludeRes.body as any[];
        assert.ok(
          !excluded.some((session) => session.id === wrapProviderScopedId("fake", "fixture-filter")),
          "expected session older than updatedAfter filter to be excluded",
        );
      },
    );
  });
});

function nativeSessionId(id: string): string { return unwrapProviderScopedId(id)?.rawId ?? id; }

describe("provider session identity", () => {
  it("shares raw aliases with canonical input delivery and keeps owners after default changes", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-session-aliases-"));
    const config = makeConfig(stateDir);
    const writer = new RestartableFakeProvider();
    const reviewer = new RestartableFakeProvider();
    const definition = makeCustomSingleProviderRuntime(writer).defaultProvider;
    const runtimeForDefault = (defaultId: string, includeWriter = true) => new AgentProviderRuntime([
      ...(includeWriter ? [{ ...definition, id: "writer", create: () => writer }] : []),
      { ...definition, id: "reviewer", create: () => reviewer },
    ], defaultId);
    let server = await startServer(config, runtimeForDefault("writer"));
    const headers = { Authorization: `Bearer ${config.token}`, "content-type": "application/json" };
    const call = (path: string, body?: unknown) => request({ hostname: "127.0.0.1", port: server.port, path,
      method: body === undefined ? "GET" : "POST", headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const native = "fake-restart-session";
    const writerId = wrapProviderScopedId("writer", native);
    const reviewerId = wrapProviderScopedId("reviewer", native);
    const input = { clientMessageId: "shared:input", input: [{ type: "text", text: "Keep each input once", text_elements: [] }] };
    try {
      for (const provider of ["writer", "reviewer"]) {
        const created = await call("/api/sessions/create", { provider, cwd: `${stateDir}/${provider}`, input: [] });
        assert.equal(created.statusCode, 201);
        assert.equal((created.body as any).session.id, wrapProviderScopedId(provider, native));
      }
      const first = await call(`/api/sessions/${native}/input`, input);
      const duplicate = await call(`/api/sessions/${encodeURIComponent(writerId)}/input`, input);
      assert.equal(first.statusCode, 200);
      assert.equal(duplicate.statusCode, 200);
      assert.equal((first.body as any).messageId, (duplicate.body as any).messageId);
      assert.equal(writer.submittedInputs, 1);
      assert.equal(reviewer.submittedInputs, 0);
      assert.equal((await call(`/api/sessions/${encodeURIComponent(reviewerId)}/input`, input)).statusCode, 200);
      assert.equal(reviewer.submittedInputs, 1);
      const rawLog = await call(`/api/sessions/${native}/log`);
      assert.equal(rawLog.statusCode, 200);
      assert.equal((rawLog.body as any).session.id, native);
      assert.equal((rawLog.body as any).canonicalSessionId, writerId);
      assert.equal((rawLog.body as any).session.cwd, `${stateDir}/writer`);
      const otherLog = await call(`/api/sessions/${encodeURIComponent(reviewerId)}/log`);
      assert.equal((otherLog.body as any).session.cwd, `${stateDir}/reviewer`);
      const rawSocket = await openSessionLiveSocket(server.port, config.token, native);
      const canonicalSocket = await openSessionLiveSocket(server.port, config.token, writerId);
      try {
        writer.emit("liveEvent", { type: "provider_warning", sessionId: native, level: "warning", code: "alias-check", message: "Same published event" });
        const rawEvent = await waitFor(() => rawSocket.events.find((event) => event.code === "alias-check"), "raw alias event");
        const canonicalEvent = await waitFor(() => canonicalSocket.events.find((event) => event.code === "alias-check"), "canonical event");
        assert.equal(rawEvent.sessionId, native);
        assert.equal(canonicalEvent.sessionId, writerId);
        assert.equal(rawEvent.revision, canonicalEvent.revision);
        assert.equal(rawEvent.seq, canonicalEvent.seq);
      } finally { await closeSessionLiveSocket(rawSocket.socket); await closeSessionLiveSocket(canonicalSocket.socket); }
      await server.close();
      server = await startServer(config, runtimeForDefault("reviewer"));
      const uncertain = await call(`/api/sessions/${native}/input`, input);
      assert.equal(uncertain.statusCode, 409);
      assert.equal(writer.submittedInputs, 1);
      assert.equal(reviewer.submittedInputs, 1);
      const next = await call(`/api/sessions/${native}/input`, { ...input, clientMessageId: "next:input" });
      assert.equal(next.statusCode, 200);
      assert.equal(writer.submittedInputs, 2);
      assert.equal(reviewer.submittedInputs, 1);
      await server.close();
      server = await startServer(config, runtimeForDefault("reviewer", false));
      assert.equal((await call(`/api/sessions/${native}/input`, { ...input, clientMessageId: "removed:owner" })).statusCode, 404);
      assert.equal(reviewer.submittedInputs, 1);
    } finally { await server.close(); await rm(stateDir, { recursive: true, force: true }); }
  });
});
