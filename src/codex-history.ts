import { createReadStream } from "node:fs";
import { access, open, stat } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";

import {
  buildCommandActivityFromGuardianAssessment,
  buildCommandActivityFromRolloutEvent,
  buildFileChangeActivityFromRolloutEvent,
  buildImageGenerationActivityFromRolloutEvent,
  buildWebSearchActivityFromRolloutEvent,
  mergeActivity,
} from "./activity.js";
import { extractSessionAttachments } from "./session-attachments.js";
import type {
  CommandActivity,
  SessionLogSnapshot,
  SessionActivity,
  SessionMessageAttachment,
  SessionMessage,
  SessionSubAgentInfo,
  SessionRuntimeSummary,
  ThreadRecord,
  ToolActivity,
} from "./types.js";

const RECENT_ROLLOUT_SCAN_DAYS = 3;
const LARGE_ROLLOUT_FAST_SCAN_THRESHOLD_BYTES = 2 * 1024 * 1024;
const ROLLOUT_HEAD_SCAN_BYTES = 256 * 1024;
const ROLLOUT_TAIL_SCAN_BYTES = 1024 * 1024;

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
    if (await shouldUseFastRolloutScan(resolvedPath)) {
      return await scanRolloutRuntimeFast(resolvedPath);
    }
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
  const cutoffMs = Date.now() - RECENT_ROLLOUT_SCAN_DAYS * 24 * 60 * 60 * 1000;
  const candidates = await collectRecentRolloutFiles(sessionsRoot, cutoffMs, 0);
  return candidates
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
    .slice(0, limit)
    .map((candidate) => candidate.path);
}

async function collectRecentRolloutFiles(
  root: string,
  cutoffMs: number,
  depth: number,
): Promise<Array<{ path: string; mtimeMs: number }>> {
  if (depth > 4) {
    return [];
  }

  let entries: any[];
  try {
    entries = await import("node:fs/promises").then(({ readdir }) =>
      readdir(root, { withFileTypes: true }),
    );
  } catch {
    return [];
  }

  const result: Array<{ path: string; mtimeMs: number }> = [];
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isFile()) {
      if (!entry.name.startsWith("rollout-") || !entry.name.endsWith(".jsonl")) {
        continue;
      }
      try {
        const stats = await stat(fullPath);
        if (stats.mtimeMs >= cutoffMs) {
          result.push({ path: fullPath, mtimeMs: stats.mtimeMs });
        }
      } catch {
        // Race with deletion or rotation; ignore.
      }
    } else if (entry.isDirectory()) {
      const nested = await collectRecentRolloutFiles(fullPath, cutoffMs, depth + 1);
      result.push(...nested);
    }
  }

  return result;
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
  const commandFunctionCalls = new Map<string, PendingCommandFunctionCall>();
  const commandSessionCalls = new Map<string, PendingCommandFunctionCall>();
  const stdinFunctionCalls = new Map<string, string>();
  const toolFunctionCalls = new Map<string, PendingToolFunctionCall>();
  const countedActivityIds = new Set<string>();
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
      const commandFunctionCall = parseCommandFunctionCall(parsed, seq);
      if (commandFunctionCall) {
        commandFunctionCalls.set(commandFunctionCall.callId, commandFunctionCall);
        const added = upsertBoundedActivity(
          activities,
          commandFunctionCall.activity,
          options.activityLimit ?? null,
        );
        if (!countedActivityIds.has(commandFunctionCall.activity.id)) {
          countedActivityIds.add(commandFunctionCall.activity.id);
          totalActivities += 1;
        }
        if (added) {
          seq += 1;
        }
        continue;
      }

      const stdinFunctionCall = parseStdinFunctionCall(parsed);
      if (stdinFunctionCall) {
        stdinFunctionCalls.set(stdinFunctionCall.callId, stdinFunctionCall.sessionId);
        continue;
      }

      const toolFunctionCall = parseToolFunctionCall(parsed);
      if (toolFunctionCall) {
        toolFunctionCalls.set(toolFunctionCall.callId, toolFunctionCall);
        continue;
      }

      const commandFunctionOutput = parseCommandFunctionOutput(
        parsed,
        commandFunctionCalls,
        commandSessionCalls,
        stdinFunctionCalls,
      );
      if (commandFunctionOutput) {
        const wasCounted = countedActivityIds.has(commandFunctionOutput.id);
        const added = upsertBoundedActivity(
          activities,
          commandFunctionOutput,
          options.activityLimit ?? null,
        );
        if (!wasCounted) {
          countedActivityIds.add(commandFunctionOutput.id);
          totalActivities += 1;
        }
        if (added && !wasCounted) {
          seq += 1;
        }
        continue;
      }

      const toolFunctionOutput = parseToolFunctionOutput(
        parsed,
        toolFunctionCalls,
        seq,
      );
      if (toolFunctionOutput) {
        upsertBoundedActivity(
          activities,
          toolFunctionOutput,
          options.activityLimit ?? null,
        );
        if (!countedActivityIds.has(toolFunctionOutput.id)) {
          countedActivityIds.add(toolFunctionOutput.id);
          totalActivities += 1;
          seq += 1;
        }
        continue;
      }

      const activity = parseActivity(parsed, seq);
      if (activity) {
        upsertBoundedActivity(activities, activity, options.activityLimit ?? null);
        if (!countedActivityIds.has(activity.id)) {
          countedActivityIds.add(activity.id);
          totalActivities += 1;
          seq += 1;
        }
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
  if (await shouldUseFastRolloutScan(rolloutPath)) {
    return readLargeRolloutThreadSummary(rolloutPath);
  }

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
  const source = normalizeThreadSource(meta?.source);
  return {
    id,
    name: null,
    preview,
    createdAt,
    updatedAt,
    cwd,
    source,
    path: rolloutPath,
    status: { type: inProgress ? "running" : "idle" },
    gitInfo: null,
    subAgent: subAgentInfoFromCodexSource(source, {
      agentRole: asOptionalString(meta?.agentRole),
      agentNickname: asOptionalString(meta?.agentNickname),
    }),
  };
}

