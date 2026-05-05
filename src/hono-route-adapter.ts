import { Buffer } from "node:buffer";

import type { HttpBindings } from "@hono/node-server";
import type { Context, Handler } from "hono";
import { HTTPException } from "hono/http-exception";
import type { ContentfulStatusCode, StatusCode } from "hono/utils/http-status";

export type HonoServerEnv = {
  Bindings: HttpBindings;
  Variables: {
    requestId: string;
  };
};

export type HonoServerContext = Context<HonoServerEnv>;
export type HonoServerHandler = Handler<HonoServerEnv>;

export interface JsonRouteRequest {
  params: Record<string, string | undefined>;
  query: Record<string, unknown>;
  body?: Record<string, unknown>;
}

export interface JsonRouteResponse {
  status(code: number): JsonRouteResponse;
  json(payload: unknown): void;
}

export type JsonRouteHandler = (
  request: JsonRouteRequest,
  response: JsonRouteResponse,
) => void | Promise<void>;

class JsonRouteResponseRecorder implements JsonRouteResponse {
  private statusCode = 200;
  private hasJsonPayload = false;
  private jsonPayload: unknown;

  public status(code: number): JsonRouteResponse {
    this.statusCode = code;
    return this;
  }

  public json(payload: unknown): void {
    this.hasJsonPayload = true;
    this.jsonPayload = payload;
  }

  public toResponse(c: HonoServerContext): Response | Promise<Response> {
    const status = this.statusCode as StatusCode;
    if (!this.hasJsonPayload) {
      return c.body(null, status);
    }
    const body = JSON.stringify(this.jsonPayload) ?? "";
    return new Response(body, {
      status: status as ContentfulStatusCode,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": String(Buffer.byteLength(body, "utf8")),
      },
    });
  }
}

export function jsonRoute(handler: JsonRouteHandler): HonoServerHandler {
  return async (c) => {
    const request = await buildJsonRouteRequest(c);
    const response = new JsonRouteResponseRecorder();
    await handler(request, response);
    return response.toResponse(c);
  };
}

export async function buildJsonRouteRequest(
  c: HonoServerContext,
): Promise<JsonRouteRequest> {
  return {
    params: c.req.param(),
    query: parseQuery(c.req.url),
    body: await readJsonBody(c),
  };
}

function parseQuery(url: string): Record<string, unknown> {
  const query: Record<string, unknown> = {};
  const params = new URL(url).searchParams;
  for (const key of new Set(params.keys())) {
    const values = params.getAll(key);
    query[key] = values.length > 1 ? values : values[0];
  }
  return query;
}

async function readJsonBody(
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
