import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, beforeEach, describe, it } from "node:test";

import { SessionSearchIndex } from "./session-search-index.js";

const NOW = Date.now();

function makeDoc(
  sessionKey: string,
  overrides: Partial<Parameters<SessionSearchIndex["indexDocument"]>[0]> = {},
): Parameters<SessionSearchIndex["indexDocument"]>[0] {
  return {
    sessionKey,
    providerKind: "fake",
    title: "Test Session",
    preview: "preview",
    cwd: "/tmp",
    createdAt: NOW,
    updatedAt: NOW,
    archived: false,
    fingerprint: `fp-${sessionKey}`,
    messages: [],
    activities: [],
    ...overrides,
  };
}

describe("SessionSearchIndex", () => {
  let tempDir = "";
  let dbPath = "";

  beforeEach(async () => {
    tempDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-search-index-"));
    dbPath = nodePath.join(tempDir, "search-index-v1.db");
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  it("returns stats after indexing", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("stats-session", {
      providerKind: "fake",
      messages: [{ id: "m1", role: "user" as const, text: "stats test", content: [], attachments: [], createdAt: Date.now(), seq: 1 }],
    }));

    const stats = index.getStats();
    assert.equal(stats.indexedSessions, 1);
    assert.ok(stats.indexSizeMB >= 0);
    assert.equal(stats.providers.length, 1);
    assert.equal(stats.providers[0].providerKind, "fake");
    assert.equal(stats.providers[0].indexedSessions, 1);

    await index.close();
  });

  it("returns a non-null snippet with the matched keyword", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("snippet-session", {
      messages: [{ id: "m1", role: "user" as const, text: "how do I configure nginx reverse proxy", content: [], attachments: [], createdAt: Date.now(), seq: 1 }],
    }));

    const results = await index.search("nginx", 10);
    assert.equal(results.length, 1);
    assert.ok(results[0].snippet != null);
    assert.ok(results[0].snippet!.toLowerCase().includes("nginx"));

    await index.close();
  });

  it("indexDocument indexes generic session data and finds it by keyword", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("session-1", {
      cwd: "/projects/sidemesh",
      messages: [
        { id: "m1", role: "user" as const, text: "how do I configure nginx", content: [], attachments: [], createdAt: Date.now(), seq: 1 },
        { id: "m2", role: "assistant" as const, text: "you can use nginx.conf", content: [], attachments: [], createdAt: Date.now(), seq: 2 },
      ],
      activities: [
        { id: "a1", type: "command", turnId: null, createdAt: Date.now(), seq: 3, status: "completed", command: "nginx -t", cwd: "/projects/sidemesh", output: null, exitCode: null, durationMs: null, source: null, processId: null, commandActions: [], terminalStatus: null, terminalInput: null },
      ],
    }));

    const results = await index.search("nginx", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "session-1");

    await index.close();
  });

  it("does not match keywords that only appear in command output", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("command-output-only", {
      title: "Navigation cleanup",
      preview: "ui tweaks",
      messages: [
        {
          id: "m1",
          role: "user" as const,
          text: "clean up breadcrumb spacing",
          content: [],
          attachments: [],
          createdAt: Date.now(),
          seq: 1,
        },
      ],
      activities: [
        {
          id: "a1",
          type: "command",
          turnId: null,
          createdAt: Date.now(),
          seq: 2,
          status: "completed",
          command: "rg breadcrumb src",
          cwd: "/tmp",
          output: "auth token retry logic\n",
          exitCode: 0,
          durationMs: 1,
          source: null,
          processId: null,
          commandActions: [],
          terminalStatus: null,
          terminalInput: null,
        },
      ],
    }));

    const results = await index.search("token", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("indexDocument skips unchanged sessions based on manifest", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const doc = makeDoc("session-2", {
      fingerprint: "fp-stable",
      messages: [{ id: "m1", role: "user" as const, text: "hello", content: [], attachments: [], createdAt: Date.now(), seq: 1 }],
    });

    await index.indexDocument(doc);
    let results = await index.search("hello", 10);
    assert.equal(results.length, 1);

    // Re-index with same fingerprint should be a no-op
    await index.indexDocument(doc);
    results = await index.search("hello", 10);
    assert.equal(results.length, 1);

    // Update content and fingerprint
    await index.indexDocument({ ...doc, fingerprint: "fp-changed", messages: [{ id: "m1", role: "user" as const, text: "goodbye", content: [], attachments: [], createdAt: Date.now(), seq: 1 }] });
    results = await index.search("goodbye", 10);
    assert.equal(results.length, 1);
    results = await index.search("hello", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("remove(sessionId) deletes generic documents", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("session-3", {
      providerKind: "pi",
      title: "Pi Session",
      preview: "pi preview",
      messages: [{ id: "m1", role: "user" as const, text: "pi test content", content: [], attachments: [], createdAt: Date.now(), seq: 1 }],
    }));

    let results = await index.search("pi test", 10);
    assert.equal(results.length, 1);

    await index.remove("session-3");
    results = await index.search("pi test", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("matches non-contiguous multi-word queries with AND semantics", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("multi-session", {
      messages: [
        { id: "m1", role: "user" as const, text: "how do I configure nginx reverse proxy", content: [], attachments: [], createdAt: Date.now(), seq: 1 },
      ],
    }));

    // Both terms appear in the content but not contiguously
    const results = await index.search("nginx proxy", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "multi-session");

    // First term matches, second does not
    const noResults = await index.search("nginx apache", 10);
    assert.equal(noResults.length, 0);

    await index.close();
  });

  it("matches prefix queries for partial words", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("prefix-session", {
      messages: [
        { id: "m1", role: "user" as const, text: "how do I configure nginx reverse proxy", content: [], attachments: [], createdAt: Date.now(), seq: 1 },
      ],
    }));

    const results = await index.search("config prox", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "prefix-session");

    await index.close();
  });

  it("returns empty results for queries with no searchable terms", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("empty-session", {
      messages: [{ id: "m1", role: "user" as const, text: "hello world", content: [], attachments: [], createdAt: Date.now(), seq: 1 }],
    }));

    const results = await index.search("***", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("filters search results by providerKind", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("fake-a", { providerKind: "fake", messages: [{ id: "m1", role: "user" as const, text: "shared keyword", content: [], attachments: [], createdAt: Date.now(), seq: 1 }] }));
    await index.indexDocument(makeDoc("pi-a", { providerKind: "pi", messages: [{ id: "m1", role: "user" as const, text: "shared keyword", content: [], attachments: [], createdAt: Date.now(), seq: 1 }] }));

    const all = await index.search("shared keyword", 10);
    assert.equal(all.length, 2);

    const filtered = await index.search("shared keyword", 10, { providerKind: "pi" });
    assert.equal(filtered.length, 1);
    assert.equal(filtered[0].sessionId, "pi-a");

    await index.close();
  });

  it("filters search results by archived", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("active-a", { archived: false, messages: [{ id: "m1", role: "user" as const, text: "banana", content: [], attachments: [], createdAt: Date.now(), seq: 1 }] }));
    await index.indexDocument(makeDoc("archived-a", { archived: true, messages: [{ id: "m1", role: "user" as const, text: "banana", content: [], attachments: [], createdAt: Date.now(), seq: 1 }] }));

    const all = await index.search("banana", 10);
    assert.equal(all.length, 2);

    const active = await index.search("banana", 10, { archived: false });
    assert.equal(active.length, 1);
    assert.equal(active[0].sessionId, "active-a");

    const archived = await index.search("banana", 10, { archived: true });
    assert.equal(archived.length, 1);
    assert.equal(archived[0].sessionId, "archived-a");

    await index.close();
  });

  it("filters search results by cwd prefix", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("cwd-a", { cwd: "/projects/sidemesh", messages: [{ id: "m1", role: "user" as const, text: "project work", content: [], attachments: [], createdAt: Date.now(), seq: 1 }] }));
    await index.indexDocument(makeDoc("cwd-b", { cwd: "/personal/notes", messages: [{ id: "m1", role: "user" as const, text: "project work", content: [], attachments: [], createdAt: Date.now(), seq: 1 }] }));

    const all = await index.search("project work", 10);
    assert.equal(all.length, 2);

    const filtered = await index.search("project work", 10, { cwd: "/projects" });
    assert.equal(filtered.length, 1);
    assert.equal(filtered[0].sessionId, "cwd-a");

    await index.close();
  });

  it("returns filtered browse results with empty query", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("browse-a", { providerKind: "fake", archived: false, updatedAt: NOW - 1000 }));
    await index.indexDocument(makeDoc("browse-b", { providerKind: "pi", archived: true, updatedAt: NOW - 500 }));

    const emptyNoFilter = await index.search("", 10);
    assert.equal(emptyNoFilter.length, 0);

    const fakeActive = await index.search("", 10, { providerKind: "fake", archived: false });
    assert.equal(fakeActive.length, 1);
    assert.equal(fakeActive[0].sessionId, "browse-a");

    await index.close();
  });

  it("per-provider stats and backfillRunning flag", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    index.setBackfillRunning(true);
    await index.indexDocument(makeDoc("stat-a", { providerKind: "fake" }));
    await index.indexDocument(makeDoc("stat-b", { providerKind: "pi" }));

    const stats = index.getStats();
    assert.equal(stats.backfillRunning, true);
    assert.equal(stats.providers.length, 2);
    const fakeStats = stats.providers.find((p) => p.providerKind === "fake");
    assert.ok(fakeStats);
    assert.equal(fakeStats!.indexedSessions, 1);

    index.setBackfillRunning(false);
    const stats2 = index.getStats();
    assert.equal(stats2.backfillRunning, false);
    assert.equal(stats2.indexedSessions, 2);

    await index.close();
  });

  it("setProviderError stores and clears errors", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("err-a", { providerKind: "fake" }));
    index.setProviderError("fake", "connection timeout");

    const stats = index.getStats();
    const fakeStats = stats.providers.find((p) => p.providerKind === "fake");
    assert.equal(fakeStats?.lastError, "connection timeout");

    index.setProviderError("fake", null);
    const stats2 = index.getStats();
    const fakeStats2 = stats2.providers.find((p) => p.providerKind === "fake");
    assert.equal(fakeStats2?.lastError, null);

    await index.close();
  });

  it("keeps current search data on reopen", async () => {
    // Simulate a v1 database by creating one manually
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument(makeDoc("migrate-a", {
      messages: [{ id: "m1", role: "user" as const, text: "testing migration", content: [], attachments: [], createdAt: Date.now(), seq: 1 }],
    }));

    // Close, reopen to trigger migration (should be a no-op since already at v2)
    await index.close();
    const index2 = new SessionSearchIndex(dbPath);
    await index2.open();

    const results = await index2.search("migration", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "migrate-a");

    await index2.close();
  });

  it("rebuilds incompatible search caches from scratch", async () => {
    const db = new DatabaseSync(dbPath);
    const createdAtSeconds = Math.trunc(NOW / 1000) - 60;
    const updatedAtSeconds = Math.trunc(NOW / 1000);
    db.exec(`
      CREATE TABLE session_search_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE session_search_documents (
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
      CREATE TABLE manifest (
        rollout_path TEXT PRIMARY KEY,
        size INTEGER NOT NULL,
        mtime_ms INTEGER NOT NULL,
        indexed_at INTEGER NOT NULL
      );
      CREATE TABLE session_manifest (
        session_key TEXT PRIMARY KEY,
        fingerprint TEXT NOT NULL,
        indexed_at INTEGER NOT NULL
      );
      CREATE VIRTUAL TABLE session_fts USING fts5(
        session_id UNINDEXED,
        content,
        tokenize = 'unicode61'
      );
    `);
    db.prepare(
      `INSERT INTO session_search_meta (key, value) VALUES ('schema_version', '3')`
    ).run();
    db.prepare(`
      INSERT INTO session_search_documents (
        session_id,
        provider_kind,
        title,
        preview,
        cwd,
        created_at,
        updated_at,
        archived,
        fingerprint,
        indexed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(
      "stale-session",
      "fake",
      "Stale Session",
      "stale preview",
      "/tmp",
      createdAtSeconds,
      updatedAtSeconds,
      0,
      "stale-fingerprint",
      NOW,
    );
    db.prepare(
      `INSERT INTO manifest (rollout_path, size, mtime_ms, indexed_at) VALUES (?, ?, ?, ?)`
    ).run("/tmp/rollout.jsonl", 128, NOW, NOW);
    db.prepare(
      `INSERT INTO session_manifest (session_key, fingerprint, indexed_at) VALUES (?, ?, ?)`
    ).run("stale-session", "stale-fingerprint", NOW);
    db.prepare(`INSERT INTO session_fts (session_id, content) VALUES (?, ?)`).run(
      "stale-session",
      "stale migration keyword",
    );
    db.close();

    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const results = await index.search("stale", 10);
    assert.deepEqual(results, []);
    assert.equal(index.getStats().indexedSessions, 0);

    await index.close();

    const reopened = new DatabaseSync(dbPath);
    const counts = reopened.prepare(`
      SELECT
        (SELECT COUNT(*) FROM session_search_documents) AS documentCount,
        (SELECT COUNT(*) FROM session_manifest) AS sessionManifestCount,
        (SELECT COUNT(*) FROM session_fts) AS ftsCount
    `).get() as {
      documentCount: number;
      sessionManifestCount: number;
      ftsCount: number;
    };
    reopened.close();

    assert.equal(counts.documentCount, 0);
    assert.equal(counts.sessionManifestCount, 0);
    assert.equal(counts.ftsCount, 0);
  });

});
