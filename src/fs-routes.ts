import { Buffer } from "node:buffer";
import { realpath, stat } from "node:fs/promises";
import path from "node:path";

import type { Express, Request, Response, NextFunction } from "express";
import type { WebSocket, WebSocketServer } from "ws";

import {
  requireProviderMethod,
  type AgentProviderMethod,
  type AgentProviderMethodName,
  type AgentProvider,
} from "./agent-provider.js";
import {
  collectWorkspaceRoots,
  resolveWorkspacePath,
  WorkspaceAccessError,
} from "./workspace-scope.js";
import type { SessionSummary } from "./types.js";

const READ_SOFT_CAP_BYTES = 2 * 1024 * 1024; // 2 MiB — UX preview cap.
const WRITE_SOFT_CAP_BYTES = 4 * 1024 * 1024; // 4 MiB — payload safety cap.

interface FsRoutesOptions {
  provider: AgentProvider;
  listSessions: () => Promise<SessionSummary[]>;
  watchRegistry: FsWatchRegistry;
}

export function registerFsRoutes(app: Express, opts: FsRoutesOptions): void {
  const { provider, listSessions } = opts;

  app.use("/api/fs", (_request, response, next) => {
    if (!provider.capabilities.workspace.filesystem) {
      response.status(501).json({
        error: `${provider.displayName} does not support filesystem access`,
      });
      return;
    }
    next();
  });

  app.get(
    "/api/fs/list",
    asyncRoute(async (request, response) => {
      const target = await resolveIncomingPath(request.query.path, provider, listSessions);
      const readDirectory = requireFilesystemMethod(provider, "fsReadDirectory", "filesystem directory listing");
      const result = await readDirectory.call(provider, target);
      const entries = (result.entries || []).map((entry) => ({
        name: entry.fileName,
        path: path.join(target, entry.fileName),
        isDirectory: !!entry.isDirectory,
        isFile: !!entry.isFile,
      }));
      entries.sort((a, b) => {
        if (a.isDirectory !== b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
      response.json({ path: target, entries });
    }),
  );

  app.get(
    "/api/fs/metadata",
    asyncRoute(async (request, response) => {
      const target = await resolveIncomingPath(request.query.path, provider, listSessions);
      const getMetadata = requireFilesystemMethod(provider, "fsGetMetadata", "filesystem metadata");
      const meta = await getMetadata.call(provider, target);
      response.json({ path: target, ...meta });
    }),
  );

  app.get(
    "/api/fs/read",
    asyncRoute(async (request, response) => {
      const target = await resolveIncomingPath(request.query.path, provider, listSessions);
      const getMetadata = requireFilesystemMethod(provider, "fsGetMetadata", "filesystem metadata");
      const readFile = requireFilesystemMethod(provider, "fsReadFile", "filesystem file reads");
      const meta = await getMetadata.call(provider, target);
      if (!meta.isFile) {
        response.status(400).json({ error: "path is not a regular file" });
        return;
      }
      const res = await readFile.call(provider, target);
      const bytes = Buffer.from(res.dataBase64 || "", "base64");
      const size = bytes.byteLength;
      const binary = isBinary(bytes);
      const truncated = size > READ_SOFT_CAP_BYTES;
      if (binary) {
        response.json({
          path: target,
          size,
          binary: true,
          truncated: false,
          modifiedAtMs: meta.modifiedAtMs,
          mimeHint: guessMime(target),
          encoding: "none",
          contents: "",
        });
        return;
      }
      const preview = truncated ? bytes.subarray(0, READ_SOFT_CAP_BYTES) : bytes;
      response.json({
        path: target,
        size,
        binary: false,
        truncated,
        modifiedAtMs: meta.modifiedAtMs,
        mimeHint: guessMime(target),
        encoding: "utf8",
        contents: preview.toString("utf8"),
      });
    }),
  );

  app.get(
    "/api/fs/blob",
    asyncRoute(async (request, response) => {
      const target = await resolveIncomingBlobPath(
        request.query.path,
        provider,
        listSessions,
      );
      const readFile = requireFilesystemMethod(provider, "fsReadFile", "filesystem blob reads");
      const res = await readFile.call(provider, target);
      const bytes = Buffer.from(res.dataBase64 || "", "base64");
      response.setHeader("Content-Type", guessMime(target));
      response.setHeader("Content-Length", String(bytes.byteLength));
      response.setHeader("Cache-Control", "private, max-age=60");
      response.setHeader(
        "Content-Disposition",
        `inline; filename="${path.basename(target).replaceAll('"', "")}"`,
      );
      response.send(bytes);
    }),
  );

  app.post(
    "/api/fs/write",
    asyncRoute(async (request, response) => {
      const target = await resolveIncomingPath(
        request.body?.path,
        provider,
        listSessions,
        { allowMissing: true },
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
      const writeFile = requireFilesystemMethod(provider, "fsWriteFile", "filesystem file writes");
      await writeFile.call(provider, target, buffer.toString("base64"));
      response.json({ path: target, bytes: buffer.byteLength });
    }),
  );

  app.post(
    "/api/fs/createDir",
    asyncRoute(async (request, response) => {
      const target = await resolveIncomingPath(
        request.body?.path,
        provider,
        listSessions,
        { allowMissing: true },
      );
      const recursive = request.body?.recursive !== false;
      const createDirectory = requireFilesystemMethod(provider, "fsCreateDirectory", "filesystem directory creation");
      await createDirectory.call(provider, target, recursive);
      response.json({ path: target });
    }),
  );

  app.post(
    "/api/fs/remove",
    asyncRoute(async (request, response) => {
      const target = await resolveIncomingPath(request.body?.path, provider, listSessions);
      const recursive = request.body?.recursive !== false;
      const force = request.body?.force !== false;
      const remove = requireFilesystemMethod(provider, "fsRemove", "filesystem removal");
      await remove.call(provider, target, { recursive, force });
      response.json({ path: target });
    }),
  );

  app.post(
    "/api/fs/copy",
    asyncRoute(async (request, response) => {
      const source = await resolveIncomingPath(
        request.body?.sourcePath,
        provider,
        listSessions,
      );
      const destination = await resolveIncomingPath(
        request.body?.destinationPath,
        provider,
        listSessions,
        { allowMissing: true },
      );
      const recursive = request.body?.recursive === true;
      const copy = requireFilesystemMethod(provider, "fsCopy", "filesystem copy");
      await copy.call(provider, { sourcePath: source, destinationPath: destination, recursive });
      response.json({ sourcePath: source, destinationPath: destination });
    }),
  );

  app.get(
    "/api/fs/roots",
    asyncRoute(async (_request, response) => {
      const roots = await collectWorkspaceRoots(provider, listSessions);
      response.json({ roots });
    }),
  );
}

async function resolveIncomingPath(
  raw: unknown,
  provider: AgentProvider,
  listSessions: () => Promise<SessionSummary[]>,
  options: { allowMissing?: boolean } = {},
): Promise<string> {
  if (typeof raw !== "string") {
    throw new WorkspaceAccessError("path is required", 400);
  }
  const roots = await collectWorkspaceRoots(provider, listSessions);
  return resolveWorkspacePath(raw, roots, options);
}

async function resolveIncomingBlobPath(
  raw: unknown,
  provider: AgentProvider,
  listSessions: () => Promise<SessionSummary[]>,
): Promise<string> {
  try {
    return await resolveIncomingPath(raw, provider, listSessions);
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
  handler: (request: Request, response: Response, next: NextFunction) => Promise<void>,
): (request: Request, response: Response, next: NextFunction) => void {
  return (request, response, next) => {
    void handler(request, response, next).catch((error) => {
      if (error instanceof WorkspaceAccessError) {
        response.status(error.status).json({ error: error.message });
        return;
      }
      next(error);
    });
  };
}

function requireFilesystemMethod<K extends AgentProviderMethodName>(
  provider: AgentProvider,
  method: K,
  feature: string,
): AgentProviderMethod<K> {
  try {
    return requireProviderMethod(provider, method, feature);
  } catch (error) {
    throw new WorkspaceAccessError(
      error instanceof Error ? error.message : String(error),
      501,
    );
  }
}

// ---------------------------------------------------------------------------
// fs/watch registry — bridges WebSocket clients ↔ provider fs/watch notifications.
//
// The provider returns a watchId per fs/watch call. The registry tracks which client
// owns which watchId and fans out fs/changed notifications to that client
// only. When a client disconnects we unsubscribe all of its watches upstream.
// ---------------------------------------------------------------------------

interface WatchRecord {
  ws: WebSocket;
  userWatchId: string; // Client-supplied id echoed back in change events.
  path: string;
}

export class FsWatchRegistry {
  private readonly records = new Map<string, WatchRecord>();
  private readonly byClient = new WeakMap<WebSocket, Set<string>>();

  public constructor(private readonly provider: AgentProvider) {}

  public async subscribe(
    ws: WebSocket,
    params: { path: string; userWatchId: string; roots: string[] },
  ): Promise<{ watchId: string; path: string }> {
    const resolved = await resolveWorkspacePath(params.path, params.roots);
    const watch = requireFilesystemMethod(this.provider, "fsWatch", "filesystem watching");
    const result = await watch.call(this.provider, resolved);
    const watchId = result.watchId;
    this.records.set(watchId, { ws, userWatchId: params.userWatchId, path: resolved });
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
    try {
      const unwatch = requireFilesystemMethod(this.provider, "fsUnwatch", "filesystem watching");
      await unwatch.call(this.provider, watchId);
    } catch {
      // Best-effort; Codex may already have dropped the watch.
    }
  }

  public async disconnect(ws: WebSocket): Promise<void> {
    const set = this.byClient.get(ws);
    if (!set) return;
    this.byClient.delete(ws);
    for (const watchId of set) {
      this.records.delete(watchId);
      try {
        const unwatch = requireFilesystemMethod(this.provider, "fsUnwatch", "filesystem watching");
        await unwatch.call(this.provider, watchId);
      } catch {
        // swallow
      }
    }
  }

  public deliver(params: { watchId?: string; changedPaths?: string[] }): void {
    const watchId = params.watchId ? String(params.watchId) : "";
    if (!watchId) return;
    const record = this.records.get(watchId);
    if (!record) return;
    const payload = JSON.stringify({
      type: "fs_changed",
      watchId: record.userWatchId,
      path: record.path,
      changedPaths: Array.isArray(params.changedPaths)
        ? params.changedPaths.map((p) => String(p))
        : [],
    });
    try {
      record.ws.send(payload);
    } catch {
      // swallow
    }
  }
}

/**
 * Handle a WebSocket connection on /api/fs/live. Incoming JSON frames:
 *   { type: "subscribe", id: "...", path: "/abs/path" }
 *   { type: "unsubscribe", watchId: "..." }
 * Outgoing:
 *   { type: "subscribed", id, watchId, path }
 *   { type: "unsubscribed", watchId }
 *   { type: "fs_changed", watchId, path, changedPaths }
 *   { type: "error", id?, message }
 */
export function attachFsLiveSocket(
  ws: WebSocket,
  registry: FsWatchRegistry,
  opts: {
    provider: AgentProvider;
    listSessions: () => Promise<SessionSummary[]>;
  },
): void {
  ws.on("message", async (raw) => {
    let message: any;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      sendJson(ws, { type: "error", message: "invalid json" });
      return;
    }
    const messageType = message?.type;
    try {
      if (messageType === "subscribe") {
        const roots = await collectWorkspaceRoots(opts.provider, opts.listSessions);
        const { watchId, path: resolved } = await registry.subscribe(ws, {
          path: String(message.path ?? ""),
          userWatchId: String(message.id ?? ""),
          roots,
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
    provider: AgentProvider;
    listSessions: () => Promise<SessionSummary[]>;
  },
) {
  return (request: any, socket: any, head: Buffer, pathOnly: string) => {
    if (pathOnly !== "/api/fs/live") return false;
    wsServer.handleUpgrade(request, socket, head, (ws) => {
      sendJson(ws, { type: "hello" });
      attachFsLiveSocket(ws, registry, opts);
    });
    return true;
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
  const ext = lower.includes(".") ? lower.slice(lower.lastIndexOf(".") + 1) : "";
  switch (ext) {
    case "md": return "text/markdown";
    case "ts":
    case "tsx": return "text/x-typescript";
    case "js":
    case "mjs":
    case "cjs": return "text/javascript";
    case "json": return "application/json";
    case "yaml":
    case "yml": return "text/yaml";
    case "toml": return "text/x-toml";
    case "html":
    case "htm": return "text/html";
    case "css": return "text/css";
    case "rs": return "text/x-rust";
    case "py": return "text/x-python";
    case "go": return "text/x-go";
    case "java": return "text/x-java";
    case "kt":
    case "kts": return "text/x-kotlin";
    case "swift": return "text/x-swift";
    case "dart": return "text/x-dart";
    case "sh":
    case "bash":
    case "zsh": return "text/x-shellscript";
    case "xml": return "application/xml";
    case "svg": return "image/svg+xml";
    case "png": return "image/png";
    case "jpg":
    case "jpeg": return "image/jpeg";
    case "gif": return "image/gif";
    case "webp": return "image/webp";
    case "pdf": return "application/pdf";
    case "zip": return "application/zip";
    default: return "application/octet-stream";
  }
}
