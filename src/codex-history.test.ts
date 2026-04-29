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

  it("derives context telemetry from Codex token count rollout events", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/tmp/project", model_provider: "openai" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "turn_context",
        payload: {
          turn_id: "turn-1",
          model: "gpt-5.4",
          model_provider: "openai",
          approval_policy: "on-request",
          sandbox_policy: { type: "workspace-write" },
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: {
          type: "token_count",
          info: {
            total_token_usage: {
              input_tokens: 9000,
              cached_input_tokens: 3000,
              output_tokens: 200,
              reasoning_output_tokens: 50,
              total_tokens: 9200,
            },
            last_token_usage: {
              input_tokens: 64000,
              cached_input_tokens: 12000,
              output_tokens: 800,
              reasoning_output_tokens: 300,
              total_tokens: 64800,
            },
            model_context_window: 128000,
          },
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:03.000Z",
        type: "event_msg",
        payload: {
          type: "task_complete",
          turn_id: "turn-1",
          last_agent_message: "Done",
        },
      }),
    ];

    await writeFile(rolloutPath, `${lines.join("\n")}\n`, "utf8");

    const runtime = await loadSessionRuntime("thread-1", rolloutPath, null);

    assert.deepEqual(runtime?.telemetry?.contextWindow, {
      currentTokens: 64800,
      tokenLimit: 128000,
      messagesLength: 0,
      updatedAt: Date.parse("2026-04-29T00:00:02.000Z"),
    });
    assert.deepEqual(runtime?.telemetry?.lastUsage, {
      inputTokens: 64000,
      outputTokens: 800,
      reasoningTokens: 300,
      cacheReadTokens: 12000,
      updatedAt: Date.parse("2026-04-29T00:00:02.000Z"),
    });
    assert.equal(runtime?.model, "gpt-5.4");
    assert.equal(runtime?.turnId, "turn-1");
  });
});
