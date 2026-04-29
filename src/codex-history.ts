import { createReadStream } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";

import {
  buildCommandActivityFromGuardianAssessment,
  buildCommandActivityFromRolloutEvent,
  buildFileChangeActivityFromRolloutEvent,
  buildImageGenerationActivityFromRolloutEvent,
  buildWebSearchActivityFromRolloutEvent,
} from "./activity.js";
import type {
  SessionLogSnapshot,
  SessionActivity,
  SessionMessageAttachment,
  SessionMessage,
  SessionRuntimeSummary,
  ThreadRecord,
} from "./types.js";

const RECENT_ROLLOUT_SCAN_DAYS = 3;

export async function loadRolloutLog(
  sessionId: string,
  rolloutPath: string | null,
  codexHomePath: string | null,
  messageLimit: number | null = null,
  activityLimit: number | null = null,
): Promise<SessionLogSnapshot> {
  const resolvedPath = await resolveRolloutPath(sessionId, rolloutPath, codexHomePath);
  if (!resolvedPath || !(await rolloutExists(resolvedPath))) {
    return emptyRolloutLog();
  }

  try {
    return await scanRolloutFile(resolvedPath, {
      includeMessages: true,
      messageLimit,
      includeActivities: true,
      activityLimit,
    });
  } catch (error) {
    if (isMissingRolloutFileError(error)) {
      return emptyRolloutLog();
    }
    throw error;
  }
}

export async function loadSessionRuntime(
  sessionId: string,
  rolloutPath: string | null,
  codexHomePath: string | null,
): Promise<SessionRuntimeSummary | null> {
  const resolvedPath = await resolveRolloutPath(sessionId, rolloutPath, codexHomePath);
  if (!resolvedPath || !(await rolloutExists(resolvedPath))) {
    return null;
  }

  try {
    const parsed = await scanRolloutFile(resolvedPath, {
      includeMessages: false,
      includeActivities: false,
    });
    return parsed.runtime;
  } catch (error) {
    if (isMissingRolloutFileError(error)) {
      return null;
    }
    throw error;
  }
}

export async function listRecentRolloutThreads(
  codexHomePath: string | null,
  limit: number,
): Promise<ThreadRecord[]> {
  if (!codexHomePath || limit <= 0) {
    return [];
  }

  const sessionsRoot = path.join(codexHomePath, "sessions");
  const files = await listRecentRolloutFiles(sessionsRoot, limit);
  const threads = (
    await Promise.all(files.map((filePath) => readRolloutThreadSummary(filePath)))
  ).filter((thread): thread is ThreadRecord => thread !== null);

  return threads
    .sort((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, limit);
}

async function listRecentRolloutFiles(
  sessionsRoot: string,
  limit: number,
): Promise<string[]> {
  const candidates: Array<{ path: string; sortKey: string }> = [];

  for (let offset = 0; offset < RECENT_ROLLOUT_SCAN_DAYS; offset += 1) {
    const day = new Date(Date.now() - offset * 24 * 60 * 60 * 1000);
    const dayDir = path.join(
      sessionsRoot,
      String(day.getFullYear()),
      String(day.getMonth() + 1).padStart(2, "0"),
      String(day.getDate()).padStart(2, "0"),
    );

    const entries = await import("node:fs/promises").then(({ readdir }) =>
      readdir(dayDir, { withFileTypes: true }).catch(() => []),
    );
    for (const entry of entries) {
      if (!entry.isFile() || !entry.name.startsWith("rollout-") || !entry.name.endsWith(".jsonl")) {
        continue;
      }
      candidates.push({
        path: path.join(dayDir, entry.name),
        sortKey: entry.name,
      });
    }
  }

  return candidates
    .sort((left, right) => right.sortKey.localeCompare(left.sortKey))
    .slice(0, limit)
    .map((candidate) => candidate.path);
}

function emptyRolloutLog(): SessionLogSnapshot {
  return {
    messages: [],
    activities: [],
    runtime: null,
    totalMessages: 0,
    totalActivities: 0,
    nextSeq: 0,
  };
}

function isMissingRolloutFileError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === "ENOENT"
  );
}

async function resolveRolloutPath(
  sessionId: string,
  rolloutPath: string | null,
  codexHomePath: string | null,
): Promise<string | null> {
  return rolloutPath || (await findRolloutPath(sessionId, codexHomePath));
}

