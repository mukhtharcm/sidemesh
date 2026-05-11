import { createServer } from "node:http";
import type { Server } from "node:http";
import { homedir, hostname, platform } from "node:os";
import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import nodePath from "node:path";

import { getRequestListener } from "@hono/node-server";
import { bodyLimit } from "hono/body-limit";
import { compress } from "hono/compress";
import { cors } from "hono/cors";
import { createMiddleware } from "hono/factory";
import { Hono } from "hono";
import { HTTPException } from "hono/http-exception";
import { logger } from "hono/logger";
import { secureHeaders } from "hono/secure-headers";
import type { ContentfulStatusCode } from "hono/utils/http-status";
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
  LatestPlanUpdate,
  LiveEvent,
  LiveThreadStatus,
  SessionActivity,
  NodeConfig,
  PendingAction,
  UpdateChannel,
  RecentSessionsLiveEvent,
  SessionMessageAttachment,
  SessionMessage,
  SessionResourcesResponse,
  SessionRuntimeSummary,
  SessionResource,
  SessionSummary,
  ThreadRecord,
  TurnRecord,
  UsageObservation,
  UsageSnapshotResponse,
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
import {
  buildGitDiff,
  readGitDiff,
  readGitStatus,
  sanitizeGitUrl,
} from "./git.js";
import {
  createAgentProviderRuntime,
  type AgentProviderRuntime,
} from "./provider-factory.js";
import { isAgentProviderKind } from "./provider-registry.js";
import { buildSessionResources } from "./resources.js";
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
import { SessionSearchIndex, type SearchFilter } from "./session-search-index.js";
import { saveConfig } from "./config.js";
import { detectInstallInfo } from "./install-info.js";
import { spawnSelfUpdater } from "./updater-spawn.js";
import {
  jsonRoute,
  type HonoServerEnv,
  type JsonRouteRequest,
  type JsonRouteResponse,
} from "./hono-route-adapter.js";

const SESSION_LOG_CACHE_LIMIT = 24;
const SESSION_INPUT_DEDUPE_LIMIT = 500;
const SESSION_INPUT_DEDUPE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const SESSION_INPUT_DEDUPE_FILE = "session-input-dedupe-v1.json";
const SESSION_RUNTIME_SIGNALS_LIMIT = 500;
const SESSION_RUNTIME_SIGNALS_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const SESSION_RUNTIME_SIGNALS_FILE = "session-runtime-signals-v1.json";
const CLIENT_MESSAGE_ID_MAX_LENGTH = 128;
const CLIENT_MESSAGE_ID_PATTERN = /^[A-Za-z0-9._:-]+$/;
const RECENT_UNINDEXED_SESSION_SCAN_LIMIT = 50;
const RECENT_LIVE_LIMIT = 40;
const RECENT_SESSIONS_CACHE_TTL_MS = 1_500;
const TERMINAL_LIVE_STATUS_GRACE_MS = 1_000;
const RECENT_SESSION_RUNTIME_CONCURRENCY = 4;
const SESSION_EVENT_DELTA_MAX_ITEMS = 220;
const SESSION_EVENT_DELTA_MAX_BYTES = 256 * 1024;
const INSTALL_INFO_REFRESH_TTL_MS = 60_000;
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
  sessions: {
    search: true,
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
  latestPlanUpdate: LatestPlanUpdate | null;
}

interface SessionHistorySummary {
  isTruncated: boolean;
  totalMessages: number;
  returnedMessages: number;
  totalActivities: number;
  returnedActivities: number;
}

interface SessionRuntimeSignalsEntry {
  latestPlanUpdate: LatestPlanUpdate | null;
  updatedAt: number;
}

interface SessionInputReceipt {
  mode: "steer" | "turn";
  turnId: string | null;
  messageId: string;
}

interface SessionInputDedupeEntry {
  signatureHash: string;
  rawSignatureHash?: string;
  createdAt: number;
  promise?: Promise<SessionInputReceipt>;
  receipt?: SessionInputReceipt;
}

interface LiveActivityEntry {
  activity: SessionActivity;
  replaySeq: number;
}

interface InstallInfoRefreshResult {
  ok: boolean;
  refreshed: boolean;
  error: string | null;
}

export interface RunningServer {
  port: number;
  close(): Promise<void>;
}

interface StartServerDependencies {
  detectInstallInfo: typeof detectInstallInfo;
  spawnSelfUpdater: typeof spawnSelfUpdater;
  exitProcess(code?: number): never;
}

const DEFAULT_START_SERVER_DEPENDENCIES: StartServerDependencies = {
  detectInstallInfo,
  spawnSelfUpdater,
  exitProcess: (code = 0) => process.exit(code),
};

