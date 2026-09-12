import { parseContentInput, contentInputAttachment } from "./input-content.js";
import { createServer } from "node:http";
import type { Server } from "node:http";
import { homedir, hostname, platform } from "node:os";
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import {
  chmod,
  mkdir,
  stat,
} from "node:fs/promises";
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

import { SessionCoordinator } from "./session-coordinator.js";
import {
  AgentProviderRequestError,
  hasProviderMethod,
  requireProviderMethod,
  type AgentPendingAction,
  type AgentProvider,
  type AgentProviderMethodName,
  type AgentProviderLiveEvent,
  type AgentSessionListOptions,
  type AgentSessionInputItem,
  type AgentSessionOverrides,
} from "./agent-provider.js";
import type {
  AgentRunSummary,
  ApprovalLiveEvent,
  GitInfoSummary,
  HostCapabilities,
  LiveEvent,
  LiveThreadStatus,
  NodeConfig,
  PendingAction,
  UpdateChannel,
  RecentSessionsLiveEvent,
  SessionMessageAttachment,
  SessionMessage,
  SessionResourcesResponse,
  SessionRuntimeSummary,
  SessionSubAgentInfo,
  SessionSummary,
  ThreadRecord,
  UsageObservation,
  UsageSnapshotResponse,
  WorkspaceSummary,
} from "./types.js";
import {
  parsePendingActionResponseBody,
  toPublicPendingAction,
} from "./approvals.js";
import {
  readGitCommonDir,
  readGitIdentity,
  readGitDiff,
  readGitStatus,
  sanitizeGitUrl,
} from "./git.js";
import {
  createAgentProviderRuntime,
  type AgentProviderRuntime,
  type AgentProviderRuntimeEntry,
} from "./provider-factory.js";
import { isAgentProviderKind } from "./provider-registry.js";
import { wrapProviderScopedId } from "./session-identity.js";
import { buildSessionResources } from "./resources.js";
import {
  FsWatchRegistry,
  attachFsLiveSocket,
  registerFsRoutes,
} from "./fs-routes.js";
import { registerHostResourceRoutes } from "./host-resource.js";
import {
  artifactReferencesMatch,
  registerSessionArtifactRoutes,
} from "./session-artifacts.js";
import {
  TerminalError,
  TerminalRegistry,
  normalizeTerminalShell,
} from "./terminal.js";
import {
  BrowserPreviewError,
  BrowserPreviewRegistry,
} from "./browser-preview.js";
import {
  WorkspaceAccessError,
  collectWorkspaceRoots,
  resolveWorkspacePath,
} from "./workspace-scope.js";
import { SessionStore } from "./session-store.js";
import { SessionInputError } from "./session-input-coordinator.js";
import { startupSummaryLines } from "./startup-summary.js";
import { getCodexRpcAuditSnapshot } from "./codex-rpc-audit.js";
import { SessionSearchIndex, type SearchFilter } from "./session-search-index.js";
import { saveConfig } from "./config.js";
import { detectInstallInfo } from "./install-info.js";
import { spawnSelfUpdater } from "./updater-spawn.js";
import {
  readUpdateStatus,
  UpdateAlreadyInProgressError,
} from "./update-status.js";
import { PushNotificationDispatcher } from "./push-notifications.js";
import { jsonResponse, readJsonBody, readQuery, type HonoServerEnv } from "./server-http.js";

const CLIENT_MESSAGE_ID_MAX_LENGTH = 128;
const CLIENT_MESSAGE_ID_PATTERN = /^[A-Za-z0-9._:-]+$/;
const RECENT_UNINDEXED_SESSION_SCAN_LIMIT = 50;
const RECENT_LIVE_LIMIT = 40;
const RECENT_SESSIONS_CACHE_TTL_MS = 1_500;
const INSTALL_INFO_REFRESH_TTL_MS = 60_000;
type SessionRuntimeListMode = "all" | "active" | "none";
const HOST_CAPABILITIES: HostCapabilities = {
  workspace: {
    filesystem: true,
    gitStatus: true,
    gitDiff: true,
    terminal: false,
    browserPreview: false,
  },
  sessions: {
    search: true,
  },
};

interface SessionHistorySummary {
  isTruncated: boolean;
  totalMessages: number;
  returnedMessages: number;
  totalActivities: number;
  returnedActivities: number;
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
  readUpdateStatus: typeof readUpdateStatus;
  exitProcess(code?: number): never;
}

