import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { describe, it } from "node:test";

import type { WebSocket } from "ws";

import {
  BrowserPreviewError,
  BrowserPreviewRegistry,
  buildBrowserTargetUrlCandidates,
  browserPreviewReuseKey,
  isBrowserNavigationUrl,
  maybeRecoverStaleChromeSingletonProfile,
  normalizeBrowserPreviewTargetUrl,
  parseChromeProfileSingletonError,
} from "./browser-preview.js";

describe("browser", () => {
  it("keeps browser opt-in", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: false });

    await assert.rejects(
      () => registry.create({ targetPort: 3000 }),
      (error) =>
        error instanceof BrowserPreviewError &&
        error.status === 403 &&
        error.message === "browser is disabled",
    );
  });

  it("rejects unsupported targets before launching Chromium", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true });

    await assert.rejects(
      () => registry.create({ targetHost: "192.168.1.10", targetPort: 3000 }),
      /browser can only open localhost targets/,
    );
    await assert.rejects(
      () => registry.create({ targetHost: "127.0.0.1", targetPort: 3000, scheme: "tcp" }),
      /browser scheme must be http or https/,
    );
    await assert.rejects(
      () => registry.create({ targetHost: "127.0.0.1", targetPort: 0 }),
      /targetPort must be between 1 and 65535/,
    );
    await assert.rejects(
      () =>
        registry.create({
          targetHost: "127.0.0.1",
          targetPort: 3000,
          profileMode: "default-profile",
        }),
      /browser profileMode must be temporary or sidemesh/,
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
    assert.deepEqual(
      buildBrowserTargetUrlCandidates("http", "tenant.localhost", 3000),
      ["http://tenant.localhost:3000/"],
    );
  });

  it("normalizes explicit browser URLs without losing localhost subdomains", () => {
    assert.deepEqual(normalizeBrowserPreviewTargetUrl("http://0.0.0.0:3000/app"), {
      targetHost: "127.0.0.1",
      targetPort: 3000,
      scheme: "http",
      initialUrl: "http://127.0.0.1:3000/app",
      defaultLabel: "127.0.0.1:3000",
    });
    assert.deepEqual(
      normalizeBrowserPreviewTargetUrl("https://tenant.localhost:8443/docs"),
      {
        targetHost: "tenant.localhost",
        targetPort: 8443,
        scheme: "https",
        initialUrl: "https://tenant.localhost:8443/docs",
        defaultLabel: "tenant.localhost:8443",
      },
    );
    assert.deepEqual(normalizeBrowserPreviewTargetUrl("https://example.com/app"), {
      targetHost: "example.com",
      targetPort: 443,
      scheme: "https",
      initialUrl: "https://example.com/app",
      defaultLabel: "example.com",
    });
  });

  it("rejects unsafe browser URL schemes before launching Chromium", () => {
    assert.throws(
      () => normalizeBrowserPreviewTargetUrl("file:///etc/passwd"),
      /browser scheme must be http or https/,
    );
    assert.throws(
      () => normalizeBrowserPreviewTargetUrl("javascript:alert\\(1\\)"),
      /browser scheme must be http or https/,
    );
  });

  it("keys reusable previews by target and session scope", () => {
    const base = {
      targetHost: "127.0.0.1",
      targetPort: 3000,
      scheme: "http" as const,
      cwd: "/workspace",
      sessionId: "session-1",
      profileMode: "temporary" as const,
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
    assert.notEqual(
      browserPreviewReuseKey(base),
      browserPreviewReuseKey({ ...base, profileMode: "sidemesh" }),
    );
  });

  it("only follows safe browser navigation URLs from popups", () => {
    assert.equal(isBrowserNavigationUrl("https://accounts.google.com/"), true);
    assert.equal(isBrowserNavigationUrl("http://localhost:3000/login"), true);
    assert.equal(isBrowserNavigationUrl("file:///etc/passwd"), false);
    assert.equal(isBrowserNavigationUrl("javascript:alert(1)"), false);
    assert.equal(isBrowserNavigationUrl("not a url"), false);
  });

  it("parses Chrome singleton profile errors", () => {
    const details = parseChromeProfileSingletonError(
      [
        "Chromium exited before opening DevTools.",
        "[649051:649051:0521/070933.051854:ERROR:chrome/browser/process_singleton_posix.cc:363]",
        "The profile appears to be in use by another Google Chrome process (1353711) on another computer (cortex-dev).",
      ].join(" "),
    );

    assert.deepEqual(details, {
      pid: 1353711,
      hostname: "cortex-dev",
    });
  });

  it("clears stale Chrome singleton files when the referenced process is gone", async () => {
    const cleared: string[] = [];
    const recovered = await maybeRecoverStaleChromeSingletonProfile(
      "/tmp/sidemesh-browser-profiles/sidemesh",
      new Error(
        "The profile appears to be in use by another Google Chrome process (1353711) on another computer (cortex-dev).",
      ),
      {
        currentHostname: "devbox",
        getProcessCommand: async () => null,
        removeArtifacts: async (profileDir) => {
          cleared.push(profileDir);
        },
      },
    );

    assert.equal(recovered, true);
    assert.deepEqual(cleared, ["/tmp/sidemesh-browser-profiles/sidemesh"]);
  });

  it("keeps singleton files when a live Chrome process is using the same profile", async () => {
    let cleared = false;
    const recovered = await maybeRecoverStaleChromeSingletonProfile(
      "/tmp/sidemesh-browser-profiles/sidemesh",
      new Error(
        "The profile appears to be in use by another Google Chrome process (1353711) on another computer (cortex-dev).",
      ),
      {
        currentHostname: "devbox",
        getProcessCommand: async () =>
          "google-chrome --headless=new --user-data-dir=/tmp/sidemesh-browser-profiles/sidemesh about:blank",
        removeArtifacts: async () => {
          cleared = true;
        },
      },
    );

    assert.equal(recovered, false);
    assert.equal(cleared, false);
  });

  it("tracks page loading for the main frame and ignores subframes", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp, { mainFrameId: "main-frame" });
    const events: Array<Record<string, unknown>> = [];
    registry.broadcast = (_preview: unknown, payload: Record<string, unknown>) => {
      events.push(payload);
    };

    registry.registerPageLoadHandlers(preview, "session-1");

    cdp.emitSession("Page.frameStartedLoading", { frameId: "subframe-1" });
    assert.equal(preview.pageLoading, false);

    cdp.emitSession("Page.frameStartedLoading", { frameId: "main-frame" });
    assert.equal(preview.pageLoading, true);

    cdp.emitSession("Page.frameStoppedLoading", { frameId: "subframe-1" });
    assert.equal(preview.pageLoading, true);

    cdp.emitSession("Page.frameStoppedLoading", { frameId: "main-frame" });
    assert.equal(preview.pageLoading, false);

    assert.deepEqual(events, [
      { type: "loading", state: "started" },
      { type: "loading", state: "complete" },
    ]);
  });

  it("refreshes inspector and storage on loadEventFired even when loading start was missed", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp, {
      inspectorSnapshot: { selectedPath: [], warnings: [] },
    });
    let inspectorRefreshes = 0;
    let inspectorBroadcasts = 0;
    let storageRefreshes = 0;
    registry.refreshInspectorSnapshot = async () => {
      inspectorRefreshes += 1;
      return { selectedPath: [], warnings: [] };
    };
    registry.broadcastInspectorSnapshot = () => {
      inspectorBroadcasts += 1;
    };
    registry.scheduleStorageSnapshotRefresh = () => {
      storageRefreshes += 1;
    };

    registry.registerPageLoadHandlers(preview, "session-1");
    cdp.emitSession("Page.loadEventFired", {});
    await Promise.resolve();

    assert.equal(preview.pageLoading, false);
    assert.equal(inspectorRefreshes, 1);
    assert.equal(inspectorBroadcasts, 1);
    assert.equal(storageRefreshes, 1);
  });

  it("tracks network requests and emits summary updates", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    const events: Array<Record<string, unknown>> = [];
    registry.broadcast = (_preview: unknown, payload: Record<string, unknown>) => {
      events.push(payload);
    };

    registry.registerNetworkHandlers(preview, "session-1");

    cdp.emitSession("Network.requestWillBeSent", {
      requestId: "request-1",
      type: "Fetch",
      timestamp: 10,
      wallTime: 20,
      request: {
        method: "POST",
        url: "http://127.0.0.1:3000/api/search",
        headers: {
          accept: "application/json",
        },
      },
    });
    cdp.emitSession("Network.responseReceived", {
      requestId: "request-1",
      response: {
        status: 200,
        statusText: "OK",
        mimeType: "application/json",
        headers: {
          "content-type": "application/json",
        },
        fromDiskCache: false,
      },
    });
    cdp.emitSession("Network.requestServedFromCache", {
      requestId: "request-1",
    });
    cdp.emitSession("Network.loadingFinished", {
      requestId: "request-1",
      timestamp: 10.125,
      encodedDataLength: 512,
    });

    assert.equal(preview.networkEntries.size, 1);
    const entry = preview.networkEntries.get("request-1");
    assert.ok(entry);
    assert.equal(entry.method, "POST");
    assert.equal(entry.resourceType, "Fetch");
    assert.equal(entry.status, 200);
    assert.equal(entry.mimeType, "application/json");
    assert.equal(entry.servedFromCache, true);
    assert.equal(entry.encodedDataLength, 512);
    assert.equal(entry.durationMs, 125);

    assert.equal(events.length, 4);
    assert.deepEqual(events[0], {
      type: "network",
      entry: {
        requestId: "request-1",
        url: "http://127.0.0.1:3000/api/search",
        method: "POST",
        resourceType: "Fetch",
        status: null,
        mimeType: null,
        encodedDataLength: null,
        durationMs: null,
        startedAt: 20_000,
        errorText: null,
        finished: false,
        failed: false,
        servedFromCache: false,
        webSocketMessageCount: 0,
      },
    });
    assert.equal(events[3].type, "network");
    assert.equal((events[3].entry as any).durationMs, 125);
    assert.equal((events[3].entry as any).servedFromCache, true);
  });

  it("tracks websocket handshakes and frames", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    const events: Array<Record<string, unknown>> = [];
    registry.broadcast = (_preview: unknown, payload: Record<string, unknown>) => {
      events.push(payload);
    };

    registry.registerNetworkHandlers(preview, "session-1");

    cdp.emitSession("Network.webSocketWillSendHandshakeRequest", {
      requestId: "socket-1",
      timestamp: 10,
      wallTime: 20,
      request: {
        url: "ws://127.0.0.1:3000/socket",
        method: "GET",
        headers: {
          upgrade: "websocket",
          connection: "Upgrade",
        },
      },
    });
    cdp.emitSession("Network.webSocketHandshakeResponseReceived", {
      requestId: "socket-1",
      response: {
        status: 101,
        statusText: "Switching Protocols",
        headers: {
          upgrade: "websocket",
        },
      },
    });
    cdp.emitSession("Network.webSocketFrameSent", {
      requestId: "socket-1",
      timestamp: 10.1,
      response: {
        opcode: 1,
        payloadData: "ping",
      },
    });
    cdp.emitSession("Network.webSocketFrameReceived", {
      requestId: "socket-1",
      timestamp: 10.2,
      response: {
        opcode: 1,
        payloadData: "pong",
      },
    });
    cdp.emitSession("Network.webSocketClosed", {
      requestId: "socket-1",
      timestamp: 10.5,
    });

    const entry = preview.networkEntries.get("socket-1");
    assert.ok(entry);
    assert.equal(entry.resourceType, "WebSocket");
    assert.equal(entry.status, 101);
    assert.equal(entry.finished, true);
    assert.equal(entry.durationMs, 500);
    assert.equal(entry.webSocketMessages.length, 2);
    assert.deepEqual(entry.webSocketMessages[0], {
      direction: "sent",
      timestamp: 10_100,
      opcode: 1,
      payload: "ping",
      base64Encoded: false,
      error: null,
    });
    assert.equal((events.at(-1)?.entry as any).webSocketMessageCount, 2);

    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);
    await registry.sendNetworkDetail(preview, socket, "socket-1");

    assert.equal(cdp.sent.length, 0);
    assert.deepEqual(messages[0], {
      type: "networkDetail",
      requestId: "socket-1",
      detail: {
        requestId: "socket-1",
        url: "ws://127.0.0.1:3000/socket",
        method: "GET",
        resourceType: "WebSocket",
        status: 101,
        mimeType: null,
        encodedDataLength: null,
        durationMs: 500,
        startedAt: 20_000,
        errorText: null,
        finished: true,
        failed: false,
        servedFromCache: false,
        statusText: "Switching Protocols",
        requestHeaders: {
          upgrade: "websocket",
          connection: "Upgrade",
        },
        responseHeaders: {
          upgrade: "websocket",
        },
        requestBody: null,
        requestBodyError: null,
        body: null,
        bodyBase64Encoded: false,
        bodyError: null,
        webSocketMessages: [
          {
            direction: "sent",
            timestamp: 10_100,
            opcode: 1,
            payload: "ping",
            base64Encoded: false,
            error: null,
          },
          {
            direction: "received",
            timestamp: 10_200,
            opcode: 1,
            payload: "pong",
            base64Encoded: false,
            error: null,
          },
        ],
      },
    });
  });

  it("hydrates websocket timing from the handshake after early creation", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    registry.broadcast = () => {};

    registry.registerNetworkHandlers(preview, "session-1");

    cdp.emitSession("Network.webSocketCreated", {
      requestId: "socket-1",
      url: "ws://127.0.0.1:3000/socket",
    });
    const provisionalEntry = preview.networkEntries.get("socket-1");
    assert.ok(provisionalEntry);
    assert.equal(provisionalEntry.startTimestampSeconds, null);

    cdp.emitSession("Network.webSocketWillSendHandshakeRequest", {
      requestId: "socket-1",
      timestamp: 10,
      wallTime: 20,
      request: {
        url: "ws://127.0.0.1:3000/socket",
        method: "GET",
        headers: {},
      },
    });

    const entry = preview.networkEntries.get("socket-1");
    assert.ok(entry);
    assert.equal(entry.startedAt, 20_000);
    assert.equal(entry.startTimestampSeconds, 10);
  });

  it("tracks redirect hops as separate network rows", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    const events: Array<Record<string, unknown>> = [];
    registry.broadcast = (_preview: unknown, payload: Record<string, unknown>) => {
      events.push(payload);
    };

    registry.registerNetworkHandlers(preview, "session-1");

    cdp.emitSession("Network.requestWillBeSent", {
      requestId: "request-1",
      type: "Document",
      timestamp: 10,
      wallTime: 20,
      request: {
        method: "GET",
        url: "http://127.0.0.1:3000/start",
        headers: {},
      },
    });
    cdp.emitSession("Network.requestWillBeSent", {
      requestId: "request-1",
      type: "Document",
      timestamp: 10.05,
      wallTime: 20.05,
      redirectResponse: {
        status: 302,
        statusText: "Found",
        mimeType: "text/html",
        headers: {
          location: "/login",
        },
      },
      request: {
        method: "GET",
        url: "http://127.0.0.1:3000/login",
        headers: {},
      },
    });
    cdp.emitSession("Network.responseReceived", {
      requestId: "request-1",
      response: {
        status: 200,
        statusText: "OK",
        mimeType: "text/html",
        headers: {
          "content-type": "text/html",
        },
      },
    });
    cdp.emitSession("Network.loadingFinished", {
      requestId: "request-1",
      timestamp: 10.2,
      encodedDataLength: 256,
    });

    assert.equal(preview.networkEntries.size, 2);
    const redirectEntry = preview.networkEntries.get("request-1");
    const finalEntry = preview.networkEntries.get("request-1:redirect:1");
    assert.ok(redirectEntry);
    assert.ok(finalEntry);
    assert.equal(redirectEntry.status, 302);
    assert.equal(redirectEntry.finished, true);
    assert.equal(redirectEntry.isRedirectResponse, true);
    assert.equal(redirectEntry.durationMs, 50);
    assert.equal(finalEntry.status, 200);
    assert.equal(finalEntry.finished, true);
    assert.equal(finalEntry.durationMs, 150);
    assert.equal(preview.networkEntryIdsByRequestId.get("request-1"), "request-1:redirect:1");
    assert.equal((events[1].entry as any).requestId, "request-1");
    assert.equal((events[2].entry as any).requestId, "request-1:redirect:1");
  });

  it("ignores untracked data URLs in network logs", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    registry.broadcast = () => {};

    registry.registerNetworkHandlers(preview, "session-1");
    cdp.emitSession("Network.requestWillBeSent", {
      requestId: "request-1",
      type: "Image",
      timestamp: 10,
      wallTime: 20,
      request: {
        method: "GET",
        url: "data:image/png;base64,AAAA",
        headers: {},
      },
    });

    assert.equal(preview.networkEntries.size, 0);
  });

  it("returns network details with response bodies on demand", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    preview.status = "running";
    preview.sessionIdCdp = "session-1";
    preview.networkEntries.set("request-1", {
      requestId: "request-1",
      cdpRequestId: "request-1",
      redirectHop: 0,
      isRedirectResponse: false,
      url: "http://127.0.0.1:3000/app.js",
      method: "POST",
      resourceType: "Script",
      requestHeaders: { accept: "*/*" },
      responseHeaders: { "content-type": "text/javascript" },
      status: 200,
      statusText: "OK",
      mimeType: "text/javascript",
      encodedDataLength: 128,
      durationMs: 42,
      startedAt: 1,
      startTimestampSeconds: 1,
      errorText: null,
      finished: true,
      failed: false,
      servedFromCache: false,
      webSocketMessages: [],
    });
    cdp.sendResult = {
      body: '  console.log("ok")\n',
      base64Encoded: false,
      postData: '{"query":"ok"}',
    };
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);

    await registry.sendNetworkDetail(preview, socket, "request-1");

    assert.deepEqual(
      cdp.sent.map((item) => item.method),
      ["Network.getRequestPostData", "Network.getResponseBody"],
    );
    assert.deepEqual(messages[0], {
      type: "networkDetail",
      requestId: "request-1",
      detail: {
        requestId: "request-1",
        url: "http://127.0.0.1:3000/app.js",
        method: "POST",
        resourceType: "Script",
        status: 200,
        mimeType: "text/javascript",
        encodedDataLength: 128,
        durationMs: 42,
        startedAt: 1,
        errorText: null,
        finished: true,
        failed: false,
        servedFromCache: false,
        statusText: "OK",
        requestHeaders: { accept: "*/*" },
        responseHeaders: { "content-type": "text/javascript" },
        requestBody: '{"query":"ok"}',
        requestBodyError: null,
        body: '  console.log("ok")\n',
        bodyBase64Encoded: false,
        bodyError: null,
        webSocketMessages: [],
      },
    });
  });

  it("does not request response bodies for redirect responses", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    preview.networkEntries.set("request-1", {
      requestId: "request-1",
      cdpRequestId: "request-1",
      redirectHop: 0,
      isRedirectResponse: true,
      url: "http://127.0.0.1:3000/start",
      method: "GET",
      resourceType: "Document",
      requestHeaders: {},
      responseHeaders: { location: "/login" },
      status: 302,
      statusText: "Found",
      mimeType: "text/html",
      encodedDataLength: null,
      durationMs: 50,
      startedAt: 1,
      startTimestampSeconds: 1,
      errorText: null,
      finished: true,
      failed: false,
      servedFromCache: false,
      webSocketMessages: [],
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);

    await registry.sendNetworkDetail(preview, socket, "request-1");

    assert.equal(cdp.sent.length, 0);
    assert.equal(
      (messages[0].detail as any).bodyError,
      "Response body is not available for redirect responses.",
    );
  });

  it("returns storage snapshots on demand", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    cdp.sendHandler = async (method, params) => {
      if (method === "Network.getCookies") {
        assert.deepEqual(params, {
          urls: ["http://127.0.0.1:3000/app"],
        });
        return {
          cookies: [
            {
              name: "sid",
              value: "abc123",
              domain: "127.0.0.1",
              path: "/",
              expires: -1,
              size: 9,
              httpOnly: true,
              secure: false,
              session: true,
              sameSite: "Lax",
            },
          ],
        };
      }
      if (method === "IndexedDB.requestDatabaseNames") {
        assert.deepEqual(params, {
          securityOrigin: "http://127.0.0.1:3000",
        });
        return {
          databaseNames: ["app-cache"],
        };
      }
      if (method === "IndexedDB.requestDatabase") {
        assert.deepEqual(params, {
          securityOrigin: "http://127.0.0.1:3000",
          databaseName: "app-cache",
        });
        return {
          databaseWithObjectStores: {
            name: "app-cache",
            version: 3,
            objectStores: [
              {
                name: "items",
                keyPath: {
                  type: "string",
                  string: "id",
                },
                autoIncrement: false,
                indexes: [
                  {
                    name: "byUpdatedAt",
                    keyPath: {
                      type: "string",
                      string: "updatedAt",
                    },
                    unique: false,
                    multiEntry: false,
                  },
                ],
              },
            ],
          },
        };
      }
      if (method === "DOMStorage.getDOMStorageItems") {
        const storageId = (params.storageId ?? {}) as Record<string, unknown>;
        if (storageId.isLocalStorage === true) {
          return { entries: [["theme", "dark"]] };
        }
        return { entries: [["draft", "1"]] };
      }
      if (method === "Storage.getUsageAndQuota") {
        assert.deepEqual(params, {
          origin: "http://127.0.0.1:3000",
        });
        return {
          usage: 2_048,
          quota: 10_485_760,
          usageBreakdown: [
            { storageType: "indexeddb", usage: 1_536 },
            { storageType: "local_storage", usage: 512 },
          ],
        };
      }
      return {};
    };
    const preview = buildFakePreview(cdp, {
      url: "http://127.0.0.1:3000/app",
      status: "running",
      sessionIdCdp: "session-1",
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);

    await registry.sendStorageSnapshot(preview, socket);

    assert.deepEqual(
      cdp.sent.map((item) => item.method),
      [
        "Network.getCookies",
        "IndexedDB.requestDatabaseNames",
        "IndexedDB.requestDatabase",
        "DOMStorage.getDOMStorageItems",
        "DOMStorage.getDOMStorageItems",
        "Storage.getUsageAndQuota",
      ],
    );
    assert.equal(messages[0]?.type, "storageSnapshot");
    const snapshot = (messages[0]?.snapshot ?? {}) as Record<string, unknown>;
    assert.equal(snapshot.url, "http://127.0.0.1:3000/app");
    assert.equal(snapshot.origin, "http://127.0.0.1:3000");
    assert.equal(typeof snapshot.refreshedAt, "number");
    assert.deepEqual(snapshot.cookies, [
      {
        name: "sid",
        value: "abc123",
        domain: "127.0.0.1",
        path: "/",
        expires: null,
        size: 9,
        httpOnly: true,
        secure: false,
        session: true,
        sameSite: "Lax",
      },
    ]);
    assert.deepEqual(snapshot.indexedDbDatabases, [
      {
        name: "app-cache",
        version: 3,
        objectStores: [
          {
            name: "items",
            keyPath: "id",
            autoIncrement: false,
            indexes: [
              {
                name: "byUpdatedAt",
                keyPath: "updatedAt",
                unique: false,
                multiEntry: false,
              },
            ],
          },
        ],
      },
    ]);
    assert.deepEqual(snapshot.localStorage, [
      { key: "theme", value: "dark" },
    ]);
    assert.deepEqual(snapshot.sessionStorage, [
      { key: "draft", value: "1" },
    ]);
    assert.equal(snapshot.usage, 2_048);
    assert.equal(snapshot.quota, 10_485_760);
    assert.deepEqual(snapshot.usageBreakdown, [
      { storageType: "indexeddb", usage: 1_536 },
      { storageType: "local_storage", usage: 512 },
    ]);
    assert.deepEqual(snapshot.warnings, []);
    assert.deepEqual(preview.storageSnapshot, snapshot);
  });

  it("updates localStorage entries and broadcasts the refreshed snapshot", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp, {
      url: "http://127.0.0.1:3000/app",
      status: "running",
      sessionIdCdp: "session-1",
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);
    preview.clients.add(socket);

    cdp.sendHandler = async (method, params) => {
      if (method === "DOMStorage.setDOMStorageItem") {
        assert.deepEqual(params, {
          storageId: {
            securityOrigin: "http://127.0.0.1:3000",
            isLocalStorage: true,
          },
          key: "theme",
          value: "amber",
        });
        return {};
      }
      if (method === "IndexedDB.requestDatabaseNames") {
        return { databaseNames: [] };
      }
      if (method === "Network.getCookies") {
        return { cookies: [] };
      }
      if (method === "DOMStorage.getDOMStorageItems") {
        const storageId = (params.storageId ?? {}) as Record<string, unknown>;
        if (storageId.isLocalStorage === true) {
          return { entries: [["theme", "amber"]] };
        }
        return { entries: [["draft", "42"]] };
      }
      if (method === "Storage.getUsageAndQuota") {
        return {
          usage: 512,
          quota: 2048,
          usageBreakdown: [{ storageType: "local_storage", usage: 512 }],
        };
      }
      throw new Error(`Unexpected CDP method: ${method}`);
    };

    await registry.handleClientMessage(
      preview,
      socket,
      Buffer.from(
        JSON.stringify({
          type: "storageSetEntry",
          area: "localStorage",
          key: "theme",
          value: "amber",
        }),
      ),
    );

    assert.deepEqual(
      cdp.sent.map((item) => item.method),
      [
        "DOMStorage.setDOMStorageItem",
        "Network.getCookies",
        "IndexedDB.requestDatabaseNames",
        "DOMStorage.getDOMStorageItems",
        "DOMStorage.getDOMStorageItems",
        "Storage.getUsageAndQuota",
      ],
    );
    assert.equal(messages[0]?.type, "storageSnapshot");
    assert.deepEqual((messages[0]?.snapshot as any).localStorage, [
      { key: "theme", value: "amber" },
    ]);
    assert.deepEqual((messages[0]?.snapshot as any).sessionStorage, [
      { key: "draft", value: "42" },
    ]);
  });

  it("clears visible cookies and broadcasts the refreshed snapshot", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp, {
      url: "http://127.0.0.1:3000/app",
      status: "running",
      sessionIdCdp: "session-1",
      storageSnapshot: {
        url: "http://127.0.0.1:3000/app",
        origin: "http://127.0.0.1:3000",
        refreshedAt: 1,
        cookies: [
          {
            name: "sid",
            value: "abc",
            domain: "127.0.0.1",
            path: "/",
            expires: null,
            size: 3,
            httpOnly: true,
            secure: false,
            session: true,
            sameSite: "Lax",
          },
        ],
        indexedDbDatabases: [],
        localStorage: [],
        sessionStorage: [],
        usage: 0,
        quota: 2048,
        usageBreakdown: [],
        warnings: [],
      },
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);
    preview.clients.add(socket);

    let getCookiesCalls = 0;
    cdp.sendHandler = async (method, params) => {
      if (method === "Network.deleteCookies") {
        assert.deepEqual(params, {
          name: "sid",
          domain: "127.0.0.1",
          path: "/",
          url: "http://127.0.0.1:3000/app",
        });
        return {};
      }
      if (method === "IndexedDB.requestDatabaseNames") {
        return { databaseNames: [] };
      }
      if (method === "Network.getCookies") {
        getCookiesCalls += 1;
        return {
          cookies:
            getCookiesCalls === 1
              ? [
                  {
                    name: "sid",
                    value: "abc",
                    domain: "127.0.0.1",
                    path: "/",
                    expires: -1,
                    size: 3,
                    httpOnly: true,
                    secure: false,
                    session: true,
                    sameSite: "Lax",
                  },
                ]
              : [],
        };
      }
      if (method === "DOMStorage.getDOMStorageItems") {
        return { entries: [] };
      }
      if (method === "Storage.getUsageAndQuota") {
        return {
          usage: 0,
          quota: 2048,
          usageBreakdown: [],
        };
      }
      throw new Error(`Unexpected CDP method: ${method}`);
    };

    await registry.handleClientMessage(
      preview,
      socket,
      Buffer.from(JSON.stringify({ type: "storageClearCookies" })),
    );

    assert.deepEqual(
      cdp.sent.map((item) => item.method),
      [
        "Network.getCookies",
        "Network.deleteCookies",
        "Network.getCookies",
        "IndexedDB.requestDatabaseNames",
        "DOMStorage.getDOMStorageItems",
        "DOMStorage.getDOMStorageItems",
        "Storage.getUsageAndQuota",
      ],
    );
    assert.equal(messages[0]?.type, "storageSnapshot");
    assert.deepEqual((messages[0]?.snapshot as any).cookies, []);
  });

  it("clears cookies from current browser state instead of a stale cache", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp, {
      url: "http://127.0.0.1:3000/app",
      status: "running",
      sessionIdCdp: "session-1",
      storageSnapshot: {
        url: "http://127.0.0.1:3000/app",
        origin: "http://127.0.0.1:3000",
        refreshedAt: 1,
        cookies: [
          {
            name: "sid",
            value: "abc",
            domain: "127.0.0.1",
            path: "/",
            expires: null,
            size: 3,
            httpOnly: true,
            secure: false,
            session: true,
            sameSite: "Lax",
          },
        ],
        indexedDbDatabases: [],
        localStorage: [],
        sessionStorage: [],
        usage: 0,
        quota: 2048,
        usageBreakdown: [],
        warnings: [],
      },
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);
    preview.clients.add(socket);

    cdp.sendHandler = async (method, params) => {
      if (method === "Network.getCookies") {
        return {
          cookies: [
            {
              name: "sid",
              value: "abc",
              domain: "127.0.0.1",
              path: "/",
              expires: -1,
              size: 3,
              httpOnly: true,
              secure: false,
              session: true,
              sameSite: "Lax",
            },
            {
              name: "fresh",
              value: "new",
              domain: "127.0.0.1",
              path: "/",
              expires: -1,
              size: 3,
              httpOnly: false,
              secure: false,
              session: true,
              sameSite: "Lax",
            },
          ],
        };
      }
      if (method === "Network.deleteCookies") {
        return {};
      }
      if (method === "IndexedDB.requestDatabaseNames") {
        return { databaseNames: [] };
      }
      if (method === "DOMStorage.getDOMStorageItems") {
        return { entries: [] };
      }
      if (method === "Storage.getUsageAndQuota") {
        return {
          usage: 0,
          quota: 2048,
          usageBreakdown: [],
        };
      }
      throw new Error(`Unexpected CDP method: ${method}`);
    };

    await registry.handleClientMessage(
      preview,
      socket,
      Buffer.from(JSON.stringify({ type: "storageClearCookies" })),
    );

    const deleteCalls = cdp.sent.filter(
      (item) => item.method === "Network.deleteCookies",
    );
    assert.equal(deleteCalls.length, 2);
    assert.deepEqual(
      deleteCalls.map((item) => item.params.name),
      ["fresh", "sid"],
    );
    assert.equal(messages[0]?.type, "storageSnapshot");
  });

  it("refreshes storage snapshots after DOMStorage events", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp, {
      url: "http://127.0.0.1:3000/app",
      status: "running",
      sessionIdCdp: "session-1",
      storageSnapshot: {
        url: "http://127.0.0.1:3000/app",
        origin: "http://127.0.0.1:3000",
        refreshedAt: 1,
        cookies: [],
        indexedDbDatabases: [],
        localStorage: [{ key: "theme", value: "dark" }],
        sessionStorage: [],
        usage: 128,
        quota: 2048,
        usageBreakdown: [{ storageType: "local_storage", usage: 128 }],
        warnings: [],
      },
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);
    preview.clients.add(socket);

    cdp.sendHandler = async (method, params) => {
      if (method === "IndexedDB.requestDatabaseNames") {
        return { databaseNames: [] };
      }
      if (method === "Network.getCookies") {
        return { cookies: [] };
      }
      if (method === "DOMStorage.getDOMStorageItems") {
        const storageId = (params.storageId ?? {}) as Record<string, unknown>;
        if (storageId.isLocalStorage === true) {
          return { entries: [["theme", "amber"]] };
        }
        return { entries: [] };
      }
      if (method === "Storage.getUsageAndQuota") {
        return {
          usage: 256,
          quota: 2048,
          usageBreakdown: [{ storageType: "local_storage", usage: 256 }],
        };
      }
      throw new Error(`Unexpected CDP method: ${method}`);
    };

    registry.registerStorageHandlers(preview, "session-1");
    cdp.emitSession("DOMStorage.domStorageItemUpdated", {
      storageId: {
        securityOrigin: "http://127.0.0.1:3000",
        isLocalStorage: true,
      },
      key: "theme",
      oldValue: "dark",
      newValue: "amber",
    });

    await new Promise((resolve) => setTimeout(resolve, 220));

    assert.equal(messages[0]?.type, "storageSnapshot");
    assert.deepEqual((messages[0]?.snapshot as any).localStorage, [
      { key: "theme", value: "amber" },
    ]);
  });

  it("returns inspector snapshots on demand", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    cdp.sendHandler = async (method, params, sessionId) => {
      assert.equal(method, "Runtime.evaluate");
      assert.equal(sessionId, "session-1");
      assert.equal(params.returnByValue, true);
      assert.equal(params.awaitPromise, true);
      assert.match(String(params.expression), /"selectedPath":null/);
      assert.match(String(params.expression), /"inspectPoint":null/);
      return {
        result: {
          value: {
            selectedPath: [0, 1],
            treeRoot: {
              path: [],
              nodeName: "html",
              selector: "html",
              textPreview: null,
              childElementCount: 1,
              isSelected: false,
              truncatedChildren: false,
              children: [
                {
                  path: [0],
                  nodeName: "body",
                  selector: "body",
                  textPreview: "Hello",
                  childElementCount: 1,
                  isSelected: false,
                  truncatedChildren: false,
                  children: [
                    {
                      path: [0, 1],
                      nodeName: "main",
                      selector: "main#app.shell",
                      textPreview: "Inspector",
                      childElementCount: 0,
                      isSelected: true,
                      truncatedChildren: false,
                      children: [],
                    },
                  ],
                },
              ],
            },
            selectedNode: {
              path: [0, 1],
              nodeName: "main",
              selector: "main#app.shell",
              textPreview: "Inspector",
              childElementCount: 0,
              isSelected: true,
              truncatedChildren: false,
              children: [],
              attributes: [
                { name: "id", value: "app" },
                { name: "class", value: "shell" },
              ],
              computedStyles: [{ name: "display", value: "block" }],
              inlineStyles: [{ name: "color", value: "red" }],
              box: {
                x: 12.5,
                y: 44.25,
                width: 320,
                height: 180,
              },
            },
            warnings: ["The selected element is no longer available."],
          },
        },
      };
    };
    const preview = buildFakePreview(cdp, {
      url: "http://127.0.0.1:3000/app",
      status: "running",
      sessionIdCdp: "session-1",
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);

    await registry.sendInspectorSnapshot(preview, socket);

    assert.deepEqual(
      cdp.sent.map((item) => item.method),
      ["Runtime.evaluate"],
    );
    assert.equal(messages[0]?.type, "inspectorSnapshot");
    assert.equal((messages[0]?.snapshot as any).url, "http://127.0.0.1:3000/app");
    assert.deepEqual((messages[0]?.snapshot as any).selectedPath, [0, 1]);
    assert.equal(
      (messages[0]?.snapshot as any).selectedNode?.selector,
      "main#app.shell",
    );
    assert.deepEqual(
      (messages[0]?.snapshot as any).warnings,
      ["The selected element is no longer available."],
    );
    assert.deepEqual(preview.inspectorSelectedPath, [0, 1]);
    assert.equal(preview.inspectorSnapshot?.selectedNode?.box?.height, 180);
  });

  it("selects inspector nodes by path and broadcasts refreshed snapshots", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    cdp.sendHandler = async (method, params) => {
      assert.equal(method, "Runtime.evaluate");
      assert.match(String(params.expression), /"selectedPath":\[1,2\]/);
      return {
        result: {
          value: {
            selectedPath: [1, 2],
            treeRoot: {
              path: [],
              nodeName: "html",
              selector: "html",
              textPreview: null,
              childElementCount: 0,
              isSelected: false,
              truncatedChildren: false,
              children: [],
            },
            selectedNode: {
              path: [1, 2],
              nodeName: "button",
              selector: "button.cta",
              textPreview: "Deploy",
              childElementCount: 0,
              isSelected: true,
              truncatedChildren: false,
              children: [],
              attributes: [{ name: "class", value: "cta" }],
              computedStyles: [{ name: "display", value: "inline-flex" }],
              inlineStyles: [],
              box: { x: 30, y: 80, width: 120, height: 44 },
            },
            warnings: [],
          },
        },
      };
    };
    const preview = buildFakePreview(cdp, {
      status: "running",
      sessionIdCdp: "session-1",
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);
    preview.clients.add(socket);

    await registry.handleClientMessage(
      preview,
      socket,
      Buffer.from(
        JSON.stringify({
          type: "inspectorSelectPath",
          path: [1, 2],
        }),
      ),
    );

    assert.deepEqual(
      cdp.sent.map((item) => item.method),
      ["Runtime.evaluate"],
    );
    assert.equal(messages[0]?.type, "inspectorSnapshot");
    assert.deepEqual((messages[0]?.snapshot as any).selectedPath, [1, 2]);
    assert.equal(
      (messages[0]?.snapshot as any).selectedNode?.selector,
      "button.cta",
    );
    assert.deepEqual(preview.inspectorSelectedPath, [1, 2]);
  });

  it("inspects preview points and broadcasts refreshed snapshots", async () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    cdp.sendHandler = async (method, params) => {
      assert.equal(method, "Runtime.evaluate");
      assert.match(String(params.expression), /"inspectPoint":\{"x":195,"y":211\}/);
      return {
        result: {
          value: {
            selectedPath: [0, 0],
            treeRoot: {
              path: [],
              nodeName: "html",
              selector: "html",
              textPreview: null,
              childElementCount: 0,
              isSelected: false,
              truncatedChildren: false,
              children: [],
            },
            selectedNode: {
              path: [0, 0],
              nodeName: "section",
              selector: "section.hero",
              textPreview: "Ship faster",
              childElementCount: 0,
              isSelected: true,
              truncatedChildren: false,
              children: [],
              attributes: [{ name: "class", value: "hero" }],
              computedStyles: [{ name: "display", value: "block" }],
              inlineStyles: [],
              box: { x: 24, y: 96, width: 342, height: 220 },
            },
            warnings: [],
          },
        },
      };
    };
    const preview = buildFakePreview(cdp, {
      status: "running",
      sessionIdCdp: "session-1",
      width: 390,
      height: 844,
    });
    const messages: Array<Record<string, unknown>> = [];
    const socket = createFakeSocket(messages);
    preview.clients.add(socket);

    await registry.handleClientMessage(
      preview,
      socket,
      Buffer.from(
        JSON.stringify({
          type: "inspectorInspectPoint",
          x: 0.5,
          y: 0.25,
        }),
      ),
    );

    assert.deepEqual(
      cdp.sent.map((item) => item.method),
      ["Runtime.evaluate"],
    );
    assert.equal(messages[0]?.type, "inspectorSnapshot");
    assert.deepEqual((messages[0]?.snapshot as any).selectedPath, [0, 0]);
    assert.equal(
      (messages[0]?.snapshot as any).selectedNode?.selector,
      "section.hero",
    );
  });

  it("sends an authoritative network snapshot on attach", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const preview = buildFakePreview(new FakeCdpConnection(), {
      status: "starting",
      starting: new Promise<void>(() => {}),
    });
    registry.previews.set(preview.id, preview);
    const socket = new FakeAttachSocket();

    registry.attach(socket as unknown as WebSocket, preview.id);

    assert.equal(socket.frames[0]?.type, "hello");
    assert.deepEqual(socket.frames[1], {
      type: "consoleSnapshot",
      entries: [],
    });
    assert.deepEqual(socket.frames[2], {
      type: "networkSnapshot",
      entries: [],
    });
  });

  it("sends cached inspector snapshots on attach", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const preview = buildFakePreview(new FakeCdpConnection(), {
      status: "starting",
      starting: new Promise<void>(() => {}),
      inspectorSnapshot: {
        url: "http://127.0.0.1:3000/app",
        refreshedAt: 123,
        selectedPath: [0],
        treeRoot: {
          path: [],
          nodeName: "html",
          selector: "html",
          textPreview: null,
          childElementCount: 1,
          isSelected: false,
          truncatedChildren: false,
          children: [],
        },
        selectedNode: {
          path: [0],
          nodeName: "body",
          selector: "body",
          textPreview: "Hello",
          childElementCount: 0,
          isSelected: true,
          truncatedChildren: false,
          children: [],
          attributes: [],
          computedStyles: [],
          inlineStyles: [],
          box: { x: 0, y: 0, width: 390, height: 844 },
        },
        warnings: [],
      },
    });
    registry.previews.set(preview.id, preview);
    const socket = new FakeAttachSocket();

    registry.attach(socket as unknown as WebSocket, preview.id);

    assert.deepEqual(socket.frames[3], {
      type: "inspectorSnapshot",
      snapshot: preview.inspectorSnapshot,
    });
  });

  it("sends a console snapshot on attach and flushes pending entries", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const preview = buildFakePreview(new FakeCdpConnection(), {
      status: "starting",
      starting: new Promise<void>(() => {}),
      consoleHistory: [
        {
          seq: 1,
          type: "console",
          level: "log",
          text: "ready",
          args: [],
          url: null,
          lineNumber: null,
          columnNumber: null,
          source: null,
          timestamp: 1,
        },
      ],
      consoleBuffer: [
        {
          seq: 2,
          type: "exception",
          level: "error",
          text: "boom",
          args: [],
          url: "http://127.0.0.1:3000/app.js",
          lineNumber: 4,
          columnNumber: 2,
          source: null,
          timestamp: 2,
        },
      ],
    });
    registry.previews.set(preview.id, preview);
    const socket = new FakeAttachSocket();

    registry.attach(socket as unknown as WebSocket, preview.id);

    assert.deepEqual(socket.frames[1], {
      type: "consoleSnapshot",
      entries: [
        {
          seq: 1,
          type: "console",
          level: "log",
          text: "ready",
          args: [],
          url: null,
          lineNumber: null,
          columnNumber: null,
          source: null,
          timestamp: 1,
        },
        {
          seq: 2,
          type: "exception",
          level: "error",
          text: "boom",
          args: [],
          url: "http://127.0.0.1:3000/app.js",
          lineNumber: 4,
          columnNumber: 2,
          source: null,
          timestamp: 2,
        },
      ],
    });
    assert.equal(preview.consoleBuffer.length, 0);
    assert.equal(preview.consoleHistory.length, 2);
  });

  it("normalizes console timestamps from CDP seconds", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const cdp = new FakeCdpConnection();
    const preview = buildFakePreview(cdp);
    registry.broadcast = () => {};

    registry.registerConsoleHandlers(preview, "session-1");

    cdp.emitSession("Runtime.exceptionThrown", {
      timestamp: 10.5,
      exceptionDetails: {
        text: "boom",
        url: "http://127.0.0.1:3000/app.js",
        lineNumber: 4,
        columnNumber: 2,
      },
    });
    cdp.emitSession("Log.entryAdded", {
      entry: {
        level: "warning",
        source: "network",
        text: "late header",
        url: "http://127.0.0.1:3000/app.js",
        lineNumber: 8,
        timestamp: 10.25,
      },
    });

    registry.flushConsoleBuffer(preview);

    assert.deepEqual(
      preview.consoleHistory.map((entry: { timestamp: number }) => entry.timestamp),
      [10_500, 10_250],
    );
  });

  it("reports unavailable network inspection on attach", () => {
    const registry = new BrowserPreviewRegistry({ enabled: true }) as any;
    const preview = buildFakePreview(new FakeCdpConnection(), {
      status: "starting",
      starting: new Promise<void>(() => {}),
      networkUnavailableMessage:
        "Network inspection is unavailable: Network domain is not supported.",
    });
    registry.previews.set(preview.id, preview);
    const socket = new FakeAttachSocket();

    registry.attach(socket as unknown as WebSocket, preview.id);

    assert.deepEqual(socket.frames[1], {
      type: "consoleSnapshot",
      entries: [],
    });
    assert.deepEqual(socket.frames[2], {
      type: "networkStatus",
      available: false,
      message:
        "Network inspection is unavailable: Network domain is not supported.",
    });
    assert.deepEqual(socket.frames[3], {
      type: "networkSnapshot",
      entries: [],
    });
  });
});

