import { createReadStream } from "node:fs";
import { access, readdir, stat } from "node:fs/promises";
import nodePath from "node:path";
import readline from "node:readline";
import { DatabaseSync } from "node:sqlite";

import { parseJsonLine } from "./codex-history.js";
import type { SessionActivity, SessionMessage } from "./types.js";

const SCHEMA_VERSION = 2;

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

interface RolloutManifestEntry {
  rolloutPath: string;
  size: number;
  mtimeMs: number;
  indexedAt: number;
}

interface SessionManifestEntry {
  sessionKey: string;
  fingerprint: string;
  indexedAt: number;
}

const EXTRACTORS: Record<string, (payload: unknown) => string | undefined> = {
  "event_msg:user_message": (p) =>
    typeof p === "object" && p !== null && "message" in p
      ? String((p as Record<string, unknown>).message)
      : undefined,
  "event_msg:agent_message": (p) =>
    typeof p === "object" && p !== null && "message" in p
      ? String((p as Record<string, unknown>).message)
      : undefined,
  "event_msg:agent_reasoning": (p) =>
    typeof p === "object" && p !== null && "text" in p
      ? String((p as Record<string, unknown>).text)
      : undefined,
  "event_msg:exec_command_end": (p) =>
    typeof p === "object" && p !== null && "command" in p
      ? String((p as Record<string, unknown>).command)
      : undefined,
  "event_msg:web_search_begin": (p) =>
    typeof p === "object" && p !== null && "query" in p
      ? String((p as Record<string, unknown>).query)
      : undefined,
  "event_msg:web_search_end": (p) =>
    typeof p === "object" && p !== null && "pattern" in p
      ? String((p as Record<string, unknown>).pattern)
      : undefined,
  "event_msg:patch_apply_end": (p) => {
    if (typeof p !== "object" || p === null) return undefined;
    const changes = (p as Record<string, unknown>).changes;
    if (!Array.isArray(changes)) return undefined;
    return changes
      .map((c: unknown) => {
        if (typeof c !== "object" || c === null) return "";
        const path = String((c as Record<string, unknown>).path ?? "");
        const diff = String((c as Record<string, unknown>).diff ?? "");
        return `${path}\n${diff}`;
      })
      .join("\n");
  },
  "response_item:function_call": (p) =>
    typeof p === "object" && p !== null
      ? `${String((p as Record<string, unknown>).name ?? "")} ${String((p as Record<string, unknown>).arguments ?? "")}`
      : undefined,
  "event_msg:image_generation_begin": (p) =>
    typeof p === "object" && p !== null && "revisedPrompt" in p
      ? String((p as Record<string, unknown>).revisedPrompt)
      : undefined,
  "event_msg:image_generation_end": (p) =>
    typeof p === "object" && p !== null && "revisedPrompt" in p
      ? String((p as Record<string, unknown>).revisedPrompt)
      : undefined,
  session_meta: (p) => {
    if (typeof p !== "object" || p === null) return undefined;
    const cwd = String((p as Record<string, unknown>).cwd ?? "");
    const baseInstructions = (p as Record<string, unknown>).base_instructions;
    const text =
      typeof baseInstructions === "object" &&
      baseInstructions !== null &&
      "text" in baseInstructions
        ? String((baseInstructions as Record<string, unknown>).text ?? "")
        : "";
    return `${cwd} ${text}`.trim();
  },
};

function extractText(parsed: unknown): string | undefined {
  if (typeof parsed !== "object" || parsed === null) return undefined;
  const record = parsed as Record<string, unknown>;
  const type = String(record.type ?? "");
  const payload = record.payload;

  if (type === "event_msg" && typeof payload === "object" && payload !== null) {
    const payloadType = String((payload as Record<string, unknown>).type ?? "");
    const extractor = EXTRACTORS[`event_msg:${payloadType}`];
    if (extractor) {
      return extractor(payload);
    }
    return undefined;
  }

  if (type === "response_item" && typeof payload === "object" && payload !== null) {
    const payloadType = String((payload as Record<string, unknown>).type ?? "");
    if (payloadType === "function_call") {
      return EXTRACTORS["response_item:function_call"]?.(payload);
    }
    return undefined;
  }

  if (type === "session_meta") {
    return EXTRACTORS.session_meta?.(payload);
  }

  return undefined;
}