async function scanRolloutFile(
  rolloutPath: string,
  options: {
    includeMessages: boolean;
    messageLimit?: number | null;
    includeActivities: boolean;
    activityLimit?: number | null;
  },
): Promise<SessionLogSnapshot> {
  const messages: SessionMessage[] = [];
  const activities: SessionActivity[] = [];
  let runtime: SessionRuntimeSummary | null = null;
  const pendingTurnRuntime = new Map<string, SessionRuntimeSummary>();
  let totalMessages = 0;
  let totalActivities = 0;
  let seq = 0;
  const file = createReadStream(rolloutPath, { encoding: "utf8" });
  const lines = readline.createInterface({ input: file, crlfDelay: Infinity });

  for await (const line of lines) {
    const parsed = parseJsonLine(line);
    if (!parsed) {
      continue;
    }

    const nextRuntime = parseRuntime(parsed);
    if (nextRuntime) {
      if (nextRuntime.turnId) {
        pendingTurnRuntime.set(
          nextRuntime.turnId,
          mergeRuntime(pendingTurnRuntime.get(nextRuntime.turnId) ?? null, nextRuntime),
        );
      } else {
        runtime = mergeRuntime(runtime, nextRuntime);
      }
    }

    const committedTurnId = resolveCommittedTurnId(parsed);
    if (committedTurnId) {
      const committed = pendingTurnRuntime.get(committedTurnId);
      if (committed) {
        runtime = mergeRuntime(runtime, {
          ...committed,
          updatedAt: parseTimestamp(parsed.timestamp),
        });
      }
      pendingTurnRuntime.delete(committedTurnId);
    }

    const discardedTurnId = resolveDiscardedTurnId(parsed);
    if (discardedTurnId) {
      pendingTurnRuntime.delete(discardedTurnId);
    }

    if (options.includeMessages) {
      const entry = parseMessage(parsed, seq);
      if (entry) {
        totalMessages += 1;
        seq += 1;
        appendBounded(messages, entry, options.messageLimit ?? null);
      }
    }

    if (options.includeActivities) {
      const activity = parseActivity(parsed, seq);
      if (activity) {
        totalActivities += 1;
        seq += 1;
        appendBounded(activities, activity, options.activityLimit ?? null);
      }
    }
  }

  return { messages, activities, runtime, totalMessages, totalActivities, nextSeq: seq };
}

async function findRolloutPath(sessionId: string, codexHomePath: string | null): Promise<string | null> {
  if (!codexHomePath) {
    return null;
  }

  const sessionsRoot = path.join(codexHomePath, "sessions");
  const parts = await walkDirectories(sessionsRoot, 0);
  for (const candidate of parts) {
    if (candidate.includes(sessionId) && candidate.endsWith(".jsonl")) {
      return candidate;
    }
  }

  return null;
}

async function readRolloutThreadSummary(rolloutPath: string): Promise<ThreadRecord | null> {
  const file = createReadStream(rolloutPath, { encoding: "utf8" });
  const lines = readline.createInterface({ input: file, crlfDelay: Infinity });
  let meta: Record<string, any> | null = null;
  let preview = "";
  let latestTimestamp = 0;
  let inProgress = false;

  for await (const line of lines) {
    const parsed = parseJsonLine(line);
    if (!parsed) {
      continue;
    }

    latestTimestamp = Math.max(latestTimestamp, parseTimestamp(parsed.timestamp));
    if (parsed.type === "session_meta" && parsed.payload && typeof parsed.payload === "object") {
      meta = parsed.payload as Record<string, any>;
      latestTimestamp = Math.max(latestTimestamp, parseTimestamp(meta.timestamp));
      continue;
    }

    if (parsed.type !== "event_msg") {
      continue;
    }

    if (parsed.payload?.type === "user_message" && !preview) {
      preview = typeof parsed.payload.message === "string" ? parsed.payload.message : "";
    }
    if (parsed.payload?.type === "task_started") {
      inProgress = true;
    } else if (
      parsed.payload?.type === "task_complete" ||
      parsed.payload?.type === "turn_aborted"
    ) {
      inProgress = false;
    }
  }

  const id = asOptionalString(meta?.id);
  const cwd = asOptionalString(meta?.cwd);
  if (!id || !cwd) {
    return null;
  }

  const createdAt = Math.floor(parseTimestamp(meta?.timestamp) / 1000);
  const updatedAt = Math.floor((latestTimestamp || parseTimestamp(meta?.timestamp)) / 1000);
  return {
    id,
    name: null,
    preview,
    createdAt,
    updatedAt,
    cwd,
    source: normalizeThreadSource(meta?.source),
    path: rolloutPath,
    status: { type: inProgress ? "running" : "idle" },
    gitInfo: null,
  };
}

function normalizeThreadSource(source: unknown): ThreadRecord["source"] {
  if (typeof source === "string") {
    return source;
  }
  if (source && typeof source === "object") {
    return source as ThreadRecord["source"];
  }
  return "unknown";
}

