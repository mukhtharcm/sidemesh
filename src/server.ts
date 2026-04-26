import { createServer } from "node:http";
import { hostname, platform } from "node:os";
import { createHash, randomUUID } from "node:crypto";
import { access, stat } from "node:fs/promises";
import nodePath from "node:path";

import cors from "cors";
import express, { type Request, type Response, type NextFunction } from "express";
import { WebSocketServer, type WebSocket } from "ws";

import {
  materializeAgentActivityDraft,
  type AgentPendingAction,
  type AgentProvider,
  type AgentSessionActivityDraft,
  type AgentSessionInputItem,
  type AgentSessionOverrides,
} from "./agent-provider.js";
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
  SkillCatalogEntry,
  SkillErrorInfo,
  SkillSummary,
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
import { summarizeProviderConfig } from "./config.js";
import { buildGitDiff, readGitDiff, readGitStatus, sanitizeGitUrl } from "./git.js";
import { createAgentProvider } from "./provider-factory.js";
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
const RECENT_UNINDEXED_SESSION_SCAN_LIMIT = 50;

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

export async function startServer(config: NodeConfig): Promise<void> {
  const provider = createAgentProvider(config);
  await provider.start();

  const app = express();
  const server = createServer(app);
  const socketsBySession = new Map<string, Set<WebSocket>>();
  const approvalSockets = new Set<WebSocket>();
  const activeTurns = new Map<string, ActiveTurnState>();
  const pendingActions = new Map<string, AgentPendingAction>();
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
  let providerVersion = "unknown";

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

  provider.on("stderr", (line) => {
    process.stderr.write(line);
  });

  const fsWatchRegistry = new FsWatchRegistry(provider);

  provider.on("liveEvent", (event) => {
    switch (event.type) {
      case "fs_changed":
        fsWatchRegistry.deliver({
          watchId: event.watchId,
          changedPaths: event.changedPaths,
        });
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
        const next = updateLiveCommandActivity(
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
        // NOTE: do NOT reset sessionSeqCursor between turns — clients rely on
        // a monotonically increasing seq across the whole session lifetime to
        // detect gaps after a reconnect.
        return;
      case "action_opened":
        pendingActions.set(event.action.id, event.action);
        broadcastLive(event.action.sessionId, {
          type: "action_opened",
          sessionId: event.action.sessionId,
          action: event.action,
        });
        broadcastApprovalLive({
          type: "action_opened",
          action: event.action,
        });
        return;
    }
  });

  providerVersion = await provider.getVersion();

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
      codexVersion: providerVersion,
      provider: provider.kind,
      providerName: provider.displayName,
      providerVersion,
      providerConfig: summarizeProviderConfig(config.provider),
      providerCapabilities: provider.capabilities,
      startedAt: process.uptime(),
      tokenSource: config.tokenSource,
    });
  });

  app.get("/api/sessions", asyncRoute(async (_request, response) => {
    const requestedLimit = asInteger((_request.query as Record<string, unknown>)?.limit);
    const sessions = await listSessions(provider, runtimeCache, requestedLimit);
    response.json(sessions);
  }));

  app.get("/api/workspaces", asyncRoute(async (_request, response) => {
    const sessions = await listSessions(provider, runtimeCache);
    response.json(buildWorkspaces(sessions));
  }));

  registerFsRoutes(app, {
    provider,
    listSessions: () => listSessions(provider, runtimeCache),
    watchRegistry: fsWatchRegistry,
  });

  app.get("/api/actions", asyncRoute(async (_request, response) => {
    response.json(await listPendingActions(provider, pendingActions));
  }));

  app.get("/api/sessions/:sessionId/log", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const query = request.query as Record<string, unknown>;
    const messageLimit = asInteger(query.messageLimit);
    const activityLimit = asInteger(query.activityLimit);
    const cacheKey = buildSessionLogCacheKey(sessionId, messageLimit, activityLimit);
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
          pendingAction: findPendingActionForSession(pendingActions, sessionId),
          history: cached.history,
        });
        return;
      }
    }

    const session = await readSession(provider, sessionId, false);
    const log = await provider.readSessionLog(session, {
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
  }));

  // Replay endpoint for cheap reconnect / resume. Clients pass `since`
  // (the highest seq they've already observed) and get only newer
  // messages + activities — no re-downloading the full transcript.
  app.get("/api/sessions/:sessionId/events", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const query = request.query as Record<string, unknown>;
    const since = asInteger(query.since) ?? 0;

    const session = await readSession(provider, sessionId, false);
    const log = await provider.readSessionLog(session);
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
    response.json(await readSessionResources(provider, sessionId, liveActivities));
  }));

  app.get("/api/sessions/:sessionId/status", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const state = await loadRunState(provider, sessionId, activeTurns);
    response.json({
      sessionId,
      isRunning: Boolean(state.turnId),
      activeTurnId: state.turnId,
      pendingAction: findPendingActionForSession(pendingActions, sessionId),
    });
  }));

  app.get("/api/sessions/:sessionId/git", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const session = await readSession(provider, sessionId, false);
    response.json(await readGitStatus(session.cwd, mapGitInfo(session.gitInfo)));
  }));

  app.get("/api/sessions/:sessionId/git/diff", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    const kind = parseGitDiffKind((request.query as Record<string, unknown>).kind);
    if (!kind) {
      response.status(400).json({ error: "kind must be working, staged, unstaged, or remote" });
      return;
    }

    const session = await readSession(provider, sessionId, false);
    if (kind === "remote") {
      const result = (await provider.readRemoteGitDiff(session.cwd)) as Record<string, unknown>;
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
    const payload = (await provider.listSkills({
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

    const result = await provider.writeSkillConfig({
      path: path ?? undefined,
      name: name ?? undefined,
      enabled,
    });
    response.json(result);
  }));

  app.get("/api/models", asyncRoute(async (request, response) => {
    if (!provider.capabilities.configuration.models) {
      response.status(501).json({ error: `${provider.displayName} does not support model listing` });
      return;
    }
    const query = request.query as Record<string, unknown>;
    const cwd = asString(query.cwd) || null;
    const profile = asString(query.profile) || null;
    const modelProvider = asString(query.provider) || null;
    response.json(await provider.listModels({
      cwd,
      profile,
      provider: modelProvider,
    }));
  }));

  app.get("/api/profiles", asyncRoute(async (request, response) => {
    const query = request.query as Record<string, unknown>;
    const cwd = asString(query.cwd) || null;
    response.json(await listProfiles(provider, cwd));
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

    const resolvedInput = input.length > 0 ? input : buildLegacyTextInput(prompt);
    const started = await provider.createSession({
      cwd,
      input: resolvedInput,
      overrides,
    });
    if (started.activeTurnId) {
      activeTurns.set(started.thread.id, {
        turnId: started.activeTurnId,
        startedAt: Date.now(),
      });
    }

    response.status(201).json({
      session: mapSession(started.thread, started.runtime),
      activeTurnId: started.activeTurnId,
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
      const state = await loadRunState(provider, sessionId, activeTurns);
      const submitted = await provider.submitInput({
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
    const state = await loadRunState(provider, sessionId, activeTurns);
    if (!state.turnId) {
      response.json({ stopped: false });
      return;
    }
    await provider.interruptTurn(sessionId, state.turnId);
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
    if (!(await isThreadLoaded(provider, sessionId))) {
      await provider.resumeSessionThread(sessionId, {
        persistExtendedHistory: true,
      });
    }
    await provider.setSessionName(sessionId, name);
    const thread = await readSession(provider, sessionId, false);
    response.json({ session: mapSession(thread) });
  }));

  app.post("/api/sessions/:sessionId/archive", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    await provider.archiveSession(sessionId);
    activeTurns.delete(sessionId);
    liveActivities.delete(sessionId);
    clearSessionLogCache(logCache, sessionId);
    sessionSeqCursor.delete(sessionId);
    response.json({ archived: true });
  }));

  app.post("/api/sessions/:sessionId/unarchive", asyncRoute(async (request, response) => {
    const sessionId = pathParam(request.params.sessionId);
    await provider.unarchiveSession(sessionId);
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

    const handled = provider.respondToPendingAction(action, decision);
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
          provider,
          listSessions: () => listSessions(provider, runtimeCache),
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
    console.log(`[sidemesh] provider: ${provider.displayName} (${provider.kind})`);
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
  provider: AgentProvider,
  runtimeCache: Map<string, SessionRuntimeCacheEntry>,
  limitOverride: number | null = null,
): Promise<SessionSummary[]> {
  const limit = Math.max(1, Math.min(limitOverride ?? 100, 100));
  const result = (await provider.listSessionThreads({
    limit,
    sortKey: "updated_at",
    sortDirection: "desc",
    sourceKinds: DEFAULT_SOURCES,
    archived: false,
  })) as any;
  const threads = Array.isArray(result.data) ? (result.data as ThreadRecord[]) : [];
  const mergedThreads = await mergeRecentUnindexedThreads(provider, threads, limit);
  return Promise.all(
    mergedThreads.map(async (thread) =>
      mapSession(
        thread,
        await loadCachedSessionRuntime(provider, thread, runtimeCache),
      ),
    ),
  );
}

async function mergeRecentUnindexedThreads(
  provider: AgentProvider,
  indexedThreads: ThreadRecord[],
  limit: number,
): Promise<ThreadRecord[]> {
  const threadsById = new Map(indexedThreads.map((thread) => [thread.id, thread]));
  const recentThreads = await provider.listRecentUnindexedSessionThreads(
    Math.max(limit, RECENT_UNINDEXED_SESSION_SCAN_LIMIT),
  );

  for (const thread of recentThreads) {
    if (threadsById.has(thread.id)) {
      continue;
    }
    threadsById.set(thread.id, thread);
    if (threadsById.size >= limit) {
      break;
    }
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
  return [...grouped.values()].sort((left, right) => right.lastUsedAt - left.lastUsedAt);
}

async function listPendingActions(
  provider: AgentProvider,
  pendingActions: Map<string, AgentPendingAction>,
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
        sessionPromise = readSession(provider, action.sessionId, false).catch(() => null);
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
  provider: AgentProvider,
  sessionId: string,
  includeTurns: boolean,
): Promise<ThreadRecord> {
  const result = (await provider.readSessionThread(sessionId, includeTurns)) as any;
  return result.thread as ThreadRecord;
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
    session = await readSession(provider, sessionId, true);
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

async function isThreadLoaded(provider: AgentProvider, sessionId: string): Promise<boolean> {
  const result = (await provider.listLoadedSessionIds()) as any;
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
): Promise<SessionRuntimeSummary | null> {
  const cached = runtimeCache.get(thread.id);
  if (cached && cached.threadUpdatedAt === thread.updatedAt) {
    return cached.runtime;
  }

  const runtime = await provider.readSessionRuntime(thread);
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
  provider: AgentProvider,
  sessionId: string,
  liveActivities: Map<string, Map<string, SessionActivity>>,
): Promise<SessionResourcesResponse> {
  const session = await readSession(provider, sessionId, false);
  const log = await provider.readSessionLog(session);
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

function clearActionsForSession(
  pendingActions: Map<string, AgentPendingAction>,
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
  pendingActions: Map<string, AgentPendingAction>,
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

function buildSubmittedUserMessageText(input: AgentSessionInputItem[]): string {
  return input
    .filter((item): item is Extract<AgentSessionInputItem, { type: "text" }> => item.type === "text")
    .map((item) => item.text.trim())
    .filter(Boolean)
    .join("\n\n");
}

function buildSubmittedUserMessageAttachments(input: AgentSessionInputItem[]): SessionMessageAttachment[] {
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

async function listProfiles(
  provider: AgentProvider,
  cwd: string | null,
): Promise<CodexProfileCatalog> {
  const profileConfig = await readProfileConfig(provider, cwd);
  return {
    defaultProfile: profileConfig.defaultProfile,
    profiles: profileConfig.profiles,
  };
}

async function readProfileConfig(
  provider: AgentProvider,
  cwd: string | null,
): Promise<CodexProfileConfig> {
  const payload = (await provider.readConfig({
    includeLayers: false,
    cwd: cwd ?? undefined,
  })) as { config?: unknown };
  return normalizeProfileConfig(payload.config);
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

function parseCreateSessionOverrides(value: unknown): AgentSessionOverrides {
  const typed = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  return {
    model: asString(typed.model),
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
  const typed = value && typeof value === "object" ? (value as Record<string, unknown>) : {};
  return {
    model: asString(typed.model),
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
