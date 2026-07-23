import assert from "node:assert/strict";
import {
  access,
  chmod,
  mkdir,
  mkdtemp,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
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

  it("normalizes relative blob paths against a session workspace", async () => {
    const root = await tempRoot(tempRoots);
    const imageDir = nodePath.join(root, "artifacts");
    const filePath = nodePath.join(imageDir, "result.png");
    await mkdir(imageDir, { recursive: true });
    await writeFile(filePath, Buffer.from("image payload", "utf8"));
    const app = testApp(root, {
      getSessionCwd: async (sessionId) =>
        sessionId === "session-1" ? root : null,
    });
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/blob?path=${encodeURIComponent("./artifacts/../artifacts/result.png")}&sessionId=session-1`,
      );
      assert.equal(response.status, 200);
      assert.equal(await response.text(), "image payload");
    } finally {
      await close(server);
    }
  });

  it("rejects relative paths that escape a session workspace", async () => {
    const root = await tempRoot(tempRoots);
    const outsideRoot = await tempRoot(tempRoots);
    await writeFile(
      nodePath.join(outsideRoot, "secret.png"),
      Buffer.from("secret", "utf8"),
    );
    const app = testApp(root, {
      getSessionCwd: async () => root,
    });
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/blob?path=${encodeURIComponent(`../${nodePath.basename(outsideRoot)}/secret.png`)}&sessionId=session-1`,
      );
      assert.equal(response.status, 403);
    } finally {
      await close(server);
    }
  });

  it("serves audio files with a playable MIME type", async () => {
    const root = await tempRoot(tempRoots);
    const filePath = nodePath.join(root, "theme.mp3");
    await writeFile(filePath, Buffer.from("mp3 payload", "utf8"));
    const app = testApp(root);
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/blob?path=${encodeURIComponent(filePath)}`,
      );
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("content-type"), "audio/mpeg");
      assert.equal(await response.text(), "mp3 payload");
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

  it("rejects blob reads outside the resolved workspace", async () => {
    const root = await tempRoot(tempRoots);
    const outsideRoot = await tempRoot(tempRoots);
    const outsidePath = nodePath.join(outsideRoot, "secret.png");
    await writeFile(outsidePath, Buffer.from("not really an image", "utf8"));
    const app = testApp(root);
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/blob?path=${encodeURIComponent(outsidePath)}`,
      );
      assert.equal(response.status, 403);
      assert.deepEqual(await response.json(), {
        error: "path is outside any workspace",
      });
    } finally {
      await close(server);
    }
  });

  it("rejects deletion of a workspace root", async () => {
    const root = await tempRoot(tempRoots);
    const app = testApp(root);
    const server = await listen(app);
    try {
      const response = await fetch(`${baseUrl(server)}/api/fs/remove`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ path: root }),
      });
      assert.equal(response.status, 403);
      assert.deepEqual(await response.json(), {
        error: "cannot remove a workspace root",
      });
      await access(root);
    } finally {
      await close(server);
    }
  });

  it("preserves an existing file's mode during atomic writes", async () => {
    const root = await tempRoot(tempRoots);
    const filePath = nodePath.join(root, "script.sh");
    await writeFile(filePath, "old", "utf8");
    await chmod(filePath, 0o755);
    const app = testApp(root);
    const server = await listen(app);
    try {
      const response = await fetch(`${baseUrl(server)}/api/fs/write`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ path: filePath, contents: "new" }),
      });
      assert.equal(response.status, 200);
      assert.equal((await stat(filePath)).mode & 0o777, 0o755);
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

  it("fails closed when a requested session has no workspace", async () => {
    const root = await tempRoot(tempRoots);
    let listCalls = 0;
    const app = new Hono<HonoServerEnv>();
    registerFsRoutes(app, {
      listSessions: async () => {
        listCalls += 1;
        return [sessionForRoot(root)];
      },
      getSessionCwd: async () => null,
    });
    const server = await listen(app);
    try {
      const response = await fetch(
        `${baseUrl(server)}/api/fs/list?path=${encodeURIComponent(root)}&sessionId=missing-session`,
      );
      assert.equal(response.status, 403);
      assert.deepEqual(await response.json(), {
        error: "session workspace is unavailable",
      });
      assert.equal(listCalls, 0);
    } finally {
      await close(server);
    }
  });
});

function testApp(
  root: string,
  options: {
    getSessionCwd?: (sessionId: string) => Promise<string | null>;
  } = {},
): Hono<HonoServerEnv> {
  const app = new Hono<HonoServerEnv>();
  registerFsRoutes(app, {
    listSessions: async () => [sessionForRoot(root)],
    getSessionCwd: options.getSessionCwd,
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
