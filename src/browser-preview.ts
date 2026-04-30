import { randomUUID } from "node:crypto";
import { access, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { once } from "node:events";
import type { Readable } from "node:stream";

import { WebSocket } from "ws";

const DEFAULT_MAX_PREVIEWS = 8;
const DEFAULT_IDLE_TTL_MS = 60 * 60 * 1000;
const DEFAULT_FRAME_INTERVAL_MS = 900;
const DEFAULT_WIDTH = 390;
const DEFAULT_HEIGHT = 844;
const DEFAULT_QUALITY = 55;
const CHROME_START_TIMEOUT_MS = 10_000;
const MAX_TEXT_INPUT_CHARS = 20_000;
const MAX_CLIENT_BUFFERED_AMOUNT = 8 * 1024 * 1024;

type BrowserProcess = ChildProcessByStdio<null, Readable, Readable>;

export type BrowserPreviewStatus = "starting" | "running" | "stopped" | "failed";
export type BrowserPreviewScheme = "http" | "https";

export interface BrowserPreviewRegistryOptions {
  enabled: boolean;
  chromePath?: string | null;
  maxPreviews?: number;
  idleTtlMs?: number;
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

interface BrowserPreviewRecord {
  id: string;
  label: string;
  url: string;
  targetHost: string;
  targetPort: number;
  scheme: BrowserPreviewScheme;
  cwd: string | null;
  sessionId: string | null;
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
  nextFrameSeq: number;
  frameTimer: NodeJS.Timeout | null;
  starting: Promise<void> | null;
  capturingFrame: boolean;
}

export class BrowserPreviewRegistry {
  private readonly previews = new Map<string, BrowserPreviewRecord>();
  private readonly enabled: boolean;
  private readonly chromePath: string | null;
  private readonly maxPreviews: number;
  private readonly idleTtlMs: number;
  private cleanupTimer: NodeJS.Timeout | null = null;

  public constructor(options: BrowserPreviewRegistryOptions) {
    this.enabled = options.enabled;
    this.chromePath = options.chromePath?.trim() || null;
    this.maxPreviews = options.maxPreviews ?? DEFAULT_MAX_PREVIEWS;
    this.idleTtlMs = options.idleTtlMs ?? DEFAULT_IDLE_TTL_MS;
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
    this.enforcePreviewLimit();

    const targetHost = normalizeTargetHost(request.targetHost);
    const targetPort = normalizePort(request.targetPort);
    const scheme = normalizeScheme(request.scheme);
    const width = normalizeViewportSize(request.width, DEFAULT_WIDTH);
    const height = normalizeViewportSize(request.height, DEFAULT_HEIGHT);
    const url = `${scheme}://${targetHost}:${targetPort}/`;
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
      cwd: request.cwd?.trim() || null,
      sessionId: request.sessionId?.trim() || null,
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
      nextFrameSeq: 1,
      frameTimer: null,
      starting: null,
      capturingFrame: false,
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
    if (!preview || preview.status === "stopped") {
      sendJson(socket, { type: "error", message: "browser preview not found" });
      socket.close();
      return;
    }

    preview.clients.add(socket);
    preview.lastClientAt = Date.now();
    preview.updatedAt = preview.lastClientAt;
    sendJson(socket, { type: "hello", preview: this.info(preview) });

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
  }

  private async startPreview(preview: BrowserPreviewRecord): Promise<void> {
    try {
      const chromePath = await resolveChromePath(this.chromePath);
      const userDataDir = await mkdtemp(
        path.join(tmpdir(), "sidemesh-browser-preview-"),
      );
      preview.userDataDir = userDataDir;
      const { process: child, browserWsUrl } = await launchChrome(
        chromePath,
        userDataDir,
      );
      preview.process = child;
      const cdp = await CdpConnection.connect(browserWsUrl);
      const target = await cdp.send("Target.createTarget", {
        url: "about:blank",
        width: preview.width,
        height: preview.height,
      });
      const targetId = stringField(target, "targetId");
      const attached = await cdp.send("Target.attachToTarget", {
        targetId,
        flatten: true,
      });
      const sessionId = stringField(attached, "sessionId");
      preview.cdp = cdp;
      preview.sessionIdCdp = sessionId;
      await setViewport(preview);
      await cdp.send("Page.enable", {}, sessionId);
      await cdp.send("Runtime.enable", {}, sessionId);
      await cdp.send("Page.navigate", { url: preview.url }, sessionId);
      preview.status = "running";
      preview.updatedAt = Date.now();
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
    } catch (error) {
      preview.status = "failed";
      preview.lastError = error instanceof Error ? error.message : String(error);
      preview.updatedAt = Date.now();
      await this.stopRecord(preview, "failed");
      throw error;
    }
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
    if (type === "resize") {
      preview.width = normalizeViewportSize(message.width, preview.width);
      preview.height = normalizeViewportSize(message.height, preview.height);
      await setViewport(preview);
    }
  }

  private startFrameLoop(preview: BrowserPreviewRecord): void {
    if (preview.frameTimer || preview.clients.size === 0) return;
    preview.frameTimer = setInterval(() => {
      void this.captureAndBroadcast(preview).catch((error: unknown) =>
        this.handleCaptureError(preview, error),
      );
    }, DEFAULT_FRAME_INTERVAL_MS);
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
          quality: DEFAULT_QUALITY,
          fromSurface: true,
          optimizeForSpeed: true,
        },
        sessionId,
      );
      const data = stringField(response, "data");
      preview.lastFrameAt = Date.now();
      preview.updatedAt = preview.lastFrameAt;
      this.broadcast(preview, {
        type: "frame",
        seq: preview.nextFrameSeq++,
        mimeType: "image/jpeg",
        width: preview.width,
        height: preview.height,
        timestamp: preview.lastFrameAt,
        data,
      });
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

  private broadcast(
    preview: BrowserPreviewRecord,
    payload: Record<string, unknown>,
  ): void {
    for (const client of preview.clients) {
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
    preview.cdp?.close();
    preview.cdp = null;
    preview.sessionIdCdp = null;
    if (preview.process && !preview.process.killed) {
      preview.process.kill("SIGTERM");
    }
    preview.process = null;
    const userDataDir = preview.userDataDir;
    preview.userDataDir = null;
    if (userDataDir) {
      await rm(userDataDir, { recursive: true, force: true }).catch(() => {});
    }
    this.previews.delete(preview.id);
  }

  private requirePreview(id: string): BrowserPreviewRecord {
    const preview = this.previews.get(id);
    if (!preview) {
      throw new BrowserPreviewError("browser preview not found", 404);
    }
    return preview;
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
  private readonly pending = new Map<
    number,
    {
      resolve: (value: Record<string, unknown>) => void;
      reject: (error: Error) => void;
    }
  >();

  private constructor(private readonly socket: WebSocket) {
    socket.on("message", (raw) => this.handleMessage(raw));
    socket.on("close", () => this.rejectAll(new Error("CDP socket closed")));
    socket.on("error", (error) => this.rejectAll(error));
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
    const id = this.nextId++;
    const payload = sessionId
      ? { id, method, params, sessionId }
      : { id, method, params };
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify(payload), (error) => {
        if (!error) return;
        this.pending.delete(id);
        reject(error);
      });
    });
  }

  public close(): void {
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
    if (id == null) return;
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
  const targetHost = value?.trim() || "127.0.0.1";
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

function numberValue(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function sendJson(socket: WebSocket, payload: Record<string, unknown>): void {
  if (socket.readyState !== socket.OPEN) return;
  if (socket.bufferedAmount > MAX_CLIENT_BUFFERED_AMOUNT) return;
  socket.send(JSON.stringify(payload));
}
