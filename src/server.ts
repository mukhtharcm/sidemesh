import { createServer } from "node:http";
import type { Server } from "node:http";
import { hostname, platform } from "node:os";
import { createHash, randomUUID } from "node:crypto";
import nodePath from "node:path";

import compression from "compression";
import cors from "cors";
import express, {
  type Request,
  type Response,
  type NextFunction,
} from "express";
import { WebSocketServer, type WebSocket } from "ws";

import {
  hasProviderMethod,
  materializeAgentActivityDraft,
  requireProviderMethod,
  type AgentPendingAction,
  type AgentProvider,
  type AgentProviderMethodName,
  type AgentSessionActivityDraft,
  type AgentSessionInputItem,
  type AgentSessionOverrides,
} from "./agent-provider.js";
import type {
  ActiveTurnState,
  ApprovalLiveEvent,
  GitInfoSummary,
  HostCapabilities,
  LiveEvent,
  SessionActivity,
  NodeConfig,
  PendingAction,
  RecentSessionsLiveEvent,
  SessionMessageAttachment,
  SessionMessage,
  SessionResourcesResponse,
  SessionRuntimeSummary,
  SessionResource,
  SessionSummary,
  ThreadRecord,
  TurnRecord,
  WorkspaceSummary,
} from "./types.js";
import {
  applyCommandTerminalInteraction,
  appendCommandActivityOutput,
  mergeActivity,
  mergeSessionActivities,
} from "./activity.js";
import {
  parsePendingActionResponseBody,
  toPublicPendingAction,
} from "./approvals.js";
import { summarizeProviderConfig } from "./config.js";
import {
  buildGitDiff,
  readGitDiff,
  readGitStatus,
  sanitizeGitUrl,
} from "./git.js";
import { createAgentProviderRuntime } from "./provider-factory.js";
import { isAgentProviderKind } from "./provider-registry.js";
import { buildSessionResources } from "./resources.js";
import { MultiAgentProvider } from "./multi-provider.js";
import {
  FsWatchRegistry,
  attachFsLiveSocket,
  registerFsRoutes,
} from "./fs-routes.js";
import {
  TerminalError,
  TerminalRegistry,
  normalizeTerminalShell,
} from "./terminal.js";
import { PortForwardError, PortForwardRegistry } from "./port-forward.js";
import {
  BrowserPreviewError,
  BrowserPreviewRegistry,
} from "./browser-preview.js";
import {
  WorkspaceAccessError,
  collectWorkspaceRoots,
  resolveWorkspacePath,
} from "./workspace-scope.js";
import {
  SessionInputDedupeStore,
  type StoredSessionInputDedupeEntry,
} from "./session-input-dedupe-store.js";
import { startupSummaryLines } from "./startup-summary.js";
import { getCodexRpcAuditSnapshot } from "./codex-rpc-audit.js";
import { SessionReplayIndex } from "./session-replay-index.js";

const SESSION_LOG_CACHE_LIMIT = 24;
const SESSION_INPUT_DEDUPE_LIMIT = 500;
const SESSION_INPUT_DEDUPE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const SESSION_INPUT_DEDUPE_FILE = "session-input-dedupe-v1.json";
const CLIENT_MESSAGE_ID_MAX_LENGTH = 128;
const CLIENT_MESSAGE_ID_PATTERN = /^[A-Za-z0-9._:-]+$/;
const RECENT_UNINDEXED_SESSION_SCAN_LIMIT = 50;
const RECENT_LIVE_LIMIT = 40;
const RECENT_SESSIONS_CACHE_TTL_MS = 1_500;
const RECENT_SESSION_RUNTIME_CONCURRENCY = 4;
type SessionRuntimeListMode = "all" | "active" | "none";
const HOST_CAPABILITIES: HostCapabilities = {
  workspace: {
    filesystem: true,
    gitStatus: true,
    gitDiff: true,
    terminal: false,
    portForwarding: false,
    browserPreview: false,
  },
};

interface SessionRuntimeCacheEntry {
  threadUpdatedAt: number;
  runtime: SessionRuntimeSummary | null;
  promise?: Promise<SessionRuntimeSummary | null>;
}

interface SessionLogCacheEntry {
  threadUpdatedAt: number;
  messages: SessionMessage[];
  activities: SessionActivity[];
  runtime: SessionRuntimeSummary | null;
  history: SessionHistorySummary;
  nextSeq: number;
}

interface SessionHistorySummary {
  isTruncated: boolean;
  totalMessages: number;
  returnedMessages: number;
  totalActivities: number;
  returnedActivities: number;
}

interface SessionInputReceipt {
  mode: "steer" | "turn";
  turnId: string | null;
  messageId: string;
}

interface SessionInputDedupeEntry {
  signatureHash: string;
  createdAt: number;
  promise?: Promise<SessionInputReceipt>;
  receipt?: SessionInputReceipt;
}

export interface RunningServer {
  close(): Promise<void>;
}

