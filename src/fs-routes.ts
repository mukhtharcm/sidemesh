import { Buffer } from "node:buffer";
import { randomUUID } from "node:crypto";
import { createReadStream, watch, type FSWatcher } from "node:fs";
import type { IncomingMessage } from "node:http";
import {
  copyFile,
  cp,
  lstat,
  mkdir,
  open,
  readdir,
  realpath,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import { Readable, type Duplex } from "node:stream";

import type { Hono } from "hono";
import type { WebSocket, WebSocketServer } from "ws";

import {
  collectWorkspaceRoots,
  resolveWorkspacePath,
  WorkspaceAccessError,
} from "./workspace-scope.js";
import { clearFsSearchCache, searchFiles } from "./fs-search.js";
import type { SessionSummary } from "./types.js";
import {
  buildJsonRouteRequest,
  jsonRoute,
  type HonoServerEnv,
  type JsonRouteRequest,
  type JsonRouteResponse,
} from "./hono-route-adapter.js";

const READ_SOFT_CAP_BYTES = 2 * 1024 * 1024; // 2 MiB — UX preview cap.
const WRITE_SOFT_CAP_BYTES = 4 * 1024 * 1024; // 4 MiB — payload safety cap.
const WORKSPACE_ROOTS_TTL_MS = 5_000;

interface FsRoutesOptions {
  listSessions: () => Promise<SessionSummary[]>;
  getSessionCwd?: (sessionId: string) => Promise<string | null>;
}

export function registerFsRoutes(app: Hono<HonoServerEnv>, opts: FsRoutesOptions): void {
  const fallbackResolveRoots = createWorkspaceRootsResolver(opts.listSessions);

  app.get(
    "/api/fs/list",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const target = await resolveIncomingPath(
        request.query.path,
        resolveRoots,
      );
      const entries = (await readdir(target, { withFileTypes: true }))
        .map((entry) => ({
          name: entry.name,
          path: path.join(target, entry.name),
          isDirectory: entry.isDirectory(),
          isFile: entry.isFile(),
        }))
        .sort((a, b) => {
          if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.localeCompare(b.name);
        });
      response.json({ path: target, entries });
    }),
  );

  app.get(
    "/api/fs/metadata",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const target = await resolveIncomingPath(
        request.query.path,
        resolveRoots,
      );
      response.json(await buildMetadata(target));
    }),
  );

  app.get(
    "/api/fs/read",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const target = await resolveIncomingPath(
        request.query.path,
        resolveRoots,
      );
      const meta = await buildMetadata(target);
      if (!meta.isFile) {
        response.status(400).json({ error: "path is not a regular file" });
        return;
      }
      const bytes = await readFilePreview(target, meta.size);
      const binary = isBinary(bytes);
      const truncated = meta.size > READ_SOFT_CAP_BYTES;
      if (binary) {
        response.json({
          path: target,
          size: meta.size,
          binary: true,
          truncated,
          modifiedAtMs: meta.modifiedAtMs,
          mimeHint: guessMime(target),
          encoding: "none",
          contents: "",
        });
        return;
      }
      const preview = truncated
        ? bytes.subarray(0, READ_SOFT_CAP_BYTES)
        : bytes;
      response.json({
        path: target,
        size: meta.size,
        binary: false,
        truncated,
        modifiedAtMs: meta.modifiedAtMs,
        mimeHint: guessMime(target),
        encoding: "utf8",
        contents: preview.toString("utf8"),
      });
    }),
  );

  app.get("/api/fs/blob", async (c) => {
    const request = await buildJsonRouteRequest(c);
    const resolveRoots = createRequestRootsResolver(
      request,
      opts,
      fallbackResolveRoots,
    );
    const target = await resolveIncomingBlobPath(
      request.query.path,
      resolveRoots,
    );
    const info = await stat(target);
    c.header("Content-Type", guessMime(target));
    c.header("Content-Length", String(info.size));
    c.header("Cache-Control", "private, max-age=60");
    c.header(
      "Content-Disposition",
      `inline; filename="${path.basename(target).replaceAll('"', "")}"`,
    );
    return c.body(
      Readable.toWeb(createReadStream(target)) as ReadableStream,
      200,
    );
  });

  app.post(
    "/api/fs/write",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const target = await resolveIncomingPath(
        request.body?.path,
        resolveRoots,
        {
          allowMissing: true,
        },
      );
      const contents = request.body?.contents;
      if (typeof contents !== "string") {
        response.status(400).json({ error: "contents must be a string" });
        return;
      }
      const buffer = Buffer.from(contents, "utf8");
      if (buffer.byteLength > WRITE_SOFT_CAP_BYTES) {
        response.status(413).json({ error: "payload too large" });
        return;
      }
      await writeFile(target, buffer);
      clearFsSearchCache();
      response.json({ path: target, bytes: buffer.byteLength });
    }),
  );

  app.post(
    "/api/fs/createDir",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const target = await resolveIncomingPath(
        request.body?.path,
        resolveRoots,
        {
          allowMissing: true,
        },
      );
      const recursive = request.body?.recursive !== false;
      await mkdir(target, { recursive });
      clearFsSearchCache();
      response.json({ path: target });
    }),
  );

  app.post(
    "/api/fs/remove",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const target = await resolveIncomingPath(
        request.body?.path,
        resolveRoots,
      );
      const recursive = request.body?.recursive !== false;
      const force = request.body?.force !== false;
      await rm(target, { recursive, force });
      clearFsSearchCache();
      response.json({ path: target });
    }),
  );

  app.post(
    "/api/fs/copy",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const source = await resolveIncomingPath(
        request.body?.sourcePath,
        resolveRoots,
      );
      const destination = await resolveIncomingPath(
        request.body?.destinationPath,
        resolveRoots,
        { allowMissing: true },
      );
      const recursive = request.body?.recursive === true;
      const sourceMeta = await buildMetadata(source);
      if (sourceMeta.isDirectory) {
        if (!recursive) {
          response
            .status(400)
            .json({ error: "recursive must be true when copying a directory" });
          return;
        }
        await cp(source, destination, { recursive: true });
      } else {
        await copyFile(source, destination);
      }
      clearFsSearchCache();
      response.json({ sourcePath: source, destinationPath: destination });
    }),
  );

  app.post(
    "/api/fs/search",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      const roots = await resolveRoots();
      const query = asString(request.body?.query) ?? "";
      const limit = typeof request.body?.limit === "number"
        ? Math.max(1, Math.min(200, request.body.limit))
        : undefined;
      const results = await searchFiles(query, roots, { limit });
      response.json({ files: results });
    }),
  );

  app.get(
    "/api/fs/roots",
    asyncRoute(async (request, response) => {
      const resolveRoots = createRequestRootsResolver(
        request,
        opts,
        fallbackResolveRoots,
      );
      response.json({ roots: await resolveRoots() });
    }),
  );
}

