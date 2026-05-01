import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, describe, it } from "node:test";
import assert from "node:assert/strict";

import { SessionTimelineOverlayStore } from "./session-timeline-overlay-store.js";

const tempRoots: string[] = [];

describe("SessionTimelineOverlayStore", () => {
  afterEach(async () => {
    await Promise.all(
      tempRoots.splice(0).map((dir) => rm(dir, { recursive: true, force: true })),
    );
  });

  it("persists Sidemesh-owned messages and activities", async () => {
    const root = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-overlay-"));
    tempRoots.push(root);
    const path = nodePath.join(root, "overlays.json");
    const options = {
      maxSessions: 10,
      maxMessagesPerSession: 10,
      maxActivitiesPerSession: 10,
    };

    const first = await SessionTimelineOverlayStore.open(path, options);
    await first.upsertMessage("session-1", {
      id: "message-1",
      role: "user",
      text: "staging",
      attachments: [],
      createdAt: 100,
      seq: 1,
    });
    await first.upsertActivity("session-1", {
      id: "plan-1",
      type: "plan",
      turnId: null,
      createdAt: 101,
      seq: 2,
      status: "completed",
      action: "updated",
      title: "Updated plan",
      summary: "Checked deployment steps.",
      content: null,
    });

    const second = await SessionTimelineOverlayStore.open(path, options);

    assert.equal(second.getMessages("session-1").length, 1);
    assert.equal(second.getMessages("session-1")[0]?.text, "staging");
    assert.equal(second.getActivities("session-1").length, 1);
    assert.equal(second.getActivities("session-1")[0]?.type, "plan");
  });
});
