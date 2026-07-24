import { isIP } from "node:net";

import type { Hono } from "hono";

import type { HonoServerEnv } from "./hono-route-adapter.js";

const MAX_HOST_RESOURCE_BYTES = 12 * 1024 * 1024;
const MAX_REDIRECTS = 4;

export function registerHostResourceRoutes(app: Hono<HonoServerEnv>): void {
  app.get("/api/host-resource", async (c) => {
    const raw = c.req.query("url")?.trim() ?? "";
    let target: URL;
    try {
      target = normalizeHostResourceUrl(raw);
    } catch (error) {
      return c.json({ error: errorMessage(error) }, 400);
    }

    let upstream: Response;
    try {
      upstream = await fetchHostResource(target);
    } catch (error) {
      return c.json(
        { error: `could not load host resource: ${errorMessage(error)}` },
        502,
      );
    }
    if (!upstream.ok) {
      await discardResponseBody(upstream);
      return c.json(
        { error: `host resource returned ${upstream.status}` },
        502,
      );
    }
    const contentType = upstream.headers
      .get("content-type")
      ?.split(";")[0]
      ?.trim();
    if (!contentType?.startsWith("image/")) {
      await discardResponseBody(upstream);
      return c.json({ error: "host resource is not an image" }, 415);
    }
    const declaredLength = Number(upstream.headers.get("content-length"));
    if (
      Number.isFinite(declaredLength) &&
      declaredLength > MAX_HOST_RESOURCE_BYTES
    ) {
      await discardResponseBody(upstream);
      return c.json({ error: "host resource is too large" }, 413);
    }
    let bytes: Uint8Array;
    try {
      bytes = await readLimitedResponseBody(
        upstream,
        MAX_HOST_RESOURCE_BYTES,
      );
    } catch (error) {
      if (error instanceof HostResourceLimitError) {
        return c.json({ error: error.message }, 413);
      }
      return c.json(
        { error: `could not load host resource: ${errorMessage(error)}` },
        502,
      );
    }
    c.header("Content-Type", contentType);
    c.header("Cache-Control", "private, no-store");
    c.header("Content-Length", String(bytes.byteLength));
    return c.body(bytes.buffer as ArrayBuffer);
  });
}

export function normalizeHostResourceUrl(raw: string): URL {
  if (!raw) {
    throw new Error("url is required");
  }
  const url = new URL(raw);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("only HTTP and HTTPS host resources are supported");
  }
  if (url.username || url.password) {
    throw new Error("host resource credentials are not supported");
  }
  if (!isLoopbackHostname(url.hostname)) {
    throw new Error("host resource URL must target loopback");
  }
  if (url.hostname === "0.0.0.0") {
    url.hostname = "127.0.0.1";
  }
  return url;
}

export function isLoopbackHostname(raw: string): boolean {
  const hostname = raw.replace(/^\[|\]$/g, "").toLowerCase();
  if (
    hostname === "localhost" ||
    hostname === "::1" ||
    hostname === "0.0.0.0" ||
    hostname.endsWith(".localhost")
  ) {
    return true;
  }
  if (isIP(hostname) !== 4) {
    return false;
  }
  const first = Number.parseInt(hostname.split(".")[0] ?? "", 10);
  return first === 127;
}

async function fetchHostResource(initial: URL): Promise<Response> {
  let target = initial;
  for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
    const response = await fetch(target, {
      redirect: "manual",
      signal: AbortSignal.timeout(10_000),
      headers: {
        Accept: "image/*",
      },
    });
    if (response.status < 300 || response.status >= 400) {
      return response;
    }
    const location = response.headers.get("location");
    if (!location) {
      return response;
    }
    if (redirects === MAX_REDIRECTS) {
      throw new Error("too many redirects");
    }
    target = normalizeHostResourceUrl(new URL(location, target).toString());
  }
  throw new Error("too many redirects");
}

async function readLimitedResponseBody(
  response: Response,
  maxBytes: number,
): Promise<Uint8Array> {
  if (!response.body) {
    return new Uint8Array();
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) {
        break;
      }
      total += result.value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        throw new HostResourceLimitError();
      }
      chunks.push(result.value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function discardResponseBody(response: Response): Promise<void> {
  await response.body?.cancel().catch(() => {});
}

class HostResourceLimitError extends Error {
  constructor() {
    super("host resource is too large");
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
