import { randomUUID } from "node:crypto";
import { access, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { EventEmitter, once } from "node:events";
import type { Readable } from "node:stream";

import { WebSocket } from "ws";

const DEFAULT_MAX_PREVIEWS = 8;
const DEFAULT_IDLE_TTL_MS = 60 * 60 * 1000;
const DEFAULT_FRAME_INTERVAL_MS = 900;
const DEFAULT_WIDTH = 390;
const DEFAULT_HEIGHT = 844;
const DEFAULT_QUALITY = 55;
const CHROME_START_TIMEOUT_MS = 10_000;
const CDP_COMMAND_TIMEOUT_MS = 15_000;
const CHROME_SHUTDOWN_TIMEOUT_MS = 2_000;
const MAX_TEXT_INPUT_CHARS = 20_000;
const MAX_CLIENT_BUFFERED_AMOUNT = 8 * 1024 * 1024;
const MAX_CONSOLE_BUFFER = 256;
const CONSOLE_FLUSH_INTERVAL_MS = 500;
const CONSOLE_FLUSH_THRESHOLD = 32;
const MAX_NETWORK_ENTRIES = 300;
const MAX_WEBSOCKET_MESSAGES_PER_ENTRY = 100;
const MIN_VIEWPORT_SIZE = 240;
const MAX_VIEWPORT_WIDTH = 3840;
const MAX_VIEWPORT_HEIGHT = 2160;
const INSPECTOR_MAX_CHILDREN = 24;
const INSPECTOR_MAX_TEXT_PREVIEW = 160;
const INSPECTOR_COMPUTED_STYLE_NAMES = [
  "display",
  "position",
  "top",
  "right",
  "bottom",
  "left",
  "z-index",
  "width",
  "height",
  "min-width",
  "min-height",
  "max-width",
  "max-height",
  "margin",
  "padding",
  "color",
  "background-color",
  "font-size",
  "font-weight",
  "line-height",
  "text-align",
  "opacity",
  "overflow",
  "transform",
  "flex",
  "flex-direction",
  "justify-content",
  "align-items",
  "grid-template-columns",
  "grid-template-rows",
] as const;

const SIDEMESH_BROWSER_PROFILE_DIR = "sidemesh";

type BrowserProcess = ChildProcessByStdio<null, Readable, Readable>;

export type BrowserPreviewStatus = "starting" | "running" | "stopped" | "failed";
export type BrowserPreviewScheme = "http" | "https";
export type BrowserPreviewProfileMode = "temporary" | "sidemesh";

export interface BrowserPreviewRegistryOptions {
  enabled: boolean;
  chromePath?: string | null;
  persistentProfileRoot?: string | null;
  maxPreviews?: number;
  idleTtlMs?: number;
  frameIntervalMs?: number;
  quality?: number;
}

export interface CreateBrowserPreviewRequest {
  targetHost?: string | null;
  targetPort?: number | null;
  targetUrl?: string | null;
  scheme?: string | null;
  label?: string | null;
  cwd?: string | null;
  sessionId?: string | null;
  width?: number | null;
  height?: number | null;
  profileMode?: string | null;
}

export interface BrowserPreviewInfo {
  id: string;
  label: string;
  url: string;
  targetHost: string;
  targetPort: number;
  scheme: BrowserPreviewScheme;
  cwd: string | null;
  sessionId: string | null;
  profileMode: BrowserPreviewProfileMode;
  status: BrowserPreviewStatus;
  width: number;
  height: number;
  clients: number;
  createdAt: number;
  updatedAt: number;
  lastClientAt: number | null;
  lastFrameAt: number | null;
  lastError: string | null;
}

export interface BrowserPreviewReuseCriteria {
  targetHost: string;
  targetPort: number;
  scheme: BrowserPreviewScheme;
  cwd: string | null;
  sessionId: string | null;
  profileMode: BrowserPreviewProfileMode;
}

interface BrowserPreviewRecord {
  id: string;
  label: string;
  url: string;
  initialUrl: string | null;
  targetHost: string;
  targetPort: number;
  scheme: BrowserPreviewScheme;
  cwd: string | null;
  sessionId: string | null;
  profileMode: BrowserPreviewProfileMode;
  status: BrowserPreviewStatus;
  width: number;
  height: number;
  createdAt: number;
  updatedAt: number;
  lastClientAt: number | null;
  lastFrameAt: number | null;
  lastError: string | null;
  clients: Set<WebSocket>;
  userDataDir: string | null;
  process: BrowserProcess | null;
  cdp: CdpConnection | null;
  sessionIdCdp: string | null;
  targetId: string | null;
  mainFrameId: string | null;
  ownsBrowser: boolean;
  nextFrameSeq: number;
  lastFramePayload: Record<string, unknown> | null;
  frameTimer: NodeJS.Timeout | null;
  starting: Promise<void> | null;
  capturingFrame: boolean;
  consoleBuffer: BrowserPreviewConsoleEntry[];
  consoleHistory: BrowserPreviewConsoleEntry[];
  nextConsoleSeq: number;
  consoleFlushTimer: NodeJS.Timeout | null;
  networkEntries: Map<string, BrowserPreviewNetworkEntry>;
  networkEntryIdsByRequestId: Map<string, string>;
  networkRedirectCountsByRequestId: Map<string, number>;
  networkUnavailableMessage: string | null;
  inspectorSnapshot: BrowserPreviewInspectorSnapshot | null;
  inspectorSelectedPath: number[] | null;
  storageSnapshot: BrowserPreviewStorageSnapshot | null;
  storageRefreshTimer: NodeJS.Timeout | null;
  pageLoading: boolean;
  cleanupHandlers: Array<() => void>;
}

interface PersistentBrowserHost {
  userDataDir: string;
  process: BrowserProcess;
  cdp: CdpConnection;
}

interface BrowserPreviewConsoleEntry {
  seq: number;
  type: "console" | "exception" | "log";
  level: string;
  text: string;
  args: Array<Record<string, unknown>>;
  url: string | null;
  lineNumber: number | null;
  columnNumber: number | null;
  source: string | null;
  timestamp: number;
}

interface BrowserPreviewNetworkMessage {
  direction: "sent" | "received" | "error";
  timestamp: number;
  opcode: number | null;
  payload: string | null;
  base64Encoded: boolean;
  error: string | null;
}

interface BrowserPreviewNetworkEntry {
  requestId: string;
  cdpRequestId: string;
  redirectHop: number;
  isRedirectResponse: boolean;
  url: string;
  method: string;
  resourceType: string;
  requestHeaders: Record<string, string>;
  responseHeaders: Record<string, string>;
  status: number | null;
  statusText: string | null;
  mimeType: string | null;
  encodedDataLength: number | null;
  durationMs: number | null;
  startedAt: number;
  startTimestampSeconds: number | null;
  errorText: string | null;
  finished: boolean;
  failed: boolean;
  servedFromCache: boolean;
  webSocketMessages: BrowserPreviewNetworkMessage[];
}

interface BrowserPreviewNetworkDetail {
  requestId: string;
  url: string;
  method: string;
  resourceType: string;
  status: number | null;
  mimeType: string | null;
  encodedDataLength: number | null;
  durationMs: number | null;
  startedAt: number;
  errorText: string | null;
  finished: boolean;
  failed: boolean;
  servedFromCache: boolean;
  statusText: string | null;
  requestHeaders: Record<string, string>;
  responseHeaders: Record<string, string>;
  requestBody: string | null;
  requestBodyError: string | null;
  body: string | null;
  bodyBase64Encoded: boolean;
  bodyError: string | null;
  webSocketMessages: BrowserPreviewNetworkMessage[];
}

interface NormalizedBrowserPreviewTarget {
  targetHost: string;
  targetPort: number;
  scheme: BrowserPreviewScheme;
  initialUrl: string | null;
  defaultLabel: string;
}

interface BrowserPreviewStorageEntry {
  key: string;
  value: string;
}

type BrowserPreviewStorageArea = "localStorage" | "sessionStorage";

interface BrowserPreviewStorageUsage {
  storageType: string;
  usage: number;
}

interface BrowserPreviewStorageCookie {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires: number | null;
  size: number | null;
  httpOnly: boolean;
  secure: boolean;
  session: boolean;
  sameSite: string | null;
}

interface BrowserPreviewIndexedDbIndex {
  name: string;
  keyPath: string | null;
  unique: boolean;
  multiEntry: boolean;
}

interface BrowserPreviewIndexedDbObjectStore {
  name: string;
  keyPath: string | null;
  autoIncrement: boolean;
  indexes: BrowserPreviewIndexedDbIndex[];
}

interface BrowserPreviewIndexedDbDatabase {
  name: string;
  version: number | null;
  objectStores: BrowserPreviewIndexedDbObjectStore[];
}

interface BrowserPreviewInspectorNode {
  path: number[];
  nodeName: string;
  selector: string;
  textPreview: string | null;
  childElementCount: number;
  isSelected: boolean;
  truncatedChildren: boolean;
  children: BrowserPreviewInspectorNode[];
}

interface BrowserPreviewInspectorAttribute {
  name: string;
  value: string;
}

interface BrowserPreviewInspectorStyleProperty {
  name: string;
  value: string;
}

interface BrowserPreviewInspectorBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface BrowserPreviewInspectorSelectedNode extends BrowserPreviewInspectorNode {
  attributes: BrowserPreviewInspectorAttribute[];
  computedStyles: BrowserPreviewInspectorStyleProperty[];
  inlineStyles: BrowserPreviewInspectorStyleProperty[];
  box: BrowserPreviewInspectorBox | null;
}

interface BrowserPreviewInspectorSnapshot {
  url: string;
  refreshedAt: number;
  selectedPath: number[];
  treeRoot: BrowserPreviewInspectorNode | null;
  selectedNode: BrowserPreviewInspectorSelectedNode | null;
  warnings: string[];
}

interface BrowserPreviewStorageSnapshot {
  url: string;
  origin: string | null;
  refreshedAt: number;
  cookies: BrowserPreviewStorageCookie[];
  indexedDbDatabases: BrowserPreviewIndexedDbDatabase[];
  localStorage: BrowserPreviewStorageEntry[];
  sessionStorage: BrowserPreviewStorageEntry[];
  usage: number | null;
  quota: number | null;
  usageBreakdown: BrowserPreviewStorageUsage[];
  warnings: string[];
}

export class BrowserPreviewRegistry {
  private readonly previews = new Map<string, BrowserPreviewRecord>();
  private readonly enabled: boolean;
  private readonly chromePath: string | null;
  private readonly persistentProfileRoot: string;
  private readonly maxPreviews: number;
  private readonly idleTtlMs: number;
  private readonly frameIntervalMs: number;
  private readonly quality: number;
  private cleanupTimer: NodeJS.Timeout | null = null;
  private persistentHost: PersistentBrowserHost | null = null;
  private persistentHostStarting: Promise<PersistentBrowserHost> | null = null;

  public constructor(options: BrowserPreviewRegistryOptions) {
    this.enabled = options.enabled;
    this.chromePath = options.chromePath?.trim() || null;
    this.persistentProfileRoot =
      options.persistentProfileRoot?.trim() ||
      path.join(tmpdir(), "sidemesh-browser-profiles");
    this.maxPreviews = clampInteger(
      options.maxPreviews ?? DEFAULT_MAX_PREVIEWS,
      1,
      32,
    );
    this.idleTtlMs = clampInteger(
      options.idleTtlMs ?? DEFAULT_IDLE_TTL_MS,
      30_000,
      24 * 60 * 60 * 1000,
    );
    this.frameIntervalMs = clampInteger(
      options.frameIntervalMs ?? DEFAULT_FRAME_INTERVAL_MS,
      250,
      10_000,
    );
    this.quality = clampInteger(options.quality ?? DEFAULT_QUALITY, 20, 95);
    if (this.enabled) {
      this.cleanupTimer = setInterval(() => void this.cleanup(), 60_000);
      this.cleanupTimer.unref?.();
    }
  }

  public isEnabled(): boolean {
    return this.enabled;
  }

  public list(): BrowserPreviewInfo[] {
    return [...this.previews.values()]
      .map((preview) => this.info(preview))
      .sort((left, right) => right.updatedAt - left.updatedAt);
  }

  public async create(
    request: CreateBrowserPreviewRequest,
  ): Promise<BrowserPreviewInfo> {
    this.assertEnabled();

    const target = normalizeCreateTarget(request);
    const width = normalizeViewportSize(
      request.width,
      DEFAULT_WIDTH,
      MAX_VIEWPORT_WIDTH,
    );
    const height = normalizeViewportSize(
      request.height,
      DEFAULT_HEIGHT,
      MAX_VIEWPORT_HEIGHT,
    );
    const cwd = request.cwd?.trim() || null;
    const sessionId = request.sessionId?.trim() || null;
    const profileMode = normalizeProfileMode(request.profileMode);
    let reusable = this.findReusablePreview({
      targetHost: target.targetHost,
      targetPort: target.targetPort,
      scheme: target.scheme,
      cwd,
      sessionId,
      profileMode,
    });
    if (reusable && this.isPreviewUnhealthy(reusable)) {
      await this.stopRecord(reusable, "failed");
      reusable = null;
    }
    if (reusable) {
      await this.updatePreviewViewport(reusable, width, height);
      if (request.label?.trim()) {
        reusable.label = request.label.trim();
      }
      reusable.updatedAt = Date.now();
      if (reusable.starting) {
        await reusable.starting;
      }
      if (target.initialUrl && reusable.url !== target.initialUrl) {
        await this.navigatePreviewToUrl(reusable, target.initialUrl);
      }
      return this.info(reusable);
    }

    this.enforcePreviewLimit();

    const url =
      target.initialUrl ??
      buildBrowserTargetUrlCandidates(
        target.scheme,
        target.targetHost,
        target.targetPort,
      )[0];
    const now = Date.now();
    const preview: BrowserPreviewRecord = {
      id: randomUUID(),
      label: request.label?.trim() || target.defaultLabel,
      url,
      initialUrl: target.initialUrl,
      targetHost: target.targetHost,
      targetPort: target.targetPort,
      scheme: target.scheme,
      cwd,
      sessionId,
      profileMode,
      status: "starting",
      width,
      height,
      createdAt: now,
      updatedAt: now,
      lastClientAt: null,
      lastFrameAt: null,
      lastError: null,
      clients: new Set(),
      userDataDir: null,
      process: null,
      cdp: null,
      sessionIdCdp: null,
      targetId: null,
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
    };
    this.previews.set(preview.id, preview);
    preview.starting = this.startPreview(preview);
    await preview.starting;
    return this.info(preview);
  }

  public async stop(id: string): Promise<BrowserPreviewInfo> {
    this.assertEnabled();
    const preview = this.requirePreview(id);
    await this.stopRecord(preview, "stopped");
    return this.info(preview);
  }

  public attach(socket: WebSocket, id: string): void {
    if (!this.enabled) {
      sendJson(socket, {
        type: "error",
        message: "browser preview is disabled",
      });
      socket.close();
      return;
    }
    const preview = this.previews.get(id);
    if (
      !preview ||
      preview.status === "stopped" ||
      preview.status === "failed"
    ) {
      sendJson(socket, { type: "error", message: "browser preview not found" });
      socket.close();
      return;
    }

    this.flushConsoleBuffer(preview);
    preview.clients.add(socket);
    preview.lastClientAt = Date.now();
    preview.updatedAt = preview.lastClientAt;
    sendJson(socket, { type: "hello", preview: this.info(preview) });
    sendJson(socket, {
      type: "consoleSnapshot",
      entries: preview.consoleHistory,
    });
    if (preview.networkUnavailableMessage) {
      sendJson(socket, {
        type: "networkStatus",
        available: false,
        message: preview.networkUnavailableMessage,
      });
    }
    sendJson(socket, {
      type: "networkSnapshot",
      entries: this.networkSummaries(preview),
    });
    if (preview.storageSnapshot) {
      sendJson(socket, {
        type: "storageSnapshot",
        snapshot: preview.storageSnapshot,
      });
    }
    if (preview.inspectorSnapshot) {
      sendJson(socket, {
        type: "inspectorSnapshot",
        snapshot: preview.inspectorSnapshot,
      });
    }
    if (preview.lastFramePayload) {
      sendJson(socket, preview.lastFramePayload);
    }
    if (preview.pageLoading) {
      sendJson(socket, { type: "loading", state: "started" });
    }

    const onClose = () => {
      preview.clients.delete(socket);
      preview.lastClientAt = Date.now();
      preview.updatedAt = preview.lastClientAt;
      if (preview.clients.size === 0) {
        this.stopFrameLoop(preview);
      }
    };

    socket.on("message", (raw) => {
      void this.handleClientMessage(preview, socket, raw);
    });
    socket.on("close", onClose);
    socket.on("error", onClose);

    if (preview.status === "running") {
      this.startFrameLoop(preview);
      void this.captureAndBroadcast(preview).catch((error: unknown) =>
        this.handleCaptureError(preview, error),
      );
      return;
    }

    preview.starting
      ?.then(() => {
        if (socket.readyState !== socket.OPEN) return;
        sendJson(socket, { type: "ready", preview: this.info(preview) });
        this.startFrameLoop(preview);
        void this.captureAndBroadcast(preview).catch((error: unknown) =>
          this.handleCaptureError(preview, error),
        );
      })
      .catch((error: unknown) => {
        sendJson(socket, {
          type: "error",
          message: error instanceof Error ? error.message : String(error),
        });
      });
  }

  public async dispose(): Promise<void> {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
    await Promise.all(
      [...this.previews.values()].map((preview) =>
        this.stopRecord(preview, "stopped"),
      ),
    );
    this.previews.clear();
    await this.stopPersistentHost();
  }

  private async startPreview(preview: BrowserPreviewRecord): Promise<void> {
    try {
      const { cdp, process: child, userDataDir, ownsBrowser } =
        await this.openBrowserForPreview(preview);
      preview.userDataDir = userDataDir;
      preview.process = ownsBrowser ? child : null;
      preview.ownsBrowser = ownsBrowser;
      preview.cdp = cdp;
      const target = await cdp.send("Target.createTarget", {
        url: "about:blank",
      });
      const targetId = stringField(target, "targetId");
      const attached = await cdp.send("Target.attachToTarget", {
        targetId,
        flatten: true,
      });
      const sessionId = stringField(attached, "sessionId");
      preview.targetId = targetId;
      preview.sessionIdCdp = sessionId;
      await setViewport(preview);
      await cdp.send("Page.enable", {}, sessionId);
      await cdp.send("Runtime.enable", {}, sessionId);
      await cdp.send("Log.enable", {}, sessionId);
      try {
        await cdp.send("Network.enable", {}, sessionId);
        this.registerNetworkHandlers(preview, sessionId);
      } catch (error) {
        // Keep the browser preview running even if Network CDP support is
        // unavailable on this Chromium build.
        preview.networkUnavailableMessage = error instanceof Error && error.message
          ? `Network inspection is unavailable: ${error.message}`
          : "Network inspection is unavailable on this Chromium build.";
        this.broadcast(preview, {
          type: "networkStatus",
          available: false,
          message: preview.networkUnavailableMessage,
        });
      }
      try {
        await cdp.send("DOMStorage.enable", {}, sessionId);
        this.registerStorageHandlers(preview, sessionId);
      } catch {
        // Keep storage snapshots available even if live DOMStorage events are
        // unsupported on this Chromium build.
      }
      this.registerConsoleHandlers(preview, sessionId);
      this.registerPageLoadHandlers(preview, sessionId);
      this.registerBrowserNavigationHandlers(preview, targetId, sessionId, {
        followUnscopedPopups: preview.profileMode === "temporary",
      });
      if (preview.profileMode === "temporary") {
        await cdp.send("Target.setDiscoverTargets", { discover: true });
      }
      preview.url = await navigateToReachableTarget(cdp, sessionId, preview);
      preview.status = "running";
      preview.updatedAt = Date.now();
      if (ownsBrowser) {
        child.once("exit", () => {
          if (preview.status === "stopped") return;
          preview.status = "failed";
          preview.lastError = "Chromium exited.";
          preview.updatedAt = Date.now();
          this.stopFrameLoop(preview);
          this.broadcast(preview, {
            type: "error",
            message: preview.lastError,
          });
        });
      }
    } catch (error) {
      preview.status = "failed";
      preview.lastError = error instanceof Error ? error.message : String(error);
      preview.updatedAt = Date.now();
      await this.stopRecord(preview, "failed");
      throw error;
    }
  }

  private async openBrowserForPreview(preview: BrowserPreviewRecord): Promise<{
    cdp: CdpConnection;
    process: BrowserProcess;
    userDataDir: string;
    ownsBrowser: boolean;
  }> {
    const chromePath = await resolveChromePath(this.chromePath);
    if (preview.profileMode === "sidemesh") {
      const host = await this.ensurePersistentHost(chromePath);
      return {
        cdp: host.cdp,
        process: host.process,
        userDataDir: host.userDataDir,
        ownsBrowser: false,
      };
    }
    const userDataDir = await mkdtemp(
      path.join(tmpdir(), "sidemesh-browser-preview-"),
    );
    const { process: child, browserWsUrl } = await launchChrome(
      chromePath,
      userDataDir,
    );
    try {
      return {
        cdp: await CdpConnection.connect(browserWsUrl),
        process: child,
        userDataDir,
        ownsBrowser: true,
      };
    } catch (error) {
      await terminateBrowserProcess(child);
      await rm(userDataDir, { recursive: true, force: true }).catch(() => {});
      throw error;
    }
  }

  private async ensurePersistentHost(
    chromePath: string,
  ): Promise<PersistentBrowserHost> {
    if (
      this.persistentHost &&
      !this.persistentHost.process.killed &&
      !this.persistentHost.cdp.isClosed
    ) {
      return this.persistentHost;
    }
    if (this.persistentHost) {
      await this.stopPersistentHost();
    }
    if (this.persistentHostStarting) {
      return this.persistentHostStarting;
    }
    this.persistentHostStarting = this.startPersistentHost(chromePath);
    try {
      this.persistentHost = await this.persistentHostStarting;
      return this.persistentHost;
    } finally {
      this.persistentHostStarting = null;
    }
  }

  private async startPersistentHost(
    chromePath: string,
  ): Promise<PersistentBrowserHost> {
    const userDataDir = path.join(
      this.persistentProfileRoot,
      SIDEMESH_BROWSER_PROFILE_DIR,
    );
    const { process: child, browserWsUrl } = await launchChrome(
      chromePath,
      userDataDir,
    );
    let cdp: CdpConnection;
    try {
      cdp = await CdpConnection.connect(browserWsUrl);
      await cdp.send("Target.setDiscoverTargets", { discover: true });
    } catch (error) {
      await terminateBrowserProcess(child);
      throw error;
    }
    const host = { userDataDir, process: child, cdp };
    child.once("exit", () => {
      if (this.persistentHost?.process === child) {
        this.persistentHost = null;
      }
      for (const preview of this.previews.values()) {
        if (preview.profileMode !== "sidemesh") continue;
        if (preview.status === "stopped") continue;
        preview.status = "failed";
        preview.lastError = "Chromium exited.";
        preview.updatedAt = Date.now();
        this.stopFrameLoop(preview);
        this.broadcast(preview, {
          type: "error",
          message: preview.lastError,
        });
      }
    });
    return host;
  }

  private async handleClientMessage(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
    raw: WebSocket.RawData,
  ): Promise<void> {
    if (typeof raw !== "string" && !Buffer.isBuffer(raw)) return;
    let message: unknown;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      return;
    }
    const record = message as Record<string, unknown>;
    const type = stringValue(record.type);
    try {
      if (type === "networkDetailRequest") {
        await this.sendNetworkDetail(
          preview,
          socket,
          stringValue(record.requestId),
        );
        return;
      }
      if (type === "storageRefreshRequest") {
        await this.sendStorageSnapshot(preview, socket);
        return;
      }
      if (type === "inspectorSnapshotRequest") {
        await this.sendInspectorSnapshot(preview, socket);
        return;
      }
      if (type === "inspectorSelectPath") {
        await this.selectInspectorPath(preview, socket, record);
        return;
      }
      if (type === "inspectorInspectPoint") {
        await this.inspectPreviewPoint(preview, socket, record);
        return;
      }
      if (type === "storageSetEntry") {
        await this.handleStorageMutation(preview, socket, () =>
          this.setStorageEntry(preview, record),
        );
        return;
      }
      if (type === "storageRemoveEntry") {
        await this.handleStorageMutation(preview, socket, () =>
          this.removeStorageEntry(preview, record),
        );
        return;
      }
      if (type === "storageClearEntries") {
        await this.handleStorageMutation(preview, socket, () =>
          this.clearStorageEntries(preview, record),
        );
        return;
      }
      if (type === "storageDeleteCookie") {
        await this.handleStorageMutation(preview, socket, () =>
          this.deleteStorageCookie(preview, record),
        );
        return;
      }
      if (type === "storageClearCookies") {
        await this.handleStorageMutation(preview, socket, () =>
          this.clearStorageCookies(preview),
        );
        return;
      }
      await this.applyInput(preview, record);
      await this.captureAndBroadcast(preview);
    } catch (error) {
      sendJson(socket, {
        type: "error",
        message: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async applyInput(
    preview: BrowserPreviewRecord,
    message: Record<string, unknown>,
  ): Promise<void> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    if (!cdp || !sessionId || preview.status !== "running") return;
    const type = stringValue(message.type);
    if (type === "tap") {
      const point = normalizedPoint(message, preview);
      await cdp.send(
        "Input.dispatchMouseEvent",
        {
          type: "mousePressed",
          x: point.x,
          y: point.y,
          button: "left",
          buttons: 1,
          clickCount: 1,
        },
        sessionId,
      );
      await cdp.send(
        "Input.dispatchMouseEvent",
        {
          type: "mouseReleased",
          x: point.x,
          y: point.y,
          button: "left",
          buttons: 0,
          clickCount: 1,
        },
        sessionId,
      );
      return;
    }
    if (type === "scroll") {
      const point = normalizedPoint(message, preview);
      await cdp.send(
        "Input.dispatchMouseEvent",
        {
          type: "mouseWheel",
          x: point.x,
          y: point.y,
          deltaX: numberValue(message.deltaX, 0),
          deltaY: numberValue(message.deltaY, 0),
        },
        sessionId,
      );
      return;
    }
    if (type === "text") {
      const text = stringValue(message.text).slice(0, MAX_TEXT_INPUT_CHARS);
      if (text) {
        await cdp.send("Input.insertText", { text }, sessionId);
      }
      return;
    }
    if (type === "key") {
      await sendSpecialKey(cdp, sessionId, stringValue(message.key));
      return;
    }
    if (type === "navigation") {
      await this.applyNavigation(preview, stringValue(message.action));
      return;
    }
    if (type === "tapDown") {
      const point = normalizedPoint(message, preview);
      await cdp.send(
        "Input.dispatchMouseEvent",
        {
          type: "mousePressed",
          x: point.x,
          y: point.y,
          button: "left",
          buttons: 1,
          clickCount: 1,
        },
        sessionId,
      );
      return;
    }
    if (type === "tapUp") {
      const point = normalizedPoint(message, preview);
      await cdp.send(
        "Input.dispatchMouseEvent",
        {
          type: "mouseReleased",
          x: point.x,
          y: point.y,
          button: "left",
          buttons: 0,
          clickCount: 1,
        },
        sessionId,
      );
      return;
    }
    if (type === "touchStart") {
      const point = normalizedPoint(message, preview);
      const touchId = numberValue(message.id, 0);
      await cdp.send(
        "Input.dispatchTouchEvent",
        {
          type: "touchStart",
          touchPoints: [{ x: point.x, y: point.y, id: touchId }],
        },
        sessionId,
      );
      return;
    }
    if (type === "touchMove") {
      const point = normalizedPoint(message, preview);
      const touchId = numberValue(message.id, 0);
      await cdp.send(
        "Input.dispatchTouchEvent",
        {
          type: "touchMove",
          touchPoints: [{ x: point.x, y: point.y, id: touchId }],
        },
        sessionId,
      );
      return;
    }
    if (type === "touchEnd") {
      await cdp.send(
        "Input.dispatchTouchEvent",
        { type: "touchEnd", touchPoints: [] },
        sessionId,
      );
      return;
    }
    if (type === "hover") {
      const point = normalizedPoint(message, preview);
      await cdp.send(
        "Input.dispatchMouseEvent",
        { type: "mouseMoved", x: point.x, y: point.y },
        sessionId,
      );
      return;
    }
    if (type === "navigate") {
      const url = stringValue(message.url);
      if (url) {
        await this.navigatePreviewToUrl(preview, url);
      }
      return;
    }
    if (type === "resize") {
      await this.updatePreviewViewport(
        preview,
        normalizeViewportSize(
          message.width,
          preview.width,
          MAX_VIEWPORT_WIDTH,
        ),
        normalizeViewportSize(
          message.height,
          preview.height,
          MAX_VIEWPORT_HEIGHT,
        ),
      );
    }
  }

  private async applyNavigation(
    preview: BrowserPreviewRecord,
    action: string,
  ): Promise<void> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    if (!cdp || !sessionId || preview.status !== "running") return;
    if (action === "reload") {
      await cdp.send("Page.reload", { ignoreCache: false }, sessionId);
      return;
    }
    if (action !== "back" && action !== "forward") return;
    const history = await cdp.send("Page.getNavigationHistory", {}, sessionId);
    const currentIndex = numberValue(history.currentIndex, -1);
    const entries = Array.isArray(history.entries) ? history.entries : [];
    const targetIndex = action === "back" ? currentIndex - 1 : currentIndex + 1;
    const target = entries[targetIndex];
    if (!target || typeof target !== "object" || Array.isArray(target)) return;
    const entryId = numberValue((target as Record<string, unknown>).id, 0);
    if (entryId <= 0) return;
    await cdp.send("Page.navigateToHistoryEntry", { entryId }, sessionId);
  }

  private async updatePreviewViewport(
    preview: BrowserPreviewRecord,
    width: number,
    height: number,
  ): Promise<void> {
    if (preview.width === width && preview.height === height) return;
    // Broadcast the intended dimensions immediately so the client chip updates
    // and interaction mapping is correct before the first frame arrives.
    preview.width = width;
    preview.height = height;
    preview.updatedAt = Date.now();
    this.broadcast(preview, { type: "preview", preview: this.info(preview) });
    // Clear the cached last-frame so reconnecting clients wait for a fresh
    // frame at the new size, not a stale frame from the old viewport.
    preview.lastFramePayload = null;
    // Apply the viewport change in Chrome.  Any frame-loop captures that race
    // in during this await will use the already-updated preview.width/height
    // for their payload dims — the CDP command ordering (setDeviceMetrics was
    // sent synchronously inside setViewport before we yield) guarantees those
    // captures see the new Chrome viewport, so dims and image stay in sync.
    await setViewport(preview);
  }

  private startFrameLoop(preview: BrowserPreviewRecord): void {
    if (preview.frameTimer || preview.clients.size === 0) return;
    preview.frameTimer = setInterval(() => {
      void this.captureAndBroadcast(preview).catch((error: unknown) =>
        this.handleCaptureError(preview, error),
      );
    }, this.frameIntervalMs);
    preview.frameTimer.unref?.();
  }

  private stopFrameLoop(preview: BrowserPreviewRecord): void {
    if (!preview.frameTimer) return;
    clearInterval(preview.frameTimer);
    preview.frameTimer = null;
  }

  private async captureAndBroadcast(preview: BrowserPreviewRecord): Promise<void> {
    if (preview.clients.size === 0 || preview.status !== "running") return;
    if (preview.capturingFrame) return;
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    if (!cdp || !sessionId) return;
    preview.capturingFrame = true;
    try {
      const response = await cdp.send(
        "Page.captureScreenshot",
        {
          format: "jpeg",
          quality: this.quality,
          fromSurface: true,
          optimizeForSpeed: true,
        },
        sessionId,
      );
      const data = stringField(response, "data");
      preview.lastFrameAt = Date.now();
      preview.updatedAt = preview.lastFrameAt;
      preview.lastError = null;
      const framePayload = {
        type: "frame",
        seq: preview.nextFrameSeq++,
        mimeType: "image/jpeg",
        width: preview.width,
        height: preview.height,
        timestamp: preview.lastFrameAt,
        data,
      };
      preview.lastFramePayload = framePayload;
      this.broadcast(preview, framePayload);
    } finally {
      preview.capturingFrame = false;
    }
  }

  private handleCaptureError(
    preview: BrowserPreviewRecord,
    error: unknown,
  ): void {
    preview.lastError = error instanceof Error ? error.message : String(error);
    preview.updatedAt = Date.now();
    this.broadcast(preview, {
      type: "error",
      message: preview.lastError,
    });
  }

  private networkSummaries(
    preview: BrowserPreviewRecord,
  ): Array<Record<string, unknown>> {
    return [...preview.networkEntries.values()].map((entry) =>
      this.networkSummary(entry),
    );
  }

  private networkSummary(
    entry: BrowserPreviewNetworkEntry,
  ): Record<string, unknown> {
    return {
      requestId: entry.requestId,
      url: entry.url,
      method: entry.method,
      resourceType: entry.resourceType,
      status: entry.status,
      mimeType: entry.mimeType,
      encodedDataLength: entry.encodedDataLength,
      durationMs: entry.durationMs,
      startedAt: entry.startedAt,
      errorText: entry.errorText,
      finished: entry.finished,
      failed: entry.failed,
      servedFromCache: entry.servedFromCache,
      webSocketMessageCount: entry.webSocketMessages.length,
    };
  }

  private broadcastNetworkEntry(
    preview: BrowserPreviewRecord,
    entry: BrowserPreviewNetworkEntry,
  ): void {
    this.broadcast(preview, {
      type: "network",
      entry: this.networkSummary(entry),
    });
  }

  private registerNetworkHandlers(
    preview: BrowserPreviewRecord,
    sessionId: string,
  ): void {
    const cdp = preview.cdp;
    if (!cdp) return;

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.requestWillBeSent", (params) => {
        const cdpRequestId = stringValue(params.requestId);
        if (!cdpRequestId) return;

        const redirectResponse = objectValue(params.redirectResponse);
        const previousEntry = this.networkEntryForCdpRequest(preview, cdpRequestId);
        if (previousEntry && redirectResponse) {
          previousEntry.status = numberOrNull(redirectResponse.status);
          previousEntry.statusText = stringOrNull(redirectResponse.statusText);
          previousEntry.mimeType = stringOrNull(redirectResponse.mimeType);
          previousEntry.responseHeaders = headerRecord(redirectResponse.headers);
          previousEntry.servedFromCache =
            previousEntry.servedFromCache ||
            redirectResponse.fromDiskCache === true ||
            redirectResponse.fromPrefetchCache === true ||
            redirectResponse.fromServiceWorker === true;
          previousEntry.finished = true;
          previousEntry.failed = false;
          previousEntry.errorText = null;
          previousEntry.isRedirectResponse = true;
          this.updateNetworkEntryDuration(
            previousEntry,
            numberOrNull(params.timestamp),
          );
          this.broadcastNetworkEntry(preview, previousEntry);
        }

        const request = objectValue(params.request);
        const url = stringValue(request?.url);
        if (!isTrackedBrowserPreviewNetworkUrl(url)) {
          if (redirectResponse) {
            preview.networkEntryIdsByRequestId.delete(cdpRequestId);
          }
          return;
        }

        const identity = this.nextNetworkEntryIdentity(preview, cdpRequestId);
        const entry: BrowserPreviewNetworkEntry = {
          requestId: identity.entryId,
          cdpRequestId,
          redirectHop: identity.redirectHop,
          isRedirectResponse: false,
          url,
          method: stringValue(request?.method) || "GET",
          resourceType: stringValue(params.type) || "Other",
          requestHeaders: headerRecord(request?.headers),
          responseHeaders: {},
          status: null,
          statusText: null,
          mimeType: null,
          encodedDataLength: null,
          durationMs: null,
          startedAt: browserPreviewNetworkStartedAt(params),
          startTimestampSeconds: numberOrNull(params.timestamp),
          errorText: null,
          finished: false,
          failed: false,
          servedFromCache: false,
          webSocketMessages: [],
        };
        this.upsertNetworkEntry(preview, entry);
        preview.networkEntryIdsByRequestId.set(cdpRequestId, entry.requestId);
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.requestServedFromCache", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        entry.servedFromCache = true;
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.responseReceived", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        const response = objectValue(params.response);
        entry.status = numberOrNull(response?.status);
        entry.statusText = stringOrNull(response?.statusText);
        entry.mimeType = stringOrNull(response?.mimeType);
        entry.responseHeaders = headerRecord(response?.headers);
        entry.servedFromCache =
          entry.servedFromCache ||
          response?.fromDiskCache === true ||
          response?.fromPrefetchCache === true ||
          response?.fromServiceWorker === true;
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.loadingFinished", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        entry.encodedDataLength = numberOrNull(params.encodedDataLength);
        entry.finished = true;
        entry.failed = false;
        entry.errorText = null;
        this.updateNetworkEntryDuration(entry, numberOrNull(params.timestamp));
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.loadingFailed", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        entry.finished = true;
        entry.failed = true;
        entry.errorText = stringOrNull(params.errorText);
        this.updateNetworkEntryDuration(entry, numberOrNull(params.timestamp));
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.webSocketCreated", (params) => {
        const requestId = stringValue(params.requestId);
        if (!requestId) return;
        const entry = this.ensureWebSocketEntry(
          preview,
          requestId,
          stringValue(params.url),
          Date.now(),
          null,
        );
        if (!entry) return;
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(
        sessionId,
        "Network.webSocketWillSendHandshakeRequest",
        (params) => {
          const requestId = stringValue(params.requestId);
          if (!requestId) return;
          const request = objectValue(params.request);
          const entry = this.ensureWebSocketEntry(
            preview,
            requestId,
            stringValue(request?.url),
            browserPreviewNetworkStartedAt(params),
            numberOrNull(params.timestamp),
          );
          if (!entry) return;
          entry.method = stringValue(request?.method) || "GET";
          entry.requestHeaders = headerRecord(request?.headers);
          this.broadcastNetworkEntry(preview, entry);
        },
      ),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(
        sessionId,
        "Network.webSocketHandshakeResponseReceived",
        (params) => {
          const entry = this.networkEntryForCdpRequest(
            preview,
            stringValue(params.requestId),
          );
          if (!entry) return;
          const response = objectValue(params.response);
          entry.status = numberOrNull(response?.status);
          entry.statusText = stringOrNull(response?.statusText);
          entry.responseHeaders = headerRecord(response?.headers);
          entry.requestHeaders = {
            ...entry.requestHeaders,
            ...headerRecord(response?.requestHeaders),
          };
          entry.mimeType =
            stringOrNull(response?.mimeType) ||
            headerValue(entry.responseHeaders, "content-type");
          entry.failed = false;
          entry.errorText = null;
          this.broadcastNetworkEntry(preview, entry);
        },
      ),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.webSocketFrameSent", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        const response = objectValue(params.response);
        this.recordWebSocketMessage(entry, {
          direction: "sent",
          timestamp:
            timestampFromSeconds(numberOrNull(params.timestamp)) ?? Date.now(),
          opcode: numberOrNull(response?.opcode),
          payload: stringOrNull(response?.payloadData),
          base64Encoded: websocketFramePayloadIsBase64(response),
          error: null,
        });
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.webSocketFrameReceived", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        const response = objectValue(params.response);
        this.recordWebSocketMessage(entry, {
          direction: "received",
          timestamp:
            timestampFromSeconds(numberOrNull(params.timestamp)) ?? Date.now(),
          opcode: numberOrNull(response?.opcode),
          payload: stringOrNull(response?.payloadData),
          base64Encoded: websocketFramePayloadIsBase64(response),
          error: null,
        });
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.webSocketFrameError", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        entry.failed = true;
        entry.errorText = stringOrNull(params.errorMessage);
        this.recordWebSocketMessage(entry, {
          direction: "error",
          timestamp:
            timestampFromSeconds(numberOrNull(params.timestamp)) ?? Date.now(),
          opcode: null,
          payload: null,
          base64Encoded: false,
          error: entry.errorText,
        });
        this.broadcastNetworkEntry(preview, entry);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Network.webSocketClosed", (params) => {
        const entry = this.networkEntryForCdpRequest(
          preview,
          stringValue(params.requestId),
        );
        if (!entry) return;
        entry.finished = true;
        this.updateNetworkEntryDuration(entry, numberOrNull(params.timestamp));
        this.broadcastNetworkEntry(preview, entry);
      }),
    );
  }

  private networkEntryForCdpRequest(
    preview: BrowserPreviewRecord,
    cdpRequestId: string,
  ): BrowserPreviewNetworkEntry | null {
    const entryId = preview.networkEntryIdsByRequestId.get(cdpRequestId);
    if (!entryId) return null;
    return preview.networkEntries.get(entryId) ?? null;
  }

  private nextNetworkEntryIdentity(
    preview: BrowserPreviewRecord,
    cdpRequestId: string,
  ): { entryId: string; redirectHop: number } {
    const redirectHop =
      (preview.networkRedirectCountsByRequestId.get(cdpRequestId) ?? -1) + 1;
    preview.networkRedirectCountsByRequestId.set(cdpRequestId, redirectHop);
    return {
      entryId:
        redirectHop === 0
          ? cdpRequestId
          : `${cdpRequestId}:redirect:${redirectHop}`,
      redirectHop,
    };
  }

  private ensureWebSocketEntry(
    preview: BrowserPreviewRecord,
    cdpRequestId: string,
    url: string,
    startedAt: number,
    startTimestampSeconds: number | null,
  ): BrowserPreviewNetworkEntry | null {
    const existing = this.networkEntryForCdpRequest(preview, cdpRequestId);
    if (existing) {
      existing.resourceType = "WebSocket";
      if (url && !existing.url) {
        existing.url = url;
      }
      if (
        startTimestampSeconds != null &&
        existing.startTimestampSeconds == null
      ) {
        existing.startTimestampSeconds = startTimestampSeconds;
        existing.startedAt = startedAt;
      }
      if (existing.startedAt <= 0) {
        existing.startedAt = startedAt;
      }
      return existing;
    }
    if (!isTrackedBrowserPreviewNetworkUrl(url)) {
      return null;
    }
    const entry: BrowserPreviewNetworkEntry = {
      requestId: cdpRequestId,
      cdpRequestId,
      redirectHop: 0,
      isRedirectResponse: false,
      url,
      method: "GET",
      resourceType: "WebSocket",
      requestHeaders: {},
      responseHeaders: {},
      status: null,
      statusText: null,
      mimeType: null,
      encodedDataLength: null,
      durationMs: null,
      startedAt,
      startTimestampSeconds,
      errorText: null,
      finished: false,
      failed: false,
      servedFromCache: false,
      webSocketMessages: [],
    };
    this.upsertNetworkEntry(preview, entry);
    preview.networkEntryIdsByRequestId.set(cdpRequestId, entry.requestId);
    return entry;
  }

  private updateNetworkEntryDuration(
    entry: BrowserPreviewNetworkEntry,
    completedAtSeconds: number | null,
  ): void {
    if (
      entry.startTimestampSeconds == null ||
      completedAtSeconds == null ||
      completedAtSeconds < entry.startTimestampSeconds
    ) {
      return;
    }
    entry.durationMs = Math.round(
      (completedAtSeconds - entry.startTimestampSeconds) * 1000,
    );
  }

  private recordWebSocketMessage(
    entry: BrowserPreviewNetworkEntry,
    message: BrowserPreviewNetworkMessage,
  ): void {
    entry.webSocketMessages.push(message);
    while (entry.webSocketMessages.length > MAX_WEBSOCKET_MESSAGES_PER_ENTRY) {
      entry.webSocketMessages.shift();
    }
  }

  private upsertNetworkEntry(
    preview: BrowserPreviewRecord,
    entry: BrowserPreviewNetworkEntry,
  ): void {
    preview.networkEntries.set(entry.requestId, entry);
    while (preview.networkEntries.size > MAX_NETWORK_ENTRIES) {
      const oldestEntry = preview.networkEntries.values().next().value;
      if (!oldestEntry) break;
      preview.networkEntries.delete(oldestEntry.requestId);
      if (
        preview.networkEntryIdsByRequestId.get(oldestEntry.cdpRequestId) ===
        oldestEntry.requestId
      ) {
        preview.networkEntryIdsByRequestId.delete(oldestEntry.cdpRequestId);
      }
    }
  }

  private async sendNetworkDetail(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
    requestId: string,
  ): Promise<void> {
    if (!requestId) {
      sendJson(socket, {
        type: "networkDetail",
        requestId,
        error: "network requestId is required",
      });
      return;
    }
    const entry = preview.networkEntries.get(requestId);
    if (!entry) {
      sendJson(socket, {
        type: "networkDetail",
        requestId,
        error: "network request not found",
      });
      return;
    }

    const detail = this.networkDetailFromEntry(entry);
    if (entry.resourceType === "WebSocket") {
      sendJson(socket, {
        type: "networkDetail",
        requestId,
        detail,
      });
      return;
    }
    if (!preview.cdp || !preview.sessionIdCdp || preview.status !== "running") {
      if (canBrowserPreviewRequestHaveBody(entry.method)) {
        detail.requestBodyError = "Browser preview is no longer running.";
      }
      if (!entry.finished) {
        detail.bodyError = "Response body is not available until the request finishes.";
      } else if (entry.failed) {
        detail.bodyError = "Response body is not available for failed requests.";
      } else if (entry.isRedirectResponse) {
        detail.bodyError = "Response body is not available for redirect responses.";
      } else {
        detail.bodyError = "Browser preview is no longer running.";
      }
      sendJson(socket, {
        type: "networkDetail",
        requestId,
        detail,
      });
      return;
    }

    if (canBrowserPreviewRequestHaveBody(entry.method)) {
      if (entry.isRedirectResponse) {
        detail.requestBodyError =
          "Request body is not available for redirect hops.";
      } else {
        try {
          const result = await preview.cdp.send(
            "Network.getRequestPostData",
            { requestId: entry.cdpRequestId },
            preview.sessionIdCdp,
          );
          detail.requestBody = typeof result.postData === "string"
            ? result.postData
            : null;
          if (!detail.requestBody) {
            detail.requestBodyError = "No request body captured for this request.";
          }
        } catch (error) {
          detail.requestBodyError = error instanceof Error
            ? error.message
            : String(error);
        }
      }
    }

    if (!entry.finished) {
      detail.bodyError = "Response body is not available until the request finishes.";
    } else if (entry.failed) {
      detail.bodyError = "Response body is not available for failed requests.";
    } else if (entry.isRedirectResponse) {
      detail.bodyError = "Response body is not available for redirect responses.";
    } else {
      try {
        const result = await preview.cdp.send(
          "Network.getResponseBody",
          { requestId: entry.cdpRequestId },
          preview.sessionIdCdp,
        );
        detail.body = typeof result.body === "string" ? result.body : null;
        detail.bodyBase64Encoded = result.base64Encoded === true;
      } catch (error) {
        detail.bodyError = error instanceof Error ? error.message : String(error);
      }
    }

    sendJson(socket, {
      type: "networkDetail",
      requestId,
      detail,
    });
  }

  private networkDetailFromEntry(
    entry: BrowserPreviewNetworkEntry,
  ): BrowserPreviewNetworkDetail {
    return {
      requestId: entry.requestId,
      url: entry.url,
      method: entry.method,
      resourceType: entry.resourceType,
      status: entry.status,
      mimeType: entry.mimeType,
      encodedDataLength: entry.encodedDataLength,
      durationMs: entry.durationMs,
      startedAt: entry.startedAt,
      errorText: entry.errorText,
      finished: entry.finished,
      failed: entry.failed,
      servedFromCache: entry.servedFromCache,
      statusText: entry.statusText,
      requestHeaders: entry.requestHeaders,
      responseHeaders: entry.responseHeaders,
      requestBody: null,
      requestBodyError: null,
      body: null,
      bodyBase64Encoded: false,
      bodyError: null,
      webSocketMessages: entry.webSocketMessages,
    };
  }

  private async sendInspectorSnapshot(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
  ): Promise<void> {
    try {
      const snapshot = await this.refreshInspectorSnapshot(preview);
      sendJson(socket, {
        type: "inspectorSnapshot",
        snapshot,
      });
    } catch (error) {
      sendJson(socket, {
        type: "inspectorSnapshot",
        snapshot: preview.inspectorSnapshot ?? undefined,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async selectInspectorPath(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
    record: Record<string, unknown>,
  ): Promise<void> {
    const path = inspectorPathFromValue(record.path);
    if (!path) {
      sendJson(socket, {
        type: "inspectorSnapshot",
        snapshot: preview.inspectorSnapshot ?? undefined,
        error: "Inspector path is invalid.",
      });
      return;
    }
    await this.handleInspectorRefresh(preview, socket, {
      selectedPath: path,
    });
  }

  private async inspectPreviewPoint(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
    record: Record<string, unknown>,
  ): Promise<void> {
    const point = normalizedPoint(record, preview);
    await this.handleInspectorRefresh(preview, socket, {
      inspectPoint: point,
    });
  }

  private async handleInspectorRefresh(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
    options: {
      selectedPath?: number[];
      inspectPoint?: { x: number; y: number };
    } = {},
  ): Promise<void> {
    try {
      const snapshot = await this.refreshInspectorSnapshot(preview, options);
      this.broadcastInspectorSnapshot(preview, snapshot);
    } catch (error) {
      sendJson(socket, {
        type: "inspectorSnapshot",
        snapshot: preview.inspectorSnapshot ?? undefined,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async refreshInspectorSnapshot(
    preview: BrowserPreviewRecord,
    options: {
      selectedPath?: number[];
      inspectPoint?: { x: number; y: number };
    } = {},
  ): Promise<BrowserPreviewInspectorSnapshot> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    if (!cdp || !sessionId || preview.status !== "running") {
      throw new BrowserPreviewError(
        "Browser preview is no longer running.",
        409,
      );
    }
    const snapshot = await this.buildInspectorSnapshot(preview, cdp, sessionId, {
      selectedPath: options.selectedPath ?? preview.inspectorSelectedPath,
      inspectPoint: options.inspectPoint ?? null,
    });
    preview.inspectorSnapshot = snapshot;
    preview.inspectorSelectedPath = snapshot.selectedPath;
    return snapshot;
  }

  private async buildInspectorSnapshot(
    preview: BrowserPreviewRecord,
    cdp: CdpConnection,
    sessionId: string,
    options: {
      selectedPath: number[] | null;
      inspectPoint: { x: number; y: number } | null;
    },
  ): Promise<BrowserPreviewInspectorSnapshot> {
    const result = await runtimeEvaluateJson(
      cdp,
      sessionId,
      buildInspectorSnapshotExpression({
        selectedPath: options.selectedPath,
        inspectPoint: options.inspectPoint,
      }),
    );
    return inspectorSnapshotFromRuntimeValue(result, preview.url);
  }

  private broadcastInspectorSnapshot(
    preview: BrowserPreviewRecord,
    snapshot: BrowserPreviewInspectorSnapshot,
  ): void {
    this.broadcast(preview, {
      type: "inspectorSnapshot",
      snapshot,
    });
  }

  private async sendStorageSnapshot(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
  ): Promise<void> {
    try {
      const snapshot = await this.refreshStorageSnapshot(preview);
      sendJson(socket, {
        type: "storageSnapshot",
        snapshot,
      });
    } catch (error) {
      sendJson(socket, {
        type: "storageSnapshot",
        snapshot: preview.storageSnapshot ?? undefined,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async handleStorageMutation(
    preview: BrowserPreviewRecord,
    socket: WebSocket,
    mutation: () => Promise<void>,
  ): Promise<void> {
    try {
      await mutation();
    } catch (error) {
      sendJson(socket, {
        type: "storageSnapshot",
        snapshot: preview.storageSnapshot ?? undefined,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  private async refreshStorageSnapshot(
    preview: BrowserPreviewRecord,
  ): Promise<BrowserPreviewStorageSnapshot> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    if (!cdp || !sessionId || preview.status !== "running") {
      throw new BrowserPreviewError(
        "Browser preview is no longer running.",
        409,
      );
    }
    const snapshot = await this.buildStorageSnapshot(preview, cdp, sessionId);
    preview.storageSnapshot = snapshot;
    return snapshot;
  }

  private async buildStorageSnapshot(
    preview: BrowserPreviewRecord,
    cdp: CdpConnection,
    sessionId: string,
  ): Promise<BrowserPreviewStorageSnapshot> {
    const warnings: string[] = [];
    const origin = storageOriginForUrl(preview.url);
    let cookies: BrowserPreviewStorageCookie[] = [];
    let indexedDbDatabases: BrowserPreviewIndexedDbDatabase[] = [];
    let localStorage: BrowserPreviewStorageEntry[] = [];
    let sessionStorage: BrowserPreviewStorageEntry[] = [];
    let usage: number | null = null;
    let quota: number | null = null;
    let usageBreakdown: BrowserPreviewStorageUsage[] = [];

    try {
      const result = await cdp.send(
        "Network.getCookies",
        { urls: [preview.url] },
        sessionId,
      );
      cookies = cookiesFromResult(result);
    } catch (error) {
      warnings.push(
        `Could not read cookies: ${error instanceof Error ? error.message : String(error)}`,
      );
    }

    if (!origin) {
      warnings.push("Storage inspection requires a page with a valid origin.");
    } else {
      try {
        const namesResult = await cdp.send(
          "IndexedDB.requestDatabaseNames",
          { securityOrigin: origin },
          sessionId,
        );
        const databaseNames = indexedDbDatabaseNamesFromResult(namesResult);
        const databases: BrowserPreviewIndexedDbDatabase[] = [];
        for (const databaseName of databaseNames) {
          const result = await cdp.send(
            "IndexedDB.requestDatabase",
            {
              securityOrigin: origin,
              databaseName,
            },
            sessionId,
          );
          const database = indexedDbDatabaseFromResult(result);
          if (database) {
            databases.push(database);
          }
        }
        indexedDbDatabases = databases;
      } catch (error) {
        warnings.push(
          `Could not read IndexedDB: ${error instanceof Error ? error.message : String(error)}`,
        );
      }

      try {
        const result = await cdp.send(
          "DOMStorage.getDOMStorageItems",
          {
            storageId: {
              securityOrigin: origin,
              isLocalStorage: true,
            },
          },
          sessionId,
        );
        localStorage = storageEntriesFromPairs(result.entries);
      } catch (error) {
        warnings.push(
          `Could not read localStorage: ${error instanceof Error ? error.message : String(error)}`,
        );
      }

      try {
        const result = await cdp.send(
          "DOMStorage.getDOMStorageItems",
          {
            storageId: {
              securityOrigin: origin,
              isLocalStorage: false,
            },
          },
          sessionId,
        );
        sessionStorage = storageEntriesFromPairs(result.entries);
      } catch (error) {
        warnings.push(
          `Could not read sessionStorage: ${error instanceof Error ? error.message : String(error)}`,
        );
      }

      try {
        const result = await cdp.send(
          "Storage.getUsageAndQuota",
          { origin },
          sessionId,
        );
        usage = numberOrNull(result.usage);
        quota = numberOrNull(result.quota);
        usageBreakdown = storageUsageBreakdownFromResult(result.usageBreakdown);
      } catch (error) {
        warnings.push(
          `Could not read storage quota: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }

    return {
      url: preview.url,
      origin,
      refreshedAt: Date.now(),
      cookies,
      indexedDbDatabases,
      localStorage,
      sessionStorage,
      usage,
      quota,
      usageBreakdown,
      warnings,
    };
  }

  private async setStorageEntry(
    preview: BrowserPreviewRecord,
    record: Record<string, unknown>,
  ): Promise<void> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    const origin = storageOriginForUrl(preview.url);
    const area = storageAreaFromMessage(record.area);
    const key = stringValue(record.key);
    const value = stringValue(record.value);
    if (!cdp || !sessionId || preview.status !== "running") {
      throw new BrowserPreviewError(
        "Browser preview is no longer running.",
        409,
      );
    }
    if (!origin) {
      throw new BrowserPreviewError(
        "Storage editing requires a page with a valid origin.",
        400,
      );
    }
    if (!area) {
      throw new BrowserPreviewError("Storage area must be localStorage or sessionStorage.", 400);
    }
    if (!key.trim()) {
      throw new BrowserPreviewError("Storage key is required.", 400);
    }
    await cdp.send(
      "DOMStorage.setDOMStorageItem",
      {
        storageId: storageIdForArea(origin, area),
        key,
        value,
      },
      sessionId,
    );
    await this.refreshAndBroadcastStorageSnapshot(preview);
  }

  private async removeStorageEntry(
    preview: BrowserPreviewRecord,
    record: Record<string, unknown>,
  ): Promise<void> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    const origin = storageOriginForUrl(preview.url);
    const area = storageAreaFromMessage(record.area);
    const key = stringValue(record.key);
    if (!cdp || !sessionId || preview.status !== "running") {
      throw new BrowserPreviewError(
        "Browser preview is no longer running.",
        409,
      );
    }
    if (!origin) {
      throw new BrowserPreviewError(
        "Storage editing requires a page with a valid origin.",
        400,
      );
    }
    if (!area) {
      throw new BrowserPreviewError("Storage area must be localStorage or sessionStorage.", 400);
    }
    if (!key.trim()) {
      throw new BrowserPreviewError("Storage key is required.", 400);
    }
    await cdp.send(
      "DOMStorage.removeDOMStorageItem",
      {
        storageId: storageIdForArea(origin, area),
        key,
      },
      sessionId,
    );
    await this.refreshAndBroadcastStorageSnapshot(preview);
  }

  private async clearStorageEntries(
    preview: BrowserPreviewRecord,
    record: Record<string, unknown>,
  ): Promise<void> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    const origin = storageOriginForUrl(preview.url);
    const area = storageAreaFromMessage(record.area);
    if (!cdp || !sessionId || preview.status !== "running") {
      throw new BrowserPreviewError(
        "Browser preview is no longer running.",
        409,
      );
    }
    if (!origin) {
      throw new BrowserPreviewError(
        "Storage editing requires a page with a valid origin.",
        400,
      );
    }
    if (!area) {
      throw new BrowserPreviewError("Storage area must be localStorage or sessionStorage.", 400);
    }
    await cdp.send(
      "DOMStorage.clear",
      {
        storageId: storageIdForArea(origin, area),
      },
      sessionId,
    );
    await this.refreshAndBroadcastStorageSnapshot(preview);
  }

  private async deleteStorageCookie(
    preview: BrowserPreviewRecord,
    record: Record<string, unknown>,
  ): Promise<void> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    const name = stringValue(record.name);
    const domain = stringValue(record.domain);
    const path = stringValue(record.path) || "/";
    if (!cdp || !sessionId || preview.status !== "running") {
      throw new BrowserPreviewError(
        "Browser preview is no longer running.",
        409,
      );
    }
    if (!name.trim()) {
      throw new BrowserPreviewError("Cookie name is required.", 400);
    }
    await cdp.send(
      "Network.deleteCookies",
      {
        name,
        domain: domain || undefined,
        path,
        url: preview.url || undefined,
      },
      sessionId,
    );
    await this.refreshAndBroadcastStorageSnapshot(preview);
  }

  private async clearStorageCookies(
    preview: BrowserPreviewRecord,
  ): Promise<void> {
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    if (!cdp || !sessionId || preview.status !== "running") {
      throw new BrowserPreviewError(
        "Browser preview is no longer running.",
        409,
      );
    }
    let cookies: BrowserPreviewStorageCookie[] = [];
    try {
      const result = await cdp.send(
        "Network.getCookies",
        { urls: [preview.url] },
        sessionId,
      );
      cookies = cookiesFromResult(result);
    } catch {
      const snapshot =
        preview.storageSnapshot ??
        (await this.buildStorageSnapshot(preview, cdp, sessionId));
      cookies = snapshot.cookies;
    }
    for (const cookie of cookies) {
      await cdp.send(
        "Network.deleteCookies",
        {
          name: cookie.name,
          domain: cookie.domain || undefined,
          path: cookie.path || "/",
          url: preview.url || undefined,
        },
        sessionId,
      );
    }
    await this.refreshAndBroadcastStorageSnapshot(preview);
  }

  private async refreshAndBroadcastStorageSnapshot(
    preview: BrowserPreviewRecord,
  ): Promise<void> {
    const snapshot = await this.refreshStorageSnapshot(preview);
    this.broadcastStorageSnapshot(preview, snapshot);
  }

  private broadcastStorageSnapshot(
    preview: BrowserPreviewRecord,
    snapshot: BrowserPreviewStorageSnapshot,
  ): void {
    this.broadcast(preview, {
      type: "storageSnapshot",
      snapshot,
    });
  }

  private registerStorageHandlers(
    preview: BrowserPreviewRecord,
    sessionId: string,
  ): void {
    const cdp = preview.cdp;
    if (!cdp) return;
    const schedule = () => this.scheduleStorageSnapshotRefresh(preview);
    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "DOMStorage.domStorageItemsCleared", schedule),
    );
    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "DOMStorage.domStorageItemRemoved", schedule),
    );
    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "DOMStorage.domStorageItemAdded", schedule),
    );
    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "DOMStorage.domStorageItemUpdated", schedule),
    );
  }

  private scheduleStorageSnapshotRefresh(preview: BrowserPreviewRecord): void {
    if (!preview.storageSnapshot) return;
    if (preview.storageRefreshTimer) {
      clearTimeout(preview.storageRefreshTimer);
    }
    preview.storageRefreshTimer = setTimeout(() => {
      preview.storageRefreshTimer = null;
      void this.refreshAndBroadcastStorageSnapshot(preview).catch(() => {});
    }, 150);
    preview.storageRefreshTimer.unref?.();
  }

  private flushConsoleBuffer(preview: BrowserPreviewRecord): void {
    if (preview.consoleBuffer.length === 0) return;
    const batch = preview.consoleBuffer.splice(0, preview.consoleBuffer.length);
    preview.consoleHistory.push(...batch);
    while (preview.consoleHistory.length > MAX_CONSOLE_BUFFER) {
      preview.consoleHistory.shift();
    }
    for (const entry of batch) {
      this.broadcast(preview, { ...entry });
    }
  }

  private registerConsoleHandlers(
    preview: BrowserPreviewRecord,
    sessionId: string,
  ): void {
    const cdp = preview.cdp;
    if (!cdp) return;

    const queueConsole = (entry: Omit<BrowserPreviewConsoleEntry, "seq">) => {
      preview.consoleBuffer.push({
        seq: preview.nextConsoleSeq++,
        ...entry,
      });
      if (preview.consoleBuffer.length >= CONSOLE_FLUSH_THRESHOLD) {
        this.flushConsoleBuffer(preview);
      }
    };

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Runtime.consoleAPICalled", (params) => {
        const args = Array.isArray(params.args) ? params.args : [];
        queueConsole({
          type: "console",
          level: stringValue(params.type) || "log",
          text: browserPreviewConsoleText(args),
          args: consoleArgumentRecords(args),
          url: null,
          lineNumber: null,
          columnNumber: null,
          source: null,
          timestamp:
            timestampFromSeconds(numberOrNull(params.timestamp)) ?? Date.now(),
        });
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Runtime.exceptionThrown", (params) => {
        const details = objectValue(params.exceptionDetails);
        const exception = objectValue(details?.exception);
        queueConsole({
          type: "exception",
          level: "error",
          text:
            stringOrNull(exception?.description) ||
            stringOrNull(details?.text) ||
            "Uncaught exception",
          args: [],
          url: stringOrNull(details?.url),
          lineNumber: numberOrNull(details?.lineNumber),
          columnNumber: numberOrNull(details?.columnNumber),
          source: null,
          timestamp:
            timestampFromSeconds(numberOrNull(params.timestamp)) ?? Date.now(),
        });
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Log.entryAdded", (params) => {
        const entry = objectValue(params.entry);
        queueConsole({
          type: "log",
          level: stringValue(entry?.level) || "info",
          text: stringValue(entry?.text),
          args: [],
          url: stringOrNull(entry?.url),
          lineNumber: numberOrNull(entry?.lineNumber),
          columnNumber: null,
          source: stringOrNull(entry?.source),
          timestamp:
            timestampFromSeconds(numberOrNull(entry?.timestamp)) ??
            numberValue(entry?.timestamp, Date.now()),
        });
      }),
    );

    preview.consoleFlushTimer = setInterval(() => {
      this.flushConsoleBuffer(preview);
    }, CONSOLE_FLUSH_INTERVAL_MS);
    preview.consoleFlushTimer.unref?.();
  }

  private registerPageLoadHandlers(
    preview: BrowserPreviewRecord,
    sessionId: string,
  ): void {
    const cdp = preview.cdp;
    if (!cdp) return;

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Page.frameStartedLoading", (params) => {
        const frameId = stringValue(params.frameId);
        if (!frameId || frameId !== preview.mainFrameId) return;
        this.setPreviewPageLoading(preview, true);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Page.frameStoppedLoading", (params) => {
        const frameId = stringValue(params.frameId);
        if (!frameId || frameId !== preview.mainFrameId) return;
        this.setPreviewPageLoading(preview, false);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Page.loadEventFired", () => {
        this.completePreviewPageLoad(preview);
      }),
    );
  }

  private setPreviewPageLoading(
    preview: BrowserPreviewRecord,
    pageLoading: boolean,
  ): void {
    if (preview.pageLoading === pageLoading) return;
    preview.pageLoading = pageLoading;
    this.broadcast(preview, {
      type: "loading",
      state: pageLoading ? "started" : "complete",
    });
  }

  private completePreviewPageLoad(preview: BrowserPreviewRecord): void {
    const wasLoading = preview.pageLoading;
    this.setPreviewPageLoading(preview, false);
    if (!wasLoading) {
      // Keep refresh behavior aligned with Page.loadEventFired even when the
      // browser did not emit a matching frameStartedLoading event we track.
      preview.pageLoading = false;
    }
    if (preview.inspectorSnapshot) {
      void this.refreshInspectorSnapshot(preview)
        .then((snapshot) => this.broadcastInspectorSnapshot(preview, snapshot))
        .catch(() => {});
    }
    this.scheduleStorageSnapshotRefresh(preview);
  }

  private registerBrowserNavigationHandlers(
    preview: BrowserPreviewRecord,
    primaryTargetId: string,
    sessionId: string,
    options: { followUnscopedPopups: boolean },
  ): void {
    const cdp = preview.cdp;
    if (!cdp) return;

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Page.frameNavigated", (params) => {
        const frame = objectValue(params.frame);
        if (!frame || stringValue(frame.parentId)) return;
        const frameId = stringValue(frame.id);
        if (frameId) {
          preview.mainFrameId = frameId;
        }
        const url = stringValue(frame.url);
        if (!url) return;
        this.updatePreviewUrl(preview, url);
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onSessionEvent(sessionId, "Page.windowOpen", (params) => {
        const url = stringValue(params.url);
        if (!isBrowserNavigationUrl(url)) return;
        void this.navigatePreviewToUrl(preview, url).catch((error: unknown) =>
          this.handleCaptureError(preview, error),
        );
      }),
    );

    const followedPopupTargets = new Set<string>();
    const followTargetInfo = (targetInfo: Record<string, unknown> | null) => {
      if (!targetInfo) return;
      const targetId = stringValue(targetInfo.targetId);
      if (!targetId || targetId === primaryTargetId) return;
      if (followedPopupTargets.has(targetId)) return;
      const openerId = stringValue(targetInfo.openerId);
      if (openerId) {
        if (openerId !== primaryTargetId) return;
      } else if (!options.followUnscopedPopups) {
        return;
      }
      if (stringValue(targetInfo.type) !== "page") return;
      const url = stringValue(targetInfo.url);
      if (!isBrowserNavigationUrl(url)) return;
      followedPopupTargets.add(targetId);
      void this.followPopupTarget(preview, targetId, url).catch(
        (error: unknown) => this.handleCaptureError(preview, error),
      );
    };

    preview.cleanupHandlers.push(
      cdp.onEvent("Target.targetCreated", (event) => {
        followTargetInfo(objectValue(event.params.targetInfo));
      }),
    );

    preview.cleanupHandlers.push(
      cdp.onEvent("Target.targetInfoChanged", (event) => {
        followTargetInfo(objectValue(event.params.targetInfo));
      }),
    );
  }

  private async followPopupTarget(
    preview: BrowserPreviewRecord,
    targetId: string,
    url: string,
  ): Promise<void> {
    await this.navigatePreviewToUrl(preview, url);
    await preview.cdp?.send("Target.closeTarget", { targetId }).catch(() => {});
  }

  private async navigatePreviewToUrl(
    preview: BrowserPreviewRecord,
    url: string,
  ): Promise<void> {
    if (!isBrowserNavigationUrl(url)) return;
    const cdp = preview.cdp;
    const sessionId = preview.sessionIdCdp;
    if (!cdp || !sessionId || preview.status !== "running") return;
    const result = await cdp.send("Page.navigate", { url }, sessionId);
    const errorText = stringValue(result.errorText);
    if (errorText) {
      throw new BrowserPreviewError(`Could not open browser URL: ${errorText}`, 502);
    }
    this.updatePreviewUrl(preview, url);
    await this.captureAndBroadcast(preview);
  }

  private updatePreviewUrl(preview: BrowserPreviewRecord, url: string): void {
    if (preview.url === url) return;
    preview.url = url;
    preview.inspectorSnapshot = null;
    preview.inspectorSelectedPath = null;
    preview.storageSnapshot = null;
    preview.updatedAt = Date.now();
    this.broadcast(preview, { type: "preview", preview: this.info(preview) });
  }

  private broadcast(
    preview: BrowserPreviewRecord,
    payload: Record<string, unknown>,
  ): void {
    for (const client of preview.clients) {
      if (client.readyState !== client.OPEN) continue;
      if (client.bufferedAmount > MAX_CLIENT_BUFFERED_AMOUNT) {
        client.close(1013, "browser preview client is too far behind");
        continue;
      }
      sendJson(client, payload);
    }
  }

  private async cleanup(): Promise<void> {
    const now = Date.now();
    await Promise.all(
      [...this.previews.values()]
        .filter(
          (preview) =>
            preview.clients.size === 0 &&
            now - preview.updatedAt > this.idleTtlMs,
        )
        .map((preview) => this.stopRecord(preview, "stopped")),
    );
  }

  private async stopRecord(
    preview: BrowserPreviewRecord,
    status: BrowserPreviewStatus,
  ): Promise<void> {
    this.stopFrameLoop(preview);
    this.flushConsoleBuffer(preview);
    preview.status = status;
    preview.updatedAt = Date.now();
    for (const client of preview.clients) {
      try {
        sendJson(client, { type: "closed", preview: this.info(preview) });
        client.close();
      } catch {
        // noop
      }
    }
    preview.clients.clear();
    if (preview.consoleFlushTimer) {
      clearInterval(preview.consoleFlushTimer);
      preview.consoleFlushTimer = null;
    }
    if (preview.storageRefreshTimer) {
      clearTimeout(preview.storageRefreshTimer);
      preview.storageRefreshTimer = null;
    }
    for (const cleanup of preview.cleanupHandlers.splice(0)) {
      cleanup();
    }
    if (preview.targetId && preview.cdp && !preview.ownsBrowser) {
      await preview.cdp
        .send("Target.closeTarget", { targetId: preview.targetId })
        .catch(() => {});
    }
    if (preview.ownsBrowser) {
      preview.cdp?.close();
    }
    preview.cdp = null;
    preview.sessionIdCdp = null;
    preview.targetId = null;
    preview.mainFrameId = null;
    if (preview.ownsBrowser && preview.process) {
      await terminateBrowserProcess(preview.process);
    }
    preview.process = null;
    const userDataDir = preview.userDataDir;
    preview.userDataDir = null;
    if (preview.ownsBrowser && userDataDir) {
      await rm(userDataDir, { recursive: true, force: true }).catch(() => {});
    }
    this.previews.delete(preview.id);
    if (
      preview.profileMode === "sidemesh" &&
      ![...this.previews.values()].some(
        (item) =>
          item.profileMode === "sidemesh" &&
          (item.status === "running" || item.status === "starting"),
      )
    ) {
      await this.stopPersistentHost();
    }
  }

  private async stopPersistentHost(): Promise<void> {
    const host = this.persistentHost;
    this.persistentHost = null;
    if (!host) return;
    host.cdp.close();
    await terminateBrowserProcess(host.process);
  }

  private requirePreview(id: string): BrowserPreviewRecord {
    const preview = this.previews.get(id);
    if (!preview) {
      throw new BrowserPreviewError("browser preview not found", 404);
    }
    return preview;
  }

  private findReusablePreview(
    criteria: BrowserPreviewReuseCriteria,
  ): BrowserPreviewRecord | null {
    const key = browserPreviewReuseKey(criteria);
    for (const preview of this.previews.values()) {
      if (preview.status !== "running" && preview.status !== "starting") {
        continue;
      }
      if (browserPreviewReuseKey(preview) === key) {
        return preview;
      }
    }
    return null;
  }

  private isPreviewUnhealthy(preview: BrowserPreviewRecord): boolean {
    if (preview.status === "failed" || preview.status === "stopped") return true;
    if (preview.status === "starting") return false;
    if (preview.cdp?.isClosed) return true;
    if (preview.lastError && preview.lastFrameAt == null) return true;
    const noFramesEver = preview.lastFrameAt == null;
    const staleWithoutClients =
      preview.clients.size === 0 &&
      Date.now() - preview.updatedAt >
        Math.max(60_000, this.frameIntervalMs * 10);
    return noFramesEver && staleWithoutClients;
  }

  private assertEnabled(): void {
    if (!this.enabled) {
      throw new BrowserPreviewError("browser preview is disabled", 403);
    }
  }

  private enforcePreviewLimit(): void {
    if (this.previews.size < this.maxPreviews) return;
    throw new BrowserPreviewError("browser preview limit reached", 429);
  }

  private info(preview: BrowserPreviewRecord): BrowserPreviewInfo {
    return {
      id: preview.id,
      label: preview.label,
      url: preview.url,
      targetHost: preview.targetHost,
      targetPort: preview.targetPort,
      scheme: preview.scheme,
      cwd: preview.cwd,
      sessionId: preview.sessionId,
      profileMode: preview.profileMode,
      status: preview.status,
      width: preview.width,
      height: preview.height,
      clients: preview.clients.size,
      createdAt: preview.createdAt,
      updatedAt: preview.updatedAt,
      lastClientAt: preview.lastClientAt,
      lastFrameAt: preview.lastFrameAt,
      lastError: preview.lastError,
    };
  }
}

export class BrowserPreviewError extends Error {
  public constructor(
    message: string,
    public readonly status = 400,
  ) {
    super(message);
    this.name = "BrowserPreviewError";
  }
}

class CdpConnection {
  private nextId = 1;
  private closed = false;
  private readonly events = new EventEmitter();
  private readonly pending = new Map<
    number,
    {
      resolve: (value: Record<string, unknown>) => void;
      reject: (error: Error) => void;
    }
  >();

  private constructor(private readonly socket: WebSocket) {
    this.events.setMaxListeners(128);
    socket.on("message", (raw) => this.handleMessage(raw));
    socket.on("close", () => {
      this.closed = true;
      this.rejectAll(new Error("CDP socket closed"));
    });
    socket.on("error", (error) => {
      this.closed = true;
      this.rejectAll(error);
    });
  }

  public get isClosed(): boolean {
    return this.closed || this.socket.readyState >= WebSocket.CLOSING;
  }

  public static async connect(url: string): Promise<CdpConnection> {
    const socket = new WebSocket(url);
    await once(socket, "open");
    return new CdpConnection(socket);
  }

  public send(
    method: string,
    params: Record<string, unknown> = {},
    sessionId?: string | null,
  ): Promise<Record<string, unknown>> {
    if (this.isClosed) {
      return Promise.reject(new Error("CDP socket closed"));
    }
    const id = this.nextId++;
    const payload = sessionId
      ? { id, method, params, sessionId }
      : { id, method, params };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new Error(
            `CDP ${method} timed out after ${CDP_COMMAND_TIMEOUT_MS}ms`,
          ),
        );
      }, CDP_COMMAND_TIMEOUT_MS);
      timer.unref?.();
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
      this.socket.send(JSON.stringify(payload), (error) => {
        if (!error) return;
        const pending = this.pending.get(id);
        this.pending.delete(id);
        pending?.reject(error);
      });
    });
  }

  public onEvent(
    method: string,
    listener: (event: CdpEventPayload) => void,
  ): () => void {
    this.events.on(method, listener);
    return () => this.events.off(method, listener);
  }

  public onSessionEvent(
    sessionId: string,
    method: string,
    listener: (params: Record<string, unknown>) => void,
  ): () => void {
    const wrapped = (event: CdpEventPayload) => {
      if (event.sessionId !== sessionId) return;
      listener(event.params);
    };
    this.events.on(method, wrapped);
    return () => this.events.off(method, wrapped);
  }

  public close(): void {
    this.closed = true;
    try {
      this.socket.close();
    } catch {
      // noop
    }
  }

  private handleMessage(raw: WebSocket.RawData): void {
    let message: unknown;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (!message || typeof message !== "object" || Array.isArray(message)) {
      return;
    }
    const record = message as Record<string, unknown>;
    const id = typeof record.id === "number" ? record.id : null;
    if (id == null) {
      const method = stringValue(record.method);
      if (!method) return;
      this.events.emit(method, {
        method,
        params: objectValue(record.params) ?? {},
        sessionId: stringValue(record.sessionId) || null,
      } satisfies CdpEventPayload);
      return;
    }
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    if (record.error && typeof record.error === "object") {
      const error = record.error as Record<string, unknown>;
      pending.reject(
        new Error(stringValue(error.message) || `CDP ${id} failed`),
      );
      return;
    }
    const result = record.result;
    pending.resolve(
      result && typeof result === "object" && !Array.isArray(result)
        ? (result as Record<string, unknown>)
        : {},
    );
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) {
      pending.reject(error);
    }
    this.pending.clear();
  }
}

interface CdpEventPayload {
  method: string;
  params: Record<string, unknown>;
  sessionId: string | null;
}

async function setViewport(preview: BrowserPreviewRecord): Promise<void> {
  if (!preview.cdp || !preview.sessionIdCdp) return;
  await preview.cdp.send(
    "Emulation.setDeviceMetricsOverride",
    {
      width: preview.width,
      height: preview.height,
      deviceScaleFactor: 1,
      // Always keep mobile:false.  Toggling this flag changes Chrome's user
      // agent string which can trigger page reloads / layout recalculations
      // mid-resize and cause screenshot dimension mismatches.
      mobile: false,
    },
    preview.sessionIdCdp,
  );
}

async function navigateToReachableTarget(
  cdp: CdpConnection,
  sessionId: string,
  preview: BrowserPreviewRecord,
): Promise<string> {
  const candidates = preview.initialUrl
    ? [preview.initialUrl]
    : buildBrowserTargetUrlCandidates(
        preview.scheme,
        preview.targetHost,
        preview.targetPort,
      );
  const failures: string[] = [];
  for (const url of candidates) {
    try {
      const result = await cdp.send("Page.navigate", { url }, sessionId);
      const errorText = stringValue(result.errorText);
      if (!errorText) {
        return url;
      }
      failures.push(`${url}: ${errorText}`);
    } catch (error) {
      failures.push(
        `${url}: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
  throw new BrowserPreviewError(
    `Could not open browser preview target. Tried ${failures.join("; ")}`,
    502,
  );
}

async function sendSpecialKey(
  cdp: CdpConnection,
  sessionId: string,
  key: string,
): Promise<void> {
  const spec = specialKeySpec(key);
  if (!spec) return;
  await cdp.send(
    "Input.dispatchKeyEvent",
    {
      type: "rawKeyDown",
      key: spec.key,
      code: spec.code,
      windowsVirtualKeyCode: spec.keyCode,
      nativeVirtualKeyCode: spec.keyCode,
    },
    sessionId,
  );
  await cdp.send(
    "Input.dispatchKeyEvent",
    {
      type: "keyUp",
      key: spec.key,
      code: spec.code,
      windowsVirtualKeyCode: spec.keyCode,
      nativeVirtualKeyCode: spec.keyCode,
    },
    sessionId,
  );
}

function specialKeySpec(
  key: string,
): { key: string; code: string; keyCode: number } | null {
  switch (key) {
    case "Enter":
      return { key: "Enter", code: "Enter", keyCode: 13 };
    case "Tab":
      return { key: "Tab", code: "Tab", keyCode: 9 };
    case "Escape":
      return { key: "Escape", code: "Escape", keyCode: 27 };
    case "Backspace":
      return { key: "Backspace", code: "Backspace", keyCode: 8 };
    case "ArrowLeft":
      return { key: "ArrowLeft", code: "ArrowLeft", keyCode: 37 };
    case "ArrowUp":
      return { key: "ArrowUp", code: "ArrowUp", keyCode: 38 };
    case "ArrowRight":
      return { key: "ArrowRight", code: "ArrowRight", keyCode: 39 };
    case "ArrowDown":
      return { key: "ArrowDown", code: "ArrowDown", keyCode: 40 };
    default:
      return null;
  }
}

async function launchChrome(
  chromePath: string,
  userDataDir: string,
): Promise<{
  process: BrowserProcess;
  browserWsUrl: string;
}> {
  await mkdir(userDataDir, { recursive: true });
  const args = [
    "--headless=new",
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--remote-debugging-port=0",
    `--user-data-dir=${userDataDir}`,
    "about:blank",
  ];
  if (typeof process.getuid === "function" && process.getuid() === 0) {
    args.unshift("--no-sandbox");
  }
  const env = { ...process.env };
  delete env.SIDEMESH_TOKEN;
  const child = spawn(chromePath, args, {
    stdio: ["ignore", "pipe", "pipe"],
    env,
  });
  try {
    const browserWsUrl = await waitForDevToolsUrl(child);
    return { process: child, browserWsUrl };
  } catch (error) {
    await terminateBrowserProcess(child);
    throw error;
  }
}

async function terminateBrowserProcess(child: BrowserProcess): Promise<void> {
  if (isBrowserProcessExited(child)) return;
  child.kill("SIGTERM");
  const exited = await waitForProcessExit(child, CHROME_SHUTDOWN_TIMEOUT_MS);
  if (exited || isBrowserProcessExited(child)) return;
  child.kill("SIGKILL");
  await waitForProcessExit(child, CHROME_SHUTDOWN_TIMEOUT_MS);
}

function isBrowserProcessExited(child: BrowserProcess): boolean {
  return child.exitCode !== null || child.signalCode !== null;
}

async function waitForProcessExit(
  child: BrowserProcess,
  timeoutMs: number,
): Promise<boolean> {
  if (isBrowserProcessExited(child)) return true;
  let timeout: NodeJS.Timeout | null = null;
  try {
    return await Promise.race([
      once(child, "exit").then(() => true),
      new Promise<boolean>((resolve) => {
        timeout = setTimeout(() => resolve(false), timeoutMs);
        timeout.unref?.();
      }),
    ]);
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function waitForDevToolsUrl(
  child: BrowserProcess,
): Promise<string> {
  let output = "";
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new BrowserPreviewError("Timed out starting Chromium.", 500));
    }, CHROME_START_TIMEOUT_MS);
    const onData = (chunk: Buffer) => {
      output += chunk.toString("utf8");
      const match = /DevTools listening on (ws:\/\/[^\s]+)/.exec(output);
      if (!match) return;
      cleanup();
      resolve(match[1]);
    };
    const onExit = () => {
      cleanup();
      reject(
        new BrowserPreviewError(
          `Chromium exited before opening DevTools. ${output}`.trim(),
          500,
        ),
      );
    };
    const cleanup = () => {
      clearTimeout(timer);
      child.stderr.off("data", onData);
      child.stdout.off("data", onData);
      child.off("exit", onExit);
    };
    child.stderr.on("data", onData);
    child.stdout.on("data", onData);
    child.once("exit", onExit);
  });
}

async function resolveChromePath(explicit: string | null): Promise<string> {
  if (explicit) return explicit;
  const candidates = process.platform === "darwin"
    ? [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
      ]
    : [
        "google-chrome-stable",
        "google-chrome",
        "chromium-browser",
        "chromium",
        "chrome",
      ];
  for (const candidate of candidates) {
    if (path.isAbsolute(candidate)) {
      try {
        await access(candidate);
        return candidate;
      } catch {
        continue;
      }
    }
    if (await commandExists(candidate)) return candidate;
  }
  throw new BrowserPreviewError(
    "Chromium/Chrome was not found. Set SIDEMESH_BROWSER_PREVIEW_CHROME_PATH.",
    500,
  );
}

async function commandExists(command: string): Promise<boolean> {
  const checker = spawn("sh", ["-lc", `command -v ${shellQuote(command)}`], {
    stdio: "ignore",
  });
  const [code] = (await once(checker, "exit")) as [number | null];
  return code === 0;
}

function normalizedPoint(
  message: Record<string, unknown>,
  preview: BrowserPreviewRecord,
): { x: number; y: number } {
  const normalizedX = clamp(numberValue(message.x, 0), 0, 1);
  const normalizedY = clamp(numberValue(message.y, 0), 0, 1);
  return {
    x: Math.round(normalizedX * preview.width),
    y: Math.round(normalizedY * preview.height),
  };
}

async function runtimeEvaluateJson(
  cdp: CdpConnection,
  sessionId: string,
  expression: string,
): Promise<unknown> {
  const result = await cdp.send(
    "Runtime.evaluate",
    {
      expression,
      returnByValue: true,
      awaitPromise: true,
    },
    sessionId,
  );
  const record = objectValue(result);
  const exceptionDetails = objectValue(record?.exceptionDetails);
  if (exceptionDetails) {
    throw new BrowserPreviewError(
      stringOrNull(exceptionDetails.text) || "Inspector evaluation failed.",
      500,
    );
  }
  const remoteResult = objectValue(record?.result);
  return remoteResult?.value;
}

function buildInspectorSnapshotExpression(payload: {
  selectedPath: number[] | null;
  inspectPoint: { x: number; y: number } | null;
}): string {
  const input = JSON.stringify({
    selectedPath: payload.selectedPath,
    inspectPoint: payload.inspectPoint,
    maxChildren: INSPECTOR_MAX_CHILDREN,
    maxTextPreview: INSPECTOR_MAX_TEXT_PREVIEW,
    computedStyleNames: INSPECTOR_COMPUTED_STYLE_NAMES,
  });
  return `(() => {
    const input = ${input};
    const maxChildren = Number(input.maxChildren) || 24;
    const maxTextPreview = Number(input.maxTextPreview) || 160;
    const computedStyleNames = Array.isArray(input.computedStyleNames)
      ? input.computedStyleNames.map((item) => String(item))
      : [];
    const selectedPathInput = Array.isArray(input.selectedPath)
      ? input.selectedPath.map((item) => Number(item))
      : null;
    const inspectPoint = input.inspectPoint &&
      typeof input.inspectPoint === "object"
      ? {
          x: Number(input.inspectPoint.x),
          y: Number(input.inspectPoint.y),
        }
      : null;
    const warnings = [];

    function trimText(value) {
      const normalized = String(value ?? "").replace(/\\s+/g, " ").trim();
      if (!normalized) return null;
      return normalized.length > maxTextPreview
        ? normalized.slice(0, maxTextPreview - 1) + "…"
        : normalized;
    }

    function selectorFor(element) {
      const tag = String(element.localName || element.nodeName || "").toLowerCase() || "node";
      const id = element.id ? "#" + element.id : "";
      const className = typeof element.className === "string"
        ? element.className.trim().split(/\\s+/).filter(Boolean).slice(0, 3).join(".")
        : "";
      return tag + id + (className ? "." + className : "");
    }

    function elementPath(element) {
      if (!(element instanceof Element)) return [];
      const path = [];
      let current = element;
      while (current && current !== document.documentElement) {
        const parent = current.parentElement;
        if (!parent) return [];
        const index = Array.prototype.indexOf.call(parent.children, current);
        if (index < 0) return [];
        path.unshift(index);
        current = parent;
      }
      return path;
    }

    function resolvePath(path) {
      if (!Array.isArray(path)) return null;
      let current = document.documentElement;
      for (const rawIndex of path) {
        const index = Number(rawIndex);
        if (!Number.isInteger(index) || index < 0) return null;
        if (!current || !current.children || index >= current.children.length) {
          return null;
        }
        current = current.children[index];
      }
      return current instanceof Element ? current : null;
    }

    function pathsEqual(left, right) {
      if (!Array.isArray(left) || !Array.isArray(right)) return false;
      if (left.length !== right.length) return false;
      for (let index = 0; index < left.length; index += 1) {
        if (left[index] !== right[index]) return false;
      }
      return true;
    }

    function summarizeNode(element, path, selectedPath) {
      return {
        path,
        nodeName: String(element.localName || element.nodeName || "").toLowerCase() || "node",
        selector: selectorFor(element),
        textPreview: trimText(element.textContent),
        childElementCount: element.children.length,
        isSelected: pathsEqual(path, selectedPath),
        truncatedChildren: false,
        children: [],
      };
    }

    function buildTree(element, path, selectedPath) {
      const node = summarizeNode(element, path, selectedPath);
      const children = Array.from(element.children);
      if (children.length === 0) return node;
      const selectedHere = pathsEqual(path, selectedPath);
      const nextIndex = Array.isArray(selectedPath) && selectedPath.length > path.length
        ? selectedPath[path.length]
        : null;
      const indices = [];
      for (let index = 0; index < Math.min(children.length, maxChildren); index += 1) {
        indices.push(index);
      }
      if (
        Number.isInteger(nextIndex) &&
        nextIndex >= 0 &&
        nextIndex < children.length &&
        !indices.includes(nextIndex)
      ) {
        indices.push(nextIndex);
      }
      indices.sort((left, right) => left - right);
      node.truncatedChildren = children.length > indices.length;
      node.children = indices.map((childIndex) => {
        const child = children[childIndex];
        const childPath = path.concat(childIndex);
        if (selectedHere || childIndex === nextIndex) {
          return buildTree(child, childPath, selectedPath);
        }
        return summarizeNode(child, childPath, selectedPath);
      });
      return node;
    }

    function attributesFor(element) {
      return element.getAttributeNames()
        .map((name) => ({ name, value: element.getAttribute(name) ?? "" }))
        .sort((left, right) => left.name.localeCompare(right.name));
    }

    function inlineStylesFor(element) {
      return Array.from(element.style)
        .map((name) => ({ name, value: element.style.getPropertyValue(name) }))
        .filter((entry) => entry.value.trim().length > 0)
        .sort((left, right) => left.name.localeCompare(right.name));
    }

    function computedStylesFor(element) {
      const styles = window.getComputedStyle(element);
      return computedStyleNames
        .map((name) => ({ name, value: styles.getPropertyValue(name).trim() }))
        .filter((entry) => entry.value.length > 0)
        .sort((left, right) => left.name.localeCompare(right.name));
    }

    function boxFor(element) {
      const rect = element.getBoundingClientRect();
      if (!Number.isFinite(rect.x) || !Number.isFinite(rect.y)) return null;
      return {
        x: Math.round(rect.x * 100) / 100,
        y: Math.round(rect.y * 100) / 100,
        width: Math.round(rect.width * 100) / 100,
        height: Math.round(rect.height * 100) / 100,
      };
    }

    if (!(document.documentElement instanceof Element)) {
      return {
        selectedPath: [],
        treeRoot: null,
        selectedNode: null,
        warnings: ["Inspector is unavailable on this page."],
      };
    }

    let selected = null;
    if (
      inspectPoint &&
      Number.isFinite(inspectPoint.x) &&
      Number.isFinite(inspectPoint.y)
    ) {
      const picked = document.elementFromPoint(inspectPoint.x, inspectPoint.y);
      if (picked instanceof Element) {
        selected = picked;
      } else {
        warnings.push("No element was found at that point.");
      }
    }
    if (!selected && Array.isArray(selectedPathInput)) {
      selected = resolvePath(selectedPathInput);
      if (!selected && selectedPathInput.length > 0) {
        warnings.push("The selected element is no longer available.");
      }
    }
    if (!selected) {
      selected = document.body instanceof Element
        ? document.body
        : document.documentElement;
    }

    const selectedPath = elementPath(selected);
    const treeRoot = buildTree(document.documentElement, [], selectedPath);
    const selectedNode = Object.assign(
      summarizeNode(selected, selectedPath, selectedPath),
      {
        attributes: attributesFor(selected),
        computedStyles: computedStylesFor(selected),
        inlineStyles: inlineStylesFor(selected),
        box: boxFor(selected),
      },
    );

    return {
      selectedPath,
      treeRoot,
      selectedNode,
      warnings,
    };
  })()`;
}

function inspectorSnapshotFromRuntimeValue(
  value: unknown,
  url: string,
): BrowserPreviewInspectorSnapshot {
  const record = objectValue(value);
  return {
    url,
    refreshedAt: Date.now(),
    selectedPath: inspectorPathFromValue(record?.selectedPath) ?? [],
    treeRoot: inspectorNodeFromValue(record?.treeRoot),
    selectedNode: inspectorSelectedNodeFromValue(record?.selectedNode),
    warnings: stringList(record?.warnings),
  };
}

function inspectorNodeFromValue(
  value: unknown,
): BrowserPreviewInspectorNode | null {
  const record = objectValue(value);
  if (!record) return null;
  return {
    path: inspectorPathFromValue(record.path) ?? [],
    nodeName: stringValue(record.nodeName) || "node",
    selector: stringValue(record.selector) || stringValue(record.nodeName) || "node",
    textPreview: stringOrNull(record.textPreview),
    childElementCount: numberValue(record.childElementCount, 0),
    isSelected: record.isSelected === true,
    truncatedChildren: record.truncatedChildren === true,
    children: Array.isArray(record.children)
      ? record.children
          .map((item) => inspectorNodeFromValue(item))
          .filter((item): item is BrowserPreviewInspectorNode => item !== null)
      : [],
  };
}

function inspectorSelectedNodeFromValue(
  value: unknown,
): BrowserPreviewInspectorSelectedNode | null {
  const node = inspectorNodeFromValue(value);
  const record = objectValue(value);
  if (!node || !record) return null;
  return {
    ...node,
    attributes: inspectorAttributeList(record.attributes),
    computedStyles: inspectorStyleList(record.computedStyles),
    inlineStyles: inspectorStyleList(record.inlineStyles),
    box: inspectorBoxFromValue(record.box),
  };
}

function inspectorAttributeList(
  value: unknown,
): BrowserPreviewInspectorAttribute[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => objectValue(item))
    .filter((item): item is Record<string, unknown> => item !== null)
    .map((item) => ({
      name: stringValue(item.name),
      value: stringValue(item.value),
    }))
    .filter((item) => item.name.length > 0);
}

function inspectorStyleList(
  value: unknown,
): BrowserPreviewInspectorStyleProperty[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => objectValue(item))
    .filter((item): item is Record<string, unknown> => item !== null)
    .map((item) => ({
      name: stringValue(item.name),
      value: stringValue(item.value),
    }))
    .filter((item) => item.name.length > 0 && item.value.length > 0);
}

function inspectorBoxFromValue(
  value: unknown,
): BrowserPreviewInspectorBox | null {
  const record = objectValue(value);
  if (!record) return null;
  return {
    x: numberValue(record.x, 0),
    y: numberValue(record.y, 0),
    width: numberValue(record.width, 0),
    height: numberValue(record.height, 0),
  };
}

function inspectorPathFromValue(value: unknown): number[] | null {
  if (!Array.isArray(value)) return null;
  const path: number[] = [];
  for (const item of value) {
    if (!Number.isInteger(item) || item < 0) {
      return null;
    }
    path.push(item);
  }
  return path;
}

function normalizePort(value: number | null | undefined): number {
  if (!Number.isInteger(value) || value == null || value < 1 || value > 65535) {
    throw new BrowserPreviewError("targetPort must be between 1 and 65535", 400);
  }
  return value;
}

function normalizeCreateTarget(
  request: CreateBrowserPreviewRequest,
): NormalizedBrowserPreviewTarget {
  const rawTargetUrl = request.targetUrl?.trim();
  if (rawTargetUrl) {
    return normalizeBrowserPreviewTargetUrl(rawTargetUrl);
  }
  const targetHost = normalizeTargetHost(request.targetHost);
  const targetPort = normalizePort(request.targetPort);
  const scheme = normalizeScheme(request.scheme);
  return {
    targetHost,
    targetPort,
    scheme,
    initialUrl: null,
    defaultLabel: `${scheme.toUpperCase()} ${targetHost}:${targetPort}`,
  };
}

export function normalizeBrowserPreviewTargetUrl(
  value: string,
): NormalizedBrowserPreviewTarget {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new BrowserPreviewError("browser preview targetUrl must be a URL", 400);
  }
  const scheme = normalizeScheme(parsed.protocol.replace(/:$/, ""));
  const targetPort = normalizeUrlPort(parsed, scheme);
  const targetHost = normalizeUrlTargetHost(parsed.hostname);
  const initialUrl = normalizeInitialTargetUrl(parsed, targetHost);
  return {
    targetHost,
    targetPort,
    scheme,
    initialUrl,
    defaultLabel:
      new URL(initialUrl).host ||
      `${scheme.toUpperCase()} ${targetHost}:${targetPort}`,
  };
}

function normalizeTargetHost(value: string | null | undefined): string {
  const rawTargetHost = value?.trim() || "127.0.0.1";
  const targetHost =
    rawTargetHost === "[::1]" ? "::1" : rawTargetHost.toLowerCase();
  if (
    !["127.0.0.1", "::1", "localhost"].includes(targetHost) &&
    !isLocalhostSubdomain(targetHost)
  ) {
    throw new BrowserPreviewError(
      "browser previews can only open localhost targets",
      400,
    );
  }
  return targetHost;
}

function normalizeUrlTargetHost(hostname: string): string {
  const hostnameWithoutBrackets = hostname
    .trim()
    .toLowerCase()
    .replace(/^\[|\]$/g, "");
  if (
    hostnameWithoutBrackets === "0.0.0.0" ||
    hostnameWithoutBrackets.startsWith("127.")
  ) {
    return "127.0.0.1";
  }
  if (hostnameWithoutBrackets === "localhost") {
    return "127.0.0.1";
  }
  if (hostnameWithoutBrackets === "::1") {
    return "::1";
  }
  if (isLocalhostSubdomain(hostnameWithoutBrackets)) {
    return hostnameWithoutBrackets;
  }
  if (!hostnameWithoutBrackets) {
    throw new BrowserPreviewError("browser preview targetUrl must include a host", 400);
  }
  return hostnameWithoutBrackets;
}

function normalizeUrlPort(parsed: URL, scheme: BrowserPreviewScheme): number {
  if (!parsed.port) {
    return scheme === "https" ? 443 : 80;
  }
  const targetPort = Number(parsed.port);
  if (!Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65535) {
    throw new BrowserPreviewError("targetPort must be between 1 and 65535", 400);
  }
  return targetPort;
}

function normalizeInitialTargetUrl(parsed: URL, targetHost: string): string {
  const url = new URL(parsed.href);
  const rawHost = parsed.hostname
    .trim()
    .toLowerCase()
    .replace(/^\[|\]$/g, "");
  if (targetHost === "127.0.0.1" && rawHost !== "localhost") {
    url.hostname = "127.0.0.1";
  } else if (targetHost === "::1") {
    url.hostname = "[::1]";
  } else if (isLocalhostSubdomain(targetHost)) {
    url.hostname = targetHost;
  }
  return url.href;
}

function normalizeScheme(value: string | null | undefined): BrowserPreviewScheme {
  const scheme = value?.trim().toLowerCase() || "http";
  if (scheme === "http" || scheme === "https") return scheme;
  throw new BrowserPreviewError("browser preview scheme must be http or https");
}

function normalizeProfileMode(
  value: string | null | undefined,
): BrowserPreviewProfileMode {
  const mode = value?.trim().toLowerCase() || "temporary";
  if (mode === "temporary" || mode === "sidemesh") return mode;
  throw new BrowserPreviewError(
    "browser preview profileMode must be temporary or sidemesh",
  );
}

export function buildBrowserTargetUrlCandidates(
  scheme: BrowserPreviewScheme,
  targetHost: string,
  targetPort: number,
): string[] {
  if (isLocalhostSubdomain(targetHost)) {
    return [`${scheme}://${targetHost}:${targetPort}/`];
  }
  if (!["127.0.0.1", "localhost", "::1"].includes(targetHost)) {
    return [`${scheme}://${formatUrlHost(targetHost)}:${targetPort}/`];
  }
  return loopbackTargetCandidates(targetHost).map(
    (host) => `${scheme}://${formatUrlHost(host)}:${targetPort}/`,
  );
}

export function browserPreviewReuseKey(
  criteria: BrowserPreviewReuseCriteria,
): string {
  return JSON.stringify([
    criteria.profileMode,
    criteria.scheme,
    criteria.targetHost,
    criteria.targetPort,
    criteria.cwd ?? "",
    criteria.sessionId ?? "",
  ]);
}

export function isBrowserNavigationUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

function loopbackTargetCandidates(targetHost: string): string[] {
  switch (targetHost) {
    case "localhost":
      return ["localhost", "127.0.0.1", "::1"];
    case "::1":
      return ["::1", "localhost", "127.0.0.1"];
    case "127.0.0.1":
    default:
      return ["127.0.0.1", "localhost", "::1"];
  }
}

function isLocalhostSubdomain(value: string): boolean {
  return /^[a-z0-9-]+(?:\.[a-z0-9-]+)*\.localhost$/.test(value);
}

function formatUrlHost(host: string): string {
  return host.includes(":") ? `[${host.replace(/^\[|\]$/g, "")}]` : host;
}

function normalizeViewportSize(
  value: unknown,
  fallback: number,
  max: number,
): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(MIN_VIEWPORT_SIZE, Math.min(max, Math.round(parsed)));
}

function isTrackedBrowserPreviewNetworkUrl(url: string): boolean {
  return !!url && !url.startsWith("data:") && !url.startsWith("about:");
}

function canBrowserPreviewRequestHaveBody(method: string): boolean {
  switch (method.trim().toUpperCase()) {
    case "POST":
    case "PUT":
    case "PATCH":
    case "DELETE":
      return true;
    default:
      return false;
  }
}

function browserPreviewNetworkStartedAt(
  params: Record<string, unknown>,
): number {
  const wallTime = numberOrNull(params.wallTime);
  if (wallTime != null) {
    return Math.round(wallTime * 1000);
  }
  return Date.now();
}

function timestampFromSeconds(value: number | null): number | null {
  if (value == null) return null;
  return Math.round(value * 1000);
}

function headerRecord(value: unknown): Record<string, string> {
  const record = objectValue(value);
  if (!record) return {};
  const headers: Record<string, string> = {};
  for (const [key, headerValue] of Object.entries(record)) {
    if (typeof headerValue === "string") {
      headers[key] = headerValue;
      continue;
    }
    if (typeof headerValue === "number" || typeof headerValue === "boolean") {
      headers[key] = String(headerValue);
      continue;
    }
    if (Array.isArray(headerValue)) {
      headers[key] = headerValue.map((item) => String(item)).join(", ");
    }
  }
  return headers;
}

function headerValue(
  headers: Record<string, string>,
  name: string,
): string | null {
  const target = name.toLowerCase();
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === target) {
      return value;
    }
  }
  return null;
}

function consoleArgumentRecords(args: unknown[]): Array<Record<string, unknown>> {
  return args
    .map((arg) => objectValue(arg))
    .filter((arg): arg is Record<string, unknown> => arg !== null)
    .slice(0, 20);
}

function browserPreviewConsoleText(args: unknown[]): string {
  return args
    .map((arg) => browserPreviewConsoleValue(arg))
    .filter((value) => value.length > 0)
    .join(" ");
}

function browserPreviewConsoleValue(value: unknown): string {
  const record = objectValue(value);
  if (!record) {
    return typeof value === "string" ? value : String(value ?? "");
  }
  if (Object.prototype.hasOwnProperty.call(record, "value")) {
    const primitive = record.value;
    if (typeof primitive === "string") {
      return primitive;
    }
    if (primitive === null) {
      return "null";
    }
    if (
      typeof primitive === "number" ||
      typeof primitive === "boolean" ||
      typeof primitive === "bigint"
    ) {
      return String(primitive);
    }
    if (primitive !== undefined) {
      try {
        return JSON.stringify(primitive);
      } catch {
        return String(primitive);
      }
    }
  }
  const unserializableValue = stringOrNull(record.unserializableValue);
  if (unserializableValue) {
    return unserializableValue;
  }
  if (record.subtype === "null") {
    return "null";
  }
  const preview = objectValue(record.preview);
  const previewText = browserPreviewConsolePreviewText(preview);
  if (previewText) {
    return previewText;
  }
  const description = stringOrNull(record.description);
  if (description) {
    return description;
  }
  const type = stringOrNull(record.type);
  return type ?? "";
}

function browserPreviewConsolePreviewText(
  preview: Record<string, unknown> | null,
): string | null {
  if (!preview) return null;
  const subtype = stringOrNull(preview.subtype);
  const properties = Array.isArray(preview.properties)
    ? preview.properties
        .map((item) => objectValue(item))
        .filter((item): item is Record<string, unknown> => item !== null)
    : [];
  const overflow = preview.overflow === true;
  if (subtype === "array") {
    const values = properties
      .map((item) => stringOrNull(item.value) ?? stringOrNull(item.name) ?? "")
      .filter((item) => item.length > 0);
    if (values.length === 0) {
      return overflow ? "[…]" : "[]";
    }
    return `[${values.join(", ")}${overflow ? ", …" : ""}]`;
  }
  if (properties.length === 0) {
    return null;
  }
  const parts = properties.map((item) => {
    const name = stringOrNull(item.name) ?? "";
    const value = stringOrNull(item.value) ?? stringOrNull(item.type) ?? "";
    return name ? `${name}: ${value}` : value;
  });
  return `{${parts.join(", ")}${overflow ? ", …" : ""}}`;
}

function websocketFramePayloadIsBase64(
  response: Record<string, unknown> | null,
): boolean {
  const opcode = numberOrNull(response?.opcode);
  if (opcode == null) {
    return false;
  }
  return opcode !== 0 && opcode !== 1;
}

function storageOriginForUrl(url: string): string | null {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return null;
    }
    return parsed.origin;
  } catch {
    return null;
  }
}

function storageAreaFromMessage(
  value: unknown,
): BrowserPreviewStorageArea | null {
  if (value === "localStorage" || value === "sessionStorage") {
    return value;
  }
  return null;
}

function storageIdForArea(
  origin: string,
  area: BrowserPreviewStorageArea,
): { securityOrigin: string; isLocalStorage: boolean } {
  return {
    securityOrigin: origin,
    isLocalStorage: area === "localStorage",
  };
}

function indexedDbDatabaseNamesFromResult(value: unknown): string[] {
  const record = objectValue(value);
  if (!Array.isArray(record?.databaseNames)) return [];
  return record.databaseNames
    .map((item) => stringValue(item).trim())
    .filter((item) => item.length > 0)
    .sort((left, right) => left.localeCompare(right));
}

function indexedDbDatabaseFromResult(
  value: unknown,
): BrowserPreviewIndexedDbDatabase | null {
  const record = objectValue(value);
  const rawDatabase = objectValue(record?.databaseWithObjectStores);
  if (!rawDatabase) return null;
  const name = stringValue(rawDatabase.name).trim();
  if (!name) return null;
  const objectStores = Array.isArray(rawDatabase.objectStores)
    ? rawDatabase.objectStores
        .map((item) => objectValue(item))
        .filter((item): item is Record<string, unknown> => item !== null)
        .map((store) => ({
          name: stringValue(store.name),
          keyPath: indexedDbKeyPathText(store.keyPath),
          autoIncrement: store.autoIncrement === true,
          indexes: indexedDbIndexesFromResult(store.indexes),
        }))
        .filter((store) => store.name.length > 0)
        .sort((left, right) => left.name.localeCompare(right.name))
    : [];
  return {
    name,
    version: numberOrNull(rawDatabase.version),
    objectStores,
  };
}

function indexedDbIndexesFromResult(
  value: unknown,
): BrowserPreviewIndexedDbIndex[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => objectValue(item))
    .filter((item): item is Record<string, unknown> => item !== null)
    .map((item) => ({
      name: stringValue(item.name),
      keyPath: indexedDbKeyPathText(item.keyPath),
      unique: item.unique === true,
      multiEntry: item.multiEntry === true,
    }))
    .filter((item) => item.name.length > 0)
    .sort((left, right) => left.name.localeCompare(right.name));
}

function indexedDbKeyPathText(value: unknown): string | null {
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed ? trimmed : null;
  }
  if (Array.isArray(value)) {
    const values = value
      .map((item) => stringValue(item).trim())
      .filter((item) => item.length > 0);
    return values.length > 0 ? `[${values.join(", ")}]` : null;
  }
  const record = objectValue(value);
  if (!record) return null;
  const type = stringValue(record.type);
  if (type === "string") {
    return stringOrNull(record.string);
  }
  if (type === "array") {
    const values = Array.isArray(record.array)
      ? record.array
          .map((item) => stringValue(item).trim())
          .filter((item) => item.length > 0)
      : [];
    return values.length > 0 ? `[${values.join(", ")}]` : null;
  }
  return stringOrNull(record.description);
}

function storageEntriesFromPairs(value: unknown): BrowserPreviewStorageEntry[] {
  if (!Array.isArray(value)) return [];
  const entries: BrowserPreviewStorageEntry[] = [];
  for (const item of value) {
    if (!Array.isArray(item) || item.length < 2) continue;
    entries.push({
      key: typeof item[0] === "string" ? item[0] : String(item[0] ?? ""),
      value: typeof item[1] === "string" ? item[1] : String(item[1] ?? ""),
    });
  }
  entries.sort((left, right) => left.key.localeCompare(right.key));
  return entries;
}

function storageUsageBreakdownFromResult(
  value: unknown,
): BrowserPreviewStorageUsage[] {
  if (!Array.isArray(value)) return [];
  const entries = value
    .map((item) => objectValue(item))
    .filter((item): item is Record<string, unknown> => item !== null)
    .map((item) => ({
      storageType: stringValue(item.storageType),
      usage: numberValue(item.usage, 0),
    }))
    .filter((item) => item.storageType.length > 0);
  entries.sort((left, right) => right.usage - left.usage);
  return entries;
}

function cookiesFromResult(value: unknown): BrowserPreviewStorageCookie[] {
  const record = objectValue(value);
  const cookies = Array.isArray(record?.cookies) ? record.cookies : [];
  const entries = cookies
    .map((item) => objectValue(item))
    .filter((item): item is Record<string, unknown> => item !== null)
    .map((item) => {
      const session = item.session === true;
      const expires = numberOrNull(item.expires);
      return {
        name: stringValue(item.name),
        value: stringValue(item.value),
        domain: stringValue(item.domain),
        path: stringValue(item.path) || "/",
        expires:
          session || expires == null || expires < 0 ? null : expires,
        size: numberOrNull(item.size),
        httpOnly: item.httpOnly === true,
        secure: item.secure === true,
        session,
        sameSite: stringOrNull(item.sameSite),
      } satisfies BrowserPreviewStorageCookie;
    });
  entries.sort((left, right) => {
    const domainOrder = left.domain.localeCompare(right.domain);
    if (domainOrder !== 0) return domainOrder;
    const pathOrder = left.path.localeCompare(right.path);
    if (pathOrder !== 0) return pathOrder;
    return left.name.localeCompare(right.name);
  });
  return entries;
}

function stringOrNull(value: unknown): string | null {
  const result = stringValue(value).trim();
  return result ? result : null;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .map((item) => stringValue(item).trim())
    .filter((item) => item.length > 0);
}

function stringField(record: Record<string, unknown>, field: string): string {
  const value = record[field];
  if (typeof value === "string" && value) return value;
  throw new BrowserPreviewError(`CDP response missing ${field}`, 500);
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function objectValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function numberValue(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function clampInteger(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min;
  return Math.max(min, Math.min(max, Math.round(value)));
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function sendJson(socket: WebSocket, payload: Record<string, unknown>): void {
  if (socket.readyState !== socket.OPEN) return;
  if (socket.bufferedAmount > MAX_CLIENT_BUFFERED_AMOUNT) return;
  socket.send(JSON.stringify(payload));
}
