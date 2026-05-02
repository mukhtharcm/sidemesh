import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { createServer } from "node:net";
import { after, describe, it } from "node:test";

import type { FakeCapabilityProfile } from "./types.js";

const TOKEN = "fake-profile-smoke";
const PROFILE_EXPECTATIONS: ProfileExpectation[] = [
  {
    profile: "full",
    capabilities: {
      "input.imageUrl": true,
      "input.skills": true,
      "configuration.models": true,
      "configuration.profiles": true,
      "configuration.skills": true,
      "configuration.prompts": true,
      "runtimeControls.model": true,
      "runtimeControls.mode": false,
      "runtimeControls.approvalPolicy": true,
      "workspace.filesystem": true,
      "workspace.remoteGitDiff": true,
      "sessions.interrupt": true,
      "sessions.archive": true,
      "sessions.compact": true,
    },
    routes: {
      models: 200,
      profiles: 200,
      skills: 200,
      prompts: 200,
      fsList: 200,
      createWithModel: 201,
      createWithImage: 201,
    },
  },
  {
    profile: "chat-only",
    capabilities: {
      "input.imageUrl": false,
      "input.skills": false,
      "configuration.models": false,
      "configuration.profiles": false,
      "configuration.skills": false,
      "configuration.prompts": false,
      "runtimeControls.model": false,
      "runtimeControls.mode": false,
      "runtimeControls.approvalPolicy": false,
      "workspace.filesystem": false,
      "workspace.remoteGitDiff": false,
      "sessions.interrupt": true,
      "sessions.archive": true,
      "sessions.compact": true,
    },
    routes: {
      models: 501,
      profiles: 501,
      skills: 501,
      prompts: 501,
      fsList: 200,
      createWithModel: 501,
      createWithImage: 501,
    },
  },
  {
    profile: "no-files",
    capabilities: {
      "input.imageUrl": true,
      "input.skills": true,
      "configuration.models": true,
      "configuration.profiles": true,
      "configuration.skills": true,
      "configuration.prompts": true,
      "runtimeControls.model": true,
      "runtimeControls.mode": false,
      "runtimeControls.approvalPolicy": true,
      "workspace.filesystem": false,
      "workspace.remoteGitDiff": false,
      "sessions.interrupt": true,
      "sessions.archive": true,
      "sessions.compact": true,
    },
    routes: {
      models: 200,
      profiles: 200,
      skills: 200,
      prompts: 200,
      fsList: 200,
      createWithModel: 201,
      createWithImage: 201,
    },
  },
  {
    profile: "no-model-controls",
    capabilities: {
      "input.imageUrl": true,
      "input.skills": true,
      "configuration.models": false,
      "configuration.profiles": false,
      "configuration.skills": true,
      "configuration.prompts": true,
      "runtimeControls.model": false,
      "runtimeControls.mode": false,
      "runtimeControls.approvalPolicy": true,
      "workspace.filesystem": true,
      "workspace.remoteGitDiff": true,
      "sessions.interrupt": true,
      "sessions.archive": true,
      "sessions.compact": true,
    },
    routes: {
      models: 501,
      profiles: 501,
      skills: 200,
      prompts: 200,
      fsList: 200,
      createWithModel: 501,
      createWithImage: 201,
    },
  },
  {
    profile: "no-approvals",
    capabilities: {
      "input.imageUrl": true,
      "input.skills": true,
      "configuration.models": true,
      "configuration.profiles": true,
      "configuration.skills": true,
      "configuration.prompts": true,
      "runtimeControls.model": true,
      "runtimeControls.mode": false,
      "runtimeControls.approvalPolicy": false,
      "workspace.filesystem": true,
      "workspace.remoteGitDiff": true,
      "sessions.interrupt": true,
      "sessions.archive": true,
      "sessions.compact": true,
    },
    routes: {
      models: 200,
      profiles: 200,
      skills: 200,
      prompts: 200,
      fsList: 200,
      createWithModel: 201,
      createWithImage: 201,
    },
  },
  {
    profile: "minimal",
    capabilities: {
      "input.imageUrl": false,
      "input.skills": false,
      "configuration.models": false,
      "configuration.profiles": false,
      "configuration.skills": false,
      "configuration.prompts": false,
      "runtimeControls.model": false,
      "runtimeControls.mode": false,
      "runtimeControls.approvalPolicy": false,
      "workspace.filesystem": false,
      "workspace.remoteGitDiff": false,
      "sessions.interrupt": false,
      "sessions.archive": false,
      "sessions.compact": false,
    },
    routes: {
      models: 501,
      profiles: 501,
      skills: 501,
      prompts: 501,
      fsList: 200,
      createWithModel: 501,
      createWithImage: 501,
    },
  },
];

