import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import {
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
import { createServer as createNetServer } from "node:net";

import { WebSocket } from "ws";

import type { InstallInfo } from "./install-info.js";
import { startServer, type RunningServer } from "./server.js";
import type { FakeCapabilityProfile, NodeConfig } from "./types.js";
import {
  FAKE_PROVIDER_CAPABILITIES,
  FakeAgentProvider,
  type FakeAgentProviderOptions,
} from "./fake-provider.js";
import { MultiAgentProvider } from "./multi-provider.js";
import {
  listAgentProviderDefinitionSummaries,
  summarizeAgentProviderConfig,
} from "./provider-registry.js";
import type { AgentProviderRuntime, AgentProviderRuntimeEntry } from "./provider-factory.js";
import type {
  AgentCreateSessionRequest,
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

async function writeLegacyDedupeReceipt(
  stateDir: string,
  key: string,
  signatureHash: string,
  receipt: { mode: string; turnId: string | null; messageId: string },
): Promise<void> {
  await mkdir(stateDir, { recursive: true });
  await writeFile(
    nodePath.join(stateDir, "session-input-dedupe-v1.json"),
    JSON.stringify({
      version: 1,
      entries: [
        {
          key,
          signatureHash,
          createdAt: Date.now(),
          updatedAt: Date.now(),
          receipt,
        },
      ],
    }),
    "utf8",
  );
}

function legacyInputSignature(input: AgentSessionInputItem[]): string {
  return createHash("sha256")
    .update(
      JSON.stringify({
        input,
        overrides: {
          model: null,
          reasoningEffort: null,
          fastMode: null,
          approvalPolicy: null,
          sandboxMode: null,
          networkAccess: null,
        },
      }),
    )
    .digest("hex");
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

  const fakeEntry: AgentProviderRuntimeEntry = {
    kind: "fake",
    provider: defaultProvider,
    configSummary: summarizeAgentProviderConfig(fakeConfig),
    definitionSummary: fakeDef,
  };
  const secondaryEntry: AgentProviderRuntimeEntry = {
    kind: "codex",
    provider: secondaryProvider,
    configSummary: summarizeAgentProviderConfig(codexConfig),
    definitionSummary: codexDef,
  };

  const multiProvider = new MultiAgentProvider(
    [
      { kind: "fake", config: fakeConfig, provider: defaultProvider },
      { kind: "codex", config: codexConfig, provider: secondaryProvider },
    ],
    "fake",
  );

  const providersByKind = new Map<string, AgentProviderRuntimeEntry>([
    ["fake", fakeEntry],
    ["codex", secondaryEntry],
  ]);

  return {
    provider: multiProvider,
    providers: [fakeEntry, secondaryEntry],
    defaultProviderKind: "fake",
    defaultProvider: fakeEntry,
    providerForKind(kind) {
      if (kind === null || kind === undefined) return fakeEntry;
      const trimmed = kind.trim();
      if (!trimmed) return null;
      return providersByKind.get(trimmed) ?? null;
    },
    providerForSessionId(sessionId) {
      try {
        const resolved = multiProvider.resolveSessionProvider(sessionId);
        return providersByKind.get(resolved.kind) ?? null;
      } catch {
        return fakeEntry;
      }
    },
  };
}

function makeCustomSingleProviderRuntime(provider: AgentProvider): AgentProviderRuntime {
  const definitionSummary = listAgentProviderDefinitionSummaries().find(
    (summary) => summary.kind === "fake",
  );
  if (!definitionSummary) {
    throw new Error("Missing fake provider definition");
  }
  const configSummary = summarizeAgentProviderConfig({
    kind: "fake",
    latencyMs: 0,
    seedSessions: false,
    workspaceRoot: null,
    capabilityProfile: "full",
  });
  const entry: AgentProviderRuntimeEntry = {
    kind: "fake",
    provider,
    configSummary,
    definitionSummary,
  };
  return {
    provider,
    providers: [entry],
    defaultProviderKind: "fake",
    defaultProvider: entry,
    providerForKind(kind) {
      return kind == null || kind.trim() === "fake" ? entry : null;
    },
    providerForSessionId() {
      return entry;
    },
  };
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

const RESTARTABLE_FAKE_CAPABILITIES: AgentProviderCapabilities = {
  ...FAKE_PROVIDER_CAPABILITIES,
  lifecycle: {
    ...FAKE_PROVIDER_CAPABILITIES.lifecycle,
    restart: true,
  },
};

class RestartableFakeProvider
  extends EventEmitter
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

  public async close(): Promise<void> {}

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

class ImmediateCompletionProvider extends EventEmitter implements AgentProvider {
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
      sessionId: this.sessionId,
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

class StaleIdleSubmitProvider extends EventEmitter implements AgentProvider {
  public readonly kind = "fake";
  public readonly displayName = "Stale Idle Submit Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;

  private readonly sessionId = "fake-stale-idle-session";
  private cwd = "/tmp";
  private created = false;
  private currentTurnId: string | null = null;
  private submitCount = 0;

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "stale-idle-submit-test";
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.created = true;
    this.cwd = request.cwd;
    return {
      thread: this.buildThread(false),
      activeTurnId: null,
      runtime: null,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    assert.equal(request.sessionId, this.sessionId);
    this.submitCount += 1;
    this.currentTurnId = `fake-stale-submit-turn-${this.submitCount}`;
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

  private buildThread(includeTurns: boolean): ThreadRecord {
    const running = this.currentTurnId !== null;
    return {
      id: this.sessionId,
      name: "Stale idle session",
      preview: "Stale idle session",
      createdAt: 1,
      updatedAt: running ? 2 : 1,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: running
        ? { type: "running", activeFlags: ["inProgress"] }
        : { type: "idle" },
      ...(includeTurns && this.currentTurnId
        ? {
            turns: [
              {
                id: this.currentTurnId,
                status: "in_progress",
                startedAt: 2,
                completedAt: null,
              },
            ],
          }
        : {}),
    };
  }
}

class SplitFreshnessRecentProvider extends EventEmitter implements AgentProvider {
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

class LaggingCreateTurnProvider extends EventEmitter implements AgentProvider {
  public readonly kind = "fake";
  public readonly displayName = "Lagging Create Turn Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;

  private readonly sessionId = "fake-lagging-create-session";
  private readonly createTurnId = "fake-lagging-create-turn";
  private cwd = "/tmp";
  private created = false;

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "lagging-create-turn-test";
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.created = true;
    this.cwd = request.cwd;
    return {
      thread: this.buildThread(false),
      activeTurnId: request.input.length > 0 ? this.createTurnId : null,
      runtime: null,
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

  private buildThread(includeTurns: boolean): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Lagging create turn session",
      preview: "Lagging create turn session",
      createdAt: 1,
      updatedAt: 1,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: { type: "idle" },
      ...(includeTurns ? { turns: [] } : {}),
    };
  }
}

class TransientUnreadableCreateTurnProvider
  extends EventEmitter
  implements AgentProvider
{
  public readonly kind = "fake";
  public readonly displayName = "Transient Unreadable Create Turn Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;

  private readonly sessionId = "fake-transient-create-session";
  private readonly createTurnId = "fake-transient-create-turn";
  private cwd = "/tmp";
  private created = false;

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "transient-unreadable-create-turn-test";
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.created = true;
    this.cwd = request.cwd;
    return {
      thread: this.buildThread(),
      activeTurnId: request.input.length > 0 ? this.createTurnId : null,
      runtime: null,
    };
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    if (!this.created || options.archived) {
      return [];
    }
    return [this.buildThread()].slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    assert.equal(threadId, this.sessionId);
    if (includeTurns) {
      throw new Error(
        `failed to read thread ${threadId}: rollout /tmp/${threadId}.jsonl is empty`,
      );
    }
    return this.buildThread();
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    if (!this.created) {
      return [];
    }
    return [this.buildThread()].slice(0, limit);
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

  private buildThread(): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Transient unreadable create session",
      preview: "Transient unreadable create session",
      createdAt: 1,
      updatedAt: 1,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: { type: "idle" },
    };
  }
}

class RecoveringCreateTurnProvider extends EventEmitter implements AgentProvider {
  public readonly kind = "fake";
  public readonly displayName = "Recovering Create Turn Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;

  private cwd = "/tmp";
  private created = false;
  private recoveredIncludeTurnRead: (() => void | Promise<void>) | null = null;

  public constructor(
    private readonly sessionId: string,
    private readonly createTurnId: string,
    private includeTurnFailuresRemaining: number,
    private readonly recoveredTurnStatus: string | null,
  ) {
    super();
  }

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "recovering-create-turn-test";
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.created = true;
    this.cwd = request.cwd;
    return {
      thread: this.buildThread(false),
      activeTurnId: request.input.length > 0 ? this.createTurnId : null,
      runtime: null,
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
    if (includeTurns && this.includeTurnFailuresRemaining > 0) {
      this.includeTurnFailuresRemaining -= 1;
      throw new Error(
        `failed to read thread ${threadId}: rollout /tmp/${threadId}.jsonl is empty`,
      );
    }
    if (includeTurns && this.recoveredIncludeTurnRead) {
      const recoveredIncludeTurnRead = this.recoveredIncludeTurnRead;
      this.recoveredIncludeTurnRead = null;
      await recoveredIncludeTurnRead();
    }
    return this.buildThread(includeTurns);
  }

  public onRecoveredIncludeTurnRead(
    recoveredIncludeTurnRead: () => void | Promise<void>,
  ): void {
    this.recoveredIncludeTurnRead = recoveredIncludeTurnRead;
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

  private buildThread(includeTurns: boolean): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Recovering create turn session",
      preview: "Recovering create turn session",
      createdAt: 1,
      updatedAt: 1,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: { type: "idle" },
      ...(includeTurns
        ? {
            turns: this.recoveredTurnStatus
              ? [
                  {
                    id: this.createTurnId,
                    status: this.recoveredTurnStatus,
                    startedAt: 1,
                    completedAt: 2,
                  },
                ]
              : [],
          }
        : {}),
    };
  }
}

class TransientUnreadableCreateStatusProvider
  extends EventEmitter
  implements AgentProvider
{
  public readonly kind = "fake";
  public readonly displayName = "Transient Unreadable Create Status Provider";
  public readonly capabilities = FAKE_PROVIDER_CAPABILITIES;

  private readonly sessionId = "fake-transient-create-status-session";
  private readonly createTurnId = "fake-transient-create-status-turn";
  private cwd = "/tmp";
  private created = false;
  private unreadable = true;

  public async start(): Promise<void> {}

  public async close(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return "transient-unreadable-create-status-test";
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.created = true;
    this.cwd = request.cwd;
    return {
      thread: this.buildThread(),
      activeTurnId: request.input.length > 0 ? this.createTurnId : null,
      runtime: null,
    };
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    if (!this.created || options.archived) {
      return [];
    }
    return [this.buildThread()].slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    _includeTurns: boolean,
  ): Promise<ThreadRecord> {
    assert.equal(threadId, this.sessionId);
    if (this.unreadable) {
      this.unreadable = false;
      throw new Error(
        `failed to read thread ${threadId}: rollout file not found`,
      );
    }
    return this.buildThread();
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    if (!this.created) {
      return [];
    }
    return [this.buildThread()].slice(0, limit);
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

  private buildThread(): ThreadRecord {
    return {
      id: this.sessionId,
      name: "Transient unreadable create status session",
      preview: "Transient unreadable create status session",
      createdAt: 1,
      updatedAt: 1,
      cwd: this.cwd,
      source: "fake",
      path: null,
      status: { type: "idle" },
    };
  }
}

class SearchFixtureProvider extends EventEmitter implements AgentProvider {
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

class ActivityReplayFixtureProvider extends EventEmitter implements AgentProvider {
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
  const entry: AgentProviderRuntimeEntry = {
    kind: "fake",
    provider,
    configSummary: summarizeAgentProviderConfig(fakeConfig),
    definitionSummary: fakeDef,
  };
  return {
    provider,
    runtime: {
      provider,
      providers: [entry],
      defaultProviderKind: "fake",
      defaultProvider: entry,
      providerForKind(kind) {
        if (kind === null || kind === undefined) {
          return entry;
        }
        const trimmed = kind.trim();
        if (!trimmed || trimmed === "fake") {
          return entry;
        }
        return null;
      },
      providerForSessionId() {
        return entry;
      },
    },
  };
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

describe("/healthz", () => {
  it("returns 200 when provider is healthy", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server) => {
      const res = await request({ hostname: "127.0.0.1", port: server.port, path: "/healthz", method: "GET" });
      assert.equal(res.statusCode, 200);
      assert.equal((res.body as any).ok, true);
    });
  });

  it("returns 503 when provider getVersion throws", async () => {
    const original = FakeAgentProvider.prototype.getVersion;
    FakeAgentProvider.prototype.getVersion = async function () {
      throw new Error("simulated provider failure");
    };
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    try {
      await withServer(makeConfig(stateDir), async (server) => {
        const res = await request({ hostname: "127.0.0.1", port: server.port, path: "/healthz", method: "GET" });
        assert.equal(res.statusCode, 503);
        assert.equal((res.body as any).ok, false);
        assert.equal((res.body as any).error, "provider unreachable");
      });
    } finally {
      FakeAgentProvider.prototype.getVersion = original;
    }
  });

  it("returns 503 when an explicit provider health probe rejects", async () => {
    const prototype = FakeAgentProvider.prototype as unknown as {
      health?: () => Promise<boolean>;
    };
    const original = prototype.health;
    prototype.health = async () => {
      throw new Error("simulated health rejection");
    };
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    try {
      await withServer(makeConfig(stateDir), async (server) => {
        const res = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/healthz",
          method: "GET",
        });
        assert.equal(res.statusCode, 503);
        assert.equal((res.body as any).ok, false);
      });
    } finally {
      if (original) {
        prototype.health = original;
      } else {
        delete prototype.health;
      }
    }
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
  async function prepareFileInputWorkspace(stateDir: string): Promise<string> {
    const cwd = nodePath.join(stateDir, "workspace");
    await mkdir(nodePath.join(cwd, "src"), { recursive: true });
    await writeFile(nodePath.join(cwd, "README.md"), "readme\n", "utf8");
    await writeFile(nodePath.join(cwd, "package.json"), "{}\n", "utf8");
    return realpath(cwd);
  }

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
      assert.deepEqual(provider.lastCreateInput, [
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
      assert.deepEqual(provider.lastCreateInput, [
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
          prompt: "start",
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
      assert.equal(provider.submittedInputs, 1);

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
      assert.equal(provider.submittedInputs, 1);
    });
  });

  it("replays legacy dedupe receipts that ignored file inputs", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    const cwd = await prepareFileInputWorkspace(stateDir);
    const clientMessageId = "legacy-file-retry";
    const legacyReceipt = {
      mode: "turn",
      turnId: "legacy-turn",
      messageId: "legacy-message",
    };
    await writeLegacyDedupeReceipt(
      stateDir,
      `fake-restart-session:${clientMessageId}`,
      legacyInputSignature([
        {
          type: "text",
          text: "legacy retry",
          text_elements: [],
        },
      ]),
      legacyReceipt,
    );
    await rm(nodePath.join(cwd, "package.json"));
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
          prompt: "start",
        }),
      });
      assert.equal(created.statusCode, 201);
      const sessionId = (created.body as any).session.id as string;

      const retry = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/input`,
        method: "POST",
        headers: {
          Authorization: "Bearer " + config.token,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          clientMessageId,
          input: [
            { type: "file", path: "package.json" },
            { type: "text", text: "legacy retry" },
          ],
        }),
      });
      assert.equal(retry.statusCode, 200);
      assert.deepEqual(retry.body, {
        ...legacyReceipt,
        replayed: true,
      });
      assert.equal(provider.submittedInputs, 0);
    });
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
          prompt: "start",
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
      assert.equal(provider.submittedInputs, 1);
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

  it("returns 501 when provider does not support restart", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/admin/provider/fake/restart",
        method: "POST",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(res.statusCode, 501);
      assert.equal((res.body as any).error, "provider does not support restart");
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
          prompt: "start",
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
      assert.equal((beforeStatus.body as any).pendingAction.id, "fake-restart-action");

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
        const hello = sessionLive.events.find((event) => event.type === "hello");
        provider.emit("liveEvent", {
          type: "provider_warning",
          sessionId,
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
        assert.equal(seeded.seq, hello?.nextSeq);

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
                event.actionId === "fake-restart-action",
            ),
          "restart action resolved live event",
        );
        const turnCompleted = await waitFor(
          () =>
            sessionLive.events.find(
              (event) =>
                event.type === "turn_completed" &&
                event.turnId === "fake-restart-turn",
            ),
          "restart turn completed live event",
        );
        const idleStatus = await waitFor(
          () =>
            sessionLive.events.find(
              (event) =>
                event.type === "thread_status_changed" && event.status === "idle",
            ),
          "restart idle status live event",
        );
        assert.equal(turnCompleted.status, "interrupted");
        assert.equal(turnCompleted.seq, seeded.seq + 1);
        assert.equal(actionResolved.seq, turnCompleted.seq + 1);
        assert.equal(idleStatus.seq, actionResolved.seq + 1);
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

  it("clears interrupted input dedupe receipts after provider restart", async () => {
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
          prompt: "start",
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
          text: "retry me",
          clientMessageId: "local-1",
        }),
      });
      assert.equal(firstSend.statusCode, 200);
      assert.equal((firstSend.body as any).replayed, false);
      assert.equal(provider.submittedInputs, 1);

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
          text: "retry me",
          clientMessageId: "local-1",
        }),
      });
      assert.equal(duplicateBeforeRestart.statusCode, 200);
      assert.equal((duplicateBeforeRestart.body as any).replayed, true);
      assert.equal(provider.submittedInputs, 1);

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
          text: "retry me",
          clientMessageId: "local-1",
        }),
      });
      assert.equal(retryAfterRestart.statusCode, 200);
      assert.equal((retryAfterRestart.body as any).replayed, false);
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
      assert.equal(body.providerCapabilities.sessions.create, true);
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

  it("with two providers: providerCapabilities reflects default; per-provider caps are preserved", async () => {
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

      // providerCapabilities and defaultProviderCapabilities both reflect the
      // default (full) provider.
      assert.equal(body.providerCapabilities.configuration.models, true);
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
    let exitCode: number | null = null;
    let resolveExit: (() => void) | null = null;
    const exited = new Promise<void>((resolve) => {
      resolveExit = resolve;
    });

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
      },
      exitProcess: (code = 0) => {
        exitCode = code;
        resolveExit?.();
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
      assert.deepEqual(res.body, { ok: true, message: "daemon is updating" });

      await Promise.race([
        exited,
        new Promise<never>((_, reject) =>
          setTimeout(
            () => reject(new Error("timed out waiting for updater spawn")),
            2_000,
          ),
        ),
      ]);

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
      assert.equal(exitCode, 0);
    } finally {
      if (exitCode === null) {
        await server.close();
      }
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
          sessionId: primary.thread.id,
          level: "warning",
          code: "warn-1",
          message: "Heads up",
          source: "fake/runtime",
        });
        provider.emit("liveEvent", {
          type: "thread_status_changed",
          sessionId: primary.thread.id,
          status: "running",
          message: "Working",
        });
        provider.emit("liveEvent", {
          type: "plan_updated",
          sessionId: primary.thread.id,
          turnId: "turn-1",
          explanation: "Follow the envelope plan.",
          plan: [
            { step: "Read docs", status: "completed" },
            { step: "Wire the server", status: "in_progress" },
          ],
        });
        provider.emit("liveEvent", {
          type: "reasoning_delta",
          sessionId: primary.thread.id,
          turnId: "turn-1",
          itemId: "item-1",
          reasoningId: "reason-1",
          delta: "Thinking...",
          summary: true,
        });
        provider.emit("liveEvent", {
          type: "queue_updated",
          sessionId: primary.thread.id,
          steeringCount: 1,
          followUpCount: 2,
          steeringPreview: ["Keep it provider-neutral"],
          followUpPreview: ["Add tests", "Run analyze"],
        });
        provider.emit("liveEvent", {
          type: "auto_retry_updated",
          sessionId: primary.thread.id,
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
        sessionId,
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
        sessionId,
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

  it("replays the latest missed plan update through the events delta route", async () => {
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

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId,
        turnId: "turn-1",
        explanation: "Catch up on reconnect.",
        plan: [{ step: "Replay the latest plan", status: "in_progress" }],
      });

      const delta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/events?since=-1`,
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
        path: `/api/sessions/${encodeURIComponent(sessionId)}/events?since=${replayedSeq}`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(upToDate.statusCode, 200);
      assert.equal((upToDate.body as any).latestPlanUpdate, null);
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
      const created = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const sessionId = created.thread.id;

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId,
        turnId: "turn-1",
        explanation: "Create the plan card.",
        plan: [{ step: "Show the plan", status: "in_progress" }],
      });

      const firstDelta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/events?since=-1`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(firstDelta.statusCode, 200);
      assert.equal(
        (firstDelta.body as any).latestPlanUpdate.plan[0].step,
        "Show the plan",
      );
      const firstSeq = (firstDelta.body as any).latestPlanUpdate.seq as number;

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId,
        turnId: "turn-1",
        plan: [],
      });

      const clearDelta = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/events?since=${firstSeq}`,
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

  it("replays updated activities through the events delta route even when the transcript seq is unchanged", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-live-test-"));
    const provider = new ActivityReplayFixtureProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const logPath = `/api/sessions/${encodeURIComponent(provider.sessionId)}/log`;
      const eventsPath = `/api/sessions/${encodeURIComponent(provider.sessionId)}/events?since=1`;

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
        sessionId: provider.sessionId,
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
      assert.ok(((delta.body as any).nextSeq as number) > 1);

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

  it("forces snapshot fallback when persisted session state changed without replayable seq deltas", async () => {
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
          `/api/sessions/${encodeURIComponent(provider.sessionId)}/events?since=1&baseUpdatedAt=1000`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(delta.statusCode, 409);
      assert.equal((delta.body as any).error, "stale_snapshot");
      assert.equal((delta.body as any).currentUpdatedAt, 2000);
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

  it("restores the latest plan update and replay cursor from persisted daemon state after restart", async () => {
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
      const created = await provider.createSession({
        cwd: stateDir,
        input: [],
        overrides: EMPTY_OVERRIDES,
      });
      const sessionId = created.thread.id;

      provider.emit("liveEvent", {
        type: "plan_updated",
        sessionId,
        turnId: "turn-1",
        explanation: "Persist this plan.",
        plan: [{ step: "Reload after restart", status: "completed" }],
      });

      await firstServer.close();
      firstServer = null;

      secondServer = await startServer(config, runtime);
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
        path: `/api/sessions/${encodeURIComponent(sessionId)}/events?since=-1`,
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
        assert.equal(hello.nextSeq, 1);
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
          sessionId: primary.thread.id,
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
        prompt: "start",
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

  async function createTransientStatusSession(
    server: RunningServer,
    config: NodeConfig,
  ): Promise<any> {
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
        cwd: "/tmp/transient-unreadable-create-status-test",
        prompt: "start while thread read is temporarily unavailable",
      }),
    });
    assert.equal(createRes.statusCode, 201);
    return createRes.body as any;
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

  it("falls back to turn scan and reports running for in_progress turns", async () => {
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

      const original = (FakeAgentProvider.prototype as any).readSessionThread;
      (FakeAgentProvider.prototype as any).readSessionThread = async function (
        sid: string,
        includeTurns: boolean,
      ) {
        const result = await original.call(this, sid, includeTurns);
        if (includeTurns && result.turns) {
          for (const turn of result.turns) {
            if (turn.status === "inProgress") {
              turn.status = "in_progress";
            }
          }
        }
        result.status = { type: "idle" };
        return result;
      };

      try {
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
      } finally {
        (FakeAgentProvider.prototype as any).readSessionThread = original;
      }
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
      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId: session.thread.id,
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
        (item) => item.id === session.thread.id,
      );
      assert.ok(listed);
      assert.equal(listed.status, "waiting_for_approval");
    });
  });

  it("returns structured sub-agent lineage for child sessions in recent rows", async () => {
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
        (item) => item.id === "thread-child",
      );
      assert.ok(listed);
      assert.equal(listed.source, "sub-agent");
      assert.equal(listed.isSubAgent, true);
      assert.deepEqual(listed.subAgent, {
        parentSessionId: "thread-parent",
        sourceKind: "thread_spawn",
        agentRole: "explorer",
        agentNickname: "scout",
        depth: 1,
      });
    });
  });

  it("does not let stale live idle status override an active turn", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionId = await createRestartableSession(server, config);
      await resumeRestartableSession(server, config);

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
        status: "idle",
      });

      const status = await readStatus(server, config, sessionId);
      assert.equal(status.status, "running");
      assert.equal(status.isRunning, true);
      assert.equal(await readRecentStatus(server, config, sessionId), "running");
    });
  });

  it("preserves provider waiting status while an active turn is tracked", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionId = await createRestartableSession(server, config);
      await resumeRestartableSession(server, config);

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
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

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
        status: "errored",
      });

      const status = await readStatus(server, config, sessionId);
      assert.equal(status.status, "errored");
      assert.equal(status.isRunning, false);
      assert.equal(status.activeTurnId, null);
      assert.equal(await readRecentStatus(server, config, sessionId), "errored");
    });
  });

  it("drops live activities after a terminal status closes the turn", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionId = await createRestartableSession(server, config);
      await resumeRestartableSession(server, config);

      provider.emit("liveEvent", {
        type: "activity_updated",
        sessionId,
        turnId: "fake-restart-turn",
        activity: {
          id: "cmd-1",
          type: "command",
          turnId: "fake-restart-turn",
          status: "in_progress",
          command: "npm test",
          cwd: "/tmp/restart-test",
          output: "still streaming",
          exitCode: null,
          durationMs: null,
          source: "agent",
          processId: "proc-1",
          commandActions: [],
          terminalStatus: null,
          terminalInput: null,
        },
      });

      const liveLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(liveLog.statusCode, 200);
      assert.equal((liveLog.body as any).activities[0]?.id, "cmd-1");

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
        status: "errored",
      });

      const originalReadSessionThread = provider.readSessionThread.bind(provider);
      provider.readSessionThread = async (threadId, includeTurns) => {
        const thread = await originalReadSessionThread(threadId, includeTurns);
        return {
          ...thread,
          status: { type: "errored" },
          ...(includeTurns ? { turns: [] } : {}),
        };
      };

      const clearedLog = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(clearedLog.statusCode, 200);
      assert.deepEqual((clearedLog.body as any).activities, []);
    });
  });

  it("clears stale terminal session state from events, resources, and actions after provider confirmation", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionId = await createRestartableSession(server, config);

      provider.emit("liveEvent", {
        type: "activity_updated",
        sessionId,
        turnId: "fake-restart-turn",
        activity: {
          id: "search-1",
          type: "web_search",
          turnId: "fake-restart-turn",
          status: "completed",
          query: "example",
          queries: ["example"],
          targetUrl: "https://example.com/docs",
          pattern: null,
        },
      });

      const liveResources = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/resources`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(liveResources.statusCode, 200);
      assert.equal((liveResources.body as any).resources.length, 1);

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
        status: "errored",
      });

      const originalReadSessionThread = provider.readSessionThread.bind(provider);
      provider.readSessionThread = async (threadId, includeTurns) => {
        const thread = await originalReadSessionThread(threadId, includeTurns);
        return {
          ...thread,
          status: { type: "errored" },
          ...(includeTurns ? { turns: [] } : {}),
        };
      };

      const actionsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/actions",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(actionsRes.statusCode, 200);
      assert.deepEqual(actionsRes.body, []);

      const eventsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/events?since=0`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(eventsRes.statusCode, 200);
      assert.deepEqual((eventsRes.body as any).activities, []);
      assert.equal((eventsRes.body as any).pendingAction, null);
      assert.equal((eventsRes.body as any).session.status, "errored");

      const clearedResources = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/resources`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(clearedResources.statusCode, 200);
      assert.deepEqual((clearedResources.body as any).resources, []);
    });
  });

  it("reconciles stale terminal live status after a short grace window", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RestartableFakeProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const sessionId = await createRestartableSession(server, config);
      await resumeRestartableSession(server, config);

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
        status: "errored",
      });

      const terminalStatus = await readStatus(server, config, sessionId);
      assert.equal(terminalStatus.status, "errored");

      await new Promise((resolve) => setTimeout(resolve, 1_100));

      assert.equal(await readRecentStatus(server, config, sessionId), "running");

      const reconciledStatus = await readStatus(server, config, sessionId);
      assert.equal(reconciledStatus.status, "running");
      assert.equal(reconciledStatus.isRunning, true);
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
          prompt: "finish immediately",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal((createRes.body as any).session.status, "idle");
      assert.equal((createRes.body as any).activeTurnId, "fake-immediate-create-turn");

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
          text: "finish immediately again",
        }),
      });
      assert.equal(inputRes.statusCode, 200);
      assert.equal((inputRes.body as any).turnId, "fake-immediate-submit-turn-1");

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

  it("does not resurrect completed turns when the immediate status read is transiently unreadable", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new ImmediateCompletionProvider(1);
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
          cwd: "/tmp/immediate-completion-transient-status-test",
          prompt: "finish immediately while status read is unavailable",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal((createRes.body as any).session.status, "idle");
      assert.equal((createRes.body as any).activeTurnId, "fake-immediate-create-turn");

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "idle");
      assert.equal((statusRes.body as any).isRunning, false);
      assert.equal((statusRes.body as any).activeTurnId, null);
    });
  });

  it("tracks returned turn ids when cached live status is terminal", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new StaleIdleSubmitProvider();
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
          cwd: "/tmp/stale-idle-submit-test",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal((createRes.body as any).session.status, "idle");

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
        status: "idle",
      });

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
          text: "start after cached idle",
        }),
      });
      assert.equal(inputRes.statusCode, 200);
      assert.equal((inputRes.body as any).turnId, "fake-stale-submit-turn-1");

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "running");
      assert.equal((statusRes.body as any).isRunning, true);
      assert.equal(
        (statusRes.body as any).activeTurnId,
        "fake-stale-submit-turn-1",
      );
    });
  });

  it("tracks returned turn ids while provider snapshots lag behind start", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new LaggingCreateTurnProvider();
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
          cwd: "/tmp/lagging-create-turn-test",
          prompt: "start while history lags",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal(
        (createRes.body as any).activeTurnId,
        "fake-lagging-create-turn",
      );
      assert.equal((createRes.body as any).session.status, "running");

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "running");
      assert.equal((statusRes.body as any).isRunning, true);
      assert.equal(
        (statusRes.body as any).activeTurnId,
        "fake-lagging-create-turn",
      );
    });
  });

  it("tracks returned turn ids when turn snapshots are temporarily unreadable", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new TransientUnreadableCreateTurnProvider();
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
          cwd: "/tmp/transient-unreadable-create-turn-test",
          prompt: "start while rollout is still empty",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal(
        (createRes.body as any).activeTurnId,
        "fake-transient-create-turn",
      );
      assert.equal((createRes.body as any).session.status, "running");

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "running");
      assert.equal((statusRes.body as any).isRunning, true);
      assert.equal(
        (statusRes.body as any).activeTurnId,
        "fake-transient-create-turn",
      );
    });
  });

  it("keeps unverified returned turns until a transient turn snapshot recovers", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RecoveringCreateTurnProvider(
      "fake-recovering-missing-session",
      "fake-recovering-missing-turn",
      2,
      null,
    );
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
          cwd: "/tmp/recovering-missing-create-turn-test",
          prompt: "start while turn snapshot is temporarily unavailable",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal(sessionId, "fake-recovering-missing-session");
      assert.equal((createRes.body as any).session.status, "running");

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "idle");
      assert.equal((statusRes.body as any).isRunning, false);
      assert.equal((statusRes.body as any).activeTurnId, null);
    });
  });

  it("does not reconcile an old unverified turn after a newer turn starts", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RecoveringCreateTurnProvider(
      "fake-recovering-race-session",
      "fake-recovering-race-turn",
      2,
      null,
    );
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
          cwd: "/tmp/recovering-race-create-turn-test",
          prompt: "start while turn snapshot is temporarily unavailable",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      provider.onRecoveredIncludeTurnRead(() => {
        provider.emit("liveEvent", {
          type: "turn_started",
          sessionId,
          turnId: "fake-recovering-new-turn",
        });
      });

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "running");
      assert.equal((statusRes.body as any).isRunning, true);
      assert.equal((statusRes.body as any).activeTurnId, "fake-recovering-new-turn");
    });
  });

  it("keeps live activities when recovery clears a transient active turn", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RecoveringCreateTurnProvider(
      "fake-recovering-live-activity-session",
      "fake-recovering-live-activity-turn",
      2,
      null,
    );
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
          cwd: "/tmp/recovering-live-activity-create-turn-test",
          prompt: "start while turn snapshot is temporarily unavailable",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      provider.emit("liveEvent", {
        type: "activity_updated",
        sessionId,
        turnId: "fake-recovering-live-activity-turn",
        activity: {
          id: "cmd-live-tail",
          type: "command",
          turnId: "fake-recovering-live-activity-turn",
          status: "in_progress",
          command: "npm test",
          cwd: "/tmp/recovering-live-activity-create-turn-test",
          output: "streamed output not flushed yet",
          exitCode: null,
          durationMs: null,
          source: "agent",
          processId: "proc-live-tail",
          commandActions: [],
          terminalStatus: null,
          terminalInput: null,
        },
      });

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "idle");

      const logRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(logRes.statusCode, 200);
      assert.equal((logRes.body as any).activities[0]?.id, "cmd-live-tail");
    });
  });

  it("keeps recovered failed turn status after live terminal grace expires", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new RecoveringCreateTurnProvider(
      "fake-recovering-failed-session",
      "fake-recovering-failed-turn",
      2,
      "failed",
    );
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
          cwd: "/tmp/recovering-failed-create-turn-test",
          prompt: "start while failed turn snapshot is temporarily unavailable",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;
      assert.equal(sessionId, "fake-recovering-failed-session");
      assert.equal((createRes.body as any).session.status, "running");

      const statusRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(statusRes.statusCode, 200);
      assert.equal((statusRes.body as any).status, "errored");
      assert.equal((statusRes.body as any).isRunning, false);
      assert.equal((statusRes.body as any).activeTurnId, null);

      await new Promise((resolve) => setTimeout(resolve, 1_100));

      assert.equal(await readRecentStatus(server, config, sessionId), "errored");
      const delayedStatus = await readStatus(server, config, sessionId);
      assert.equal(delayedStatus.status, "errored");
      assert.equal(delayedStatus.isRunning, false);
    });
  });

  it("returns create success and clears unverified active turns from idle thread status", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new TransientUnreadableCreateStatusProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const createBody = await createTransientStatusSession(server, config);
      const sessionId = createBody.session.id as string;
      assert.equal(sessionId, "fake-transient-create-status-session");
      assert.equal(
        createBody.activeTurnId,
        "fake-transient-create-status-turn",
      );
      assert.equal(createBody.session.status, "running");

      const sessionLive = await openSessionLiveSocket(
        server.port,
        config.token,
        sessionId,
      );
      try {
        await waitFor(
          () => sessionLive.events.find((event) => event.type === "hello"),
          "transient status hello",
        );

        const statusRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${encodeURIComponent(sessionId)}/status`,
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(statusRes.statusCode, 200);
        assert.equal((statusRes.body as any).status, "idle");
        assert.equal((statusRes.body as any).isRunning, false);
        assert.equal((statusRes.body as any).activeTurnId, null);
        await waitFor(
          () =>
            sessionLive.events.find(
              (event) =>
                event.type === "thread_status_changed" &&
                event.status === "idle",
            ),
          "transient status idle live event",
        );
      } finally {
        await closeSessionLiveSocket(sessionLive.socket);
      }
    });
  });

  it("clears unverified active turns from log snapshots", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new TransientUnreadableCreateStatusProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const createBody = await createTransientStatusSession(server, config);
      const sessionId = createBody.session.id as string;

      const logRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/log`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(logRes.statusCode, 200);
      assert.equal((logRes.body as any).session.status, "idle");
    });
  });

  it("clears unverified active turns from event replay snapshots", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new TransientUnreadableCreateStatusProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const createBody = await createTransientStatusSession(server, config);
      const sessionId = createBody.session.id as string;

      const eventsRes = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: `/api/sessions/${encodeURIComponent(sessionId)}/events?since=0`,
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(eventsRes.statusCode, 200);
      assert.equal((eventsRes.body as any).session.status, "idle");
    });
  });

  it("clears unverified active turns from recent session snapshots", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-test-"));
    const provider = new TransientUnreadableCreateStatusProvider();
    const runtime = makeCustomSingleProviderRuntime(provider);
    await withServerRuntime(makeConfig(stateDir), runtime, async (server, config) => {
      const createBody = await createTransientStatusSession(server, config);
      const sessionId = createBody.session.id as string;

      assert.equal(await readRecentStatus(server, config, sessionId), "idle");
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
          prompt: "start",
        }),
      });
      assert.equal(createRes.statusCode, 201);
      const sessionId = (createRes.body as any).session.id as string;

      provider.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
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
            prompt: "start",
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
          (session) => session.id === provider.sessionId,
        );
        assert.equal(snapshotSession?.updatedAt, provider.freshUpdatedAt);

        provider.emit("liveEvent", {
          type: "thread_status_changed",
          sessionId: provider.sessionId,
          status: "running",
        });

        const upsert = await waitFor(
          () =>
            recentLive.events.find(
              (event) =>
                event.type === "upsert" &&
                event.session?.id === provider.sessionId,
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

  it("keeps rename live upserts aligned with canonical recent session summaries", async () => {
    const stateDir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-server-recent-rename-test-"),
    );
    await withServer(makeConfig(stateDir), async (server, config) => {
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
            cwd: "/tmp/recent-rename-test",
            prompt: "rename this recent session",
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

  it("returns archived provider sessions from startup backfill when requested", async () => {
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
          results.some((session) => session.id === "fixture-archived"),
          "expected archived startup-backfilled session in archived search",
        );
        assert.ok(
          !results.some((session) => session.id === "fixture-active"),
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
          included.some((session) => session.id === "fixture-filter"),
          "expected session newer than updatedAfter filter",
        );

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
        const excluded = excludeRes.body as any[];
        assert.ok(
          !excluded.some((session) => session.id === "fixture-filter"),
          "expected session older than updatedAfter filter to be excluded",
        );
      },
    );
  });
});
