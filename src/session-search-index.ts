import { createHash } from "node:crypto";
import { access, chmod } from "node:fs/promises";
import nodePath from "node:path";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";

import type { SessionActivity, SessionMessage, SessionSummary } from "./types.js";

const SCHEMA_VERSION = 6;

export interface SessionSearchResult {
  sessionId: string;
  session: SessionSummary;
  rank: number;
  snippet: string | null;
}

export interface ProviderSearchIndexStats {
  providerId: string;
  providerKind: string;
  indexedSessions: number;
  lastIndexedAt: number | null;
  lastError: string | null;
}

export interface SessionSearchIndexStats {
  indexedSessions: number;
  indexSizeMB: number;
  providers: ProviderSearchIndexStats[];
  backfillRunning: boolean;
}

export interface SearchFilter {
  providerKind?: string;
  providerId?: string;
  /** Apply configured ownership before the result limit. */
  providerIds?: string[];
  cwd?: string;
  archived?: boolean;
  updatedAfter?: number;
  updatedBefore?: number;
}

export interface SessionSearchDocument {
  session: SessionSummary;
  archived?: boolean;
  messages: SessionMessage[];
  activities: SessionActivity[];
}

function buildSearchableContent(doc: SessionSearchDocument): string {
  const parts: string[] = [];
  parts.push(doc.session.title);
  parts.push(doc.session.title);
  parts.push(doc.session.preview);
  parts.push(doc.session.cwd);

  for (const message of doc.messages) {
    parts.push(message.text);
    for (const attachment of message.attachments) {
      if (attachment.path) parts.push(attachment.path);
    }
  }

  for (const activity of doc.activities) {
    switch (activity.type) {
      case "command":
        parts.push(activity.command);
        break;
      case "tool":
        parts.push(activity.toolName);
        if (activity.semantic) {
          for (const target of activity.semantic.targets) {
            if (target.type === "file") parts.push(target.path);
            if (target.type === "url") parts.push(target.url);
            if (target.type === "query") parts.push(target.value);
            if (target.type === "command") parts.push(target.command);
            if (target.type === "unknown") parts.push(target.label);
          }
        }
        break;
      case "file_change":
        for (const change of activity.changes) {
          parts.push(change.path);
          if (change.movePath) parts.push(change.movePath);
        }
        break;
      case "turn_diff":
        break;
      case "web_search":
        if (activity.query) parts.push(activity.query);
        for (const q of activity.queries) parts.push(q);
        break;
      case "image_generation":
        if (activity.revisedPrompt) parts.push(activity.revisedPrompt);
        if (activity.savedPath) parts.push(activity.savedPath);
        break;
    }
  }

  return parts.filter((p) => p && p.trim()).join("\n");
}