async function shouldUseFastRolloutScan(rolloutPath: string): Promise<boolean> {
  try {
    return (await stat(rolloutPath)).size > LARGE_ROLLOUT_FAST_SCAN_THRESHOLD_BYTES;
  } catch {
    return false;
  }
}

async function readLargeRolloutThreadSummary(
  rolloutPath: string,
): Promise<ThreadRecord | null> {
  const stats = await stat(rolloutPath);
  const sections = await readRolloutSummarySections(rolloutPath, stats.size);
  let meta: Record<string, any> | null = null;
  let preview = "";
  let latestTimestamp = stats.mtimeMs;
  let inProgress = false;

  for (const parsed of parseRolloutSections(sections)) {
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
  const source = normalizeThreadSource(meta?.source);
  return {
    id,
    name: null,
    preview,
    createdAt,
    updatedAt,
    cwd,
    source,
    path: rolloutPath,
    status: { type: inProgress ? "running" : "idle" },
    gitInfo: null,
    subAgent: subAgentInfoFromCodexSource(source, {
      agentRole: asOptionalString(meta?.agentRole),
      agentNickname: asOptionalString(meta?.agentNickname),
    }),
  };
}

async function scanRolloutRuntimeFast(
  rolloutPath: string,
): Promise<SessionRuntimeSummary | null> {
  const stats = await stat(rolloutPath);
  const sections = await readRolloutSummarySections(rolloutPath, stats.size);
  let runtime: SessionRuntimeSummary | null = null;
  const pendingTurnRuntime = new Map<string, SessionRuntimeSummary>();

  for (const parsed of parseRolloutSections(sections)) {
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
  }

  return runtime;
}

async function readRolloutSummarySections(
  rolloutPath: string,
  size: number,
): Promise<string[]> {
  if (size <= ROLLOUT_HEAD_SCAN_BYTES + ROLLOUT_TAIL_SCAN_BYTES) {
    return [await readFileSlice(rolloutPath, 0, size)];
  }
  return [
    await readFileSlice(rolloutPath, 0, ROLLOUT_HEAD_SCAN_BYTES),
    await readFileSlice(
      rolloutPath,
      Math.max(0, size - ROLLOUT_TAIL_SCAN_BYTES),
      ROLLOUT_TAIL_SCAN_BYTES,
    ),
  ];
}

async function readFileSlice(
  filePath: string,
  start: number,
  length: number,
): Promise<string> {
  const handle = await open(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buffer, 0, length, start);
    return buffer.subarray(0, bytesRead).toString("utf8");
  } finally {
    await handle.close();
  }
}

