import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import type { SessionActivity, SessionMessage } from "./types.js";

export interface StoredSessionTimelineOverlay {
  sessionId: string;
  updatedAt: number;
  messages: SessionMessage[];
  activities: SessionActivity[];
}

interface StoreFile {
  version: 1;
  sessions: StoredSessionTimelineOverlay[];
}

interface SessionTimelineOverlayStoreOptions {
  maxSessions: number;
  maxMessagesPerSession: number;
  maxActivitiesPerSession: number;
}

export class SessionTimelineOverlayStore {
  private readonly overlaysBySession = new Map<string, StoredSessionTimelineOverlay>();
  private writeQueue: Promise<void> = Promise.resolve();

  private constructor(
    private readonly filePath: string,
    private readonly options: SessionTimelineOverlayStoreOptions,
  ) {}

  static async open(
    filePath: string,
    options: SessionTimelineOverlayStoreOptions,
  ): Promise<SessionTimelineOverlayStore> {
    const store = new SessionTimelineOverlayStore(filePath, options);
    await store.load();
    await store.flush();
    return store;
  }

  entries(): StoredSessionTimelineOverlay[] {
    this.prune();
    return [...this.overlaysBySession.values()].map(cloneOverlay);
  }

  getMessages(sessionId: string): SessionMessage[] {
    const overlay = this.overlaysBySession.get(sessionId);
    return overlay ? overlay.messages.map(cloneJson) : [];
  }

  getActivities(sessionId: string): SessionActivity[] {
    const overlay = this.overlaysBySession.get(sessionId);
    return overlay ? overlay.activities.map(cloneJson) : [];
  }

  async upsertMessage(sessionId: string, message: SessionMessage): Promise<void> {
    await this.mutate(sessionId, (overlay) => {
      overlay.messages = upsertById(overlay.messages, message)
        .sort(sortBySeq)
        .slice(-this.options.maxMessagesPerSession);
    });
  }

  async upsertActivity(
    sessionId: string,
    activity: SessionActivity,
  ): Promise<void> {
    await this.mutate(sessionId, (overlay) => {
      overlay.activities = upsertById(overlay.activities, activity)
        .sort(sortBySeq)
        .slice(-this.options.maxActivitiesPerSession);
    });
  }

  private async mutate(
    sessionId: string,
    apply: (overlay: StoredSessionTimelineOverlay) => void,
  ): Promise<void> {
    const write = this.writeQueue.then(async () => {
      const overlay =
        this.overlaysBySession.get(sessionId) ??
        {
          sessionId,
          updatedAt: Date.now(),
          messages: [],
          activities: [],
        };
      apply(overlay);
      overlay.updatedAt = Date.now();
      this.overlaysBySession.set(sessionId, overlay);
      this.prune();
      await this.flush();
    });
    this.writeQueue = write.catch(() => undefined);
    await write;
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
    if (parsed.version !== 1 || !Array.isArray(parsed.sessions)) {
      throw new Error("Invalid session timeline overlay store format");
    }

    for (const rawOverlay of parsed.sessions) {
      const overlay = normalizeOverlay(rawOverlay);
      if (overlay) {
        this.overlaysBySession.set(overlay.sessionId, overlay);
      }
    }
    this.prune();
  }

  private prune(): void {
    if (this.overlaysBySession.size <= this.options.maxSessions) {
      return;
    }
    const stale = [...this.overlaysBySession.entries()]
      .sort((left, right) => left[1].updatedAt - right[1].updatedAt)
      .slice(0, this.overlaysBySession.size - this.options.maxSessions);
    for (const [sessionId] of stale) {
      this.overlaysBySession.delete(sessionId);
    }
  }

  private async flush(): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
    const tmpPath = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    const file: StoreFile = {
      version: 1,
      sessions: [...this.overlaysBySession.values()]
        .map(cloneOverlay)
        .sort((left, right) => left.updatedAt - right.updatedAt),
    };
    await writeFile(tmpPath, JSON.stringify(file), {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(tmpPath, this.filePath);
  }
}

function normalizeOverlay(value: unknown): StoredSessionTimelineOverlay | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const raw = value as Partial<StoredSessionTimelineOverlay>;
  if (typeof raw.sessionId !== "string" || typeof raw.updatedAt !== "number") {
    return null;
  }
  return {
    sessionId: raw.sessionId,
    updatedAt: raw.updatedAt,
    messages: Array.isArray(raw.messages)
      ? raw.messages.filter(isSessionMessage).map(cloneJson).sort(sortBySeq)
      : [],
    activities: Array.isArray(raw.activities)
      ? raw.activities.filter(isSessionActivity).map(cloneJson).sort(sortBySeq)
      : [],
  };
}

function isSessionMessage(value: unknown): value is SessionMessage {
  if (!value || typeof value !== "object") {
    return false;
  }
  const raw = value as Partial<SessionMessage>;
  return (
    typeof raw.id === "string" &&
    (raw.role === "user" || raw.role === "assistant" || raw.role === "system") &&
    typeof raw.text === "string" &&
    Array.isArray(raw.attachments) &&
    typeof raw.createdAt === "number" &&
    typeof raw.seq === "number"
  );
}

function isSessionActivity(value: unknown): value is SessionActivity {
  if (!value || typeof value !== "object") {
    return false;
  }
  const raw = value as Partial<SessionActivity>;
  return (
    typeof raw.id === "string" &&
    typeof raw.type === "string" &&
    typeof raw.createdAt === "number" &&
    typeof raw.seq === "number" &&
    (raw.status === "in_progress" ||
      raw.status === "completed" ||
      raw.status === "failed" ||
      raw.status === "declined")
  );
}

function upsertById<T extends { id: string }>(items: T[], item: T): T[] {
  return [...items.filter((candidate) => candidate.id !== item.id), cloneJson(item)];
}

function sortBySeq(left: { seq: number }, right: { seq: number }): number {
  return left.seq - right.seq;
}

function cloneOverlay(
  overlay: StoredSessionTimelineOverlay,
): StoredSessionTimelineOverlay {
  return {
    sessionId: overlay.sessionId,
    updatedAt: overlay.updatedAt,
    messages: overlay.messages.map(cloneJson),
    activities: overlay.activities.map(cloneJson),
  };
}

function cloneJson<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}