async function walkDirectories(root: string, depth: number): Promise<string[]> {
  if (depth > 4) {
    return [];
  }

  const entries = await import("node:fs/promises").then(({ readdir }) =>
    readdir(root, { withFileTypes: true }).catch(() => []),
  );
  const files: string[] = [];
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isFile()) {
      files.push(fullPath);
      continue;
    }
    if (entry.isDirectory()) {
      files.push(...(await walkDirectories(fullPath, depth + 1)));
    }
  }
  return files;
}

function parseMessage(parsed: any, seq: number): SessionMessage | null {
  const createdAt = parseTimestamp(parsed.timestamp);
  if (parsed.type === "event_msg") {
    const payloadType = parsed.payload?.type;
    if (payloadType === "user_message") {
      const text = typeof parsed.payload?.message === "string" ? parsed.payload.message : "";
      const attachments = parseMessageAttachments(parsed.payload);
      if (!text && attachments.length === 0) {
        return null;
      }
      return {
        id: `${createdAt}-user`,
        role: "user",
        text,
        attachments,
        createdAt,
        seq,
      };
    }
    if (payloadType === "agent_message" && typeof parsed.payload?.message === "string") {
      return {
        id: `${createdAt}-assistant-${parsed.payload.phase || "final_answer"}`,
        role: "assistant",
        text: parsed.payload.message,
        attachments: [],
        createdAt,
        seq,
        phase: parsed.payload.phase || "final_answer",
      };
    }
    if (payloadType === "turn_aborted") {
      return {
        id: `${createdAt}-system-turn_aborted`,
        role: "system",
        text: `Turn aborted: ${parsed.payload?.reason || "unknown"}`,
        attachments: [],
        createdAt,
        seq,
      };
    }
  }

  return null;
}

function parseMessageAttachments(payload: any): SessionMessageAttachment[] {
  const attachments: SessionMessageAttachment[] = [];
  const images = Array.isArray(payload?.images) ? payload.images : [];
  for (const url of images) {
    if (typeof url === "string" && url.length > 0) {
      attachments.push({ type: "image", url });
    }
  }

  const localImages = Array.isArray(payload?.local_images) ? payload.local_images : [];
  for (const path of localImages) {
    if (typeof path === "string" && path.length > 0) {
      attachments.push({ type: "localImage", path });
    }
  }

  return attachments;
}

function parseActivity(parsed: any, seq: number): SessionActivity | null {
  if (parsed.type !== "event_msg") {
    return null;
  }

  const payload = parsed.payload;
  const createdAt = parseTimestamp(parsed.timestamp);
  switch (payload?.type) {
    case "exec_command_end":
      return buildCommandActivityFromRolloutEvent(payload, createdAt, seq);
    case "patch_apply_end":
      return buildFileChangeActivityFromRolloutEvent(payload, createdAt, seq);
    case "web_search_begin":
      return buildWebSearchActivityFromRolloutEvent(payload, createdAt, seq);
    case "web_search_end":
      return buildWebSearchActivityFromRolloutEvent(payload, createdAt, seq);
    case "image_generation_begin":
      return buildImageGenerationActivityFromRolloutEvent(
        { ...payload, status: "in_progress" },
        createdAt,
        seq,
      );
    case "image_generation_end":
      return buildImageGenerationActivityFromRolloutEvent(
        payload,
        createdAt,
        seq,
      );
    case "guardian_assessment":
      return buildCommandActivityFromGuardianAssessment(payload, createdAt, seq);
    default:
      return null;
  }
}

