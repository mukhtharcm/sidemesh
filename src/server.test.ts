import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import http from "node:http";

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
  AgentProviderCapabilities,
  AgentSessionListOptions,
  AgentSessionLogOptions,
  AgentSubmitInputRequest,
  AgentSubmitInputResult,
} from "./agent-provider.js";
import type { SessionLogSnapshot, ThreadRecord } from "./types.js";

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
    terminal: { enabled: false, shell: null, requirePty: false },
    portForwarding: { enabled: false, allowNonLoopbackTargets: false },
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
          });
        } catch {
          resolve({
            statusCode: res.statusCode ?? 0,
            body: data,
          });
        }
      });
    });
    req.on("error", reject);
    if (options.body) req.write(options.body);
    req.end();
  });
}

const ADMIN_CONFIG_ENV_KEYS = [
  "SIDEMESH_LABEL",
  "SIDEMESH_RECOMMENDED_MOBILE_CLIENT_VERSION",
  "SIDEMESH_MINIMUM_MOBILE_CLIENT_VERSION",
  "SIDEMESH_TERMINAL",
  "SIDEMESH_ENABLE_TERMINAL",
  "SIDEMESH_TERMINAL_SHELL",
  "SIDEMESH_TERMINAL_REQUIRE_PTY",
  "SIDEMESH_PORT_FORWARDING",
  "SIDEMESH_ENABLE_PORT_FORWARDING",
  "SIDEMESH_PORT_FORWARDING_ALLOW_NON_LOOPBACK",
  "SIDEMESH_BROWSER_PREVIEW",
  "SIDEMESH_ENABLE_BROWSER_PREVIEW",
  "SIDEMESH_BROWSER_PREVIEW_CHROME_PATH",
  "SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS",
  "SIDEMESH_BROWSER_PREVIEW_IDLE_TTL_MS",
  "SIDEMESH_BROWSER_PREVIEW_FRAME_INTERVAL_MS",
  "SIDEMESH_BROWSER_PREVIEW_QUALITY",
] as const;

