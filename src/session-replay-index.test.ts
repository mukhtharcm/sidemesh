import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, appendFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { SessionReplayIndex } from "./session-replay-index.js";

describe("SessionReplayIndex", () => {
  let tempDir = "";
  let rolloutPath = "";

  beforeEach(async () => {
    tempDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-replay-index-"));
    rolloutPath = nodePath.join(tempDir, "rollout.jsonl");
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  it("parses a rollout file on first load", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "Hello" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: { type: "agent_message", message: "Hi there", phase: "final_answer" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const index = new SessionReplayIndex();
    const entry = await index.load("thread-1", rolloutPath);

    assert.equal(entry.messages.length, 2);
    assert.equal(entry.messages[0].seq, 0);
    assert.equal(entry.messages[0].role, "user");
    assert.equal(entry.messages[1].seq, 1);
    assert.equal(entry.messages[1].role, "assistant");
    assert.equal(entry.nextSeq, 2);
    assert.equal(entry.totalMessages, 2);
  });

  it("incrementally parses appended lines without re-reading the whole file", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "Hello" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const index = new SessionReplayIndex();
    const entry1 = await index.load("thread-1", rolloutPath);
    assert.equal(entry1.messages.length, 1);
    assert.equal(entry1.messages[0].seq, 0);

    await appendFile(
      rolloutPath,
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: { type: "agent_message", message: "Hi", phase: "final_answer" },
      }) + "\n",
      "utf8",
    );

    const entry2 = await index.load("thread-1", rolloutPath);
    assert.equal(entry2.messages.length, 2);
    assert.equal(entry2.messages[1].seq, 1);
    assert.equal(entry2.messages[1].role, "assistant");
    assert.equal(entry2.nextSeq, 2);
    assert.equal(entry2.totalMessages, 2);
  });

  it("rebuilds from scratch when the file is rewritten (inode changes)", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "First" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const index = new SessionReplayIndex();
    await index.load("thread-1", rolloutPath);

    const newLines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "Rewritten" },
      }),
    ];
    await rm(rolloutPath);
    await writeFile(rolloutPath, newLines.join("\n") + "\n", "utf8");

    const entry = await index.load("thread-1", rolloutPath);
    assert.equal(entry.messages.length, 1);
    assert.equal(entry.messages[0].text, "Rewritten");
  });

  it("returns a delta with only events newer than since", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "A" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "agent_message", message: "B", phase: "final_answer" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "C" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const index = new SessionReplayIndex();
    const entry = await index.load("thread-1", rolloutPath);
    const delta = index.getDelta(entry, 0);
    assert.equal(delta.messages.length, 2);
    assert.equal(delta.messages[0].text, "B");
    assert.equal(delta.messages[1].text, "C");

    const delta2 = index.getDelta(entry, 1);
    assert.equal(delta2.messages.length, 1);
    assert.equal(delta2.messages[0].text, "C");
    assert.equal(delta2.nextSeq, 2);
  });

  it("throws STALE_CURSOR when since is older than the retained ring buffer", async () => {
    const index = new SessionReplayIndex({ maxMessages: 2, maxActivities: 2 });

    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "A" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "agent_message", message: "B", phase: "final_answer" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "C" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const entry = await index.load("thread-1", rolloutPath);
    assert.equal(entry.messages.length, 2);

    assert.throws(() => index.getDelta(entry, -1), /Stale cursor/);
    assert.throws(() => index.getDelta(entry, 0), /Stale cursor/);

    const delta = index.getDelta(entry, 1);
    assert.equal(delta.messages.length, 1);
  });

  it("evicts least-recently-used sessions when over capacity", async () => {
    const index = new SessionReplayIndex({ maxSessions: 2 });

    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "Hello" },
      }),
    ];

    const path1 = nodePath.join(tempDir, "rollout-1.jsonl");
    const path2 = nodePath.join(tempDir, "rollout-2.jsonl");
    const path3 = nodePath.join(tempDir, "rollout-3.jsonl");

    await writeFile(path1, lines.join("\n") + "\n", "utf8");
    await writeFile(path2, lines.join("\n") + "\n", "utf8");
    await writeFile(path3, lines.join("\n") + "\n", "utf8");

    await index.load("session-1", path1);
    await index.load("session-2", path2);
    assert.equal(index.getStats().entryCount, 2);

    await index.load("session-3", path3);
    assert.equal(index.getStats().entryCount, 2);
  });

  it("preserves runtime state across incremental reads", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "turn_context",
        payload: {
          turn_id: "turn-1",
          model: "gpt-5.4",
          model_provider: "openai",
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "Hello" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const index = new SessionReplayIndex();
    const entry1 = await index.load("thread-1", rolloutPath);
    // turn_context with turnId goes into pendingTurnRuntime, not runtime
    assert.equal(entry1.runtime, null);

    await appendFile(
      rolloutPath,
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: { type: "task_complete", turn_id: "turn-1", last_agent_message: "Done" },
      }) + "\n",
      "utf8",
    );

    const entry2 = await index.load("thread-1", rolloutPath);
    // After task_complete, pending runtime is merged into main runtime
    assert.equal(entry2.runtime?.model, "gpt-5.4");
    assert.equal(entry2.runtime?.modelProvider, "openai");
  });

  it("returns empty delta for since newer than all events", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "Hello" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const index = new SessionReplayIndex();
    const entry = await index.load("thread-1", rolloutPath);

    const delta = index.getDelta(entry, 999);
    assert.equal(delta.messages.length, 0);
    assert.equal(delta.activities.length, 0);
    assert.equal(delta.nextSeq, 999);
  });

  it("handles an empty rollout file gracefully", async () => {
    await writeFile(rolloutPath, "", "utf8");

    const index = new SessionReplayIndex();
    const entry = await index.load("thread-1", rolloutPath);

    assert.equal(entry.messages.length, 0);
    assert.equal(entry.activities.length, 0);
    assert.equal(entry.nextSeq, 0);
    assert.equal(entry.runtime, null);
  });

  it("invalidates an entry and rebuilds on next load", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "Hello" },
      }),
    ];
    await writeFile(rolloutPath, lines.join("\n") + "\n", "utf8");

    const index = new SessionReplayIndex();
    await index.load("thread-1", rolloutPath);
    index.invalidate("thread-1");
    assert.equal(index.getStats().entryCount, 0);

    const entry = await index.load("thread-1", rolloutPath);
    assert.equal(entry.messages.length, 1);
  });
});
