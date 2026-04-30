import { randomUUID } from "node:crypto";
import { connect, type Socket } from "node:net";

import type { WebSocket } from "ws";

const DEFAULT_TARGET_HOST = "127.0.0.1";
const DEFAULT_MAX_FORWARDS = 24;
const DEFAULT_IDLE_TTL_MS = 12 * 60 * 60 * 1000;
const TARGET_CONNECT_TIMEOUT_MS = 15_000;
const MAX_WS_BUFFERED_AMOUNT = 8 * 1024 * 1024;
const MAX_PENDING_CLIENT_BYTES = 1024 * 1024;

export type PortForwardScheme = "http" | "https" | "tcp";
export type PortForwardStatus = "running" | "stopped";

export interface PortForwardRegistryOptions {
  enabled: boolean;
  allowNonLoopbackTargets?: boolean;
  maxForwards?: number;
  idleTtlMs?: number;
}

export interface CreatePortForwardRequest {
  targetPort: number | null;
  targetHost?: string | null;
  scheme?: string | null;
  label?: string | null;
  cwd?: string | null;
  sessionId?: string | null;
}

export interface PortForwardInfo {
  id: string;
  label: string;
  targetHost: string;
  targetPort: number;
  scheme: PortForwardScheme;
  cwd: string | null;
  sessionId: string | null;
  status: PortForwardStatus;
  createdAt: number;
  updatedAt: number;
  lastConnectionAt: number | null;
  connections: number;
  activeConnections: number;
  bytesFromClient: number;
  bytesFromTarget: number;
}

interface PortForwardRecord {
  id: string;
  label: string;
  targetHost: string;
  targetPort: number;
  scheme: PortForwardScheme;
  cwd: string | null;
  sessionId: string | null;
  status: PortForwardStatus;
  createdAt: number;
  updatedAt: number;
  lastConnectionAt: number | null;
  connections: number;
  activeConnections: number;
  bytesFromClient: number;
  bytesFromTarget: number;
  activeClosers: Set<() => void>;
}

export class PortForwardRegistry {
  private readonly forwards = new Map<string, PortForwardRecord>();
  private readonly enabled: boolean;
  private readonly allowNonLoopbackTargets: boolean;
  private readonly maxForwards: number;
  private readonly idleTtlMs: number;
  private cleanupTimer: NodeJS.Timeout | null = null;

  public constructor(options: PortForwardRegistryOptions) {
    this.enabled = options.enabled;
    this.allowNonLoopbackTargets = options.allowNonLoopbackTargets === true;
    this.maxForwards = options.maxForwards ?? DEFAULT_MAX_FORWARDS;
    this.idleTtlMs = options.idleTtlMs ?? DEFAULT_IDLE_TTL_MS;
    if (this.enabled) {
      this.cleanupTimer = setInterval(() => this.cleanup(), 60_000);
      this.cleanupTimer.unref?.();
    }
  }

  public isEnabled(): boolean {
    return this.enabled;
  }

  public list(): PortForwardInfo[] {
    return [...this.forwards.values()]
      .map((forward) => this.info(forward))
      .sort((left, right) => right.updatedAt - left.updatedAt);
  }

  public get(id: string): PortForwardInfo | null {
    const forward = this.forwards.get(id);
    return forward ? this.info(forward) : null;
  }

  public create(request: CreatePortForwardRequest): PortForwardInfo {
    this.assertEnabled();
    this.enforceForwardLimit();

    const targetPort = normalizePort(request.targetPort);
    const targetHost = normalizeTargetHost(
      request.targetHost,
      this.allowNonLoopbackTargets,
    );
    const scheme = normalizeScheme(request.scheme);
    const label =
      request.label?.trim() ||
      `${scheme === "tcp" ? "TCP" : scheme.toUpperCase()} ${targetHost}:${targetPort}`;
    const now = Date.now();
    const forward: PortForwardRecord = {
      id: randomUUID(),
      label,
      targetHost,
      targetPort,
      scheme,
      cwd: request.cwd?.trim() || null,
      sessionId: request.sessionId?.trim() || null,
      status: "running",
      createdAt: now,
      updatedAt: now,
      lastConnectionAt: null,
      connections: 0,
      activeConnections: 0,
      bytesFromClient: 0,
      bytesFromTarget: 0,
      activeClosers: new Set(),
    };
    this.forwards.set(forward.id, forward);
    return this.info(forward);
  }