function buildSearchableContent(doc: SessionSearchDocument): string {
  const parts: string[] = [];
  parts.push(doc.title);
  parts.push(doc.preview);
  parts.push(doc.cwd);

  for (const message of doc.messages) {
    parts.push(message.text);
    for (const attachment of message.attachments) {
      if (attachment.path) parts.push(attachment.path);
      if (attachment.url) parts.push(attachment.url);
    }
  }

  for (const activity of doc.activities) {
    switch (activity.type) {
      case "command":
        parts.push(activity.command);
        if (activity.output) parts.push(activity.output);
        break;
      case "tool":
        parts.push(activity.toolName);
        if (activity.args) parts.push(JSON.stringify(activity.args));
        if (activity.output) parts.push(activity.output);
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
          if (change.diff) parts.push(change.diff);
        }
        break;
      case "turn_diff":
        if (activity.diff) parts.push(activity.diff);
        break;
      case "web_search":
        if (activity.query) parts.push(activity.query);
        for (const q of activity.queries) parts.push(q);
        if (activity.targetUrl) parts.push(activity.targetUrl);
        if (activity.pattern) parts.push(activity.pattern);
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
  return terms.map((t) => `"${t}"`).join(" AND ");
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

    this.db = new DatabaseSync(this.dbPath);

    // Schema version + metadata table
    this.db.exec(`
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
        indexed_at INTEGER NOT NULL,
        source TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_search_documents_provider ON session_search_documents(provider_kind);
      CREATE INDEX IF NOT EXISTS idx_search_documents_archived ON session_search_documents(archived);
      CREATE INDEX IF NOT EXISTS idx_search_documents_updated_at ON session_search_documents(updated_at);
      CREATE TABLE IF NOT EXISTS manifest (
        rollout_path TEXT PRIMARY KEY,
        size INTEGER NOT NULL,
        mtime_ms INTEGER NOT NULL,
        indexed_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS session_manifest (
        session_key TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL,
        indexed_at INTEGER NOT NULL
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
        session_id UNINDEXED,
        content,
        tokenize = 'unicode61'
      );
    `);

    this.migrate();
  }

  private migrate(): void {
    if (!this.db) return;

    const getVersion = this.db.prepare(
      `SELECT value FROM session_search_meta WHERE key = 'schema_version'`
    ) as {
      get: () => { value: string } | undefined;
    };
    const row = getVersion.get();
    const version = row ? parseInt(row.value, 10) || 1 : 1;

    if (version < 2) {
      // FTS5 table may exist from v1 without unicode61 tokenizer.
      // Rebuild it so tokenization is consistent.
      this.db.exec(`
        DROP TABLE IF EXISTS session_fts;
        CREATE VIRTUAL TABLE session_fts USING fts5(
          session_id UNINDEXED,
          content,
          tokenize = 'unicode61'
        );
      `);

      // Clear stale manifest tables so next backfill repopulates them.
      this.db.exec(`DELETE FROM session_manifest;`);
    }

    const setVersion = this.db.prepare(
      `INSERT OR REPLACE INTO session_search_meta (key, value) VALUES ('schema_version', ?)`
    );
    setVersion.run(String(SCHEMA_VERSION));
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

    const manifest = this.getSessionManifestEntry(doc.sessionKey);
    if (manifest && manifest.fingerprint === doc.fingerprint) {
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
          created_at, updated_at, archived, fingerprint, indexed_at, source
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
        doc.providerKind,
      );

      this.updateSessionManifest(doc.sessionKey, doc.fingerprint);

      this.db.exec("COMMIT");
    } catch {
      this.db.exec("ROLLBACK");
      throw new Error("Failed to index document");
    }
  }

  async indexRollout(
    rolloutPath: string,
    namespacedSessionId?: string,
  ): Promise<void> {
    if (!this.db) {
      throw new Error("Index not opened");
    }

    const sessionId =
      namespacedSessionId ?? extractSessionIdFromRolloutPath(rolloutPath);
    const deleteStmt = this.db.prepare(
      `DELETE FROM session_fts WHERE session_id = ?`,
    );
    deleteStmt.run(sessionId);

    const insert = this.db.prepare(
      `INSERT INTO session_fts (session_id, content) VALUES (?, ?)`,
    );

    const lines: string[] = [];
    const stream = createReadStream(rolloutPath, { encoding: "utf8" });
    const rl = readline.createInterface({ input: stream });
    for await (const line of rl) {
      const parsed = parseJsonLine(line);
      const text = extractText(parsed);
      if (text) {
        lines.push(text);
      }
    }

    if (lines.length > 0) {
      insert.run(sessionId, lines.join("\n"));
    }

    const stats = await stat(rolloutPath);
    await this.updateRolloutManifest(
      rolloutPath,
      stats.size,
      Math.floor(stats.mtimeMs),
    );
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

  async catchUp(codexHomePath: string | null): Promise<{
    indexed: number;
    removed: number;
  }> {
    if (!this.db || !codexHomePath) {
      return { indexed: 0, removed: 0 };
    }

    const allFiles = await listAllRolloutFiles(
      nodePath.join(codexHomePath, "sessions"),
    );
    const manifestPaths = this.getAllRolloutManifestPaths();
    const fileSet = new Set(allFiles);

    let removed = 0;
    for (const manifestPath of manifestPaths) {
      if (!fileSet.has(manifestPath)) {
        await this.removeByRolloutPath(manifestPath);
        removed++;
      }
    }

    let indexed = 0;
    for (const filePath of allFiles) {
      const manifest = this.getRolloutManifestEntry(filePath);
      const stats = await stat(filePath).catch(() => null);
      if (!stats) {
        await this.removeByRolloutPath(filePath);
        removed++;
        continue;
      }
      if (
        manifest &&
        manifest.size === stats.size &&
        manifest.mtimeMs === Math.floor(stats.mtimeMs)
      ) {
        continue;
      }
      await this.indexRollout(filePath);
      indexed++;
    }

    return { indexed, removed };
  }

  async remove(sessionId: string): Promise<void> {
    if (!this.db) {
      throw new Error("Index not opened");
    }
    const stmt = this.db.prepare(`DELETE FROM session_fts WHERE session_id = ?`);
    stmt.run(sessionId);

    const manifestStmt = this.db.prepare(
      `DELETE FROM session_manifest WHERE session_key = ?`,
    );
    manifestStmt.run(sessionId);

    const docStmt = this.db.prepare(
      `DELETE FROM session_search_documents WHERE session_id = ?`,
    );
    docStmt.run(sessionId);
  }

  async updateRolloutManifest(
    rolloutPath: string,
    size: number,
    mtimeMs: number,
  ): Promise<void> {
    if (!this.db) {
      throw new Error("Index not opened");
    }
    const stmt = this.db.prepare(
      `INSERT OR REPLACE INTO manifest (rollout_path, size, mtime_ms, indexed_at) VALUES (?, ?, ?, ?)`,
    );
    stmt.run(rolloutPath, size, mtimeMs, Date.now());
  }

  updateSessionManifest(sessionKey: string, fingerprint: string): void {
    if (!this.db) {
      throw new Error("Index not opened");
    }
    const stmt = this.db.prepare(
      `INSERT OR REPLACE INTO session_manifest (session_key, fingerprint, indexed_at) VALUES (?, ?, ?)`,
    );
    stmt.run(sessionKey, fingerprint, Date.now());
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

  private getRolloutManifestEntry(rolloutPath: string): RolloutManifestEntry | null {
    if (!this.db) return null;
    const stmt = this.db.prepare(
      `SELECT rollout_path, size, mtime_ms, indexed_at FROM manifest WHERE rollout_path = ?`,
    );
    const row = stmt.get(rolloutPath) as
      | {
          rollout_path: string;
          size: number;
          mtime_ms: number;
          indexed_at: number;
        }
      | undefined;
    if (!row) return null;
    return {
      rolloutPath: row.rollout_path,
      size: row.size,
      mtimeMs: row.mtime_ms,
      indexedAt: row.indexed_at,
    };
  }

  private getAllRolloutManifestPaths(): string[] {
    if (!this.db) return [];
    const stmt = this.db.prepare(`SELECT rollout_path FROM manifest`);
    const rows = stmt.all() as Array<{ rollout_path: string }>;
    return rows.map((r) => r.rollout_path);
  }

  private getSessionManifestEntry(sessionKey: string): SessionManifestEntry | null {
    if (!this.db) return null;
    const stmt = this.db.prepare(
      `SELECT session_key, fingerprint, indexed_at FROM session_manifest WHERE session_key = ?`,
    );
    const row = stmt.get(sessionKey) as
      | {
          session_key: string;
          fingerprint: string;
          indexed_at: number;
        }
      | undefined;
    if (!row) return null;
    return {
      sessionKey: row.session_key,
      fingerprint: row.fingerprint,
      indexedAt: row.indexed_at,
    };
  }

  private async removeByRolloutPath(rolloutPath: string): Promise<void> {
    if (!this.db) return;
    const sessionId = extractSessionIdFromRolloutPath(rolloutPath);
    await this.remove(sessionId);
    const deleteManifest = this.db.prepare(
      `DELETE FROM manifest WHERE rollout_path = ?`,
    );
    deleteManifest.run(rolloutPath);
  }
}

function extractSessionIdFromRolloutPath(rolloutPath: string): string {
  const base = nodePath.basename(rolloutPath, ".jsonl");
  if (base.startsWith("rollout-")) {
    return base.slice("rollout-".length);
  }
  return base;
}

async function listAllRolloutFiles(sessionsRoot: string): Promise<string[]> {
  const files: string[] = [];
  const years = await readdir(sessionsRoot).catch(() => []);
  for (const year of years) {
    const yearPath = nodePath.join(sessionsRoot, year);
    const yearStat = await stat(yearPath).catch(() => null);
    if (!yearStat?.isDirectory()) continue;
    const months = await readdir(yearPath).catch(() => []);
    for (const month of months) {
      const monthPath = nodePath.join(yearPath, month);
      const monthStat = await stat(monthPath).catch(() => null);
      if (!monthStat?.isDirectory()) continue;
      const days = await readdir(monthPath).catch(() => []);
      for (const day of days) {
        const dayPath = nodePath.join(monthPath, day);
        const dayStat = await stat(dayPath).catch(() => null);
        if (!dayStat?.isDirectory()) continue;
        const entries = await readdir(dayPath).catch(() => []);
        for (const entry of entries) {
          if (entry.startsWith("rollout-") && entry.endsWith(".jsonl")) {
            files.push(nodePath.join(dayPath, entry));
          }
        }
      }
    }
  }
  return files;
}
