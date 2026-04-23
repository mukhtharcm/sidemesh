import { createServer } from "node:http";
import { hostname, platform } from "node:os";
import { randomUUID } from "node:crypto";

import cors from "cors";
import express, { type Request, type Response, type NextFunction } from "express";
import { WebSocketServer, type WebSocket } from "ws";

import type {
  ActiveTurnState,
  LiveEvent,
  SessionActivity,
  NodeConfig,
  PendingAction,
  PendingActionRecord,
  SessionMessage,
  SessionRuntimeSummary,
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
import { loadRolloutLog, loadSessionRuntime } from "./history.js";

const DEFAULT_SOURCES = ["cli", "vscode", "exec", "appServer"];
const SESSION_LOG_CACHE_LIMIT = 24;

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

type ApprovalPolicyValue = "untrusted" | "on-failure" | "on-request" | "never";
type SandboxModeValue = "read-only" | "workspace-write" | "danger-full-access";
type WebSearchModeValue = "disabled" | "cached" | "live";

interface CreateSessionOverrides {
  model: string | null;
  approvalPolicy: ApprovalPolicyValue | null;
  sandboxMode: SandboxModeValue | null;
  webSearch: WebSearchModeValue | null;
  profile: string | null;
}

export async function startServer(config: NodeConfig): Promise<void> {
  const bridge = new CodexBridge(config.codexBin);
  await bridge.start();

  const app = express();
  const server = createServer(app);
  const socketsBySession = new Map<string, Set<WebSocket>>();
  const activeTurns = new Map<string, ActiveTurnState>();
  const pendingActions = new Map<string, PendingActionRecord>();
  const liveActivities = new Map<string, Map<string, SessionActivity>>();
  const runtimeCache = new Map<string, SessionRuntimeCacheEntry>();
  const logCache = new Map<string, SessionLogCacheEntry>();
  const sessionSeqCursor = new Map<string, number>();
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

  bridge.on("stderr", (line) => {
    process.stderr.write(line);
  });

  bridge.on("notification", ({ method, params }) => {
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
      if (delta) {
        broadcastLive(sessionId, {
          type: "assistant_delta",
          sessionId,
          delta,
          turnId: asString((params as any)?.turnId) || undefined,
        });
      }
      return;
    }

    if (method === "item/started" || method === "item/completed") {
      const item = (params as any)?.item;
      const turnId = asString((params as any)?.turnId);
      if (item && typeof item === "object") {
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
          socketsBySession,
          sessionId,
          broadcastLive,
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
  app.use(express.json({ limit: "1mb" }));

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

  app.post("/api/sessions/create", asyncRoute(async (request, response) => {
    const cwd = asString(request.body?.cwd);
    const prompt = asString(request.body?.prompt);
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

    let turnId: string | null = null;
    if (prompt) {
      const turn = (await bridge.request("turn/start", {
        threadId: thread.id,
        input: [{ type: "text", text: prompt, text_elements: [] }],
      })) as any;
      turnId = asString(turn.turn?.id) || null;
      if (turnId) {
        activeTurns.set(thread.id, { turnId, startedAt: Date.now() });
      }
    }

    response.status(201).json({
      session: mapSession(thread),
      activeTurnId: turnId,
    });
  }));

  app.post("/api/sessions/:sessionId/input", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const text = asString(request.body?.text);
    const clientMessageId = asString(request.body?.clientMessageId);
    if (!text) {
      response.status(400).json({ error: "text is required" });
      return;
    }

    const submittedMessage = buildSubmittedUserMessage(text, clientMessageId, allocSeq(sessionId));
    const state = await loadRunState(bridge, sessionId, activeTurns);
    if (state.turnId) {
      const steer = (await bridge.request("turn/steer", {
        threadId: sessionId,
        input: [{ type: "text", text, text_elements: [] }],
        expectedTurnId: state.turnId,
      })) as any;
      broadcastLive(sessionId, {
        type: "user_message_submitted",
        sessionId,
        turnId: state.turnId,
        messageItem: submittedMessage,
      });
      response.json({
        mode: "steer",
        turnId: asString(steer.turnId),
        messageId: submittedMessage.id,
      });
      return;
    }

    if (!(await isThreadLoaded(bridge, sessionId))) {
      await bridge.request("thread/resume", {
        threadId: sessionId,
        persistExtendedHistory: true,
      });
    }
    const turn = (await bridge.request("turn/start", {
      threadId: sessionId,
      input: [{ type: "text", text, text_elements: [] }],
    })) as any;
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
    response.json({
      mode: "turn",
      turnId,
      messageId: submittedMessage.id,
    });
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
    response.json({ ok: true });
  }));

  const wsServer = new WebSocketServer({ noServer: true });
  server.on("upgrade", (request, socket, head) => {
    const [pathOnly, queryString] = (request.url || "").split("?");
    if (pathOnly !== "/api/live") {
      socket.destroy();
      return;
    }

    const authHeader = request.headers.authorization;
    const token = authHeader?.startsWith("Bearer ") ? authHeader.slice("Bearer ".length) : "";
    if (token !== config.token) {
      socket.destroy();
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
  return Promise.all(
    threads.map(async (thread) =>
      mapSession(
        thread,
        await loadCachedSessionRuntime(bridge, thread, runtimeCache),
      ),
    ),
  );
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
  };
}

function sanitizeTitle(raw: string): string {
  const compact = raw.replace(/\s+/g, " ").trim();
  if (!compact) {
    return "Untitled session";
  }
  return compact.length > 90 ? `${compact.slice(0, 87)}...` : compact;
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
  text: string,
  clientMessageId: string | null,
  seq: number,
): SessionMessage {
  return {
    id: clientMessageId || randomUUID(),
    role: "user",
    text,
    createdAt: Date.now(),
    seq,
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
  _socketsBySession: Map<string, Set<WebSocket>>,
  sessionId: string,
  broadcastLive: (sessionId: string, event: LiveEvent) => void,
): void {
  const toDelete = [...pendingActions.values()].filter((action) => action.sessionId === sessionId);
  for (const action of toDelete) {
    pendingActions.delete(action.id);
    broadcastLive(sessionId, {
      type: "action_resolved",
      sessionId,
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

function sendEvent(socket: WebSocket, event: LiveEvent): void {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(event));
  }
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function parseCreateSessionOverrides(value: unknown): CreateSessionOverrides {
  const typed = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  return {
    model: asString(typed.model),
    approvalPolicy: parseApprovalPolicy(typed.approvalPolicy),
    sandboxMode: parseSandboxMode(typed.sandboxMode),
    webSearch: parseWebSearchMode(typed.webSearch),
    profile: asString(typed.profile),
  };
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