export async function startServer(config: NodeConfig): Promise<RunningServer> {
  const providerRuntime = createAgentProviderRuntime(config);
  const provider = providerRuntime.provider;
  await provider.start();
  const hostCapabilities: HostCapabilities = {
    workspace: {
      ...HOST_CAPABILITIES.workspace,
      terminal: config.terminal.enabled,
      portForwarding: config.portForwarding.enabled,
      browserPreview: config.browserPreview.enabled,
    },
  };

  const app = express();
  const server = createServer(app);
  const socketsBySession = new Map<string, Set<WebSocket>>();
  const approvalSockets = new Set<WebSocket>();
  const recentSessionsSockets = new Set<WebSocket>();
  const recentSessionBroadcastTimers = new Map<string, NodeJS.Timeout>();
  let recentSessionsCache: {
    limit: number;
    runtimeMode: SessionRuntimeListMode;
    expiresAt: number;
    promise?: Promise<SessionSummary[]>;
    value?: SessionSummary[];
  } | null = null;
  const activeTurns = new Map<string, ActiveTurnState>();
  const pendingActions = new Map<string, AgentPendingAction>();
  const liveActivities = new Map<string, Map<string, SessionActivity>>();
  const replayIndex = new SessionReplayIndex();
  const runtimeCache = new Map<string, SessionRuntimeCacheEntry>();
  const logCache = new Map<string, SessionLogCacheEntry>();
  const sessionSeqCursor = new Map<string, number>();
  const sessionInputDedupe = new Map<string, SessionInputDedupeEntry>();
  const sessionInputDedupeStore = await SessionInputDedupeStore.open(
    nodePath.join(config.stateDir, SESSION_INPUT_DEDUPE_FILE),
    {
      ttlMs: SESSION_INPUT_DEDUPE_TTL_MS,
      limit: SESSION_INPUT_DEDUPE_LIMIT,
    },
  );
  for (const entry of sessionInputDedupeStore.entries()) {
    sessionInputDedupe.set(entry.key, {
      signatureHash: entry.signatureHash,
      createdAt: entry.createdAt,
      receipt: entry.receipt,
    });
  }
  let providerVersion = "unknown";
  const providerVersions = new Map<string, string>();
  const providerEntriesByKind = new Map(
    providerRuntime.providers.map((entry) => [entry.kind, entry]),
  );
  const terminalRegistry = new TerminalRegistry({
    enabled: hostCapabilities.workspace.terminal,
    shell: normalizeTerminalShell(config.terminal.shell),
    requirePty: config.terminal.requirePty,
    resolveCwd: (cwd, request) =>
      resolveTerminalCwd(provider, runtimeCache, cwd, request.sessionId),
  });
  const portForwardRegistry = new PortForwardRegistry({
    enabled: hostCapabilities.workspace.portForwarding,
    allowNonLoopbackTargets: config.portForwarding.allowNonLoopbackTargets,
  });
  const browserPreviewRegistry = new BrowserPreviewRegistry({
    enabled: hostCapabilities.workspace.browserPreview,
    chromePath: config.browserPreview.chromePath,
    persistentProfileRoot: nodePath.join(config.stateDir, "browser-profiles"),
    maxPreviews: config.browserPreview.maxPreviews,
    idleTtlMs: config.browserPreview.idleTtlMs,
    frameIntervalMs: config.browserPreview.frameIntervalMs,
    quality: config.browserPreview.quality,
  });

  function allocSeq(sessionId: string): number {
    const current = sessionSeqCursor.get(sessionId) ?? 0;
    sessionSeqCursor.set(sessionId, current + 1);
    return current;
  }

  function ensureSeqCursor(sessionId: string, minimum: number): void {
    const current = sessionSeqCursor.get(sessionId) ?? 0;
    if (minimum > current) {
      sessionSeqCursor.set(sessionId, minimum);
    }
  }

  function sessionInputDedupeKey(
    sessionId: string,
    clientMessageId: string,
  ): string {
    return `${sessionId}:${clientMessageId}`;
  }

  function providerEntryForKind(kind: string | null | undefined) {
    if (!kind) {
      return providerEntriesByKind.get(config.defaultProviderKind) ?? null;
    }
    if (!isAgentProviderKind(kind)) {
      return null;
    }
    return providerEntriesByKind.get(kind) ?? null;
  }

  function providerEntryForSessionId(sessionId: string) {
    if (provider instanceof MultiAgentProvider) {
      try {
        const resolved = provider.resolveSessionProvider(sessionId);
        return providerEntryForKind(resolved.kind);
      } catch {
        return null;
      }
    }
    return providerEntryForKind(null);
  }

  function mergeRuntimeSummary(
    previous: SessionRuntimeSummary | null,
    next: SessionRuntimeSummary | null,
  ): SessionRuntimeSummary | null {
    if (!previous) {
      return next;
    }
    if (!next) {
      return previous;
    }
    return {
      ...previous,
      ...next,
      telemetry: {
        ...(previous.telemetry ?? {}),
        ...(next.telemetry ?? {}),
      },
    };
  }

  function pruneSessionInputDedupe(now = Date.now()): void {
    for (const [key, entry] of sessionInputDedupe) {
      if (
        !entry.promise &&
        now - entry.createdAt > SESSION_INPUT_DEDUPE_TTL_MS
      ) {
        sessionInputDedupe.delete(key);
      }
    }

    if (sessionInputDedupe.size <= SESSION_INPUT_DEDUPE_LIMIT) {
      return;
    }
    const stale = [...sessionInputDedupe.entries()]
      .filter(([, entry]) => !entry.promise)
      .sort((left, right) => left[1].createdAt - right[1].createdAt)
      .slice(0, sessionInputDedupe.size - SESSION_INPUT_DEDUPE_LIMIT);
    for (const [key] of stale) {
      sessionInputDedupe.delete(key);
    }
  }

  // Wrap each broadcast so every live event carries a monotonically
  // increasing `seq` — this lets clients detect gaps after a reconnect
  // and decide whether they need a fresh snapshot.
  function broadcastLive(sessionId: string, event: LiveEvent): void {
    const stamped: LiveEvent =
      event.seq === undefined ? { ...event, seq: allocSeq(sessionId) } : event;
    broadcast(socketsBySession, sessionId, stamped);
  }

  function broadcastApprovalLive(event: ApprovalLiveEvent): void {
    for (const socket of approvalSockets) {
      sendEvent(socket, event);
    }
  }

  function broadcastRecentSessionsLive(event: RecentSessionsLiveEvent): void {
    for (const socket of recentSessionsSockets) {
      sendEvent(socket, event);
    }
  }

  async function sendRecentSessionsSnapshot(socket: WebSocket): Promise<void> {
    const sessions = await loadRecentSessions(RECENT_LIVE_LIMIT, "active");
    sendEvent(socket, { type: "snapshot", sessions });
  }

  async function loadRecentSessions(
    limitOverride: number | null = null,
    runtimeMode: SessionRuntimeListMode = "active",
  ): Promise<SessionSummary[]> {
    const limit = normalizedSessionListLimit(limitOverride);
    const now = Date.now();
    const cached = recentSessionsCache;
    if (cached && cached.limit >= limit && cached.runtimeMode === runtimeMode) {
      if (cached.promise) {
        return (await cached.promise).slice(0, limit);
      }
      if (cached.value && cached.expiresAt > now) {
        return cached.value.slice(0, limit);
      }
    }

    const promise = listSessions(provider, runtimeCache, limit, runtimeMode);
    recentSessionsCache = {
      limit,
      runtimeMode,
      expiresAt: now + RECENT_SESSIONS_CACHE_TTL_MS,
      promise,
    };
    try {
      const value = await promise;
      recentSessionsCache = {
        limit,
        runtimeMode,
        expiresAt: Date.now() + RECENT_SESSIONS_CACHE_TTL_MS,
        value,
      };
      return value.slice(0, limit);
    } catch (error) {
      if (recentSessionsCache?.promise === promise) {
        recentSessionsCache = null;
      }
      throw error;
    }
  }

  function invalidateRecentSessionsCache(): void {
    recentSessionsCache = null;
  }

  async function broadcastRecentSessionUpsert(
    sessionId: string,
  ): Promise<void> {
    invalidateRecentSessionsCache();
    if (recentSessionsSockets.size === 0) {
      return;
    }
    try {
      const thread = await readSession(provider, sessionId, false);
      const session = mapSession(
        thread,
        await loadCachedSessionRuntime(provider, thread, runtimeCache, "active"),
      );
      broadcastRecentSessionsLive({ type: "upsert", session });
    } catch {
      // The session may have been archived/removed before we could refresh it.
    }
  }

  function scheduleRecentSessionUpsert(sessionId: string, delayMs = 150): void {
    if (recentSessionBroadcastTimers.has(sessionId)) {
      return;
    }
    recentSessionBroadcastTimers.set(
      sessionId,
      setTimeout(() => {
        recentSessionBroadcastTimers.delete(sessionId);
        void broadcastRecentSessionUpsert(sessionId);
      }, delayMs),
    );
  }

  function cancelRecentSessionUpsert(sessionId: string): void {
    const timer = recentSessionBroadcastTimers.get(sessionId);
    if (!timer) {
      return;
    }
    clearTimeout(timer);
    recentSessionBroadcastTimers.delete(sessionId);
  }

  function broadcastRecentSessionRemove(sessionId: string): void {
    invalidateRecentSessionsCache();
    cancelRecentSessionUpsert(sessionId);
    broadcastRecentSessionsLive({ type: "remove", sessionId });
  }

  provider.on("stderr", (line) => {
    process.stderr.write(line);
  });

  const fsWatchRegistry = new FsWatchRegistry();

  async function listSessionsForProvider(
    kind: string | null | undefined,
  ): Promise<SessionSummary[]> {
    const selected = providerEntryForKind(kind);
    if (!selected) {
      return [];
    }
    const sessions = await loadRecentSessions(null, "none");
    return sessions.filter((session) => session.provider === selected.kind);
  }

  provider.on("liveEvent", (event) => {
    switch (event.type) {
      case "fs_changed":
        return;
      case "skills_changed":
        broadcastSkillsChanged(socketsBySession);
        return;
      case "turn_started":
        activeTurns.set(event.sessionId, {
          turnId: event.turnId,
          startedAt: Date.now(),
        });
        broadcastLive(event.sessionId, {
          type: "turn_started",
          sessionId: event.sessionId,
          turnId: event.turnId,
        });
        scheduleRecentSessionUpsert(event.sessionId, 0);
        return;
      case "assistant_delta":
        broadcastLive(event.sessionId, {
          type: "assistant_delta",
          sessionId: event.sessionId,
          delta: event.delta,
          turnId: event.turnId,
          itemId: event.itemId,
        });
        return;
      case "assistant_message_completed": {
        const seq = allocSeq(event.sessionId);
        broadcastLive(event.sessionId, {
          type: "assistant_message_completed",
          sessionId: event.sessionId,
          turnId: event.turnId,
          seq,
          messageItem: {
            id: event.message.id,
            role: "assistant",
            text: event.message.text,
            attachments: [],
            createdAt: Date.now(),
            seq,
            phase: event.message.phase,
          },
        });
        scheduleRecentSessionUpsert(event.sessionId);
        return;
      }
      case "activity_updated": {
        const next = upsertLiveActivity(
          liveActivities,
          event.sessionId,
          materializeLiveActivityDraft(
            liveActivities,
            event.sessionId,
            event.activity,
            () => allocSeq(event.sessionId),
          ),
        );
        broadcastLive(event.sessionId, {
          type: "activity_updated",
          sessionId: event.sessionId,
          turnId: event.turnId,
          activity: next,
        });
        return;
      }
      case "activity_output_delta": {
        const next = updateLiveOutputActivity(
          liveActivities,
          event.sessionId,
          event.activityId,
          event.delta,
        );
        if (next) {
          broadcastLive(event.sessionId, {
            type: "activity_updated",
            sessionId: event.sessionId,
            turnId: event.turnId,
            activity: next,
          });
        }
        return;
      }
      case "activity_terminal_input": {
        const next = updateLiveCommandTerminalInteraction(
          liveActivities,
          event.sessionId,
          event.activityId,
          event.stdin,
        );
        if (next) {
          broadcastLive(event.sessionId, {
            type: "activity_updated",
            sessionId: event.sessionId,
            turnId: event.turnId,
            activity: next,
          });
        }
        return;
      }
      case "runtime_updated": {
        const previousRuntime =
          runtimeCache.get(event.sessionId)?.runtime ??
          logCache.get(event.sessionId)?.runtime ??
          null;
        const runtime = mergeRuntimeSummary(previousRuntime, event.runtime);
        runtimeCache.set(event.sessionId, {
          threadUpdatedAt: Date.now() / 1000,
          runtime,
        });
        const cachedLog = logCache.get(event.sessionId);
        if (cachedLog) {
          cachedLog.runtime = runtime;
        }
        broadcastLive(event.sessionId, {
          type: "runtime_updated",
          sessionId: event.sessionId,
          runtime: runtime ?? undefined,
        });
        scheduleRecentSessionUpsert(event.sessionId, 0);
        return;
      }
      case "turn_completed":
        // Broadcast the completion first so any concurrent snapshot reader
        // sees both the provider-flushed history AND the live state still in
        // memory. Clearing liveActivities before the broadcast can briefly
        // leave both the snapshot and live stream blank for a second client.
        broadcastLive(event.sessionId, {
          type: "turn_completed",
          sessionId: event.sessionId,
          turnId: event.turnId,
          status: event.status,
        });
        clearActionsForSession(
          pendingActions,
          event.sessionId,
          broadcastLive,
          broadcastApprovalLive,
        );
        activeTurns.delete(event.sessionId);
        liveActivities.delete(event.sessionId);
        clearSessionLogCache(logCache, event.sessionId);
        scheduleRecentSessionUpsert(event.sessionId, 0);
        // NOTE: do NOT reset sessionSeqCursor between turns — clients rely on
        // a monotonically increasing seq across the whole session lifetime to
        // detect gaps after a reconnect.
        return;
      case "action_opened":
        pendingActions.set(event.action.id, event.action);
        const publicAction = toPublicPendingAction(event.action);
        broadcastLive(event.action.sessionId, {
          type: "action_opened",
          sessionId: event.action.sessionId,
          action: publicAction,
        });
        broadcastApprovalLive({
          type: "action_opened",
          action: publicAction,
        });
        scheduleRecentSessionUpsert(event.action.sessionId);
        return;
    }
  });

  for (const entry of providerRuntime.providers) {
    providerVersions.set(
      entry.kind,
      await entry.provider.getVersion().catch(() => "unknown"),
    );
  }
  providerVersion =
    providerVersions.get(config.defaultProviderKind) ??
    (await provider.getVersion().catch(() => "unknown"));

  app.use(cors());
  // Compress large JSON responses while skipping already-compressed content
  // types (images, video) and the unauthenticated health-check endpoint.
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
  // Image attachments are sent as data URLs, so message payloads can be
  // materially larger than plain-text turns.
  app.use(express.json({ limit: "16mb" }));

  app.get("/healthz", (_request, response) => {
    response.json({ ok: true, label: config.label });
  });

  app.use((request, response, next) => {
    if (request.path === "/healthz") {
      next();
      return;
    }
    authenticate(request, response, next, config.token);
  });

  app.get("/api/node", (_request, response) => {
    const supportedProviders = providerRuntime.providers.map((entry) => ({
      ...entry.definitionSummary,
      config: entry.configSummary,
      version: providerVersions.get(entry.kind) ?? "unknown",
      isDefault: entry.kind === config.defaultProviderKind,
    }));
    response.json({
      label: config.label,
      hostname: hostname(),
      platform: platform(),
      codexVersion: providerVersion,
      provider: config.defaultProviderKind,
      providerName:
        supportedProviders.find((item) => item.isDefault)?.displayName ??
        provider.displayName,
      providerVersion,
      providerConfig: summarizeProviderConfig(config.provider),
      providerCapabilities: provider.capabilities,
      hostCapabilities,
      supportedProviders,
      startedAt: process.uptime(),
      tokenSource: config.tokenSource,
    });
  });

  app.get("/api/providers", (_request, response) => {
    response.json({
      currentProvider: config.defaultProviderKind,
      providers: providerRuntime.providers.map((entry) => ({
        ...entry.definitionSummary,
        config: entry.configSummary,
        version: providerVersions.get(entry.kind) ?? "unknown",
        isDefault: entry.kind === config.defaultProviderKind,
      })),
    });
  });

  app.get("/api/debug/codex-rpc-audit", (_request, response) => {
    response.json(getCodexRpcAuditSnapshot());
  });

  app.get(
    "/api/sessions",
    asyncRoute(async (_request, response) => {
      if (
        !requireProviderCapability(
          response,
          provider,
          provider.capabilities.sessions.history,
          "session history",
          "listSessionThreads",
        )
      ) {
        return;
      }
      const requestedLimit = asInteger(
        (_request.query as Record<string, unknown>)?.limit,
      );
      const runtimeMode = parseSessionRuntimeListMode(
        (_request.query as Record<string, unknown>)?.runtime,
      );
      const sessions = await loadRecentSessions(requestedLimit, runtimeMode);
      response.json(sessions);
    }),
  );

  app.get(
    "/api/workspaces",
    asyncRoute(async (_request, response) => {
      if (
        !requireProviderCapability(
          response,
          provider,
          provider.capabilities.sessions.history,
          "workspace history",
          "listSessionThreads",
        )
      ) {
        return;
      }
      const sessions = await loadRecentSessions(null, "none");
      response.json(buildWorkspaces(sessions));
    }),
  );

  registerFsRoutes(app, {
    listSessions: () => listSessions(provider, runtimeCache, null, "none"),
  });

  app.get("/api/terminals", (_request, response) => {
    if (
      !requireHostCapability(
        response,
        hostCapabilities.workspace.terminal,
        "integrated terminal",
      )
    ) {
      return;
    }
    response.json({ terminals: terminalRegistry.list() });
  });

  app.post(
    "/api/terminals",
    asyncRoute(async (request, response) => {
      if (
        !requireHostCapability(
          response,
          hostCapabilities.workspace.terminal,
          "integrated terminal",
        )
      ) {
        return;
      }
      const cwd = asString(request.body?.cwd);
      if (!cwd) {
        response.status(400).json({ error: "cwd is required" });
        return;
      }
      const terminal = await terminalRegistry.create({
        cwd,
        title: asString(request.body?.title),
        sessionId: asString(request.body?.sessionId),
        cols: asInteger(request.body?.cols),
        rows: asInteger(request.body?.rows),
        replaceExisting: request.body?.replaceExisting === true,
      });
      response.status(201).json(terminal);
    }),
  );

  app.post(
    "/api/terminals/:terminalId/resize",
    asyncRoute(async (request, response) => {
      if (
        !requireHostCapability(
          response,
          hostCapabilities.workspace.terminal,
          "integrated terminal",
        )
      ) {
        return;
      }
      const terminalId = pathParam(request.params.terminalId);
      response.json(
        terminalRegistry.resize(
          terminalId,
          asInteger(request.body?.cols),
          asInteger(request.body?.rows),
        ),
      );
    }),
  );

  app.post(
    "/api/terminals/:terminalId/kill",
    asyncRoute(async (request, response) => {
      if (
        !requireHostCapability(
          response,
          hostCapabilities.workspace.terminal,
          "integrated terminal",
        )
      ) {
        return;
      }
      response.json(terminalRegistry.kill(pathParam(request.params.terminalId)));
    }),
  );

  app.get("/api/ports", (_request, response) => {
    if (
      !requireHostCapability(
        response,
        hostCapabilities.workspace.portForwarding,
        "port forwarding",
      )
    ) {
      return;
    }
    response.json({ ports: portForwardRegistry.list() });
  });

  app.post(
    "/api/ports",
    asyncRoute(async (request, response) => {
      if (
        !requireHostCapability(
          response,
          hostCapabilities.workspace.portForwarding,
          "port forwarding",
        )
      ) {
        return;
      }
      const portForward = portForwardRegistry.create({
        targetPort: asInteger(request.body?.targetPort),
        targetHost: asString(request.body?.targetHost),
        scheme: asString(request.body?.scheme),
        label: asString(request.body?.label),
        cwd: asString(request.body?.cwd),
        sessionId: asString(request.body?.sessionId),
      });
      response.status(201).json(portForward);
    }),
  );

  app.delete(
    "/api/ports/:portForwardId",
    asyncRoute(async (request, response) => {
      if (
        !requireHostCapability(
          response,
          hostCapabilities.workspace.portForwarding,
          "port forwarding",
        )
      ) {
        return;
      }
      response.json(
        portForwardRegistry.stop(pathParam(request.params.portForwardId)),
      );
    }),
  );

  app.get("/api/browser-previews", (_request, response) => {
    if (
      !requireHostCapability(
        response,
        hostCapabilities.workspace.browserPreview,
        "browser preview",
      )
    ) {
      return;
    }
    response.json({ previews: browserPreviewRegistry.list() });
  });

  app.post(
    "/api/browser-previews",
    asyncRoute(async (request, response) => {
      if (
        !requireHostCapability(
          response,
          hostCapabilities.workspace.browserPreview,
          "browser preview",
        )
      ) {
        return;
      }
      const preview = await browserPreviewRegistry.create({
        targetPort: asInteger(request.body?.targetPort),
        targetHost: asString(request.body?.targetHost),
        scheme: asString(request.body?.scheme),
        label: asString(request.body?.label),
        cwd: asString(request.body?.cwd),
        sessionId: asString(request.body?.sessionId),
        width: asInteger(request.body?.width),
        height: asInteger(request.body?.height),
        profileMode: asString(request.body?.profileMode),
      });
      response.status(201).json(preview);
    }),
  );

  app.delete(
    "/api/browser-previews/:previewId",
    asyncRoute(async (request, response) => {
      if (
        !requireHostCapability(
          response,
          hostCapabilities.workspace.browserPreview,
          "browser preview",
        )
      ) {
        return;
      }
      response.json(
        await browserPreviewRegistry.stop(pathParam(request.params.previewId)),
      );
    }),
  );

  app.get(
    "/api/actions",
    asyncRoute(async (_request, response) => {
      response.json(await listPendingActions(provider, pendingActions));
    }),
  );

  app.get(
    "/api/sessions/:sessionId/log",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session history",
          "readSessionThread",
        ) ||
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session log",
          "readSessionLog",
        )
      ) {
        return;
      }
      const query = request.query as Record<string, unknown>;
      const messageLimit = asInteger(query.messageLimit);
      const activityLimit = asInteger(query.activityLimit);
      const cacheKey = buildSessionLogCacheKey(
        sessionId,
        messageLimit,
        activityLimit,
      );
      const cached = logCache.get(cacheKey);

      if (cached) {
        const session = await readSession(provider, sessionId, false);
        if (cached.threadUpdatedAt === session.updatedAt) {
          ensureSeqCursor(sessionId, cached.nextSeq);
          runtimeCache.set(session.id, {
            threadUpdatedAt: session.updatedAt,
            runtime: cached.runtime,
          });
          response.json({
            session: mapSession(session, cached.runtime),
            messages: cached.messages,
            activities: mergeSessionActivities(
              cached.activities,
              liveActivities.get(sessionId)?.values() || [],
            ),
            pendingAction: findPendingActionForSession(
              pendingActions,
              sessionId,
            ),
            history: cached.history,
          });
          return;
        }
      }

      const session = await readSession(provider, sessionId, false);
      const log = await provider.readSessionLog!(session, {
        messageLimit,
        activityLimit,
      });
      ensureSeqCursor(sessionId, log.nextSeq);
      const activities = mergeSessionActivities(
        log.activities,
        liveActivities.get(sessionId)?.values() || [],
      );
      const history = buildSessionHistorySummary(
        log.totalMessages,
        log.messages.length,
        log.totalActivities,
        log.activities.length,
      );

      setSessionLogCacheEntry(logCache, cacheKey, {
        threadUpdatedAt: session.updatedAt,
        messages: log.messages,
        activities: log.activities,
        runtime: log.runtime,
        history,
        nextSeq: log.nextSeq,
      });
      runtimeCache.set(session.id, {
        threadUpdatedAt: session.updatedAt,
        runtime: log.runtime,
      });
      response.json({
        session: mapSession(session, log.runtime),
        messages: log.messages,
        activities,
        pendingAction: findPendingActionForSession(pendingActions, sessionId),
        history,
      });
    }),
  );

  // Replay endpoint for cheap reconnect / resume. Clients pass `since`
  // (the highest seq they've already observed) and get only newer
  // messages + activities — no re-downloading the full transcript.
  app.get(
    "/api/sessions/:sessionId/events",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.eventReplay,
          "session event replay",
          "readSessionThread",
        ) ||
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.eventReplay,
          "session event replay",
          "readSessionLog",
        )
      ) {
        return;
      }
      const query = request.query as Record<string, unknown>;
      const since = asInteger(query.since) ?? 0;

      const session = await readSession(provider, sessionId, false);

      let newMessages: SessionMessage[];
      let newActivities: SessionActivity[];
      let nextSeq: number;
      let logRuntime: SessionRuntimeSummary | null;

      if (session.path && session.path.endsWith(".jsonl")) {
        try {
          const entry = await replayIndex.load(sessionId, session.path);
          ensureSeqCursor(sessionId, entry.nextSeq);
          const delta = replayIndex.getDelta(entry, since);
          newMessages = delta.messages;
          newActivities = mergeSessionActivities(
            delta.activities,
            liveActivities.get(sessionId)?.values() || [],
          ).filter((a) => (a.seq ?? 0) > since);
          nextSeq = delta.nextSeq;
          logRuntime = delta.runtime;
        } catch (error: any) {
          if (error.code === "STALE_CURSOR") {
            response.status(410).json({
              error: "stale_cursor",
              since: error.staleSince,
              oldestAvailableSeq: error.oldestAvailableSeq,
            });
            return;
          }
          // Fallback to provider readSessionLog on any other error
          const log = await provider.readSessionLog!(session);
          ensureSeqCursor(sessionId, log.nextSeq);
          const activities = mergeSessionActivities(
            log.activities,
            liveActivities.get(sessionId)?.values() || [],
          );
          newMessages = log.messages.filter((m) => (m.seq ?? 0) > since);
          newActivities = activities.filter((a) => (a.seq ?? 0) > since);
          let highestSeq = since;
          for (const m of newMessages) {
            if ((m.seq ?? 0) > highestSeq) highestSeq = m.seq ?? highestSeq;
          }
          for (const a of newActivities) {
            if ((a.seq ?? 0) > highestSeq) highestSeq = a.seq ?? highestSeq;
          }
          nextSeq = highestSeq;
          logRuntime = log.runtime;
        }
      } else {
        const log = await provider.readSessionLog!(session);
        ensureSeqCursor(sessionId, log.nextSeq);
        const activities = mergeSessionActivities(
          log.activities,
          liveActivities.get(sessionId)?.values() || [],
        );
        newMessages = log.messages.filter((m) => (m.seq ?? 0) > since);
        newActivities = activities.filter((a) => (a.seq ?? 0) > since);
        let highestSeq = since;
        for (const m of newMessages) {
          if ((m.seq ?? 0) > highestSeq) highestSeq = m.seq ?? highestSeq;
        }
        for (const a of newActivities) {
          if ((a.seq ?? 0) > highestSeq) highestSeq = a.seq ?? highestSeq;
        }
        nextSeq = highestSeq;
        logRuntime = log.runtime;
      }

      response.json({
        sessionId,
        since,
        nextSeq,
        messages: newMessages,
        activities: newActivities,
        pendingAction: findPendingActionForSession(pendingActions, sessionId),
        session: mapSession(session, logRuntime),
      });
    }),
  );

  app.get(
    "/api/sessions/:sessionId/resources",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session resources",
          "readSessionThread",
        ) ||
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session resources",
          "readSessionLog",
        )
      ) {
        return;
      }
      response.json(
        await readSessionResources(provider, sessionId, liveActivities),
      );
    }),
  );

  app.get(
    "/api/sessions/:sessionId/status",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session status",
          "readSessionThread",
        )
      ) {
        return;
      }
      const state = await loadFastRunState(provider, sessionId, activeTurns);
      response.json({
        sessionId,
        isRunning: state.isRunning,
        activeTurnId: state.turnId,
        pendingAction: findPendingActionForSession(pendingActions, sessionId),
      });
    }),
  );

  app.get(
    "/api/sessions/:sessionId/git",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session history",
          "readSessionThread",
        ) ||
        !requireHostCapability(
          response,
          HOST_CAPABILITIES.workspace.gitStatus,
          "git status",
        )
      ) {
        return;
      }
      const session = await readSession(provider, sessionId, false);
      response.json(
        await readGitStatus(session.cwd, mapGitInfo(session.gitInfo)),
      );
    }),
  );

  app.get(
    "/api/sessions/:sessionId/git/diff",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      const kind = parseGitDiffKind(
        (request.query as Record<string, unknown>).kind,
      );
      if (!kind) {
        response
          .status(400)
          .json({ error: "kind must be working, staged, unstaged, or remote" });
        return;
      }

      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session history",
          "readSessionThread",
        )
      ) {
        return;
      }
      const session = await readSession(provider, sessionId, false);
      if (kind === "remote") {
        const sessionProvider =
          providerEntryForKind(providerKindForThread(session)) ??
          providerEntryForKind(null);
        if (!sessionProvider) {
          response.status(500).json({ error: "provider routing failed" });
          return;
        }
        if (
          !requireProviderCapability(
            response,
            sessionProvider.provider,
            sessionProvider.provider.capabilities.workspace.remoteGitDiff,
            "remote git diff",
            "readRemoteGitDiff",
          )
        ) {
          return;
        }
        const result = await sessionProvider.provider.readRemoteGitDiff!(
          session.cwd,
        );
        response.json(
          buildGitDiff("remote", result.diff, normalizeGitSha(result.sha)),
        );
        return;
      }

      if (
        !requireHostCapability(
          response,
          HOST_CAPABILITIES.workspace.gitDiff,
          "git diff",
        )
      ) {
        return;
      }
      response.json(await readGitDiff(session.cwd, kind));
    }),
  );

  app.get(
    "/api/skills",
    asyncRoute(async (request, response) => {
      const query = request.query as Record<string, unknown>;
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = providerEntryForKind(agentProvider);
      if (!selectedProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          selectedProvider.provider,
          selectedProvider.provider.capabilities.configuration.skills,
          "skill listing",
          "listSkills",
        )
      ) {
        return;
      }
      const cwd = asString(query.cwd);
      if (!cwd) {
        response.status(400).json({ error: "cwd is required" });
        return;
      }

      const forceReload = parseQueryBool(query.forceReload);
      response.json(
        await selectedProvider.provider.listSkills!({ cwd, forceReload }),
      );
    }),
  );

  app.post(
    "/api/skills/config/write",
    asyncRoute(async (request, response) => {
      const requestedProvider = asString(request.body?.agentProvider) || null;
      const selectedProvider = providerEntryForKind(requestedProvider);
      if (!selectedProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          selectedProvider.provider,
          selectedProvider.provider.capabilities.configuration.skillManagement,
          "skill configuration",
          "writeSkillConfig",
        )
      ) {
        return;
      }
      const path = asString(request.body?.path);
      const name = asString(request.body?.name);
      const enabled = parseOptionalBool(request.body?.enabled);
      if (enabled === null) {
        response.status(400).json({ error: "enabled is required" });
        return;
      }
      if ((path && name) || (!path && !name)) {
        response
          .status(400)
          .json({ error: "provide exactly one of path or name" });
        return;
      }

      const result = await selectedProvider.provider.writeSkillConfig!({
        path,
        name,
        enabled,
      });
      response.json(result);
    }),
  );

  app.get(
    "/api/models",
    asyncRoute(async (request, response) => {
      const query = request.query as Record<string, unknown>;
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = providerEntryForKind(agentProvider);
      if (!selectedProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          selectedProvider.provider,
          selectedProvider.provider.capabilities.configuration.models,
          "model listing",
          "listModels",
        )
      ) {
        return;
      }
      const cwd = asString(query.cwd) || null;
      const profile = asString(query.profile) || null;
      const modelProvider = asString(query.provider) || null;
      response.json(
        await selectedProvider.provider.listModels!({
          cwd,
          profile,
          provider: modelProvider,
        }),
      );
    }),
  );

  app.get(
    "/api/profiles",
    asyncRoute(async (request, response) => {
      const query = request.query as Record<string, unknown>;
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = providerEntryForKind(agentProvider);
      if (!selectedProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          selectedProvider.provider,
          selectedProvider.provider.capabilities.configuration.profiles,
          "profile listing",
          "listProfiles",
        )
      ) {
        return;
      }
      const cwd = asString(query.cwd) || null;
      response.json(await selectedProvider.provider.listProfiles!({ cwd }));
    }),
  );

  app.post(
    "/api/sessions/create",
    asyncRoute(async (request, response) => {
      const requestedProvider = asString(request.body?.provider) || null;
      const selectedProvider = providerEntryForKind(requestedProvider);
      if (!selectedProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          selectedProvider.provider,
          selectedProvider.provider.capabilities.sessions.create,
          "session creation",
          "createSession",
        )
      ) {
        return;
      }
      const cwd = asString(request.body?.cwd);
      const prompt = asString(request.body?.prompt);
      const input = parseInputItems(request.body?.input);
      const overrides = parseCreateSessionOverrides(request.body);
      if (!cwd) {
        response.status(400).json({ error: "cwd is required" });
        return;
      }
      const unsupportedOverride = unsupportedOverrideCapability(
        selectedProvider.provider,
        overrides,
      );
      if (unsupportedOverride) {
        response.status(501).json({ error: unsupportedOverride });
        return;
      }

      const resolvedInput =
        input.length > 0 ? input : buildLegacyTextInput(prompt);
      const unsupportedInput = unsupportedInputCapability(
        selectedProvider.provider,
        resolvedInput,
      );
      if (unsupportedInput) {
        response.status(501).json({ error: unsupportedInput });
        return;
      }
      const started = await provider.createSession!({
        cwd,
        input: resolvedInput,
        overrides,
        provider: selectedProvider.kind,
      });
      if (started.activeTurnId) {
        activeTurns.set(started.thread.id, {
          turnId: started.activeTurnId,
          startedAt: Date.now(),
        });
      }

      const session = mapSession(started.thread, started.runtime);
      response.status(201).json({
        session,
        activeTurnId: started.activeTurnId,
      });
      broadcastRecentSessionsLive({ type: "upsert", session });
    }),
  );

  app.post(
    "/api/sessions/:sessionId/input",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          true,
          "session input submission",
          "submitInput",
        )
      ) {
        return;
      }
      const text = asString(request.body?.text);
      const input = parseInputItems(request.body?.input);
      const clientMessageId = asString(request.body?.clientMessageId);
      if (clientMessageId && !isValidClientMessageId(clientMessageId)) {
        response.status(400).json({
          error: "clientMessageId must be 1-128 URL-safe characters",
        });
        return;
      }
      const resolvedInput =
        input.length > 0 ? input : buildLegacyTextInput(text);
      if (resolvedInput.length === 0) {
        response.status(400).json({ error: "input is required" });
        return;
      }
      const unsupportedInput = unsupportedInputCapability(
        sessionProvider.provider,
        resolvedInput,
      );
      if (unsupportedInput) {
        response.status(501).json({ error: unsupportedInput });
        return;
      }

      const turnOverrides = parseTurnOverrides(request.body);
      const unsupportedOverride = unsupportedOverrideCapability(
        sessionProvider.provider,
        turnOverrides,
      );
      if (unsupportedOverride) {
        response.status(501).json({ error: unsupportedOverride });
        return;
      }
      const inputSignatureHash = hashSessionInputSignature(
        resolvedInput,
        turnOverrides,
      );
      const dedupeKey = clientMessageId
        ? sessionInputDedupeKey(sessionId, clientMessageId)
        : null;
      if (dedupeKey) {
        pruneSessionInputDedupe();
        const existing = sessionInputDedupe.get(dedupeKey);
        if (existing) {
          if (existing.signatureHash !== inputSignatureHash) {
            response.status(409).json({
              error: "clientMessageId was already used with different input",
            });
            return;
          }
          const receipt = existing.receipt ?? (await existing.promise);
          if (receipt) {
            response.json({ ...receipt, replayed: true });
            return;
          }
        }
      }

      const submit = async (): Promise<SessionInputReceipt> => {
        const submittedMessage = buildSubmittedUserMessage(
          resolvedInput,
          clientMessageId,
          allocSeq(sessionId),
        );
        const state = await loadRunState(provider, sessionId, activeTurns);
        const submitted = await provider.submitInput!({
          sessionId,
          input: resolvedInput,
          activeTurnId: state.turnId,
          overrides: turnOverrides,
        });
        if (submitted.turnId) {
          const previousStartedAt = state.turnId
            ? activeTurns.get(sessionId)?.startedAt
            : undefined;
          activeTurns.set(sessionId, {
            turnId: submitted.turnId,
            startedAt: previousStartedAt ?? Date.now(),
          });
        }
        broadcastLive(sessionId, {
          type: "user_message_submitted",
          sessionId,
          turnId: submitted.turnId || undefined,
          messageItem: submittedMessage,
        });
        return {
          mode: submitted.mode,
          turnId: submitted.turnId,
          messageId: submittedMessage.id,
        };
      };

      const promise = submit();
      if (dedupeKey) {
        sessionInputDedupe.set(dedupeKey, {
          signatureHash: inputSignatureHash,
          createdAt: Date.now(),
          promise,
        });
        pruneSessionInputDedupe();
      }

      try {
        const receipt = await promise;
        if (dedupeKey) {
          const createdAt =
            sessionInputDedupe.get(dedupeKey)?.createdAt ?? Date.now();
          sessionInputDedupe.set(dedupeKey, {
            signatureHash: inputSignatureHash,
            createdAt,
            receipt,
          });
          await persistSessionInputDedupeReceipt(
            sessionInputDedupeStore,
            dedupeKey,
            inputSignatureHash,
            createdAt,
            receipt,
          );
          pruneSessionInputDedupe();
        }
        response.json({ ...receipt, replayed: false });
        scheduleRecentSessionUpsert(sessionId, 0);
      } catch (error) {
        if (dedupeKey) {
          const current = sessionInputDedupe.get(dedupeKey);
          if (current?.promise === promise) {
            sessionInputDedupe.delete(dedupeKey);
          }
        }
        throw error;
      }
    }),
  );

  app.post(
    "/api/sessions/:sessionId/stop",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.interrupt,
          "session interruption",
          "interruptTurn",
        )
      ) {
        return;
      }
      const state = await loadRunState(provider, sessionId, activeTurns);
      if (!state.turnId) {
        response.json({ stopped: false });
        return;
      }
      await provider.interruptTurn!(sessionId, state.turnId);
      activeTurns.delete(sessionId);
      response.json({ stopped: true, turnId: state.turnId });
    }),
  );

  app.post(
    "/api/sessions/:sessionId/compact",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.compact,
          "session compaction",
          "compactSession",
        )
      ) {
        return;
      }
      const state = await loadRunState(provider, sessionId, activeTurns);
      if (state.turnId) {
        response.status(409).json({
          error: "Cannot compact while a turn is running",
          turnId: state.turnId,
        });
        return;
      }
      const result = await provider.compactSession!(sessionId);
      clearSessionLogCache(logCache, sessionId);
      response.json({ compacted: true, result: result ?? null });
      void broadcastRecentSessionUpsert(sessionId);
    }),
  );

  app.post(
    "/api/sessions/:sessionId/name",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.rename,
          "session renaming",
          "setSessionName",
        ) ||
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.history,
          "session history",
          "readSessionThread",
        )
      ) {
        return;
      }
      const name = asString(request.body?.name);
      if (!name) {
        response.status(400).json({ error: "name is required" });
        return;
      }
      if (
        hasProviderMethod(provider, "listLoadedSessionIds") &&
        !(await isThreadLoaded(provider, sessionId))
      ) {
        if (
          !requireProviderCapability(
            response,
            sessionProvider.provider,
            sessionProvider.provider.capabilities.sessions.resume,
            "session resume",
            "resumeSessionThread",
          )
        ) {
          return;
        }
        await provider.resumeSessionThread!(sessionId, {
          persistExtendedHistory: true,
        });
      }
      await provider.setSessionName!(sessionId, name);
      const thread = await readSession(provider, sessionId, false);
      const session = mapSession(thread);
      response.json({ session });
      broadcastRecentSessionsLive({ type: "upsert", session });
    }),
  );

  app.post(
    "/api/sessions/:sessionId/archive",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.archive,
          "session archiving",
          "archiveSession",
        )
      ) {
        return;
      }
      await provider.archiveSession!(sessionId);
      activeTurns.delete(sessionId);
      liveActivities.delete(sessionId);
      clearSessionLogCache(logCache, sessionId);
      sessionSeqCursor.delete(sessionId);
      response.json({ archived: true });
      broadcastRecentSessionRemove(sessionId);
    }),
  );

  app.post(
    "/api/sessions/:sessionId/unarchive",
    asyncRoute(async (request, response) => {
      const sessionId = pathParam(request.params.sessionId);
      const sessionProvider = providerEntryForSessionId(sessionId);
      if (!sessionProvider) {
        response.status(400).json({ error: "unknown provider" });
        return;
      }
      if (
        !requireProviderCapability(
          response,
          sessionProvider.provider,
          sessionProvider.provider.capabilities.sessions.archive,
          "session unarchiving",
          "unarchiveSession",
        )
      ) {
        return;
      }
      await provider.unarchiveSession!(sessionId);
      response.json({ unarchived: true });
      void broadcastRecentSessionUpsert(sessionId);
    }),
  );

  app.post(
    "/api/actions/:actionId/respond",
    asyncRoute(async (request, response) => {
      const actionId = pathParam(request.params.actionId);
      const action = pendingActions.get(actionId);
      if (!action) {
        response.status(404).json({ error: "action not found" });
        return;
      }
      const decision = parsePendingActionResponseBody(request.body, action);
      if (!decision) {
        response.status(400).json({ error: "invalid action response" });
        return;
      }

      if (
        !requireProviderCapability(
          response,
          provider,
          true,
          "pending action responses",
          "respondToPendingAction",
        )
      ) {
        return;
      }
      const handled = provider.respondToPendingAction!(action, decision);
      if (!handled) {
        response.status(400).json({ error: "unsupported decision" });
        return;
      }

      pendingActions.delete(actionId);
      broadcastLive(action.sessionId, {
        type: "action_resolved",
        sessionId: action.sessionId,
        actionId,
      });
      broadcastApprovalLive({
        type: "action_resolved",
        actionId,
      });
      scheduleRecentSessionUpsert(action.sessionId);
      response.json({ ok: true });
    }),
  );

  const wsServer = new WebSocketServer({ noServer: true });
  server.on("upgrade", (request, socket, head) => {
    const [pathOnly, queryString] = (request.url || "").split("?");
    const terminalLiveMatch = /^\/api\/terminals\/([^/]+)\/live$/.exec(
      pathOnly,
    );
    const portForwardMatch = /^\/api\/ports\/([^/]+)\/connect$/.exec(pathOnly);
    const browserPreviewMatch =
      /^\/api\/browser-previews\/([^/]+)\/live$/.exec(pathOnly);
    if (
      pathOnly !== "/api/live" &&
      pathOnly !== "/api/sessions/live" &&
      pathOnly !== "/api/fs/live" &&
      pathOnly !== "/api/actions/live" &&
      !terminalLiveMatch &&
      !portForwardMatch &&
      !browserPreviewMatch
    ) {
      socket.destroy();
      return;
    }

    const authHeader = request.headers.authorization;
    const token = authHeader?.startsWith("Bearer ")
      ? authHeader.slice("Bearer ".length)
      : "";
    if (token !== config.token) {
      socket.destroy();
      return;
    }

    if (terminalLiveMatch) {
      const terminalId = decodeURIComponent(terminalLiveMatch[1] || "");
      const params = new URLSearchParams(queryString || "");
      const since = asInteger(params.get("since")) ?? -1;
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        terminalRegistry.attach(ws, terminalId, since);
      });
      return;
    }

    if (portForwardMatch) {
      const portForwardId = decodeURIComponent(portForwardMatch[1] || "");
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        portForwardRegistry.attach(ws, portForwardId);
      });
      return;
    }

    if (browserPreviewMatch) {
      const previewId = decodeURIComponent(browserPreviewMatch[1] || "");
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        browserPreviewRegistry.attach(ws, previewId);
      });
      return;
    }

    if (pathOnly === "/api/fs/live") {
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        try {
          ws.send(JSON.stringify({ type: "hello" }));
        } catch {
          /* noop */
        }
        attachFsLiveSocket(ws, fsWatchRegistry, {
          listSessions: () => listSessions(provider, runtimeCache, null, "none"),
        });
      });
      return;
    }

    if (pathOnly === "/api/actions/live") {
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        approvalSockets.add(ws);
        sendEvent(ws, { type: "hello" });
        void listPendingActions(provider, pendingActions)
          .then((actions) => {
            sendEvent(ws, { type: "snapshot", actions });
          })
          .catch((error: unknown) => {
            sendEvent(ws, {
              type: "error",
              message:
                error instanceof Error
                  ? error.message
                  : "Failed to load pending actions",
            });
          });
        ws.on("close", () => {
          approvalSockets.delete(ws);
        });
      });
      return;
    }

    if (pathOnly === "/api/sessions/live") {
      if (!provider.capabilities.sessions.history) {
        socket.destroy();
        return;
      }
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        recentSessionsSockets.add(ws);
        sendEvent(ws, { type: "hello" });
        void sendRecentSessionsSnapshot(ws).catch((error: unknown) => {
          sendEvent(ws, {
            type: "error",
            message:
              error instanceof Error
                ? error.message
                : "Failed to load recent sessions",
          });
        });
        ws.on("close", () => {
          recentSessionsSockets.delete(ws);
        });
      });
      return;
    }

    const params = new URLSearchParams(queryString || "");
    const sessionId = params.get("sessionId");
    if (!sessionId) {
      socket.destroy();
      return;
    }

    wsServer.handleUpgrade(request, socket, head, (ws) => {
      const set = socketsBySession.get(sessionId) || new Set<WebSocket>();
      set.add(ws);
      socketsBySession.set(sessionId, set);
      sendEvent(ws, {
        type: "hello",
        sessionId,
        nextSeq: sessionSeqCursor.get(sessionId) ?? 0,
      });
      ws.on("close", () => {
        const current = socketsBySession.get(sessionId);
        if (!current) {
          return;
        }
        current.delete(ws);
        if (current.size === 0) {
          socketsBySession.delete(sessionId);
        }
      });
    });
  });

  app.use(
    (
      error: unknown,
      _request: Request,
      response: Response,
      _next: NextFunction,
    ) => {
      const message =
        error instanceof Error ? error.message : "Internal server error";
      const status =
        error instanceof TerminalError ||
        error instanceof WorkspaceAccessError ||
        error instanceof PortForwardError ||
        error instanceof BrowserPreviewError
          ? error.status
          : 500;
      response.status(status).json({ error: message });
    },
  );

  await listen(server, config.port);
  for (const line of startupSummaryLines({
    config,
    providerDisplayName: provider.displayName,
    providerKinds: providerRuntime.providers.map((entry) => entry.kind),
  })) {
    console.log(line);
  }

  return {
    close: async () => {
      terminalRegistry.dispose();
      portForwardRegistry.dispose();
      await browserPreviewRegistry.dispose();
      for (const socket of approvalSockets) socket.close();
      for (const socket of recentSessionsSockets) socket.close();
      for (const sockets of socketsBySession.values()) {
        for (const socket of sockets) socket.close();
      }
      await closeWebSocketServer(wsServer);
      await closeHttpServer(server);
    },
  };
}

