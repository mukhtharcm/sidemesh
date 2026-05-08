import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export interface SessionInputDedupeReceipt {
  mode: "steer" | "turn";
  turnId: string | null;
  messageId: string;
}

export interface StoredSessionInputDedupeEntry {
  key: string;
  signatureHash: string;
  createdAt: number;
  updatedAt: number;
  receipt: SessionInputDedupeReceipt;
}

interface StoreFile {
  version: 1;
  entries: StoredSessionInputDedupeEntry[];
}

interface SessionInputDedupeStoreOptions {
  ttlMs: number;
  limit: number;
}

export class SessionInputDedupeStore {
  private readonly entriesByKey = new Map<string, StoredSessionInputDedupeEntry>();
  private writeQueue: Promise<void> = Promise.resolve();

  private constructor(
    private readonly filePath: string,
    private readonly options: SessionInputDedupeStoreOptions,
  ) {}

  static async open(
    filePath: string,
    options: SessionInputDedupeStoreOptions,
  ): Promise<SessionInputDedupeStore> {
    const store = new SessionInputDedupeStore(filePath, options);
    await store.load();
    await store.flush();
    return store;
  }

  entries(): StoredSessionInputDedupeEntry[] {
    this.prune(Date.now());
    return [...this.entriesByKey.values()];
  }

  get(key: string): StoredSessionInputDedupeEntry | null {
    this.prune(Date.now());
    return this.entriesByKey.get(key) ?? null;
  }

  async put(entry: StoredSessionInputDedupeEntry): Promise<void> {
    const write = this.writeQueue.then(async () => {
      this.entriesByKey.set(entry.key, entry);
      this.prune(Date.now());
      await this.flush();
    });
    this.writeQueue = write.catch(() => undefined);
    await write;
  }

  async deleteMany(keys: Iterable<string>): Promise<void> {
    const uniqueKeys = [...new Set(keys)];
    if (uniqueKeys.length === 0) {
      return;
    }
    const write = this.writeQueue.then(async () => {
      for (const key of uniqueKeys) {
        this.entriesByKey.delete(key);
      }
      this.prune(Date.now());
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
    if (parsed.version !== 1 || !Array.isArray(parsed.entries)) {
      throw new Error("Invalid session input dedupe ledger format");
    }

    for (const rawEntry of parsed.entries) {
      const entry = normalizeEntry(rawEntry);
      if (!entry) {
        throw new Error("Invalid session input dedupe ledger entry");
      }
      this.entriesByKey.set(entry.key, entry);
    }
    this.prune(Date.now());
  }

  private prune(now: number): void {
    for (const [key, entry] of this.entriesByKey) {
      if (now - entry.updatedAt > this.options.ttlMs) {
        this.entriesByKey.delete(key);
      }
    }

    if (this.entriesByKey.size <= this.options.limit) {
      return;
    }

    const stale = [...this.entriesByKey.entries()]
      .sort((left, right) => left[1].updatedAt - right[1].updatedAt)
      .slice(0, this.entriesByKey.size - this.options.limit);
    for (const [key] of stale) {
      this.entriesByKey.delete(key);
    }
  }

  private async flush(): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
    const tmpPath = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    const file: StoreFile = {
      version: 1,
      entries: [...this.entriesByKey.values()].sort(
        (left, right) => left.updatedAt - right.updatedAt,
      ),
    };
    await writeFile(tmpPath, JSON.stringify(file), {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(tmpPath, this.filePath);
  }
}

function normalizeEntry(value: unknown): StoredSessionInputDedupeEntry | null {
  if (!value || typeof value !== "object") {
    return null;
  }

  const entry = value as Partial<StoredSessionInputDedupeEntry>;
  if (
    typeof entry.key !== "string" ||
    typeof entry.signatureHash !== "string" ||
    typeof entry.createdAt !== "number" ||
    typeof entry.updatedAt !== "number" ||
    !entry.receipt ||
    typeof entry.receipt !== "object"
  ) {
    return null;
  }

  const receipt = entry.receipt as Partial<SessionInputDedupeReceipt>;
  if (
    (receipt.mode !== "steer" && receipt.mode !== "turn") ||
    (receipt.turnId !== null && typeof receipt.turnId !== "string") ||
    typeof receipt.messageId !== "string"
  ) {
    return null;
  }

  return {
    key: entry.key,
    signatureHash: entry.signatureHash,
    createdAt: entry.createdAt,
    updatedAt: entry.updatedAt,
    receipt: {
      mode: receipt.mode,
      turnId: receipt.turnId,
      messageId: receipt.messageId,
    },
  };
}
