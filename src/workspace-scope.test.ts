import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { collectWorkspaceRoots } from "./workspace-scope.js";
import type { SessionSummary } from "./types.js";

describe("collectWorkspaceRoots", () => {
  it("uses only explicitly configured and session workspace roots", async () => {
    const roots = await collectWorkspaceRoots(
      async () => [session("/work/alpha"), session("/work/alpha")],
      ["/work/configured"],
    );

    assert.deepEqual(roots, ["/work/configured", "/work/alpha"]);
  });

  it("does not expose an implicit root before sessions exist", async () => {
    assert.deepEqual(await collectWorkspaceRoots(async () => []), []);
  });

  it("falls back only to configured roots when session discovery fails", async () => {
    const roots = await collectWorkspaceRoots(
      async () => {
        throw new Error("provider unavailable");
      },
      ["/work/configured"],
    );

    assert.deepEqual(roots, ["/work/configured"]);
  });
});

function session(cwd: string): SessionSummary {
  return {
    id: cwd,
    title: cwd,
    preview: "",
    cwd,
    createdAt: 0,
    updatedAt: 0,
    source: "test",
    status: "idle",
    rolloutPath: null,
    runtime: null,
    gitInfo: null,
  };
}