async function listen(server: Server, port: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const onError = (error: NodeJS.ErrnoException) => {
      server.off("listening", onListening);
      if (error.code === "EADDRINUSE") {
        reject(
          new Error(
            `Port ${port} is already in use. Run \`sidemesh status\` to inspect the active daemon or choose another SIDEMESH_PORT.`,
          ),
        );
        return;
      }
      reject(error);
    };
    const onListening = () => {
      server.off("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port);
  });
}

async function closeHttpServer(server: Server): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

async function closeWebSocketServer(server: WebSocketServer): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

function asyncRoute(
  handler: (
    request: Request,
    response: Response,
    next: NextFunction,
  ) => Promise<void>,
): (request: Request, response: Response, next: NextFunction) => void {
  return (request, response, next) => {
    void handler(request, response, next).catch(next);
  };
}

function pathParam(value: string | string[] | undefined): string {
  if (Array.isArray(value)) {
    return value[0] || "";
  }
  return value || "";
}

function authenticate(
  request: Request,
  response: Response,
  next: NextFunction,
  token: string,
): void {
  const auth = request.headers.authorization;
  if (
    !auth ||
    !auth.startsWith("Bearer ") ||
    auth.slice("Bearer ".length) !== token
  ) {
    response.status(401).json({ error: "unauthorized" });
    return;
  }
  next();
}