  public stop(id: string): PortForwardInfo {
    this.assertEnabled();
    const forward = this.requireForward(id);
    forward.status = "stopped";
    forward.updatedAt = Date.now();
    for (const close of [...forward.activeClosers]) {
      close();
    }
    return this.info(forward);
  }

  public attach(socket: WebSocket, id: string): void {
    if (!this.enabled) {
      sendJson(socket, {
        type: "error",
        message: "port forwarding is disabled",
      });
      socket.close();
      return;
    }
    const forward = this.forwards.get(id);
    if (!forward || forward.status !== "running") {
      sendJson(socket, { type: "error", message: "port forward not found" });
      socket.close();
      return;
    }

    let target: Socket | null = null;
    let targetConnected = false;
    const pendingClientChunks: Buffer[] = [];
    let pendingClientBytes = 0;
    let closed = false;
    const connectTimer = setTimeout(() => {
      sendJson(socket, {
        type: "error",
        message: "target connection timed out",
      });
      closeBoth();
    }, TARGET_CONNECT_TIMEOUT_MS);
    connectTimer.unref?.();

    forward.connections += 1;
    forward.activeConnections += 1;
    forward.lastConnectionAt = Date.now();
    forward.updatedAt = forward.lastConnectionAt;

    const closeBoth = () => {
      if (closed) return;
      closed = true;
      clearTimeout(connectTimer);
      forward.activeClosers.delete(closeBoth);
      forward.activeConnections = Math.max(0, forward.activeConnections - 1);
      forward.updatedAt = Date.now();
      try {
        target?.destroy();
      } catch {
        // noop
      }
      try {
        socket.close();
      } catch {
        // noop
      }
    };
    forward.activeClosers.add(closeBoth);

    socket.on("message", (raw) => {
      if (closed) return;
      if (typeof raw === "string") return;
      const payload = rawDataToBuffer(raw);
      if (payload.length === 0) return;
      forward.bytesFromClient += payload.length;
      forward.updatedAt = Date.now();
      if (targetConnected && target && !target.destroyed) {
        target.write(payload);
        return;
      }
      pendingClientBytes += payload.length;
      if (pendingClientBytes > MAX_PENDING_CLIENT_BYTES) {
        sendJson(socket, {
          type: "error",
          message: "port forward target is not ready; request buffer exceeded",
        });
        closeBoth();
        return;
      }
      pendingClientChunks.push(payload);
    });
    socket.on("close", closeBoth);
    socket.on("error", closeBoth);

    const targetHosts = loopbackTargetCandidates(forward.targetHost);
    let targetHostIndex = 0;
    const connectNextTarget = (lastError: Error | null = null): void => {
      if (closed) return;
      const host = targetHosts[targetHostIndex];
      if (!host) {
        sendJson(socket, {
          type: "error",
          message: `target connection failed: ${
            lastError?.message ?? "no loopback target was reachable"
          }`,
        });
        closeBoth();
        return;
      }
      targetHostIndex += 1;
      let attemptSettled = false;
      const attempt = connect({
        host,
        port: forward.targetPort,
      });
      target = attempt;
      let attemptDone = false;
      const failAttempt = (error: Error | null) => {
        if (attemptDone || closed) return;
        attemptDone = true;
        try {
          attempt.destroy();
        } catch {
          // noop
        }
        connectNextTarget(error);
      };
      attempt.on("connect", () => {
        if (closed) return;
        attemptSettled = true;
        attemptDone = true;
        targetConnected = true;
        clearTimeout(connectTimer);
        sendJson(socket, {
          type: "hello",
          portForward: this.info(forward),
        });
        for (const chunk of pendingClientChunks.splice(0)) {
          attempt.write(chunk);
        }
        pendingClientBytes = 0;
      });
      attempt.on("data", (chunk) => {
        if (closed || socket.readyState !== socket.OPEN) return;
        if (socket.bufferedAmount > MAX_WS_BUFFERED_AMOUNT) {
          sendJson(socket, {
            type: "error",
            message: "port forward client is too far behind; reconnecting",
          });
          closeBoth();
          return;
        }
        forward.bytesFromTarget += chunk.length;
        forward.updatedAt = Date.now();
        socket.send(chunk);
      });
      attempt.on("close", () => {
        if (closed) return;
        if (targetConnected) {
          closeBoth();
          return;
        }
        if (!attemptSettled && !attemptDone) {
          failAttempt(new Error("target connection closed before it was ready"));
        }
      });
      attempt.on("error", (error) => {
        if (closed) return;
        if (targetConnected) {
          sendJson(socket, {
            type: "error",
            message: `target connection failed: ${error.message}`,
          });
          closeBoth();
          return;
        }
        failAttempt(error);
      });
    };
    connectNextTarget();
  }

