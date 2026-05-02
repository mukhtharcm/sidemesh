import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import http from "node:http";

import { startServer, type RunningServer } from "./server.js";
import type { FakeCapabilityProfile, NodeConfig } from "./types.js";
import { FakeAgentProvider } from "./fake-provider.js";

function makeConfig(
  stateDir: string,
  options: {
    latencyMs?: number;
    capabilityProfile?: FakeCapabilityProfile;
  } = {},
): NodeConfig {
  const token = "test-token-" + Math.random().toString(36).slice(2);
  const provider = {
    kind: "fake" as const,
    latencyMs: options.latencyMs ?? 0,
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
    stateDir,
    terminal: { enabled: false, shell: null, requirePty: false },
    portForwarding: { enabled: false, allowNonLoopbackTargets: false },
    browserPreview: { enabled: false, chromePath: null, maxPreviews: 8, idleTtlMs: 3_600_000, frameIntervalMs: 900, quality: 55 },
    configPath: nodePath.join(stateDir, "config.json"),
    configExists: false,
  };
}

function request(options: http.RequestOptions & { body?: string }): Promise<{ statusCode: number; body: unknown }> {
  return new Promise((resolve, reject) => {
    const req = http.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => {
        try {
          resolve({ statusCode: res.statusCode ?? 0, body: data ? JSON.parse(data) : null });
        } catch {
          resolve({ statusCode: res.statusCode ?? 0, body: data });
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

async function poll(
  fn: () => Promise<boolean>,
  timeoutMs = 1_500,
  intervalMs = 25,
): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (await fn()) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error("timed out waiting for condition");
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
});

describe("provider metadata and capability gating", () => {
  it("reports the actual configured provider capabilities", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-node-test-"));
    await withServer(
      makeConfig(stateDir, { capabilityProfile: "no-files" }),
      async (server, config) => {
        const res = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/node",
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(res.statusCode, 200);
        const supported = ((res.body as any).supportedProviders ?? [])[0];
        assert.equal(supported?.kind, "fake");
        assert.equal((res.body as any).searchSessions, false);
        assert.equal(supported?.capabilities?.workspace?.filesystem, false);
        assert.equal(supported?.capabilities?.sessions?.searchSessions, false);
      },
    );
  });

  it("returns 501 when session search is unsupported", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-search-test-"));
    await withServer(makeConfig(stateDir), async (server, config) => {
      const res = await request({
        hostname: "127.0.0.1",
        port: server.port,
        path: "/api/sessions/search?q=hello",
        method: "GET",
        headers: { Authorization: "Bearer " + config.token },
      });
      assert.equal(res.statusCode, 501);
      assert.equal(
        (res.body as any).error,
        "Fake Test Provider does not support session search",
      );
    });
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

  it("normalizes completed, interrupted, and unloaded session states", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-server-status-normalized-"));
    await withServer(
      makeConfig(stateDir, { latencyMs: 120 }),
      async (server, config) => {
        const createRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/sessions/create",
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            cwd: "/tmp",
            input: [{ type: "text", text: "hello" }],
          }),
        });
        assert.equal(createRes.statusCode, 201);
        const sessionId = (createRes.body as any).session.id as string;

        await poll(async () => {
          const statusRes = await request({
            hostname: "127.0.0.1",
            port: server.port,
            path: `/api/sessions/${sessionId}/status`,
            method: "GET",
            headers: { Authorization: "Bearer " + config.token },
          });
          return (statusRes.body as any).status === "completed";
        });

        const completedStatus = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${sessionId}/status`,
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(completedStatus.statusCode, 200);
        assert.equal((completedStatus.body as any).status, "completed");
        assert.equal((completedStatus.body as any).loaded, true);
        assert.equal((completedStatus.body as any).isRunning, false);

        const slowCreateRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: "/api/sessions/create",
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.token,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            cwd: "/tmp",
            input: [{ type: "text", text: "slow" }],
          }),
        });
        assert.equal(slowCreateRes.statusCode, 201);
        const slowSessionId = (slowCreateRes.body as any).session.id as string;

        const stopRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${slowSessionId}/stop`,
          method: "POST",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(stopRes.statusCode, 200);

        const interruptedStatus = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${slowSessionId}/status`,
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(interruptedStatus.statusCode, 200);
        assert.equal((interruptedStatus.body as any).status, "interrupted");
        assert.equal((interruptedStatus.body as any).loaded, true);
        assert.equal((interruptedStatus.body as any).isRunning, false);

        const archiveRes = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${sessionId}/archive`,
          method: "POST",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(archiveRes.statusCode, 200);

        const unloadedStatus = await request({
          hostname: "127.0.0.1",
          port: server.port,
          path: `/api/sessions/${sessionId}/status`,
          method: "GET",
          headers: { Authorization: "Bearer " + config.token },
        });
        assert.equal(unloadedStatus.statusCode, 200);
        assert.equal((unloadedStatus.body as any).status, "unloaded");
        assert.equal((unloadedStatus.body as any).loaded, false);
        assert.equal((unloadedStatus.body as any).threadStatus, "loaded");
      },
    );
  });
});