function requireProviderCapability(
  response: Response,
  provider: AgentProvider,
  supported: boolean,
  feature: string,
  method?: AgentProviderMethodName,
): boolean {
  if (!supported) {
    response.status(501).json({
      error: `${provider.displayName} does not support ${feature}`,
    });
    return false;
  }
  if (method && !hasProviderMethod(provider, method)) {
    response.status(501).json({
      error: `${provider.displayName} does not implement ${feature}`,
    });
    return false;
  }
  return true;
}

function requireHostCapability(
  response: Response,
  supported: boolean,
  feature: string,
): boolean {
  if (!supported) {
    response.status(501).json({
      error: `Sidemesh host does not support ${feature}`,
    });
    return false;
  }
  return true;
}

function unsupportedInputCapability(
  provider: AgentProvider,
  input: AgentSessionInputItem[],
): string | null {
  for (const item of input) {
    switch (item.type) {
      case "text":
        if (!provider.capabilities.input.text) {
          return `${provider.displayName} does not support text input`;
        }
        break;
      case "image":
        if (!provider.capabilities.input.imageUrl) {
          return `${provider.displayName} does not support image URL input`;
        }
        break;
      case "localImage":
        if (!provider.capabilities.input.localImage) {
          return `${provider.displayName} does not support local image input`;
        }
        break;
      case "skill":
        if (!provider.capabilities.input.skills) {
          return `${provider.displayName} does not support skill input`;
        }
        break;
    }
  }
  return null;
}

