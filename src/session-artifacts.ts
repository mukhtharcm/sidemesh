import { constants as fsConstants } from "node:fs";
import {
  chmod,
  mkdir,
  open,
  readdir,
  readFile,
  realpath,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { platform, tmpdir } from "node:os";
import nodePath from "node:path";
import { randomUUID } from "node:crypto";

import type { Hono } from "hono";

import type { HonoServerEnv } from "./hono-route-adapter.js";

const MAX_SESSION_ARTIFACT_BYTES = 12 * 1024 * 1024;
const MAX_SESSION_ARTIFACT_CACHE_BYTES = 200 * 1024 * 1024;
const MAX_SESSION_ARTIFACT_FILES = 200;
const SESSION_ARTIFACT_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const ARTIFACT_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(?:png|jpe?g|gif|webp)$/i;

interface SessionArtifactRouteOptions {
  stateDir: string;
  isReferenced(sessionId: string, source: string): Promise<boolean>;
}

export function registerSessionArtifactRoutes(
  app: Hono<HonoServerEnv>,
  options: SessionArtifactRouteOptions,
): void {
  const artifactRoot = nodePath.join(options.stateDir, "session-artifacts");
  let artifactMutation = Promise.resolve();

  app.post("/api/sessions/:sessionId/artifacts", async (c) => {
    const sessionId = c.req.param("sessionId").trim();
    const body = await c.req.json<unknown>().catch(() => null);
    const source =
      body && typeof body === "object" && "source" in body
        ? String(body.source).trim()
        : "";
    if (!sessionId || !source) {
      return c.json({ error: "sessionId and source are required" }, 400);
    }
    if (!(await options.isReferenced(sessionId, source))) {
      return c.json(
        { error: "artifact source is not referenced by this session" },
        403,
      );
    }

    try {
      const canonicalSource = await resolveTemporaryArtifactSource(source);
      const noFollow =
        platform() === "win32" ? 0 : fsConstants.O_NOFOLLOW;
      const sourceHandle = await open(
        canonicalSource,
        fsConstants.O_RDONLY | noFollow,
      );
      let bytes: Buffer;
      try {
        const fileInfo = await sourceHandle.stat();
        if (!fileInfo.isFile()) {
          return c.json(
            { error: "artifact source is not a regular file" },
            400,
          );
        }
        if (fileInfo.size > MAX_SESSION_ARTIFACT_BYTES) {
          return c.json({ error: "artifact is too large" }, 413);
        }
        bytes = await sourceHandle.readFile();
      } finally {
        await sourceHandle.close();
      }
      if (bytes.byteLength > MAX_SESSION_ARTIFACT_BYTES) {
        return c.json({ error: "artifact is too large" }, 413);
      }
      const image = detectImageType(bytes.subarray(0, 16));
      if (!image) {
        return c.json({ error: "artifact is not a supported image" }, 415);
      }

      const artifactId = `${randomUUID()}.${image.extension}`;
      const mutate = artifactMutation.then(async () => {
        await mkdir(artifactRoot, { recursive: true, mode: 0o700 });
        await pruneArtifactCache(artifactRoot, bytes.byteLength);
        const destination = nodePath.join(artifactRoot, artifactId);
        await writeFile(destination, bytes, { flag: "wx", mode: 0o600 });
        await chmod(destination, 0o600);
      });
      artifactMutation = mutate.catch(() => {});
      await mutate;
      return c.json({
        artifactId,
        contentType: image.contentType,
        size: bytes.byteLength,
      });
    } catch (error) {
      const status =
        error instanceof SessionArtifactError ? error.status : 500;
      return c.json({ error: errorMessage(error) }, status);
    }
  });

  app.get("/api/session-artifacts/:artifactId", async (c) => {
    const artifactId = c.req.param("artifactId");
    if (!ARTIFACT_ID_PATTERN.test(artifactId)) {
      return c.json({ error: "invalid artifact id" }, 400);
    }
    try {
      const path = nodePath.join(artifactRoot, artifactId);
      const info = await stat(path);
      if (Date.now() - info.mtimeMs > SESSION_ARTIFACT_TTL_MS) {
        await unlink(path).catch(() => {});
        return c.json({ error: "artifact not found" }, 404);
      }
      const bytes = await readFile(path);
      if (bytes.byteLength > MAX_SESSION_ARTIFACT_BYTES) {
        return c.json({ error: "artifact is too large" }, 413);
      }
      const image = detectImageType(bytes.subarray(0, 16));
      if (!image) {
        return c.json({ error: "artifact is not a supported image" }, 415);
      }
      c.header("Content-Type", image.contentType);
      c.header("Content-Length", String(bytes.byteLength));
      c.header("Cache-Control", "private, max-age=300");
      c.header("X-Content-Type-Options", "nosniff");
      return c.body(bytes);
    } catch (error) {
      if (isMissingFileError(error)) {
        return c.json({ error: "artifact not found" }, 404);
      }
      return c.json({ error: errorMessage(error) }, 500);
    }
  });
}

async function pruneArtifactCache(
  artifactRoot: string,
  incomingBytes: number,
): Promise<void> {
  const now = Date.now();
  const entries = await readdir(artifactRoot, { withFileTypes: true });
  const files = (
    await Promise.all(
      entries
        .filter(
          (entry) => entry.isFile() && ARTIFACT_ID_PATTERN.test(entry.name),
        )
        .map(async (entry) => {
          const path = nodePath.join(artifactRoot, entry.name);
          try {
            const info = await stat(path);
            return { path, size: info.size, modifiedAtMs: info.mtimeMs };
          } catch {
            return null;
          }
        }),
    )
  )
    .filter(
      (
        entry,
      ): entry is { path: string; size: number; modifiedAtMs: number } =>
        entry != null,
    )
    .sort((left, right) => right.modifiedAtMs - left.modifiedAtMs);

  let keptFiles = 0;
  let keptBytes = incomingBytes;
  for (const file of files) {
    const expired = now - file.modifiedAtMs > SESSION_ARTIFACT_TTL_MS;
    const exceedsCount = keptFiles >= MAX_SESSION_ARTIFACT_FILES - 1;
    const exceedsBytes =
      keptBytes + file.size > MAX_SESSION_ARTIFACT_CACHE_BYTES;
    if (expired || exceedsCount || exceedsBytes) {
      await unlink(file.path).catch(() => {});
      continue;
    }
    keptFiles += 1;
    keptBytes += file.size;
  }
}

export async function resolveTemporaryArtifactSource(
  raw: string,
): Promise<string> {
  const decoded = decodeHostPath(raw);
  if (!nodePath.isAbsolute(decoded)) {
    throw new SessionArtifactError(
      "only absolute temporary artifact paths are supported",
      400,
    );
  }
  let canonicalSource: string;
  let canonicalTemps: string[];
  try {
    canonicalSource = await realpath(decoded);
    canonicalTemps = (
      await Promise.all(
        [
          tmpdir(),
          ...(platform() === "win32" ? [] : ["/tmp", "/var/tmp"]),
        ].map((candidate) => realpath(candidate).catch(() => null)),
      )
    ).filter((candidate): candidate is string => candidate != null);
  } catch (error) {
    if (isMissingFileError(error)) {
      throw new SessionArtifactError("artifact source was not found", 404);
    }
    throw error;
  }
  const insideTemporaryRoot = canonicalTemps.some((canonicalTemp) => {
    const relative = nodePath.relative(canonicalTemp, canonicalSource);
    return (
      relative !== "" &&
      relative !== ".." &&
      !relative.startsWith(`..${nodePath.sep}`) &&
      !nodePath.isAbsolute(relative)
    );
  });
  if (!insideTemporaryRoot) {
    throw new SessionArtifactError(
      "only files inside the host temporary directory can be published",
      403,
    );
  }
  return canonicalSource;
}

export function artifactReferencesMatch(
  left: string,
  right: string,
): boolean {
  try {
    return (
      nodePath.normalize(decodeHostPath(left)) ===
      nodePath.normalize(decodeHostPath(right))
    );
  } catch {
    return false;
  }
}

function decodeHostPath(raw: string): string {
  const value = raw.trim().replace(/[?#].*$/, "");
  if (value.toLowerCase().startsWith("file:")) {
    try {
      return fileURLToPath(value);
    } catch {
      throw new SessionArtifactError("invalid file URL", 400);
    }
  }
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function detectImageType(
  bytes: Uint8Array,
): { contentType: string; extension: string } | null {
  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return { contentType: "image/png", extension: "png" };
  }
  if (
    bytes.length >= 3 &&
    bytes[0] === 0xff &&
    bytes[1] === 0xd8 &&
    bytes[2] === 0xff
  ) {
    return { contentType: "image/jpeg", extension: "jpg" };
  }
  if (
    bytes.length >= 6 &&
    String.fromCharCode(...bytes.subarray(0, 6)) === "GIF87a" ||
    bytes.length >= 6 &&
    String.fromCharCode(...bytes.subarray(0, 6)) === "GIF89a"
  ) {
    return { contentType: "image/gif", extension: "gif" };
  }
  if (
    bytes.length >= 12 &&
    String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF" &&
    String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP"
  ) {
    return { contentType: "image/webp", extension: "webp" };
  }
  return null;
}

class SessionArtifactError extends Error {
  constructor(
    message: string,
    readonly status: 400 | 403 | 404,
  ) {
    super(message);
  }
}

function isMissingFileError(error: unknown): boolean {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT"
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
