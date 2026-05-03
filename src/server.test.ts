import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import http from "node:http";

import { startServer, type RunningServer } from "./server.js";
import type { NodeConfig } from "./types.js";
import { FakeAgentProvider } from "./fake-provider.js";

function makeConfig(stateDir: string): NodeConfig {
  const token = "test-token-" + Math.random().toString(36).slice(2);
  return {
    label: "test",
    port: 0,
    token,
    tokenSource: "generated",
    provider: { kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" },
    providers: [{ kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" }],
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
});
