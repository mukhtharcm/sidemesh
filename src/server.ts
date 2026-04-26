import { createServer } from "node:http";
import { hostname, homedir, platform } from "node:os";
import { createHash, randomUUID } from "node:crypto";
import { access, readdir, stat } from "node:fs/promises";
import nodePath from "node:path";

import cors from "cors";
import express, { type Request, type Response, type NextFunction } from "express";
import { WebSocketServer, type WebSocket } from "ws";

import type {
  ActiveTurnState,
  ApprovalLiveEvent,
  CodexProfileCatalog,
  CodexProfileSummary,
  GitInfoSummary,
  LiveEvent,
  SessionActivity,
  NodeConfig,
  PendingAction,
  PendingActionRecord,
  SkillCatalogEntry,
  SkillErrorInfo,
  SkillSummary,
  ModelSummary,
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
  buildActivityFromThreadItem,
  buildFileChangeChanges,
  buildTurnDiffActivity,
  mergeActivity,
  mergeSessionActivities,
} from "./activity.js";
import { CodexBridge } from "./codex-client.js";
import { buildGitDiff, readGitDiff, readGitStatus, sanitizeGitUrl } from "./git.js";
import { loadRolloutLog, loadSessionRuntime } from "./history.js";
import { buildSessionResources } from "./resources.js";
import {
  FsWatchRegistry,
  attachFsLiveSocket,
  registerFsRoutes,
} from "./fs-routes.js";
import {
  SessionInputDedupeStore,
  type StoredSessionInputDedupeEntry,
} from "./session-input-dedupe-store.js";

const DEFAULT_SOURCES = ["cli", "vscode", "exec", "appServer"];
const SESSION_LOG_CACHE_LIMIT = 24;
const SESSION_INPUT_DEDUPE_LIMIT = 500;
const SESSION_INPUT_DEDUPE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const SESSION_INPUT_DEDUPE_FILE = "session-input-dedupe-v1.json";
const CLIENT_MESSAGE_ID_MAX_LENGTH = 128;
const CLIENT_MESSAGE_ID_PATTERN = /^[A-Za-z0-9._:-]+$/;
const PROVIDER_MODEL_LIST_TIMEOUT_MS = 2500;
const RECENT_ROLLOUT_SCAN_DAYS = 3;
const RECENT_ROLLOUT_FALLBACK_LIMIT = 50;
const ROLLOUT_THREAD_ID_PATTERN =
  /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/;

