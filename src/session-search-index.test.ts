import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
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
  let codexHome = "";

  beforeEach(async () => {
    tempDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-search-index-"));
    dbPath = nodePath.join(tempDir, "search-index-v1.db");
    codexHome = nodePath.join(tempDir, "codex-home");
    await mkdir(nodePath.join(codexHome, "sessions", "2026", "05", "02"), {
      recursive: true,
    });
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  function rolloutPath(sessionId: string): string {
    return nodePath.join(
      codexHome,
      "sessions",
      "2026",
      "05",
      "02",
      `rollout-${sessionId}.jsonl`,
    );
  }

  it("indexes a rollout with user message and finds it by keyword", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-1");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "how do I configure nginx" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    const results = await index.search("nginx", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "thread-1");

    await index.close();
  });

  it("does NOT match keywords only in aggregated_output", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-2");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: {
          type: "exec_command_end",
          command: "echo hello",
          aggregated_output: "nginx configuration details here",
        },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    const results = await index.search("nginx", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("catches up new files and skips unchanged ones", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path1 = rolloutPath("thread-a");
    await writeFile(
      path1,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "alpha content" },
      }) + "\n",
      "utf8",
    );

    const result1 = await index.catchUp(codexHome);
    assert.equal(result1.indexed, 1);

    const result2 = await index.catchUp(codexHome);
    assert.equal(result2.indexed, 0);

    await index.close();
  });

  it("removes deleted files from manifest and fts on catch-up", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-del");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "delete me" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    let results = await index.search("delete", 10);
    assert.equal(results.length, 1);

    await rm(path);
    const result = await index.catchUp(codexHome);
    assert.equal(result.removed, 1);

    results = await index.search("delete", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("remove(sessionId) deletes from fts", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-rm");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "remove test" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    let results = await index.search("remove", 10);
    assert.equal(results.length, 1);

    await index.remove("thread-rm");
    results = await index.search("remove", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("indexes session_meta cwd and base instructions", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-meta");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "session_meta",
        payload: {
          id: "thread-meta",
          cwd: "/projects/sidemesh",
          base_instructions: { text: "always write tests" },
        },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    const results = await index.search("sidemesh", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "thread-meta");

    await index.close();
  });

  it("indexes agent_reasoning text", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-reason");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "agent_reasoning", text: "thinking about redis caching" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    const results = await index.search("redis", 10);
    assert.equal(results.length, 1);

    await index.close();
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

  it("indexRollout accepts an optional namespacedSessionId", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-ns");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "namespace test" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path, "codex:base64url-thread-ns");
    const results = await index.search("namespace", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "codex:base64url-thread-ns");

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

  it("schema migration rebuilds fts table", async () => {
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
  it("rollout-indexed sessions support filter queries", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-filter");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-filter", cwd: "/projects/sidemesh" },
      }) + "\n" +
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "filter test content" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);

    const textResults = await index.search("filter", 10, { providerKind: "codex" });
    assert.equal(textResults.length, 1);
    assert.equal(textResults[0].sessionId, "thread-filter");

    const browseResults = await index.search("", 10, { cwd: "/projects" });
    assert.equal(browseResults.length, 1);
    assert.equal(browseResults[0].sessionId, "thread-filter");

    await index.close();
  });

});
