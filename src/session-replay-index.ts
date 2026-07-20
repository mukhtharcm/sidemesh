import crypto from "node:crypto";
import { createReadStream } from "node:fs";
import { open, stat } from "node:fs/promises";
import readline from "node:readline";

import { mergeActivity } from "./activity.js";
import { CodexHistoryParser } from "./codex-history.js";
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
  parser: CodexHistoryParser;
  totalMessages: number;
  totalActivities: number;
  highestEvictedSeq: number;
  lastAccessedAt: number;
  prefixLength: number;
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
  private readonly pendingLoads = new Map<string, Promise<ReplayIndexEntry>>();
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
    const previous = this.pendingLoads.get(sessionId);
    const pending = (previous
      ? previous.catch(() => undefined)
      : Promise.resolve()
    ).then(() => this.loadSerialized(sessionId, rolloutPath));
    this.pendingLoads.set(sessionId, pending);
    try {
      return await pending;
    } finally {
      if (this.pendingLoads.get(sessionId) === pending) {
        this.pendingLoads.delete(sessionId);
      }
    }
  }

  private async loadSerialized(
    sessionId: string,
    rolloutPath: string,
  ): Promise<ReplayIndexEntry> {
    const existing = this.entries.get(sessionId);

    let stats;
    try {
      stats = await stat(rolloutPath);
    } catch {
      this.entries.delete(sessionId);
      throw new Error(`Rollout file not found: ${rolloutPath}`);
    }

    const existingPrefixHash = existing &&
        existing.prefixLength > 0 &&
        stats.size >= existing.prefixLength
      ? await hashPrefix(rolloutPath, existing.prefixLength)
      : "";
    if (
      existing &&
      existing.rolloutPath === rolloutPath &&
      existing.inode === stats.ino &&
      existing.device === stats.dev &&
      existing.size <= stats.size &&
      stats.size >= existing.prefixLength &&
      existing.prefixHash === existingPrefixHash
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
    if (since < -1) since = -1;

    if (since < entry.highestEvictedSeq) {
      const error = new Error("Stale cursor") as Error & {
        code: string;
        staleSince: number;
        oldestAvailableSeq: number;
      };
      error.code = "STALE_CURSOR";
      error.staleSince = since;
      error.oldestAvailableSeq = entry.highestEvictedSeq + 1;
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
    const prefixLength = Math.min(stats.size, 4096);
    const prefixHash = prefixLength > 0
      ? await hashPrefix(rolloutPath, prefixLength)
      : "";
    const entry: ReplayIndexEntry = {
      sessionId,
      rolloutPath,
      inode: stats.ino,
      device: stats.dev,
      size: 0,
      mtimeMs: stats.mtimeMs,
      lastByteOffset: 0,
      nextSeq: 0,
      messages: [],
      activities: [],
      runtime: null,
      parser: new CodexHistoryParser(),
      totalMessages: 0,
      totalActivities: 0,
      highestEvictedSeq: -1,
      lastAccessedAt: Date.now(),
      prefixLength,
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
    entry.mtimeMs = Date.now();
  }

  private async parseBytes(
    entry: ReplayIndexEntry,
    rolloutPath: string,
    startOffset: number,
    endOffset: number,
  ): Promise<void> {
    const completeEndOffset = await findLastCompleteLineOffset(
      rolloutPath,
      startOffset,
      endOffset,
    );
    if (completeEndOffset <= startOffset) {
      return;
    }
    const file = createReadStream(rolloutPath, {
      encoding: "utf8",
      start: startOffset,
      end: completeEndOffset - 1,
    });
    const lines = readline.createInterface({
      input: file,
      crlfDelay: Infinity,
    });

    for await (const line of lines) {
      const result = entry.parser.parseLine(line);
      if (!result) continue;
      entry.runtime = entry.parser.runtime;
      entry.nextSeq = entry.parser.nextSeq;

      if (result.message) {
        entry.totalMessages += 1;
        entry.messages.push(result.message);
        if (entry.messages.length > this.maxMessages) {
          const evicted = entry.messages.shift();
          if (evicted) {
            entry.highestEvictedSeq = Math.max(
              entry.highestEvictedSeq,
              evicted.seq,
            );
          }
        }
      }

      if (result.activity) {
        const existingIndex = entry.activities.findIndex(
          (activity) => activity.id === result.activity!.id,
        );
        if (existingIndex >= 0) {
          entry.activities[existingIndex] = mergeActivity(
            entry.activities[existingIndex],
            result.activity,
          );
        } else if (result.isNewActivity) {
          entry.totalActivities += 1;
          entry.activities.push(result.activity);
          if (entry.activities.length > this.maxActivities) {
            const evicted = entry.activities.shift();
            if (evicted) {
              entry.highestEvictedSeq = Math.max(
                entry.highestEvictedSeq,
                evicted.seq,
              );
            }
          }
        }
      }
    }

    entry.lastByteOffset = completeEndOffset;
    entry.size = completeEndOffset;
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

async function findLastCompleteLineOffset(
  rolloutPath: string,
  startOffset: number,
  endOffset: number,
): Promise<number> {
  const handle = await open(rolloutPath, "r");
  try {
    const chunkSize = 64 * 1024;
    let cursor = endOffset;
    let lastNewlineEnd = startOffset;
    let foundNewline = false;
    while (cursor > startOffset) {
      const readStart = Math.max(startOffset, cursor - chunkSize);
      const buffer = Buffer.allocUnsafe(cursor - readStart);
      const { bytesRead } = await handle.read(
        buffer,
        0,
        buffer.length,
        readStart,
      );
      for (let index = bytesRead - 1; index >= 0; index -= 1) {
        if (buffer[index] === 0x0a) {
          lastNewlineEnd = readStart + index + 1;
          foundNewline = true;
          break;
        }
      }
      if (foundNewline) break;
      cursor = readStart;
    }
    if (lastNewlineEnd === endOffset) {
      return endOffset;
    }

    // JSONL writers do not universally append a final newline. Treat a
    // syntactically complete terminal JSON value as a finished record, while
    // retaining an actually partial tail until a later append completes it.
    const tail = Buffer.allocUnsafe(endOffset - lastNewlineEnd);
    let bytesRead = 0;
    while (bytesRead < tail.length) {
      const result = await handle.read(
        tail,
        bytesRead,
        tail.length - bytesRead,
        lastNewlineEnd + bytesRead,
      );
      if (result.bytesRead === 0) break;
      bytesRead += result.bytesRead;
    }
    const terminalLine = tail.subarray(0, bytesRead).toString("utf8").trim();
    if (!terminalLine) {
      return endOffset;
    }
    try {
      JSON.parse(terminalLine);
      return endOffset;
    } catch {
      return lastNewlineEnd;
    }
  } finally {
    await handle.close();
  }
}