function unsupportedOverrideCapability(
  provider: AgentProvider,
  overrides: AgentSessionOverrides,
): string | null {
  if (overrides.model && !provider.capabilities.runtimeControls.model) {
    return `${provider.displayName} does not support model overrides`;
  }
  if (overrides.mode && !provider.capabilities.runtimeControls.mode) {
    return `${provider.displayName} does not support mode overrides`;
  }
  if (
    overrides.reasoningEffort &&
    !provider.capabilities.runtimeControls.reasoningEffort
  ) {
    return `${provider.displayName} does not support reasoning effort overrides`;
  }
  if (
    overrides.fastMode !== null &&
    !provider.capabilities.runtimeControls.fastMode
  ) {
    return `${provider.displayName} does not support fast mode`;
  }
  if (
    overrides.approvalPolicy &&
    !provider.capabilities.runtimeControls.approvalPolicy
  ) {
    return `${provider.displayName} does not support approval policy overrides`;
  }
  if (
    overrides.sandboxMode &&
    !provider.capabilities.runtimeControls.sandboxMode
  ) {
    return `${provider.displayName} does not support sandbox overrides`;
  }
  if (
    overrides.networkAccess !== null &&
    !provider.capabilities.runtimeControls.networkAccess
  ) {
    return `${provider.displayName} does not support network access overrides`;
  }
  if (overrides.webSearch && !provider.capabilities.runtimeControls.webSearch) {
    return `${provider.displayName} does not support web search overrides`;
  }
  if (overrides.profile && !provider.capabilities.configuration.profiles) {
    return `${provider.displayName} does not support profile overrides`;
  }
  return null;
}

