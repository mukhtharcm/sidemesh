import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { describe, it } from "node:test";

import { AgentProviderRuntime, createAgentProviderRuntime } from "./provider-factory.js";
import { listAgentProviderDefinitionSummaries, summarizeAgentProviderConfig } from "./provider-registry.js";
import { AgentProviderRequestError, type AgentProviderEvents, type AgentHostServices, type AgentProviderLiveEvent } from "./agent-provider.js";
import { FAKE_PROVIDER_CAPABILITIES } from "./fake-provider.js";
import { wrapProviderScopedId } from "./session-identity.js";
import type { NodeConfig, ThreadRecord } from "./types.js";

class TestProvider extends EventEmitter<AgentProviderEvents> {
  readonly kind = "fake";
  readonly displayName = "Test provider";
  readonly capabilities = FAKE_PROVIDER_CAPABILITIES;
  hostServices?: AgentHostServices;
  attachHostServices(services: AgentHostServices): void { this.hostServices = services; }
  starts = 0;
  closes = 0;
  healthy = true;
  async start(): Promise<void> { this.starts++; }
  async close(): Promise<void> { this.closes++; }
  async health(): Promise<boolean> { return this.healthy; }
  async getVersion(): Promise<string> { return "test 1"; }
}

function runtimeFor(factories: Record<string, () => TestProvider>): AgentProviderRuntime {
  const definitionSummary = listAgentProviderDefinitionSummaries().find((entry) => entry.kind === "fake")!;
  const configSummary = summarizeAgentProviderConfig({ kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" });
  return new AgentProviderRuntime(Object.entries(factories).map(([id, create]) => ({ id, kind: "fake", create, configSummary, definitionSummary })), Object.keys(factories)[0]!);
}

describe("configured provider runtime", () => {
  it("scopes authentication terminals to the configured instance before and after startup", async () => {
    const a = new TestProvider();
    const b = new TestProvider();
    const runtime = runtimeFor({ writer: () => a, reviewer: () => b });
    const sessions: string[] = [];
    try {
      await runtime.ensure(runtime.providers[0]!);
      runtime.attachHostServices({ runAuthenticationTerminal: async (request) => { sessions.push(request.sessionId); } });
      await runtime.ensure(runtime.providers[1]!);
      for (const provider of [a, b]) await provider.hostServices!.runAuthenticationTerminal({
        cwd: "/tmp", sessionId: "same", executable: "/agent", args: [], signal: new AbortController().signal, onReady: () => {},
      });
      assert.deepEqual(sessions, ["writer", "reviewer"].map((id) => wrapProviderScopedId(id, "same")));
    } finally { await runtime.close(); }
  });

  it("keeps instances lazy and capabilities specific to each configured provider", async () => {
    const runtime = createAgentProviderRuntime(makeMultiProviderConfig());
    try {
      assert.equal(runtime.defaultProviderKind, "copilot");
      assert.equal(runtime.providerForKind(null), runtime.defaultProvider);
      assert.equal(runtime.providerForKind(undefined), runtime.defaultProvider);
      for (const id of ["", "   ", "unknown"]) assert.equal(runtime.providerForKind(id), null);
      assert.equal(runtime.providerForKind("fake")?.capabilities.sessions.searchSessions, true);
      assert.equal(runtime.defaultProvider.capabilities.sessions.searchSessions, false);
      assert.ok(runtime.providers.every((entry) => entry.state === "idle" && entry.instance === null));
    } finally { await runtime.close(); }
  });

  it("keeps identical native session, parent, and approval IDs separate", async () => {
    const a = new TestProvider();
    const b = new TestProvider();
    const runtime = runtimeFor({ writer: () => a, reviewer: () => b });
    const events: AgentProviderLiveEvent[] = [];
    runtime.on("liveEvent", (event) => events.push(event));
    try {
      assert.equal(runtime.providerForKind("fake"), null);
      for (const entry of runtime.providers) {
        const provider = await runtime.ensure(entry);
        const thread: ThreadRecord = { id: "same", cwd: "/tmp", source: "fake", path: null,
          name: null, preview: "", createdAt: 1, updatedAt: 1, status: { type: "idle" },
          subAgent: { parentSessionId: "parent", sourceKind: "child_session" } };
        const publicThread = runtime.wrapThread(entry, thread);
        const resolved = runtime.resolveSession(publicThread.id);
        assert.equal(resolved.rawId, "same");
        assert.equal(resolved.entry, entry);
        assert.equal(publicThread.subAgent?.parentSessionId, wrapProviderScopedId(entry.id, "parent"));
        assert.equal(publicThread.providerKind, "fake");
        assert.equal(publicThread.providerId, entry.id);
        provider.emit("liveEvent", { type: "plan_updated", sessionId: "same", plan: [{ step: "Keep the plan", status: "in_progress" }] });
        provider.emit("liveEvent", { type: "action_opened", action: { id: "choice", sessionId: "same", kind: "command",
          title: "Approval", detail: "Read a file", requestedAt: 1, canApprove: true, canDecline: true,
          canApproveForSession: false, providerRequestId: "choice", providerRequestKind: "command" } });
      }
      assert.equal(events.length, 4);
      assert.deepEqual(events.map((event) => event.type === "action_opened" ? event.action.sessionId : "sessionId" in event ? event.sessionId : null),
        ["writer", "writer", "reviewer", "reviewer"].map((id) => wrapProviderScopedId(id, "same")));
      const actions = events.filter((event) => event.type === "action_opened");
      assert.equal(new Set(actions.map((event) => event.action.id)).size, 2);
      assert.equal(runtime.providerForSessionId(wrapProviderScopedId("missing", "same")), null);
      assert.throws(() => runtime.resolveSession(wrapProviderScopedId("missing", "same")), /not configured/);
    } finally { await runtime.close(); }
    assert.equal(a.listenerCount("liveEvent"), 0);
    assert.equal(b.listenerCount("exit"), 0);
  });

  it("shares startup work and isolates a failed provider", async () => {
    const good = new TestProvider();
    const bad = new TestProvider();
    bad.start = async () => { bad.starts++; throw new Error("Missing executable"); };
    const runtime = runtimeFor({ good: () => good, bad: () => bad });
    let reentrant: Promise<unknown> | undefined;
    runtime.on("liveEvent", () => { reentrant = runtime.ensure(runtime.providers[0]!); });
    good.start = async () => { good.starts++; good.emit("liveEvent", { type: "turn_started", sessionId: "native", turnId: "turn" }); };
    try {
      const [a, b] = await Promise.all([runtime.ensure(runtime.providers[0]!), runtime.ensure(runtime.providers[0]!)]);
      assert.equal(a, b);
      assert.equal(await reentrant, a);
      assert.equal(good.starts, 1);
      await assert.rejects(runtime.ensure(runtime.providers[1]!), (error) => error instanceof AgentProviderRequestError && error.inputNotDispatched && error.status === 503);
      assert.equal(bad.closes, 1);
      assert.equal(bad.listenerCount("exit"), 0);
      assert.equal(runtime.providers[1]?.state, "unavailable");
      assert.equal(runtime.providers[0]?.state, "ready");
      assert.equal(await runtime.ensure(runtime.providers[0]!), good);
    } finally { await runtime.close(); }
  });

  it("recreates a failed provider without routing work to its old connection", async () => {
    const old = new TestProvider();
    const replacement = new TestProvider();
    let created = 0;
    const runtime = runtimeFor({ writer: () => created++ === 0 ? old : replacement });
    try {
      const entry = runtime.defaultProvider;
      await runtime.ensure(entry);
      old.emit("exit", 1);
      assert.equal(entry.state, "unavailable");
      let release!: () => void;
      old.close = async () => { old.closes++; await new Promise<void>((resolve) => { release = resolve; }); };
      const restarting = runtime.restart(entry);
      const waiting = runtime.ensure(entry);
      await Promise.resolve();
      release();
      await restarting;
      assert.equal(await waiting, replacement);
      assert.equal(entry.state, "ready");
      assert.equal(old.closes, 1);
      old.emit("exit", 1);
      assert.equal(entry.state, "ready");
      assert.equal(replacement.starts, 1);
    } finally { await runtime.close(); }
  });

  it("finishes every provider close before reporting a failure", async () => {
    const a = new TestProvider();
    const b = new TestProvider();
    const runtime = runtimeFor({ a: () => a, b: () => b });
    await Promise.all(runtime.providers.map((entry) => runtime.ensure(entry)));
    let release!: () => void;
    let flushed = false;
    a.close = async () => { throw new Error("SDK close failed"); };
    b.close = async () => { await new Promise<void>((resolve) => { release = resolve; }); flushed = true; };
    const closing = runtime.close();
    assert.equal(runtime.close(), closing);
    const result = assert.rejects(closing, (error) => {
      assert.equal(flushed, true);
      return error instanceof AggregateError && error.errors.length === 1;
    });
    release();
    await result;
    assert.equal(a.listenerCount("exit"), 0);
    assert.equal(b.listenerCount("liveEvent"), 0);
  });

  it("cancels startup during shutdown and closes the owned instance once", async () => {
    const provider = new TestProvider();
    let rejectStart!: (error: Error) => void;
    provider.start = () => new Promise<void>((_, reject) => { rejectStart = reject; });
    provider.close = async () => { provider.closes++; rejectStart(new Error("Stopped")); };
    const runtime = runtimeFor({ writer: () => provider });
    const starting = assert.rejects(runtime.ensure(runtime.defaultProvider), /could not start/);
    await Promise.resolve();
    await runtime.close();
    await starting;
    assert.equal(provider.closes, 1);
    assert.equal(runtime.defaultProvider.state, "closed");
    assert.equal(provider.listenerCount("liveEvent"), 0);
    const untouched = runtimeFor({ idle: () => { throw new Error("Must not construct after shutdown"); } });
    const cancelled = assert.rejects(untouched.ensure(untouched.defaultProvider), /host is stopping/);
    await untouched.close();
    await cancelled;
  });

  it("reports each provider health independently and keeps idle providers idle", async () => {
    const a = new TestProvider();
    const b = new TestProvider();
    const runtime = runtimeFor({ a: () => a, b: () => b, idle: () => { throw new Error("Must stay idle"); } });
    try {
      await runtime.ensure(runtime.providers[0]!);
      await runtime.ensure(runtime.providers[1]!);
      b.healthy = false;
      await runtime.checkHealth();
      assert.deepEqual(runtime.providers.map((entry) => entry.state), ["ready", "unavailable", "idle"]);
      b.healthy = true;
      await runtime.checkHealth();
      assert.equal(runtime.providers[1]?.state, "ready");
    } finally { await runtime.close(); }
  });
});

function makeMultiProviderConfig(): NodeConfig {
  return {
    label: "runtime-test",
    port: 0,
    token: "test-token",
    tokenSource: "generated",
    provider: {
      kind: "copilot",
      bin: "copilot",
      stateDir: null,
      allowAll: false,
      configuredModel: null,
    },
    providers: [
      {
        kind: "fake",
        latencyMs: 0,
        seedSessions: false,
        workspaceRoot: null,
        capabilityProfile: "full",
      },
      {
        kind: "copilot",
        bin: "copilot",
        stateDir: null,
        allowAll: false,
        configuredModel: null,
      },
    ],
    defaultProviderKind: "copilot",
    updateChannel: "stable",
    stateDir: "/tmp/sidemesh-runtime-test",
    workspaceRoots: [],
    terminal: { enabled: false, shell: null, requirePty: false },
    browserPreview: {
      enabled: false,
      chromePath: null,
      maxPreviews: 8,
      idleTtlMs: 3_600_000,
      frameIntervalMs: 900,
      quality: 55,
    },
    configPath: "/tmp/sidemesh-runtime-test/config.json",
    configExists: false,
  };
}