function buildFts5MatchQuery(query: string): string {
  const terms = query
    .trim()
    .split(/\s+/)
    .filter((t) => t.length > 0)
    .map((t) => t.replace(/"/g, '""').replace(/\*/g, "").replace(/'/g, "''"))
    .filter((t) => t.length > 0);
  if (terms.length === 0) {
    return "";
  }
  return terms.map((t) => `"${t}"*`).join(" AND ");
}

export class SessionSearchIndex {
  private db: DatabaseSync | null = null;
  private backfillRunning = false;

  constructor(private readonly dbPath: string) {}

  async open(): Promise<void> {
    await access(nodePath.dirname(this.dbPath));
    const db = new DatabaseSync(this.dbPath);
    try {
      await chmod(this.dbPath, 0o600);
      db.exec("CREATE TABLE IF NOT EXISTS session_search_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
      const version = db.prepare("SELECT value FROM session_search_meta WHERE key = 'schema_version'").get() as { value: string } | undefined;
      if (version?.value !== String(SCHEMA_VERSION)) {
        // Search is derived data. Never put input receipts or recovery records here.
        db.exec(`DROP TABLE IF EXISTS session_fts;
          DROP TABLE IF EXISTS session_search_documents;
          DROP TABLE IF EXISTS session_manifest;
          DROP TABLE IF EXISTS manifest;
          DELETE FROM session_search_meta;`);
      }
      db.exec(`CREATE TABLE IF NOT EXISTS session_search_documents (
          session_id TEXT PRIMARY KEY, provider_id TEXT NOT NULL, provider_kind TEXT NOT NULL,
          cwd TEXT NOT NULL, updated_at INTEGER NOT NULL, archived INTEGER NOT NULL,
          summary TEXT NOT NULL, fingerprint TEXT NOT NULL, indexed_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS search_provider ON session_search_documents(provider_id);
        CREATE INDEX IF NOT EXISTS search_updated ON session_search_documents(updated_at);
        CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(session_id UNINDEXED, content, tokenize = 'unicode61');`);
      db.prepare("INSERT OR REPLACE INTO session_search_meta (key, value) VALUES ('schema_version', ?)").run(String(SCHEMA_VERSION));
      this.db = db;
    } catch (error) { db.close(); throw error; }
  }

  async close(): Promise<void> { this.db?.close(); this.db = null; }

  async indexDocument(doc: SessionSearchDocument): Promise<void> {
    const db = this.database();
    const session = doc.session;
    if (!session.providerId) throw new Error("Search sessions need a provider instance ID");
    const content = buildSearchableContent(doc);
    const summary = JSON.stringify(session);
    const fingerprint = createHash("sha256").update(JSON.stringify([summary, doc.archived ?? false, content])).digest("hex");
    const existing = db.prepare("SELECT fingerprint FROM session_search_documents WHERE session_id = ?").get(session.id) as { fingerprint: string } | undefined;
    if (existing?.fingerprint === fingerprint) return;
    db.exec("BEGIN");
    try {
      db.prepare("DELETE FROM session_fts WHERE session_id = ?").run(session.id);
      db.prepare("INSERT INTO session_fts (session_id, content) VALUES (?, ?)").run(session.id, content);
      db.prepare(`INSERT OR REPLACE INTO session_search_documents
        (session_id, provider_id, provider_kind, cwd, updated_at, archived, summary, fingerprint, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(session.id, session.providerId, session.provider ?? "unknown",
          session.cwd, session.updatedAt, doc.archived ? 1 : 0, summary, fingerprint, Date.now());
      db.exec("COMMIT");
    } catch (error) { db.exec("ROLLBACK"); throw error; }
  }

  async search(query: string, limit: number, filter?: SearchFilter): Promise<SessionSearchResult[]> {
    const db = this.database();
    const match = buildFts5MatchQuery(query);
    if (!match && !filter) return [];
    const conditions: string[] = [];
    const params: SQLInputValue[] = [];
    if (match) { conditions.push("fts.session_fts MATCH ?"); params.push(match); }
    if (filter?.providerKind) { conditions.push("d.provider_kind = ?"); params.push(filter.providerKind); }
    if (filter?.providerId) { conditions.push("d.provider_id = ?"); params.push(filter.providerId); }
    if (filter?.providerIds) {
      if (!filter.providerIds.length) return [];
      conditions.push(`d.provider_id IN (${filter.providerIds.map(() => "?").join(",")})`);
      params.push(...filter.providerIds);
    }
    if (filter?.cwd) { conditions.push("substr(d.cwd, 1, length(?)) = ?"); params.push(filter.cwd, filter.cwd); }
    if (filter?.archived != null) { conditions.push("d.archived = ?"); params.push(filter.archived ? 1 : 0); }
    if (filter?.updatedAfter != null) { conditions.push("d.updated_at >= ?"); params.push(filter.updatedAfter); }
    if (filter?.updatedBefore != null) { conditions.push("d.updated_at <= ?"); params.push(filter.updatedBefore); }
    const rows = db.prepare(`SELECT d.session_id, d.summary,
        ${match ? "fts.rank, snippet(fts.session_fts, 1, '<<<', '>>>', '...', 48)" : "0 AS rank, NULL"} AS snippet
      FROM session_search_documents d
      ${match ? "JOIN session_fts fts ON fts.session_id = d.session_id" : ""}
      ${conditions.length ? `WHERE ${conditions.join(" AND ")}` : ""}
      ORDER BY ${match ? "fts.rank," : ""} d.updated_at DESC, d.session_id
      LIMIT ?`).all(...params, Math.max(1, limit)) as Array<{ session_id: string; summary: string; rank?: number; snippet: string | null }>;
    return rows.map((row) => ({ sessionId: row.session_id, session: JSON.parse(row.summary) as SessionSummary,
      rank: row.rank ?? 0, snippet: row.snippet }));
  }

  async remove(sessionId: string): Promise<void> {
    const db = this.database();
    db.exec("BEGIN");
    try {
      db.prepare("DELETE FROM session_fts WHERE session_id = ?").run(sessionId);
      db.prepare("DELETE FROM session_search_documents WHERE session_id = ?").run(sessionId);
      db.exec("COMMIT");
    } catch (error) { db.exec("ROLLBACK"); throw error; }
  }

  setBackfillRunning(running: boolean): void { this.backfillRunning = running; }

  getStats(): SessionSearchIndexStats {
    const db = this.db;
    if (!db) return { indexedSessions: 0, indexSizeMB: 0, providers: [], backfillRunning: this.backfillRunning };
    const { count } = db.prepare("SELECT COUNT(*) AS count FROM session_search_documents").get() as { count: number };
    const { page_count } = db.prepare("PRAGMA page_count").get() as { page_count: number };
    const { page_size } = db.prepare("PRAGMA page_size").get() as { page_size: number };
    const rows = db.prepare(`SELECT provider_id, provider_kind, COUNT(*) AS count, MAX(indexed_at) AS last_indexed_at
      FROM session_search_documents GROUP BY provider_id`).all() as Array<{ provider_id: string; provider_kind: string; count: number; last_indexed_at: number }>;
    const providers = new Map<string, ProviderSearchIndexStats>(rows.map((row) => [row.provider_id, {
      providerId: row.provider_id, providerKind: row.provider_kind, indexedSessions: row.count,
      lastIndexedAt: row.last_indexed_at, lastError: null,
    }]));
    const errors = db.prepare("SELECT key, value FROM session_search_meta WHERE key LIKE 'backfill_error:%'").all() as Array<{ key: string; value: string }>;
    for (const row of errors) {
      const id = row.key.slice("backfill_error:".length);
      const error = JSON.parse(row.value) as { kind: string; message: string };
      const provider = providers.get(id) ?? { providerId: id, providerKind: error.kind, indexedSessions: 0, lastIndexedAt: null, lastError: null };
      providers.set(id, { ...provider, lastError: error.message });
    }
    return { indexedSessions: count, indexSizeMB: Math.round(page_count * page_size / 1024 / 1024 * 100) / 100,
      providers: [...providers.values()], backfillRunning: this.backfillRunning };
  }

  setProviderError(providerId: string, error: string | null, providerKind = providerId): void {
    if (!this.db) return;
    if (error) this.db.prepare("INSERT OR REPLACE INTO session_search_meta (key, value) VALUES (?, ?)")
      .run(`backfill_error:${providerId}`, JSON.stringify({ kind: providerKind, message: error }));
    else this.db.prepare("DELETE FROM session_search_meta WHERE key = ?").run(`backfill_error:${providerId}`);
  }

  private database(): DatabaseSync {
    if (!this.db) throw new Error("Index not opened");
    return this.db;
  }
}