async function resolveTerminalCwd(
  provider: AgentProvider,
  runtimeCache: Map<string, SessionRuntimeCacheEntry>,
  cwd: string,
  sessionId: string | null | undefined,
): Promise<string> {
  if (sessionId?.trim() && hasProviderMethod(provider, "readSessionThread")) {
    try {
      const thread = await provider.readSessionThread(sessionId.trim(), false);
      if (thread.cwd) {
        return resolveWorkspacePath(cwd, [thread.cwd]);
      }
    } catch {
      // Fallback keeps terminal startup usable if a provider cannot rehydrate a
      // session thread but the cwd is still under a known workspace root.
    }
  }
  return resolveWorkspacePath(
    cwd,
    await collectWorkspaceRoots(() =>
      listSessions(provider, runtimeCache, null, "none"),
    ),
  );
}

async function listSessions(
  provider: AgentProvider,
  runtimeCache: Map<string, SessionRuntimeCacheEntry>,
  limitOverride: number | null = null,
  runtimeMode: SessionRuntimeListMode = "active",
): Promise<SessionSummary[]> {
  const limit = normalizedSessionListLimit(limitOverride);
  const listThreads = requireProviderMethod(
    provider,
    "listSessionThreads",
    "session history",
  );
  const threads = await listThreads.call(provider, {
    limit,
    archived: false,
  });
  const mergedThreads = await mergeRecentUnindexedThreads(
    provider,
    threads,
    limit,
  );
  return mapWithConcurrency(
    mergedThreads,
    RECENT_SESSION_RUNTIME_CONCURRENCY,
    async (thread) =>
      mapSession(
        thread,
        await loadCachedSessionRuntime(
          provider,
          thread,
          runtimeCache,
          runtimeMode,
        ),
      ),
  );
}

function parseSessionRuntimeListMode(
  value: unknown,
): SessionRuntimeListMode {
  switch (asString(value)) {
    case "all":
      return "all";
    case "none":
      return "none";
    case "active":
    default:
      return "active";
  }
}

function normalizedSessionListLimit(limitOverride: number | null): number {
  return Math.max(1, Math.min(limitOverride ?? 100, 100));
}

