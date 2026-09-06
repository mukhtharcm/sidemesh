import { access, chmod } from "node:fs/promises";
import nodePath from "node:path";
import { DatabaseSync } from "node:sqlite";

import type { SessionActivity, SessionMessage } from "./types.js";

const SCHEMA_VERSION = 5;

export interface SessionSearchResult {
  sessionId: string;
  rank: number;
  snippet: string | null;
}

export interface ProviderSearchIndexStats {
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
  /** Exact provider kind match */
  providerKind?: string;
  /** Workspace directory prefix match */
  cwd?: string;
  /** true = archived only, false = active only, undefined = all */
  archived?: boolean;
  /** Epoch milliseconds */
  updatedAfter?: number;
  /** Epoch milliseconds */
  updatedBefore?: number;
}

export interface SessionSearchDocument {
  sessionKey: string;
  providerKind: string;
  title: string;
  preview: string;
  cwd: string;
  createdAt: number;
  updatedAt: number;
  archived?: boolean;
  fingerprint: string;
  messages: SessionMessage[];
  activities: SessionActivity[];
}

function buildSearchableContent(doc: SessionSearchDocument): string {
  const parts: string[] = [];
  parts.push(doc.title);
  parts.push(doc.title);
  parts.push(doc.preview);
  parts.push(doc.cwd);

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
  private readonly dbPath: string;
  private backfillRunning = false;

  constructor(dbPath: string) {
    this.dbPath = dbPath;
  }

  async open(): Promise<void> {
    const parent = nodePath.dirname(this.dbPath);
    await access(parent).catch(() => {
      throw new Error(`State directory does not exist: ${parent}`);
    });

    const db = new DatabaseSync(this.dbPath);
    await chmod(this.dbPath, 0o600);

    try {
      db.exec("CREATE TABLE IF NOT EXISTS session_search_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
      const version = db.prepare("SELECT value FROM session_search_meta WHERE key = 'schema_version'").get() as { value: string } | undefined;
      if (version?.value !== String(SCHEMA_VERSION)) {
        // Search is derived data. Rebuild instead of migrating historical layouts.
        db.exec(`
          DROP TABLE IF EXISTS session_fts;
          DROP TABLE IF EXISTS session_search_documents;
          DROP TABLE IF EXISTS session_manifest;
          DROP TABLE IF EXISTS manifest;
        `);
      }
      // Do not expose the database to request handlers until the complete
      // schema exists. Startup intentionally opens the index in the
      // background, so assigning this.db earlier creates a narrow race where
      // getStats() can query tables that have not been created yet.
      db.exec(`
        CREATE TABLE IF NOT EXISTS session_search_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS session_search_documents (
          session_id TEXT PRIMARY KEY,
          provider_kind TEXT,
          title TEXT,
          preview TEXT,
          cwd TEXT,
          created_at INTEGER,
          updated_at INTEGER,
          archived INTEGER NOT NULL DEFAULT 0,
          fingerprint TEXT NOT NULL,
          indexed_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_search_documents_provider ON session_search_documents(provider_kind);
        CREATE INDEX IF NOT EXISTS idx_search_documents_archived ON session_search_documents(archived);
        CREATE INDEX IF NOT EXISTS idx_search_documents_updated_at ON session_search_documents(updated_at);
        CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
          session_id UNINDEXED,
          content,
          tokenize = 'unicode61'
        );
      `);

      db.prepare("INSERT OR REPLACE INTO session_search_meta (key, value) VALUES ('schema_version', ?)").run(String(SCHEMA_VERSION));
      this.db = db;

    } catch (error) {
      this.db = null;
      db.close();
      throw error;
    }
  }

  async close(): Promise<void> {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  }

  async indexDocument(doc: SessionSearchDocument): Promise<void> {
    if (!this.db) {
      throw new Error("Index not opened");
    }

    const indexed = this.db.prepare(
      "SELECT fingerprint FROM session_search_documents WHERE session_id = ?",
    ).get(doc.sessionKey) as { fingerprint: string } | undefined;
    if (indexed?.fingerprint === doc.fingerprint) {
      return;
    }

    const content = buildSearchableContent(doc);

    this.db.exec("BEGIN");
    try {
      const deleteFts = this.db.prepare(
        `DELETE FROM session_fts WHERE session_id = ?`,
      );
      deleteFts.run(doc.sessionKey);

      const insertFts = this.db.prepare(
        `INSERT INTO session_fts (session_id, content) VALUES (?, ?)`,
      );
      insertFts.run(doc.sessionKey, content);

      const deleteDoc = this.db.prepare(
        `DELETE FROM session_search_documents WHERE session_id = ?`,
      );
      deleteDoc.run(doc.sessionKey);

      const insertDoc = this.db.prepare(
        `INSERT INTO session_search_documents (
          session_id, provider_kind, title, preview, cwd,
          created_at, updated_at, archived, fingerprint, indexed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      );
      insertDoc.run(
        doc.sessionKey,
        doc.providerKind,
        doc.title,
        doc.preview,
        doc.cwd,
        doc.createdAt,
        doc.updatedAt,
        doc.archived ? 1 : 0,
        doc.fingerprint,
        Date.now(),
      );


      this.db.exec("COMMIT");
    } catch {
      this.db.exec("ROLLBACK");
      throw new Error("Failed to index document");
    }
  }

  async search(
    query: string,
    limit: number,
    filter?: SearchFilter,
  ): Promise<SessionSearchResult[]> {
    if (!this.db) {
      throw new Error("Index not opened");
    }

    const matchExpr = buildFts5MatchQuery(query);

    // Empty query with no filters → legacy no-op
    if (!matchExpr && !filter) {
      return [];
    }

    // Filtered browse without text query
    if (!matchExpr && filter) {
      const { sql, params } = this.buildBrowseQuery(filter, limit);
      const stmt = this.db.prepare(sql);
      const rows = stmt.all(...(params as any[])) as Array<{
        session_id: string;
        snippet: string | null;
        rank: number;
      }>;
      return rows.map((row, index) => ({
        sessionId: row.session_id,
        rank: row.rank ?? index,
        snippet: row.snippet,
      }));
    }

    // Text search with optional filters
    const { sql, params } = this.buildFtsQuery(matchExpr, limit, filter);
    const stmt = this.db.prepare(sql);
    const rows = stmt.all(...(params as any[])) as Array<{
      session_id: string;
      rank: number;
      snippet: string | null;
    }>;
    return rows.map((row) => ({
      sessionId: row.session_id,
      rank: row.rank,
      snippet: row.snippet,
    }));
  }

  private buildBrowseQuery(
    filter: SearchFilter,
    limit: number,
  ): { sql: string; params: unknown[] } {
    const conditions: string[] = ["1 = 1"];
    const params: unknown[] = [];

    if (filter.providerKind) {
      conditions.push("provider_kind = ?");
      params.push(filter.providerKind);
    }
    if (filter.archived !== undefined) {
      conditions.push("archived = ?");
      params.push(filter.archived ? 1 : 0);
    }
    if (filter.cwd) {
      conditions.push("cwd LIKE ? || '%'");
      params.push(filter.cwd);
    }
    if (filter.updatedAfter) {
      conditions.push("updated_at >= ?");
      params.push(filter.updatedAfter);
    }
    if (filter.updatedBefore) {
      conditions.push("updated_at <= ?");
      params.push(filter.updatedBefore);
    }

    const where = conditions.join(" AND ");
    return {
      sql: `SELECT session_id, NULL as snippet, 0 as rank
            FROM session_search_documents
            WHERE ${where}
            ORDER BY updated_at DESC
            LIMIT ?`,
      params: [...params, limit],
    };
  }

  private buildFtsQuery(
    matchExpr: string,
    limit: number,
    filter?: SearchFilter,
  ): { sql: string; params: unknown[] } {
    const conditions: string[] = ["fts.session_fts MATCH ?"];
    const params: unknown[] = [matchExpr];

    if (filter?.providerKind) {
      conditions.push("(d.provider_kind = ?)");
      params.push(filter.providerKind);
    }
    if (filter?.archived !== undefined) {
      conditions.push("(d.archived = ?)");
      params.push(filter.archived ? 1 : 0);
    }
    if (filter?.cwd) {
      conditions.push("(d.cwd LIKE ? || '%')");
      params.push(filter.cwd);
    }
    if (filter?.updatedAfter) {
      conditions.push("(d.updated_at >= ?)");
      params.push(filter.updatedAfter);
    }
    if (filter?.updatedBefore) {
      conditions.push("(d.updated_at <= ?)");
      params.push(filter.updatedBefore);
    }

    const where = conditions.join(" AND ");

    const orderBy = filter ? "fts.rank, d.updated_at DESC" : "fts.rank";
    const sql = `SELECT fts.session_id, fts.rank,
      snippet(fts.session_fts, 1, '<<<', '>>>', '...', 48) AS snippet
      FROM session_fts AS fts
      ${filter ? "JOIN session_search_documents AS d ON fts.session_id = d.session_id" : ""}
      WHERE ${where}
      ORDER BY ${orderBy}
      LIMIT ?`;

    params.push(limit);
    return { sql, params };
  }

  async remove(sessionId: string): Promise<void> {
    if (!this.db) {
      throw new Error("Index not opened");
    }
    const stmt = this.db.prepare(`DELETE FROM session_fts WHERE session_id = ?`);
    stmt.run(sessionId);

    const docStmt = this.db.prepare(
      `DELETE FROM session_search_documents WHERE session_id = ?`,
    );
    docStmt.run(sessionId);
  }

  setBackfillRunning(running: boolean): void {
    this.backfillRunning = running;
  }

  getStats(): SessionSearchIndexStats {
    if (!this.db) {
      return { indexedSessions: 0, indexSizeMB: 0, providers: [], backfillRunning: this.backfillRunning };
    }

    const sessionCount = this.db.prepare(
      `SELECT COUNT(DISTINCT session_id) AS count FROM session_fts`,
    ) as { get: () => { count: number } | undefined };
    const row = sessionCount.get();

    const pageCount = this.db.prepare(`PRAGMA page_count`) as {
      get: () => { page_count: number } | undefined;
    };
    const pageSize = this.db.prepare(`PRAGMA page_size`) as {
      get: () => { page_size: number } | undefined;
    };

    const pageCountRow = pageCount.get();
    const pageSizeRow = pageSize.get();
    const bytes =
      (pageCountRow?.page_count ?? 0) * (pageSizeRow?.page_size ?? 0);

    const providerRows = this.db.prepare(
      `SELECT provider_kind, COUNT(*) as count, MAX(indexed_at) as last_indexed_at
       FROM session_search_documents
       GROUP BY provider_kind`
    );

    const providers = (providerRows.all() as Array<{
        provider_kind: string;
        count: number;
        last_indexed_at: number | null;
      }
    >).map((r) => {
      const errMeta = this.db!.prepare(
        `SELECT value FROM session_search_meta WHERE key = ?`
      );
      const errRow = errMeta.get(`backfill_error:${r.provider_kind}`) as { value: string } | undefined;
      return {
        providerKind: r.provider_kind ?? "unknown",
        indexedSessions: r.count ?? 0,
        lastIndexedAt: r.last_indexed_at ?? null,
        lastError: errRow?.value ?? null,
      };
    });

    return {
      indexedSessions: row?.count ?? 0,
      indexSizeMB: Math.round((bytes / 1024 / 1024) * 100) / 100,
      providers,
      backfillRunning: this.backfillRunning,
    };
  }

  setProviderError(providerKind: string, error: string | null): void {
    if (!this.db) return;
    if (error) {
      const stmt = this.db.prepare(
        `INSERT OR REPLACE INTO session_search_meta (key, value) VALUES (?, ?)`
      );
      stmt.run(`backfill_error:${providerKind}`, error);
    } else {
      const stmt = this.db.prepare(
        `DELETE FROM session_search_meta WHERE key = ?`
      );
      stmt.run(`backfill_error:${providerKind}`);
    }
  }

}