async function resolveIncomingPath(
  raw: unknown,
  roots: () => Promise<string[]>,
  options: { allowMissing?: boolean } = {},
): Promise<string> {
  if (typeof raw !== "string") {
    throw new WorkspaceAccessError("path is required", 400);
  }
  return resolveWorkspacePath(raw, await roots(), options);
}

async function resolveIncomingBlobPath(
  raw: unknown,
  roots: () => Promise<string[]>,
): Promise<string> {
  try {
    return await resolveIncomingPath(raw, roots);
  } catch (error) {
    if (typeof raw !== "string" || !path.isAbsolute(raw)) {
      throw error;
    }

    const canonical = await realpath(raw).catch((realpathError) => {
      throw new WorkspaceAccessError(
        `cannot resolve path: ${realpathError instanceof Error ? realpathError.message : String(realpathError)}`,
      );
    });
    const info = await stat(canonical).catch((statError) => {
      throw new WorkspaceAccessError(
        `cannot stat path: ${statError instanceof Error ? statError.message : String(statError)}`,
      );
    });
    if (!info.isFile()) {
      throw new WorkspaceAccessError("path is not a regular file", 400);
    }
    if (!guessMime(canonical).startsWith("image/")) {
      throw new WorkspaceAccessError(
        "blob route only supports image files",
        403,
      );
    }

    return canonical;
  }
}