export async function mergeRecentUnindexedThreads(
  provider: AgentProvider,
  indexedThreads: ThreadRecord[],
  limit: number,
): Promise<ThreadRecord[]> {
  if (
    !provider.capabilities.sessions.recentFallback ||
    !hasProviderMethod(provider, "listRecentUnindexedSessionThreads")
  ) {
    return indexedThreads;
  }
  const threadsById = new Map(
    indexedThreads.map((thread) => [thread.id, thread]),
  );
  const recentThreads = await provider.listRecentUnindexedSessionThreads(
    Math.max(limit, RECENT_UNINDEXED_SESSION_SCAN_LIMIT),
  );

  for (const thread of recentThreads) {
    if (threadsById.has(thread.id)) {
      continue;
    }
    threadsById.set(thread.id, thread);
  }

  return [...threadsById.values()]
    .sort((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, limit);
}

function buildWorkspaces(sessions: SessionSummary[]): WorkspaceSummary[] {
  const grouped = new Map<string, WorkspaceSummary>();
  for (const session of sessions) {
    const label = session.cwd.split("/").filter(Boolean).pop() || session.cwd;
    const existing = grouped.get(session.cwd);
    if (!existing) {
      grouped.set(session.cwd, {
        cwd: session.cwd,
        label,
        sessionCount: 1,
        lastUsedAt: session.updatedAt,
      });
      continue;
    }
    existing.sessionCount += 1;
    existing.lastUsedAt = Math.max(existing.lastUsedAt, session.updatedAt);
  }
  return [...grouped.values()].sort(
    (left, right) => right.lastUsedAt - left.lastUsedAt,
  );
}

async function listPendingActions(
  provider: AgentProvider,
  pendingActions: Map<string, AgentPendingAction>,
): Promise<PendingAction[]> {
  const actions = [...pendingActions.values()].sort(
    (left, right) => right.requestedAt - left.requestedAt,
  );
  const sessionsById = new Map<string, Promise<ThreadRecord | null>>();

  return Promise.all(
    actions.map(async (action) => {
      if (!action.sessionId || action.sessionId === "unknown") {
        return toPublicPendingAction(action);
      }

      let sessionPromise = sessionsById.get(action.sessionId);
      if (!sessionPromise) {
        sessionPromise = readSession(provider, action.sessionId, false).catch(
          () => null,
        );
        sessionsById.set(action.sessionId, sessionPromise);
      }

      const session = await sessionPromise;
      if (!session) {
        return toPublicPendingAction(action);
      }

      const mapped = mapSession(session);
      return toPublicPendingAction({
        ...action,
        sessionTitle: mapped.title,
        cwd: mapped.cwd,
      });
    }),
  );
}

async function readSession(
  provider: AgentProvider,
  sessionId: string,
  includeTurns: boolean,
): Promise<ThreadRecord> {
  const readThread = requireProviderMethod(
    provider,
    "readSessionThread",
    "session history",
  );
  return readThread.call(provider, sessionId, includeTurns);
}

async function loadRunState(
  provider: AgentProvider,
  sessionId: string,
  activeTurns: Map<string, ActiveTurnState>,
): Promise<{ turnId: string | null }> {
  const known = activeTurns.get(sessionId);
  if (known) {
    return { turnId: known.turnId };
  }

  let session: ThreadRecord;
  try {
    if (!hasProviderMethod(provider, "readSessionThread")) {
      return { turnId: null };
    }
    session = await readSession(provider, sessionId, true);
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (
      message.includes("includeTurns is unavailable before first user message")
    ) {
      return { turnId: null };
    }
    throw error;
  }
  const turns = Array.isArray(session.turns) ? session.turns : [];
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turn = turns[index] as TurnRecord;
    if (turn.status === "inProgress") {
      activeTurns.set(sessionId, {
        turnId: turn.id,
        startedAt: Date.now(),
      });
      return { turnId: turn.id };
    }
  }

  return { turnId: null };
}

async function loadFastRunState(
  provider: AgentProvider,
  sessionId: string,
  activeTurns: Map<string, ActiveTurnState>,
): Promise<{ isRunning: boolean; turnId: string | null }> {
  const known = activeTurns.get(sessionId);
  if (known) {
    return { isRunning: true, turnId: known.turnId };
  }
  if (!hasProviderMethod(provider, "readSessionThread")) {
    return { isRunning: false, turnId: null };
  }
  const session = await readSession(provider, sessionId, false);
  return { isRunning: isActiveThread(session), turnId: null };
}

async function isThreadLoaded(
  provider: AgentProvider,
  sessionId: string,
): Promise<boolean> {
  if (!hasProviderMethod(provider, "listLoadedSessionIds")) {
    return true;
  }
  const data = await provider.listLoadedSessionIds();
  return data.includes(sessionId);
}

function upsertLiveActivity(
  liveActivities: Map<string, Map<string, SessionActivity>>,
  sessionId: string,
  activity: SessionActivity,
): SessionActivity {
  const sessionActivities =
    liveActivities.get(sessionId) || new Map<string, SessionActivity>();
  const merged = mergeActivity(sessionActivities.get(activity.id), activity);
  sessionActivities.set(activity.id, merged);
  liveActivities.set(sessionId, sessionActivities);
  return merged;
}

function materializeLiveActivityDraft(
  liveActivities: Map<string, Map<string, SessionActivity>>,
  sessionId: string,
  draft: AgentSessionActivityDraft,
  allocSeq: () => number,
): SessionActivity {
  const existing = liveActivities.get(sessionId)?.get(draft.id);
  const activity = materializeAgentActivityDraft(draft, {
    createdAt: existing?.createdAt ?? Date.now(),
    seq: existing?.seq ?? allocSeq(),
  });
  if (
    existing?.type === "file_change" &&
    activity.type === "file_change" &&
    activity.status === "in_progress"
  ) {
    return { ...activity, status: existing.status };
  }
  return activity;
}

function updateLiveOutputActivity(
  liveActivities: Map<string, Map<string, SessionActivity>>,
  sessionId: string,
  itemId: string,
  delta: string,
): SessionActivity | null {
  const sessionActivities = liveActivities.get(sessionId);
  if (!sessionActivities) {
    return null;
  }

  const existing = sessionActivities.get(itemId);
  if (!existing || (existing.type !== "command" && existing.type !== "tool")) {
    return null;
  }

  const updated = appendCommandActivityOutput(existing, delta);
  if (!updated) {
    return null;
  }

  sessionActivities.set(itemId, updated);
  return updated;
}

function updateLiveCommandTerminalInteraction(
  liveActivities: Map<string, Map<string, SessionActivity>>,
  sessionId: string,
  itemId: string,
  stdin: string,
): SessionActivity | null {
  const sessionActivities = liveActivities.get(sessionId);
  if (!sessionActivities) {
    return null;
  }

  const existing = sessionActivities.get(itemId);
  if (!existing || existing.type !== "command") {
    return null;
  }

  const updated = applyCommandTerminalInteraction(existing, stdin);
  if (!updated) {
    return null;
  }

  sessionActivities.set(itemId, updated);
  return updated;
}

function mapSession(
  thread: ThreadRecord,
  runtime: SessionRuntimeSummary | null = null,
): SessionSummary {
  const provider = providerKindForThread(thread);
  return {
    id: thread.id,
    title: sanitizeTitle(thread.name || thread.preview),
    preview: thread.preview,
    cwd: thread.cwd,
    createdAt: thread.createdAt * 1000,
    updatedAt: thread.updatedAt * 1000,
    source:
      typeof thread.source === "string"
        ? thread.source
        : JSON.stringify(thread.source),
    provider,
    status: thread.status?.type || "notLoaded",
    rolloutPath: thread.path,
    runtime,
    gitInfo: mapGitInfo(thread.gitInfo),
    isSubAgent: typeof thread.source === "object" && thread.source != null && (thread.source as Record<string, unknown>).subAgent != null,
  };
}

function providerKindForThread(thread: ThreadRecord): string | null {
  const source =
    typeof thread.source === "string" && isAgentProviderKind(thread.source)
      ? thread.source
      : null;
  if (source) {
    return source;
  }
  const separator = thread.id.indexOf(":");
  if (separator <= 0) {
    return null;
  }
  const prefix = thread.id.slice(0, separator);
  return isAgentProviderKind(prefix) ? prefix : null;
}

function mapGitInfo(raw: unknown): GitInfoSummary | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const typed = raw as Record<string, unknown>;
  const info: GitInfoSummary = {
    sha: asString(typed.sha),
    branch: asString(typed.branch),
    originUrl: sanitizeGitUrl(asString(typed.originUrl ?? typed.origin_url)),
  };
  return info.sha || info.branch || info.originUrl ? info : null;
}

function parseGitDiffKind(
  value: unknown,
): "working" | "staged" | "unstaged" | "remote" | null {
  const kind = asString(value);
  switch (kind) {
    case "working":
    case "staged":
    case "unstaged":
    case "remote":
      return kind;
    default:
      return null;
  }
}

function normalizeGitSha(value: unknown): string | null {
  if (typeof value === "string") {
    return value || null;
  }
  if (value && typeof value === "object") {
    const typed = value as Record<string, unknown>;
    return asString(typed.sha ?? typed.value ?? typed["0"]) ?? null;
  }
  return null;
}

function sanitizeTitle(raw: string): string {
  const compact = raw.replace(/\s+/g, " ").trim();
  if (!compact) {
    return "Untitled session";
  }
  return compact.length > 90 ? `${compact.slice(0, 87)}...` : compact;
}

function hashSessionInputSignature(
  input: AgentSessionInputItem[],
  overrides: AgentSessionOverrides,
): string {
  return createHash("sha256")
    .update(
      JSON.stringify({
        input,
        overrides: buildTurnInputSignatureOverrides(overrides),
      }),
    )
    .digest("hex");
}

function buildTurnInputSignatureOverrides(
  overrides: AgentSessionOverrides,
): Record<string, unknown> {
  return {
    model: overrides.model,
    reasoningEffort: overrides.reasoningEffort,
    fastMode: overrides.fastMode,
    approvalPolicy: overrides.approvalPolicy,
    sandboxMode: overrides.sandboxMode,
    networkAccess: overrides.networkAccess,
  };
}