function parseRolloutSections(sections: string[]): any[] {
  const parsed: any[] = [];
  const seen = new Set<string>();
  for (const section of sections) {
    for (const line of section.split(/\r?\n/)) {
      if (!line.startsWith("{") || seen.has(line)) {
        continue;
      }
      seen.add(line);
      const item = parseJsonLine(line);
      if (item) {
        parsed.push(item);
      }
    }
  }
  return parsed;
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

export function subAgentInfoFromCodexSource(
  source: ThreadRecord["source"],
  overrides: {
    agentRole?: string;
    agentNickname?: string;
  } = {},
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
      ...(overrides.agentRole ? { agentRole: overrides.agentRole } : {}),
      ...(overrides.agentNickname ? { agentNickname: overrides.agentNickname } : {}),
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
      parentSessionId: asOptionalString(typedThreadSpawn.parent_thread_id) ?? null,
      sourceKind: "thread_spawn",
      agentRole:
        overrides.agentRole ??
        asOptionalString(typedThreadSpawn.agent_role) ??
        null,
      agentNickname:
        overrides.agentNickname ??
        asOptionalString(typedThreadSpawn.agent_nickname) ??
        null,
      depth: asOptionalNumber(typedThreadSpawn.depth) ?? null,
    };
  }
  const other = asOptionalString(subAgent.other);
  if (other) {
    return {
      parentSessionId: null,
      sourceKind: other,
      ...(overrides.agentRole ? { agentRole: overrides.agentRole } : {}),
      ...(overrides.agentNickname ? { agentNickname: overrides.agentNickname } : {}),
    };
  }
  return {
    parentSessionId: null,
    sourceKind: "subagent",
    ...(overrides.agentRole ? { agentRole: overrides.agentRole } : {}),
    ...(overrides.agentNickname ? { agentNickname: overrides.agentNickname } : {}),
  };
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

