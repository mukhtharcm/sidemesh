import { createReadStream } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";

import type { RolloutLog, SessionMessage, SessionRuntimeSummary } from "./types.js";

export async function loadRolloutLog(
  sessionId: string,
  rolloutPath: string | null,
  codexHomePath: string | null,
): Promise<RolloutLog> {
  const resolvedPath = await resolveRolloutPath(sessionId, rolloutPath, codexHomePath);
  if (!resolvedPath) {
    return { messages: [], runtime: null };
  }

  return scanRolloutFile(resolvedPath, true);
}

export async function loadSessionRuntime(
  sessionId: string,
  rolloutPath: string | null,
  codexHomePath: string | null,
): Promise<SessionRuntimeSummary | null> {
  const resolvedPath = await resolveRolloutPath(sessionId, rolloutPath, codexHomePath);
  if (!resolvedPath) {
    return null;
  }

  const parsed = await scanRolloutFile(resolvedPath, false);
  return parsed.runtime;
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
  includeMessages: boolean,
): Promise<RolloutLog> {
  const messages: SessionMessage[] = [];
  let runtime: SessionRuntimeSummary | null = null;
  const file = createReadStream(rolloutPath, { encoding: "utf8" });
  const lines = readline.createInterface({ input: file, crlfDelay: Infinity });

  for await (const line of lines) {
    const nextRuntime = parseRuntime(line);
    if (nextRuntime) {
      runtime = nextRuntime;
    }

    if (!includeMessages) {
      continue;
    }

    const entry = parseLine(line);
    if (entry) {
      messages.push(entry);
    }
  }

  return { messages, runtime };
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

function parseLine(line: string): SessionMessage | null {
  const parsed = parseJsonLine(line);
  if (!parsed) {
    return null;
  }

  const createdAt = parseTimestamp(parsed.timestamp);
  if (parsed.type === "event_msg") {
    const payloadType = parsed.payload?.type;
    if (payloadType === "user_message" && typeof parsed.payload?.message === "string") {
      return {
        id: `${createdAt}-user`,
        role: "user",
        text: parsed.payload.message,
        createdAt,
      };
    }
    if (payloadType === "agent_message" && typeof parsed.payload?.message === "string") {
      return {
        id: `${createdAt}-assistant-${parsed.payload.phase || "final_answer"}`,
        role: "assistant",
        text: parsed.payload.message,
        createdAt,
        phase: parsed.payload.phase || "final_answer",
      };
    }
    if (payloadType === "turn_aborted") {
      return {
        id: `${createdAt}-system-turn_aborted`,
        role: "system",
        text: `Turn aborted: ${parsed.payload?.reason || "unknown"}`,
        createdAt,
      };
    }
  }

  return null;
}

function parseRuntime(line: string): SessionRuntimeSummary | null {
  const parsed = parseJsonLine(line);
  if (!parsed || parsed.type !== "turn_context") {
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
    reasoningEffort:
      asOptionalString(typed.effort) || asOptionalString(collaborationSettings?.reasoning_effort),
    approvalPolicy: asOptionalString(typed.approval_policy),
    sandboxMode: asOptionalString(typed.sandbox_policy?.type),
    networkAccess: asOptionalBoolean(typed.sandbox_policy?.network_access),
    summaryMode: asOptionalString(typed.summary),
    personality: asOptionalString(typed.personality),
    updatedAt: parseTimestamp(parsed.timestamp),
  };

  if (
    !runtime.model &&
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
