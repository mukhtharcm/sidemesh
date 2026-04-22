import { createReadStream } from "node:fs";
import { access } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";

import type { RolloutLog, SessionMessage } from "./types.js";

export async function loadRolloutLog(
  sessionId: string,
  rolloutPath: string | null,
  codexHomePath: string | null,
): Promise<RolloutLog> {
  const resolvedPath = rolloutPath || (await findRolloutPath(sessionId, codexHomePath));
  if (!resolvedPath) {
    return { messages: [] };
  }

  const messages: SessionMessage[] = [];
  const file = createReadStream(resolvedPath, { encoding: "utf8" });
  const lines = readline.createInterface({ input: file, crlfDelay: Infinity });

  for await (const line of lines) {
    const entry = parseLine(line);
    if (!entry) {
      continue;
    }
    messages.push(entry);
  }

  return { messages };
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
  let parsed: any;
  try {
    parsed = JSON.parse(line);
  } catch {
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