class FakeCdpConnection {
  public sendResult: Record<string, unknown> = {};
  public sendHandler:
    | ((
        method: string,
        params: Record<string, unknown>,
        sessionId?: string | null,
      ) => Promise<Record<string, unknown>> | Record<string, unknown>)
    | null = null;
  public readonly sent: Array<{
    method: string;
    params: Record<string, unknown>;
    sessionId?: string | null;
  }> = [];
  private readonly sessionListeners = new Map<
    string,
    Array<(params: Record<string, unknown>) => void>
  >();

  public onSessionEvent(
    _sessionId: string,
    method: string,
    listener: (params: Record<string, unknown>) => void,
  ): () => void {
    const listeners = this.sessionListeners.get(method) ?? [];
    listeners.push(listener);
    this.sessionListeners.set(method, listeners);
    return () => {
      const current = this.sessionListeners.get(method) ?? [];
      this.sessionListeners.set(
        method,
        current.filter((item) => item !== listener),
      );
    };
  }

  public emitSession(method: string, params: Record<string, unknown>): void {
    for (const listener of this.sessionListeners.get(method) ?? []) {
      listener(params);
    }
  }

  public async send(
    method: string,
    params: Record<string, unknown> = {},
    sessionId?: string | null,
  ): Promise<Record<string, unknown>> {
    this.sent.push({ method, params, sessionId });
    if (this.sendHandler) {
      return await this.sendHandler(method, params, sessionId);
    }
    return this.sendResult;
  }
}

