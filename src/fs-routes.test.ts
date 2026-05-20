import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { after, describe, it } from "node:test";

import { getRequestListener } from "@hono/node-server";
import { Hono } from "hono";

import { registerFsRoutes } from "./fs-routes.js";
import type { HonoServerEnv } from "./hono-route-adapter.js";
import type { SessionSummary } from "./types.js";

describe("filesystem routes", () => {
  const tempRoots: string[] = [];

  after(async () => {
    await Promise.all(
      tempRoots.map((root) => rm(root, { recursive: true, force: true })),
    );
  });

  it("returns bounded previews for files larger than the preview cap", async () => {
    const root = await tempRoot(tempRoots);
    const filePath = nodePath.join(root, "large.txt");
    await writeFile(filePath, "a".repeat(3 * 1024 * 1024), "utf8");
    const app = testApp(root);
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/read?path=${encodeURIComponent(filePath)}`,
      );
      assert.equal(response.status, 200);
      const body = (await response.json()) as {
        size: number;
        binary: boolean;
        truncated: boolean;
        contents: string;
      };

      assert.equal(body.size, 3 * 1024 * 1024);
      assert.equal(body.binary, false);
      assert.equal(body.truncated, true);
      assert.equal(body.contents.length, 2 * 1024 * 1024);
    } finally {
      await close(server);
    }
  });

  it("serves byte ranges for blob reads", async () => {
    const root = await tempRoot(tempRoots);
    const filePath = nodePath.join(root, "clip.mp4");
    await writeFile(filePath, Buffer.from("hello world", "utf8"));
    const app = testApp(root);
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/blob?path=${encodeURIComponent(filePath)}`,
        {
          headers: {
            Range: "bytes=2-5",
          },
        },
      );
      assert.equal(response.status, 206);
      assert.equal(response.headers.get("accept-ranges"), "bytes");
      assert.equal(response.headers.get("content-type"), "video/mp4");
      assert.equal(response.headers.get("content-range"), "bytes 2-5/11");
      assert.equal(response.headers.get("content-length"), "4");
      assert.equal(await response.text(), "llo ");
    } finally {
      await close(server);
    }
  });

  it("rejects unsatisfiable blob ranges", async () => {
    const root = await tempRoot(tempRoots);
    const filePath = nodePath.join(root, "clip.mp4");
    await writeFile(filePath, Buffer.from("hello world", "utf8"));
    const app = testApp(root);
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/blob?path=${encodeURIComponent(filePath)}`,
        {
          headers: {
            Range: "bytes=40-80",
          },
        },
      );
      assert.equal(response.status, 416);
      assert.equal(response.headers.get("content-range"), "bytes */11");
    } finally {
      await close(server);
    }
  });

  it("caches workspace roots across adjacent filesystem requests", async () => {
    const root = await tempRoot(tempRoots);
    await writeFile(nodePath.join(root, "a.txt"), "a", "utf8");
    let listCalls = 0;
    const app = new Hono<HonoServerEnv>();
    registerFsRoutes(app, {
      listSessions: async () => {
        listCalls += 1;
        return [sessionForRoot(root)];
      },
    });
    const server = await listen(app);
    try {
      for (let i = 0; i < 2; i += 1) {
        const response = await fetch(
          `${baseUrl(server)}/api/fs/list?path=${encodeURIComponent(root)}`,
        );
        assert.equal(response.status, 200);
      }
      assert.equal(listCalls, 1);
    } finally {
      await close(server);
    }
  });

  it("uses session cwd without listing all sessions when sessionId is provided", async () => {
    const root = await tempRoot(tempRoots);
    await writeFile(nodePath.join(root, "session.txt"), "a", "utf8");
    let listCalls = 0;
    let cwdCalls = 0;
    const app = new Hono<HonoServerEnv>();
    registerFsRoutes(app, {
      listSessions: async () => {
        listCalls += 1;
        return [];
      },
      getSessionCwd: async (sessionId) => {
        cwdCalls += 1;
        return sessionId === "session-a" ? root : null;
      },
    });
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/list?path=${encodeURIComponent(root)}&sessionId=session-a`,
      );
      assert.equal(response.status, 200);
      assert.equal(listCalls, 0);
      assert.equal(cwdCalls, 1);
    } finally {
      await close(server);
    }
  });
});

function testApp(root: string): Hono<HonoServerEnv> {
  const app = new Hono<HonoServerEnv>();
  registerFsRoutes(app, {
    listSessions: async () => [sessionForRoot(root)],
  });
  return app;
}

function sessionForRoot(root: string): SessionSummary {
  return {
    id: "test-session",
    title: "Test",
    preview: "",
    cwd: root,
    createdAt: 0,
    updatedAt: 0,
    source: "test",
    provider: "test",
    status: "idle",
    rolloutPath: null,
    runtime: null,
    gitInfo: null,
  };
}

async function tempRoot(tempRoots: string[]): Promise<string> {
  const root = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-fs-"));
  tempRoots.push(root);
  return root;
}

async function listen(app: Hono<HonoServerEnv>): Promise<Server> {
  const server = createServer(getRequestListener(app.fetch));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return server;
}

async function close(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function baseUrl(server: Server): string {
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return `http://127.0.0.1:${address.port}`;
}