const DEFAULT_START_SERVER_DEPENDENCIES: StartServerDependencies = {
  detectInstallInfo,
  spawnSelfUpdater,
  readUpdateStatus,
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
  await mkdir(config.stateDir, { recursive: true, mode: 0o700 });
  await chmod(config.stateDir, 0o700);
  let runtimeConfig = config;
  const sessionStore = await SessionStore.open(config.stateDir);
  let providerRuntime: AgentProviderRuntime;
  try { providerRuntime = prebuiltRuntime ?? createAgentProviderRuntime(config, sessionStore); }
  catch (error) { sessionStore.close(); throw error; }
  try { providerRuntime.attachStore(sessionStore); }
  catch (error) { sessionStore.close(); throw error; }
  let runningServerRef: RunningServer | null = null;
  let closing = false;
  let closingPromise: Promise<void> | null = null;
  const hostCapabilities: HostCapabilities = {
    ...HOST_CAPABILITIES,
    workspace: {
      ...HOST_CAPABILITIES.workspace,
      terminal: config.terminal.enabled,
      browserPreview: config.browserPreview.enabled,
    },
  };

  const app = new Hono<HonoServerEnv>();
  const server = createServer(getRequestListener(app.fetch));
  const socketsBySession = new Map<string, Set<WebSocket>>();
  const sessionSocketAliases = new WeakMap<WebSocket, string>();
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
  const sessionState = new SessionCoordinator(sessionStore, {
    readSnapshot: async (id, options) => {
      const resolved = providerRuntime.resolveSession(id);
      const provider = await providerRuntime.ensure(resolved.entry);
      const snapshot = await requireProviderMethod(provider, "readSessionSnapshot", "session snapshot")
        .call(provider, resolved.rawId, { ...options, requireNativeHistory: sessionStore.hasUncertainInputs(id) });
      return { ...snapshot, latestPlanUpdate: snapshot.latestPlanUpdate ? { ...snapshot.latestPlanUpdate, sessionId: resolved.sessionId } : null,
        thread: providerRuntime.wrapThread(resolved.entry, snapshot.thread) };
    },
    publish: publishSessionEvent,
    input: {
      canSteer: (id) => providerEntryForSessionId(id)?.capabilities.input.steer !== false,
      prepare: async (id, payload) => ({ ...payload,
        input: await resolveFileInputItemsForSession(providerRuntime, id, payload.input) }),
      dispatch: async (request) => {
        const resolved = providerRuntime.resolveSession(request.sessionId);
        const provider = await providerRuntime.ensure(resolved.entry);
        return requireProviderMethod(provider, "submitInput", "session input").call(provider, { ...request, sessionId: resolved.rawId });
      },
      submitted: async (request, receipt) => {
        broadcastLive(request.sessionId, { type: "user_message_submitted", sessionId: request.sessionId,
          turnId: receipt.turnId ?? undefined,
          messageItem: buildSubmittedUserMessage(request.input, receipt.messageId, allocSeq(request.sessionId)) });
        scheduleRecentSessionUpsert(request.sessionId, 0);
      },
    },
  });
  const pendingActions = sessionState.pendingActions;
  const inputs = sessionState.inputs;
  const searchIndex = new SessionSearchIndex(
    nodePath.join(config.stateDir, "search-index-v1.db"),
  );
  await searchIndex.open();
  const pushNotifications = await PushNotificationDispatcher.open(
    config.stateDir,
  );
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
      resolveTerminalCwd(
        providerRuntime,
        sessionState,
        cwd,
        request.sessionId,
        config.workspaceRoots,
      ),
  });
  if (terminalRegistry.isEnabled()) providerRuntime.attachHostServices({
    runAuthenticationTerminal: (request) => terminalRegistry.runAuthentication(request),
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

  function allocSeq(sessionId: string): number { return sessionState.allocSeq(sessionId); }

  async function clearInterruptedSessionInputDedupe(
    interruptedTurnIds: Map<string, string>,
  ): Promise<void> {
    sessionStore.clearInterruptedInputs(interruptedTurnIds);
  }


  function providerEntryForSessionId(sessionId: string) {
    return providerRuntime.providerForSessionId(sessionId);
  }

  async function startedProviderForKind(id: string | null | undefined) {
    const entry = providerRuntime.providerForKind(id);
    return entry ? { ...entry, provider: await providerRuntime.ensure(entry) } : null;
  }

  async function startedSessionProvider(id: string) {
    const resolved = providerRuntime.resolveSession(id);
    return { ...resolved.entry, rawId: resolved.rawId, provider: await providerRuntime.ensure(resolved.entry) };
  }

  async function clearProviderScopedRuntimeState(kind: string): Promise<void> {
    const interruptedTurnIds = new Map<string, string>();
    for (const sessionId of sessionState.keys()) {
      const entry = providerEntryForSessionId(sessionId);
      if ((entry?.id ?? entry?.kind) !== kind) continue;
      const active = sessionState.get(sessionId).activeTurn;
      if (active) interruptedTurnIds.set(sessionId, active.turnId);
      sessionState.invalidate(sessionId);
      scheduleRecentSessionUpsert(sessionId, 0);
    }
    await clearInterruptedSessionInputDedupe(interruptedTurnIds);
    recentSessionsCache.clear();
  }

  async function getSessionCwd(sessionId: string): Promise<string | null> {
    const sessionProvider = await startedSessionProvider(sessionId);
    if (
      !sessionProvider ||
      !sessionProvider.provider.capabilities.sessions.history
    ) {
      return null;
    }
    const session = await readSession(
      providerRuntime,
      sessionId,
      false,
    ).catch(() => null);
    return session?.cwd || null;
  }

  function broadcastLive(sessionId: string, event: LiveEvent): LiveEvent {
    return sessionState.publish({ ...event, sessionId });
  }

  function publishSessionEvent(event: LiveEvent): void {
    if (closing) return;
    broadcast(socketsBySession, event.sessionId, event, sessionSocketAliases);
    if (event.type === "action_opened" && event.action) {
      broadcastApprovalLive({ type: "action_opened", action: event.action });
      void pushNotifications.enqueue({
        kind: event.action.kind === "user_input" || event.action.kind === "elicitation" ? "input_required" : "approval_required",
        sessionId: event.sessionId, actionId: event.action.id,
      });
    } else if (event.type === "action_resolved") {
      broadcastApprovalLive({ type: "action_resolved", actionId: event.actionId });
    } else if (event.type === "turn_completed") {
      void pushNotifications.enqueue({ kind: /error|fail/i.test(event.status ?? "") ? "turn_failed" : "turn_completed",
        sessionId: event.sessionId, turnId: event.turnId });
      void indexSessionForSearch(searchIndex, sessionState, event.sessionId).catch(() => {});
    }
    if (!["assistant_delta", "reasoning_delta", "activity_updated", "plan_updated", "provider_warning"].includes(event.type)) {
      scheduleRecentSessionUpsert(event.sessionId, 0);
    }
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
      if (event.source && providerEntryForSessionId(sessionId)?.id !== event.source) continue;
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
      providerRuntime,
      sessionState,
      limit,
      runtimeMode,
    );
    recentSessionsCache.set(cacheKey, {
      limit,
      runtimeMode,
      expiresAt: now + RECENT_SESSIONS_CACHE_TTL_MS,
      promise,
    });
    try {
      const value = await promise;
      if (recentSessionsCache.get(cacheKey)?.promise !== promise) return loadRecentSessions(limit, runtimeMode);
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
      const sessions = await loadRecentSessions(RECENT_LIVE_LIMIT, "active");
      const session = sessions.find((entry) => entry.id === sessionId);
      if (session) {
        broadcastRecentSessionsLive({ type: "upsert", session });
        return;
      }
      // Keep clients aligned to the same bounded recent window as the
      // snapshot route. If a session no longer belongs in that window,
      // remove any stale row instead of reintroducing it via a fallback read.
      broadcastRecentSessionsLive({ type: "remove", sessionId });
    } catch {
      try {
        const thread = await readSession(providerRuntime, sessionId, false);
        if (sessionSubAgentForThread(thread)) {
          broadcastRecentSessionsLive({ type: "remove", sessionId });
          return;
        }
        const [session] = await buildRecentSessionSummaries(sessionState, [thread]);
        broadcastRecentSessionsLive({ type: "upsert", session });
      } catch {
        // The session may have been archived/removed before we could refresh it.
      }
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

  const onProviderStderr = (line: string): void => { process.stderr.write(line); };
  providerRuntime.on("stderr", onProviderStderr);

  const fsWatchRegistry = new FsWatchRegistry();

  const onProviderLiveEvent = (event: AgentProviderLiveEvent): void => {
    if (event.type === "skills_changed") { broadcastSkillsChanged(socketsBySession); return; }
    if (event.type === "provider_warning" && !event.sessionId) { broadcastProviderWarning(event); return; }
    sessionState.handle(event);
  };
  providerRuntime.on("liveEvent", onProviderLiveEvent);

  const onProviderState = (entry: AgentProviderRuntimeEntry): void => {
    if (entry.state === "unavailable" || entry.state === "starting") void clearProviderScopedRuntimeState(entry.id);
    if (entry.state === "unavailable") broadcastProviderWarning({ level: "error",
      code: "provider_unavailable", message: `${entry.displayName}: ${entry.error}`, source: entry.id });
  };
  providerRuntime.on("state", onProviderState);

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
  app.use("*", cors({
    origin: (origin) =>
      isAllowedBrowserOrigin(origin, config.allowedBrowserOrigins) ? origin : null,
    allowHeaders: ["Authorization", "Content-Type", "Range"],
    exposeHeaders: [
      "Accept-Ranges",
      "Content-Length",
      "Content-Range",
      "ETag",
      "Last-Modified",
    ],
  }));
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

  app.get("/healthz", (c) => {
    return jsonResponse(c, { ok: true, label: config.label });
  });

  const authMiddleware = createMiddleware<HonoServerEnv>(async (c, next) => {
    if (isHealthCheckPath(c.req.path)) {
      await next();
      return;
    }
    const auth = c.req.header("Authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
    if (!secretsEqual(token, config.token)) {
      throw new HTTPException(401, { message: "unauthorized" });
    }
    await next();
  });
  app.use("*", authMiddleware);
  app.use("/api/sessions/:sessionId/*", async (c, next) => {
    if (c.req.path.split("/").length < 5) { await next(); return; }
    const alias = c.req.param("sessionId");
    const canonical = providerRuntime.resolveSession(alias).sessionId;
    await next();
    if (alias === canonical || !c.res.headers.get("content-type")?.includes("application/json")) return;
    const body = JSON.stringify(withSessionAlias(await c.res.clone().json(), canonical, alias));
    const headers = new Headers(c.res.headers);
    headers.set("content-length", String(Buffer.byteLength(body)));
    c.header("content-length", String(Buffer.byteLength(body)));
    c.res = new Response(body, { status: c.res.status, statusText: c.res.statusText, headers });
  });
  registerHostResourceRoutes(app);

  app.get("/api/node", (c) => {
    const defaultProvider = providerRuntime.defaultProvider;
    const defaultProviderCapabilities = defaultProvider.capabilities;
    const supportedProviders = providerRuntime.providers.map((entry) => ({
      ...entry.definitionSummary,
      id: entry.id ?? entry.kind,
      config: entry.configSummary,
      capabilities: entry.capabilities,
      version: entry.version ?? "unknown",
      state: entry.state,
      error: entry.error,
      isDefault: entry === providerRuntime.defaultProvider,
    }));
    return jsonResponse(c, {
      label: config.label,
      hostname: hostname(),
      platform: platform(),
      homeDirectory: homedir(),
      provider: providerRuntime.defaultProviderKind,
      providerId: providerRuntime.defaultProviderId ?? providerRuntime.defaultProviderKind,
      providerName:
        supportedProviders.find((item) => item.isDefault)?.displayName ??
        defaultProvider.displayName,
      providerVersion: defaultProvider.version ?? "unknown",
      providerConfig: defaultProvider.configSummary,
      defaultProviderCapabilities,
      hostCapabilities,
      searchSessions: hostCapabilities.sessions.search,
      searchIndexStats: searchIndex.getStats(),
      supportedProviders,
      sessionAliases: providerRuntime.sessionAliases,
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
  });

  app.post(
    "/api/admin/update-check",
    async (c) => {
      const result = await refreshInstallInfo({ force: true });
      return jsonResponse(c, updateInfoPayload(result));
    },
  );

  app.get(
    "/api/admin/update-status",
    async (c) => {
      return jsonResponse(c, {
        ok: true,
        update: await dependencies.readUpdateStatus(runtimeConfig.stateDir),
      });
    },
  );

  app.get("/api/providers", (c) => {
    return jsonResponse(c, {
      currentProvider: providerRuntime.defaultProviderKind,
      currentProviderId: providerRuntime.defaultProviderId,
      sessionAliases: providerRuntime.sessionAliases,
      providers: providerRuntime.providers.map((entry) => ({
        ...entry.definitionSummary,
        id: entry.id ?? entry.kind,
        config: entry.configSummary,
        capabilities: entry.capabilities,
        version: entry.version ?? "unknown",
      state: entry.state,
      error: entry.error,
        isDefault: entry === providerRuntime.defaultProvider,
      })),
    });
  });

  app.get("/api/push/subscriptions", (c) => {
    return jsonResponse(c, { subscriptions: pushNotifications.listSubscriptions() });
  });

  app.post(
    "/api/push/subscriptions",
    async (c) => {
      const body = await readJsonBody(c);
      const installationId = asString(body?.installationId);
      const hostId = asString(body?.hostId);
      const relayUrl = asString(body?.relayUrl);
      const publishToken = asString(body?.publishToken);
      if (!installationId || !hostId || !relayUrl || !publishToken) {
        return jsonResponse(c, { error: "invalid push subscription" }, 400);
      }
      try {
        const subscription = await pushNotifications.upsertSubscription({
          installationId,
          hostId,
          relayUrl,
          publishToken,
        });
        return jsonResponse(c, { ok: true, subscription });
      } catch (error) {
        return jsonResponse(c, {
          error:
            error instanceof Error
              ? error.message
              : "invalid push subscription",
        }, 400);
      }
    },
  );

  app.delete(
    "/api/push/subscriptions/:installationId",
    async (c) => {
      const installationId = (c.req.param("installationId") ?? "");
      const removed = await pushNotifications.removeSubscription(installationId);
      return jsonResponse(c, { ok: removed }, removed ? 200 : 404);
    },
  );

  app.get(
    "/api/usage",
    async (c) => {
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
      return jsonResponse(c, payload);
    },
  );

  app.get("/api/diagnostics", (c) => {
    let sessionLiveSockets = 0;
    for (const sockets of socketsBySession.values()) {
      sessionLiveSockets += sockets.size;
    }
    let liveActivityItems = 0;
    for (const { activities } of sessionState.values()) {
      liveActivityItems += activities.size;
    }

    return jsonResponse(c, {
      label: config.label,
      hostname: hostname(),
      platform: platform(),
      uptimeSeconds: Math.round(process.uptime()),
      provider: providerRuntime.defaultProviderKind,
      providerId: providerRuntime.defaultProviderId ?? providerRuntime.defaultProviderKind,
      memory: process.memoryUsage(),
      resourceUsage: process.resourceUsage(),
      caches: {
        recentSessions: recentSessionsCache.size,
        recentSessionBroadcastTimers: recentSessionBroadcastTimers.size,
        sessions: sessionState.size,
        activeTurns: [...sessionState.values()].filter((state) => state.activeTurn).length,
        pendingActions: pendingActions.size,
        liveActivityItems,
        inputDedupe: sessionStore.inputCount(),
      },
      sockets: {
        sessionRooms: socketsBySession.size,
        sessionLiveSockets,
        approvalLiveSockets: approvalSockets.size,
        recentSessionsLiveSockets: recentSessionsSockets.size,
      },
      features: {
        terminals: terminalRegistry.list().length,
        browserPreviews: browserPreviewRegistry.list().length,
      },
    });
  });

  app.get("/api/debug/codex-rpc-audit", (c) => {
    return jsonResponse(c, getCodexRpcAuditSnapshot());
  });

  app.post(
    "/api/admin/provider/:kind/restart",
    async (c) => {
      const kind = c.req.param("kind");
      const selectedProvider = providerRuntime.providerForKind(kind);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider kind" }, 400);
      }
      await providerRuntime.restart(selectedProvider);
      await clearProviderScopedRuntimeState(selectedProvider.id ?? selectedProvider.kind);
      return jsonResponse(c, { ok: true, kind });
    },
  );

  app.post("/api/admin/provider/:kind/logout", async (c) => {
    const selected = providerRuntime.providerForKind(c.req.param("kind"));
    if (!selected) return jsonResponse(c, { error: "unknown provider kind" }, 400);
    const provider = await providerRuntime.ensure(selected);
    requireProviderCapability(provider, provider.capabilities.lifecycle.logout === true, "sign-out", "logout");
    await requireProviderMethod(provider, "logout", "sign-out").call(provider);
    return jsonResponse(c, { ok: true });
  });

  app.post(
    "/api/admin/restart",
    async (c) => {
      const response = jsonResponse(c, { ok: true, message: "daemon is restarting" });
      setTimeout(async () => {
        try {
          await runningServerRef!.close();
        } finally {
          dependencies.exitProcess(0);
        }
      }, 100);
      return response;
    },
  );

  app.post(
    "/api/admin/update-channel",
    async (c) => {
      const body = await readJsonBody(c);
      const requestedChannel = parseUpdateChannel(body?.channel);
      if (requestedChannel === null) {
        return jsonResponse(c, { error: "channel must be stable or bleeding-edge" }, 400);
      }

      const nextConfig: NodeConfig = {
        ...runtimeConfig,
        updateChannel: requestedChannel,
        configExists: true,
      };
      await saveConfig(nextConfig, { configPath: nextConfig.configPath });
      runtimeConfig = nextConfig;

      const result = await refreshInstallInfo({ force: true });

      return jsonResponse(c, {
        ...updateInfoPayload(result),
        ok: true,
      });
    },
  );

  app.post(
    "/api/admin/update",
    async (c) => {
      const body = await readJsonBody(c);
      const requestedChannelRaw = body?.channel;
      const requestedChannel =
        requestedChannelRaw === undefined
          ? null
          : parseUpdateChannel(requestedChannelRaw);
      if (requestedChannelRaw !== undefined && requestedChannel === null) {
        return jsonResponse(c, { error: "channel must be stable or bleeding-edge" }, 400);
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
        return jsonResponse(c, { error: "update not supported for this install type" }, 501);
      }

      let update;
      try {
        update = await dependencies.spawnSelfUpdater(runtimeConfig, {
          updateChannel: requestedChannel,
        });
      } catch (error) {
        if (error instanceof UpdateAlreadyInProgressError) {
          return jsonResponse(c, {
            error: error.message,
            updateId: error.updateId,
          }, 409);
        }
        throw error;
      }

      return jsonResponse(c, { ok: true, message: "daemon is updating", update });
    },
  );

  app.get(
    "/api/sessions",
    async (c) => {
      if (!providerRuntime.providers.some((entry) => entry.capabilities.sessions.history)) {
        return jsonResponse(c, { error: "No provider supports session history" }, 501);
      }
      const requestedLimit = asInteger(
        readQuery(c)?.limit,
      );
      const runtimeMode = parseSessionRuntimeListMode(
        readQuery(c)?.runtime,
      );
      const sessions = await loadRecentSessions(requestedLimit, runtimeMode);
      return jsonResponse(c, sessions);
    },
  );

  app.get(
    "/api/sessions/search",
    async (c) => {
      if (!hostCapabilities.sessions.search) {
        return jsonResponse(c, { error: "Session search is not available" }, 503);
      }
      const query = readQuery(c);
      const rawQuery = asString(query.q);
      const normalizedQuery = rawQuery?.trim() ?? "";
      const limit = Math.max(1, Math.min(
        asInteger(query.limit) ?? 20,
        100,
      ));
      if (normalizedQuery.length < 2) {
        const hasFilters =
          asString(query.providerId) ||
          asString(query.provider) ||
          asString(query.cwd) ||
          query.archived !== undefined ||
          asString(query.updatedAfter) ||
          asString(query.updatedBefore);
        if (!hasFilters) {
          return jsonResponse(c, { error: "Query must be at least 2 characters" }, 400);
        }
      }
      const filter: SearchFilter = { providerIds: providerRuntime.providers.map((entry) => entry.id) };
      const providerId = asString(query.providerId);
      if (providerId) filter.providerId = providerId;
      const providerFilter = asString(query.provider);
      if (providerFilter) {
        filter.providerKind = providerFilter;
      }
      const cwdFilter = asString(query.cwd);
      if (cwdFilter) {
        filter.cwd = cwdFilter;
      }
      const archivedFilter = query.archived;
      if (archivedFilter === "true") {
        filter.archived = true;
      } else if (archivedFilter === "false") {
        filter.archived = false;
      } else {
        filter.archived = false;
      }
      const updatedAfter = parseTimestamp(query.updatedAfter);
      if (updatedAfter != null) {
        filter.updatedAfter = updatedAfter;
      }
      const updatedBefore = parseTimestamp(query.updatedBefore);
      if (updatedBefore != null) {
        filter.updatedBefore = updatedBefore;
      }
      await ensureSearchBackfill();
      const searchResults = await searchIndex.search(normalizedQuery, limit, filter);
      const sessions = searchResults.map((result) => ({
        ...sessionState.projectSummary(result.session), matchSnippet: result.snippet, matchRank: result.rank,
      }));
      return jsonResponse(c, sessions);
    },
  );

  app.get(
    "/api/sessions/:sessionId/agent-runs",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "agent runs", "listSessionThreads");
      const requestedLimit = Math.max(
        1,
        Math.min(
          asInteger(readQuery(c)?.limit) ?? 100,
          200,
        ),
      );
      const threads = await listProviderThreads(providerRuntime, {
        limit: requestedLimit, archived: false, includeSubAgents: true, subAgentParentId: sessionId,
      });
      const runs = threads
        .map(mapAgentRun)
        .filter(
          (run): run is AgentRunSummary =>
            run != null && run.parentSessionId === sessionId,
        )
        .sort((left, right) => right.updatedAt - left.updatedAt)
        .slice(0, requestedLimit);
      return jsonResponse(c, runs);
    },
  );

  app.get(
    "/api/workspaces",
    async (c) => {
      if (!providerRuntime.providers.some((entry) => entry.capabilities.sessions.history)) {
        return jsonResponse(c, { error: "No provider supports workspace history" }, 501);
      }
      const sessions = await loadRecentSessions(null, "none");
      return jsonResponse(c, buildWorkspaces(sessions));
    },
  );

  registerFsRoutes(app, {
    listSessions: () =>
      listSessions(
        providerRuntime,
        sessionState,
        null,
        "none",
      ),
    getSessionCwd,
    workspaceRoots: config.workspaceRoots,
  });
  registerSessionArtifactRoutes(app, {
    stateDir: config.stateDir,
    isReferenced: async (sessionId, source) => {
      const sessionProvider = await startedSessionProvider(sessionId);
      if (
        !sessionProvider ||
        !sessionProvider.provider.capabilities.sessions.history ||
        !hasProviderMethod(sessionProvider.provider, "readSessionLog")
      ) {
        return false;
      }
      const resources = await readSessionResources(
        sessionId,
        sessionState,
      );
      return resources.resources.some(
        (resource) =>
          (resource.path != null &&
            artifactReferencesMatch(resource.path, source)) ||
          (resource.url != null &&
            artifactReferencesMatch(resource.url, source)),
      );
    },
  });

  app.get("/api/terminals", (c) => {
    requireHostCapability(hostCapabilities.workspace.terminal, "integrated terminal");
    return jsonResponse(c, { terminals: terminalRegistry.list() });
  });

  app.post(
    "/api/terminals",
    async (c) => {
      const body = await readJsonBody(c);
      requireHostCapability(hostCapabilities.workspace.terminal, "integrated terminal");
      const cwd = asString(body?.cwd);
      if (!cwd) {
        return jsonResponse(c, { error: "cwd is required" }, 400);
      }
      const terminal = await terminalRegistry.create({
        cwd,
        title: asString(body?.title),
        sessionId: asString(body?.sessionId),
        cols: asInteger(body?.cols),
        rows: asInteger(body?.rows),
        replaceExisting: body?.replaceExisting === true,
      });
      return jsonResponse(c, terminal, 201);
    },
  );

  app.post(
    "/api/terminals/:terminalId/resize",
    async (c) => {
      const body = await readJsonBody(c);
      requireHostCapability(hostCapabilities.workspace.terminal, "integrated terminal");
      const terminalId = (c.req.param("terminalId") ?? "");
      return jsonResponse(c, terminalRegistry.resize(
          terminalId,
          asInteger(body?.cols),
          asInteger(body?.rows),
        ));
    },
  );

  app.post(
    "/api/terminals/:terminalId/kill",
    async (c) => {
      requireHostCapability(hostCapabilities.workspace.terminal, "integrated terminal");
      return jsonResponse(c, terminalRegistry.kill((c.req.param("terminalId") ?? "")));
    },
  );

  app.get("/api/browser-previews", (c) => {
    requireHostCapability(hostCapabilities.workspace.browserPreview, "browser");
    return jsonResponse(c, { previews: browserPreviewRegistry.list() });
  });

  app.post(
    "/api/browser-previews",
    async (c) => {
      const body = await readJsonBody(c);
      requireHostCapability(hostCapabilities.workspace.browserPreview, "browser");
      const preview = await browserPreviewRegistry.create({
        targetPort: asInteger(body?.targetPort),
        targetHost: asString(body?.targetHost),
        targetUrl: asString(body?.targetUrl),
        scheme: asString(body?.scheme),
        label: asString(body?.label),
        cwd: asString(body?.cwd),
        sessionId: asString(body?.sessionId),
        width: asInteger(body?.width),
        height: asInteger(body?.height),
        profileMode: asString(body?.profileMode),
        reuseExisting: asBoolean(body?.reuseExisting),
      });
      return jsonResponse(c, preview, 201);
    },
  );

  app.delete(
    "/api/browser-previews/:previewId",
    async (c) => {
      requireHostCapability(hostCapabilities.workspace.browserPreview, "browser");
      return jsonResponse(c, await browserPreviewRegistry.stop((c.req.param("previewId") ?? "")));
    },
  );

  app.get(
    "/api/actions",
    async (c) => {
      return jsonResponse(c, await listPendingActions(
          providerRuntime,
          pendingActions,
        ));
    },
  );

  app.get(
    "/api/sessions/:sessionId/log",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session history", "readSessionThread");
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session log", "readSessionLog");
      const query = readQuery(c);
      const messageLimit = Math.max(1, asInteger(query.messageLimit) ?? 200);
      const activityLimit = Math.max(1, asInteger(query.activityLimit) ?? 200);
      const snapshot = await sessionState.snapshot(sessionId, { messageLimit, activityLimit });
      return jsonResponse(c, {
        session: mapSession(snapshot.thread, snapshot.runtime, snapshot.status),
        revision: snapshot.revision,
        liveAssistantText: snapshot.liveAssistantText,
        liveAssistantReasoning: snapshot.liveAssistantReasoning,
        messages: snapshot.messages,
        activities: snapshot.activities,
        pendingAction: findPendingActionForSession(pendingActions, sessionId),
        history: buildSessionHistorySummary(snapshot.totalMessages, snapshot.messages.length,
          snapshot.totalActivities, snapshot.activities.length),
        latestPlanUpdate: snapshot.latestPlanUpdate,
      });
    },
  );

  app.get(
    "/api/sessions/:sessionId/resources",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session resources", "readSessionThread");
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session resources", "readSessionLog");
      return jsonResponse(c, await readSessionResources(
          sessionId,
          sessionState,
        ));
    },
  );

  app.get(
    "/api/sessions/:sessionId/status",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session status", "readSessionThread");
      const snapshot = await sessionState.snapshot(sessionId, { messageLimit: 1, activityLimit: 1 });
      return jsonResponse(c, { sessionId, status: snapshot.status, isRunning: snapshot.busy,
        activeTurnId: snapshot.activeTurnId,
        pendingAction: findPendingActionForSession(pendingActions, sessionId) });
    },
  );

  app.get(
    "/api/sessions/:sessionId/git",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session history", "readSessionThread");
      requireHostCapability(HOST_CAPABILITIES.workspace.gitStatus, "git status");
      const session = await readSession(providerRuntime, sessionId, false);
      return jsonResponse(c, await readGitStatus(session.cwd, mapGitInfo(session.gitInfo)));
    },
  );

  app.get(
    "/api/sessions/:sessionId/git/diff",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      const kind = parseGitDiffKind(
        readQuery(c).kind,
      );
      if (!kind) {
        return jsonResponse(c, { error: "kind must be working, staged, unstaged, or remote" }, 400);
      }

      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session history", "readSessionThread");
      const session = await readSession(providerRuntime, sessionId, false);
      requireHostCapability(HOST_CAPABILITIES.workspace.gitDiff, "git diff");
      return jsonResponse(c, await readGitDiff(session.cwd, kind));
    },
  );

  app.get(
    "/api/skills",
    async (c) => {
      const query = readQuery(c);
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = await startedProviderForKind(agentProvider);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(selectedProvider.provider, selectedProvider.provider.capabilities.configuration.skills, "skill listing", "listSkills");
      const cwd = asString(query.cwd);
      if (!cwd) {
        return jsonResponse(c, { error: "cwd is required" }, 400);
      }

      const forceReload = parseQueryBool(query.forceReload);
      return jsonResponse(c, await selectedProvider.provider.listSkills!({ cwd, forceReload }));
    },
  );

  app.post(
    "/api/skills/config/write",
    async (c) => {
      const body = await readJsonBody(c);
      const requestedProvider = asString(body?.agentProvider) || null;
      const selectedProvider = await startedProviderForKind(requestedProvider);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(selectedProvider.provider, selectedProvider.provider.capabilities.configuration.skillManagement, "skill configuration", "writeSkillConfig");
      const path = asString(body?.path);
      const name = asString(body?.name);
      const enabled = parseOptionalBool(body?.enabled);
      if (enabled === null) {
        return jsonResponse(c, { error: "enabled is required" }, 400);
      }
      if ((path && name) || (!path && !name)) {
        return jsonResponse(c, { error: "provide exactly one of path or name" }, 400);
      }

      const result = await selectedProvider.provider.writeSkillConfig!({
        path,
        name,
        enabled,
      });
      return jsonResponse(c, result);
    },
  );

  app.get(
    "/api/modes",
    async (c) => {
      const query = readQuery(c);
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = await startedProviderForKind(agentProvider);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(selectedProvider.provider, selectedProvider.provider.capabilities.runtimeControls.mode, "mode listing", "listModes");
      if (!hasProviderMethod(selectedProvider.provider, "listModes")) {
        return jsonResponse(c, { error: "mode listing not supported" }, 501);
      }
      const cwd = asString(query.cwd) || null;
      return jsonResponse(c, await selectedProvider.provider.listModes({ cwd }));
    },
  );

  app.get(
    "/api/models",
    async (c) => {
      const query = readQuery(c);
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = await startedProviderForKind(agentProvider);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(selectedProvider.provider, selectedProvider.provider.capabilities.configuration.models, "model listing", "listModels");
      const cwd = asString(query.cwd) || null;
      const profile = asString(query.profile) || null;
      const modelProvider = asString(query.provider) || null;
      return jsonResponse(c, await selectedProvider.provider.listModels!({
          cwd,
          profile,
          provider: modelProvider,
        }));
    },
  );

  app.get(
    "/api/profiles",
    async (c) => {
      const query = readQuery(c);
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = await startedProviderForKind(agentProvider);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(selectedProvider.provider, selectedProvider.provider.capabilities.configuration.profiles, "profile listing", "listProfiles");
      const cwd = asString(query.cwd) || null;
      return jsonResponse(c, await selectedProvider.provider.listProfiles!({ cwd }));
    },
  );

  app.get(
    "/api/access-modes",
    async (c) => {
      const query = readQuery(c);
      const agentProvider = asString(query.agentProvider) || null;
      const selectedProvider = await startedProviderForKind(agentProvider);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(selectedProvider.provider, selectedProvider.provider.capabilities.configuration.accessModes, "access mode listing", "listAccessModes");
      const cwd = asString(query.cwd) || null;
      return jsonResponse(c, await selectedProvider.provider.listAccessModes!({ cwd }));
    },
  );

  app.post(
    "/api/sessions/create",
    async (c) => {
      const body = await readJsonBody(c);
      const requestedProvider = asString(body?.provider) || null;
      const selectedProvider = await startedProviderForKind(requestedProvider);
      if (!selectedProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(selectedProvider.provider, selectedProvider.provider.capabilities.sessions.create, "session creation", "createSession");
      const cwd = asString(body?.cwd);
      const input = parseInputItems(body?.input);
      const overrides = parseCreateSessionOverrides(body);
      if (!cwd) {
        return jsonResponse(c, { error: "cwd is required" }, 400);
      }
      const unsupportedOverride = unsupportedOverrideCapability(
        selectedProvider.provider,
        overrides,
      );
      if (unsupportedOverride) {
        return jsonResponse(c, { error: unsupportedOverride }, 501);
      }

      const unsupportedInput = unsupportedInputCapability(
        selectedProvider.provider,
        input,
      );
      if (unsupportedInput) {
        return jsonResponse(c, { error: unsupportedInput }, 501);
      }
      const scopedInput = await resolveFileInputItemsForCwd(
        input,
        cwd,
      );
      const clientMessageId = asString(body?.clientMessageId) || randomUUID();
      if (!isValidClientMessageId(clientMessageId)) {
        return jsonResponse(c, { error: "clientMessageId must be 1-128 URL-safe characters" }, 400);
      }
      const native = await selectedProvider.provider.createSession!({ cwd, input: [], overrides });
      const started = { ...native, thread: providerRuntime.wrapThread(selectedProvider, native.thread) };
      const inputOverrides = parseTurnOverrides(body);
      let receipt = null;
      try {
        if (scopedInput.length) receipt = await inputs.submit({
          key: `${started.thread.id}:${clientMessageId}`, sessionId: started.thread.id,
          signatureHash: hashSessionInputSignature(input, inputOverrides),
          payload: { input: scopedInput, overrides: inputOverrides },
        });
      } catch (error) {
        // Creation succeeded even when dispatch did not. Keep the recoverable session visible.
        return jsonResponse(c, {
          error: error instanceof Error ? error.message : String(error),
          session: mapSession(started.thread, started.runtime), clientMessageId,
          code: error instanceof SessionInputError ? error.code : "initial_input_failed",
        }, (error instanceof AgentProviderRequestError ? error.status : 502) as ContentfulStatusCode);
      }
      const response = jsonResponse(c, {
        session: sessionState.projectSummary(mapSession(started.thread, started.runtime)),
        activeTurnId: sessionState.get(started.thread.id).activeTurn?.turnId ?? null,
        input: receipt,
      }, 201);
      scheduleRecentSessionUpsert(started.thread.id, 0);
      void indexSessionForSearch(searchIndex, sessionState, started.thread.id).catch(() => {});
      return response;
    },
  );

  app.post(
    "/api/sessions/:sessionId/input",
    async (c) => {
      const body = await readJsonBody(c);
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, true, "session input submission", "submitInput");
      const input = parseInputItems(body?.input);
      const clientMessageId = asString(body?.clientMessageId);
      if (clientMessageId && !isValidClientMessageId(clientMessageId)) {
        return jsonResponse(c, {
          error: "clientMessageId must be 1-128 URL-safe characters",
        }, 400);
      }
      if (input.length === 0) {
        return jsonResponse(c, { error: "input is required" }, 400);
      }
      const unsupportedInput = unsupportedInputCapability(
        sessionProvider.provider,
        input,
      );
      if (unsupportedInput) {
        return jsonResponse(c, { error: unsupportedInput }, 501);
      }

      const turnOverrides = parseTurnOverrides(body);
      const unsupportedOverride = unsupportedOverrideCapability(
        sessionProvider.provider,
        turnOverrides,
      );
      if (unsupportedOverride) {
        return jsonResponse(c, { error: unsupportedOverride }, 501);
      }
      const inputSignatureHash = hashSessionInputSignature(
        input,
        turnOverrides,
      );
      const dedupeKey = `${sessionId}:${clientMessageId || randomUUID()}`;
      return jsonResponse(c, await inputs.submit({
        key: dedupeKey, sessionId, signatureHash: inputSignatureHash,
        payload: { input, overrides: turnOverrides },
      }));
    },
  );

  app.get("/api/sessions/:sessionId/configuration", async (c) => {
    const sessionId = providerRuntime.resolveSession(c.req.param("sessionId")).sessionId;
    const selected = await startedSessionProvider(sessionId);
    requireProviderCapability(selected.provider, selected.provider.capabilities.configuration.sessionOptions === true,
      "session configuration", "setSessionConfiguration");
    const snapshot = await sessionState.snapshot(sessionId, { messageLimit: 1, activityLimit: 1 });
    return jsonResponse(c, { runtime: snapshot.runtime });
  });

  app.post("/api/sessions/:sessionId/configuration", async (c) => {
    const sessionId = providerRuntime.resolveSession(c.req.param("sessionId")).sessionId;
    const selected = await startedSessionProvider(sessionId);
    requireProviderCapability(selected.provider, selected.provider.capabilities.configuration.sessionOptions === true,
      "session configuration", "setSessionConfiguration");
    const body = await readJsonBody(c);
    const optionId = asString(body?.optionId);
    const value = body?.value;
    if (!optionId || (typeof value !== "string" && typeof value !== "boolean")) {
      return jsonResponse(c, { error: "optionId and a string or boolean value are required" }, 400);
    }
    const runtime = await selected.provider.setSessionConfiguration!(selected.rawId, optionId, value);
    scheduleRecentSessionUpsert(sessionId, 0);
    return jsonResponse(c, { runtime });
  });

  app.post(
    "/api/sessions/:sessionId/stop",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.interrupt, "session interruption", "interruptTurn");
      let turnId: string | null = null;
      let stopped = false;
      await inputs.stop(sessionId, async () => {
        const state = await sessionState.snapshot(sessionId, { messageLimit: 1, activityLimit: 1 });
        turnId = state.activeTurnId;
        if (state.busy) {
          const result = await sessionProvider.provider.interruptTurn!(sessionProvider.rawId, turnId);
          stopped = !(result && typeof result === "object" && "interrupted" in result && result.interrupted === false);
        }
      });
      return jsonResponse(c, { stopped, turnId });
    },
  );

  app.post(
    "/api/sessions/:sessionId/compact",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.compact, "session compaction", "compactSession");
      const state = await sessionState.snapshot(sessionId, { messageLimit: 1, activityLimit: 1 });
      if (state.busy) {
        return jsonResponse(c, {
          error: "Cannot compact while a turn is running",
          turnId: state.activeTurnId,
        }, 409);
      }
      const result = await sessionProvider.provider.compactSession!(sessionProvider.rawId);

      const response = jsonResponse(c, { compacted: true, result: result ?? null });
      scheduleRecentSessionUpsert(sessionId, 0);
      return response;
    },
  );

  app.post(
    "/api/sessions/:sessionId/name",
    async (c) => {
      const body = await readJsonBody(c);
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.rename, "session renaming", "setSessionName");
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.history, "session history", "readSessionThread");
      const name = asString(body?.name);
      if (!name) {
        return jsonResponse(c, { error: "name is required" }, 400);
      }
      if (
        hasProviderMethod(sessionProvider.provider, "listLoadedSessionIds") &&
        !(await isThreadLoaded(sessionProvider.provider, sessionProvider.rawId))
      ) {
        requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.resume, "session resume", "resumeSessionThread");
        await sessionProvider.provider.resumeSessionThread!(sessionProvider.rawId, {
          persistExtendedHistory: true,
        });
      }
      await sessionProvider.provider.setSessionName!(sessionProvider.rawId, name);
      const thread = await readSession(providerRuntime, sessionId, false);
      const session = sessionState.projectSummary(mapSession(thread, thread.runtime ?? null));
      const response = jsonResponse(c, { session });
      scheduleRecentSessionUpsert(sessionId, 0);
      void indexSessionForSearch(searchIndex, sessionState, sessionId).catch(() => {});
      return response;
    },
  );

  app.post(
    "/api/sessions/:sessionId/archive",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.archive, "session archiving", "archiveSession");
      await inputs.stop(sessionId, async () => { await sessionProvider.provider.archiveSession!(sessionProvider.rawId); });
      sessionState.invalidate(sessionId);
      broadcastRecentSessionRemove(sessionId);
      void indexSessionForSearch(searchIndex, sessionState, sessionId, true).catch(() => {});
      return c.body(null, 200);
    },
  );

  app.post(
    "/api/sessions/:sessionId/unarchive",
    async (c) => {
      const sessionId = providerRuntime.resolveSession((c.req.param("sessionId") ?? "")).sessionId;
      const sessionProvider = await startedSessionProvider(sessionId);
      if (!sessionProvider) {
        return jsonResponse(c, { error: "unknown provider" }, 400);
      }
      requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.archive, "session unarchiving", "unarchiveSession");
      await sessionProvider.provider.unarchiveSession!(sessionProvider.rawId);
      const response = jsonResponse(c, { unarchived: true });
      scheduleRecentSessionUpsert(sessionId, 0);
      void indexSessionForSearch(searchIndex, sessionState, sessionId, false).catch(() => {});
      return response;
    },
  );

  app.delete("/api/sessions/:sessionId", async (c) => {
    const sessionId = providerRuntime.resolveSession(c.req.param("sessionId")).sessionId;
    const sessionProvider = await startedSessionProvider(sessionId);
    if (!sessionProvider) return jsonResponse(c, { error: "unknown provider" }, 400);
    requireProviderCapability(sessionProvider.provider, sessionProvider.provider.capabilities.sessions.delete === true,
      "session deletion", "deleteSession");
    await inputs.stop(sessionId, async () => {
      await sessionProvider.provider.deleteSession!(sessionProvider.rawId);
      await sessionState.deleteSessionView(sessionId);
      await searchIndex.remove(sessionId);
    });
    broadcastRecentSessionRemove(sessionId);
    return jsonResponse(c, { deleted: true });
  });

  app.post(
    "/api/actions/:actionId/respond",
    async (c) => {
      const body = await readJsonBody(c);
      const actionId = providerRuntime.resolveSession((c.req.param("actionId") ?? "")).sessionId;
      const action = pendingActions.get(actionId);
      if (!action) {
        return jsonResponse(c, { error: "action not found" }, 404);
      }
      const decision = parsePendingActionResponseBody(body, action);
      if (!decision) {
        return jsonResponse(c, { error: "invalid action response" }, 400);
      }

      const resolved = providerRuntime.resolveSession(action.sessionId);
      const actionReference = providerRuntime.resolveSession(action.id);
      if (actionReference.providerId !== resolved.providerId) throw new AgentProviderRequestError("Action owner does not match session owner", 409);
      const provider = await providerRuntime.ensure(resolved.entry);
      const handled = requireProviderMethod(provider, "respondToPendingAction", "pending action responses").call(provider,
        { ...action, id: actionReference.rawId, sessionId: resolved.rawId }, decision);
      if (!handled) {
        return jsonResponse(c, { error: "unsupported decision" }, 400);
      }

      sessionState.handle({ type: "action_resolved", sessionId: action.sessionId, actionId });
      return jsonResponse(c, { ok: true });
    },
  );

  const wsServer = new WebSocketServer({
    noServer: true,
    maxPayload: 1024 * 1024,
    perMessageDeflate: false,
    handleProtocols: (protocols) =>
      protocols.has("sidemesh") ? "sidemesh" : false,
  });
  server.on("upgrade", (request, socket, head) => {
    const [pathOnly, queryString] = (request.url || "").split("?");
    const terminalLiveMatch = /^\/api\/terminals\/([^/]+)\/live$/.exec(
      pathOnly,
    );
    const browserPreviewMatch =
      /^\/api\/browser-previews\/([^/]+)\/live$/.exec(pathOnly);
    if (
      pathOnly !== "/api/live" &&
      pathOnly !== "/api/sessions/live" &&
      pathOnly !== "/api/fs/live" &&
      pathOnly !== "/api/actions/live" &&
      !terminalLiveMatch &&
      !browserPreviewMatch
    ) {
      socket.destroy();
      return;
    }

    const origin = request.headers.origin;
    if (
      origin &&
      !isAllowedBrowserOrigin(origin, config.allowedBrowserOrigins)
    ) {
      socket.destroy();
      return;
    }

    const authHeader = request.headers.authorization;
    const token = authHeader?.startsWith("Bearer ")
      ? authHeader.slice("Bearer ".length)
      : tokenFromWebSocketProtocols(request.headers["sec-websocket-protocol"]);
    if (!secretsEqual(token, config.token)) {
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
              providerRuntime,
              sessionState,
              null,
              "none",
            ),
          getSessionCwd,
          sessionId: params.get("sessionId"),
          workspaceRoots: config.workspaceRoots,
        });
      });
      return;
    }

    if (pathOnly === "/api/actions/live") {
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        approvalSockets.add(ws);
        sendEvent(ws, { type: "hello" });
        void listPendingActions(providerRuntime, pendingActions)
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
      if (!providerRuntime.providers.some((entry) => entry.capabilities.sessions.history)) {
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
      const alias = params.get("sessionId");
      if (!alias || alias.length > 1024) {
      socket.destroy();
      return;
    }
      let sessionId: string;
      try { sessionId = providerRuntime.resolveSession(alias).sessionId; }
      catch { socket.destroy(); return; }

      wsServer.handleUpgrade(request, socket, head, (ws) => {
        sessionSocketAliases.set(ws, alias);
        const set = socketsBySession.get(sessionId) || new Set<WebSocket>();
        set.add(ws);
        socketsBySession.set(sessionId, set);
        void providerRuntime.ensure(providerRuntime.resolveSession(sessionId).entry).catch(() => undefined);
        sendEvent(ws, {
          type: "hello",
          sessionId: alias,
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
    if (error instanceof SessionInputError) {
      return c.json({ error: message, code: error.code }, error.status as ContentfulStatusCode);
    }
    if (
      error instanceof AgentProviderRequestError ||
      error instanceof TerminalError ||
      error instanceof WorkspaceAccessError ||
      error instanceof BrowserPreviewError
    ) {
      return c.json({ error: message }, error.status as ContentfulStatusCode);
    }
    console.error("[Error]", error);
    return c.json({ error: "Internal server error" }, 500);
  });

  await listen(server, config.port);
  inputs.recover();

  let searchIndexBackfill: Promise<void> | null = null;
  function ensureSearchBackfill(): Promise<void> {
    searchIndexBackfill ??= (async () => {
      searchIndex.setBackfillRunning(true);
      try {
        for (const entry of providerRuntime.providers) {
          if (closing) break;
          if (!entry.capabilities.sessions.history) continue;
          searchIndex.setProviderError(entry.id, null);
          try {
            const provider = await providerRuntime.ensure(entry);
            if (!hasProviderMethod(provider, "listSessionThreads") || !hasProviderMethod(provider, "readSessionSnapshot")) continue;
            for (const archived of [false, true]) {
              const threads = await provider.listSessionThreads({ limit: 200, archived, includeSubAgents: false });
              for (const thread of threads) {
                if (closing) break;
                const sessionId = wrapProviderScopedId(entry.id, thread.id);
                if (sessionSubAgentForThread(thread)) { await searchIndex.remove(sessionId); continue; }
                await indexSessionForSearch(searchIndex, sessionState, sessionId, archived);
              }
            }
          } catch (error) {
            searchIndex.setProviderError(entry.id, error instanceof Error ? error.message : String(error), entry.kind);
          }
        }
      } finally { searchIndex.setBackfillRunning(false); }
    })();
    return searchIndexBackfill;
  }

  for (const line of startupSummaryLines({
    config,
    providerDisplayName: providerRuntime.defaultProvider.displayName,
    providerKinds: providerRuntime.providers.map((entry) => entry.kind),
  })) {
    console.log(line);
  }

  let healthMonitor: NodeJS.Timeout | null = null;
  let healthMonitorStopped = false;
  const runHealthMonitor = async (): Promise<void> => {
    await providerRuntime.checkHealth();
    if (!healthMonitorStopped) healthMonitor = setTimeout(() => void runHealthMonitor(), 30_000);
  };
  healthMonitor = setTimeout(() => void runHealthMonitor(), 30_000);

  const boundAddress = server.address();
  const boundPort = typeof boundAddress === "string" ? 0 : (boundAddress?.port ?? 0);

  runningServerRef = {
    port: boundPort,
    close: () => closingPromise ??= (async () => {
      closing = true;
      inputs.close();
      const httpClosing = closeHttpServer(server);
      void httpClosing.catch(() => {});
      healthMonitorStopped = true;
      if (healthMonitor) clearTimeout(healthMonitor);
      terminalRegistry.dispose();
      for (const socket of wsServer.clients) socket.close();
      for (const timer of recentSessionBroadcastTimers.values()) clearTimeout(timer);
      recentSessionBroadcastTimers.clear();
      const stopped = await Promise.allSettled([providerRuntime.close(), browserPreviewRegistry.dispose(),
        closeWebSocketServer(wsServer), httpClosing, inputs.drain(), searchIndexBackfill]);
      providerRuntime.off("liveEvent", onProviderLiveEvent);
      providerRuntime.off("stderr", onProviderStderr);
      providerRuntime.off("state", onProviderState);
      await sessionState.drain();
      const flushed = await Promise.allSettled([searchIndex.close(), pushNotifications.close(), Promise.resolve().then(() => sessionStore.close())]);
      const errors = [...stopped, ...flushed].flatMap((result) => result.status === "rejected" ? [result.reason] : []);
      if (errors.length) throw new AggregateError(errors, "Host shutdown did not finish cleanly");
    })(),
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


function secretsEqual(candidate: string, expected: string): boolean {
  const candidateDigest = createHash("sha256").update(candidate).digest();
  const expectedDigest = createHash("sha256").update(expected).digest();
  return timingSafeEqual(candidateDigest, expectedDigest);
}

function tokenFromWebSocketProtocols(header: string | undefined): string {
  const prefix = "sidemesh.auth.";
  const encoded = header
    ?.split(",")
    .map((value) => value.trim())
    .find((value) => value.startsWith(prefix))
    ?.slice(prefix.length);
  if (!encoded) return "";
  try {
    const decoded = Buffer.from(encoded, "base64url");
    if (decoded.toString("base64url") !== encoded) return "";
    return decoded.toString("utf8");
  } catch {
    return "";
  }
}

export function isAllowedBrowserOrigin(
  origin: string,
  configuredOrigins: readonly string[] = [],
): boolean {
  try {
    const parsed = new URL(origin);
    const hostname = parsed.hostname.replace(/^\[|\]$/g, "").toLowerCase();
    const loopback =
      hostname === "localhost" ||
      hostname === "127.0.0.1" ||
      hostname === "::1" ||
      hostname.endsWith(".localhost");
    const hostedApp =
      parsed.origin === "https://app.sidemesh.com" ||
      parsed.origin === "https://sidemesh-app.pages.dev";
    const configured = configuredOrigins.includes(parsed.origin);
    return (
      (parsed.protocol === "http:" || parsed.protocol === "https:") &&
      (loopback || hostedApp || configured)
    );
  } catch {
    return false;
  }
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


function isHealthCheckPath(path: string): boolean {
  return path === "/healthz";
}

function requireProviderCapability(
  provider: AgentProvider,
  supported: boolean,
  feature: string,
  method?: AgentProviderMethodName,
): void {
  if (!supported) throw new HTTPException(501, { message: `${provider.displayName} does not support ${feature}` });
  if (method && !hasProviderMethod(provider, method)) {
    throw new HTTPException(501, { message: `${provider.displayName} does not implement ${feature}` });
  }
}

function requireHostCapability(supported: boolean, feature: string): void {
  if (!supported) throw new HTTPException(501, { message: `Sidemesh host does not support ${feature}` });
}

function unsupportedInputCapability(
  provider: AgentProvider,
  input: AgentSessionInputItem[],
): string | null {
  for (const item of input) {
    switch (item.type) {
      case "audio":
      case "resource":
      case "resourceLink": {
        const capability = item.type === "audio" ? "audio" : item.type === "resource" ? "embeddedResources" : "resourceLinks";
        if (!provider.capabilities.input[capability]) return `${provider.displayName} does not support ${item.type} input`;
        break;
      }
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
  if (overrides.accessMode && !provider.capabilities.runtimeControls.accessMode) {
    return `${provider.displayName} does not support access mode overrides`;
  }
  if (overrides.profile && !provider.capabilities.configuration.profiles) {
    return `${provider.displayName} does not support profile overrides`;
  }
  return null;
}

async function resolveTerminalCwd(
  providerRuntime: AgentProviderRuntime,
  sessionState: SessionCoordinator,
  cwd: string,
  sessionId: string | null | undefined,
  configuredRoots: string[],
): Promise<string> {
  if (sessionId?.trim()) {
    try {
      const thread = await readSession(providerRuntime, sessionId.trim(), false);
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
    await collectWorkspaceRoots(
      () => listSessions(providerRuntime, sessionState, null, "none"),
      configuredRoots,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// gitCommonDir enrichment
//
// Providers (Codex, Copilot, etc.) report git context from their own agent
// perspective. None of them run `git rev-parse --git-common-dir`, so
// Git metadata is refreshed with each recent-list read. The short recent-list
// cache bounds work without keeping branch names stale for the daemon lifetime.
async function enrichSessionsWithGitCommonDir(
  sessions: SessionSummary[],
): Promise<SessionSummary[]> {
  const directories = [...new Set(sessions.map((session) => session.cwd).filter(Boolean))];
  const entries = await Promise.all(directories.map(async (cwd) => {
    const [commonDir, identity] = await Promise.all([
      readGitCommonDir(cwd).catch(() => null),
      readGitIdentity(cwd).catch(() => null),
    ]);
    return [cwd, { commonDir, identity }] as const;
  }));
  const metadata = new Map(entries);
  return sessions.map((session) => {
    const git = metadata.get(session.cwd);
    if (!git) return session;
    const existing = session.gitInfo;
    return { ...session, gitInfo: {
      sha: existing?.sha ?? git.identity?.sha ?? null,
      branch: existing?.branch ?? git.identity?.branch ?? null,
      originUrl: existing?.originUrl ?? git.identity?.originUrl ?? null,
      gitCommonDir: git.commonDir,
    } };
  });
}

// Canonical recent-session projection used by /api/sessions and the recent
// live socket so all delivery paths share the same runtime, status, and git
// enrichment behavior.
async function buildRecentSessionSummaries(
  coordinator: SessionCoordinator,
  threads: ThreadRecord[],
  runtimeMode: SessionRuntimeListMode = "active",
): Promise<SessionSummary[]> {
  const sessions = threads.filter((thread) => sessionSubAgentForThread(thread) == null).map((thread) => {
    const summary = coordinator.projectSummary(mapSession(thread, thread.runtime ?? null));
    return runtimeMode === "none" ? { ...summary, runtime: null } : summary;
  });
  return enrichSessionsWithGitCommonDir(sessions);
}

async function listSessions(
  providerRuntime: AgentProviderRuntime,
  coordinator: SessionCoordinator,
  limitOverride: number | null = null,
  runtimeMode: SessionRuntimeListMode = "active",
): Promise<SessionSummary[]> {
  const limit = normalizedSessionListLimit(limitOverride);
  const threads = await listProviderThreads(providerRuntime, { limit, archived: false, includeSubAgents: false });
  return buildRecentSessionSummaries(coordinator, threads, runtimeMode);
}

async function listProviderThreads(
  runtime: AgentProviderRuntime,
  options: AgentSessionListOptions,
): Promise<ThreadRecord[]> {
  const parent = options.subAgentParentId ? runtime.resolveSession(options.subAgentParentId) : null;
  const entries = parent ? [parent.entry] : runtime.providers.filter((entry) => entry.capabilities.sessions.history);
  const groups = await Promise.allSettled(entries.map(async (entry) => {
    const provider = await runtime.ensure(entry);
    let threads: ThreadRecord[];
    if (hasProviderMethod(provider, "listSessionThreads")) {
      threads = await provider.listSessionThreads({ ...options, subAgentParentId: parent?.rawId });
      if (!options.archived && !parent) threads = await mergeRecentUnindexedThreads(provider, threads, options.limit);
    } else if (!options.archived && !parent && provider.capabilities.sessions.recentFallback && hasProviderMethod(provider, "listRecentUnindexedSessionThreads")) {
      threads = await provider.listRecentUnindexedSessionThreads(options.limit);
    } else throw new AgentProviderRequestError(`${entry.displayName} does not support session listing`, 501);
    return threads.map((thread) => runtime.wrapThread(entry, thread));
  }));
  if (groups.length && groups.every((group) => group.status === "rejected")) throw (groups[0] as PromiseRejectedResult).reason;
  return groups.flatMap((group) => group.status === "fulfilled" ? group.value : [])
    .sort((a, b) => threadTimestampMillis(b.updatedAt) - threadTimestampMillis(a.updatedAt)).slice(0, options.limit);
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
  providerRuntime: AgentProviderRuntime,
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
        sessionPromise = readSession(providerRuntime, action.sessionId, false).catch(
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
  coordinator: SessionCoordinator,
  sessionId: string,
  archived?: boolean,
): Promise<void> {
  const snapshot = await coordinator.snapshot(sessionId);
  if (sessionSubAgentForThread(snapshot.thread)) { await searchIndex.remove(sessionId); return; }
  await searchIndex.indexDocument({
    session: mapSession(snapshot.thread, snapshot.runtime, snapshot.status),
    archived: archived ?? false, messages: snapshot.messages, activities: snapshot.activities,
  });
}

async function collectUsageObservations(
  providerRuntime: AgentProviderRuntime,
  hostLabel: string,
  generatedAt: number,
): Promise<UsageObservation[]> {
  const groups = await Promise.all(
    providerRuntime.providers.map(async (entry) => {
      if (!Object.values(entry.capabilities.usage).some(Boolean)) {
        return [
          buildUnsupportedUsageObservation(
            entry.kind,
            entry.displayName,
            hostLabel,
            generatedAt,
          ),
        ];
      }
      try {
        const provider = await providerRuntime.ensure(entry);
        const observations = hasProviderMethod(provider, "readUsageObservations") ? await provider.readUsageObservations() : [];
        if (observations.length === 0) {
          return [
            buildUnsupportedUsageObservation(
              entry.kind,
              entry.displayName,
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
              observation.provider.displayName || entry.displayName,
          },
        }));
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        return [
          buildUsageErrorObservation(
            entry.kind,
            entry.displayName,
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
  providerRuntime: AgentProviderRuntime,
  sessionId: string,
  includeTurns: boolean,
): Promise<ThreadRecord> {
  const resolved = providerRuntime.resolveSession(sessionId);
  const provider = await providerRuntime.ensure(resolved.entry);
  const thread = await requireProviderMethod(provider, "readSessionThread", "session history").call(provider, resolved.rawId, includeTurns);
  return providerRuntime.wrapThread(resolved.entry, thread);
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

function mapSession(
  thread: ThreadRecord,
  runtime: SessionRuntimeSummary | null = null,
  statusOverride: LiveThreadStatus | null = null,
): SessionSummary {
  const provider = providerKindForThread(thread);
  const subAgent = sessionSubAgentForThread(thread);
  return {
    id: thread.id,
    title: sanitizeTitle(thread.name || thread.preview),
    preview: thread.preview,
    cwd: thread.cwd,
    createdAt: threadTimestampMillis(thread.createdAt),
    updatedAt: threadTimestampMillis(thread.updatedAt),
    source: sourceLabelForThread(thread, subAgent),
    provider,
    providerId: thread.providerId,
    status: resolvedSessionStatus(thread, statusOverride),
    rolloutPath: thread.path,
    runtime,
    gitInfo: mapGitInfo(thread.gitInfo),
    isSubAgent: subAgent != null,
    subAgent,
  };
}

function mapAgentRun(thread: ThreadRecord): AgentRunSummary | null {
  const subAgent = sessionSubAgentForThread(thread);
  if (!subAgent?.parentSessionId) {
    return null;
  }
  return {
    id: thread.id,
    parentSessionId: subAgent.parentSessionId,
    title: sanitizeTitle(thread.name || thread.preview),
    preview: thread.preview,
    cwd: thread.cwd,
    createdAt: threadTimestampMillis(thread.createdAt),
    updatedAt: threadTimestampMillis(thread.updatedAt),
    provider: providerKindForThread(thread),
    providerId: thread.providerId,
    status: resolvedSessionStatus(thread, null),
    agentName: subAgent.agentName ?? null,
    agentDisplayName: subAgent.agentDisplayName ?? null,
    agentRole: subAgent.agentRole ?? null,
    agentNickname: subAgent.agentNickname ?? null,
    depth: subAgent.depth ?? null,
  };
}

function sessionSubAgentForThread(thread: ThreadRecord): SessionSubAgentInfo | null {
  if (thread.subAgent) {
    return thread.subAgent;
  }
  return subAgentInfoFromThreadSource(thread.source);
}

function subAgentInfoFromThreadSource(
  source: ThreadRecord["source"],
): SessionSubAgentInfo | null {
  if (!source || typeof source !== "object") {
    return null;
  }
  const typed = source as Record<string, unknown>;
  const rawSubAgent = typed.subAgent ?? typed.subagent;
  if (typeof rawSubAgent === "string") {
    return {
      parentSessionId: null,
      sourceKind: rawSubAgent,
    };
  }
  if (!rawSubAgent || typeof rawSubAgent !== "object") {
    return null;
  }
  const subAgent = rawSubAgent as Record<string, unknown>;
  const threadSpawn = subAgent.thread_spawn;
  if (threadSpawn && typeof threadSpawn === "object") {
    const typedThreadSpawn = threadSpawn as Record<string, unknown>;
    return {
      parentSessionId: asString(typedThreadSpawn.parent_thread_id) ?? null,
      sourceKind: "thread_spawn",
      agentRole: asString(typedThreadSpawn.agent_role) ?? null,
      agentNickname: asString(typedThreadSpawn.agent_nickname) ?? null,
      depth: asInteger(typedThreadSpawn.depth) ?? null,
    };
  }
  const other = asString(subAgent.other);
  if (other) {
    return {
      parentSessionId: null,
      sourceKind: other,
    };
  }
  return {
    parentSessionId: null,
    sourceKind: "subagent",
  };
}

function sourceLabelForThread(
  thread: ThreadRecord,
  subAgent: SessionSubAgentInfo | null,
): string {
  if (typeof thread.source === "string") {
    return thread.source;
  }
  if (subAgent) {
    return formatSubAgentSourceKind(subAgent.sourceKind);
  }
  const typed = thread.source as Record<string, unknown>;
  const custom = asString(typed.custom);
  if (custom) {
    return custom;
  }
  try {
    return JSON.stringify(thread.source);
  } catch {
    return "unknown";
  }
}

function formatSubAgentSourceKind(kind: string): string {
  switch (kind) {
    case "child_session":
    case "thread_spawn":
    case "subagent":
      return "sub-agent";
    case "memory_consolidation":
      return "memory consolidation";
    default:
      return kind.replaceAll("_", " ");
  }
}

function providerKindForThread(thread: ThreadRecord): string | null {
  if (thread.providerKind) return thread.providerKind;
  const separator = thread.id.indexOf(":");
  if (separator > 0) {
    const prefix = thread.id.slice(0, separator);
    if (isAgentProviderKind(prefix)) {
      return prefix;
    }
  }
  const source =
    typeof thread.source === "string" && isAgentProviderKind(thread.source)
      ? thread.source
      : null;
  if (source) {
    return source;
  }
  return null;
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
    gitCommonDir: asString(typed.gitCommonDir) ?? null,
  };
  return info.sha || info.branch || info.originUrl || info.gitCommonDir ? info : null;
}

function parseGitDiffKind(
  value: unknown,
): "working" | "staged" | "unstaged" | null {
  const kind = asString(value);
  switch (kind) {
    case "working":
    case "staged":
    case "unstaged":
      return kind;
    default:
      return null;
  }
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
        overrides,
      }),
    )
    .digest("hex");
}

function isValidClientMessageId(value: string): boolean {
  return (
    value.length > 0 &&
    value.length <= CLIENT_MESSAGE_ID_MAX_LENGTH &&
    CLIENT_MESSAGE_ID_PATTERN.test(value)
  );
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

function asBoolean(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null;
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
  sessionId: string,
  sessionState: SessionCoordinator,
): Promise<SessionResourcesResponse> {
  const snapshot = await sessionState.snapshot(sessionId);
  return { sessionId, updatedAt: snapshot.thread.updatedAt,
    resources: buildSessionResources(snapshot.messages, snapshot.activities) };
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
  aliases: WeakMap<WebSocket, string>,
): void {
  const sockets = socketsBySession.get(sessionId);
  if (!sockets) {
    return;
  }
  for (const socket of sockets) {
    const alias = aliases.get(socket) ?? sessionId;
    sendEvent(socket, alias === sessionId ? event : withSessionAlias(event, sessionId, alias));
  }
}

/** Old clients keep their requested ID; all host state uses the canonical identity. */
function withSessionAlias(value: unknown, canonical: string, alias: string): unknown {
  const owner = (item: unknown): unknown => {
    if (!item || typeof item !== "object" || Array.isArray(item)) return item;
    const mapped = { ...item } as Record<string, unknown>;
    for (const key of ["sessionId", "parentSessionId"]) if (mapped[key] === canonical) mapped[key] = alias;
    return mapped;
  };
  if (Array.isArray(value)) return value.map(owner);
  const result = owner(value);
  if (!result || typeof result !== "object") return result;
  const payload = result as Record<string, unknown>;
  for (const key of ["action", "pendingAction", "latestPlanUpdate"]) if (payload[key]) payload[key] = owner(payload[key]);
  if (payload.session && typeof payload.session === "object") {
    const session = { ...payload.session } as Record<string, unknown>;
    if (session.id === canonical) session.id = alias;
    payload.session = session;
  }
  return { ...payload, canonicalSessionId: canonical };
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
      case "audio":
      case "resource":
      case "resourceLink":
        items.push(parseContentInput(typed));
        break;
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

const LOCAL_IMAGE_MAX_BYTES = 10 * 1024 * 1024;

function hasLocalPathInputItem(input: AgentSessionInputItem[]): boolean {
  return input.some(
    (item) => item.type === "file" || item.type === "localImage",
  );
}

async function resolveFileInputItemsForSession(
  providerRuntime: AgentProviderRuntime,
  sessionId: string,
  input: AgentSessionInputItem[],
): Promise<AgentSessionInputItem[]> {
  if (!hasLocalPathInputItem(input)) {
    return input;
  }
  const thread = await readSession(providerRuntime, sessionId, false);
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
  if (!hasLocalPathInputItem(input)) {
    return input;
  }
  const workspaceRoot = nodePath.resolve(cwd);
  return Promise.all(
    input.map(async (item): Promise<AgentSessionInputItem> => {
      if (item.type !== "file" && item.type !== "localImage") {
        return item;
      }
      const candidate = nodePath.isAbsolute(item.path)
        ? item.path
        : nodePath.resolve(workspaceRoot, item.path);
      const path = await resolveWorkspacePath(candidate, [workspaceRoot]);
      const info = await stat(path);
      if (item.type === "localImage") {
        if (!info.isFile()) {
          throw new WorkspaceAccessError(
            "local image path must be a regular file",
            400,
          );
        }
        if (info.size > LOCAL_IMAGE_MAX_BYTES) {
          throw new WorkspaceAccessError(
            "local image exceeds 10 MiB",
            413,
          );
        }
        return { type: "localImage", path };
      }
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
    if (item.type === "audio" || item.type === "resource" || item.type === "resourceLink") {
      attachments.push(contentInputAttachment(item));
      continue;
    }
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
    accessMode: asString(typed.accessMode),
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
    sandboxMode: asString(typed.sandboxMode),
    networkAccess: parseOptionalBool(typed.networkAccess),
    webSearch: null,
    profile: null,
    accessMode: asString(typed.accessMode),
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
