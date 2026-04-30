import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  BrowserPreviewError,
  BrowserPreviewRegistry,
  buildBrowserTargetUrl,
} from "./browser-preview.js";

describe("browser preview", () => {
  it("keeps browser previews opt-in", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: false });

    await assert.rejects(
      () => registry.create({ targetPort: 3000 }),
      (error) =>
        error instanceof BrowserPreviewError &&
        error.status === 403 &&
        error.message === "browser preview is disabled",
    );
  });

  it("rejects unsupported targets before launching Chromium", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true });

    await assert.rejects(
      () => registry.create({ targetHost: "192.168.1.10", targetPort: 3000 }),
      /browser previews can only open localhost targets/,
    );
    await assert.rejects(
      () => registry.create({ targetHost: "127.0.0.1", targetPort: 3000, scheme: "tcp" }),
      /browser preview scheme must be http or https/,
    );
    await assert.rejects(
      () => registry.create({ targetHost: "127.0.0.1", targetPort: 0 }),
      /targetPort must be between 1 and 65535/,
    );
  });

  it("opens loopback browser targets through localhost", () => {
    assert.equal(
      buildBrowserTargetUrl("http", "127.0.0.1", 3000),
      "http://localhost:3000/",
    );
    assert.equal(
      buildBrowserTargetUrl("http", "::1", 3000),
      "http://localhost:3000/",
    );
    assert.equal(
      buildBrowserTargetUrl("https", "localhost", 8443),
      "https://localhost:8443/",
    );
  });
});
