import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { describe, it } from "node:test";

import { getRequestListener } from "@hono/node-server";
import { Hono } from "hono";

import {
  isLoopbackHostname,
  normalizeHostResourceUrl,
  registerHostResourceRoutes,
} from "./host-resource.js";
import type { HonoServerEnv } from "./hono-route-adapter.js";

describe("host resources", () => {
  it("accepts loopback targets and rejects remote hosts", () => {
    assert.equal(isLoopbackHostname("localhost"), true);
    assert.equal(isLoopbackHostname("app.localhost"), true);
    assert.equal(isLoopbackHostname("127.4.3.2"), true);
    assert.equal(isLoopbackHostname("::1"), true);
    assert.equal(isLoopbackHostname("192.168.1.2"), false);
    assert.throws(
      () => normalizeHostResourceUrl("https://example.com/image.png"),
      /must target loopback/,
    );
  });

  it("loads loopback images through the host and rejects non-images", async () => {
    const upstream = createServer((request, response) => {
      if (request.url === "/image") {
        response.writeHead(200, {
          "content-type": "image/png",
          "content-length": "3",
        });
        response.end(Buffer.from([1, 2, 3]));
        return;
      }
      if (request.url === "/too-large") {
        response.writeHead(200, { "content-type": "image/png" });
        for (let index = 0; index < 13; index += 1) {
          response.write(Buffer.alloc(1024 * 1024));
        }
        response.end();
        return;
      }
      if (request.url === "/remote-redirect") {
        response.writeHead(302, {
          location: "https://example.com/image.png",
        });
        response.end();
        return;
      }
      response.writeHead(200, { "content-type": "text/html" });
      response.end("not an image");
    });
    await listen(upstream);
    const upstreamAddress = upstream.address();
    assert.ok(upstreamAddress && typeof upstreamAddress === "object");

    const app = new Hono<HonoServerEnv>();
    registerHostResourceRoutes(app);
    const proxy = createServer(getRequestListener(app.fetch));
    await listen(proxy);
    const proxyAddress = proxy.address();
    assert.ok(proxyAddress && typeof proxyAddress === "object");
    const proxyBase = `http://127.0.0.1:${proxyAddress.port}`;
    const upstreamBase = `http://127.0.0.1:${upstreamAddress.port}`;
    try {
      const image = await fetch(
        `${proxyBase}/api/host-resource?url=${encodeURIComponent(`${upstreamBase}/image`)}`,
      );
      assert.equal(image.status, 200);
      assert.equal(image.headers.get("content-type"), "image/png");
      assert.deepEqual(
        new Uint8Array(await image.arrayBuffer()),
        new Uint8Array([1, 2, 3]),
      );

      const text = await fetch(
        `${proxyBase}/api/host-resource?url=${encodeURIComponent(`${upstreamBase}/text`)}`,
      );
      assert.equal(text.status, 415);

      const tooLarge = await fetch(
        `${proxyBase}/api/host-resource?url=${encodeURIComponent(`${upstreamBase}/too-large`)}`,
      );
      assert.equal(tooLarge.status, 413);

      const remoteRedirect = await fetch(
        `${proxyBase}/api/host-resource?url=${encodeURIComponent(`${upstreamBase}/remote-redirect`)}`,
      );
      assert.equal(remoteRedirect.status, 502);
    } finally {
      await Promise.all([close(proxy), close(upstream)]);
    }
  });
});

async function listen(server: Server): Promise<void> {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
}

async function close(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}