interface ProfileExpectation {
  profile: FakeCapabilityProfile;
  capabilities: Record<string, boolean>;
  routes: {
    models: number;
    profiles: number;
    skills: number;
    prompts: number;
    fsList: number;
    createWithModel: number;
    createWithImage: number;
  };
}

interface RunningDaemon {
  baseUrl: string;
  process: ChildProcessWithoutNullStreams;
  output(): string;
  close(): Promise<void>;
}

describe("fake provider capability profile API smoke", () => {
  const tempRoots: string[] = [];

  after(async () => {
    await Promise.all(
      tempRoots.map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  for (const expectation of PROFILE_EXPECTATIONS) {
    it(`advertises and gates ${expectation.profile}`, async () => {
      const workspaceRoot = await tempRoot(tempRoots);
      const stateDir = await tempRoot(tempRoots);
      const daemon = await startFakeDaemon({
        profile: expectation.profile,
        workspaceRoot,
        stateDir,
      });
      try {
        const node = await getJson(daemon.baseUrl, "/api/node");
        assert.equal(node.provider, "fake");
        assert.match(
          asString(node.providerVersion),
          new RegExp(`\\(${expectation.profile}\\)$`),
        );

        for (const [path, supported] of Object.entries(
          expectation.capabilities,
        )) {
          assert.equal(
            readCapability(node.providerCapabilities, path),
            supported,
            path,
          );
        }

        assert.equal(
          await postStatus(daemon.baseUrl, "/api/sessions/create", {
            cwd: workspaceRoot,
            prompt: "baseline profile smoke",
          }),
          201,
        );

        assert.equal(
          await status(daemon.baseUrl, "/api/models"),
          expectation.routes.models,
        );
        assert.equal(
          await status(daemon.baseUrl, "/api/profiles"),
          expectation.routes.profiles,
        );
        assert.equal(
          await status(
            daemon.baseUrl,
            `/api/skills?cwd=${encodeURIComponent(workspaceRoot)}`,
          ),
          expectation.routes.skills,
        );
        assert.equal(
          await status(
            daemon.baseUrl,
            `/api/prompts?cwd=${encodeURIComponent(workspaceRoot)}`,
          ),
          expectation.routes.prompts,
        );
        assert.equal(
          await status(
            daemon.baseUrl,
            `/api/fs/list?path=${encodeURIComponent(workspaceRoot)}`,
          ),
          expectation.routes.fsList,
        );

        assert.equal(
          await postStatus(daemon.baseUrl, "/api/sessions/create", {
            cwd: workspaceRoot,
            prompt: "profile smoke with model",
            model: "fake-balanced",
          }),
          expectation.routes.createWithModel,
        );
        assert.equal(
          await postStatus(daemon.baseUrl, "/api/sessions/create", {
            cwd: workspaceRoot,
            input: [
              {
                type: "image",
                url: "data:image/png;base64,ZmFrZQ==",
              },
            ],
          }),
          expectation.routes.createWithImage,
        );
      } catch (error) {
        throw new Error(
          `Profile ${expectation.profile} smoke failed.\n${daemon.output()}\n${String(error)}`,
        );
      } finally {
        await daemon.close();
      }
    });
  }
});

async function startFakeDaemon(options: {
  profile: FakeCapabilityProfile;
  workspaceRoot: string;
  stateDir: string;
}): Promise<RunningDaemon> {
  const port = await freePort();
  const child = spawn(process.execPath, ["--import", "tsx", "src/index.ts"], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      SIDEMESH_PROVIDER: "fake",
      SIDEMESH_PROVIDERS: "fake",
      SIDEMESH_FAKE_CAPABILITY_PROFILE: options.profile,
      SIDEMESH_FAKE_LATENCY_MS: "0",
      SIDEMESH_FAKE_SEED: "0",
      SIDEMESH_FAKE_WORKSPACE_ROOT: options.workspaceRoot,
      SIDEMESH_STATE_DIR: options.stateDir,
      SIDEMESH_LABEL: `fake-${options.profile}`,
      SIDEMESH_PORT: String(port),
      SIDEMESH_TOKEN: TOKEN,
    },
  });
  let output = "";
  child.stdout.on("data", (chunk: Buffer) => {
    output += chunk.toString("utf8");
  });
  child.stderr.on("data", (chunk: Buffer) => {
    output += chunk.toString("utf8");
  });

  const baseUrl = `http://127.0.0.1:${port}`;
  await waitForHealth(baseUrl, child, () => output);

  return {
    baseUrl,
    process: child,
    output: () => output,
    close: () => stopProcess(child),
  };
}

async function waitForHealth(
  baseUrl: string,
  child: ChildProcessWithoutNullStreams,
  output: () => string,
): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(
        `daemon exited early with ${child.exitCode}\n${output()}`,
      );
    }
    try {
      const response = await fetch(`${baseUrl}/healthz`);
      if (response.ok) {
        return;
      }
    } catch {
      // Keep polling until the daemon binds its port.
    }
    await sleep(50);
  }
  throw new Error(`daemon did not become healthy\n${output()}`);
}

