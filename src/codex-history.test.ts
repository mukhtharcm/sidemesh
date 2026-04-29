import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { loadSessionRuntime } from "./codex-history.js";

describe("loadSessionRuntime", () => {
  let tempDir = "";
  let rolloutPath = "";

  beforeEach(async () => {
    tempDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-codex-history-"));
    rolloutPath = nodePath.join(tempDir, "rollout.jsonl");
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  it("ignores failed turn runtime when deriving the latest session runtime", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/tmp/project", model_provider: "ollama-launch" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "turn_context",
        payload: {
          turn_id: "turn-good",
          model: "kimi-k2.6:cloud",
          model_provider: "ollama-launch",
          approval_policy: "never",
          sandbox_policy: { type: "danger-full-access" },
          collaboration_mode: {
            mode: "default",
            settings: { model: "kimi-k2.6:cloud", reasoning_effort: "medium" },
          },
          effort: "medium",
          summary: "auto",
          personality: "pragmatic",
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: {
          type: "task_complete",
          turn_id: "turn-good",
          last_agent_message: "Done",
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:03.000Z",
        type: "turn_context",
        payload: {
          turn_id: "turn-bad",
          model: "gpt-5.4",
          model_provider: "ollama-launch",
          approval_policy: "never",
          sandbox_policy: { type: "danger-full-access" },
          collaboration_mode: {
            mode: "default",
            settings: { model: "gpt-5.4", reasoning_effort: "medium" },
          },
          effort: "medium",
          summary: "none",
          personality: "pragmatic",
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:04.000Z",
        type: "event_msg",
        payload: {
          type: "task_complete",
          turn_id: "turn-bad",
          last_agent_message: null,
        },
      }),
    ];

    await writeFile(rolloutPath, `${lines.join("\n")}\n`, "utf8");

    const runtime = await loadSessionRuntime("thread-1", rolloutPath, null);

    assert.deepEqual(runtime, {
      model: "kimi-k2.6:cloud",
      modelProvider: "ollama-launch",
      serviceTier: undefined,
      reasoningEffort: "medium",
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
      networkAccess: undefined,
      summaryMode: "auto",
      personality: "pragmatic",
      updatedAt: Date.parse("2026-04-29T00:00:02.000Z"),
      turnId: "turn-good",
    });
  });
});
