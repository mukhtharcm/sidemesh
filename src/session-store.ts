import { chmod, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { z } from "zod";

import type { AgentSessionInputItem, AgentSessionOverrides } from "./agent-provider.js";
import type { LatestPlanUpdate } from "./types.js";

const receiptSchema = z.object({
  mode: z.enum(["steer", "turn"]),
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
  state: "prepared" | "dispatching" | "uncertain" | "accepted";
  payload: { input: AgentSessionInputItem[]; overrides: AgentSessionOverrides } | null;
  receipt: SessionInputReceipt | null;
}

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
      `);
      const store = new SessionStore(db);
      await store.importLegacy(stateDir);
      // The provider can have accepted a request before the daemon stopped.
      // Never dispatch these rows again without an explicit recovery decision.
      db.exec("UPDATE inputs SET state = 'uncertain' WHERE state = 'dispatching'");
      store.prune();
      return store;
    } catch (error) {
      db.close();
      throw error;
    }
  }

  close(): void { this.db.close(); }

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

  dispatchInput(key: string): void {
    const result = this.db.prepare(
      "UPDATE inputs SET state = 'dispatching', updated_at = ? WHERE key = ? AND state = 'prepared'",
    ).run(Date.now(), key);
    if (result.changes !== 1) throw new Error("Input is not ready for dispatch");
  }

  acceptInput(key: string, receipt: SessionInputReceipt): void {
    const result = this.db.prepare(`UPDATE inputs SET state = 'accepted', receipt = ?, updated_at = ?
      WHERE key = ? AND state = 'dispatching'`).run(JSON.stringify(receipt), Date.now(), key);
    if (result.changes !== 1) throw new Error("Input acceptance has no dispatch record");
    this.prune();
  }

  failInput(key: string): void {
    this.db.prepare(
      "UPDATE inputs SET state = 'uncertain', updated_at = ? WHERE key = ? AND state = 'dispatching'",
    ).run(Date.now(), key);
    // A failure before dispatch is safe to retry; the durable payload remains prepared.
  }

  clearInterruptedInputs(interruptedTurnIds: Map<string, string>): void {
    const remove = this.db.prepare(`DELETE FROM inputs WHERE session_id = ? AND state = 'accepted'
      AND json_extract(receipt, '$.turnId') = ?`);
    for (const [sessionId, turnId] of interruptedTurnIds) remove.run(sessionId, turnId);
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
    // Uncertain and unsent requests are user data, not an expiring dedupe cache.
    this.db.prepare("DELETE FROM inputs WHERE state = 'accepted' AND updated_at < ?")
      .run(Date.now() - 7 * 24 * 60 * 60 * 1000);
    this.db.exec(`DELETE FROM inputs WHERE key IN (
      SELECT key FROM inputs WHERE state = 'accepted' ORDER BY updated_at DESC LIMIT -1 OFFSET 500
    )`);
    this.db.prepare("DELETE FROM plans WHERE updated_at < ?")
      .run(Date.now() - 30 * 24 * 60 * 60 * 1000);
    this.db.exec(`DELETE FROM plans WHERE session_id IN (
      SELECT session_id FROM plans ORDER BY updated_at DESC LIMIT -1 OFFSET 500
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
        insert.run(entry.key, entry.key.slice(0, entry.key.lastIndexOf(":")), entry.signatureHash,
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