export async function startServer(
  config: NodeConfig,
  prebuiltRuntime?: AgentProviderRuntime,
  dependencyOverrides: Partial<StartServerDependencies> = {},
): Promise<RunningServer> {
  const dependencies = {
    ...DEFAULT_START_SERVER_DEPENDENCIES,
    ...dependencyOverrides,
  } satisfies StartServerDependencies;
  let runtimeConfig = config;
  const providerRuntime = prebuiltRuntime ?? createAgentProviderRuntime(config);
  const provider = providerRuntime.provider;
  await provider.start();
  let runningServerRef: RunningServer | null = null;
  const hostCapabilities: HostCapabilities = {
    ...HOST_CAPABILITIES,
    workspace: {
      ...HOST_CAPABILITIES.workspace,
      terminal: config.terminal.enabled,
      portForwarding: config.portForwarding.enabled,
      browserPreview: config.browserPreview.enabled,
    },
  };

  const app = new Hono<HonoServerEnv>();
  const server = createServer(getRequestListener(app.fetch));
  const socketsBySession = new Map<string, Set<WebSocket>>();
  const approvalSockets = new Set<WebSocket>();
  const recentSessionsSockets = new Set<WebSocket>();
  const recentSessionBroadcastTimers = new Map<string, NodeJS.Timeout>();
  const recentSessionsCache = new Map<string, {
    limit: number;
    runtimeMode: SessionRuntimeListMode;
    expiresAt: number;
    promise?: Promise<SessionSummary[]>;
    value?: SessionSummary[];
  }>();
  const activeTurns = new Map<string, ActiveTurnState>();
  const pendingActions = new Map<string, AgentPendingAction>();
  const liveActivities = new Map<string, Map<string, LiveActivityEntry>>();
  const liveThreadStatuses = new Map<string, LiveThreadStatus>();
  const liveThreadStatusUpdatedAt = new Map<string, number>();
  const replayIndex = new SessionReplayIndex();
  const searchIndex = new SessionSearchIndex(
    nodePath.join(config.stateDir, "search-index-v1.db"),
  );
  const runtimeCache = new Map<string, SessionRuntimeCacheEntry>();
  const logCache = new Map<string, SessionLogCacheEntry>();
  const sessionRuntimeSignals = await loadSessionRuntimeSignalsState(
    nodePath.join(config.stateDir, SESSION_RUNTIME_SIGNALS_FILE),
  );
  const sessionSeqCursor = new Map<string, number>();
  const sessionInputDedupe = new Map<string, SessionInputDedupeEntry>();
  let sessionRuntimeSignalsSaveChain = Promise.resolve();
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
      ...(entry.rawSignatureHash
        ? { rawSignatureHash: entry.rawSignatureHash }
        : {}),
      createdAt: entry.createdAt,
      receipt: entry.receipt,
    });
  }
  let providerVersion = "unknown";
  const providerVersions = new Map<string, string>();
  let installInfo = {
    packageVersion: "unknown",
    latestVersion: null as string | null,
    currentCommitSha: null as string | null,
    latestCommitSha: null as string | null,
    updateChannel: runtimeConfig.updateChannel,
    updateAvailable: false,
    installType: "unknown",
    updateSupported: false,
  };
  let installInfoCheckedAt = 0;
  let installInfoRefreshPromise: Promise<InstallInfoRefreshResult> | null = null;
  const setInstallInfo = (
    detected: Awaited<ReturnType<typeof detectInstallInfo>>,
  ): void => {
    installInfo = {
      packageVersion: detected.packageVersion,
      latestVersion: detected.latestVersion,
      currentCommitSha: detected.currentCommitSha,
      latestCommitSha: detected.latestCommitSha,
      updateChannel: detected.updateChannel,
      updateAvailable: detected.updateAvailable,
      installType: detected.installType,
      updateSupported: detected.updateSupported,
    };
    installInfoCheckedAt = Date.now();
  };
  const updateInfoPayload = (
    result: InstallInfoRefreshResult = {
      ok: true,
      refreshed: false,
      error: null,
    },
  ) => ({
    ok: result.ok,
    refreshed: result.refreshed,
    error: result.error,
    updateChannel: installInfo.updateChannel,
    updateAvailable: installInfo.updateAvailable,
    latestVersion: installInfo.latestVersion,
    packageVersion: installInfo.packageVersion,
    currentCommitSha: installInfo.currentCommitSha,
    latestCommitSha: installInfo.latestCommitSha,
    installType: installInfo.installType,
    updateSupported: installInfo.updateSupported,
  });
  const refreshInstallInfo = async (
    options: { force?: boolean } = {},
  ): Promise<InstallInfoRefreshResult> => {
    const freshEnough =
      installInfoCheckedAt > 0 &&
      Date.now() - installInfoCheckedAt < INSTALL_INFO_REFRESH_TTL_MS;
    if (!options.force && freshEnough) {
      return { ok: true, refreshed: false, error: null };
    }
    if (installInfoRefreshPromise) {
      return installInfoRefreshPromise;
    }

    installInfoRefreshPromise = (async () => {
      try {
        const detected = await dependencies.detectInstallInfo({
          config: runtimeConfig,
        });
        setInstallInfo(detected);
        return { ok: true, refreshed: true, error: null };
      } catch (error) {
        installInfo = {
          ...installInfo,
          updateChannel: runtimeConfig.updateChannel,
        };
        return {
          ok: false,
          refreshed: false,
          error: error instanceof Error ? error.message : String(error),
        };
      }
    })();
    try {
      return await installInfoRefreshPromise;
    } finally {
      installInfoRefreshPromise = null;
    }
  };
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
    const current = Math.max(
      sessionSeqCursor.get(sessionId) ?? 0,
      nextSeqForLatestPlanUpdate(0, latestPlanUpdateForSession(sessionId)),
    );
    sessionSeqCursor.set(sessionId, current + 1);
    return current;
  }

  function ensureSeqCursor(sessionId: string, minimum: number): void {
    const current = sessionSeqCursor.get(sessionId) ?? 0;
    if (minimum > current) {
      sessionSeqCursor.set(sessionId, minimum);
    }
  }

  function latestPlanUpdateForSession(sessionId: string): LatestPlanUpdate | null {
    return sessionRuntimeSignals.get(sessionId)?.latestPlanUpdate ?? null;
  }

  function latestThreadStatusForSession(sessionId: string): LiveThreadStatus | null {
    return liveThreadStatuses.get(sessionId) ?? null;
  }

  function setLatestThreadStatusForSession(
    sessionId: string,
    status: LiveThreadStatus | null,
  ): void {
    if (status == null) {
      liveThreadStatuses.delete(sessionId);
      liveThreadStatusUpdatedAt.delete(sessionId);
      return;
    }
    liveThreadStatuses.set(sessionId, status);
    liveThreadStatusUpdatedAt.set(sessionId, Date.now());
  }

  function sessionStatusOverrideForDisplay(
    sessionId: string,
  ): LiveThreadStatus | null {
    const status = latestThreadStatusForSession(sessionId);
    if (status == null) {
      return null;
    }
    if (isRunningThreadStatus(status)) {
      return status;
    }
    if (!isTerminalThreadStatus(status)) {
      return null;
    }
    const updatedAt = liveThreadStatusUpdatedAt.get(sessionId) ?? 0;
    return Date.now() - updatedAt <= TERMINAL_LIVE_STATUS_GRACE_MS ? status : null;
  }

  function clearConfirmedTerminalSessionState(sessionId: string): void {
    activeTurns.delete(sessionId);
    liveActivities.delete(sessionId);
    clearSessionLogCache(logCache, sessionId);
    clearActionsForSession(
      pendingActions,
      sessionId,
      broadcastLive,
      broadcastApprovalLive,
    );
  }

  function reconcileObservedThreadStatus(
    sessionId: string,
    observedStatus: LiveThreadStatus,
  ): void {
    const nextStatus = reconciledThreadStatus(sessionId, observedStatus);
    if (isTerminalThreadStatus(observedStatus)) {
      clearConfirmedTerminalSessionState(sessionId);
    }
    const previousStatus = latestThreadStatusForSession(sessionId);
    if (previousStatus === nextStatus) {
      return;
    }
    setLatestThreadStatusForSession(sessionId, nextStatus);
    scheduleRecentSessionUpsert(sessionId, 0);
  }

  function reconciledThreadStatus(
    sessionId: string,
    observedStatus: LiveThreadStatus,
  ): LiveThreadStatus {
    if (isTerminalThreadStatus(observedStatus)) {
      return observedStatus;
    }
    const terminalOverride = sessionStatusOverrideForDisplay(sessionId);
    if (terminalOverride && isTerminalThreadStatus(terminalOverride)) {
      return terminalOverride;
    }
    if (hasPendingActionForSession(pendingActions, sessionId)) {
      return "waiting_for_approval";
    }
    if (isRunningThreadStatus(observedStatus)) {
      return observedStatus;
    }
    if (observedStatus === "idle" && activeTurns.has(sessionId)) {
      return "running";
    }
    return observedStatus;
  }

  async function shouldTrackProviderTurn(
    agentProvider: AgentProvider,
    sessionId: string,
    turnId: string | null | undefined,
  ): Promise<boolean> {
    if (!turnId) {
      return false;
    }
    const observedStatus = latestThreadStatusForSession(sessionId);
    const state = await loadFastRunState(
      agentProvider,
      sessionId,
      new Map<string, ActiveTurnState>(),
      isRunningThreadStatus(observedStatus) ? observedStatus : null,
    );
    if (state.isRunning) {
      return state.turnId == null || state.turnId === turnId;
    }
    return !(await providerReportsTerminalTurn(agentProvider, sessionId, turnId));
  }

  function persistSessionRuntimeSignalsEventually(): void {
    sessionRuntimeSignalsSaveChain = sessionRuntimeSignalsSaveChain
      .catch(() => undefined)
      .then(() =>
        saveSessionRuntimeSignalsState(
          nodePath.join(config.stateDir, SESSION_RUNTIME_SIGNALS_FILE),
          sessionRuntimeSignals,
        )
      );
    void sessionRuntimeSignalsSaveChain.catch((error: unknown) => {
      console.error(
        error instanceof Error
          ? `Failed to persist session runtime signals: ${error.message}`
          : "Failed to persist session runtime signals.",
      );
    });
  }

  function setLatestPlanUpdateForSession(
    sessionId: string,
    latestPlanUpdate: LatestPlanUpdate | null,
  ): void {
    const normalized = normalizeLatestPlanUpdate(latestPlanUpdate, sessionId);
    if (normalized == null) {
      sessionRuntimeSignals.delete(sessionId);
    } else {
      sessionRuntimeSignals.set(sessionId, {
        latestPlanUpdate: normalized,
        updatedAt: Date.now(),
      });
    }
    updateSessionLogCacheLatestPlanUpdate(
      logCache,
      sessionId,
      latestPlanUpdateForSession(sessionId),
    );
    persistSessionRuntimeSignalsEventually();
  }

  function sessionInputDedupeKey(
    sessionId: string,
    clientMessageId: string,
  ): string {
    return `${sessionId}:${clientMessageId}`;
  }

  function sessionInputDedupeKeyMatchesSession(
    key: string,
    sessionId: string,
  ): boolean {
    return key.startsWith(`${sessionId}:`);
  }

  async function clearInterruptedSessionInputDedupe(
    interruptedTurnIds: Map<string, string>,
  ): Promise<void> {
    if (interruptedTurnIds.size === 0) {
      return;
    }
    const keysToDelete: string[] = [];
    for (const [key, entry] of sessionInputDedupe) {
      for (const [sessionId, turnId] of interruptedTurnIds) {
        if (!sessionInputDedupeKeyMatchesSession(key, sessionId)) {
          continue;
        }
        if (entry.promise || entry.receipt?.turnId === turnId) {
          keysToDelete.push(key);
        }
        break;
      }
    }
    if (keysToDelete.length === 0) {
      return;
    }
    for (const key of keysToDelete) {
      sessionInputDedupe.delete(key);
    }
    await sessionInputDedupeStore.deleteMany(keysToDelete);
  }

  function providerEntryForKind(kind: string | null | undefined) {
    return providerRuntime.providerForKind(kind);
  }

  function providerEntryForSessionId(sessionId: string) {
    return providerRuntime.providerForSessionId(sessionId);
  }

  async function clearProviderScopedRuntimeState(kind: string): Promise<void> {
    const sessionIds = new Set<string>();
    const sessionIdsNeedingIdleBroadcast = new Set<string>();
    const interruptedTurnIds = new Map<string, string>();
    const isProviderSession = (sessionId: string): boolean =>
      providerEntryForSessionId(sessionId)?.kind === kind;

    for (const sessionId of activeTurns.keys()) {
      if (isProviderSession(sessionId)) {
        sessionIds.add(sessionId);
        sessionIdsNeedingIdleBroadcast.add(sessionId);
        const activeTurn = activeTurns.get(sessionId);
        if (activeTurn?.turnId) {
          interruptedTurnIds.set(sessionId, activeTurn.turnId);
        }
      }
    }
    for (const action of pendingActions.values()) {
      if (isProviderSession(action.sessionId)) {
        sessionIds.add(action.sessionId);
        sessionIdsNeedingIdleBroadcast.add(action.sessionId);
      }
    }
    for (const sessionId of liveActivities.keys()) {
      if (isProviderSession(sessionId)) {
        sessionIds.add(sessionId);
      }
    }
    for (const sessionId of runtimeCache.keys()) {
      if (isProviderSession(sessionId)) {
        sessionIds.add(sessionId);
      }
    }
    for (const key of logCache.keys()) {
      const delimiterIndex = key.indexOf("::");
      const sessionId = delimiterIndex >= 0 ? key.slice(0, delimiterIndex) : key;
      if (isProviderSession(sessionId)) {
        sessionIds.add(sessionId);
      }
    }

    await clearInterruptedSessionInputDedupe(interruptedTurnIds);
    recentSessionsCache.clear();
    for (const sessionId of sessionIds) {
      const interruptedTurnId = interruptedTurnIds.get(sessionId);
      if (interruptedTurnId) {
        broadcastLive(sessionId, {
          type: "turn_completed",
          sessionId,
          turnId: interruptedTurnId,
          status: "interrupted",
        });
      }
      activeTurns.delete(sessionId);
      liveActivities.delete(sessionId);
      runtimeCache.delete(sessionId);
      clearSessionLogCache(logCache, sessionId);
      clearActionsForSession(
        pendingActions,
        sessionId,
        broadcastLive,
        broadcastApprovalLive,
      );
      if (sessionIdsNeedingIdleBroadcast.has(sessionId)) {
        setLatestThreadStatusForSession(sessionId, "idle");
        broadcastLive(sessionId, {
          type: "thread_status_changed",
          sessionId,
          status: "idle",
        });
      }
      scheduleRecentSessionUpsert(sessionId, 0);
    }
  }

  async function getSessionCwd(sessionId: string): Promise<string | null> {
    const sessionProvider = providerEntryForSessionId(sessionId);
    if (
      !sessionProvider ||
      !hasProviderMethod(sessionProvider.provider, "readSessionThread")
    ) {
      return null;
    }
    const session = await readSession(
      sessionProvider.provider,
      sessionId,
      false,
    ).catch(() => null);
    return session?.cwd || null;
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
  function broadcastLive(sessionId: string, event: LiveEvent): LiveEvent {
    const stamped: LiveEvent =
      event.seq === undefined ? { ...event, seq: allocSeq(sessionId) } : event;
    broadcast(socketsBySession, sessionId, stamped);
    return stamped;
  }

  function broadcastProviderWarning(event: {
    sessionId?: string;
    level: LiveEvent["level"];
    code?: string;
    message: string;
    source?: string;
  }): void {
    if (event.sessionId) {
      broadcastLive(event.sessionId, {
        type: "provider_warning",
        sessionId: event.sessionId,
        level: event.level,
        code: event.code,
        message: event.message,
        source: event.source,
      });
      return;
    }
    for (const sessionId of socketsBySession.keys()) {
      broadcastLive(sessionId, {
        type: "provider_warning",
        sessionId,
        level: event.level,
        code: event.code,
        message: event.message,
        source: event.source,
      });
    }
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
    const cacheKey = `${runtimeMode}:${limit}`;
    const cached = recentSessionsCache.get(cacheKey);
    if (cached && cached.limit >= limit && cached.runtimeMode === runtimeMode) {
      if (cached.promise) {
        return (await cached.promise).slice(0, limit);
      }
      if (cached.value && cached.expiresAt > now) {
        return cached.value.slice(0, limit);
      }
    }

    const promise = listSessions(
      provider,
      runtimeCache,
      limit,
      runtimeMode,
      sessionStatusOverrideForDisplay,
    );
    recentSessionsCache.set(cacheKey, {
      limit,
      runtimeMode,
      expiresAt: now + RECENT_SESSIONS_CACHE_TTL_MS,
      promise,
    });
    try {
      const value = await promise;
      recentSessionsCache.set(cacheKey, {
        limit,
        runtimeMode,
        expiresAt: Date.now() + RECENT_SESSIONS_CACHE_TTL_MS,
        value,
      });
      return value.slice(0, limit);
    } catch (error) {
      if (recentSessionsCache.get(cacheKey)?.promise === promise) {
        recentSessionsCache.delete(cacheKey);
      }
      throw error;
    }
  }

  function invalidateRecentSessionsCache(): void {
    recentSessionsCache.clear();
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
        sessionStatusOverrideForDisplay(thread.id),
      );
      broadcastRecentSessionsLive({ type: "upsert", session });
    } catch {
      // The session may have been archived/removed before we could refresh it.
    }
  }

  function scheduleRecentSessionUpsert(sessionId: string, delayMs = 150): void {
    // Status/runtime changes should be visible to the next /api/sessions read
    // immediately; the deferred upsert is only for live subscribers.
    invalidateRecentSessionsCache();
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
      case "skills_changed":
        broadcastSkillsChanged(socketsBySession);
        return;
      case "turn_started":
        activeTurns.set(event.sessionId, {
          turnId: event.turnId,
          startedAt: Date.now(),
        });
        setLatestThreadStatusForSession(event.sessionId, "running");
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
            content: event.message.content ?? [],
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
          () => allocSeq(event.sessionId),
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
          () => allocSeq(event.sessionId),
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
          () => allocSeq(event.sessionId),
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
      case "provider_warning": {
        broadcastProviderWarning(event);
        return;
      }
      case "thread_status_changed": {
        const status = reconciledThreadStatus(event.sessionId, event.status);
        setLatestThreadStatusForSession(event.sessionId, status);
        broadcastLive(event.sessionId, {
          type: "thread_status_changed",
          sessionId: event.sessionId,
          status,
          message: event.message,
          pendingActionKind: event.pendingActionKind,
        });
        scheduleRecentSessionUpsert(event.sessionId, 0);
        return;
      }
      case "plan_updated": {
        const stamped = broadcastLive(event.sessionId, {
          type: "plan_updated",
          sessionId: event.sessionId,
          turnId: event.turnId,
          explanation: event.explanation,
          plan: event.plan,
        });
        setLatestPlanUpdateForSession(
          event.sessionId,
          stamped.type === "plan_updated"
            ? {
                type: "plan_updated",
                sessionId: event.sessionId,
                seq: stamped.seq,
                turnId: stamped.turnId,
                explanation: stamped.explanation,
                plan: stamped.plan ?? event.plan,
              }
            : null,
        );
        return;
      }
      case "reasoning_delta": {
        broadcastLive(event.sessionId, {
          type: "reasoning_delta",
          sessionId: event.sessionId,
          turnId: event.turnId,
          itemId: event.itemId,
          reasoningId: event.reasoningId,
          delta: event.delta,
          summary: event.summary,
        });
        return;
      }
      case "queue_updated": {
        broadcastLive(event.sessionId, {
          type: "queue_updated",
          sessionId: event.sessionId,
          steeringCount: event.steeringCount,
          followUpCount: event.followUpCount,
          steeringPreview: event.steeringPreview,
          followUpPreview: event.followUpPreview,
        });
        return;
      }
      case "auto_retry_updated": {
        broadcastLive(event.sessionId, {
          type: "auto_retry_updated",
          sessionId: event.sessionId,
          phase: event.phase,
          attempt: event.attempt,
          maxAttempts: event.maxAttempts,
          delayMs: event.delayMs,
          errorMessage: event.errorMessage,
          success: event.success,
          finalError: event.finalError,
        });
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
        setLatestThreadStatusForSession(
          event.sessionId,
          event.status === "errored" ? "errored" : "idle",
        );
        liveActivities.delete(event.sessionId);
        clearSessionLogCache(logCache, event.sessionId);
        scheduleRecentSessionUpsert(event.sessionId, 0);
        void indexSessionForSearch(searchIndex, provider, event.sessionId).catch(() => {});
        // NOTE: do NOT reset sessionSeqCursor between turns — clients rely on
        // a monotonically increasing seq across the whole session lifetime to
        // detect gaps after a reconnect.
        return;
      case "action_opened":
        pendingActions.set(event.action.id, event.action);
        setLatestThreadStatusForSession(
          event.action.sessionId,
          "waiting_for_approval",
        );
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
    providerVersions.get(providerRuntime.defaultProviderKind) ??
    (await provider.getVersion().catch(() => "unknown"));

  try {
    const detected = await dependencies.detectInstallInfo({ config: runtimeConfig });
    setInstallInfo(detected);
  } catch {
    // Install detection is best-effort; never block server startup.
  }

  app.use("*", async (c, next) => {
    c.set("requestId", randomUUID());
    await next();
  });
  app.use("*", logger());
  app.use("*", secureHeaders({
    contentSecurityPolicy: {
      defaultSrc: ["'none'"],
      frameAncestors: ["'none'"],
    },
    xFrameOptions: "DENY",
  }));
  app.use("*", cors());
  // Compress large JSON responses while skipping already-compressed content
  // types (images, video) and the unauthenticated health-check endpoint.
  const compressionMiddleware = compress();
  app.use("*", async (c, next) => {
    if (isHealthCheckPath(c.req.path)) {
      await next();
      return;
    }
    return compressionMiddleware(c, next);
  });
  // Image attachments are sent as data URLs, so message payloads can be
  // materially larger than plain-text turns.
  app.use("*", bodyLimit({
    maxSize: 16 * 1024 * 1024,
    onError: (c) => c.json({ error: "payload too large" }, 413),
  }));

  app.get("/healthz", jsonRoute(async (_request, response) => {
    const probe = provider.health
      ? provider.health()
      : provider.getVersion().then(() => true).catch(() => false);
    let timer: NodeJS.Timeout | null = null;
    const providerHealthy = await Promise.race([
      probe,
      new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), 3_000);
      }),
    ]);
    if (timer) clearTimeout(timer);
    if (providerHealthy) {
      response.json({ ok: true, label: config.label });
      return;
    }
    response.status(503).json({
      ok: false,
      label: config.label,
      error: "provider unreachable",
    });
  }));

  const authMiddleware = createMiddleware<HonoServerEnv>(async (c, next) => {
    if (isHealthCheckPath(c.req.path)) {
      await next();
      return;
    }
    const auth = c.req.header("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
    if (token !== config.token) {
      throw new HTTPException(401, { message: "unauthorized" });
    }
    await next();
  });
  app.use("*", authMiddleware);

  app.get("/api/node", jsonRoute((_request, response) => {
    const defaultProvider = providerRuntime.defaultProvider;
    const defaultProviderCapabilities = defaultProvider.provider.capabilities;
    const supportedProviders = providerRuntime.providers.map((entry) => ({
      ...entry.definitionSummary,
      config: entry.configSummary,
      capabilities: entry.provider.capabilities,
      version: providerVersions.get(entry.kind) ?? "unknown",
      isDefault: entry.kind === providerRuntime.defaultProviderKind,
    }));
    response.json({
      label: config.label,
      hostname: hostname(),
      platform: platform(),
      homeDirectory: homedir(),
      codexVersion: providerVersion,
      provider: providerRuntime.defaultProviderKind,
      providerName:
        supportedProviders.find((item) => item.isDefault)?.displayName ??
        defaultProvider.provider.displayName,
      providerVersion,
      providerConfig: defaultProvider.configSummary,
      // Compatibility alias for defaultProviderCapabilities.
      // Retained until the minimum supported mobile client version no longer depends on it.
      providerCapabilities: defaultProviderCapabilities,
      defaultProviderCapabilities,
      hostCapabilities,
      searchSessions: hostCapabilities.sessions.search,
      searchIndexStats: searchIndex.getStats(),
      supportedProviders,
      startedAt: process.uptime(),
      tokenSource: config.tokenSource,
      packageVersion: installInfo.packageVersion,
      latestVersion: installInfo.latestVersion,
      currentCommitSha: installInfo.currentCommitSha,
      latestCommitSha: installInfo.latestCommitSha,
      updateChannel: installInfo.updateChannel,
      updateAvailable: installInfo.updateAvailable,
      installType: installInfo.installType,
      updateSupported: installInfo.updateSupported,
      recommendedMobileClientVersion:
        config.recommendedMobileClientVersion ?? null,
      minimumMobileClientVersion: config.minimumMobileClientVersion ?? null,
    });
  }));

  app.post(
    "/api/admin/update-check",
    asyncRoute(async (_request, response) => {
      const result = await refreshInstallInfo({ force: true });
      response.json(updateInfoPayload(result));
    }),
  );

  app.get("/api/providers", jsonRoute((_request, response) => {
    response.json({
      currentProvider: providerRuntime.defaultProviderKind,
      providers: providerRuntime.providers.map((entry) => ({
        ...entry.definitionSummary,
        config: entry.configSummary,
        capabilities: entry.provider.capabilities,
        version: providerVersions.get(entry.kind) ?? "unknown",
        isDefault: entry.kind === providerRuntime.defaultProviderKind,
      })),
    });
  }));

  app.get(
    "/api/usage",
    asyncRoute(async (_request, response) => {
      const generatedAt = Date.now();
      const observations = await collectUsageObservations(
        providerRuntime,
        config.label,
        generatedAt,
      );
      const payload: UsageSnapshotResponse = {
        generatedAt,
        host: {
          label: config.label,
          hostname: hostname(),
          provider: providerRuntime.defaultProviderKind,
        },
        observations,
      };
      response.json(payload);
    }),
  );

  app.get("/api/diagnostics", jsonRoute((_request, response) => {
    let sessionLiveSockets = 0;
    for (const sockets of socketsBySession.values()) {
      sessionLiveSockets += sockets.size;
    }
    let liveActivityItems = 0;
    for (const activities of liveActivities.values()) {
      liveActivityItems += activities.size;
    }

    response.json({
      label: config.label,
      hostname: hostname(),
      platform: platform(),
      uptimeSeconds: Math.round(process.uptime()),
      provider: providerRuntime.defaultProviderKind,
      memory: process.memoryUsage(),
      resourceUsage: process.resourceUsage(),
      caches: {
        recentSessions: recentSessionsCache.size,
        recentSessionBroadcastTimers: recentSessionBroadcastTimers.size,
        runtime: runtimeCache.size,
        logs: logCache.size,
        replay: replayIndex.getStats(),
        activeTurns: activeTurns.size,
        pendingActions: pendingActions.size,
        liveActivitySessions: liveActivities.size,
        liveActivityItems,
        sessionSeqCursors: sessionSeqCursor.size,
        inputDedupe: sessionInputDedupe.size,
      },
      sockets: {
        sessionRooms: socketsBySession.size,
        sessionLiveSockets,
        approvalLiveSockets: approvalSockets.size,
        recentSessionsLiveSockets: recentSessionsSockets.size,
      },
      features: {
        terminals: terminalRegistry.list().length,
        portForwards: portForwardRegistry.list().length,
        browserPreviews: browserPreviewRegistry.list().length,
      },
    });
  }));

  app.get("/api/debug/codex-rpc-audit", jsonRoute((_request, response) => {
    response.json(getCodexRpcAuditSnapshot());
  }));

  app.post(
    "/api/admin/provider/:kind/restart",
    asyncRoute(async (request, response) => {
      const kind = Array.isArray(request.params.kind) ? request.params.kind[0] : request.params.kind;
      if (!isAgentProviderKind(kind)) {
        response.status(400).json({ error: "unknown provider kind" });
        return;
      }
      const selectedProvider = providerRuntime.providerForKind(kind);
      if (
        !selectedProvider ||
        !selectedProvider.provider.capabilities.lifecycle.restart ||
        !selectedProvider.provider.restart
      ) {
        response.status(501).json({ error: "provider does not support restart" });
        return;
      }
      await selectedProvider.provider.restart();
      await clearProviderScopedRuntimeState(kind);
      response.json({ ok: true, kind });
    }),
  );

  app.post(
    "/api/admin/restart",
    asyncRoute(async (_request, response) => {
      response.json({ ok: true, message: "daemon is restarting" });
      setTimeout(async () => {
        try {
          await runningServerRef!.close();
        } finally {
          dependencies.exitProcess(0);
        }
      }, 100);
    }),
  );

  app.post(
    "/api/admin/update-channel",
    asyncRoute(async (request, response) => {
      const requestedChannel = parseUpdateChannel(request.body?.channel);
      if (requestedChannel === null) {
        response.status(400).json({ error: "channel must be stable or bleeding-edge" });
        return;
      }

      const nextConfig: NodeConfig = {
        ...runtimeConfig,
        updateChannel: requestedChannel,
        configExists: true,
      };
      await saveConfig(nextConfig, { configPath: nextConfig.configPath });
      runtimeConfig = nextConfig;

      const result = await refreshInstallInfo({ force: true });

      response.json({
        ...updateInfoPayload(result),
        ok: true,
      });
    }),
  );

  app.post(
    "/api/admin/update",
    asyncRoute(async (request, response) => {
      const requestedChannelRaw = request.body?.channel;
      const requestedChannel =
        requestedChannelRaw === undefined
          ? null
          : parseUpdateChannel(requestedChannelRaw);
      if (requestedChannelRaw !== undefined && requestedChannel === null) {
        response.status(400).json({ error: "channel must be stable or bleeding-edge" });
        return;
      }

      const effectiveConfig =
        requestedChannel && requestedChannel !== runtimeConfig.updateChannel
          ? {
              ...runtimeConfig,
              updateChannel: requestedChannel,
              configExists: true,
            }
          : runtimeConfig;
      if (effectiveConfig !== runtimeConfig) {
        await saveConfig(effectiveConfig, { configPath: effectiveConfig.configPath });
        runtimeConfig = effectiveConfig;
      }
      await refreshInstallInfo({ force: true });
      const info = installInfo;
      if (!info.updateSupported) {
        response.status(501).json({ error: "update not supported for this install type" });
        return;
      }

      await dependencies.spawnSelfUpdater(runtimeConfig, {
        updateChannel: requestedChannel,
      });

      response.json({ ok: true, message: "daemon is updating" });

      setTimeout(async () => {
        try {
          await runningServerRef!.close();
        } finally {
          dependencies.exitProcess(0);
        }
      }, 100);
    }),
  );

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
    "/api/sessions/search",
    asyncRoute(async (request, response) => {
      if (!hostCapabilities.sessions.search) {
        response.status(503).json({ error: "Session search is not available" });
        return;
      }
      const rawQuery = asString((request.query as Record<string, unknown>)?.q);
      const normalizedQuery = rawQuery?.trim() ?? "";
      const limit = Math.min(
        asInteger((request.query as Record<string, unknown>)?.limit) ?? 20,
        100,
      );
      if (normalizedQuery.length < 2) {
        const hasFilters =
          asString((request.query as Record<string, unknown>)?.provider) ||
          asString((request.query as Record<string, unknown>)?.cwd) ||
          (request.query as Record<string, unknown>)?.archived !== undefined ||
          asString((request.query as Record<string, unknown>)?.updatedAfter) ||
          asString((request.query as Record<string, unknown>)?.updatedBefore);
        if (!hasFilters) {
          response.status(400).json({ error: "Query must be at least 2 characters" });
          return;
        }
      }
      const filter: SearchFilter = {};
      const providerFilter = asString((request.query as Record<string, unknown>)?.provider);
      if (providerFilter) {
        filter.providerKind = providerFilter;
      }
      const cwdFilter = asString((request.query as Record<string, unknown>)?.cwd);
      if (cwdFilter) {
        filter.cwd = cwdFilter;
      }
      const archivedFilter = (request.query as Record<string, unknown>)?.archived;
      if (archivedFilter === "true") {
        filter.archived = true;
      } else if (archivedFilter === "false") {
        filter.archived = false;
      } else {
        filter.archived = false;
      }
      const updatedAfter = parseTimestamp((request.query as Record<string, unknown>)?.updatedAfter);
      if (updatedAfter != null) {
        filter.updatedAfter = updatedAfter;
      }
      const updatedBefore = parseTimestamp((request.query as Record<string, unknown>)?.updatedBefore);
      if (updatedBefore != null) {
        filter.updatedBefore = updatedBefore;
      }
      const searchResults = await searchIndex.search(normalizedQuery, limit, filter);
      const sessions = (await Promise.all(
        searchResults.map(async (result) => {
          if (!providerEntryForSessionId(result.sessionId)) {
            return null;
          }
          const thread = await readSession(provider, result.sessionId, false).catch(() => null);
          if (!thread) {
            return null;
          }
          const runtime = await loadCachedSessionRuntime(provider, thread, runtimeCache, "active");
          const session = mapSession(
            thread,
            runtime,
            sessionStatusOverrideForDisplay(thread.id),
          );
          const summary: SessionSummary = {
            ...session,
            matchSnippet: result.snippet ?? null,
            matchRank: result.rank,
          };
          return summary;
        }),
      )).filter((session): session is SessionSummary => session != null);
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
        listSessions: () =>
          listSessions(
            provider,
            runtimeCache,
            null,
            "none",
            sessionStatusOverrideForDisplay,
          ),
    getSessionCwd,
  });

  app.get("/api/terminals", jsonRoute((_request, response) => {
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
  }));

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

  app.get("/api/ports", jsonRoute((_request, response) => {
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
  }));

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

  app.get("/api/browser-previews", jsonRoute((_request, response) => {
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
  }));

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
      response.json(
        await listPendingActions(
          provider,
          pendingActions,
          reconcileObservedThreadStatus,
        ),
      );
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
      const session = await readSession(provider, sessionId, false);
      reconcileObservedThreadStatus(session.id, threadStatusPhase(session));
      const log = await provider.readSessionLog!(session, {
        messageLimit,
        activityLimit,
      });
      const latestPlanUpdate = mergeLatestPlanUpdate(
        sessionId,
        log.latestPlanUpdate ?? null,
        latestPlanUpdateForSession(sessionId),
      );
      ensureSeqCursor(
        sessionId,
        nextSeqForLatestPlanUpdate(log.nextSeq, latestPlanUpdate),
      );
      const activities = mergeSessionActivities(
        log.activities,
        liveActivityValues(liveActivities.get(sessionId)),
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
        latestPlanUpdate,
      });
      runtimeCache.set(session.id, {
        threadUpdatedAt: session.updatedAt,
        runtime: log.runtime,
      });
      response.json({
        session: mapSession(
          session,
          log.runtime,
          sessionStatusOverrideForDisplay(session.id),
        ),
        messages: log.messages,
        activities,
        pendingAction: findPendingActionForSession(pendingActions, sessionId),
        history,
        latestPlanUpdate,
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
      const baseUpdatedAt = asInteger(query.baseUpdatedAt);

      const session = await readSession(provider, sessionId, false);
      reconcileObservedThreadStatus(session.id, threadStatusPhase(session));

      let newMessages: SessionMessage[];
      let newActivities: SessionActivity[];
      let nextSeq: number;
      let logRuntime: SessionRuntimeSummary | null;
      let logLatestPlanUpdate: LatestPlanUpdate | null;

      if (session.path && session.path.endsWith(".jsonl")) {
        try {
          const entry = await replayIndex.load(sessionId, session.path);
          const liveSessionActivities = liveActivities.get(sessionId);
          if (hostCapabilities.sessions.search) {
            void indexSessionForSearch(searchIndex, provider, sessionId).catch(() => {
              // Ignore indexing errors for live sessions
            });
          }
          ensureSeqCursor(sessionId, entry.nextSeq);
          const delta = replayIndex.getDelta(entry, since);
          newMessages = delta.messages;
          const replayedActivities = filterActivitiesForReplay(
            mergeSessionActivities(
              delta.activities,
              liveActivityValues(liveSessionActivities),
            ),
            liveSessionActivities,
            since,
          );
          newActivities = replayedActivities.activities;
          logLatestPlanUpdate = mergeLatestPlanUpdate(
            sessionId,
            latestPlanUpdateForSession(sessionId),
          );
          nextSeq = nextSeqForLatestPlanUpdate(
            Math.max(delta.nextSeq, replayedActivities.highestSeq),
            logLatestPlanUpdate,
          );
          logRuntime = delta.runtime;
        } catch (error: unknown) {
          const staleCursor = error && typeof error === "object"
            ? (error as Record<string, unknown>)
            : null;
          if (staleCursor?.code === "STALE_CURSOR") {
            response.status(410).json({
              error: "stale_cursor",
              since: staleCursor.staleSince,
              oldestAvailableSeq: staleCursor.oldestAvailableSeq,
            });
            return;
          }
          // Fallback to provider readSessionLog on any other error
          const log = await provider.readSessionLog!(session);
          const latestPlanUpdate = mergeLatestPlanUpdate(
            sessionId,
            log.latestPlanUpdate ?? null,
            latestPlanUpdateForSession(sessionId),
          );
          ensureSeqCursor(
            sessionId,
            nextSeqForLatestPlanUpdate(log.nextSeq, latestPlanUpdate),
          );
          const liveSessionActivities = liveActivities.get(sessionId);
          const activities = mergeSessionActivities(
            log.activities,
            liveActivityValues(liveSessionActivities),
          );
          const replayedActivities = filterActivitiesForReplay(
            activities,
            liveSessionActivities,
            since,
          );
          newMessages = log.messages.filter((m) => (m.seq ?? 0) > since);
          newActivities = replayedActivities.activities;
          let highestSeq = replayedActivities.highestSeq;
          for (const m of newMessages) {
            if ((m.seq ?? 0) > highestSeq) highestSeq = m.seq ?? highestSeq;
          }
          logLatestPlanUpdate = latestPlanUpdate;
          nextSeq = nextSeqForLatestPlanUpdate(highestSeq, latestPlanUpdate);
          logRuntime = log.runtime;
        }
      } else {
        const log = await provider.readSessionLog!(session);
        const latestPlanUpdate = mergeLatestPlanUpdate(
          sessionId,
          log.latestPlanUpdate ?? null,
          latestPlanUpdateForSession(sessionId),
        );
        ensureSeqCursor(
          sessionId,
          nextSeqForLatestPlanUpdate(log.nextSeq, latestPlanUpdate),
        );
        const liveSessionActivities = liveActivities.get(sessionId);
        const activities = mergeSessionActivities(
          log.activities,
          liveActivityValues(liveSessionActivities),
        );
        const replayedActivities = filterActivitiesForReplay(
          activities,
          liveSessionActivities,
          since,
        );
        newMessages = log.messages.filter((m) => (m.seq ?? 0) > since);
        newActivities = replayedActivities.activities;
        let highestSeq = replayedActivities.highestSeq;
        for (const m of newMessages) {
          if ((m.seq ?? 0) > highestSeq) highestSeq = m.seq ?? highestSeq;
        }
        logLatestPlanUpdate = latestPlanUpdate;
        nextSeq = nextSeqForLatestPlanUpdate(highestSeq, latestPlanUpdate);
        logRuntime = log.runtime;
      }

      const latestPlanUpdate = isLatestPlanUpdateNewerThan(
        logLatestPlanUpdate,
        since,
      )
        ? logLatestPlanUpdate
        : null;

      if (
        baseUpdatedAt != null &&
        threadTimestampMillis(session.updatedAt) > baseUpdatedAt &&
        newMessages.length === 0 &&
        newActivities.length === 0 &&
        latestPlanUpdate == null
      ) {
        response.status(409).json({
          error: "stale_snapshot",
          since,
          baseUpdatedAt,
          currentUpdatedAt: threadTimestampMillis(session.updatedAt),
        });
        return;
      }

      const eventDeltaSize = measureSessionEventDelta(
        newMessages,
        newActivities,
        latestPlanUpdate,
      );
      if (
        eventDeltaSize.items > SESSION_EVENT_DELTA_MAX_ITEMS ||
        eventDeltaSize.bytes > SESSION_EVENT_DELTA_MAX_BYTES
      ) {
        response.status(410).json({
          error: "stale_cursor",
          reason: "delta_too_large",
          since,
          nextSeq,
          maxItems: SESSION_EVENT_DELTA_MAX_ITEMS,
          maxBytes: SESSION_EVENT_DELTA_MAX_BYTES,
          actualItems: eventDeltaSize.items,
          actualBytes: eventDeltaSize.bytes,
        });
        return;
      }

      response.json({
        sessionId,
        since,
        nextSeq,
        messages: newMessages,
        activities: newActivities,
        latestPlanUpdate,
        pendingAction: findPendingActionForSession(pendingActions, sessionId),
        session: mapSession(
          session,
          logRuntime,
          sessionStatusOverrideForDisplay(session.id),
        ),
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
        await readSessionResources(
          provider,
          sessionId,
          liveActivities,
          reconcileObservedThreadStatus,
        ),
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
      const statusOverride = sessionStatusOverrideForDisplay(sessionId);
      const state = await loadFastRunState(
        provider,
        sessionId,
        activeTurns,
        statusOverride,
      );
      if (!isTerminalThreadStatus(statusOverride)) {
        reconcileObservedThreadStatus(sessionId, state.status);
      }
      response.json({
        sessionId,
        status: state.status,
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
    "/api/modes",
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
          selectedProvider.provider.capabilities.runtimeControls.mode,
          "mode listing",
          "listModes",
        )
      ) {
        return;
      }
      if (!hasProviderMethod(selectedProvider.provider, "listModes")) {
        response.status(501).json({ error: "mode listing not supported" });
        return;
      }
      const cwd = asString(query.cwd) || null;
      response.json(await selectedProvider.provider.listModes({ cwd }));
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
      const scopedInput = await resolveFileInputItemsForCwd(
        resolvedInput,
        cwd,
      );
      const started = await provider.createSession!({
        cwd,
        input: scopedInput,
        overrides,
        provider: selectedProvider.kind,
      });
      if (
        await shouldTrackProviderTurn(
          provider,
          started.thread.id,
          started.activeTurnId,
        )
      ) {
        activeTurns.set(started.thread.id, {
          turnId: started.activeTurnId!,
          startedAt: Date.now(),
        });
        setLatestThreadStatusForSession(
          started.thread.id,
          hasPendingActionForSession(pendingActions, started.thread.id)
            ? "waiting_for_approval"
            : "running",
        );
      }

      const session = mapSession(
        started.thread,
        started.runtime,
        sessionStatusOverrideForDisplay(started.thread.id),
      );
      response.status(201).json({
        session,
        activeTurnId: started.activeTurnId,
      });
      broadcastRecentSessionsLive({ type: "upsert", session });
      void indexSessionForSearch(searchIndex, provider, started.thread.id).catch(() => {});
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
      const rawInputSignatureHash = hashSessionInputSignature(
        resolvedInput,
        turnOverrides,
      );
      const dedupeKey = clientMessageId
        ? sessionInputDedupeKey(sessionId, clientMessageId)
        : null;
      let existingDedupe: SessionInputDedupeEntry | undefined;
      if (dedupeKey) {
        pruneSessionInputDedupe();
        existingDedupe = sessionInputDedupe.get(dedupeKey);
        if (existingDedupe?.rawSignatureHash) {
          if (existingDedupe.rawSignatureHash !== rawInputSignatureHash) {
            response.status(409).json({
              error: "clientMessageId was already used with different input",
            });
            return;
          }
          const receipt =
            existingDedupe.receipt ?? (await existingDedupe.promise);
          if (receipt) {
            response.json({ ...receipt, replayed: true });
            return;
          }
        }
      }

      let scopedInput: AgentSessionInputItem[] | null = null;
      let inputSignatureHash: string | null = null;
      const resolveScopedInput = async (): Promise<AgentSessionInputItem[]> => {
        if (scopedInput) {
          return scopedInput;
        }
        scopedInput = await resolveFileInputItemsForSession(
          provider,
          sessionId,
          resolvedInput,
        );
        inputSignatureHash = hashSessionInputSignature(
          scopedInput,
          turnOverrides,
        );
        return scopedInput;
      };

      if (dedupeKey && existingDedupe && !existingDedupe.rawSignatureHash) {
        const legacySignatureHash = hashLegacySessionInputSignature(
          resolvedInput,
          turnOverrides,
        );
        if (existingDedupe.signatureHash === legacySignatureHash) {
          const receipt =
            existingDedupe.receipt ?? (await existingDedupe.promise);
          if (receipt) {
            response.json({ ...receipt, replayed: true });
            return;
          }
        }
        await resolveScopedInput();
        if (existingDedupe.signatureHash !== inputSignatureHash) {
          response.status(409).json({
            error: "clientMessageId was already used with different input",
          });
          return;
        }
        const receipt = existingDedupe.receipt ?? (await existingDedupe.promise);
        if (receipt) {
          response.json({ ...receipt, replayed: true });
          return;
        }
      }

      const submit = async (): Promise<SessionInputReceipt> => {
        const inputForSubmit = await resolveScopedInput();
        const submittedMessage = buildSubmittedUserMessage(
          inputForSubmit,
          clientMessageId,
          allocSeq(sessionId),
        );
        const state = await loadRunState(provider, sessionId, activeTurns);
        const submitted = await provider.submitInput!({
          sessionId,
          input: inputForSubmit,
          activeTurnId: state.turnId,
          overrides: turnOverrides,
        });
        if (
          await shouldTrackProviderTurn(
            provider,
            sessionId,
            submitted.turnId,
          )
        ) {
          const previousStartedAt = state.turnId
            ? activeTurns.get(sessionId)?.startedAt
            : undefined;
          activeTurns.set(sessionId, {
            turnId: submitted.turnId!,
            startedAt: previousStartedAt ?? Date.now(),
          });
          setLatestThreadStatusForSession(
            sessionId,
            hasPendingActionForSession(pendingActions, sessionId)
              ? "waiting_for_approval"
              : "running",
          );
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
          signatureHash: rawInputSignatureHash,
          rawSignatureHash: rawInputSignatureHash,
          createdAt: Date.now(),
          promise,
        });
        pruneSessionInputDedupe();
      }

      try {
        const receipt = await promise;
        if (dedupeKey) {
          const finalSignatureHash = inputSignatureHash ?? rawInputSignatureHash;
          const createdAt =
            sessionInputDedupe.get(dedupeKey)?.createdAt ?? Date.now();
          sessionInputDedupe.set(dedupeKey, {
            signatureHash: finalSignatureHash,
            rawSignatureHash: rawInputSignatureHash,
            createdAt,
            receipt,
          });
          await persistSessionInputDedupeReceipt(
            sessionInputDedupeStore,
            dedupeKey,
            finalSignatureHash,
            rawInputSignatureHash,
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
      const session = mapSession(thread, null, sessionStatusOverrideForDisplay(thread.id));
      response.json({ session });
      broadcastRecentSessionsLive({ type: "upsert", session });
      void indexSessionForSearch(searchIndex, provider, sessionId).catch(() => {});
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
      liveThreadStatuses.delete(sessionId);
      liveActivities.delete(sessionId);
      clearSessionLogCache(logCache, sessionId);
      sessionSeqCursor.delete(sessionId);
      response.json({ archived: true });
      broadcastRecentSessionRemove(sessionId);
      void indexSessionForSearch(searchIndex, provider, sessionId, true).catch(() => {});
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
      void indexSessionForSearch(searchIndex, provider, sessionId, false).catch(() => {});
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
      setLatestThreadStatusForSession(
        action.sessionId,
        activeTurns.has(action.sessionId) ? "running" : null,
      );
      scheduleRecentSessionUpsert(action.sessionId, 0);
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
      const params = new URLSearchParams(queryString || "");
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        try {
          ws.send(JSON.stringify({ type: "hello" }));
        } catch {
          /* noop */
        }
        attachFsLiveSocket(ws, fsWatchRegistry, {
          listSessions: () =>
            listSessions(
              provider,
              runtimeCache,
              null,
              "none",
              sessionStatusOverrideForDisplay,
            ),
          getSessionCwd,
          sessionId: params.get("sessionId"),
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
          nextSeq: nextSeqForLatestPlanUpdate(
            sessionSeqCursor.get(sessionId) ?? 0,
            latestPlanUpdateForSession(sessionId),
          ),
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

  app.onError((error, c) => {
    const message =
      error instanceof Error ? error.message : "Internal server error";
    if (error instanceof HTTPException) {
      return c.json({ error: message }, error.status as ContentfulStatusCode);
    }
    if (
      error instanceof TerminalError ||
      error instanceof WorkspaceAccessError ||
      error instanceof PortForwardError ||
      error instanceof BrowserPreviewError
    ) {
      return c.json({ error: message }, error.status as ContentfulStatusCode);
    }
    console.error("[Error]", error);
    return c.json({ error: "Internal server error" }, 500);
  });

  await listen(server, config.port);

  // Open search index and warm all provider indexes in the background
  searchIndex.open().then(async () => {
    searchIndex.setBackfillRunning(true);
    let totalIndexed = 0;
    let totalRemoved = 0;

    for (const entry of providerRuntime.providers) {
      const provider = entry.provider;
      if (
        !hasProviderMethod(provider, "listSessionThreads") ||
        !hasProviderMethod(provider, "readSessionLog")
      ) {
        continue;
      }
      searchIndex.setProviderError(provider.kind, null);
      try {
        const batchSize = 50;
        for (const archived of [false, true]) {
          const threads = await provider.listSessionThreads!({
            limit: 200,
            archived,
          });
          const batches = chunkArray(threads, batchSize);
          for (const batch of batches) {
            for (const thread of batch) {
              try {
                const log = await provider.readSessionLog!(thread, {
                  messageLimit: 200,
                  activityLimit: 200,
                });
                const createdAt = threadTimestampMillis(thread.createdAt);
                const updatedAt = threadTimestampMillis(thread.updatedAt);
                await searchIndex.indexDocument({
                  sessionKey: thread.id,
                  providerKind: provider.kind,
                  title: thread.name || thread.preview,
                  preview: thread.preview,
                  cwd: thread.cwd,
                  createdAt,
                  updatedAt,
                  archived,
                  fingerprint: `${provider.kind}|${thread.name || ""}|${thread.preview}|${thread.cwd}|${createdAt}|${updatedAt}|${archived}|${log.nextSeq}`,
                  messages: log.messages,
                  activities: log.activities,
                });
                totalIndexed++;
              } catch {
                // Ignore per-session indexing errors during catch-up
              }
            }
            // yield so startup remains responsive
            await new Promise((resolve) => setImmediate(resolve));
          }
        }
      } catch (error: unknown) {
        const message =
          error instanceof Error ? error.message : String(error);
        searchIndex.setProviderError(provider.kind, message);
      }
    }

    searchIndex.setBackfillRunning(false);
    return { indexed: totalIndexed, removed: totalRemoved };
  }).then((result) => {
    if (result.indexed > 0 || result.removed > 0) {
      console.log(`Search index caught up: ${result.indexed} indexed, ${result.removed} removed`);
    }
  }).catch((error: unknown) => {
    console.error(
      "Failed to open search index:",
      error instanceof Error ? error.message : error,
    );
  });

  for (const line of startupSummaryLines({
    config,
    providerDisplayName: provider.displayName,
    providerKinds: providerRuntime.providers.map((entry) => entry.kind),
  })) {
    console.log(line);
  }

  // Health monitor: exit if provider is unhealthy so systemd can restart.
  const HEALTH_MONITOR_INTERVAL_MS = 30_000;
  const HEALTH_MONITOR_MAX_FAILURES = 3;
  let healthFailures = 0;
  const healthMonitor = setInterval(async () => {
    const probe = provider.health
      ? provider.health()
      : provider.getVersion().then(() => true).catch(() => false);
    const healthy = await Promise.race([
      probe,
      new Promise<boolean>((resolve) =>
        setTimeout(() => resolve(false), 5_000),
      ),
    ]);
    if (healthy) {
      healthFailures = 0;
      return;
    }
    healthFailures++;
    console.error(
      `Health monitor: provider unhealthy (${healthFailures}/${HEALTH_MONITOR_MAX_FAILURES})`,
    );
    if (healthFailures >= HEALTH_MONITOR_MAX_FAILURES) {
      console.error("Health monitor: exiting due to persistent provider failure");
      await runningServerRef!.close();
      dependencies.exitProcess(1);
    }
  }, HEALTH_MONITOR_INTERVAL_MS);

  const boundAddress = server.address();
  const boundPort = typeof boundAddress === "string" ? 0 : (boundAddress?.port ?? 0);

  runningServerRef = {
    port: boundPort,
    close: async () => {
      clearInterval(healthMonitor);
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
      await sessionRuntimeSignalsSaveChain.catch(() => undefined);
      await provider.close?.();
    },
  };
  return runningServerRef;
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


function getCodexHomePath(provider: AgentProvider): string | null {
  const runtimeHome = (provider as { runtimeHome?: string }).runtimeHome;
  return typeof runtimeHome === "string" ? runtimeHome : null;
}
function asyncRoute(
  handler: (
    request: JsonRouteRequest,
    response: JsonRouteResponse,
  ) => Promise<void>,
): ReturnType<typeof jsonRoute> {
  return jsonRoute(handler);
}

function pathParam(value: string | string[] | undefined): string {
  if (Array.isArray(value)) {
    return value[0] || "";
  }
  return value || "";
}

function isHealthCheckPath(path: string): boolean {
  return path === "/healthz";
}

function requireProviderCapability(
  response: JsonRouteResponse,
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
  response: JsonRouteResponse,
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
      case "file":
        if (!provider.capabilities.input.fileMentions) {
          return `${provider.displayName} does not support file mentions`;
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
  statusOverrideForSession?: (sessionId: string) => LiveThreadStatus | null,
): Promise<SessionSummary[]> {
  const limit = normalizedSessionListLimit(limitOverride);
  if (
    canUseRecentSessionFallback(provider) &&
    !hasProviderMethod(provider, "listSessionThreads")
  ) {
    const threads = await provider.listRecentUnindexedSessionThreads(
      Math.max(limit, RECENT_UNINDEXED_SESSION_SCAN_LIMIT),
    );
    return mapWithConcurrency(
      threads,
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
          statusOverrideForSession?.(thread.id) ?? null,
      ),
    );
  }
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
        statusOverrideForSession?.(thread.id) ?? null,
      ),
  );
}

function canUseRecentSessionFallback(provider: AgentProvider): provider is AgentProvider & {
  listRecentUnindexedSessionThreads: NonNullable<
    AgentProvider["listRecentUnindexedSessionThreads"]
  >;
} {
  return (
    provider.capabilities.sessions.recentFallback &&
    hasProviderMethod(provider, "listRecentUnindexedSessionThreads")
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
    .sort(
      (left, right) =>
        threadTimestampMillis(right.updatedAt) -
        threadTimestampMillis(left.updatedAt),
    )
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
  reconcileStatus?: (
    sessionId: string,
    observedStatus: LiveThreadStatus,
  ) => void,
): Promise<PendingAction[]> {
  const actions = [...pendingActions.values()].sort(
    (left, right) => right.requestedAt - left.requestedAt,
  );
  const sessionsById = new Map<string, Promise<ThreadRecord | null>>();

  return (
    await Promise.all(
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
      reconcileStatus?.(action.sessionId, threadStatusPhase(session));
      if (!pendingActions.has(action.id)) {
        return null;
      }

      const mapped = mapSession(session);
      return toPublicPendingAction({
        ...action,
        sessionTitle: mapped.title,
        cwd: mapped.cwd,
      });
    }),
    )
  ).filter((action): action is PendingAction => action != null);
}

async function indexSessionForSearch(
  searchIndex: SessionSearchIndex,
  provider: AgentProvider,
  sessionId: string,
  archived?: boolean,
): Promise<void> {
  if (!provider.capabilities.sessions.history) return;
  if (!hasProviderMethod(provider, "readSessionThread") || !hasProviderMethod(provider, "readSessionLog")) {
    return;
  }
  try {
    const thread = await readSession(provider, sessionId, false);
    const log = await provider.readSessionLog!(thread, {
      messageLimit: 200,
      activityLimit: 200,
    });
    const createdAt = threadTimestampMillis(thread.createdAt);
    const updatedAt = threadTimestampMillis(thread.updatedAt);
    await searchIndex.indexDocument({
      sessionKey: sessionId,
      providerKind: provider.kind,
      title: thread.name || thread.preview,
      preview: thread.preview,
      cwd: thread.cwd,
      createdAt,
      updatedAt,
      archived: archived ?? false,
      fingerprint: `${provider.kind}|${thread.name || ""}|${thread.preview}|${thread.cwd}|${createdAt}|${updatedAt}|${archived ?? false}|${log.nextSeq}`,
      messages: log.messages,
      activities: log.activities,
    });
  } catch {
    // Ignore indexing errors
  }
}

async function collectUsageObservations(
  providerRuntime: AgentProviderRuntime,
  hostLabel: string,
  generatedAt: number,
): Promise<UsageObservation[]> {
  const groups = await Promise.all(
    providerRuntime.providers.map(async (entry) => {
      if (!hasProviderMethod(entry.provider, "readUsageObservations")) {
        return [
          buildUnsupportedUsageObservation(
            entry.kind,
            entry.provider.displayName,
            hostLabel,
            generatedAt,
          ),
        ];
      }
      try {
        const observations = await entry.provider.readUsageObservations();
        if (observations.length === 0) {
          return [
            buildUnsupportedUsageObservation(
              entry.kind,
              entry.provider.displayName,
              hostLabel,
              generatedAt,
            ),
          ];
        }
        return observations.map((observation) => ({
          ...observation,
          hostId: observation.hostId ?? hostLabel,
          hostLabel: observation.hostLabel ?? hostLabel,
          provider: {
            ...observation.provider,
            kind: observation.provider.kind || entry.kind,
            displayName:
              observation.provider.displayName || entry.provider.displayName,
          },
        }));
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return [
          buildUsageErrorObservation(
            entry.kind,
            entry.provider.displayName,
            hostLabel,
            generatedAt,
            message,
          ),
        ];
      }
    }),
  );
  return groups.flat();
}

function buildUnsupportedUsageObservation(
  providerKind: string,
  providerName: string,
  hostLabel: string,
  observedAt: number,
): UsageObservation {
  return {
    id: `${providerKind}:usage:unsupported`,
    hostId: hostLabel,
    hostLabel,
    observedAt,
    expiresAt: observedAt + 60 * 60_000,
    provider: {
      kind: providerKind,
      displayName: providerName,
    },
    account: null,
    subject: {
      kind: "unknown",
      displayName: providerName,
      stableKeyHash: null,
    },
    windows: [],
    health: "unsupported",
    source: {
      id: `${providerKind}.usage`,
      label: "Usage collector",
      kind: "unsupported",
      priority: 0,
    },
    message: `${providerName} does not expose account usage yet.`,
  };
}

function buildUsageErrorObservation(
  providerKind: string,
  providerName: string,
  hostLabel: string,
  observedAt: number,
  message: string,
): UsageObservation {
  return {
    id: `${providerKind}:usage:error`,
    hostId: hostLabel,
    hostLabel,
    observedAt,
    expiresAt: observedAt + 60_000,
    provider: {
      kind: providerKind,
      displayName: providerName,
    },
    account: null,
    subject: {
      kind: "unknown",
      displayName: providerName,
      stableKeyHash: null,
    },
    windows: [],
    health: "error",
    source: {
      id: `${providerKind}.usage`,
      label: "Usage collector",
      kind: "unknown",
      priority: 0,
    },
    message,
  };
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

function chunkArray<T>(array: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < array.length; i += size) {
    chunks.push(array.slice(i, i + size));
  }
  return chunks;
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
    if (isActiveTurnStatus(turn.status)) {
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
  liveStatusOverride: LiveThreadStatus | null = null,
): Promise<{ status: LiveThreadStatus; isRunning: boolean; turnId: string | null }> {
  if (liveStatusOverride != null) {
    return {
      status: liveStatusOverride,
      isRunning: isRunningThreadStatus(liveStatusOverride),
      turnId: isRunningThreadStatus(liveStatusOverride)
        ? activeTurns.get(sessionId)?.turnId ?? null
        : null,
    };
  }
  const known = activeTurns.get(sessionId);
  if (known) {
    return { status: "running", isRunning: true, turnId: known.turnId };
  }
  if (!hasProviderMethod(provider, "readSessionThread")) {
    return { status: "unknown", isRunning: false, turnId: null };
  }
  const session = await readSession(provider, sessionId, false);
  const status = threadStatusPhase(session);
  if (isRunningThreadStatus(status)) {
    return { status, isRunning: true, turnId: null };
  }
  try {
    const sessionWithTurns = await readSession(provider, sessionId, true);
    const turns = Array.isArray(sessionWithTurns.turns) ? sessionWithTurns.turns : [];
    for (let index = turns.length - 1; index >= 0; index -= 1) {
      const turn = turns[index] as TurnRecord;
      if (isActiveTurnStatus(turn.status)) {
        return { status: "running", isRunning: true, turnId: turn.id };
      }
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (
      message.includes("includeTurns is unavailable before first user message")
    ) {
      return { status, isRunning: false, turnId: null };
    }
    throw error;
  }
  return { status, isRunning: false, turnId: null };
}

async function providerReportsTerminalTurn(
  provider: AgentProvider,
  sessionId: string,
  turnId: string,
): Promise<boolean> {
  if (!hasProviderMethod(provider, "readSessionThread")) {
    return false;
  }
  let session: ThreadRecord;
  try {
    session = await readSession(provider, sessionId, true);
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (
      message.includes("includeTurns is unavailable before first user message")
    ) {
      return false;
    }
    throw error;
  }
  const turns = Array.isArray(session.turns) ? session.turns : [];
  const turn = turns.find((candidate) => candidate.id === turnId);
  if (!turn) {
    return false;
  }
  return turn.completedAt != null || isTerminalTurnStatus(turn.status);
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
  liveActivities: Map<string, Map<string, LiveActivityEntry>>,
  sessionId: string,
  activity: SessionActivity,
  allocReplaySeq: () => number,
): SessionActivity {
  const sessionActivities =
    liveActivities.get(sessionId) || new Map<string, LiveActivityEntry>();
  const existing = sessionActivities.get(activity.id);
  const merged = mergeActivity(existing?.activity, activity);
  sessionActivities.set(activity.id, {
    activity: merged,
    replaySeq: existing ? allocReplaySeq() : merged.seq,
  });
  liveActivities.set(sessionId, sessionActivities);
  return merged;
}

function materializeLiveActivityDraft(
  liveActivities: Map<string, Map<string, LiveActivityEntry>>,
  sessionId: string,
  draft: AgentSessionActivityDraft,
  allocSeq: () => number,
): SessionActivity {
  const existing = liveActivities.get(sessionId)?.get(draft.id)?.activity;
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
  liveActivities: Map<string, Map<string, LiveActivityEntry>>,
  sessionId: string,
  itemId: string,
  delta: string,
  allocReplaySeq: () => number,
): SessionActivity | null {
  const sessionActivities = liveActivities.get(sessionId);
  if (!sessionActivities) {
    return null;
  }

  const existing = sessionActivities.get(itemId);
  const activity = existing?.activity;
  if (!activity || (activity.type !== "command" && activity.type !== "tool")) {
    return null;
  }

  const updated = appendCommandActivityOutput(activity, delta);
  if (!updated) {
    return null;
  }

  sessionActivities.set(itemId, {
    activity: updated,
    replaySeq: allocReplaySeq(),
  });
  return updated;
}

function updateLiveCommandTerminalInteraction(
  liveActivities: Map<string, Map<string, LiveActivityEntry>>,
  sessionId: string,
  itemId: string,
  stdin: string,
  allocReplaySeq: () => number,
): SessionActivity | null {
  const sessionActivities = liveActivities.get(sessionId);
  if (!sessionActivities) {
    return null;
  }

  const existing = sessionActivities.get(itemId);
  const activity = existing?.activity;
  if (!activity || activity.type !== "command") {
    return null;
  }

  const updated = applyCommandTerminalInteraction(activity, stdin);
  if (!updated) {
    return null;
  }

  sessionActivities.set(itemId, {
    activity: updated,
    replaySeq: allocReplaySeq(),
  });
  return updated;
}

function liveActivityValues(
  sessionActivities: Map<string, LiveActivityEntry> | undefined,
): SessionActivity[] {
  if (!sessionActivities) {
    return [];
  }
  return [...sessionActivities.values()].map((entry) => entry.activity);
}

function filterActivitiesForReplay(
  activities: SessionActivity[],
  sessionActivities: Map<string, LiveActivityEntry> | undefined,
  since: number,
): { activities: SessionActivity[]; highestSeq: number } {
  const returned: SessionActivity[] = [];
  let highestSeq = since;
  for (const activity of activities) {
    const replaySeq = Math.max(
      activity.seq ?? 0,
      sessionActivities?.get(activity.id)?.replaySeq ?? 0,
    );
    if (replaySeq <= since) {
      continue;
    }
    returned.push(activity);
    if (replaySeq > highestSeq) {
      highestSeq = replaySeq;
    }
  }
  return {
    activities: returned,
    highestSeq,
  };
}

function mapSession(
  thread: ThreadRecord,
  runtime: SessionRuntimeSummary | null = null,
  statusOverride: LiveThreadStatus | null = null,
): SessionSummary {
  const provider = providerKindForThread(thread);
  return {
    id: thread.id,
    title: sanitizeTitle(thread.name || thread.preview),
    preview: thread.preview,
    cwd: thread.cwd,
    createdAt: threadTimestampMillis(thread.createdAt),
    updatedAt: threadTimestampMillis(thread.updatedAt),
    source:
      typeof thread.source === "string"
        ? thread.source
        : JSON.stringify(thread.source),
    provider,
    status: resolvedSessionStatus(thread, statusOverride),
    rolloutPath: thread.path,
    runtime,
    gitInfo: mapGitInfo(thread.gitInfo),
    isSubAgent: isSubAgentThreadSource(thread.source),
  };
}

function isSubAgentThreadSource(source: ThreadRecord["source"]): boolean {
  if (!source || typeof source !== "object") {
    return false;
  }
  const typed = source as Record<string, unknown>;
  return typed.subAgent != null || typed.subagent != null;
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

function hashLegacySessionInputSignature(
  input: AgentSessionInputItem[],
  overrides: AgentSessionOverrides,
): string {
  return hashSessionInputSignature(
    input.filter((item) => item.type !== "file"),
    overrides,
  );
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
  rawSignatureHash: string,
  createdAt: number,
  receipt: SessionInputReceipt,
): Promise<void> {
  const entry: StoredSessionInputDedupeEntry = {
    key,
    signatureHash,
    rawSignatureHash,
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

function parseTimestamp(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  if (typeof value === "string" && value.trim()) {
    const trimmed = value.trim();
    if (/^-?\d+$/.test(trimmed)) {
      const parsedInt = Number.parseInt(trimmed, 10);
      return Number.isFinite(parsedInt) ? parsedInt : null;
    }
    const parsed = Date.parse(trimmed);
    if (!Number.isNaN(parsed)) return parsed;
  }
  return null;
}

function threadTimestampMillis(value: number): number {
  const timestamp = Math.trunc(value);
  return timestamp >= 1_000_000_000_000 ? timestamp : timestamp * 1000;
}

function buildSubmittedUserMessage(
  input: AgentSessionInputItem[],
  clientMessageId: string | null,
  seq: number,
): SessionMessage {
  const text = buildSubmittedUserMessageText(input);
  return {
    id: clientMessageId || randomUUID(),
    role: "user",
    text,
    content: [{ type: "text", text }],
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

function isActiveTurnStatus(status: string | null | undefined): boolean {
  return status === "inProgress" || status === "in_progress";
}

function isTerminalTurnStatus(status: string | null | undefined): boolean {
  return (
    status === "completed" ||
    status === "failed" ||
    status === "interrupted" ||
    status === "error" ||
    status === "errored" ||
    status === "cancelled" ||
    status === "canceled"
  );
}

function isActiveThread(thread: ThreadRecord): boolean {
  return isRunningThreadStatus(threadStatusPhase(thread));
}

function resolvedSessionStatus(
  thread: ThreadRecord,
  statusOverride: LiveThreadStatus | null = null,
): string {
  return statusOverride ?? threadStatusPhase(thread);
}

function threadStatusPhase(thread: ThreadRecord): LiveThreadStatus {
  return normalizeThreadStatusPhase(thread.status?.phase ?? thread.status?.type);
}

function isRunningThreadStatus(status: LiveThreadStatus | null | undefined): boolean {
  return (
    status === "running" ||
    status === "waiting_for_input" ||
    status === "waiting_for_approval"
  );
}

function isTerminalThreadStatus(status: LiveThreadStatus | null | undefined): boolean {
  return status === "closed" || status === "errored";
}

function normalizeThreadStatusPhase(status: string | null | undefined): LiveThreadStatus {
  switch (status) {
    case "idle":
      return "idle";
    case "running":
    case "active":
      return "running";
    case "waiting_for_input":
      return "waiting_for_input";
    case "waiting_for_approval":
      return "waiting_for_approval";
    case "errored":
    case "systemError":
      return "errored";
    case "closed":
    case "notLoaded":
      return "closed";
    default:
      return "unknown";
  }
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

function updateSessionLogCacheLatestPlanUpdate(
  logCache: Map<string, SessionLogCacheEntry>,
  sessionId: string,
  latestPlanUpdate: LatestPlanUpdate | null,
): void {
  const prefix = `${sessionId}::`;
  for (const [key, entry] of logCache) {
    if (!key.startsWith(prefix)) {
      continue;
    }
    entry.latestPlanUpdate = latestPlanUpdate;
    entry.nextSeq = nextSeqForLatestPlanUpdate(entry.nextSeq, latestPlanUpdate);
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

function normalizeLatestPlanUpdate(
  latestPlanUpdate: LatestPlanUpdate | null | undefined,
  sessionId?: string,
): LatestPlanUpdate | null {
  if (!latestPlanUpdate) {
    return null;
  }
  const normalizedSessionId = latestPlanUpdate.sessionId.trim() || sessionId?.trim() || "";
  if (!normalizedSessionId) {
    return null;
  }
  const plan = latestPlanUpdate.plan.filter(
    (step) => step.step.trim().length > 0 && step.status.trim().length > 0,
  );
  if (plan.length === 0) {
    return null;
  }
  return {
    type: "plan_updated",
    sessionId: normalizedSessionId,
    seq: latestPlanUpdate.seq,
    turnId: latestPlanUpdate.turnId?.trim() || undefined,
    explanation: latestPlanUpdate.explanation?.trim() || undefined,
    plan,
  };
}

function mergeLatestPlanUpdate(
  sessionId: string,
  ...candidates: Array<LatestPlanUpdate | null | undefined>
): LatestPlanUpdate | null {
  let best: LatestPlanUpdate | null = null;
  for (const candidate of candidates) {
    const normalized = normalizeLatestPlanUpdate(candidate, sessionId);
    if (normalized == null) {
      continue;
    }
    if (best == null) {
      best = normalized;
      continue;
    }
    const bestSeq = best.seq ?? -1;
    const nextSeq = normalized.seq ?? -1;
    if (nextSeq > bestSeq) {
      best = normalized;
    }
  }
  return best;
}

function isLatestPlanUpdateNewerThan(
  latestPlanUpdate: LatestPlanUpdate | null,
  since: number,
): latestPlanUpdate is LatestPlanUpdate {
  return latestPlanUpdate?.seq != null && latestPlanUpdate.seq > since;
}

function nextSeqForLatestPlanUpdate(
  nextSeq: number,
  latestPlanUpdate: LatestPlanUpdate | null,
): number {
  if (latestPlanUpdate?.seq == null) {
    return nextSeq;
  }
  return Math.max(nextSeq, latestPlanUpdate.seq + 1);
}

async function loadSessionRuntimeSignalsState(
  filePath: string,
): Promise<Map<string, SessionRuntimeSignalsEntry>> {
  try {
    const raw = await readFile(filePath, "utf8");
    const parsed = JSON.parse(raw) as {
      sessions?: Array<{
        sessionId?: string;
        updatedAt?: number;
        latestPlanUpdate?: LatestPlanUpdate | null;
      }>;
    };
    const loaded = new Map<string, SessionRuntimeSignalsEntry>();
    const now = Date.now();
    for (const item of parsed.sessions ?? []) {
      const sessionId = typeof item.sessionId === "string" ? item.sessionId.trim() : "";
      const latestPlanUpdate = normalizeLatestPlanUpdate(
        item.latestPlanUpdate ?? null,
        sessionId,
      );
      const updatedAt = typeof item.updatedAt === "number" ? item.updatedAt : now;
      if (!sessionId || latestPlanUpdate == null) {
        continue;
      }
      if (now - updatedAt > SESSION_RUNTIME_SIGNALS_TTL_MS) {
        continue;
      }
      loaded.set(sessionId, {
        latestPlanUpdate,
        updatedAt,
      });
    }
    while (loaded.size > SESSION_RUNTIME_SIGNALS_LIMIT) {
      const oldest = [...loaded.entries()].sort(
        (left, right) => left[1].updatedAt - right[1].updatedAt,
      )[0]?.[0];
      if (!oldest) {
        break;
      }
      loaded.delete(oldest);
    }
    return loaded;
  } catch {
    return new Map<string, SessionRuntimeSignalsEntry>();
  }
}

async function saveSessionRuntimeSignalsState(
  filePath: string,
  sessionRuntimeSignals: Map<string, SessionRuntimeSignalsEntry>,
): Promise<void> {
  await mkdir(nodePath.dirname(filePath), { recursive: true, mode: 0o700 });
  const now = Date.now();
  const sessions = [...sessionRuntimeSignals.entries()]
    .filter(([, entry]) => now - entry.updatedAt <= SESSION_RUNTIME_SIGNALS_TTL_MS)
    .sort((left, right) => right[1].updatedAt - left[1].updatedAt)
    .slice(0, SESSION_RUNTIME_SIGNALS_LIMIT)
    .flatMap(([sessionId, entry]) => {
      const latestPlanUpdate = normalizeLatestPlanUpdate(
        entry.latestPlanUpdate,
        sessionId,
      );
      if (latestPlanUpdate == null) {
        return [];
      }
      return [{
        sessionId,
        updatedAt: entry.updatedAt,
        latestPlanUpdate,
      }];
    });
  const tmpPath = `${filePath}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(
    tmpPath,
    JSON.stringify({ sessions }, null, 2),
    {
      encoding: "utf8",
      mode: 0o600,
    },
  );
  await rename(tmpPath, filePath);
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
  liveActivities: Map<string, Map<string, LiveActivityEntry>>,
  reconcileStatus?: (
    sessionId: string,
    observedStatus: LiveThreadStatus,
  ) => void,
): Promise<SessionResourcesResponse> {
  const session = await readSession(provider, sessionId, false);
  reconcileStatus?.(session.id, threadStatusPhase(session));
  const readLog = requireProviderMethod(
    provider,
    "readSessionLog",
    "session resources",
  );
  const log = await readLog.call(provider, session);
  const activities = mergeSessionActivities(
    log.activities,
    liveActivityValues(liveActivities.get(sessionId)),
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

function hasPendingActionForSession(
  pendingActions: Map<string, AgentPendingAction>,
  sessionId: string,
): boolean {
  for (const action of pendingActions.values()) {
    if (action.sessionId === sessionId) {
      return true;
    }
  }
  return false;
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

function parseUpdateChannel(value: unknown): UpdateChannel | null {
  const channel = asString(value);
  if (channel === "stable" || channel === "bleeding-edge") {
    return channel;
  }
  return null;
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
      case "file": {
        const path = asString(typed.path);
        if (!path) {
          continue;
        }
        items.push({
          type: "file",
          path,
          ...(typed.isDirectory === true ? { isDirectory: true } : {}),
        });
        break;
      }
      default:
        break;
    }
  }

  return items;
}

function hasFileInputItem(input: AgentSessionInputItem[]): boolean {
  return input.some((item) => item.type === "file");
}

async function resolveFileInputItemsForSession(
  provider: AgentProvider,
  sessionId: string,
  input: AgentSessionInputItem[],
): Promise<AgentSessionInputItem[]> {
  if (!hasFileInputItem(input)) {
    return input;
  }
  const thread = await readSession(provider, sessionId, false);
  if (!thread.cwd) {
    throw new WorkspaceAccessError(
      "session cwd is required for file mentions",
      400,
    );
  }
  return resolveFileInputItemsForCwd(input, thread.cwd);
}

async function resolveFileInputItemsForCwd(
  input: AgentSessionInputItem[],
  cwd: string,
): Promise<AgentSessionInputItem[]> {
  if (!hasFileInputItem(input)) {
    return input;
  }
  const workspaceRoot = nodePath.resolve(cwd);
  return Promise.all(
    input.map(async (item): Promise<AgentSessionInputItem> => {
      if (item.type !== "file") {
        return item;
      }
      const candidate = nodePath.isAbsolute(item.path)
        ? item.path
        : nodePath.resolve(workspaceRoot, item.path);
      const path = await resolveWorkspacePath(candidate, [workspaceRoot]);
      const info = await stat(path);
      if (!info.isFile() && !info.isDirectory()) {
        throw new WorkspaceAccessError(
          "file mention path must be a regular file or directory",
          400,
        );
      }
      return info.isDirectory()
        ? { type: "file", path, isDirectory: true }
        : { type: "file", path };
    }),
  );
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
    if (item.type === "file") {
      attachments.push({ type: "file", path: item.path });
    }
  }
  return attachments;
}

function measureSessionEventDelta(
  messages: SessionMessage[],
  activities: SessionActivity[],
  latestPlanUpdate: LatestPlanUpdate | null,
): { items: number; bytes: number } {
  return {
    items:
      messages.length +
      activities.length +
      (latestPlanUpdate == null ? 0 : 1),
    bytes: Buffer.byteLength(
      JSON.stringify({ messages, activities, latestPlanUpdate }),
      "utf8",
    ),
  };
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