  public dispose(): void {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
    for (const forward of this.forwards.values()) {
      for (const close of [...forward.activeClosers]) {
        close();
      }
    }
    this.forwards.clear();
  }

  private cleanup(): void {
    const now = Date.now();
    for (const forward of this.forwards.values()) {
      if (
        forward.activeConnections === 0 &&
        now - forward.updatedAt > this.idleTtlMs
      ) {
        this.forwards.delete(forward.id);
      }
    }
  }

  private enforceForwardLimit(): void {
    this.cleanup();
    if (this.forwards.size < this.maxForwards) {
      return;
    }
    const stale = [...this.forwards.values()]
      .filter((forward) => forward.activeConnections === 0)
      .sort((left, right) => left.updatedAt - right.updatedAt)[0];
    if (!stale) {
      throw new PortForwardError("port forward limit reached", 429);
    }
    this.forwards.delete(stale.id);
  }

  private assertEnabled(): void {
    if (!this.enabled) {
      throw new PortForwardError("port forwarding is disabled", 403);
    }
  }

  private requireForward(id: string): PortForwardRecord {
    const forward = this.forwards.get(id);
    if (!forward) {
      throw new PortForwardError("port forward not found", 404);
    }
    return forward;
  }

  private info(forward: PortForwardRecord): PortForwardInfo {
    return {
      id: forward.id,
      label: forward.label,
      targetHost: forward.targetHost,
      targetPort: forward.targetPort,
      scheme: forward.scheme,
      cwd: forward.cwd,
      sessionId: forward.sessionId,
      status: forward.status,
      createdAt: forward.createdAt,
      updatedAt: forward.updatedAt,
      lastConnectionAt: forward.lastConnectionAt,
      connections: forward.connections,
      activeConnections: forward.activeConnections,
      bytesFromClient: forward.bytesFromClient,
      bytesFromTarget: forward.bytesFromTarget,
    };
  }
}

export class PortForwardError extends Error {
  public readonly status: number;

  public constructor(message: string, status = 500) {
    super(message);
    this.name = "PortForwardError";
    this.status = status;
  }
}

function normalizePort(value: number | null): number {
  if (
    value === null ||
    !Number.isInteger(value) ||
    value < 1 ||
    value > 65535
  ) {
    throw new PortForwardError("targetPort must be between 1 and 65535", 400);
  }
  return value;
}

function normalizeTargetHost(
  value: string | null | undefined,
  allowNonLoopbackTargets: boolean,
): string {
  const host = value?.trim() || DEFAULT_TARGET_HOST;
  if (host === "[::1]") {
    return "::1";
  }
  if (allowNonLoopbackTargets || isLoopbackHost(host)) {
    return host;
  }
  throw new PortForwardError(
    "targetHost must be localhost unless non-loopback targets are enabled",
    400,
  );
}

function normalizeScheme(value: string | null | undefined): PortForwardScheme {
  const scheme = value?.trim().toLowerCase() || "http";
  if (scheme === "http" || scheme === "https" || scheme === "tcp") {
    return scheme;
  }
  throw new PortForwardError("scheme must be http, https, or tcp", 400);
}

function isLoopbackHost(host: string): boolean {
  const normalized = host.toLowerCase();
  if (
    normalized === "localhost" ||
    normalized === "::1" ||
    normalized === "[::1]"
  ) {
    return true;
  }
  const ipv4 = normalized.match(/^127(?:\.(?:\d{1,3})){0,3}$/);
  if (!ipv4) return false;
  return normalized
    .split(".")
    .slice(1)
    .every((part) => Number(part) >= 0 && Number(part) <= 255);
}

export function loopbackTargetCandidates(host: string): string[] {
  const normalized = host.toLowerCase();
  if (normalized === "localhost") {
    return ["localhost", "::1", "127.0.0.1"];
  }
  if (normalized === "127.0.0.1") {
    return ["127.0.0.1", "::1", "localhost"];
  }
  if (normalized === "::1") {
    return ["::1", "127.0.0.1", "localhost"];
  }
  return [host];
}

function rawDataToBuffer(raw: WebSocket.RawData): Buffer {
  if (Buffer.isBuffer(raw)) return raw;
  if (raw instanceof ArrayBuffer) return Buffer.from(raw);
  if (Array.isArray(raw)) return Buffer.concat(raw);
  return Buffer.from(raw);
}

function sendJson(socket: WebSocket, payload: Record<string, unknown>): void {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}