function buildFakePreview(
  cdp: FakeCdpConnection,
  overrides: Record<string, unknown> = {},
): any {
  return {
    id: "preview-1",
    label: "Preview",
    url: "http://127.0.0.1:3000/",
    targetHost: "127.0.0.1",
    targetPort: 3000,
    scheme: "http",
    cwd: null,
    sessionId: null,
    profileMode: "temporary",
    status: "running",
    width: 390,
    height: 844,
    createdAt: 1,
    updatedAt: 1,
    lastClientAt: null,
    lastFrameAt: null,
    lastError: null,
    clients: new Set(),
    userDataDir: null,
    process: null,
    cdp,
    sessionIdCdp: "session-1",
    targetId: "target-1",
    mainFrameId: null,
    ownsBrowser: false,
    nextFrameSeq: 1,
    lastFramePayload: null,
    frameTimer: null,
    starting: null,
    capturingFrame: false,
    consoleBuffer: [],
    consoleHistory: [],
    nextConsoleSeq: 1,
    consoleFlushTimer: null,
    networkEntries: new Map(),
    networkEntryIdsByRequestId: new Map(),
    networkRedirectCountsByRequestId: new Map(),
    networkUnavailableMessage: null,
    inspectorSnapshot: null,
    inspectorSelectedPath: null,
    storageSnapshot: null,
    storageRefreshTimer: null,
    pageLoading: false,
    cleanupHandlers: [],
    ...overrides,
  };
}

function createFakeSocket(
  messages: Array<Record<string, unknown>>,
): WebSocket {
  return {
    OPEN: 1,
    readyState: 1,
    bufferedAmount: 0,
    send(payload: string) {
      messages.push(JSON.parse(payload) as Record<string, unknown>);
    },
  } as unknown as WebSocket;
}

class FakeAttachSocket extends EventEmitter {
  public readonly OPEN = 1;
  public readyState = 1;
  public bufferedAmount = 0;
  public readonly frames: Array<Record<string, unknown>> = [];

  public send(payload: string): void {
    this.frames.push(JSON.parse(payload) as Record<string, unknown>);
  }

  public close(): void {
    this.readyState = 3;
    this.emit("close");
  }
}