function asyncRoute(
  handler: (
    request: JsonRouteRequest,
    response: JsonRouteResponse,
  ) => Promise<void>,
): ReturnType<typeof jsonRoute> {
  return jsonRoute(handler);
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

interface WatchRecord {
  ws: WebSocket;
  userWatchId: string;
  path: string;
  watcher: FSWatcher;
}

export class FsWatchRegistry {
  private readonly records = new Map<string, WatchRecord>();
  private readonly byClient = new WeakMap<WebSocket, Set<string>>();

  public async subscribe(
    ws: WebSocket,
    params: { path: string; userWatchId: string; roots: string[] },
  ): Promise<{ watchId: string; path: string }> {
    const resolved = await resolveWorkspacePath(params.path, params.roots);
    const metadata = await buildMetadata(resolved);
    const watchId = randomUUID();
    const watcher = watch(
      resolved,
      { persistent: false },
      (_eventType, filename) => {
        const changedPath = this.resolveChangedPath(
          resolved,
          metadata.isDirectory,
          asString(filename?.toString()),
        );
        this.deliver(watchId, changedPath ? [changedPath] : [resolved]);
      },
    );
    watcher.on("error", () => {
      void this.unsubscribe(ws, watchId);
    });
    this.records.set(watchId, {
      ws,
      userWatchId: params.userWatchId,
      path: resolved,
      watcher,
    });
    const set = this.byClient.get(ws) ?? new Set<string>();
    set.add(watchId);
    this.byClient.set(ws, set);
    return { watchId, path: resolved };
  }

  public async unsubscribe(ws: WebSocket, watchId: string): Promise<void> {
    const record = this.records.get(watchId);
    if (!record || record.ws !== ws) return;
    this.records.delete(watchId);
    this.byClient.get(ws)?.delete(watchId);
    record.watcher.close();
  }

  public async disconnect(ws: WebSocket): Promise<void> {
    const set = this.byClient.get(ws);
    if (!set) return;
    this.byClient.delete(ws);
    for (const watchId of set) {
      const record = this.records.get(watchId);
      this.records.delete(watchId);
      record?.watcher.close();
    }
  }

  public deliver(watchId: string, changedPaths: string[]): void {
    const record = this.records.get(watchId);
    if (!record) return;
    const payload = JSON.stringify({
      type: "fs_changed",
      watchId: record.userWatchId,
      path: record.path,
      changedPaths,
    });
    try {
      record.ws.send(payload);
    } catch {
      // swallow
    }
  }

  private resolveChangedPath(
    watchedPath: string,
    isDirectory: boolean,
    filename: string | null,
  ): string | null {
    if (!filename) {
      return watchedPath;
    }
    return isDirectory ? path.join(watchedPath, filename) : watchedPath;
  }
}

export function attachFsLiveSocket(
  ws: WebSocket,
  registry: FsWatchRegistry,
  opts: {
    listSessions: () => Promise<SessionSummary[]>;
    getSessionCwd?: (sessionId: string) => Promise<string | null>;
    sessionId?: string | null;
  },
): void {
  const resolveRoots = createSocketRootsResolver(opts);
  ws.on("message", async (raw) => {
    let message: Record<string, unknown>;
    try {
      const parsed = JSON.parse(raw.toString()) as unknown;
      message = parsed && typeof parsed === "object" && !Array.isArray(parsed)
        ? (parsed as Record<string, unknown>)
        : {};
    } catch {
      sendJson(ws, { type: "error", message: "invalid json" });
      return;
    }
    const messageType = message.type;
    try {
      if (messageType === "subscribe") {
        const { watchId, path: resolved } = await registry.subscribe(ws, {
          path: String(message.path ?? ""),
          userWatchId: String(message.id ?? ""),
          roots: await resolveRoots(),
        });
        sendJson(ws, {
          type: "subscribed",
          id: message.id,
          watchId,
          path: resolved,
        });
      } else if (messageType === "unsubscribe") {
        const watchId = String(message.watchId ?? "");
        await registry.unsubscribe(ws, watchId);
        sendJson(ws, { type: "unsubscribed", watchId });
      } else {
        sendJson(ws, { type: "error", message: `unknown type ${messageType}` });
      }
    } catch (error) {
      sendJson(ws, {
        type: "error",
        id: message?.id,
        message: error instanceof Error ? error.message : String(error),
      });
    }
  });
  ws.on("close", () => {
    void registry.disconnect(ws);
  });
}

function sendJson(ws: WebSocket, payload: unknown): void {
  try {
    ws.send(JSON.stringify(payload));
  } catch {
    // swallow
  }
}

export function attachWatchUpgrade(
  wsServer: WebSocketServer,
  registry: FsWatchRegistry,
  opts: {
    listSessions: () => Promise<SessionSummary[]>;
    getSessionCwd?: (sessionId: string) => Promise<string | null>;
  },
) {
  return (
    request: IncomingMessage,
    socket: Duplex,
    head: Buffer,
    pathOnly: string,
  ) => {
    if (pathOnly !== "/api/fs/live") return false;
    wsServer.handleUpgrade(request, socket, head, (ws) => {
      sendJson(ws, { type: "hello" });
      attachFsLiveSocket(ws, registry, opts);
    });
    return true;
  };
}

async function buildMetadata(target: string) {
  const info = await lstat(target);
  return {
    path: target,
    size: info.size,
    isDirectory: info.isDirectory(),
    isFile: info.isFile(),
    isSymlink: info.isSymbolicLink(),
    createdAtMs: Number.isFinite(info.birthtimeMs) ? info.birthtimeMs : 0,
    modifiedAtMs: Number.isFinite(info.mtimeMs) ? info.mtimeMs : 0,
  };
}

async function readFilePreview(target: string, size: number): Promise<Buffer> {
  const bytesToRead = Math.min(size, READ_SOFT_CAP_BYTES + 1);
  if (bytesToRead <= 0) {
    return Buffer.alloc(0);
  }
  const handle = await open(target, "r");
  try {
    const buffer = Buffer.allocUnsafe(bytesToRead);
    const { bytesRead } = await handle.read(buffer, 0, bytesToRead, 0);
    return buffer.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

function createWorkspaceRootsResolver(
  listSessions: () => Promise<SessionSummary[]>,
): () => Promise<string[]> {
  let expiresAt = 0;
  let promise: Promise<string[]> | null = null;
  return async () => {
    const now = Date.now();
    if (promise && now < expiresAt) {
      return promise;
    }
    promise = collectWorkspaceRoots(listSessions).catch(() => []);
    expiresAt = now + WORKSPACE_ROOTS_TTL_MS;
    return promise;
  };
}

function createRequestRootsResolver(
  request: JsonRouteRequest,
  opts: FsRoutesOptions,
  fallbackResolveRoots: () => Promise<string[]>,
): () => Promise<string[]> {
  return createSessionScopedRootsResolver(
    sessionIdFromRequest(request),
    opts.getSessionCwd,
    fallbackResolveRoots,
  );
}

function createSocketRootsResolver(opts: {
  listSessions: () => Promise<SessionSummary[]>;
  getSessionCwd?: (sessionId: string) => Promise<string | null>;
  sessionId?: string | null;
}): () => Promise<string[]> {
  return createSessionScopedRootsResolver(
    opts.sessionId ?? null,
    opts.getSessionCwd,
    createWorkspaceRootsResolver(opts.listSessions),
  );
}

function createSessionScopedRootsResolver(
  sessionId: string | null,
  getSessionCwd: ((sessionId: string) => Promise<string | null>) | undefined,
  fallbackResolveRoots: () => Promise<string[]>,
): () => Promise<string[]> {
  const normalizedSessionId = sessionId?.trim();
  if (!normalizedSessionId || !getSessionCwd) {
    return fallbackResolveRoots;
  }

  let promise: Promise<string[]> | null = null;
  return async () => {
    promise ??= getSessionCwd(normalizedSessionId)
      .then((cwd) => (cwd ? [cwd] : fallbackResolveRoots()))
      .catch(() => fallbackResolveRoots());
    return promise;
  };
}

function sessionIdFromRequest(request: JsonRouteRequest): string | null {
  const query = request.query as Record<string, unknown>;
  const body =
    request.body && typeof request.body === "object"
      ? (request.body as Record<string, unknown>)
      : {};
  return asString(query.sessionId) ?? asString(body.sessionId);
}

function isBinary(bytes: Buffer): boolean {
  const sample = bytes.subarray(0, Math.min(bytes.byteLength, 8192));
  if (sample.length === 0) return false;
  let suspicious = 0;
  for (let i = 0; i < sample.length; i++) {
    const b = sample[i];
    if (b === 0) return true;
    if (b < 0x09 || (b > 0x0d && b < 0x20 && b !== 0x1b)) {
      suspicious += 1;
    }
  }
  return suspicious / sample.length > 0.3;
}

function guessMime(filePath: string): string {
  const lower = filePath.toLowerCase();
  const ext = lower.includes(".")
    ? lower.slice(lower.lastIndexOf(".") + 1)
    : "";
  switch (ext) {
    case "md":
      return "text/markdown";
    case "ts":
    case "tsx":
      return "text/x-typescript";
    case "js":
    case "mjs":
    case "cjs":
      return "text/javascript";
    case "json":
      return "application/json";
    case "yaml":
    case "yml":
      return "text/yaml";
    case "toml":
      return "text/x-toml";
    case "html":
    case "htm":
      return "text/html";
    case "css":
      return "text/css";
    case "rs":
      return "text/x-rust";
    case "py":
      return "text/x-python";
    case "go":
      return "text/x-go";
    case "java":
      return "text/x-java";
    case "kt":
    case "kts":
      return "text/x-kotlin";
    case "swift":
      return "text/x-swift";
    case "dart":
      return "text/x-dart";
    case "sh":
    case "bash":
    case "zsh":
      return "text/x-shellscript";
    case "xml":
      return "application/xml";
    case "svg":
      return "image/svg+xml";
    case "png":
      return "image/png";
    case "jpg":
    case "jpeg":
      return "image/jpeg";
    case "gif":
      return "image/gif";
    case "webp":
      return "image/webp";
    case "pdf":
      return "application/pdf";
    case "zip":
      return "application/zip";
    default:
      return "application/octet-stream";
  }
}
