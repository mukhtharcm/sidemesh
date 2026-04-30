import assert from "node:assert/strict";
import { createServer, get, type Server } from "node:http";
import type { RequestOptions } from "node:http";
import { afterEach, describe, it } from "node:test";

import compression from "compression";
import cors from "cors";
import express from "express";

function testApp(): express.Express {
  const app = express();
  app.use(cors());
  app.use(
    compression({
      filter: (request, response) => {
        if (request.path === "/healthz") {
          return false;
        }
        return compression.filter(request, response);
      },
    }),
  );
  app.use(express.json({ limit: "16mb" }));

  app.get("/healthz", (_request, response) => {
    response.json({ ok: true });
  });

  app.get("/api/large", (_request, response) => {
    response.json({ data: "x".repeat(10_000) });
  });

  app.get("/api/small", (_request, response) => {
    response.json({ ok: true });
  });

  return app;
}

function listen(app: express.Express): Promise<{ baseUrl: string; server: Server }> {
  return new Promise((resolve) => {
    const server = createServer(app);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (address && typeof address !== "string") {
        resolve({ baseUrl: `http://127.0.0.1:${address.port}`, server });
      }
    });
  });
}


function rawGet(url: string, options?: RequestOptions): Promise<{ statusCode: number; headers: import("node:http").IncomingHttpHeaders; body: string }> {
  return new Promise((resolve, reject) => {
    get(url, options ?? {}, (response) => {
      let body = "";
      response.on("data", (chunk) => {
        body += chunk;
      });
      response.on("end", () => {
        resolve({ statusCode: response.statusCode ?? 0, headers: response.headers, body });
      });
    }).on("error", (error) => {
      reject(error);
    });
  });
}

describe("HTTP payload compression", () => {
  let server: Server | undefined;

  afterEach(async () => {
    if (server) {
      await new Promise<void>((resolve) => server!.close(() => resolve()));
      server = undefined;
    }
  });

  it("skips compression for the health-check endpoint", async () => {
    const app = testApp();
    const { baseUrl, server: s } = await listen(app);
    server = s;
    const response = await fetch(`${baseUrl}/healthz`, {
      headers: { "Accept-Encoding": "gzip" },
    });
    assert.strictEqual(response.status, 200);
    assert.strictEqual(response.headers.get("content-encoding"), null);
  });

  it("compresses large JSON responses when the client accepts gzip", async () => {
    const app = testApp();
    const { baseUrl, server: s } = await listen(app);
    server = s;
    const response = await fetch(`${baseUrl}/api/large`, {
      headers: { "Accept-Encoding": "gzip" },
    });
    assert.strictEqual(response.status, 200);
    assert.strictEqual(response.headers.get("content-encoding"), "gzip");
    const raw = await rawGet(`${baseUrl}/api/large`, { headers: { "Accept-Encoding": "gzip" } });
    assert.ok(raw.body.length < 10_000, "compressed body should be smaller than raw JSON");
  });

  it("does not compress small responses below the default threshold", async () => {
    const app = testApp();
    const { baseUrl, server: s } = await listen(app);
    server = s;
    const response = await fetch(`${baseUrl}/api/small`, {
      headers: { "Accept-Encoding": "gzip" },
    });
    assert.strictEqual(response.status, 200);
    assert.strictEqual(response.headers.get("content-encoding"), null);
  });
});
