import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import { SessionActivityOverlayStore } from "./session-activity-overlay-store.js";
import type { SessionActivity, ToolActivity } from "./types.js";

describe("session activity overlay store", () => {
  it("persists and rehydrates normalized session activity overlays", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-overlays-"));
    try {
      const filePath = nodePath.join(dir, "overlays.json");
      const store = await SessionActivityOverlayStore.open(filePath, {
        ttlMs: 60_000,
        limit: 10,
      });
      const activity: ToolActivity = {
        id: "tool-ask-1",
        type: "tool",
        turnId: null,
        createdAt: 123,
        seq: 4,
        status: "completed",
        toolName: "ask_user",
        title: "Model asked: Which environment?",
        args: { question: "Which environment?" },
        output: "staging",
        result: { answer: "staging" },
        isError: false,
        semantic: {
          category: "interaction",
          action: "ask",
          targets: [{ type: "query", value: "Which environment?" }],
        },
      };

      await store.put("session-1", activity);

      const reopened = await SessionActivityOverlayStore.open(filePath, {
        ttlMs: 60_000,
        limit: 10,
      });
      const overlays = reopened.entries();

      assert.equal(overlays.length, 1);
      assert.equal(overlays[0]?.sessionId, "session-1");
      assert.equal(overlays[0]?.activity.id, "tool-ask-1");
      assert.equal(overlays[0]?.activity.status, "completed");
      assert.deepEqual((overlays[0]?.activity as ToolActivity).semantic, {
        category: "interaction",
        action: "ask",
        targets: [{ type: "query", value: "Which environment?" }],
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("drops stale, invalid, and over-limit overlays when opened", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-overlays-"));
    try {
      const filePath = nodePath.join(dir, "overlays.json");
      const now = Date.now();
      await writeFile(
        filePath,
        JSON.stringify({
          version: 1,
          overlays: [
            {
              sessionId: "session-1",
              savedAt: now - 120_000,
              activity: toolActivity("stale", 1),
            },
            {
              sessionId: "session-1",
              savedAt: now - 3_000,
              activity: toolActivity("kept-1", 2),
            },
            {
              sessionId: "session-1",
              savedAt: now - 2_000,
              activity: { id: "invalid" },
            },
            {
              sessionId: "session-2",
              savedAt: now - 1_000,
              activity: toolActivity("kept-2", 3),
            },
          ],
        }),
        "utf8",
      );

      const store = await SessionActivityOverlayStore.open(filePath, {
        ttlMs: 60_000,
        limit: 1,
      });
      const overlays = store.entries();

      assert.equal(overlays.length, 1);
      assert.equal(overlays[0]?.sessionId, "session-2");
      assert.equal(overlays[0]?.activity.id, "kept-2");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("enforces the overlay limit while the store stays open", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-overlays-"));
    try {
      const filePath = nodePath.join(dir, "overlays.json");
      const store = await SessionActivityOverlayStore.open(filePath, {
        ttlMs: 60_000,
        limit: 2,
      });

      await store.put("session-1", toolActivity("kept-1", 1));
      await store.put("session-1", toolActivity("kept-2", 2));
      await store.put("session-1", toolActivity("kept-3", 3));

      const overlays = store.entries();
      assert.deepEqual(
        overlays.map((entry) => entry.activity.id),
        ["kept-2", "kept-3"],
      );
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

function toolActivity(id: string, seq: number): SessionActivity {
  return {
    id,
    type: "tool",
    turnId: null,
    createdAt: 123,
    seq,
    status: "completed",
    toolName: "ask_user",
    title: "Model asked: Continue?",
    args: { question: "Continue?" },
    output: "yes",
    result: { answer: "yes" },
    isError: false,
    semantic: {
      category: "interaction",
      action: "ask",
      targets: [{ type: "query", value: "Continue?" }],
    },
  };
}
