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
const MAX_TEXT_INPUT_CHARS = 20_000;
const MAX_CLIENT_BUFFERED_AMOUNT = 8 * 1024 * 1024;
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
  targetPort: number | null;
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
  ownsBrowser: boolean;
  nextFrameSeq: number;
  lastFramePayload: Record<string, unknown> | null;
  frameTimer: NodeJS.Timeout | null;
  starting: Promise<void> | null;
  capturingFrame: boolean;
  cleanupHandlers: Array<() => void>;
}

interface PersistentBrowserHost {
  userDataDir: string;
  process: BrowserProcess;
  cdp: CdpConnection;
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

    const targetHost = normalizeTargetHost(request.targetHost);
    const targetPort = normalizePort(request.targetPort);
    const scheme = normalizeScheme(request.scheme);
    const width = normalizeViewportSize(request.width, DEFAULT_WIDTH);
    const height = normalizeViewportSize(request.height, DEFAULT_HEIGHT);
    const cwd = request.cwd?.trim() || null;
    const sessionId = request.sessionId?.trim() || null;
    const profileMode = normalizeProfileMode(request.profileMode);
    let reusable = this.findReusablePreview({
      targetHost,
      targetPort,
      scheme,
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
      return this.info(reusable);
    }

    this.enforcePreviewLimit();

    const url = buildBrowserTargetUrlCandidates(
      scheme,
      targetHost,
      targetPort,
    )[0];
    const now = Date.now();
    const preview: BrowserPreviewRecord = {
      id: randomUUID(),
      label:
        request.label?.trim() ||
        `${scheme.toUpperCase()} ${targetHost}:${targetPort}`,
      url,
      targetHost,
      targetPort,
      scheme,
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
      ownsBrowser: false,
      nextFrameSeq: 1,
      lastFramePayload: null,
      frameTimer: null,
      starting: null,
      capturingFrame: false,
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

    preview.clients.add(socket);
    preview.lastClientAt = Date.now();
    preview.updatedAt = preview.lastClientAt;
    sendJson(socket, { type: "hello", preview: this.info(preview) });
    if (preview.lastFramePayload) {
      sendJson(socket, preview.lastFramePayload);
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
    const { process: child, browserWsUrl } = await launchChrome(chromePath, userDataDir);
    try {
      return {
        cdp: await CdpConnection.connect(browserWsUrl),
        process: child,
        userDataDir,
        ownsBrowser: true,
      };
    } catch (error) {
      if (!child.killed) child.kill("SIGTERM");
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
    const { process: child, browserWsUrl } = await launchChrome(chromePath, userDataDir);
    let cdp: CdpConnection;
    try {
      cdp = await CdpConnection.connect(browserWsUrl);
      await cdp.send("Target.setDiscoverTargets", { discover: true });
    } catch (error) {
      if (!child.killed) child.kill("SIGTERM");
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
    try {
      await this.applyInput(preview, message as Record<string, unknown>);
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
    if (type === "resize") {
      await this.updatePreviewViewport(
        preview,
        normalizeViewportSize(message.width, preview.width),
        normalizeViewportSize(message.height, preview.height),
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
    preview.width = width;
    preview.height = height;
    preview.updatedAt = Date.now();
    await setViewport(preview);
    preview.lastFramePayload = null;
    this.broadcast(preview, { type: "preview", preview: this.info(preview) });
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
    if (preview.ownsBrowser && preview.process && !preview.process.killed) {
      preview.process.kill("SIGTERM");
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
    if (!host.process.killed) {
      host.process.kill("SIGTERM");
    }
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
      mobile: preview.width < 700,
    },
    preview.sessionIdCdp,
  );
}

async function navigateToReachableTarget(
  cdp: CdpConnection,
  sessionId: string,
  preview: BrowserPreviewRecord,
): Promise<string> {
  const candidates = buildBrowserTargetUrlCandidates(
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
  const browserWsUrl = await waitForDevToolsUrl(child);
  return { process: child, browserWsUrl };
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

function normalizePort(value: number | null): number {
  if (!Number.isInteger(value) || value == null || value < 1 || value > 65535) {
    throw new BrowserPreviewError("targetPort must be between 1 and 65535", 400);
  }
  return value;
}

function normalizeTargetHost(value: string | null | undefined): string {
  const rawTargetHost = value?.trim() || "127.0.0.1";
  const targetHost = rawTargetHost === "[::1]" ? "::1" : rawTargetHost;
  if (!["127.0.0.1", "::1", "localhost"].includes(targetHost)) {
    throw new BrowserPreviewError(
      "browser previews can only open localhost targets",
      400,
    );
  }
  return targetHost;
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

function formatUrlHost(host: string): string {
  return host.includes(":") ? `[${host.replace(/^\[|\]$/g, "")}]` : host;
}

function normalizeViewportSize(value: unknown, fallback: number): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(240, Math.min(2200, Math.round(parsed)));
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
