import crypto from "node:crypto";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import readline from "node:readline";

import {
  parseJsonLine,
  parseMessage,
  parseActivity,
  parseRuntime,
  mergeRuntime,
  resolveCommittedTurnId,
  resolveDiscardedTurnId,
  parseTimestamp,
} from "./codex-history.js";
import type {
  SessionLogSnapshot,
  SessionMessage,
  SessionActivity,
  SessionRuntimeSummary,
} from "./types.js";

const DEFAULT_MAX_SESSIONS = 256;
const DEFAULT_MAX_MESSAGES = 2000;
const DEFAULT_MAX_ACTIVITIES = 2000;

function hashPrefix(path: string, length: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    const stream = createReadStream(path, { start: 0, end: length - 1, encoding: "utf8" });
    stream.on("data", (chunk: string) => hash.update(chunk, "utf8"));
    stream.on("end", () => resolve(hash.digest("hex")));
    stream.on("error", reject);
  });
}

export interface ReplayIndexEntry {
  sessionId: string;
  rolloutPath: string;
  inode: number;
  device: number;
  size: number;
  mtimeMs: number;
  lastByteOffset: number;
  nextSeq: number;
  messages: SessionMessage[];
  activities: SessionActivity[];
  runtime: SessionRuntimeSummary | null;
  pendingTurnRuntime: Map<string, SessionRuntimeSummary>;
  totalMessages: number;
  totalActivities: number;
  lastAccessedAt: number;
  prefixHash: string;
}

export interface ReplayDeltaResult {
  messages: SessionMessage[];
  activities: SessionActivity[];
  nextSeq: number;
  runtime: SessionRuntimeSummary | null;
}

export interface SessionReplayIndexStats {
  entryCount: number;
  totalMessages: number;
  totalActivities: number;
}

/**
 * Daemon-side per-session replay index for cheap delta event serving.
 * Parses Codex rollout .jsonl files incrementally and keeps a bounded
 * ring buffer in memory so /events?since=<seq> never re-scans the
 * entire transcript.
 */
export class SessionReplayIndex {
  private entries = new Map<string, ReplayIndexEntry>();
  private readonly maxSessions: number;
  private readonly maxMessages: number;
  private readonly maxActivities: number;

  constructor(options?: {
    maxSessions?: number;
    maxMessages?: number;
    maxActivities?: number;
  }) {
    this.maxSessions = options?.maxSessions ?? DEFAULT_MAX_SESSIONS;
    this.maxMessages = options?.maxMessages ?? DEFAULT_MAX_MESSAGES;
    this.maxActivities = options?.maxActivities ?? DEFAULT_MAX_ACTIVITIES;
  }

  /**
   * Load (or refresh) the replay index for a session.
   * Returns the cached entry, rebuilding incrementally if the file
   * has grown or from scratch if the file rotated / changed inode.
   */
  async load(sessionId: string, rolloutPath: string): Promise<ReplayIndexEntry> {
    const existing = this.entries.get(sessionId);

    let stats;
    try {
      stats = await stat(rolloutPath);
    } catch {
      this.entries.delete(sessionId);
      throw new Error(`Rollout file not found: ${rolloutPath}`);
    }

    const prefixHash = stats.size > 0 ? await hashPrefix(rolloutPath, Math.min(stats.size, 4096)) : "";
    if (
      existing &&
      existing.rolloutPath === rolloutPath &&
      existing.inode === stats.ino &&
      existing.device === stats.dev &&
      existing.size <= stats.size &&
      existing.prefixHash === prefixHash
    ) {
      existing.lastAccessedAt = Date.now();

      if (existing.size < stats.size) {
        await this.parseAppendedBytes(existing, rolloutPath, stats.size);
      }

      return existing;
    }

    const entry = await this.buildFromScratch(sessionId, rolloutPath, stats);
    this.evictIfNeeded();
    this.entries.set(sessionId, entry);
    return entry;
  }

  /**
   * Return events with seq > `since` from the cached entry.
   * Throws a STALE_CURSOR error if `since` is older than the oldest
   * retained event in the ring buffer.
   */
  getDelta(entry: ReplayIndexEntry, since: number): ReplayDeltaResult {
    if (since < 0) since = 0;

    const oldestMessageSeq =
      entry.messages.length > 0 ? entry.messages[0].seq : entry.nextSeq;
    const oldestActivitySeq =
      entry.activities.length > 0 ? entry.activities[0].seq : entry.nextSeq;
    const oldestSeq = Math.min(oldestMessageSeq, oldestActivitySeq);

    if (since < oldestSeq && oldestSeq > 0) {
      const error = new Error("Stale cursor") as Error & {
        code: string;
        staleSince: number;
        oldestAvailableSeq: number;
      };
      error.code = "STALE_CURSOR";
      error.staleSince = since;
      error.oldestAvailableSeq = oldestSeq;
      throw error;
    }

    const newMessages = entry.messages.filter((m) => m.seq > since);
    const newActivities = entry.activities.filter((a) => a.seq > since);
    let highestSeq = since;
    for (const m of newMessages) {
      if (m.seq > highestSeq) highestSeq = m.seq;
    }
    for (const a of newActivities) {
      if (a.seq > highestSeq) highestSeq = a.seq;
    }

    return {
      messages: newMessages,
      activities: newActivities,
      nextSeq: highestSeq,
      runtime: entry.runtime,
    };
  }

