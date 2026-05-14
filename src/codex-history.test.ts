import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import {
  listRecentRolloutThreads,
  loadRolloutLog,
  loadSessionRuntime,
} from "./codex-history.js";

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

  it("derives runtime from bounded slices of large rollout files", async () => {
    const filler = JSON.stringify({
      timestamp: "2026-04-29T00:00:01.000Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "assistant",
        content: "x".repeat(3 * 1024 * 1024),
      },
    });
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/tmp/project", model_provider: "openai" },
      }),
      filler,
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "event_msg",
        payload: {
          type: "token_count",
          info: {
            last_token_usage: { total_tokens: 42000 },
            model_context_window: 128000,
          },
        },
      }),
    ];

    await writeFile(rolloutPath, `${lines.join("\n")}\n`, "utf8");

    const runtime = await loadSessionRuntime("thread-1", rolloutPath, null);

    assert.equal(runtime?.modelProvider, "openai");
    assert.equal(runtime?.telemetry?.contextWindow?.currentTokens, 42000);
  });

  it("lists large recent rollout files without scanning full transcripts", async () => {
    const codexHome = nodePath.join(tempDir, "codex-home");
    const now = new Date();
    const year = String(now.getFullYear());
    const month = String(now.getMonth() + 1).padStart(2, "0");
    const day = String(now.getDate()).padStart(2, "0");
    const dayDir = nodePath.join(codexHome, "sessions", year, month, day);
    await mkdir(dayDir, { recursive: true });
    const largeRolloutPath = nodePath.join(
      dayDir,
      `rollout-${year}-${month}-${day}T00-00-00-thread-1.jsonl`,
    );
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: {
          id: "thread-1",
          cwd: "/tmp/project",
          source: {
            subagent: {
              thread_spawn: {
                parent_thread_id: "parent-thread",
                agent_role: "explorer",
              },
            },
          },
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "hello" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "response_item",
        payload: { content: "x".repeat(3 * 1024 * 1024) },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:03.000Z",
        type: "event_msg",
        payload: { type: "task_complete", last_agent_message: "Done" },
      }),
    ];
    await writeFile(largeRolloutPath, `${lines.join("\n")}\n`, "utf8");

    const threads = await listRecentRolloutThreads(codexHome, 10);

    assert.equal(threads.length, 1);
    assert.equal(threads[0]?.id, "thread-1");
    assert.equal(threads[0]?.preview, "hello");
    assert.equal(threads[0]?.status.type, "idle");
    assert.deepEqual(threads[0]?.source, {
      subagent: {
        thread_spawn: {
          parent_thread_id: "parent-thread",
          agent_role: "explorer",
        },
      },
    });
  });

  it("finds active sessions in old date folders when mtime is recent", async () => {
    const codexHome = nodePath.join(tempDir, "codex-home");
    const oldDayDir = nodePath.join(codexHome, "sessions", "2026", "04", "22");
    const todayDayDir = nodePath.join(codexHome, "sessions", "2026", "05", "03");
    await mkdir(oldDayDir, { recursive: true });
    await mkdir(todayDayDir, { recursive: true });

    const oldRolloutPath = nodePath.join(
      oldDayDir,
      "rollout-2026-04-22T15-36-03-old-thread.jsonl",
    );
    const todayRolloutPath = nodePath.join(
      todayDayDir,
      "rollout-2026-05-03T10-00-00-today-thread.jsonl",
    );

    const oldLines = [
      JSON.stringify({
        timestamp: "2026-04-22T15:36:03.000Z",
        type: "session_meta",
        payload: { id: "old-thread", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-05-03T12:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "hello" },
      }),
    ];
    const todayLines = [
      JSON.stringify({
        timestamp: "2026-05-03T10:00:00.000Z",
        type: "session_meta",
        payload: { id: "today-thread", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-05-03T10:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "world" },
      }),
    ];

    await writeFile(oldRolloutPath, `${oldLines.join("\n")}\n`, "utf8");
    await writeFile(todayRolloutPath, `${todayLines.join("\n")}\n`, "utf8");

    // Force the old file's mtime to be in the past (older than 3 days) so it is excluded.
    // This verifies we filter by mtime, not folder date.
    const threeDaysAgo = Date.now() - 4 * 24 * 60 * 60 * 1000;
    const fs = await import("node:fs");
    fs.utimesSync(oldRolloutPath, threeDaysAgo / 1000, threeDaysAgo / 1000);

    const threads = await listRecentRolloutThreads(codexHome, 10);

    assert.equal(threads.length, 1);
    assert.equal(threads[0]?.id, "today-thread");
  });

  it("finds old-folder sessions when mtime is recent", async () => {
    const codexHome = nodePath.join(tempDir, "codex-home");
    const oldDayDir = nodePath.join(codexHome, "sessions", "2026", "04", "22");
    const todayDayDir = nodePath.join(codexHome, "sessions", "2026", "05", "03");
    await mkdir(oldDayDir, { recursive: true });
    await mkdir(todayDayDir, { recursive: true });

    const oldRolloutPath = nodePath.join(
      oldDayDir,
      "rollout-2026-04-22T15-36-03-old-thread.jsonl",
    );
    const todayRolloutPath = nodePath.join(
      todayDayDir,
      "rollout-2026-05-03T10-00-00-today-thread.jsonl",
    );

    const oldLines = [
      JSON.stringify({
        timestamp: "2026-04-22T15:36:03.000Z",
        type: "session_meta",
        payload: { id: "old-thread", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-05-03T12:00:00.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "hello" },
      }),
    ];
    const todayLines = [
      JSON.stringify({
        timestamp: "2026-05-03T10:00:00.000Z",
        type: "session_meta",
        payload: { id: "today-thread", cwd: "/tmp/project" },
      }),
      JSON.stringify({
        timestamp: "2026-05-03T10:00:01.000Z",
        type: "event_msg",
        payload: { type: "user_message", message: "world" },
      }),
    ];

    await writeFile(oldRolloutPath, `${oldLines.join("\n")}\n`, "utf8");
    await writeFile(todayRolloutPath, `${todayLines.join("\n")}\n`, "utf8");

    // Do NOT backdate mtime — both files are freshly written.
    const threads = await listRecentRolloutThreads(codexHome, 10);

    assert.equal(threads.length, 2);
    const ids = threads.map((t) => t.id).sort();
    assert.deepEqual(ids, ["old-thread", "today-thread"]);
  });

  it("surfaces Codex rollout errors as system messages", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "event_msg",
        payload: {
          type: "user_message",
          message: "continue",
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "event_msg",
        payload: {
          type: "error",
          message:
            '{"error":"prompt too long; exceeded max context length by 12490 tokens"}',
        },
      }),
    ];

    await writeFile(rolloutPath, `${lines.join("\n")}\n`, "utf8");

    const log = await loadRolloutLog("thread-1", rolloutPath, null);

    assert.equal(log.messages.length, 2);
    assert.equal(log.messages[0]?.role, "user");
    assert.equal(log.messages[1]?.role, "system");
    assert.equal(
      log.messages[1]?.text,
      "Error: prompt too long; exceeded max context length by 12490 tokens",
    );
  });

  it("reconstructs command activities from Codex response function calls", async () => {
    const lines = [
      JSON.stringify({
        timestamp: "2026-04-29T00:00:00.000Z",
        type: "session_meta",
        payload: { id: "thread-1", cwd: "/repo" },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:01.000Z",
        type: "response_item",
        payload: {
          type: "function_call",
          name: "exec_command",
          arguments: JSON.stringify({
            cmd: "npm test",
            workdir: "/repo",
            yield_time_ms: 1000,
          }),
          call_id: "call-command-1",
        },
      }),
      JSON.stringify({
        timestamp: "2026-04-29T00:00:02.000Z",
        type: "response_item",
        payload: {
          type: "function_call_output",
          call_id: "call-command-1",
          output:
            "Chunk ID: abc\nWall time: 1.2345 seconds\nProcess exited with code 0\nOutput:\ntests passed\n",
        },
      }),
    ];

    await writeFile(rolloutPath, `${lines.join("\n")}\n`, "utf8");

    const log = await loadRolloutLog("thread-1", rolloutPath, null);

    assert.equal(log.totalActivities, 1);
    assert.equal(log.activities.length, 1);
    const activity = log.activities[0];
    assert(activity && activity.type === "command");
    assert.equal(activity.id, "call-command-1");
    assert.equal(activity.command, "npm test");
    assert.equal(activity.cwd, "/repo");
    assert.equal(activity.status, "completed");
    assert.equal(activity.exitCode, 0);
    assert.equal(activity.durationMs, 1235);
    assert.match(activity.output ?? "", /tests passed/);
  });
});
