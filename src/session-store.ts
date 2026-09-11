import { chmod, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { z } from "zod";

import type { AgentSessionInputItem, AgentSessionOverrides } from "./agent-provider.js";
import type { LatestPlanUpdate, SessionActivity, SessionMessage } from "./types.js";

const receiptSchema = z.object({
  mode: z.enum(["steer", "turn", "queued"]),
  turnId: z.string().nullable(),
  messageId: z.string(),
});
const legacyInputSchema = z.object({
  version: z.literal(1),
  entries: z.array(z.object({
    key: z.string(), signatureHash: z.string(),
    createdAt: z.number(), updatedAt: z.number(), receipt: receiptSchema,
  })),
});
const legacyPlansSchema = z.object({
  sessions: z.array(z.object({
    sessionId: z.string(), updatedAt: z.number(),
    latestPlanUpdate: z.object({
      type: z.literal("plan_updated"), sessionId: z.string(),
      seq: z.number().optional(), turnId: z.string().optional(),
      explanation: z.string().optional(),
      plan: z.array(z.object({
        step: z.string(), status: z.enum(["pending", "in_progress", "completed"]),
      })),
    }),
  })),
});

export type SessionInputReceipt = z.infer<typeof receiptSchema>;
export interface SessionInputRecord {
  key: string;
  sessionId: string;
  signatureHash: string;
  state: "prepared" | "queued" | "dispatching" | "uncertain" | "accepted" | "confirmed" | "cancelled";
  payload: { input: AgentSessionInputItem[]; overrides: AgentSessionOverrides } | null;
  receipt: SessionInputReceipt | null;
}

export interface StoredProviderSession {
  id: string;
  nativeId: string | null;
  cwd: string;
  name: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
  archived: boolean;
  metadata: unknown;
}

export type StoredSessionItem = {
  nativeId: string | null;
  /** Client identity bound to this submitted native input, never inferred from display IDs. */
  clientInputId?: string;
  /** Timestamp received in a native input event (Pi does not echo client IDs). */
  nativeInputTimestamp?: number;
  /** Native branch entry before this recovery item, when the provider has trees. */
  anchorId?: string;
  authority: "primary" | "recovery" | "cache";
} & ({ kind: "message"; value: SessionMessage } | { kind: "activity"; value: SessionActivity });

/** Durable host data. Native history and the disposable search index stay separate. */
export class SessionStore {
  private constructor(private readonly db: DatabaseSync) {}

  static async open(stateDir: string): Promise<SessionStore> {
    await mkdir(stateDir, { recursive: true, mode: 0o700 });
    const file = join(stateDir, "sessions-v1.db");
    const db = new DatabaseSync(file);
    try {
      // Set permissions before SQLite creates the WAL and shared-memory files.
      await chmod(file, 0o600);
      db.exec(`
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = FULL;
        PRAGMA busy_timeout = 5000;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS migrations (name TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS inputs (
          key TEXT PRIMARY KEY, session_id TEXT NOT NULL, signature_hash TEXT NOT NULL,
          state TEXT NOT NULL CHECK(state IN ('prepared', 'dispatching', 'uncertain', 'accepted')),
          payload TEXT, receipt TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS inputs_session ON inputs(session_id);
        CREATE TABLE IF NOT EXISTS plans (
          session_id TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS provider_sessions (
          provider_id TEXT NOT NULL, id TEXT NOT NULL, native_id TEXT, cwd TEXT NOT NULL,
          name TEXT, preview TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          archived INTEGER NOT NULL, metadata TEXT NOT NULL, PRIMARY KEY(provider_id, id)
        );
        CREATE TABLE IF NOT EXISTS session_items (
          provider_id TEXT NOT NULL, session_id TEXT NOT NULL, id TEXT NOT NULL,
          kind TEXT NOT NULL CHECK(kind IN ('message', 'activity')), native_id TEXT,
          authority TEXT NOT NULL CHECK(authority IN ('primary', 'recovery', 'cache')),
          position INTEGER NOT NULL, value TEXT NOT NULL,
          PRIMARY KEY(provider_id, session_id, id),
          FOREIGN KEY(provider_id, session_id) REFERENCES provider_sessions(provider_id, id)
        );
        CREATE INDEX IF NOT EXISTS session_items_order ON session_items(provider_id, session_id, position);
      `);
      const store = new SessionStore(db);
      if (!store.hasMigration("history-anchors-v1")) {
        store.transaction(() => {
          db.exec("ALTER TABLE session_items ADD COLUMN anchor_id TEXT; INSERT INTO migrations VALUES ('history-anchors-v1')");
        });
      }
      if (!store.hasMigration("durable-queue-v1")) {
        store.transaction(() => {
          db.exec(`
            ALTER TABLE inputs RENAME TO inputs_legacy;
            CREATE TABLE inputs (
              key TEXT PRIMARY KEY, session_id TEXT NOT NULL, signature_hash TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('prepared', 'queued', 'dispatching', 'uncertain', 'accepted', 'confirmed', 'cancelled')),
              payload TEXT, receipt TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
            );
            INSERT INTO inputs SELECT * FROM inputs_legacy;
            DROP TABLE inputs_legacy;
            CREATE INDEX inputs_session ON inputs(session_id);
            INSERT INTO migrations VALUES ('durable-queue-v1');
          `);
        });
      }
      if (!store.hasMigration("input-bindings-v1")) {
        store.transaction(() => {
          db.exec(`ALTER TABLE session_items ADD COLUMN client_input_id TEXT;
            ALTER TABLE session_items ADD COLUMN native_input_timestamp INTEGER;
            INSERT INTO migrations VALUES ('input-bindings-v1')`);
        });
      }
      await store.importLegacy(stateDir);
      // The provider can have accepted a request before the daemon stopped.
      // Never dispatch these rows again without an explicit recovery decision.
      db.exec("UPDATE inputs SET state = 'uncertain' WHERE state = 'dispatching' OR (state = 'accepted' AND payload IS NOT NULL)");
      store.prune();
      return store;
    } catch (error) {
      db.close();
      throw error;
    }
  }

  close(): void { this.db.close(); }

  getProviderSession(providerId: string, id: string): StoredProviderSession | null {
    const row = this.db.prepare("SELECT * FROM provider_sessions WHERE provider_id = ? AND id = ?")
      .get(providerId, id) as ProviderSessionRow | undefined;
    return row ? providerSessionFromRow(row) : null;
  }

  listProviderSessions(providerId: string): StoredProviderSession[] {
    return (this.db.prepare("SELECT * FROM provider_sessions WHERE provider_id = ? ORDER BY updated_at DESC")
      .all(providerId) as unknown as ProviderSessionRow[]).map(providerSessionFromRow);
  }

  saveProviderSession(providerId: string, session: StoredProviderSession): void {
    this.db.prepare(`INSERT INTO provider_sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(provider_id, id) DO UPDATE SET native_id = excluded.native_id, cwd = excluded.cwd,
      name = excluded.name, preview = excluded.preview, updated_at = excluded.updated_at,
      archived = excluded.archived, metadata = excluded.metadata`)
      .run(providerId, session.id, session.nativeId, session.cwd, session.name, session.preview,
        session.createdAt, session.updatedAt, Number(session.archived), JSON.stringify(session.metadata));
  }

  getSessionItem(providerId: string, sessionId: string, id: string): StoredSessionItem | null {
    const row = this.db.prepare("SELECT * FROM session_items WHERE provider_id = ? AND session_id = ? AND id = ?")
      .get(providerId, sessionId, id) as SessionItemRow | undefined;
    return row ? sessionItemFromRow(row) : null;
  }

  readSessionItems(providerId: string, sessionId: string): StoredSessionItem[] {
    return (this.db.prepare("SELECT * FROM session_items WHERE provider_id = ? AND session_id = ? ORDER BY position, rowid")
      .all(providerId, sessionId) as unknown as SessionItemRow[]).map(sessionItemFromRow);
  }

  nextSessionSequence(providerId: string, sessionId: string): number {
    return (this.db.prepare("SELECT coalesce(max(position) + 1, 0) AS next FROM session_items WHERE provider_id = ? AND session_id = ?")
      .get(providerId, sessionId) as { next: number }).next;
  }

  putSessionItem(providerId: string, sessionId: string, item: StoredSessionItem): void {
    this.db.prepare(`INSERT INTO session_items VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(provider_id, session_id, id) DO UPDATE SET kind = excluded.kind, native_id = excluded.native_id,
      authority = excluded.authority, position = excluded.position, value = excluded.value, anchor_id = excluded.anchor_id,
      client_input_id = excluded.client_input_id, native_input_timestamp = excluded.native_input_timestamp`)
      .run(providerId, sessionId, item.value.id, item.kind, item.nativeId, item.authority,
        item.value.seq, JSON.stringify(item.value), item.anchorId ?? null, item.clientInputId ?? null, item.nativeInputTimestamp ?? null);
  }

  replaceProviderHistory(providerId: string, session: StoredProviderSession, items: StoredSessionItem[]): void {
    this.transaction(() => {
      this.saveProviderSession(providerId, session);
      this.db.prepare("DELETE FROM session_items WHERE provider_id = ? AND session_id = ?").run(providerId, session.id);
      for (const item of items) this.putSessionItem(providerId, session.id, item);
    });
  }

  hasMigration(name: string): boolean {
    return Boolean(this.db.prepare("SELECT name FROM migrations WHERE name = ?").get(name));
  }

  importProviderSessions(name: string, providerId: string,
    sessions: Array<{ session: StoredProviderSession; items: StoredSessionItem[] }>): void {
    if (this.hasMigration(name)) return;
    this.transaction(() => {
      for (const { session, items } of sessions) {
        if (this.getProviderSession(providerId, session.id)) throw new Error(`Session import conflict: ${session.id}`);
        this.saveProviderSession(providerId, session);
        for (const item of items) this.putSessionItem(providerId, session.id, item);
      }
      this.db.prepare("INSERT INTO migrations VALUES (?)").run(name);
    });
  }

  private transaction(operation: () => void): void {
    this.db.exec("BEGIN IMMEDIATE");
    try { operation(); this.db.exec("COMMIT"); }
    catch (error) { this.db.exec("ROLLBACK"); throw error; }
  }

  getInput(key: string): SessionInputRecord | null {
    const row = this.db.prepare(
      "SELECT key, session_id, signature_hash, state, payload, receipt FROM inputs WHERE key = ?",
    ).get(key) as {
      key: string; session_id: string; signature_hash: string;
      state: SessionInputRecord["state"]; payload: string | null; receipt: string | null;
    } | undefined;
    return row ? {
      key: row.key, sessionId: row.session_id, signatureHash: row.signature_hash,
      state: row.state, payload: row.payload ? JSON.parse(row.payload) : null,
      receipt: row.receipt ? receiptSchema.parse(JSON.parse(row.receipt)) : null,
    } : null;
  }

  prepareInput(record: Omit<SessionInputRecord, "state" | "receipt">): void {
    const now = Date.now();
    this.db.prepare(`INSERT INTO inputs
      (key, session_id, signature_hash, state, payload, created_at, updated_at)
      VALUES (?, ?, ?, 'prepared', ?, ?, ?)`)
      .run(record.key, record.sessionId, record.signatureHash, JSON.stringify(record.payload), now, now);
  }

  dispatchInput(key: string, payload?: SessionInputRecord["payload"]): void {
    const result = this.db.prepare(
      "UPDATE inputs SET state = 'dispatching', payload = coalesce(?, payload), updated_at = ? WHERE key = ? AND state IN ('prepared', 'queued')",
    ).run(payload ? JSON.stringify(payload) : null, Date.now(), key);
    if (result.changes !== 1) throw new Error("Input is not ready for dispatch");
  }

  acceptInput(key: string, receipt: SessionInputReceipt): void {
    const result = this.db.prepare(`UPDATE inputs SET state = CASE WHEN state = 'confirmed' THEN state ELSE 'accepted' END, receipt = ?, updated_at = ?
      WHERE key = ? AND state IN ('dispatching', 'confirmed')`).run(JSON.stringify(receipt), Date.now(), key);
    if (result.changes !== 1) throw new Error("Input acceptance has no dispatch record");
    this.prune();
  }

  confirmInputs(sessionId: string, clientInputIds: string[]): void {
    const update = this.db.prepare(`UPDATE inputs SET state = 'confirmed', payload = NULL,
      receipt = CASE WHEN receipt IS NULL OR json_extract(receipt, '$.mode') = 'queued' THEN ? ELSE receipt END, updated_at = ?
      WHERE key = ? AND session_id = ? AND state IN ('dispatching', 'uncertain', 'accepted')`);
    this.transaction(() => {
      for (const id of clientInputIds) update.run(JSON.stringify({ mode: "turn", turnId: null, messageId: id }), Date.now(), `${sessionId}:${id}`, sessionId);
    });
  }

  failInput(key: string, notDispatched = false): void {
    this.db.prepare(
      `UPDATE inputs SET state = CASE WHEN ? THEN
        CASE WHEN json_extract(receipt, '$.mode') = 'queued' THEN 'queued' ELSE 'prepared' END
        ELSE 'uncertain' END, updated_at = ? WHERE key = ? AND state = 'dispatching'`,
    ).run(Number(notDispatched), Date.now(), key);
    // A failure before dispatch is safe to retry; the durable payload remains prepared.
  }

  clearInterruptedInputs(interruptedTurnIds: Map<string, string>): void {
    const update = this.db.prepare(`UPDATE inputs SET state = 'uncertain', updated_at = ? WHERE session_id = ? AND state = 'accepted'
      AND json_extract(receipt, '$.turnId') = ?`);
    for (const [sessionId, turnId] of interruptedTurnIds) update.run(Date.now(), sessionId, turnId);
  }

  queueInput(key: string, messageId: string, payload: NonNullable<SessionInputRecord["payload"]>): SessionInputReceipt {
    const receipt: SessionInputReceipt = { mode: "queued", turnId: null, messageId };
    const result = this.db.prepare(`UPDATE inputs SET state = 'queued', receipt = ?, payload = ?, updated_at = ?
      WHERE key = ? AND state = 'prepared'`).run(JSON.stringify(receipt), JSON.stringify(payload), Date.now(), key);
    if (result.changes !== 1) throw new Error("Input is not ready to queue");
    return receipt;
  }

  queuedInputs(sessionId: string): SessionInputRecord[] {
    return (this.db.prepare("SELECT key FROM inputs WHERE session_id = ? AND state = 'queued' ORDER BY rowid")
      .all(sessionId) as { key: string }[]).map(({ key }) => this.getInput(key)!);
  }

  queuedSessionIds(): string[] {
    return (this.db.prepare("SELECT DISTINCT session_id FROM inputs WHERE state = 'queued'")
      .all() as { session_id: string }[]).map((row) => row.session_id);
  }

  cancelQueuedInputs(sessionId: string): void {
    this.db.prepare(`UPDATE inputs SET state = 'cancelled', updated_at = ?
      WHERE session_id = ? AND state IN ('prepared', 'queued')`).run(Date.now(), sessionId);
  }

  inputCount(): number {
    return (this.db.prepare("SELECT count(*) AS count FROM inputs").get() as { count: number }).count;
  }

  getPlan(sessionId: string): LatestPlanUpdate | null {
    const row = this.db.prepare("SELECT value FROM plans WHERE session_id = ?").get(sessionId) as
      { value: string } | undefined;
    return row ? JSON.parse(row.value) as LatestPlanUpdate : null;
  }

  setPlan(sessionId: string, value: LatestPlanUpdate | null): void {
    if (value === null) {
      this.db.prepare("DELETE FROM plans WHERE session_id = ?").run(sessionId);
    } else {
      this.db.prepare(`INSERT INTO plans VALUES (?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`)
        .run(sessionId, JSON.stringify(value), Date.now());
    }
  }

  private prune(): void {
    // Only receipts whose payload is no longer needed may expire. Native queue
    // acceptance is not evidence that an input was executed or saved upstream.
    this.db.prepare("DELETE FROM inputs WHERE (state = 'confirmed' OR (state = 'accepted' AND payload IS NULL)) AND updated_at < ?")
      .run(Date.now() - 7 * 24 * 60 * 60 * 1000);
    this.db.exec(`DELETE FROM inputs WHERE key IN (
      SELECT key FROM inputs WHERE state = 'confirmed' OR (state = 'accepted' AND payload IS NULL)
      ORDER BY updated_at DESC LIMIT -1 OFFSET 500
    )`);
  }

  private async importLegacy(stateDir: string): Promise<void> {
    if (this.db.prepare("SELECT name FROM migrations WHERE name = 'host-json-v1'").get()) return;
    const inputs = await readLegacy(join(stateDir, "session-input-dedupe-v1.json"));
    const plans = await readLegacy(join(stateDir, "session-runtime-signals-v1.json"));
    // Validate everything before the transaction; preserve both original files.
    const entries = inputs === null ? [] : legacyInputSchema.parse(inputs).entries;
    const sessions = plans === null ? [] : legacyPlansSchema.parse(plans).sessions;
    this.db.exec("BEGIN IMMEDIATE");
    try {
      const insert = this.db.prepare(`INSERT OR IGNORE INTO inputs
        (key, session_id, signature_hash, state, receipt, created_at, updated_at)
        VALUES (?, ?, ?, 'accepted', ?, ?, ?)`);
      for (const entry of entries) {
        insert.run(entry.key, entry.key.endsWith(`:${entry.receipt.messageId}`)
          ? entry.key.slice(0, -entry.receipt.messageId.length - 1) : entry.key.slice(0, entry.key.lastIndexOf(":")), entry.signatureHash,
          JSON.stringify(entry.receipt), entry.createdAt, entry.updatedAt);
      }
      const insertPlan = this.db.prepare("INSERT OR IGNORE INTO plans VALUES (?, ?, ?)");
      for (const entry of sessions) {
        insertPlan.run(entry.sessionId, JSON.stringify(entry.latestPlanUpdate), entry.updatedAt);
      }
      this.db.prepare("INSERT INTO migrations VALUES ('host-json-v1')").run();
      this.db.exec("COMMIT");
    } catch (error) {
      this.db.exec("ROLLBACK");
      throw error;
    }
  }
}

async function readLegacy(path: string): Promise<unknown> {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}

interface ProviderSessionRow {
  id: string; native_id: string | null; cwd: string; name: string | null; preview: string;
  created_at: number; updated_at: number; archived: number; metadata: string;
}
function providerSessionFromRow(row: ProviderSessionRow): StoredProviderSession {
  return { id: row.id, nativeId: row.native_id, cwd: row.cwd, name: row.name, preview: row.preview,
    createdAt: row.created_at, updatedAt: row.updated_at, archived: row.archived === 1, metadata: JSON.parse(row.metadata) };
}
interface SessionItemRow {
  kind: StoredSessionItem["kind"]; native_id: string | null; authority: StoredSessionItem["authority"]; value: string; anchor_id: string | null; client_input_id: string | null; native_input_timestamp: number | null;
}
function sessionItemFromRow(row: SessionItemRow): StoredSessionItem {
  return { kind: row.kind, nativeId: row.native_id, authority: row.authority, value: JSON.parse(row.value),
    ...(row.client_input_id ? { clientInputId: row.client_input_id } : {}),
    ...(row.native_input_timestamp != null ? { nativeInputTimestamp: row.native_input_timestamp } : {}),
    ...(row.anchor_id ? { anchorId: row.anchor_id } : {}) };
}
