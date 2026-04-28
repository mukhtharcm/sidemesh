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

    assert.equal(command?.type, "command");
    assert.equal(command?.exitCode, 0);
    assert.equal(fileChange?.type, "file_change");
    assert.equal(fileChange?.changes[0]?.path, "README.md");
    assert.equal(webSearch?.type, "web_search");
    assert.equal(webSearch?.query, "sidemesh");
    assert.equal(image?.type, "image_generation");
    assert.equal(image?.savedPath, "/repo/image.png");
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
        toolCategory: "filesystem",
        toolAction: "read",
        toolTarget: "README.md",
        toolTargets: ["README.md"],
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
    assert.equal(existing?.toolCategory, "filesystem");
    assert.equal(existing?.toolAction, "read");
    assert.equal(existing?.toolTarget, "README.md");
    assert.deepEqual(existing?.toolTargets, ["README.md"]);
    assert.equal(incoming?.type, "tool");

    const merged = mergeActivity(existing, incoming);
    assert.equal(merged.type, "tool");
    assert.equal(merged.toolCategory, "filesystem");
    assert.equal(merged.toolAction, "read");
    assert.equal(merged.toolTarget, "README.md");
    assert.deepEqual(merged.toolTargets, ["README.md"]);
    assert.equal(merged.output, "README contents");
  });
});