async function withOverriddenEnv(
  overrides: Partial<Record<(typeof ADMIN_CONFIG_ENV_KEYS)[number], string | undefined>>,
  fn: () => Promise<void>,
): Promise<void> {
  const previous: Partial<Record<(typeof ADMIN_CONFIG_ENV_KEYS)[number], string | undefined>> = {};
  for (const key of ADMIN_CONFIG_ENV_KEYS) {
    previous[key] = process.env[key];
    const nextValue = overrides[key];
    if (nextValue === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = nextValue;
    }
  }
  try {
    await fn();
  } finally {
    for (const key of ADMIN_CONFIG_ENV_KEYS) {
      const prior = previous[key];
      if (prior === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = prior;
      }
    }
  }
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
  public readonly displayName = "Restartable Fake Test Provider";
  public readonly capabilities = RESTARTABLE_FAKE_CAPABILITIES;

  private readonly sessionId = "fake-restart-session";
  private readonly initialTurnId = "fake-restart-turn";
  private readonly actionId = "fake-restart-action";
  private cwd = "/tmp";
  private created = false;
  private restarted = false;
  private currentTurnId: string | null = null;
  private submitCount = 0;

  public get submittedInputs(): number {
    return this.submitCount;
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

describe("Admin config routes", () => {
  it("returns editable config fields and metadata", async () => {
    await withOverriddenEnv({}, async () => {
      const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
      await withServer(makeConfig(stateDir), async (server, config) => {
        const res = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/admin/config",
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });

        assert.equal(res.statusCode, 200);
        const body = res.body as any;
        assert.equal(body.config.label, "test");
        assert.equal(body.fields.label.writable, true);
        assert.equal(body.fields["terminal.enabled"].requiresRestart, true);
        assert.equal(body.restart.requiredForPendingChanges, false);
        assert.equal(typeof body.restart.serviceManaged, "boolean");
      });
    });
  });

  it("applies immediate fields without restart and reflects them in node/usage payloads", async () => {
    await withOverriddenEnv({}, async () => {
      const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
      await withServer(makeConfig(stateDir), async (server, config) => {
        const patch = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/admin/config",
          method: "PATCH",
          headers: {
            Authorization: "Bearer " + config.token,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            label: "test-renamed",
            recommendedMobileClientVersion: "1.4.0",
            minimumMobileClientVersion: "1.1.0",
          }),
        });
        assert.equal(patch.statusCode, 200);
        assert.equal((patch.body as any).ok, true);
        assert.deepEqual((patch.body as any).changed, [
          "label",
          "recommendedMobileClientVersion",
          "minimumMobileClientVersion",
        ]);
        assert.deepEqual((patch.body as any).appliedImmediately, [
          "label",
          "recommendedMobileClientVersion",
          "minimumMobileClientVersion",
        ]);
        assert.equal((patch.body as any).restart.requiredForPendingChanges, false);

        const node = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/node",
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(node.statusCode, 200);
        assert.equal((node.body as any).label, "test-renamed");
        assert.equal((node.body as any).recommendedMobileClientVersion, "1.4.0");
        assert.equal((node.body as any).minimumMobileClientVersion, "1.1.0");

        const health = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/healthz",
          method: "GET",
        });
        assert.equal(health.statusCode, 200);
        assert.equal((health.body as any).label, "test-renamed");

        const usage = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/usage",
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(usage.statusCode, 200);
        assert.equal((usage.body as any).host.label, "test-renamed");
        assert.equal((usage.body as any).observations[0].hostLabel, "test-renamed");
      });
    });
  });

  it("marks runtime-only host features as restart-required", async () => {
    await withOverriddenEnv({}, async () => {
      const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
      await withServer(makeConfig(stateDir), async (server, config) => {
        const patch = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/admin/config",
          method: "PATCH",
          headers: {
            Authorization: "Bearer " + config.token,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            terminal: { enabled: true },
            browserPreview: { quality: 65 },
          }),
        });
        assert.equal(patch.statusCode, 200);
        assert.equal((patch.body as any).restart.requiredForPendingChanges, true);
        assert.ok(
          (patch.body as any).restart.warning === null ||
            typeof (patch.body as any).restart.warning === "string",
        );
        assert.deepEqual((patch.body as any).changed, [
          "terminal.enabled",
          "browserPreview.quality",
        ]);
        assert.deepEqual((patch.body as any).appliedImmediately, []);

        const persisted = JSON.parse(
          await readFile(config.configPath, "utf8"),
        ) as {
          terminal?: { enabled?: boolean };
          browserPreview?: { quality?: number };
        };
        assert.equal(persisted.terminal?.enabled, true);
        assert.equal(persisted.browserPreview?.quality, 65);
      });
    });
  });

  it("rejects edits when a field is env-overridden", async () => {
    const previousLabel = process.env.SIDEMESH_LABEL;
    process.env.SIDEMESH_LABEL = "forced-by-env";
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-test-"));
    try {
      await withServer(makeConfig(stateDir), async (server, config) => {
        const current = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/admin/config",
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(current.statusCode, 200);
        assert.equal((current.body as any).fields.label.source, "env");
        assert.equal((current.body as any).fields.label.writable, false);

        const patch = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/admin/config",
          method: "PATCH",
          headers: {
            Authorization: "Bearer " + config.token,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            label: "blocked-update",
          }),
        });
        assert.equal(patch.statusCode, 409);
        assert.match(
          (patch.body as any).error,
          /controlled by environment variables/,
        );
      });
    } finally {
      if (previousLabel === undefined) {
        delete process.env.SIDEMESH_LABEL;
      } else {
        process.env.SIDEMESH_LABEL = previousLabel;
      }
    }
  });

  it("keeps fields writable when env vars are present but not effective overrides", async () => {
    await withOverriddenEnv(
      {
        SIDEMESH_LABEL: "   ",
        SIDEMESH_TERMINAL: "   ",
        SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS: "not-a-number",
      },
      async () => {
        const stateDir = await mkdtemp(
          nodePath.join(tmpdir(), "sidemesh-server-test-"),
        );
        await withServer(makeConfig(stateDir), async (server, config) => {
          const res = await request({
            hostname: "127.0.0.1",
            port: server.port,
            path: "/api/admin/config",
            method: "GET",
            headers: { Authorization: "Bearer " + config.token },
          });
          assert.equal(res.statusCode, 200);
          const body = res.body as any;
          assert.equal(body.fields.label.source, "default");
          assert.equal(body.fields.label.writable, true);
          assert.equal(body.fields["terminal.enabled"].source, "default");
          assert.equal(body.fields["terminal.enabled"].writable, true);
          assert.equal(body.fields["browserPreview.maxPreviews"].source, "default");
          assert.equal(body.fields["browserPreview.maxPreviews"].writable, true);
        });
      },
    );
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
});



describe("GET /api/sessions/:sessionId/status", () => {
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
        assert.equal((statusRes.body as any).isRunning, true);
        assert.ok((statusRes.body as any).activeTurnId);
      } finally {
        (FakeAgentProvider.prototype as any).readSessionThread = original;
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
        path: `/api/sessions/search?q=${encodeURIComponent("seed")}`,
        method: "GET",
      });
      assert.equal(searchRes.statusCode, 200);
      const results = searchRes.body as any[];
      assert.ok(results.length >= 1, "expected at least one seeded session");
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
});