export function parseMessage(parsed: any, seq: number): SessionMessage | null {
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
        content: [{ type: "text", text }],
        attachments,
        createdAt,
        seq,
      };
    }
    if (payloadType === "agent_message" && typeof parsed.payload?.message === "string") {
      const text = parsed.payload.message;
      return {
        id: `${createdAt}-assistant-${parsed.payload.phase || "final_answer"}`,
        role: "assistant",
        text,
        content: [{ type: "text", text }],
        attachments: [],
        createdAt,
        seq,
        phase: parsed.payload.phase || "final_answer",
      };
    }
    if (payloadType === "turn_aborted") {
      const text = `Turn aborted: ${parsed.payload?.reason || "unknown"}`;
      return {
        id: `${createdAt}-system-turn_aborted`,
        role: "system",
        text,
        content: [{ type: "text", text }],
        attachments: [],
        createdAt,
        seq,
      };
    }
    if (payloadType === "error") {
      const message = formatCodexErrorMessage(parsed.payload?.message);
      if (!message) {
        return null;
      }
      const text = `Error: ${message}`;
      return {
        id: `${createdAt}-system-error`,
        role: "system",
        text,
        content: [{ type: "text", text }],
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

export function parseActivity(parsed: any, seq: number): SessionActivity | null {
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
      return buildWebSearchActivityFromRolloutEvent(
        { ...payload, status: "in_progress" },
        createdAt,
        seq,
      );
    case "web_search_end":
      return buildWebSearchActivityFromRolloutEvent(
        { ...payload, status: terminalRolloutStatus(payload.status) },
        createdAt,
        seq,
      );
    case "image_generation_begin":
      return buildImageGenerationActivityFromRolloutEvent(
        { ...payload, status: "in_progress" },
        createdAt,
        seq,
      );
    case "image_generation_end":
      return buildImageGenerationActivityFromRolloutEvent(
        { ...payload, status: terminalRolloutStatus(payload.status) },
        createdAt,
        seq,
      );
    case "context_compacted":
      return {
        id: `context-compaction:${seq}`,
        type: "context_compaction",
        turnId: null,
        createdAt,
        seq,
        status: "completed",
      };
    case "guardian_assessment":
      return buildCommandActivityFromGuardianAssessment(payload, createdAt, seq);
    default:
      return null;
  }
}

function terminalRolloutStatus(
  status: unknown,
): "completed" | "failed" | "declined" {
  if (status === "failed") {
    return "failed";
  }
  if (status === "declined") {
    return "declined";
  }
  return "completed";
}

type PendingCommandFunctionCall = {
  callId: string;
  activity: CommandActivity;
  payload: Record<string, unknown>;
};

type PendingToolFunctionCall = {
  callId: string;
  name: string;
  args: unknown;
  createdAt: number;
};

function parseCommandFunctionCall(
  parsed: any,
  seq: number,
): PendingCommandFunctionCall | null {
  if (parsed?.type !== "response_item" || parsed.payload?.type !== "function_call") {
    return null;
  }

  const payload = parsed.payload as Record<string, unknown>;
  const name = asOptionalString(payload.name);
  if (name !== "exec_command" && name !== "functions.exec_command") {
    return null;
  }

  const callId = asOptionalString(payload.call_id) ?? asOptionalString(payload.callId);
  const args = parseFunctionArguments(payload.arguments);
  const command = asOptionalString(args.cmd) ?? asOptionalString(args.command);
  const cwd =
    asOptionalString(args.workdir) ??
    asOptionalString(args.cwd) ??
    asOptionalString(args.workingDirectory);
  if (!callId || !command || !cwd) {
    return null;
  }

  const createdAt = parseTimestamp(parsed.timestamp);
  const commandPayload: Record<string, unknown> = {
    call_id: callId,
    command,
    cwd,
    status: "in_progress",
    source: "agent",
  };
  const activity = buildCommandActivityFromRolloutEvent(commandPayload, createdAt, seq);
  if (!activity) {
    return null;
  }

  return { callId, activity, payload: commandPayload };
}

function parseCommandFunctionOutput(
  parsed: any,
  pendingCalls: Map<string, PendingCommandFunctionCall>,
  pendingSessions: Map<string, PendingCommandFunctionCall>,
  stdinCalls: Map<string, string>,
): SessionActivity | null {
  if (
    parsed?.type !== "response_item" ||
    parsed.payload?.type !== "function_call_output"
  ) {
    return null;
  }

  const payload = parsed.payload as Record<string, unknown>;
  const callId = asOptionalString(payload.call_id) ?? asOptionalString(payload.callId);
  if (!callId) {
    return null;
  }
  const stdinSessionId = stdinCalls.get(callId);
  const pending = stdinSessionId
    ? pendingSessions.get(stdinSessionId)
    : pendingCalls.get(callId);
  if (!pending) {
    return null;
  }
  if (stdinSessionId) {
    stdinCalls.delete(callId);
  }

  const output = asOptionalString(payload.output) ?? "";
  const exitCode = parseCommandExitCode(output);
  const processId = parseCommandSessionId(output);
  const status = exitCode == null ? "in_progress" : exitCode === 0 ? "completed" : "failed";
  const resolvedProcessId = processId ?? pending.activity.processId;
  if (exitCode != null) {
    pendingCalls.delete(pending.callId);
    if (resolvedProcessId) {
      pendingSessions.delete(resolvedProcessId);
    }
  } else if (resolvedProcessId) {
    pendingSessions.set(resolvedProcessId, pending);
  }

  const activity = buildCommandActivityFromRolloutEvent(
    {
      ...pending.payload,
      status,
      aggregated_output: appendCommandOutput(pending.activity.output, output),
      exit_code: exitCode,
      duration_ms: parseCommandDurationMs(output),
      process_id: resolvedProcessId,
    },
    pending.activity.createdAt,
    pending.activity.seq,
  );
  if (activity) {
    pending.activity = mergeActivity(pending.activity, activity) as CommandActivity;
  }
  return activity;
}

function parseStdinFunctionCall(
  parsed: any,
): { callId: string; sessionId: string } | null {
  if (parsed?.type !== "response_item" || parsed.payload?.type !== "function_call") {
    return null;
  }

  const payload = parsed.payload as Record<string, unknown>;
  const name = asOptionalString(payload.name);
  if (name !== "write_stdin" && name !== "functions.write_stdin") {
    return null;
  }

  const callId = asOptionalString(payload.call_id) ?? asOptionalString(payload.callId);
  const args = parseFunctionArguments(payload.arguments);
  const sessionId = asOptionalIdString(args.session_id) ?? asOptionalIdString(args.sessionId);
  if (!callId || !sessionId) {
    return null;
  }
  return { callId, sessionId };
}

function parseToolFunctionCall(parsed: any): PendingToolFunctionCall | null {
  if (parsed?.type !== "response_item") {
    return null;
  }
  const payload = parsed.payload as Record<string, unknown> | undefined;
  if (!payload) {
    return null;
  }
  const payloadType = asOptionalString(payload.type);
  if (payloadType !== "function_call" && payloadType !== "custom_tool_call") {
    return null;
  }
  const name = asOptionalString(payload.name);
  const callId =
    asOptionalString(payload.call_id) ?? asOptionalString(payload.callId);
  if (!name || !callId) {
    return null;
  }
  if (
    name === "exec_command" ||
    name === "functions.exec_command" ||
    name === "write_stdin" ||
    name === "functions.write_stdin"
  ) {
    return null;
  }
  return {
    callId,
    name,
    args:
      payloadType === "custom_tool_call"
        ? parseFunctionArguments(payload.input)
        : parseFunctionArguments(payload.arguments),
    createdAt: parseTimestamp(parsed.timestamp),
  };
}

function parseToolFunctionOutput(
  parsed: any,
  pendingCalls: Map<string, PendingToolFunctionCall>,
  seq: number,
): ToolActivity | null {
  if (parsed?.type !== "response_item") {
    return null;
  }
  const payload = parsed.payload as Record<string, unknown> | undefined;
  if (!payload) {
    return null;
  }
  const payloadType = asOptionalString(payload.type);
  if (
    payloadType !== "function_call_output" &&
    payloadType !== "custom_tool_call_output"
  ) {
    return null;
  }
  const callId =
    asOptionalString(payload.call_id) ?? asOptionalString(payload.callId);
  if (!callId) {
    return null;
  }
  const pending = pendingCalls.get(callId);
  if (!pending) {
    return null;
  }
  pendingCalls.delete(callId);
  const attachments = extractSessionAttachments(payload.output);
  if (attachments.length === 0) {
    return null;
  }
  return {
    id: callId,
    type: "tool",
    turnId: null,
    createdAt: pending.createdAt,
    seq,
    status: "completed",
    toolName: pending.name,
    title: pending.name,
    args: pending.args,
    output: null,
    result: extractToolOutputText(payload.output),
    attachments,
    isError: false,
    semantic: null,
  };
}

function extractToolOutputText(value: unknown): string | null {
  if (!Array.isArray(value)) {
    return typeof value === "string" && value.length > 0 ? value : null;
  }
  const text = value
    .flatMap((entry): string[] => {
      if (!entry || typeof entry !== "object") {
        return [];
      }
      const record = entry as Record<string, unknown>;
      const type = asOptionalString(record.type)
        ?.replaceAll("_", "")
        .toLowerCase();
      if (type !== "inputtext" && type !== "outputtext" && type !== "text") {
        return [];
      }
      const next = asOptionalString(record.text);
      return next ? [next] : [];
    })
    .join("\n")
    .trim();
  return text || null;
}

function upsertBoundedActivity(
  activities: SessionActivity[],
  activity: SessionActivity,
  limit: number | null,
): boolean {
  const existingIndex = activities.findIndex((item) => item.id === activity.id);
  if (existingIndex >= 0) {
    activities[existingIndex] = mergeActivity(activities[existingIndex], activity);
    return false;
  }
  appendBounded(activities, activity, limit);
  return true;
}

function parseFunctionArguments(raw: unknown): Record<string, unknown> {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    return raw as Record<string, unknown>;
  }
  if (typeof raw !== "string" || !raw.trim()) {
    return {};
  }
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    return {};
  }
}

