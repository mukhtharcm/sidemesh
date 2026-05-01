import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  appendCommandActivityOutput,
  buildActivityFromThreadItem,
  buildCommandActivityFromRolloutEvent,
  buildFileChangeActivityFromRolloutEvent,
  buildImageGenerationActivityFromRolloutEvent,
  buildWebSearchActivityFromRolloutEvent,
  mergeActivity,
  normalizeStoredSessionActivity,
} from "./activity.js";

describe("Codex activity compatibility", () => {
  it("keeps Codex commandExecution thread items as command activities", () => {
    const activity = buildActivityFromThreadItem(
      {
        id: "cmd-1",
        type: "commandExecution",
        status: "in_progress",
        command: "npm test",
        cwd: "/repo",
        aggregatedOutput: "running\n",
        source: "user",
        processId: "pty-1",
      },
      { turnId: "turn-1", createdAt: 1000, seq: 7 },
    );

    assert.equal(activity?.type, "command");
    assert.equal(activity?.id, "cmd-1");
    assert.equal(activity?.turnId, "turn-1");
    assert.equal(activity?.status, "in_progress");
    assert.equal(activity?.command, "npm test");
    assert.equal(activity?.cwd, "/repo");
    assert.equal(activity?.output, "running\n");
    assert.equal(activity?.processId, "pty-1");
  });

  it("keeps Codex live command output merging on command activities", () => {
    const activity = buildActivityFromThreadItem(
      {
        id: "cmd-2",
        type: "commandExecution",
        status: "in_progress",
        command: "printf hi",
        cwd: "/repo",
        aggregatedOutput: "hi",
      },
      { turnId: "turn-1", createdAt: 1000, seq: 1 },
    );
    assert.equal(activity?.type, "command");

    const updated = appendCommandActivityOutput(activity, "\nthere");
    assert.equal(updated?.type, "command");
    assert.equal(updated?.output, "hi\nthere");
  });

  it("keeps Codex command updates from being overwritten by sparse live updates", () => {
    const existing = buildActivityFromThreadItem(
      {
        id: "cmd-3",
        type: "commandExecution",
        status: "in_progress",
        command: "npm test",
        cwd: "/repo",
        aggregatedOutput: "start\n",
      },
      { turnId: "turn-1", createdAt: 1000, seq: 1 },
    );
    const incoming = buildActivityFromThreadItem(
      {
        id: "cmd-3",
        type: "commandExecution",
        status: "completed",
        command: "npm test",
        cwd: "/repo",
      },
      { turnId: "turn-1", createdAt: 2000, seq: 9 },
    );
    assert.equal(existing?.type, "command");
    assert.equal(incoming?.type, "command");

    const merged = mergeActivity(existing, incoming);
    assert.equal(merged.type, "command");
    assert.equal(merged.createdAt, 1000);
    assert.equal(merged.seq, 1);
    assert.equal(merged.output, "start\n");
    assert.equal(merged.status, "completed");
  });

  it("keeps Codex rollout event activity types stable", () => {
    const command = buildCommandActivityFromRolloutEvent(
      {
        call_id: "rollout-cmd",
        turn_id: "turn-1",
        command: ["npm", "test"],
        cwd: "/repo",
        status: "completed",
        exit_code: 0,
        output: "ok\n",
      },
      1000,
      1,
    );
    const fileChange = buildFileChangeActivityFromRolloutEvent(
      {
        call_id: "rollout-file",
        turn_id: "turn-1",
        status: "completed",
        changes: {
          "README.md": {
            type: "update",
            unified_diff: "@@ -1 +1 @@\n-old\n+new\n",
          },
        },
      },
      1001,
      2,
    );
    const webSearch = buildWebSearchActivityFromRolloutEvent(
      {
        call_id: "rollout-web",
        turn_id: "turn-1",
        action: { query: "sidemesh" },
      },
      1002,
      3,
    );
    const image = buildImageGenerationActivityFromRolloutEvent(
      {
        call_id: "rollout-image",
        turn_id: "turn-1",
        status: "completed",
        revised_prompt: "mesh app",
        saved_path: "/repo/image.png",
      },
      1003,
      4,
    );
    const compaction = buildActivityFromThreadItem(
      {
        id: "compact-1",
        type: "contextCompaction",
        status: "completed",
      },
      { turnId: "turn-1", createdAt: 1004, seq: 5 },
    );

    assert.equal(command?.type, "command");
    assert.equal(command?.exitCode, 0);
    assert.equal(fileChange?.type, "file_change");
    assert.equal(fileChange?.changes[0]?.path, "README.md");
    assert.equal(webSearch?.type, "web_search");
    assert.equal(webSearch?.query, "sidemesh");
    assert.equal(image?.type, "image_generation");
    assert.equal(image?.savedPath, "/repo/image.png");
    assert.equal(compaction?.type, "context_compaction");
    assert.equal(compaction?.status, "completed");
  });

  it("preserves generalized tool semantics when merging tool activities", () => {
    const existing = buildActivityFromThreadItem(
      {
        id: "tool-1",
        type: "toolExecution",
        status: "in_progress",
        toolName: "view",
        title: "Read README.md",
        args: { path: "README.md" },
        semantic: {
          category: "filesystem",
          action: "read",
          targets: [{ type: "file", path: "README.md", access: "read" }],
        },
      },
      { turnId: "turn-1", createdAt: 1000, seq: 3 },
    );
    const incoming = buildActivityFromThreadItem(
      {
        id: "tool-1",
        type: "toolExecution",
        status: "completed",
        toolName: "view",
        output: "README contents",
        result: { content: "README contents" },
      },
      { turnId: "turn-1", createdAt: 2000, seq: 9 },
    );

    assert.equal(existing?.type, "tool");
    assert.equal(existing?.semantic?.category, "filesystem");
    assert.equal(existing?.semantic?.action, "read");
    assert.deepEqual(existing?.semantic?.targets, [
      { type: "file", path: "README.md", access: "read" },
    ]);
    assert.equal(incoming?.type, "tool");

    const merged = mergeActivity(existing, incoming);
    assert.equal(merged.type, "tool");
    assert.equal(merged.semantic?.category, "filesystem");
    assert.equal(merged.semantic?.action, "read");
    assert.deepEqual(merged.semantic?.targets, [
      { type: "file", path: "README.md", access: "read" },
    ]);
    assert.equal(merged.output, "README contents");
  });

  it("normalizes legacy stored tool fields into typed semantic targets", () => {
    const modeActivity = normalizeStoredSessionActivity({
      id: "tool-mode",
      turnId: "turn-1",
      createdAt: 1000,
      seq: 1,
      type: "tool",
      status: "completed",
      toolName: "session.mode",
      title: "Switched mode",
      args: null,
      output: null,
      result: null,
      isError: false,
      toolCategory: "session",
      toolAction: "mode_change",
      toolTarget: "autopilot",
      toolTargets: [],
      toolUrl: null,
      toolQuery: null,
      toolMode: "autopilot",
    } as unknown as Parameters<typeof normalizeStoredSessionActivity>[0]);
    assert.equal(modeActivity.type, "tool");
    assert.deepEqual(modeActivity.semantic, {
      category: "session",
      action: "mode_change",
      targets: [{ type: "mode", value: "autopilot" }],
    });

    const urlActivity = normalizeStoredSessionActivity({
      id: "tool-url",
      turnId: "turn-1",
      createdAt: 1001,
      seq: 2,
      type: "tool",
      status: "completed",
      toolName: "browse",
      title: "Fetched page",
      args: null,
      output: null,
      result: null,
      isError: false,
      toolCategory: "network",
      toolAction: "fetch",
      toolTarget: "https://example.com",
      toolTargets: [],
      toolUrl: "https://example.com",
      toolQuery: null,
      toolMode: null,
    } as unknown as Parameters<typeof normalizeStoredSessionActivity>[0]);
    assert.equal(urlActivity.type, "tool");
    assert.deepEqual(urlActivity.semantic, {
      category: "network",
      action: "fetch",
      targets: [{ type: "url", url: "https://example.com", role: "target" }],
    });

    const commandActivity = normalizeStoredSessionActivity({
      id: "tool-command",
      turnId: "turn-1",
      createdAt: 1002,
      seq: 3,
      type: "tool",
      status: "completed",
      toolName: "run_command",
      title: "Executed command",
      args: null,
      output: null,
      result: null,
      isError: false,
      toolCategory: "command",
      toolAction: "invoke",
      toolTarget: "npm test",
      toolTargets: [],
      toolUrl: null,
      toolQuery: null,
      toolMode: null,
    } as unknown as Parameters<typeof normalizeStoredSessionActivity>[0]);
    assert.equal(commandActivity.type, "tool");
    assert.deepEqual(commandActivity.semantic, {
      category: "command",
      action: "invoke",
      targets: [{ type: "command", command: "npm test" }],
    });
  });
});
