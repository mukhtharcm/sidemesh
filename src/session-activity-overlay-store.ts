import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import { normalizeStoredSessionActivity } from "./activity.js";
import type { SessionActivity } from "./types.js";

export interface SessionActivityOverlayStoreOptions {
  ttlMs: number;
  limit: number;
}

export interface StoredSessionActivityOverlay {
  sessionId: string;
  activity: SessionActivity;
  savedAt: number;
}

interface StoreFile {
  version: 1;
  overlays: StoredSessionActivityOverlay[];
}

export class SessionActivityOverlayStore {
  private readonly overlaysByKey =
    new Map<string, StoredSessionActivityOverlay>();
  private writeQueue: Promise<void> = Promise.resolve();

  private constructor(
    private readonly filePath: string,
    private readonly options: SessionActivityOverlayStoreOptions,
  ) {}

  static async open(
    filePath: string,
    options: SessionActivityOverlayStoreOptions,
  ): Promise<SessionActivityOverlayStore> {
    const store = new SessionActivityOverlayStore(filePath, options);
    await store.load();
    await store.flush();
    return store;
  }

  entries(): StoredSessionActivityOverlay[] {
    this.prune(Date.now());
    return [...this.overlaysByKey.values()];
  }

  async put(sessionId: string, activity: SessionActivity): Promise<void> {
    const write = this.writeQueue.then(async () => {
      this.overlaysByKey.set(overlayKey(sessionId, activity.id), {
        sessionId,
        activity,
        savedAt: Date.now(),
      });
      this.prune(Date.now());
      await this.flush();
    });
    this.writeQueue = write.catch(() => undefined);
    await write;
  }

  async drain(): Promise<void> {
    await this.writeQueue;
  }

  private async load(): Promise<void> {
    let raw: string;
    try {
      raw = await readFile(this.filePath, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        return;
      }
      throw error;
    }

    const parsed = JSON.parse(raw) as Partial<StoreFile>;
    if (parsed.version !== 1 || !Array.isArray(parsed.overlays)) {
      throw new Error("Invalid session activity overlay store format");
    }
    for (const rawEntry of parsed.overlays) {
      const entry = normalizeStoredOverlay(rawEntry);
      if (entry) {
        this.overlaysByKey.set(overlayKey(entry.sessionId, entry.activity.id), entry);
      }
    }
    this.prune(Date.now());
  }

  private prune(now: number): void {
    for (const [key, entry] of this.overlaysByKey) {
      if (now - entry.savedAt > this.options.ttlMs) {
        this.overlaysByKey.delete(key);
      }
    }
    if (this.overlaysByKey.size <= this.options.limit) {
      return;
    }
    const stale = [...this.overlaysByKey.entries()]
      .sort((left, right) => left[1].savedAt - right[1].savedAt)
      .slice(0, this.overlaysByKey.size - this.options.limit);
    for (const [key] of stale) {
      this.overlaysByKey.delete(key);
    }
  }

  private async flush(): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
    const tmpPath = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    const file: StoreFile = {
      version: 1,
      overlays: [...this.overlaysByKey.values()].sort(
        (left, right) => left.savedAt - right.savedAt,
      ),
    };
    await writeFile(tmpPath, JSON.stringify(file), {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(tmpPath, this.filePath);
  }
}

function normalizeStoredOverlay(
  value: unknown,
): StoredSessionActivityOverlay | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const typed = value as Record<string, unknown>;
  const sessionId =
    typeof typed.sessionId === "string" && typed.sessionId.trim()
      ? typed.sessionId.trim()
      : null;
  const savedAt = typeof typed.savedAt === "number" ? typed.savedAt : null;
  const activity = normalizeActivity(typed.activity);
  if (!sessionId || savedAt == null || !Number.isFinite(savedAt) || !activity) {
    return null;
  }
  return { sessionId, savedAt, activity };
}

function normalizeActivity(value: unknown): SessionActivity | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const typed = value as Record<string, unknown>;
  if (
    typeof typed.id !== "string" ||
    typeof typed.type !== "string" ||
    typeof typed.status !== "string" ||
    typeof typed.createdAt !== "number" ||
    typeof typed.seq !== "number"
  ) {
    return null;
  }
  return normalizeStoredSessionActivity(typed as unknown as SessionActivity);
}

function overlayKey(sessionId: string, activityId: string): string {
  return `${sessionId}\u001f${activityId}`;
}