function isValidClientMessageId(value: string): boolean {
  return (
    value.length > 0 &&
    value.length <= CLIENT_MESSAGE_ID_MAX_LENGTH &&
    CLIENT_MESSAGE_ID_PATTERN.test(value)
  );
}

async function persistSessionInputDedupeReceipt(
  store: SessionInputDedupeStore,
  key: string,
  signatureHash: string,
  createdAt: number,
  receipt: SessionInputReceipt,
): Promise<void> {
  const entry: StoredSessionInputDedupeEntry = {
    key,
    signatureHash,
    createdAt,
    updatedAt: Date.now(),
    receipt,
  };
  await store.put(entry);
}

function asInteger(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function buildSubmittedUserMessage(
  input: AgentSessionInputItem[],
  clientMessageId: string | null,
  seq: number,
): SessionMessage {
  return {
    id: clientMessageId || randomUUID(),
    role: "user",
    text: buildSubmittedUserMessageText(input),
    attachments: buildSubmittedUserMessageAttachments(input),
    createdAt: Date.now(),
    seq,
  };
}

async function loadCachedSessionRuntime(
  provider: AgentProvider,
  thread: ThreadRecord,
  runtimeCache: Map<string, SessionRuntimeCacheEntry>,
  runtimeMode: SessionRuntimeListMode,
): Promise<SessionRuntimeSummary | null> {
  if (runtimeMode === "none") {
    return null;
  }
  const cached = runtimeCache.get(thread.id);
  if (cached && cached.threadUpdatedAt === thread.updatedAt) {
    if (cached.promise) {
      return cached.promise;
    }
    return cached.runtime;
  }
  if (runtimeMode === "active" && !isActiveThread(thread)) {
    return null;
  }

  const promise = hasProviderMethod(provider, "readSessionRuntime")
    ? provider.readSessionRuntime(thread).catch(() => null)
    : Promise.resolve(null);
  runtimeCache.set(thread.id, {
    threadUpdatedAt: thread.updatedAt,
    runtime: null,
    promise,
  });
  const runtime = await promise;
  runtimeCache.set(thread.id, {
    threadUpdatedAt: thread.updatedAt,
    runtime,
  });
  return runtime;
}

function isActiveThread(thread: ThreadRecord): boolean {
  const type = thread.status?.type;
  return type === "active" || type === "running";
}

async function mapWithConcurrency<T, R>(
  items: T[],
  concurrency: number,
  mapper: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let nextIndex = 0;
  const workerCount = Math.min(Math.max(1, concurrency), items.length);

  await Promise.all(
    Array.from({ length: workerCount }, async () => {
      while (nextIndex < items.length) {
        const index = nextIndex;
        nextIndex += 1;
        results[index] = await mapper(items[index]!);
      }
    }),
  );

  return results;
}

function setSessionLogCacheEntry(
  logCache: Map<string, SessionLogCacheEntry>,
  cacheKey: string,
  entry: SessionLogCacheEntry,
): void {
  if (logCache.has(cacheKey)) {
    logCache.delete(cacheKey);
  }
  logCache.set(cacheKey, entry);

  while (logCache.size > SESSION_LOG_CACHE_LIMIT) {
    const oldest = logCache.keys().next().value;
    if (!oldest) {
      return;
    }
    logCache.delete(oldest);
  }
}

function clearSessionLogCache(
  logCache: Map<string, SessionLogCacheEntry>,
  sessionId: string,
): void {
  const prefix = `${sessionId}::`;
  for (const key of [...logCache.keys()]) {
    if (key.startsWith(prefix)) {
      logCache.delete(key);
    }
  }
}

function buildSessionLogCacheKey(
  sessionId: string,
  messageLimit: number | null,
  activityLimit: number | null,
): string {
  return `${sessionId}::m${messageLimit ?? "all"}::a${activityLimit ?? "all"}`;
}

function buildSessionHistorySummary(
  totalMessages: number,
  returnedMessages: number,
  totalActivities: number,
  returnedActivities: number,
): SessionHistorySummary {
  return {
    isTruncated:
      returnedMessages < totalMessages || returnedActivities < totalActivities,
    totalMessages,
    returnedMessages,
    totalActivities,
    returnedActivities,
  };
}

async function readSessionResources(
  provider: AgentProvider,
  sessionId: string,
  liveActivities: Map<string, Map<string, SessionActivity>>,
): Promise<SessionResourcesResponse> {
  const session = await readSession(provider, sessionId, false);
  const readLog = requireProviderMethod(
    provider,
    "readSessionLog",
    "session resources",
  );
  const log = await readLog.call(provider, session);
  const activities = mergeSessionActivities(
    log.activities,
    liveActivities.get(sessionId)?.values() || [],
  );
  const resources: SessionResource[] = buildSessionResources(
    log.messages,
    activities,
  );
  return {
    sessionId,
    updatedAt: session.updatedAt,
    resources,
  };
}

function clearActionsForSession(
  pendingActions: Map<string, AgentPendingAction>,
  sessionId: string,
  broadcastLive: (sessionId: string, event: LiveEvent) => void,
  broadcastApprovalLive: (event: ApprovalLiveEvent) => void,
): void {
  const toDelete = [...pendingActions.values()].filter(
    (action) => action.sessionId === sessionId,
  );
  for (const action of toDelete) {
    pendingActions.delete(action.id);
    broadcastLive(sessionId, {
      type: "action_resolved",
      sessionId,
      actionId: action.id,
    });
    broadcastApprovalLive({
      type: "action_resolved",
      actionId: action.id,
    });
  }
}

function findPendingActionForSession(
  pendingActions: Map<string, AgentPendingAction>,
  sessionId: string,
): PendingAction | null {
  for (const action of pendingActions.values()) {
    if (action.sessionId === sessionId) {
      return toPublicPendingAction(action);
    }
  }
  return null;
}

function broadcast(
  socketsBySession: Map<string, Set<WebSocket>>,
  sessionId: string,
  event: LiveEvent,
): void {
  const sockets = socketsBySession.get(sessionId);
  if (!sockets) {
    return;
  }
  for (const socket of sockets) {
    sendEvent(socket, event);
  }
}

function broadcastSkillsChanged(
  socketsBySession: Map<string, Set<WebSocket>>,
): void {
  for (const [sessionId, sockets] of socketsBySession) {
    for (const socket of sockets) {
      sendEvent(socket, { type: "skills_changed", sessionId });
    }
  }
}

function sendEvent(socket: WebSocket, event: unknown): void {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(event));
  }
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function buildLegacyTextInput(text: string | null): AgentSessionInputItem[] {
  if (!text) {
    return [];
  }
  return [{ type: "text", text, text_elements: [] }];
}

function parseInputItems(value: unknown): AgentSessionInputItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  const items: AgentSessionInputItem[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object") {
      continue;
    }
    const typed = item as Record<string, unknown>;
    switch (typed.type) {
      case "text": {
        const text = asString(typed.text);
        if (!text) {
          continue;
        }
        items.push({
          type: "text",
          text,
          text_elements: Array.isArray(typed.text_elements)
            ? typed.text_elements
            : [],
        });
        break;
      }
      case "image": {
        const url = asString(typed.url);
        if (!url) {
          continue;
        }
        items.push({ type: "image", url });
        break;
      }
      case "localImage":
      case "local_image": {
        const path = asString(typed.path);
        if (!path) {
          continue;
        }
        items.push({ type: "localImage", path });
        break;
      }
      case "skill": {
        const name = asString(typed.name);
        const path = asString(typed.path);
        if (!name || !path) {
          continue;
        }
        items.push({ type: "skill", name, path });
        break;
      }
      default:
        break;
    }
  }

  return items;
}

function buildSubmittedUserMessageText(input: AgentSessionInputItem[]): string {
  return input
    .filter(
      (item): item is Extract<AgentSessionInputItem, { type: "text" }> =>
        item.type === "text",
    )
    .map((item) => item.text.trim())
    .filter(Boolean)
    .join("\n\n");
}

function buildSubmittedUserMessageAttachments(
  input: AgentSessionInputItem[],
): SessionMessageAttachment[] {
  const attachments: SessionMessageAttachment[] = [];
  for (const item of input) {
    if (item.type === "image") {
      attachments.push({ type: "image", url: item.url });
      continue;
    }
    if (item.type === "localImage") {
      attachments.push({ type: "localImage", path: item.path });
    }
  }
  return attachments;
}

function parseCreateSessionOverrides(value: unknown): AgentSessionOverrides {
  const typed =
    value && typeof value === "object"
      ? (value as Record<string, unknown>)
      : {};
  return {
    model: asString(typed.model),
    mode: asString(typed.mode),
    reasoningEffort: asString(typed.reasoningEffort),
    fastMode: parseOptionalBool(typed.fastMode),
    approvalPolicy: asString(typed.approvalPolicy),
    sandboxMode: asString(typed.sandboxMode),
    networkAccess: parseOptionalBool(typed.networkAccess),
    webSearch: asString(typed.webSearch),
    profile: asString(typed.profile),
  };
}

function parseTurnOverrides(value: unknown): AgentSessionOverrides {
  const typed =
    value && typeof value === "object"
      ? (value as Record<string, unknown>)
      : {};
  return {
    model: asString(typed.model),
    mode: asString(typed.mode),
    reasoningEffort: asString(typed.reasoningEffort),
    fastMode: parseOptionalBool(typed.fastMode),
    approvalPolicy: asString(typed.approvalPolicy),
    sandboxMode: asString(typed.sandbox ?? typed.sandboxMode),
    networkAccess: parseOptionalBool(typed.networkAccess),
    webSearch: null,
    profile: null,
  };
}

function parseOptionalBool(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
}

function parseQueryBool(value: unknown): boolean {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value !== "string") {
    return false;
  }
  switch (value.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
      return true;
    default:
      return false;
  }
}