interface SessionRuntimeCacheEntry {
  threadUpdatedAt: number;
  runtime: SessionRuntimeSummary | null;
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

interface ConfigModelProviderSummary {
  id: string;
  name: string | null;
  baseUrl: string | null;
  envKey: string | null;
}

interface CodexProfileConfig extends CodexProfileCatalog {
  modelProvider: string | null;
  openaiBaseUrl: string | null;
  modelProviders: Map<string, ConfigModelProviderSummary>;
}

interface SessionInputDedupeEntry {
  signatureHash: string;
  createdAt: number;
  promise?: Promise<SessionInputReceipt>;
  receipt?: SessionInputReceipt;
}

type ApprovalPolicyValue = "untrusted" | "on-failure" | "on-request" | "never";
type SandboxModeValue = "read-only" | "workspace-write" | "danger-full-access";
type WebSearchModeValue = "disabled" | "cached" | "live";
type ReasoningEffortValue = "none" | "minimal" | "low" | "medium" | "high" | "xhigh";

interface CreateSessionOverrides {
  model: string | null;
  reasoningEffort: ReasoningEffortValue | null;
  fastMode: boolean | null;
  approvalPolicy: ApprovalPolicyValue | null;
  sandboxMode: SandboxModeValue | null;
  webSearch: WebSearchModeValue | null;
  profile: string | null;
}

type SessionInputItem =
  | {
      type: "text";
      text: string;
      text_elements: unknown[];
    }
  | {
      type: "image";
      url: string;
    }
  | {
      type: "localImage";
      path: string;
    }
  | {
      type: "skill";
      name: string;
      path: string;
    };

export async function startServer(config: NodeConfig): Promise<void> {
  const bridge = new CodexBridge(config.codexBin);
  await bridge.start();

  const app = express();
  const server = createServer(app);
  const socketsBySession = new Map<string, Set<WebSocket>>();
  const approvalSockets = new Set<WebSocket>();
  const activeTurns = new Map<string, ActiveTurnState>();
  const pendingActions = new Map<string, PendingActionRecord>();
  const liveActivities = new Map<string, Map<string, SessionActivity>>();
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
  let codexVersion = "unknown";

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

  function sessionInputDedupeKey(sessionId: string, clientMessageId: string): string {
    return `${sessionId}:${clientMessageId}`;
  }

  function pruneSessionInputDedupe(now = Date.now()): void {
    for (const [key, entry] of sessionInputDedupe) {
      if (!entry.promise && now - entry.createdAt > SESSION_INPUT_DEDUPE_TTL_MS) {
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
      event.seq === undefined
        ? { ...event, seq: allocSeq(sessionId) }
        : event;
    broadcast(socketsBySession, sessionId, stamped);
  }

  function broadcastApprovalLive(event: ApprovalLiveEvent): void {
    for (const socket of approvalSockets) {
      sendEvent(socket, event);
    }
  }

  bridge.on("stderr", (line) => {
    process.stderr.write(line);
  });

  const fsWatchRegistry = new FsWatchRegistry(bridge);

  bridge.on("notification", ({ method, params }) => {
    if (method === "fs/changed") {
      fsWatchRegistry.deliver(params as { watchId?: string; changedPaths?: string[] });
      return;
    }

    if (method === "skills/changed") {
      broadcastSkillsChanged(socketsBySession);
      return;
    }

    const sessionId = extractSessionId(method, params);
    if (!sessionId) {
      return;
    }

    if (method === "turn/started") {
      const turnId = asString((params as any)?.turn?.id);
      if (turnId) {
        activeTurns.set(sessionId, { turnId, startedAt: Date.now() });
        broadcastLive(sessionId, {
          type: "turn_started",
          sessionId,
          turnId,
        });
      }
      return;
    }

    if (method === "item/agentMessage/delta") {
      const delta = asString((params as any)?.delta);
      const itemId = asString((params as any)?.itemId);
      if (delta) {
        broadcastLive(sessionId, {
          type: "assistant_delta",
          sessionId,
          delta,
          turnId: asString((params as any)?.turnId) || undefined,
          itemId: itemId || undefined,
        });
      }
      return;
    }

    if (method === "item/started" || method === "item/completed") {
      const item = (params as any)?.item;
      const turnId = asString((params as any)?.turnId);
      if (item && typeof item === "object") {
        const itemType = asString((item as any)?.type);
        if (method === "item/completed" && itemType === "agentMessage") {
          const seq = allocSeq(sessionId);
          const messageItem = buildCompletedAssistantMessage(item as Record<string, unknown>, seq);
          if (messageItem) {
            broadcastLive(sessionId, {
              type: "assistant_message_completed",
              sessionId,
              turnId: turnId || undefined,
              seq,
              messageItem,
            });
          }
          return;
        }

        const existingSeq = liveActivities.get(sessionId)?.get(asString((item as any)?.id) || "")?.seq;
        const activity = buildActivityFromThreadItem(item as any, {
          turnId,
          createdAt: Date.now(),
          seq: existingSeq ?? allocSeq(sessionId),
        });
        if (activity) {
          const next = upsertLiveActivity(liveActivities, sessionId, activity);
          broadcastLive(sessionId, {
            type: "activity_updated",
            sessionId,
            turnId: turnId || undefined,
            activity: next,
          });
        }
      }
      return;
    }

    if (method === "item/commandExecution/outputDelta") {
      const delta = asString((params as any)?.delta);
      const itemId = asString((params as any)?.itemId);
      const turnId = asString((params as any)?.turnId);
      if (!delta || !itemId) {
        return;
      }

      const next = updateLiveCommandActivity(liveActivities, sessionId, itemId, delta);
      if (next) {
        broadcastLive(sessionId, {
          type: "activity_updated",
          sessionId,
          turnId: turnId || undefined,
          activity: next,
        });
      }
      return;
    }

    if (method === "item/commandExecution/terminalInteraction") {
      const stdin = asString((params as any)?.stdin);
      const itemId = asString((params as any)?.itemId);
      const turnId = asString((params as any)?.turnId);
      if (!stdin || !itemId) {
        return;
      }

      const next = updateLiveCommandTerminalInteraction(
        liveActivities,
        sessionId,
        itemId,
        stdin,
      );
      if (next) {
        broadcastLive(sessionId, {
          type: "activity_updated",
          sessionId,
          turnId: turnId || undefined,
          activity: next,
        });
      }
      return;
    }

    if (method === "item/fileChange/patchUpdated") {
      const itemId = asString((params as any)?.itemId);
      const turnId = asString((params as any)?.turnId);
      if (!itemId) {
        return;
      }

      const next = updateLiveFileChangeActivity(
        liveActivities,
        sessionId,
        itemId,
        turnId,
        (params as any)?.changes,
        () => allocSeq(sessionId),
      );
      if (next) {
        broadcastLive(sessionId, {
          type: "activity_updated",
          sessionId,
          turnId: turnId || undefined,
          activity: next,
        });
      }
      return;
    }

    if (method === "turn/diff/updated") {
      const turnId = asString((params as any)?.turnId);
      const diff = asString((params as any)?.diff);
      if (!turnId || !diff) {
        return;
      }

      const next = updateLiveTurnDiffActivity(liveActivities, sessionId, turnId, diff, () =>
        allocSeq(sessionId),
      );
      if (next) {
        broadcastLive(sessionId, {
          type: "activity_updated",
          sessionId,
          turnId,
          activity: next,
        });
      }
      return;
    }

    if (method === "turn/completed") {
      const turn = (params as any)?.turn;
      const turnId = asString(turn?.id);
      if (turnId) {
        // Broadcast the completion first so any concurrent snapshot reader
        // sees both the rollout-flushed history AND the live state still in
        // memory. Clearing liveActivities before the broadcast can briefly
        // leave both the snapshot and live stream blank for a second client.
        broadcastLive(sessionId, {
          type: "turn_completed",
          sessionId,
          turnId,
          status: asString(turn?.status) || "completed",
        });
        clearActionsForSession(
          pendingActions,
          sessionId,
          broadcastLive,
          broadcastApprovalLive,
        );
        activeTurns.delete(sessionId);
        liveActivities.delete(sessionId);
        clearSessionLogCache(logCache, sessionId);
        // NOTE: do NOT reset sessionSeqCursor between turns — clients rely on
        // a monotonically increasing seq across the whole session lifetime to
        // detect gaps after a reconnect.
      }
    }
  });

  bridge.on("serverRequest", ({ id, method, params }) => {
    if (
      method !== "item/commandExecution/requestApproval" &&
      method !== "item/fileChange/requestApproval" &&
      method !== "item/permissions/requestApproval"
    ) {
      return;
    }

    const sessionId = extractSessionId(method, params);
    if (!sessionId) {
      return;
    }

    const action = buildPendingAction(method, params, id);
    pendingActions.set(action.id, action);
    broadcastLive(sessionId, {
      type: "action_opened",
      sessionId,
      action,
    });
    broadcastApprovalLive({
      type: "action_opened",
      action,
    });
  });

  try {
    const version = await import("node:child_process").then(({ execFileSync }) =>
      execFileSync(config.codexBin, ["--version"], { encoding: "utf8" }).trim(),
    );
    codexVersion = version;
  } catch {
    codexVersion = "unknown";
  }

  app.use(cors());
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
    response.json({
      label: config.label,
      hostname: hostname(),
      platform: platform(),
      codexVersion,
      startedAt: process.uptime(),
      tokenSource: config.tokenSource,
    });
  });

  app.get("/api/sessions", asyncRoute(async (_request, response) => {
    const requestedLimit = asInteger((_request.query as Record<string, unknown>)?.limit);
    const sessions = await listSessions(bridge, runtimeCache, requestedLimit);
    response.json(sessions);
  }));

  app.get("/api/workspaces", asyncRoute(async (_request, response) => {
    const sessions = await listSessions(bridge, runtimeCache);
    response.json(buildWorkspaces(sessions));
  }));

  registerFsRoutes(app, {
    bridge,
    listSessions: () => listSessions(bridge, runtimeCache),
    watchRegistry: fsWatchRegistry,
  });

  app.get("/api/actions", asyncRoute(async (_request, response) => {
    response.json(await listPendingActions(bridge, pendingActions));
  }));

  app.get("/api/sessions/:sessionId/log", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const query = request.query as Record<string, unknown>;
    const messageLimit = asInteger(query.messageLimit);
    const activityLimit = asInteger(query.activityLimit);
    const cacheKey = buildSessionLogCacheKey(sessionId, messageLimit, activityLimit);
    const cached = logCache.get(cacheKey);

    if (cached) {
      const session = await readSession(bridge, sessionId, false);
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
          pendingAction: findPendingActionForSession(pendingActions, sessionId),
          history: cached.history,
        });
        return;
      }
    }

    const session = await readSession(bridge, sessionId, false);
    const log = await loadRolloutLog(
      sessionId,
      session.path,
      bridge.codexHome,
      messageLimit,
      activityLimit,
    );
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
  }));

  // Replay endpoint for cheap reconnect / resume. Clients pass `since`
  // (the highest seq they've already observed) and get only newer
  // messages + activities — no re-downloading the full transcript.
  app.get("/api/sessions/:sessionId/events", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const query = request.query as Record<string, unknown>;
    const since = asInteger(query.since) ?? 0;

    const session = await readSession(bridge, sessionId, false);
    const log = await loadRolloutLog(
      sessionId,
      session.path,
      bridge.codexHome,
    );
    ensureSeqCursor(sessionId, log.nextSeq);
    const activities = mergeSessionActivities(
      log.activities,
      liveActivities.get(sessionId)?.values() || [],
    );
    const newMessages = log.messages.filter((m) => (m.seq ?? 0) > since);
    const newActivities = activities.filter((a) => (a.seq ?? 0) > since);
    let highestSeq = since;
    for (const m of newMessages) {
      if ((m.seq ?? 0) > highestSeq) highestSeq = m.seq ?? highestSeq;
    }
    for (const a of newActivities) {
      if ((a.seq ?? 0) > highestSeq) highestSeq = a.seq ?? highestSeq;
    }
    response.json({
      sessionId,
      since,
      nextSeq: highestSeq,
      messages: newMessages,
      activities: newActivities,
      pendingAction: findPendingActionForSession(pendingActions, sessionId),
      session: mapSession(session, log.runtime),
    });
  }));

  app.get("/api/sessions/:sessionId/resources", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    response.json(await readSessionResources(bridge, sessionId, liveActivities));
  }));

  app.get("/api/sessions/:sessionId/status", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const state = await loadRunState(bridge, sessionId, activeTurns);
    response.json({
      sessionId,
      isRunning: Boolean(state.turnId),
      activeTurnId: state.turnId,
      pendingAction: findPendingActionForSession(pendingActions, sessionId),
    });
  }));

  app.get("/api/sessions/:sessionId/git", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const session = await readSession(bridge, sessionId, false);
    response.json(await readGitStatus(session.cwd, mapGitInfo(session.gitInfo)));
  }));

  app.get("/api/sessions/:sessionId/git/diff", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const kind = parseGitDiffKind((request.query as Record<string, unknown>).kind);
    if (!kind) {
      response.status(400).json({ error: "kind must be working, staged, unstaged, or remote" });
      return;
    }

    const session = await readSession(bridge, sessionId, false);
    if (kind === "remote") {
      const result = (await bridge.request("gitDiffToRemote", {
        cwd: session.cwd,
      })) as Record<string, unknown>;
      response.json(buildGitDiff("remote", asString(result.diff) ?? "", normalizeGitSha(result.sha)));
      return;
    }

    response.json(await readGitDiff(session.cwd, kind));
  }));

  app.get("/api/skills", asyncRoute(async (request, response) => {
    const query = request.query as Record<string, unknown>;
    const cwd = asString(query.cwd);
    if (!cwd) {
      response.status(400).json({ error: "cwd is required" });
      return;
    }

    const forceReload = parseQueryBool(query.forceReload);
    const workspaceSkillRoots = await findWorkspaceSkillRoots(cwd);
    const payload = (await bridge.request("skills/list", {
      cwds: [cwd],
      forceReload: forceReload || workspaceSkillRoots.length > 0,
      perCwdExtraUserRoots:
        workspaceSkillRoots.length > 0
          ? [{ cwd, extraUserRoots: workspaceSkillRoots }]
          : null,
    })) as { data?: unknown[] };
    const rawEntries = Array.isArray(payload.data) ? payload.data : [];
    const rawEntry =
      rawEntries.find((entry) => asString((entry as Record<string, unknown>)?.cwd) === cwd) ??
      rawEntries[0];
    response.json(normalizeSkillCatalogEntry(rawEntry, cwd, workspaceSkillRoots));
  }));

  app.post("/api/skills/config/write", asyncRoute(async (request, response) => {
    const path = asString(request.body?.path);
    const name = asString(request.body?.name);
    const enabled = parseOptionalBool(request.body?.enabled);
    if (enabled === null) {
      response.status(400).json({ error: "enabled is required" });
      return;
    }
    if ((path && name) || (!path && !name)) {
      response.status(400).json({ error: "provide exactly one of path or name" });
      return;
    }

    const result = await bridge.request("skills/config/write", {
      path: path ?? undefined,
      name: name ?? undefined,
      enabled,
    });
    response.json(result);
  }));

  app.get("/api/models", asyncRoute(async (request, response) => {
    const query = request.query as Record<string, unknown>;
    const cwd = asString(query.cwd) || null;
    const profile = asString(query.profile) || null;
    const provider = asString(query.provider) || null;
    response.json(await listModels(bridge, cwd, { profile, provider }));
  }));

  app.get("/api/profiles", asyncRoute(async (request, response) => {
    const query = request.query as Record<string, unknown>;
    const cwd = asString(query.cwd) || null;
    response.json(await listProfiles(bridge, cwd));
  }));

  app.post("/api/sessions/create", asyncRoute(async (request, response) => {
    const cwd = asString(request.body?.cwd);
    const prompt = asString(request.body?.prompt);
    const input = parseInputItems(request.body?.input);
    const overrides = parseCreateSessionOverrides(request.body);
    if (!cwd) {
      response.status(400).json({ error: "cwd is required" });
      return;
    }

    const startedParams: Record<string, unknown> = {
      cwd,
      experimentalRawEvents: false,
      persistExtendedHistory: true,
    };

    if (overrides.model) {
      startedParams.model = overrides.model;
    }
    if (overrides.fastMode !== null) {
      startedParams.serviceTier = overrides.fastMode ? "fast" : null;
    }
    if (overrides.approvalPolicy) {
      startedParams.approvalPolicy = overrides.approvalPolicy;
    }
    if (overrides.sandboxMode) {
      startedParams.sandbox = overrides.sandboxMode;
    }
    const configOverrides = buildThreadConfigOverrides(overrides);
    if (configOverrides) {
      startedParams.config = configOverrides;
    }

    const started = (await bridge.request("thread/start", startedParams)) as any;
    const thread = started.thread as ThreadRecord;
    const startedRuntime = buildRuntimeFromThreadStart(started);

    let turnId: string | null = null;
    const resolvedInput = input.length > 0 ? input : buildLegacyTextInput(prompt);
    if (resolvedInput.length > 0) {
      const turn = (await bridge.request("turn/start", {
        threadId: thread.id,
        input: resolvedInput,
      })) as any;
      turnId = asString(turn.turn?.id) || null;
      if (turnId) {
        activeTurns.set(thread.id, { turnId, startedAt: Date.now() });
      }
    }

    response.status(201).json({
      session: mapSession(thread, startedRuntime),
      activeTurnId: turnId,
    });
  }));

  app.post("/api/sessions/:sessionId/input", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const text = asString(request.body?.text);
    const input = parseInputItems(request.body?.input);
    const clientMessageId = asString(request.body?.clientMessageId);
    if (clientMessageId && !isValidClientMessageId(clientMessageId)) {
      response.status(400).json({
        error: "clientMessageId must be 1-128 URL-safe characters",
      });
      return;
    }
    const resolvedInput = input.length > 0 ? input : buildLegacyTextInput(text);
    if (resolvedInput.length === 0) {
      response.status(400).json({ error: "input is required" });
      return;
    }

    const turnOverrides = parseTurnOverrides(request.body);
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
      const state = await loadRunState(bridge, sessionId, activeTurns);
      if (state.turnId) {
        const steer = (await bridge.request("turn/steer", {
          threadId: sessionId,
          input: resolvedInput,
          expectedTurnId: state.turnId,
        })) as any;
        broadcastLive(sessionId, {
          type: "user_message_submitted",
          sessionId,
          turnId: state.turnId,
          messageItem: submittedMessage,
        });
        return {
          mode: "steer",
          turnId: asString(steer.turnId),
          messageId: submittedMessage.id,
        };
      }

      if (!(await isThreadLoaded(bridge, sessionId))) {
        await bridge.request("thread/resume", {
          threadId: sessionId,
          persistExtendedHistory: true,
        });
      }
      const turnStartParams: Record<string, unknown> = {
        threadId: sessionId,
        input: resolvedInput,
      };
      if (turnOverrides.approvalPolicy) {
        turnStartParams.approvalPolicy = turnOverrides.approvalPolicy;
      }
      if (turnOverrides.model) {
        turnStartParams.model = turnOverrides.model;
      }
      if (turnOverrides.reasoningEffort) {
        turnStartParams.effort = turnOverrides.reasoningEffort;
      }
      if (turnOverrides.fastMode !== null) {
        turnStartParams.serviceTier = turnOverrides.fastMode ? "fast" : null;
      }
      // NOTE: turn/start expects a tagged `sandboxPolicy` object (v2 protocol),
      // NOT the simple kebab string that thread/start accepts as `sandbox`.
      // Sending `sandbox: "workspace-write"` here silently no-ops and leaves the
      // session's existing sandbox in place.
      if (turnOverrides.sandboxMode || turnOverrides.networkAccess !== null) {
        turnStartParams.sandboxPolicy = buildSandboxPolicyV2(
          turnOverrides.sandboxMode,
          turnOverrides.networkAccess,
        );
      }
      const turn = (await bridge.request("turn/start", turnStartParams)) as any;
      const turnId = asString(turn.turn?.id);
      if (turnId) {
        activeTurns.set(sessionId, { turnId, startedAt: Date.now() });
      }
      broadcastLive(sessionId, {
        type: "user_message_submitted",
        sessionId,
        turnId: turnId || undefined,
        messageItem: submittedMessage,
      });
      return {
        mode: "turn",
        turnId,
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
    } catch (error) {
      if (dedupeKey) {
        const current = sessionInputDedupe.get(dedupeKey);
        if (current?.promise === promise) {
          sessionInputDedupe.delete(dedupeKey);
        }
      }
      throw error;
    }
  }));

  app.post("/api/sessions/:sessionId/stop", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const state = await loadRunState(bridge, sessionId, activeTurns);
    if (!state.turnId) {
      response.json({ stopped: false });
      return;
    }
    await bridge.request("turn/interrupt", {
      threadId: sessionId,
      turnId: state.turnId,
    });
    activeTurns.delete(sessionId);
    response.json({ stopped: true, turnId: state.turnId });
  }));

  app.post("/api/sessions/:sessionId/name", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const name = asString(request.body?.name);
    if (!name) {
      response.status(400).json({ error: "name is required" });
      return;
    }
    if (!(await isThreadLoaded(bridge, sessionId))) {
      await bridge.request("thread/resume", {
        threadId: sessionId,
        persistExtendedHistory: true,
      });
    }
    await bridge.request("thread/name/set", {
      threadId: sessionId,
      name,
    });
    const thread = await readSession(bridge, sessionId, false);
    response.json({ session: mapSession(thread) });
  }));

  app.post("/api/sessions/:sessionId/archive", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    await bridge.request("thread/archive", { threadId: sessionId });
    activeTurns.delete(sessionId);
    liveActivities.delete(sessionId);
    clearSessionLogCache(logCache, sessionId);
    sessionSeqCursor.delete(sessionId);
    response.json({ archived: true });
  }));

  app.post("/api/sessions/:sessionId/unarchive", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    await bridge.request("thread/unarchive", { threadId: sessionId });
    response.json({ unarchived: true });
  }));

  app.post("/api/actions/:actionId/respond", asyncRoute(async (request, response) => {
    const actionId = pathParam(request.params.actionId);
    const decision = asString(request.body?.decision);
    const action = pendingActions.get(actionId);
    if (!action) {
      response.status(404).json({ error: "action not found" });
      return;
    }

    const result = buildActionResponse(action, decision);
    if (!result) {
      response.status(400).json({ error: "unsupported decision" });
      return;
    }

    bridge.respond(action.jsonRpcId, result);
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
    response.json({ ok: true });
  }));

  const wsServer = new WebSocketServer({ noServer: true });
  server.on("upgrade", (request, socket, head) => {
    const [pathOnly, queryString] = (request.url || "").split("?");
    if (
      pathOnly !== "/api/live" &&
      pathOnly !== "/api/fs/live" &&
      pathOnly !== "/api/actions/live"
    ) {
      socket.destroy();
      return;
    }

    const authHeader = request.headers.authorization;
    const token = authHeader?.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : "";
    if (token !== config.token) {
      socket.destroy();
      return;
    }

    if (pathOnly === "/api/fs/live") {
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        try { ws.send(JSON.stringify({ type: "hello" })); } catch { /* noop */ }
        attachFsLiveSocket(ws, fsWatchRegistry, {
          bridge,
          listSessions: () => listSessions(bridge, runtimeCache),
        });
      });
      return;
    }

    if (pathOnly === "/api/actions/live") {
      wsServer.handleUpgrade(request, socket, head, (ws) => {
        approvalSockets.add(ws);
        sendEvent(ws, { type: "hello" });
        void listPendingActions(bridge, pendingActions)
          .then((actions) => {
            sendEvent(ws, { type: "snapshot", actions });
          })
          .catch((error: unknown) => {
            sendEvent(ws, {
              type: "error",
              message: error instanceof Error ? error.message : "Failed to load pending actions",
            });
          });
        ws.on("close", () => {
          approvalSockets.delete(ws);
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

  app.use((error: unknown, _request: Request, response: Response, _next: NextFunction) => {
    const message = error instanceof Error ? error.message : "Internal server error";
    response.status(500).json({ error: message });
  });

  server.listen(config.port, () => {
    console.log(`[sidemesh] ${config.label} listening on port ${config.port}`);
    console.log(`[sidemesh] codex: ${config.codexBin}`);
    console.log(`[sidemesh] token (${config.tokenSource}): ${config.token}`);
  });
}

function asyncRoute(
  handler: (request: Request, response: Response, next: NextFunction) => Promise<void>,
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
  if (!auth || !auth.startsWith("Bearer ") || auth.slice("Bearer ".length) !== token) {
    response.status(401).json({ error: "unauthorized" });
    return;
  }
  next();
}

async function listSessions(
  bridge: CodexBridge,
  runtimeCache: Map<string, SessionRuntimeCacheEntry>,
  limitOverride: number | null = null,
): Promise<SessionSummary[]> {
  const limit = Math.max(1, Math.min(limitOverride ?? 100, 100));
  const result = (await bridge.request("thread/list", {
    limit,
    sortKey: "updated_at",
    sortDirection: "desc",
    sourceKinds: DEFAULT_SOURCES,
    archived: false,
  })) as any;
  const threads = Array.isArray(result.data) ? (result.data as ThreadRecord[]) : [];
  const mergedThreads = await mergeRecentUnindexedThreads(bridge, threads, limit);
  return Promise.all(
    mergedThreads.map(async (thread) =>
      mapSession(
        thread,
        await loadCachedSessionRuntime(bridge, thread, runtimeCache),
      ),
    ),
  );
}

async function mergeRecentUnindexedThreads(
  bridge: CodexBridge,
  indexedThreads: ThreadRecord[],
  limit: number,
): Promise<ThreadRecord[]> {
  const threadsById = new Map(indexedThreads.map((thread) => [thread.id, thread]));
  const recentIds = await listRecentRolloutThreadIds();

  for (const id of recentIds) {
    if (threadsById.has(id)) {
      continue;
    }
    try {
      const thread = await readSession(bridge, id, false);
      threadsById.set(id, thread);
    } catch {
      // Rollout scans are a best-effort fallback for sessions missing from Codex's index.
    }
    if (threadsById.size >= limit + RECENT_ROLLOUT_FALLBACK_LIMIT) {
      break;
    }
  }

  return [...threadsById.values()]
    .sort((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, limit);
}

async function listRecentRolloutThreadIds(): Promise<string[]> {
  const codexHome = process.env.CODEX_HOME?.trim() || nodePath.join(homedir(), ".codex");
  const sessionsRoot = nodePath.join(codexHome, "sessions");
  const candidates: Array<{ id: string; sortKey: string }> = [];
  const seen = new Set<string>();

  for (let offset = 0; offset < RECENT_ROLLOUT_SCAN_DAYS; offset += 1) {
    const day = new Date(Date.now() - offset * 24 * 60 * 60 * 1000);
    const dayDir = nodePath.join(
      sessionsRoot,
      String(day.getFullYear()),
      String(day.getMonth() + 1).padStart(2, "0"),
      String(day.getDate()).padStart(2, "0"),
    );

    let entries;
    try {
      entries = await readdir(dayDir, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.startsWith("rollout-") || !entry.name.endsWith(".jsonl")) {
        continue;
      }
      const id = entry.name.match(ROLLOUT_THREAD_ID_PATTERN)?.[1];
      if (!id || seen.has(id)) {
        continue;
      }
      seen.add(id);
      candidates.push({ id, sortKey: entry.name });
    }
  }

  return candidates
    .sort((left, right) => right.sortKey.localeCompare(left.sortKey))
    .slice(0, RECENT_ROLLOUT_FALLBACK_LIMIT)
    .map((candidate) => candidate.id);
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
  return [...grouped.values()].sort((left, right) => right.lastUsedAt - left.lastUsedAt);
}

async function listPendingActions(
  bridge: CodexBridge,
  pendingActions: Map<string, PendingActionRecord>,
): Promise<PendingAction[]> {
  const actions = [...pendingActions.values()].sort((left, right) => right.requestedAt - left.requestedAt);
  const sessionsById = new Map<string, Promise<ThreadRecord | null>>();

  return Promise.all(
    actions.map(async (action) => {
      if (!action.sessionId || action.sessionId === "unknown") {
        return action;
      }

      let sessionPromise = sessionsById.get(action.sessionId);
      if (!sessionPromise) {
        sessionPromise = readSession(bridge, action.sessionId, false).catch(() => null);
        sessionsById.set(action.sessionId, sessionPromise);
      }

      const session = await sessionPromise;
      if (!session) {
        return action;
      }

      const mapped = mapSession(session);
      return {
        ...action,
        sessionTitle: mapped.title,
        cwd: mapped.cwd,
      };
    }),
  );
}

async function readSession(
  bridge: CodexBridge,
  sessionId: string,
  includeTurns: boolean,
): Promise<ThreadRecord> {
  const result = (await bridge.request("thread/read", {
    threadId: sessionId,
    includeTurns,
  })) as any;
  return result.thread as ThreadRecord;
}

async function loadRunState(
  bridge: CodexBridge,
  sessionId: string,
  activeTurns: Map<string, ActiveTurnState>,
): Promise<{ turnId: string | null }> {
  const known = activeTurns.get(sessionId);
  if (known) {
    return { turnId: known.turnId };
  }

  let session: ThreadRecord;
  try {
    session = await readSession(bridge, sessionId, true);
  } catch (error) {
    const message = error instanceof Error ? error.message : "";
    if (message.includes("includeTurns is unavailable before first user message")) {
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

async function isThreadLoaded(bridge: CodexBridge, sessionId: string): Promise<boolean> {
  const result = (await bridge.request("thread/loaded/list", {})) as any;
  const data = Array.isArray(result.data) ? result.data : [];
  return data.includes(sessionId);
}

function upsertLiveActivity(
  liveActivities: Map<string, Map<string, SessionActivity>>,
  sessionId: string,
  activity: SessionActivity,
): SessionActivity {
  const sessionActivities = liveActivities.get(sessionId) || new Map<string, SessionActivity>();
  const merged = mergeActivity(sessionActivities.get(activity.id), activity);
  sessionActivities.set(activity.id, merged);
  liveActivities.set(sessionId, sessionActivities);
  return merged;
}

function updateLiveCommandActivity(
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
  if (!existing || existing.type !== "command") {
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

function updateLiveFileChangeActivity(
  liveActivities: Map<string, Map<string, SessionActivity>>,
  sessionId: string,
  itemId: string,
  turnId: string | null,
  rawChanges: unknown,
  allocSeq: () => number,
): SessionActivity {
  const sessionActivities = liveActivities.get(sessionId) || new Map<string, SessionActivity>();
  const existing = sessionActivities.get(itemId);
  const next: SessionActivity = {
    id: itemId,
    type: "file_change",
    turnId,
    createdAt: existing?.createdAt || Date.now(),
    seq: existing?.seq ?? allocSeq(),
    status: existing?.type === "file_change" ? existing.status : "in_progress",
    changes: buildFileChangeChanges(rawChanges),
  };
  const merged = mergeActivity(existing, next);
  sessionActivities.set(itemId, merged);
  liveActivities.set(sessionId, sessionActivities);
  return merged;
}

function updateLiveTurnDiffActivity(
  liveActivities: Map<string, Map<string, SessionActivity>>,
  sessionId: string,
  turnId: string,
  diff: string,
  allocSeq: () => number,
): SessionActivity | null {
  const sessionActivities = liveActivities.get(sessionId) || new Map<string, SessionActivity>();
  const probeId = `${turnId}::turn_diff`;
  const existingSeq = sessionActivities.get(probeId)?.seq;
  const incoming = buildTurnDiffActivity(turnId, diff, Date.now(), existingSeq ?? allocSeq());
  if (!incoming) {
    return null;
  }

  const existing = sessionActivities.get(incoming.id);
  const merged = mergeActivity(existing, incoming);
  sessionActivities.set(incoming.id, merged);
  liveActivities.set(sessionId, sessionActivities);
  return merged;
}

function mapSession(
  thread: ThreadRecord,
  runtime: SessionRuntimeSummary | null = null,
): SessionSummary {
  return {
    id: thread.id,
    title: sanitizeTitle(thread.name || thread.preview),
    preview: thread.preview,
    cwd: thread.cwd,
    createdAt: thread.createdAt * 1000,
    updatedAt: thread.updatedAt * 1000,
    source: typeof thread.source === "string" ? thread.source : JSON.stringify(thread.source),
    status: thread.status?.type || "notLoaded",
    rolloutPath: thread.path,
    runtime,
    gitInfo: mapGitInfo(thread.gitInfo),
  };
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

function parseGitDiffKind(value: unknown): "working" | "staged" | "unstaged" | "remote" | null {
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
  input: SessionInputItem[],
  overrides: TurnOverrides,
): string {
  return createHash("sha256")
    .update(JSON.stringify({ input, overrides }))
    .digest("hex");
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
  input: SessionInputItem[],
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

function buildCompletedAssistantMessage(
  item: Record<string, unknown>,
  seq: number,
): SessionMessage | null {
  const id = asString(item.id);
  const text = asString(item.text);
  if (!id || !text) {
    return null;
  }

  const phase = asString(item.phase);
  return {
    id,
    role: "assistant",
    text,
    attachments: [],
    createdAt: Date.now(),
    seq,
    phase:
      phase === "commentary" || phase === "final_answer"
        ? phase
        : undefined,
  };
}

async function loadCachedSessionRuntime(
  bridge: CodexBridge,
  thread: ThreadRecord,
  runtimeCache: Map<string, SessionRuntimeCacheEntry>,
): Promise<SessionRuntimeSummary | null> {
  const cached = runtimeCache.get(thread.id);
  if (cached && cached.threadUpdatedAt === thread.updatedAt) {
    return cached.runtime;
  }

  const runtime = await loadSessionRuntime(thread.id, thread.path, bridge.codexHome);
  runtimeCache.set(thread.id, {
    threadUpdatedAt: thread.updatedAt,
    runtime,
  });
  return runtime;
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
  bridge: CodexBridge,
  sessionId: string,
  liveActivities: Map<string, Map<string, SessionActivity>>,
): Promise<SessionResourcesResponse> {
  const session = await readSession(bridge, sessionId, false);
  const log = await loadRolloutLog(
    sessionId,
    session.path,
    bridge.codexHome,
  );
  const activities = mergeSessionActivities(
    log.activities,
    liveActivities.get(sessionId)?.values() || [],
  );
  const resources: SessionResource[] = buildSessionResources(log.messages, activities);
  return {
    sessionId,
    updatedAt: session.updatedAt,
    resources,
  };
}

function extractSessionId(method: string, params: unknown): string | null {
  if (!params || typeof params !== "object") {
    return null;
  }
  const typed = params as Record<string, any>;
  if (typeof typed.threadId === "string") {
    return typed.threadId;
  }
  if (method === "turn/started" && typeof typed.turn?.threadId === "string") {
    return typed.turn.threadId;
  }
  if (method === "turn/completed" && typeof typed.threadId === "string") {
    return typed.threadId;
  }
  return null;
}

function buildPendingAction(
  method: string,
  params: unknown,
  jsonRpcId: number | string,
): PendingActionRecord {
  const typed = (params || {}) as Record<string, any>;
  const sessionId = asString(typed.threadId) || "unknown";
  const requestedAt = Date.now();

  if (method === "item/commandExecution/requestApproval") {
    const command = asString(typed.command) || "Command approval";
    return {
      id: asString(typed.approvalId) || randomUUID(),
      sessionId,
      kind: "command",
      title: "Command approval",
      detail: command,
      requestedAt,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      jsonRpcId,
      requestMethod: method,
    };
  }

  if (method === "item/fileChange/requestApproval") {
    return {
      id: randomUUID(),
      sessionId,
      kind: "file_change",
      title: "File change approval",
      detail: asString(typed.reason) || "Codex wants to modify files.",
      requestedAt,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      jsonRpcId,
      requestMethod: method,
    };
  }

  return {
    id: randomUUID(),
    sessionId,
    kind: "permissions",
    title: "Permission request",
    detail: formatPermissionRequestDetail(typed.reason, typed.permissions),
    requestedAt,
    canApprove: true,
    canApproveForSession: true,
    canDecline: true,
    jsonRpcId,
    requestMethod: method,
    requestedPermissions: typed.permissions,
  };
}

function buildActionResponse(action: PendingActionRecord, decision: string | null): unknown | null {
  if (!decision) {
    return null;
  }

  if (action.requestMethod === "item/commandExecution/requestApproval") {
    if (decision === "accept" || decision === "acceptForSession" || decision === "decline" || decision === "cancel") {
      return { decision };
    }
    return null;
  }

  if (action.requestMethod === "item/fileChange/requestApproval") {
    if (decision === "accept" || decision === "acceptForSession" || decision === "decline" || decision === "cancel") {
      return { decision };
    }
    return null;
  }

  if (action.requestMethod === "item/permissions/requestApproval") {
    if (decision === "accept") {
      return {
        scope: "turn",
        permissions: action.requestedPermissions || {},
      };
    }
    if (decision === "acceptForSession") {
      return {
        scope: "session",
        permissions: action.requestedPermissions || {},
      };
    }
    if (decision === "decline" || decision === "cancel") {
      return { scope: "turn", permissions: {} };
    }
    return null;
  }

  return null;
}

function clearActionsForSession(
  pendingActions: Map<string, PendingActionRecord>,
  sessionId: string,
  broadcastLive: (sessionId: string, event: LiveEvent) => void,
  broadcastApprovalLive: (event: ApprovalLiveEvent) => void,
): void {
  const toDelete = [...pendingActions.values()].filter((action) => action.sessionId === sessionId);
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
  pendingActions: Map<string, PendingActionRecord>,
  sessionId: string,
): PendingAction | null {
  for (const action of pendingActions.values()) {
    if (action.sessionId === sessionId) {
      return action;
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

function broadcastSkillsChanged(socketsBySession: Map<string, Set<WebSocket>>): void {
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

function buildLegacyTextInput(text: string | null): SessionInputItem[] {
  if (!text) {
    return [];
  }
  return [{ type: "text", text, text_elements: [] }];
}

function parseInputItems(value: unknown): SessionInputItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  const items: SessionInputItem[] = [];
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
          text_elements: Array.isArray(typed.text_elements) ? typed.text_elements : [],
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

function buildSubmittedUserMessageText(input: SessionInputItem[]): string {
  return input
    .filter((item): item is Extract<SessionInputItem, { type: "text" }> => item.type === "text")
    .map((item) => item.text.trim())
    .filter(Boolean)
    .join("\n\n");
}

function buildSubmittedUserMessageAttachments(input: SessionInputItem[]): SessionMessageAttachment[] {
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

async function findWorkspaceSkillRoots(cwd: string): Promise<string[]> {
  const workspaceRoot = await findWorkspaceRoot(cwd);
  if (!workspaceRoot) {
    return [];
  }

  const cwdDir = await resolveDirectoryPath(cwd);
  const dirs = dirsBetween(workspaceRoot, cwdDir ?? workspaceRoot);
  const roots: string[] = [];
  const seen = new Set<string>();
  for (const dir of dirs) {
    const candidate = nodePath.join(dir, "skills");
    if (seen.has(candidate)) {
      continue;
    }
    seen.add(candidate);
    if (await isDirectory(candidate)) {
      roots.push(candidate);
    }
  }
  return roots;
}

async function findWorkspaceRoot(cwd: string): Promise<string | null> {
  let current = await resolveDirectoryPath(cwd);
  if (!current) {
    current = nodePath.resolve(cwd);
  }

  for (;;) {
    if (
      (await pathExists(nodePath.join(current, ".git"))) ||
      (await pathExists(nodePath.join(current, ".jj"))) ||
      (await pathExists(nodePath.join(current, ".hg")))
    ) {
      return current;
    }
    const parent = nodePath.dirname(current);
    if (parent === current) {
      return null;
    }
    current = parent;
  }
}

async function resolveDirectoryPath(rawPath: string): Promise<string | null> {
  const resolved = nodePath.resolve(rawPath);
  try {
    const metadata = await stat(resolved);
    return metadata.isDirectory() ? resolved : nodePath.dirname(resolved);
  } catch {
    return null;
  }
}

function dirsBetween(root: string, cwd: string): string[] {
  const resolvedRoot = nodePath.resolve(root);
  const resolvedCwd = nodePath.resolve(cwd);
  const dirs: string[] = [];
  let current = resolvedCwd;
  for (;;) {
    dirs.push(current);
    if (current === resolvedRoot) {
      break;
    }
    const parent = nodePath.dirname(current);
    if (parent === current) {
      return [resolvedRoot];
    }
    current = parent;
  }
  return dirs.reverse();
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

function normalizeSkillCatalogEntry(
  raw: unknown,
  cwd: string,
  workspaceSkillRoots: string[] = [],
): SkillCatalogEntry {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  return {
    cwd: asString(typed.cwd) || cwd,
    skills: Array.isArray(typed.skills)
      ? typed.skills
          .map((skill) => normalizeSkillSummary(skill, workspaceSkillRoots))
          .filter((skill): skill is SkillSummary => skill !== null)
      : [],
    errors: Array.isArray(typed.errors)
      ? typed.errors.map(normalizeSkillErrorInfo).filter((item): item is SkillErrorInfo => item !== null)
      : [],
  };
}

async function listModels(
  bridge: CodexBridge,
  cwd: string | null,
  scope: { profile?: string | null; provider?: string | null } = {},
): Promise<ModelSummary[]> {
  const profileName = scope.profile?.trim() || null;
  const providerName = scope.provider?.trim() || null;
  if (profileName || providerName) {
    const profileConfig = await readProfileConfig(bridge, cwd);
    if (profileName) {
      const profile = profileConfig.profiles.find((entry) => entry.name === profileName);
      if (!profile) {
        return [];
      }
      return listProfileScopedModels(bridge, profileConfig, profile);
    }
    if (providerName) {
      return listProviderScopedModels(bridge, profileConfig, providerName);
    }
  }

  return listHostModels(bridge);
}

async function listHostModels(bridge: CodexBridge): Promise<ModelSummary[]> {
  const models: ModelSummary[] = [];
  const seen = new Set<string>();
  let cursor: string | null = null;

  for (;;) {
    const payload = (await bridge.request("model/list", {
      includeHidden: false,
      cursor: cursor ?? undefined,
    })) as { data?: unknown[]; nextCursor?: unknown };
    const rawEntries = Array.isArray(payload.data) ? payload.data : [];

    for (const entry of rawEntries) {
      const model = normalizeModelSummary(entry);
      if (!model || seen.has(model.model)) {
        continue;
      }
      seen.add(model.model);
      models.push({ ...model, source: "host", profileName: null });
    }

    const nextCursor = asString(payload.nextCursor);
    if (!nextCursor) {
      break;
    }
    cursor = nextCursor;
  }

  return models;
}

async function listProfileScopedModels(
  bridge: CodexBridge,
  config: CodexProfileConfig,
  profile: CodexProfileSummary,
): Promise<ModelSummary[]> {
  const profileProvider = profile.modelProvider?.trim() || null;
  const defaultProvider = config.modelProvider?.trim() || null;
  const provider = profileProvider ? config.modelProviders.get(profileProvider) : null;

  if (!profileProvider || profileProvider === defaultProvider || profileProvider === "openai") {
    return mergeProfileModel([...(await listHostModels(bridge))], profile);
  }

  const baseUrl = provider?.baseUrl || profile.modelProviderBaseUrl || null;
  const providerModels = baseUrl
    ? await fetchProviderModels({
        baseUrl,
        envKey: provider?.envKey ?? null,
        profileName: profile.name,
        providerName: provider?.name || profileProvider,
        defaultReasoningEffort: profile.reasoningEffort,
      })
    : [];

  return mergeProfileModel(providerModels, profile);
}

async function listProviderScopedModels(
  bridge: CodexBridge,
  config: CodexProfileConfig,
  providerName: string,
): Promise<ModelSummary[]> {
  const defaultProvider = config.modelProvider?.trim() || null;
  if (providerName === defaultProvider || providerName === "openai") {
    return listHostModels(bridge);
  }

  const provider = config.modelProviders.get(providerName);
  if (!provider?.baseUrl) {
    return [];
  }
  return fetchProviderModels({
    baseUrl: provider.baseUrl,
    envKey: provider.envKey,
    profileName: null,
    providerName: provider.name || providerName,
    defaultReasoningEffort: null,
  });
}

function mergeProfileModel(
  models: ModelSummary[],
  profile: CodexProfileSummary,
): ModelSummary[] {
  const model = normalizeProfileModelSummary(profile);
  if (!model) {
    return models;
  }
  const seen = new Set(models.map((entry) => entry.model));
  if (!seen.has(model.model)) {
    return [model, ...models];
  }
  return models.map((entry) =>
    entry.model === model.model && entry.source !== "profile"
      ? { ...entry, isDefault: true }
      : entry,
  );
}

function normalizeProfileModelSummary(profile: CodexProfileSummary): ModelSummary | null {
  const model = profile.model?.trim();
  if (!model) {
    return null;
  }

  const profileDetails = [
    profile.modelProvider ? `provider ${profile.modelProvider}` : null,
    profile.reasoningEffort ? `${profile.reasoningEffort} reasoning` : null,
    profile.serviceTier ? `tier ${profile.serviceTier}` : null,
  ].filter((value): value is string => Boolean(value));

  const suffix =
    profileDetails.length > 0 ? ` (${profileDetails.join(", ")})` : "";

  return {
    id: `profile:${profile.name}:${model}`,
    model,
    displayName: model,
    description: `Declared by Codex profile ${profile.name}${suffix}.`,
    defaultReasoningEffort: profile.reasoningEffort ?? "medium",
    supportedReasoningEfforts: [],
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: ["text", "image"],
    isDefault: false,
    source: "profile",
    profileName: profile.name,
  };
}

async function fetchProviderModels(options: {
  baseUrl: string;
  envKey: string | null;
  profileName: string | null;
  providerName: string;
  defaultReasoningEffort: string | null;
}): Promise<ModelSummary[]> {
  const url = providerModelsUrl(options.baseUrl);
  if (!url) {
    return [];
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), PROVIDER_MODEL_LIST_TIMEOUT_MS);
  try {
    const headers: Record<string, string> = { Accept: "application/json" };
    const apiKey = options.envKey ? process.env[options.envKey]?.trim() : "";
    if (apiKey) {
      headers.Authorization = `Bearer ${apiKey}`;
    }
    const response = await fetch(url, {
      method: "GET",
      headers,
      signal: controller.signal,
    });
    if (!response.ok) {
      return [];
    }
    const payload = (await response.json()) as unknown;
    const payloadObject =
      payload && typeof payload === "object" ? (payload as { data?: unknown }) : null;
    const rawModels: unknown[] = Array.isArray(payloadObject?.data)
      ? payloadObject.data
      : Array.isArray(payload)
        ? payload
        : [];
    const models = rawModels
      .map((entry: unknown) =>
        normalizeProviderModelSummary(entry, {
          profileName: options.profileName,
          providerName: options.providerName,
          defaultReasoningEffort: options.defaultReasoningEffort,
        }),
      )
      .filter((entry: ModelSummary | null): entry is ModelSummary => entry !== null);
    const seen = new Set<string>();
    return models.filter((entry: ModelSummary) => {
      if (seen.has(entry.model)) {
        return false;
      }
      seen.add(entry.model);
      return true;
    });
  } catch {
    return [];
  } finally {
    clearTimeout(timeout);
  }
}

function providerModelsUrl(baseUrl: string): string | null {
  try {
    const url = new URL(baseUrl);
    const path = url.pathname.replace(/\/+$/, "");
    url.pathname = `${path}/models`;
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

function normalizeProviderModelSummary(
  raw: unknown,
  options: {
    profileName: string | null;
    providerName: string;
    defaultReasoningEffort: string | null;
  },
): ModelSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  const model = asString(typed?.id) || asString(typed?.model) || asString(raw);
  if (!model) {
    return null;
  }
  const profileSuffix = options.profileName ? ` via profile ${options.profileName}` : "";
  return {
    id: `${options.profileName ? `profile:${options.profileName}` : `provider:${options.providerName}`}:${model}`,
    model,
    displayName: model,
    description: `Available from ${options.providerName}${profileSuffix}.`,
    defaultReasoningEffort: options.defaultReasoningEffort ?? "medium",
    supportedReasoningEfforts: [],
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: ["text", "image"],
    isDefault: false,
    source: options.profileName ? "profile" : "host",
    profileName: options.profileName,
  };
}

async function listProfiles(
  bridge: CodexBridge,
  cwd: string | null,
): Promise<CodexProfileCatalog> {
  const profileConfig = await readProfileConfig(bridge, cwd);
  return {
    defaultProfile: profileConfig.defaultProfile,
    profiles: profileConfig.profiles,
  };
}

async function readProfileConfig(
  bridge: CodexBridge,
  cwd: string | null,
): Promise<CodexProfileConfig> {
  const payload = (await bridge.request("config/read", {
    includeLayers: false,
    cwd: cwd ?? undefined,
  })) as { config?: unknown };
  return normalizeProfileConfig(payload.config);
}

function normalizeModelSummary(raw: unknown): ModelSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const model = asString(typed.model);
  const id = asString(typed.id);
  const displayName = asString(typed.displayName) || model;
  const description = asString(typed.description);
  const defaultReasoningEffort =
    asString(typed.defaultReasoningEffort) || asString(typed.default_reasoning_effort);
  if (!id || !model || !displayName || !description || !defaultReasoningEffort) {
    return null;
  }

  const supportedReasoningEfforts = Array.isArray(typed.supportedReasoningEfforts)
    ? typed.supportedReasoningEfforts
        .map((entry) => {
          const item =
            entry && typeof entry === "object" ? (entry as Record<string, unknown>) : null;
          const reasoningEffort =
            asString(item?.reasoningEffort) || asString(item?.reasoning_effort);
          const summaryDescription = asString(item?.description);
          if (!reasoningEffort || !summaryDescription) {
            return null;
          }
          return { reasoningEffort, description: summaryDescription };
        })
        .filter((entry): entry is ModelSummary["supportedReasoningEfforts"][number] => entry !== null)
    : [];

  return {
    id,
    model,
    displayName,
    description,
    defaultReasoningEffort,
    supportedReasoningEfforts,
    supportsPersonality: typed.supportsPersonality === true,
    additionalSpeedTiers: Array.isArray(typed.additionalSpeedTiers)
      ? typed.additionalSpeedTiers.map((entry) => asString(entry)).filter((entry): entry is string => Boolean(entry))
      : [],
    inputModalities: Array.isArray(typed.inputModalities)
      ? typed.inputModalities.map((entry) => asString(entry)).filter((entry): entry is string => Boolean(entry))
      : [],
    isDefault: typed.isDefault === true,
  };
}

function normalizeProfileConfig(raw: unknown): CodexProfileConfig {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const defaultProfile = asString(typed.profile);
  const modelProvider = readStringKey(typed, "modelProvider", "model_provider");
  const openaiBaseUrl = readStringKey(typed, "openaiBaseUrl", "openai_base_url");
  const modelProviders = normalizeModelProviders(typed.modelProviders ?? typed.model_providers);
  const rawProfiles =
    typed.profiles && typeof typed.profiles === "object"
      ? (typed.profiles as Record<string, unknown>)
      : {};

  const profiles = Object.entries(rawProfiles)
    .map(([name, profile]) =>
      normalizeProfileSummary(name, profile, defaultProfile, modelProviders),
    )
    .filter((profile): profile is CodexProfileSummary => profile !== null)
    .sort(compareProfiles);

  return { defaultProfile, profiles, modelProvider, openaiBaseUrl, modelProviders };
}

function normalizeModelProviders(raw: unknown): Map<string, ConfigModelProviderSummary> {
  const providers = new Map<string, ConfigModelProviderSummary>();
  if (!raw || typeof raw !== "object") {
    return providers;
  }

  for (const [id, value] of Object.entries(raw as Record<string, unknown>)) {
    const typed = value && typeof value === "object" ? (value as Record<string, unknown>) : null;
    if (!id || !typed) {
      continue;
    }
    providers.set(id, {
      id,
      name: readStringKey(typed, "name"),
      baseUrl: readStringKey(typed, "baseUrl", "base_url"),
      envKey: readStringKey(typed, "envKey", "env_key"),
    });
  }

  return providers;
}

function normalizeProfileSummary(
  name: string,
  raw: unknown,
  defaultProfile: string | null,
  modelProviders: Map<string, ConfigModelProviderSummary>,
): CodexProfileSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed || !name) {
    return null;
  }

  const modelProvider = readStringKey(typed, "modelProvider", "model_provider");
  const provider = modelProvider ? modelProviders.get(modelProvider) : null;

  return {
    name,
    isDefault: name === defaultProfile,
    model: readStringKey(typed, "model"),
    modelProvider,
    modelProviderName: provider?.name ?? null,
    modelProviderBaseUrl:
      provider?.baseUrl ?? readStringKey(typed, "openaiBaseUrl", "openai_base_url"),
    approvalPolicy: readStringKey(typed, "approvalPolicy", "approval_policy"),
    sandboxMode: readStringKey(typed, "sandboxMode", "sandbox_mode"),
    serviceTier: readStringKey(typed, "serviceTier", "service_tier"),
    reasoningEffort: readStringKey(
      typed,
      "modelReasoningEffort",
      "model_reasoning_effort",
    ),
    reasoningSummary: readStringKey(
      typed,
      "modelReasoningSummary",
      "model_reasoning_summary",
    ),
    verbosity: readStringKey(typed, "modelVerbosity", "model_verbosity"),
    webSearch: readStringKey(typed, "webSearch", "web_search"),
    personality: readStringKey(typed, "personality"),
  };
}

function compareProfiles(left: CodexProfileSummary, right: CodexProfileSummary): number {
  if (left.isDefault !== right.isDefault) {
    return left.isDefault ? -1 : 1;
  }
  return left.name.toLowerCase().localeCompare(right.name.toLowerCase());
}

function readStringKey(
  typed: Record<string, unknown>,
  camelKey: string,
  snakeKey?: string,
): string | null {
  return asString(typed[camelKey]) ?? (snakeKey ? asString(typed[snakeKey]) : null);
}

function normalizeSkillSummary(
  raw: unknown,
  workspaceSkillRoots: string[] = [],
): SkillSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const name = asString(typed.name);
  const description = asString(typed.description);
  const path = asString(typed.path);
  if (!name || !description || !path) {
    return null;
  }

  const interfaceValue =
    typed.interface && typeof typed.interface === "object"
      ? (typed.interface as Record<string, unknown>)
      : null;

  return {
    name,
    description,
    shortDescription: asString(typed.shortDescription) || asString(typed.short_description),
    interface: interfaceValue
      ? {
          displayName:
            asString(interfaceValue.displayName) || asString(interfaceValue.display_name),
          shortDescription:
            asString(interfaceValue.shortDescription) ||
            asString(interfaceValue.short_description),
          brandColor:
            asString(interfaceValue.brandColor) || asString(interfaceValue.brand_color),
          defaultPrompt:
            asString(interfaceValue.defaultPrompt) || asString(interfaceValue.default_prompt),
        }
      : null,
    path,
    scope: isUnderAnyPath(path, workspaceSkillRoots)
      ? "repo"
      : asString(typed.scope) || "user",
    enabled: typed.enabled !== false,
  };
}

function isUnderAnyPath(path: string, roots: string[]): boolean {
  if (roots.length === 0) {
    return false;
  }
  const resolvedPath = nodePath.resolve(path);
  return roots.some((root) => {
    const resolvedRoot = nodePath.resolve(root);
    return (
      resolvedPath === resolvedRoot ||
      resolvedPath.startsWith(`${resolvedRoot}${nodePath.sep}`)
    );
  });
}

function normalizeSkillErrorInfo(raw: unknown): SkillErrorInfo | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const path = asString(typed.path);
  const message = asString(typed.message);
  if (!path || !message) {
    return null;
  }

  return { path, message };
}

function buildRuntimeFromThreadStart(raw: unknown): SessionRuntimeSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const runtime = {
    model: asString(typed.model) ?? undefined,
    modelProvider:
      asString(typed.modelProvider) ??
      asString(typed.model_provider) ??
      undefined,
    serviceTier:
      asString(typed.serviceTier) ??
      asString(typed.service_tier) ??
      undefined,
    reasoningEffort:
      asString(typed.reasoningEffort) ??
      asString(typed.reasoning_effort) ??
      undefined,
    approvalPolicy:
      asString(typed.approvalPolicy) ??
      asString(typed.approval_policy) ??
      undefined,
    sandboxMode:
      asString((typed.sandbox as Record<string, unknown> | undefined)?.type) ??
      asString(
        (typed.permissionProfile as Record<string, unknown> | undefined)
          ?.sandboxMode,
      ) ??
      undefined,
    networkAccess:
      parseOptionalBool(
        (typed.sandbox as Record<string, unknown> | undefined)?.networkAccess,
      ) ??
      parseOptionalBool(
        (typed.sandbox as Record<string, unknown> | undefined)?.network_access,
      ) ??
      undefined,
  } satisfies SessionRuntimeSummary;

  if (
    !runtime.model &&
    !runtime.modelProvider &&
    !runtime.serviceTier &&
    !runtime.reasoningEffort &&
    !runtime.approvalPolicy &&
    !runtime.sandboxMode &&
    runtime.networkAccess === undefined
  ) {
    return null;
  }

  return runtime;
}

function parseCreateSessionOverrides(value: unknown): CreateSessionOverrides {
  const typed = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  return {
    model: asString(typed.model),
    reasoningEffort: parseReasoningEffort(typed.reasoningEffort),
    fastMode: parseOptionalBool(typed.fastMode),
    approvalPolicy: parseApprovalPolicy(typed.approvalPolicy),
    sandboxMode: parseSandboxMode(typed.sandboxMode),
    webSearch: parseWebSearchMode(typed.webSearch),
    profile: asString(typed.profile),
  };
}

interface TurnOverrides {
  model: string | null;
  reasoningEffort: ReasoningEffortValue | null;
  fastMode: boolean | null;
  approvalPolicy: ApprovalPolicyValue | null;
  sandboxMode: SandboxModeValue | null;
  networkAccess: boolean | null;
}

function parseTurnOverrides(value: unknown): TurnOverrides {
  const typed = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  return {
    model: asString(typed.model),
    reasoningEffort: parseReasoningEffort(typed.reasoningEffort),
    fastMode: parseOptionalBool(typed.fastMode),
    approvalPolicy: parseApprovalPolicy(typed.approvalPolicy),
    sandboxMode: parseSandboxMode(typed.sandbox ?? typed.sandboxMode),
    networkAccess: parseOptionalBool(typed.networkAccess),
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

/**
 * Build the v2 `SandboxPolicy` tagged object that `turn/start` expects.
 * The wire format uses camelCase variant tags (`workspaceWrite`, etc.) and
 * typed fields like `networkAccess`. This is deliberately different from
 * `thread/start`, which takes a simpler `SandboxMode` string enum.
 */
function buildSandboxPolicyV2(
  mode: SandboxModeValue | null,
  networkAccess: boolean | null,
): Record<string, unknown> | null {
  // If only networkAccess was provided without a mode, we can't build a policy
  // (we don't know which variant to pick). Skip instead of guessing.
  if (!mode) {
    return null;
  }
  switch (mode) {
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    case "read-only":
      return {
        type: "readOnly",
        networkAccess: networkAccess ?? false,
      };
    case "workspace-write":
      return {
        type: "workspaceWrite",
        networkAccess: networkAccess ?? false,
      };
    default:
      return null;
  }
}

function parseApprovalPolicy(value: unknown): ApprovalPolicyValue | null {
  const policy = asString(value);
  switch (policy) {
    case "untrusted":
    case "on-failure":
    case "on-request":
    case "never":
      return policy;
    default:
      return null;
  }
}

function parseSandboxMode(value: unknown): SandboxModeValue | null {
  const mode = asString(value);
  switch (mode) {
    case "read-only":
    case "workspace-write":
    case "danger-full-access":
      return mode;
    default:
      return null;
  }
}

function parseWebSearchMode(value: unknown): WebSearchModeValue | null {
  const mode = asString(value);
  switch (mode) {
    case "disabled":
    case "cached":
    case "live":
      return mode;
    default:
      return null;
  }
}

function parseReasoningEffort(value: unknown): ReasoningEffortValue | null {
  const effort = asString(value);
  switch (effort) {
    case "none":
    case "minimal":
    case "low":
    case "medium":
    case "high":
    case "xhigh":
      return effort;
    default:
      return null;
  }
}

function buildThreadConfigOverrides(
  overrides: CreateSessionOverrides,
): Record<string, unknown> | null {
  const config: Record<string, unknown> = {};
  if (overrides.profile) {
    config.profile = overrides.profile;
  }
  if (overrides.webSearch) {
    config.web_search = overrides.webSearch;
  }
  if (overrides.reasoningEffort) {
    config.model_reasoning_effort = overrides.reasoningEffort;
  }
  return Object.keys(config).length > 0 ? config : null;
}

function formatPermissionRequestDetail(reason: unknown, permissions: unknown): string {
  const parts = [asString(reason) || "Codex requested additional permissions."];
  const summary = summarizePermissions(permissions);
  if (summary) {
    parts.push(summary);
  }
  return parts.join("\n\n");
}

function summarizePermissions(permissions: unknown): string | null {
  if (!permissions || typeof permissions !== "object") {
    return null;
  }

  const typed = permissions as Record<string, any>;
  const lines: string[] = [];

  const fileSystem = typed.fileSystem as Record<string, any> | undefined;
  if (fileSystem) {
    appendPermissionPaths(lines, "File read", fileSystem.read);
    appendPermissionPaths(lines, "File write", fileSystem.write);
  }

  const network = typed.network as Record<string, any> | undefined;
  if (network) {
    if (typeof network.mode === "string") {
      lines.push(`Network: ${network.mode}`);
    } else if (network.enabled === true) {
      lines.push("Network: enabled");
    }
  }

  if (lines.length === 0) {
    const fallback = JSON.stringify(permissions, null, 2);
    return fallback === "{}" ? null : fallback;
  }

  return lines.join("\n");
}

function appendPermissionPaths(lines: string[], label: string, paths: unknown): void {
  if (!Array.isArray(paths) || paths.length === 0) {
    return;
  }
  const normalized = paths.filter((path): path is string => typeof path === "string" && path.length > 0);
  if (normalized.length === 0) {
    return;
  }
  lines.push(`${label}: ${normalized.join(", ")}`);
}
