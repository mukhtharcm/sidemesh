import {
  mkdtemp,
  mkdir,
  rm,
  utimes,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";

import { Hono } from "hono";
import { afterEach, describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  artifactReferencesMatch,
  registerSessionArtifactRoutes,
} from "./session-artifacts.js";
import type { HonoServerEnv } from "./hono-route-adapter.js";

const temporaryRoots: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((path) => rm(path, { recursive: true })),
  );
});

describe("session artifact routes", () => {
  it("publishes a referenced temporary image through an opaque id", async () => {
    const root = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-artifact-"));
    temporaryRoots.push(root);
    const source = nodePath.join(root, "validation.png");
    const png = Buffer.from([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3,
    ]);
    await writeFile(source, png);
    const app = buildApp(root, async (_sessionId, candidate) =>
      candidate.includes("validation.png"),
    );

    const publish = await app.request("/api/sessions/s1/artifacts", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ source }),
    });
    assert.equal(publish.status, 200);
    const payload = (await publish.json()) as { artifactId: string };
    assert.match(payload.artifactId, /^[0-9a-f-]+\.png$/);

    const response = await app.request(
      `/api/session-artifacts/${payload.artifactId}`,
    );
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "image/png");
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), png);
  });

  it("rejects unreferenced and non-temporary files", async () => {
    const root = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-artifact-"));
    temporaryRoots.push(root);
    const source = nodePath.join(root, "validation.png");
    await writeFile(
      source,
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    );
    const unreferenced = buildApp(root, async () => false);
    const denied = await unreferenced.request("/api/sessions/s1/artifacts", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ source }),
    });
    assert.equal(denied.status, 403);

    const state = nodePath.join(process.cwd(), ".test-artifacts");
    temporaryRoots.push(state);
    await mkdir(state, { recursive: true });
    const outside = nodePath.join(state, "outside.png");
    await writeFile(
      outside,
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    );
    const app = buildApp(root, async () => true);
    const blocked = await app.request("/api/sessions/s1/artifacts", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ source: outside }),
    });
    assert.equal(blocked.status, 403);
  });

  it("normalizes file references and expires old artifacts on read", async () => {
    const root = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-artifact-"));
    temporaryRoots.push(root);
    const source = nodePath.join(root, "validation image.png");
    await writeFile(
      source,
      Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    );
    const referenced = `${new URL(`file://${source.replaceAll(" ", "%20")}`)}?preview=1`;
    const app = buildApp(root, async (_sessionId, candidate) =>
      artifactReferencesMatch(candidate, referenced),
    );
    const publish = await app.request("/api/sessions/s1/artifacts", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ source }),
    });
    assert.equal(publish.status, 200);
    const payload = (await publish.json()) as { artifactId: string };
    const artifactPath = nodePath.join(
      root,
      "session-artifacts",
      payload.artifactId,
    );
    const expired = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000);
    await utimes(artifactPath, expired, expired);

    const response = await app.request(
      `/api/session-artifacts/${payload.artifactId}`,
    );
    assert.equal(response.status, 404);
  });
});

function buildApp(
  stateDir: string,
  isReferenced: (sessionId: string, source: string) => Promise<boolean>,
): Hono<HonoServerEnv> {
  const app = new Hono<HonoServerEnv>();
  registerSessionArtifactRoutes(app, { stateDir, isReferenced });
  return app;
}
