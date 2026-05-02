import { createReadStream } from "node:fs";
import { access, readdir, stat, unlink } from "node:fs/promises";
import nodePath from "node:path";
import readline from "node:readline";
import { DatabaseSync } from "node:sqlite";

import { parseJsonLine } from "./codex-history.js";

export interface SessionSearchResult {
  sessionId: string;
  rank: number;
  snippet: string | null;
}

export interface SessionSearchIndexStats {
  indexedSessions: number;
  indexSizeMB: number;
}

interface ManifestEntry {
  rolloutPath: string;
  size: number;
  mtimeMs: number;
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

/**
 * Daemon-side full-text search index backed by SQLite FTS5.
 * Indexes selective content from Codex rollout .jsonl files.
 */
export class SessionSearchIndex {
  private db: DatabaseSync | null = null;
  private readonly dbPath: string;

  constructor(dbPath: string) {
    this.dbPath = dbPath;
  }

  async open(): Promise<void> {
    const parent = nodePath.dirname(this.dbPath);
    await access(parent).catch(() => {
      throw new Error(`State directory does not exist: ${parent}`);
    });

    this.db = new DatabaseSync(this.dbPath);
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS manifest (
        rollout_path TEXT PRIMARY KEY,
        size INTEGER NOT NULL,
        mtime_ms INTEGER NOT NULL,
        indexed_at INTEGER NOT NULL
      );
    `);
    this.db.exec(`
      CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(
        session_id,
        content,
        tokenize="porter"
      );
    `);
  }

  async close(): Promise<void> {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  }

  async search(query: string, limit: number): Promise<SessionSearchResult[]> {
    if (!this.db) {
      throw new Error("Index not opened");
    }
    if (query.trim().length < 2) {
      return [];
    }

    const stmt = this.db.prepare(
      `SELECT session_id, rank, snippet(session_fts, 1, '', '', '...', 20) AS snippet FROM session_fts WHERE session_fts MATCH ? ORDER BY rank LIMIT ?`,
    );
    const rows = stmt.all(query, limit) as Array<{
      session_id: string;
      rank: number;
      snippet: string;
    }>;

    return rows.map((row) => ({
      sessionId: row.session_id,
      rank: row.rank,
      snippet: row.snippet ?? null,
    }));
  }

  async indexRollout(rolloutPath: string): Promise<void> {
    if (!this.db) {
      throw new Error("Index not opened");
    }

    const stats = await stat(rolloutPath).catch(() => null);
    if (!stats) {
      await this.removeByRolloutPath(rolloutPath);
      return;
    }

    const manifest = this.getManifestEntry(rolloutPath);
    if (
      manifest &&
      manifest.size === stats.size &&
      manifest.mtimeMs === Math.floor(stats.mtimeMs)
    ) {
      return;
    }

    await this.removeByRolloutPath(rolloutPath);

    const sessionId = extractSessionIdFromRolloutPath(rolloutPath);
    const chunks: string[] = [];

    const file = createReadStream(rolloutPath, { encoding: "utf8" });
    const lines = readline.createInterface({ input: file, crlfDelay: Infinity });

    for await (const line of lines) {
      const parsed = parseJsonLine(line);
      if (!parsed) continue;
      const text = extractText(parsed);
      if (text) {
        chunks.push(text);
      }
    }

    if (chunks.length > 0) {
      const content = chunks.join("\n");
      const insert = this.db.prepare(
        `INSERT INTO session_fts (session_id, content) VALUES (?, ?)`,
      );
      insert.run(sessionId, content);
    }

    this.updateManifest(rolloutPath, stats.size, Math.floor(stats.mtimeMs));
  }

  async catchUp(
    codexHomePath: string | null,
  ): Promise<{ indexed: number; removed: number }> {
    if (!this.db) {
      throw new Error("Index not opened");
    }
    if (!codexHomePath) {
      return { indexed: 0, removed: 0 };
    }

    const sessionsRoot = nodePath.join(codexHomePath, "sessions");
    const allFiles = await listAllRolloutFiles(sessionsRoot);
    const manifestPaths = this.getAllManifestPaths();
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
      const manifest = this.getManifestEntry(filePath);
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
  }

  async updateManifest(
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

  getStats(): SessionSearchIndexStats {
    if (!this.db) {
      return { indexedSessions: 0, indexSizeMB: 0 };
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

    return {
      indexedSessions: row?.count ?? 0,
      indexSizeMB: Math.round((bytes / 1024 / 1024) * 100) / 100,
    };
  }

  private getManifestEntry(rolloutPath: string): ManifestEntry | null {
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

  private getAllManifestPaths(): string[] {
    if (!this.db) return [];
    const stmt = this.db.prepare(`SELECT rollout_path FROM manifest`);
    const rows = stmt.all() as Array<{ rollout_path: string }>;
    return rows.map((r) => r.rollout_path);
  }

  private async removeByRolloutPath(rolloutPath: string): Promise<void> {
    if (!this.db) return;
    const sessionId = extractSessionIdFromRolloutPath(rolloutPath);
    const deleteFts = this.db.prepare(
      `DELETE FROM session_fts WHERE session_id = ?`,
    );
    deleteFts.run(sessionId);
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