  /** Build a full SessionLogSnapshot from a cached entry. */
  getSnapshot(entry: ReplayIndexEntry): SessionLogSnapshot {
    return {
      messages: [...entry.messages],
      activities: [...entry.activities],
      runtime: entry.runtime,
      totalMessages: entry.totalMessages,
      totalActivities: entry.totalActivities,
      nextSeq: entry.nextSeq,
    };
  }

  /** Remove a session from the cache (e.g. on session end). */
  invalidate(sessionId: string): void {
    this.entries.delete(sessionId);
  }

  /** Lightweight diagnostics. */
  getStats(): SessionReplayIndexStats {
    let totalMessages = 0;
    let totalActivities = 0;
    for (const entry of this.entries.values()) {
      totalMessages += entry.messages.length;
      totalActivities += entry.activities.length;
    }
    return {
      entryCount: this.entries.size,
      totalMessages,
      totalActivities,
    };
  }

  private async buildFromScratch(
    sessionId: string,
    rolloutPath: string,
    stats: { ino: number; dev: number; size: number; mtimeMs: number },
  ): Promise<ReplayIndexEntry> {
    const prefixHash = stats.size > 0 ? await hashPrefix(rolloutPath, Math.min(stats.size, 4096)) : "";
    const entry: ReplayIndexEntry = {
      sessionId,
      rolloutPath,
      inode: stats.ino,
      device: stats.dev,
      size: stats.size,
      mtimeMs: stats.mtimeMs,
      lastByteOffset: 0,
      nextSeq: 0,
      messages: [],
      activities: [],
      runtime: null,
      pendingTurnRuntime: new Map(),
      totalMessages: 0,
      totalActivities: 0,
      lastAccessedAt: Date.now(),
      prefixHash,
    };

    if (stats.size > 0) {
      await this.parseBytes(entry, rolloutPath, 0, stats.size);
    }

    return entry;
  }

  private async parseAppendedBytes(
    entry: ReplayIndexEntry,
    rolloutPath: string,
    newSize: number,
  ): Promise<void> {
    if (entry.lastByteOffset >= newSize) return;
    await this.parseBytes(entry, rolloutPath, entry.lastByteOffset, newSize);
    entry.size = newSize;
    entry.mtimeMs = Date.now();
  }

  private async parseBytes(
    entry: ReplayIndexEntry,
    rolloutPath: string,
    startOffset: number,
    endOffset: number,
  ): Promise<void> {
    const file = createReadStream(rolloutPath, {
      encoding: "utf8",
      start: startOffset,
    });
    const lines = readline.createInterface({
      input: file,
      crlfDelay: Infinity,
    });

    for await (const line of lines) {
      const parsed = parseJsonLine(line);
      if (!parsed) continue;

      const nextRuntime = parseRuntime(parsed);
      if (nextRuntime) {
        if (nextRuntime.turnId) {
          entry.pendingTurnRuntime.set(
            nextRuntime.turnId,
            mergeRuntime(
              entry.pendingTurnRuntime.get(nextRuntime.turnId) ?? null,
              nextRuntime,
            ),
          );
        } else {
          entry.runtime = mergeRuntime(entry.runtime, nextRuntime);
        }
      }

      const committedTurnId = resolveCommittedTurnId(parsed);
      if (committedTurnId) {
        const committed = entry.pendingTurnRuntime.get(committedTurnId);
        if (committed) {
          entry.runtime = mergeRuntime(entry.runtime, {
            ...committed,
            updatedAt: parseTimestamp(parsed.timestamp),
          });
        }
        entry.pendingTurnRuntime.delete(committedTurnId);
      }

      const discardedTurnId = resolveDiscardedTurnId(parsed);
      if (discardedTurnId) {
        entry.pendingTurnRuntime.delete(discardedTurnId);
      }

      const message = parseMessage(parsed, entry.nextSeq);
      if (message) {
        entry.totalMessages += 1;
        entry.nextSeq += 1;
        entry.messages.push(message);
        if (entry.messages.length > this.maxMessages) {
          entry.messages.shift();
        }
      }

      const activity = parseActivity(parsed, entry.nextSeq);
      if (activity) {
        entry.totalActivities += 1;
        entry.nextSeq += 1;
        entry.activities.push(activity);
        if (entry.activities.length > this.maxActivities) {
          entry.activities.shift();
        }
      }
    }

    entry.lastByteOffset = endOffset;
  }

  private evictIfNeeded(): void {
    if (this.entries.size < this.maxSessions) return;

    let oldestKey = "";
    let oldestAt = Infinity;
    for (const [key, entry] of this.entries) {
      if (entry.lastAccessedAt < oldestAt) {
        oldestAt = entry.lastAccessedAt;
        oldestKey = key;
      }
    }
    if (oldestKey) {
      this.entries.delete(oldestKey);
    }
  }
}