function parseCommandExitCode(output: string): number | null {
  const match = /Process exited with code (-?\d+)/.exec(output);
  if (!match) {
    return null;
  }
  const exitCode = Number.parseInt(match[1], 10);
  return Number.isFinite(exitCode) ? exitCode : null;
}

function parseCommandDurationMs(output: string): number | null {
  const match = /Wall time: ([0-9.]+) seconds/.exec(output);
  if (!match) {
    return null;
  }
  const seconds = Number.parseFloat(match[1]);
  return Number.isFinite(seconds) ? Math.round(seconds * 1000) : null;
}

function parseCommandSessionId(output: string): string | null {
  const match = /Process running with session ID ([^\s]+)/.exec(output);
  return match?.[1] ?? null;
}

function asOptionalIdString(value: unknown): string | undefined {
  if (typeof value === "string" && value.trim()) {
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }
  return undefined;
}

function appendCommandOutput(existing: string | null | undefined, next: string): string {
  if (!existing) {
    return next;
  }
  if (!next) {
    return existing;
  }
  return `${existing}${existing.endsWith("\n") ? "" : "\n"}${next}`;
}

export function parseRuntime(parsed: any): SessionRuntimeSummary | null {
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
      permissionProfile: asOptionalString(
        typed.active_permission_profile?.id ?? typed.permission_profile?.id,
      ),
      approvalsReviewer: asOptionalString(typed.approvals_reviewer),
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
      runtime.networkAccess === undefined &&
      !runtime.permissionProfile &&
      !runtime.approvalsReviewer
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

  if (parsed.type === "event_msg" && parsed.payload?.type === "token_count") {
    const info = parsed.payload.info;
    if (!info || typeof info !== "object") {
      return null;
    }
    const typed = info as Record<string, any>;
    const last = typed.last_token_usage && typeof typed.last_token_usage === "object"
      ? (typed.last_token_usage as Record<string, any>)
      : null;
    const total = typed.total_token_usage && typeof typed.total_token_usage === "object"
      ? (typed.total_token_usage as Record<string, any>)
      : null;
    const currentTokens =
      asOptionalNumber(last?.total_tokens) ?? asOptionalNumber(total?.total_tokens);
    if (currentTokens == null) {
      return null;
    }
    const updatedAt = parseTimestamp(parsed.timestamp);
    return {
      telemetry: {
        contextWindow: {
          currentTokens,
          tokenLimit: asOptionalNumber(typed.model_context_window) ?? 0,
          messagesLength: 0,
          updatedAt,
        },
        lastUsage: {
          inputTokens: asOptionalNumber(last?.input_tokens),
          outputTokens: asOptionalNumber(last?.output_tokens),
          reasoningTokens: asOptionalNumber(last?.reasoning_output_tokens),
          cacheReadTokens: asOptionalNumber(last?.cached_input_tokens),
          updatedAt,
        },
      },
      updatedAt,
      turnId: undefined,
    };
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

export function mergeRuntime(
  previous: SessionRuntimeSummary | null,
  next: SessionRuntimeSummary,
): SessionRuntimeSummary {
  if (!previous) {
    return next;
  }

  const telemetry = mergeTelemetry(previous.telemetry, next.telemetry);
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
    ...(telemetry ? { telemetry } : {}),
    updatedAt: next.updatedAt ?? previous.updatedAt,
    turnId: next.turnId ?? previous.turnId,
  };
}

function mergeTelemetry(
  previous: SessionRuntimeSummary["telemetry"],
  next: SessionRuntimeSummary["telemetry"],
): SessionRuntimeSummary["telemetry"] {
  if (!previous) {
    return next;
  }
  if (!next) {
    return previous;
  }
  return {
    contextWindow: next.contextWindow ?? previous.contextWindow,
    lastUsage: next.lastUsage ?? previous.lastUsage,
    compaction: next.compaction ?? previous.compaction,
  };
}

export function resolveCommittedTurnId(parsed: any): string | null {
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

export function resolveDiscardedTurnId(parsed: any): string | null {
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

export function parseJsonLine(line: string): any | null {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function formatCodexErrorMessage(raw: unknown): string | null {
  const message = asOptionalString(raw);
  if (!message) {
    return null;
  }

  try {
    const parsed = JSON.parse(message);
    if (parsed && typeof parsed === "object") {
      return asOptionalString((parsed as Record<string, unknown>).error) ?? message;
    }
  } catch {
    // Codex sometimes emits plain strings and sometimes JSON-encoded error envelopes.
  }

  return message;
}

export function parseTimestamp(raw: unknown): number {
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

function asOptionalNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
