import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { SessionSearchIndex } from "./session-search-index.js";

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

    const path = rolloutPath("thread-stats");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "stats test" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    const stats = index.getStats();
    assert.equal(stats.indexedSessions, 1);
    assert.ok(stats.indexSizeMB >= 0);

    await index.close();
  });

  it("returns a non-null snippet with the matched keyword", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const path = rolloutPath("thread-snippet");
    await writeFile(
      path,
      JSON.stringify({
        timestamp: "2026-05-02T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "how do I configure nginx reverse proxy" },
      }) + "\n",
      "utf8",
    );

    await index.indexRollout(path);
    const results = await index.search("nginx", 10);
    assert.equal(results.length, 1);
    assert.ok(results[0].snippet != null);
    assert.ok(results[0].snippet!.toLowerCase().includes("nginx"));

    await index.close();
  });

  it("indexDocument indexes generic session data and finds it by keyword", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument({
      sessionKey: "fake:session-1",
      title: "My Session",
      preview: "preview text",
      cwd: "/projects/sidemesh",
      fingerprint: "fp-1",
      messages: [
        { id: "m1", role: "user" as const, text: "how do I configure nginx", attachments: [], createdAt: Date.now(), seq: 1 },
        { id: "m2", role: "assistant" as const, text: "you can use nginx.conf", attachments: [], createdAt: Date.now(), seq: 2 },
      ],
      activities: [
        { id: "a1", type: "command", turnId: null, createdAt: Date.now(), seq: 3, status: "completed", command: "nginx -t", cwd: "/projects/sidemesh", output: null, exitCode: null, durationMs: null, source: null, processId: null, commandActions: [], terminalStatus: null, terminalInput: null },
      ],
    });

    const results = await index.search("nginx", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "fake:session-1");

    await index.close();
  });

  it("indexDocument skips unchanged sessions based on manifest", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    const doc = {
      sessionKey: "fake:session-2",
      title: "Stable",
      preview: "preview",
      cwd: "/tmp",
      fingerprint: "fp-stable",
      messages: [{ id: "m1", role: "user" as const, text: "hello", attachments: [], createdAt: Date.now(), seq: 1 }],
      activities: [],
    };

    await index.indexDocument(doc);
    let results = await index.search("hello", 10);
    assert.equal(results.length, 1);

    // Re-index with same fingerprint should be a no-op
    await index.indexDocument(doc);
    results = await index.search("hello", 10);
    assert.equal(results.length, 1);

    // Update content and fingerprint
    await index.indexDocument({ ...doc, fingerprint: "fp-changed", messages: [{ id: "m1", role: "user" as const, text: "goodbye", attachments: [], createdAt: Date.now(), seq: 1 }] });
    results = await index.search("goodbye", 10);
    assert.equal(results.length, 1);
    results = await index.search("hello", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

  it("remove(sessionId) deletes generic documents", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument({
      sessionKey: "pi:session-3",
      title: "Pi Session",
      preview: "pi preview",
      cwd: "/tmp",
      fingerprint: "fp-1",
      messages: [{ id: "m1", role: "user" as const, text: "pi test content", attachments: [], createdAt: Date.now(), seq: 1 }],
      activities: [],
    });

    let results = await index.search("pi test", 10);
    assert.equal(results.length, 1);

    await index.remove("pi:session-3");
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

    await index.indexDocument({
      sessionKey: "multi:session",
      title: "Multi word test",
      preview: "preview text",
      cwd: "/tmp",
      fingerprint: "fp-multi",
      messages: [
        { id: "m1", role: "user" as const, text: "how do I configure nginx reverse proxy", attachments: [], createdAt: Date.now(), seq: 1 },
      ],
      activities: [],
    });

    // Both terms appear in the content but not contiguously
    const results = await index.search("nginx proxy", 10);
    assert.equal(results.length, 1);
    assert.equal(results[0].sessionId, "multi:session");

    // First term matches, second does not
    const noResults = await index.search("nginx apache", 10);
    assert.equal(noResults.length, 0);

    await index.close();
  });

  it("returns empty results for queries with no searchable terms", async () => {
    const index = new SessionSearchIndex(dbPath);
    await index.open();

    await index.indexDocument({
      sessionKey: "empty:session",
      title: "Empty query test",
      preview: "preview",
      cwd: "/tmp",
      fingerprint: "fp-empty",
      messages: [{ id: "m1", role: "user" as const, text: "hello world", attachments: [], createdAt: Date.now(), seq: 1 }],
      activities: [],
    });

    const results = await index.search("***", 10);
    assert.equal(results.length, 0);

    await index.close();
  });

});