async function stopProcess(
  child: ChildProcessWithoutNullStreams,
): Promise<void> {
  if (child.exitCode !== null) {
    return;
  }
  const exited = new Promise<void>((resolve) => {
    child.once("exit", () => resolve());
  });
  child.kill("SIGTERM");
  const timedOut = await Promise.race([
    exited.then(() => false),
    sleep(2_000).then(() => true),
  ]);
  if (timedOut && child.exitCode === null) {
    child.kill("SIGKILL");
    await exited;
  }
}

async function getJson(
  baseUrl: string,
  path: string,
): Promise<Record<string, unknown>> {
  const response = await request(baseUrl, path);
  assert.equal(response.status, 200, `${path} status`);
  const body = (await response.json()) as unknown;
  assert.equal(typeof body, "object");
  assert.notEqual(body, null);
  return body as Record<string, unknown>;
}

async function status(baseUrl: string, path: string): Promise<number> {
  return (await request(baseUrl, path)).status;
}

async function postStatus(
  baseUrl: string,
  path: string,
  body: Record<string, unknown>,
): Promise<number> {
  return (
    await request(baseUrl, path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    })
  ).status;
}

function request(
  baseUrl: string,
  path: string,
  init: RequestInit = {},
): Promise<Response> {
  return fetch(`${baseUrl}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      ...init.headers,
    },
  });
}

function readCapability(raw: unknown, path: string): boolean {
  const [section, feature] = path.split(".");
  assert.ok(section);
  assert.ok(feature);
  const capabilities =
    raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const group = capabilities[section];
  if (!group || typeof group !== "object") {
    return false;
  }
  return (group as Record<string, unknown>)[feature] === true;
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

async function tempRoot(roots: string[]): Promise<string> {
  const root = await mkdtemp(
    nodePath.join(tmpdir(), "sidemesh-profile-smoke-"),
  );
  roots.push(root);
  return root;
}

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() =>
          reject(new Error("failed to allocate a local port")),
        );
        return;
      }
      const { port } = address;
      server.close(() => resolve(port));
    });
    server.on("error", reject);
  });
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
