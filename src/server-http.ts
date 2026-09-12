import { Buffer } from "node:buffer";

import type { HttpBindings } from "@hono/node-server";
import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import type { ContentfulStatusCode } from "hono/utils/http-status";

export type HonoServerEnv = { Bindings: HttpBindings; Variables: { requestId: string } };
export type HonoServerContext = Context<HonoServerEnv>;

// The length lets Hono skip compression for small JSON responses.
export function jsonResponse(c: HonoServerContext, payload: unknown, status: ContentfulStatusCode = 200): Response {
  const body = JSON.stringify(payload) ?? "";
  return c.body(body, status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": String(Buffer.byteLength(body)) });
}

export function readQuery(c: HonoServerContext): Record<string, unknown> {
  return Object.fromEntries(Object.entries(c.req.queries()).map(([key, values]) => [key, values.length === 1 ? values[0] : values]));
}

export async function readJsonBody(
  c: HonoServerContext,
): Promise<Record<string, unknown> | undefined> {
  const method = c.req.method.toUpperCase();
  if (method === "GET" || method === "HEAD") {
    return undefined;
  }
  if (c.req.header("content-length") === "0") {
    return undefined;
  }
  const contentType = c.req.header("content-type") ?? "";
  if (!/\bjson\b/i.test(contentType)) {
    return undefined;
  }

  let parsed: unknown;
  try {
    parsed = await c.req.json();
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "invalid json";
    throw new HTTPException(400, { message });
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return undefined;
  }
  return parsed as Record<string, unknown>;
}
