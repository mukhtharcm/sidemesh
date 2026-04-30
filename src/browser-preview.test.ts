import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  BrowserPreviewError,
  BrowserPreviewRegistry,
  buildBrowserTargetUrlCandidates,
  browserPreviewReuseKey,
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

  it("tries the requested browser target before loopback fallbacks", () => {
    assert.deepEqual(
      buildBrowserTargetUrlCandidates("http", "127.0.0.1", 3000),
      [
        "http://127.0.0.1:3000/",
        "http://localhost:3000/",
        "http://[::1]:3000/",
      ],
    );
    assert.deepEqual(
      buildBrowserTargetUrlCandidates("http", "::1", 3000),
      [
        "http://[::1]:3000/",
        "http://localhost:3000/",
        "http://127.0.0.1:3000/",
      ],
    );
    assert.deepEqual(
      buildBrowserTargetUrlCandidates("https", "localhost", 8443),
      [
        "https://localhost:8443/",
        "https://127.0.0.1:8443/",
        "https://[::1]:8443/",
      ],
    );
  });

  it("keys reusable previews by target and session scope", () => {
    const base = {
      targetHost: "127.0.0.1",
      targetPort: 3000,
      scheme: "http" as const,
      cwd: "/workspace",
      sessionId: "session-1",
    };

    assert.equal(
      browserPreviewReuseKey(base),
      browserPreviewReuseKey({ ...base }),
    );
    assert.notEqual(
      browserPreviewReuseKey(base),
      browserPreviewReuseKey({ ...base, sessionId: "session-2" }),
    );
    assert.notEqual(
      browserPreviewReuseKey(base),
      browserPreviewReuseKey({ ...base, cwd: "/other" }),
    );
  });
});
