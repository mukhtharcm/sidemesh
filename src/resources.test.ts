import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildSessionResources } from "./resources.js";
import type { SessionMessage, ToolActivity } from "./types.js";

describe("buildSessionResources", () => {
  it("includes image attachments returned by provider-neutral tool activities", () => {
    const activity: ToolActivity = {
      id: "tool-1",
      type: "tool",
      turnId: "turn-1",
      createdAt: 1000,
      seq: 1,
      status: "completed",
      toolName: "inspect",
      title: "Inspect screenshot",
      args: null,
      output: null,
      result: null,
      attachments: [
        { type: "image", url: "data:image/png;base64,AAAA" },
      ],
      isError: false,
      semantic: null,
    };

    const resources = buildSessionResources([], [activity]);

    assert.equal(resources.length, 1);
    assert.equal(resources[0]?.source, "tool_attachment");
    assert.equal(resources[0]?.kind, "image");
    assert.equal(resources[0]?.title, "Tool output image");
    assert.equal(resources[0]?.url, "data:image/png;base64,AAAA");
    assert.equal(resources[0]?.activityId, "tool-1");
  });

  it("indexes bare relative Markdown file references", () => {
    const message: SessionMessage = {
      id: "message-1",
      role: "assistant",
      text: "[Open report](docs/report.md)",
      content: [],
      attachments: [],
      createdAt: 1000,
      seq: 1,
    };

    const resources = buildSessionResources([message], []);

    assert.equal(resources.length, 1);
    assert.equal(resources[0]?.kind, "file");
    assert.equal(resources[0]?.path, "docs/report.md");
  });
});