function parseRuntime(parsed: any): SessionRuntimeSummary | null {
  if (!parsed) {
    return null;
  }

  if (parsed.type === "session_configured") {
    const payload = parsed.payload;
    if (!payload || typeof payload !== "object") {
      return null;
    }

    const typed = payload as Record<string, any>;
    const runtime = {
      model: asOptionalString(typed.model),
      modelProvider: asOptionalString(typed.model_provider),
      serviceTier: asOptionalString(typed.service_tier),
      reasoningEffort: asOptionalString(typed.reasoning_effort),
      approvalPolicy: asOptionalString(typed.approval_policy),
      sandboxMode: asOptionalString(typed.sandbox_policy?.type),
      networkAccess: asOptionalBoolean(typed.sandbox_policy?.network_access),
      updatedAt: parseTimestamp(parsed.timestamp),
      turnId: undefined,
    };

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

  if (parsed.type === "session_meta") {
    const payload = parsed.payload;
    if (!payload || typeof payload !== "object") {
      return null;
    }
    const typed = payload as Record<string, any>;
    const runtime = {
      modelProvider: asOptionalString(typed.model_provider),
      updatedAt: parseTimestamp(parsed.timestamp),
      turnId: undefined,
    };
    return runtime.modelProvider ? runtime : null;
  }

  if (parsed.type !== "turn_context") {
    return null;
  }

  const payload = parsed.payload;
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const typed = payload as Record<string, any>;
  const collaborationSettings =
    typed.collaboration_mode &&
    typeof typed.collaboration_mode === "object" &&
    typed.collaboration_mode.settings &&
    typeof typed.collaboration_mode.settings === "object"
      ? (typed.collaboration_mode.settings as Record<string, any>)
      : null;

  const runtime = {
    model: asOptionalString(typed.model) || asOptionalString(collaborationSettings?.model),
    modelProvider: asOptionalString(typed.model_provider),
    serviceTier: undefined,
    reasoningEffort:
      asOptionalString(typed.effort) || asOptionalString(collaborationSettings?.reasoning_effort),
    approvalPolicy: asOptionalString(typed.approval_policy),
    sandboxMode: asOptionalString(typed.sandbox_policy?.type),
    networkAccess: asOptionalBoolean(typed.sandbox_policy?.network_access),
    summaryMode: asOptionalString(typed.summary),
    personality: asOptionalString(typed.personality),
    updatedAt: parseTimestamp(parsed.timestamp),
    turnId: asOptionalString(typed.turn_id) || asOptionalString(typed.turnId),
  };

  if (
    !runtime.model &&
    !runtime.modelProvider &&
    !runtime.serviceTier &&
    !runtime.reasoningEffort &&
    !runtime.approvalPolicy &&
    !runtime.sandboxMode &&
    runtime.networkAccess === undefined &&
    !runtime.summaryMode &&
    !runtime.personality
  ) {
    return null;
  }

  return runtime;
}

function mergeRuntime(
  previous: SessionRuntimeSummary | null,
  next: SessionRuntimeSummary,
): SessionRuntimeSummary {
  if (!previous) {
    return next;
  }

  return {
    model: next.model ?? previous.model,
    modelProvider: next.modelProvider ?? previous.modelProvider,
    serviceTier: next.serviceTier ?? previous.serviceTier,
    reasoningEffort: next.reasoningEffort ?? previous.reasoningEffort,
    approvalPolicy: next.approvalPolicy ?? previous.approvalPolicy,
    sandboxMode: next.sandboxMode ?? previous.sandboxMode,
    networkAccess: next.networkAccess ?? previous.networkAccess,
    summaryMode: next.summaryMode ?? previous.summaryMode,
    personality: next.personality ?? previous.personality,
    updatedAt: next.updatedAt ?? previous.updatedAt,
    turnId: next.turnId ?? previous.turnId,
  };
}

function resolveCommittedTurnId(parsed: any): string | null {
  if (parsed?.type !== "event_msg") {
    return null;
  }

  const payload = parsed.payload;
  if (!payload || typeof payload !== "object" || payload.type !== "task_complete") {
    return null;
  }

  if (payload.last_agent_message == null) {
    return null;
  }

  return asOptionalString(payload.turn_id) || asOptionalString(payload.turnId) || null;
}

function resolveDiscardedTurnId(parsed: any): string | null {
  if (parsed?.type !== "event_msg") {
    return null;
  }

  const payload = parsed.payload;
  if (!payload || typeof payload !== "object") {
    return null;
  }

  if (payload.type === "turn_aborted") {
    return asOptionalString(payload.turn_id) || asOptionalString(payload.turnId) || null;
  }

  if (payload.type === "task_complete" && payload.last_agent_message == null) {
    return asOptionalString(payload.turn_id) || asOptionalString(payload.turnId) || null;
  }

  return null;
}

function appendBounded<T>(entries: T[], next: T, limit: number | null): void {
  if (limit && limit > 0) {
    entries.push(next);
    if (entries.length > limit) {
      entries.shift();
    }
    return;
  }

  entries.push(next);
}

function parseJsonLine(line: string): any | null {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function parseTimestamp(raw: unknown): number {
  if (typeof raw === "number") {
    return raw * 1000;
  }
  if (typeof raw === "string") {
    const parsed = Date.parse(raw);
    if (Number.isFinite(parsed)) {
      return parsed;
    }
  }
  return Date.now();
}

export async function rolloutExists(rolloutPath: string | null): Promise<boolean> {
  if (!rolloutPath) {
    return false;
  }
  try {
    await access(rolloutPath);
    return true;
  } catch {
    return false;
  }
}

function asOptionalString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function asOptionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}
