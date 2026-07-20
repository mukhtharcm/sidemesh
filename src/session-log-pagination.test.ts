import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  paginateSessionLogEntries,
  SessionLogCursorError,
} from "./session-log-pagination.js";
import type { SessionActivity, SessionMessage } from "./types.js";

function message(
  id: string,
  seq: number,
  createdAt: number = seq,
): SessionMessage {
  return {
    id,
    role: "assistant",
    text: id,
    content: [],
    attachments: [],
    createdAt,
    seq,
  };
}

function activity(
  id: string,
  seq: number,
  createdAt: number = seq,
): SessionActivity {
  return {
    id,
    type: "tool",
    turnId: null,
    createdAt,
    seq,
    status: "completed",
    toolName: "test",
    title: id,
    args: null,
    output: null,
    result: null,
    isError: null,
    semantic: null,
  };
}

describe("session log pagination", () => {
  it("pages backward over one unified message and activity timeline", () => {
    const messages = [message("m1", 1), message("m3", 3), message("m5", 5)];
    const activities = [activity("a2", 2), activity("a4", 4)];

    const latest = paginateSessionLogEntries("session-1", messages, activities, {
      limit: 2,
    });
    assert.deepEqual(latest.messages.map((item) => item.id), ["m5"]);
    assert.deepEqual(latest.activities.map((item) => item.id), ["a4"]);
    assert.equal(latest.page.hasMoreBefore, true);
    assert.ok(latest.page.beforeCursor);

    const older = paginateSessionLogEntries("session-1", messages, activities, {
      limit: 2,
      beforeCursor: latest.page.beforeCursor,
    });
    assert.deepEqual(older.messages.map((item) => item.id), ["m3"]);
    assert.deepEqual(older.activities.map((item) => item.id), ["a2"]);
    assert.equal(older.page.hasMoreBefore, true);

    const oldest = paginateSessionLogEntries("session-1", messages, activities, {
      limit: 2,
      beforeCursor: older.page.beforeCursor,
    });
    assert.deepEqual(oldest.messages.map((item) => item.id), ["m1"]);
    assert.deepEqual(oldest.activities, []);
    assert.equal(oldest.page.hasMoreBefore, false);
  });

  it("rejects cursors from another session or a removed anchor", () => {
    const latest = paginateSessionLogEntries(
      "session-1",
      [message("m1", 1), message("m2", 2)],
      [],
      { limit: 1 },
    );

    assert.throws(
      () =>
        paginateSessionLogEntries("session-2", [message("m1", 1)], [], {
          limit: 1,
          beforeCursor: latest.page.beforeCursor,
        }),
      (error: unknown) =>
        error instanceof SessionLogCursorError && error.status === 400,
    );
    assert.throws(
      () =>
        paginateSessionLogEntries("session-1", [message("m1", 1)], [], {
          limit: 1,
          beforeCursor: latest.page.beforeCursor,
        }),
      (error: unknown) =>
        error instanceof SessionLogCursorError && error.status === 410,
    );
  });

  it("uses created time before deterministic sequence, kind, and id ties", () => {
    const latest = paginateSessionLogEntries(
      "session-1",
      [
        message("message-latest", 1, 40),
        message("message-tie", 8, 30),
        message("message-z", 9, 30),
      ],
      [
        activity("activity-older", 100, 10),
        activity("activity-tie", 8, 30),
        activity("activity-a", 9, 30),
      ],
      { limit: 5 },
    );

    assert.deepEqual(
      [
        ...latest.messages.map((item) => `message:${item.id}`),
        ...latest.activities.map((item) => `activity:${item.id}`),
      ].sort(),
      [
        "activity:activity-a",
        "activity:activity-tie",
        "message:message-latest",
        "message:message-tie",
        "message:message-z",
      ].sort(),
    );
    assert.equal(latest.page.hasMoreBefore, true);

    const older = paginateSessionLogEntries(
      "session-1",
      [message("message-latest", 1, 40), message("message-tie", 8, 30)],
      [activity("activity-older", 100, 10), activity("activity-tie", 8, 30)],
      { limit: 1, beforeCursor: latest.page.beforeCursor },
    );
    assert.deepEqual(older.activities.map((item) => item.id), [
      "activity-older",
    ]);
  });

  it("uses entry id as the final deterministic ordering tie-breaker", () => {
    const latest = paginateSessionLogEntries(
      "session-1",
      [message("message-z", 1, 10), message("message-a", 1, 10)],
      [],
      { limit: 1 },
    );
    assert.deepEqual(latest.messages.map((item) => item.id), ["message-z"]);

    const older = paginateSessionLogEntries(
      "session-1",
      [message("message-z", 1, 10), message("message-a", 1, 10)],
      [],
      { limit: 1, beforeCursor: latest.page.beforeCursor },
    );
    assert.deepEqual(older.messages.map((item) => item.id), ["message-a"]);
  });

  it("keeps a backward cursor stable when newer entries are appended", () => {
    const initialMessages = [
      message("m1", 1),
      message("m2", 2),
      message("m3", 3),
      message("m4", 4),
    ];
    const latest = paginateSessionLogEntries(
      "session-1",
      initialMessages,
      [],
      { limit: 2 },
    );

    const older = paginateSessionLogEntries(
      "session-1",
      [...initialMessages, message("m5", 5), message("m6", 6)],
      [],
      { limit: 2, beforeCursor: latest.page.beforeCursor },
    );
    assert.deepEqual(older.messages.map((item) => item.id), ["m1", "m2"]);
  });

  it("rejects non-canonical base64url cursors", () => {
    const latest = paginateSessionLogEntries(
      "session-1",
      [message("m1", 1), message("m2", 2)],
      [],
      { limit: 1 },
    );
    assert.ok(latest.page.beforeCursor);

    for (const suffix of ["!", "="]) {
      assert.throws(
        () =>
          paginateSessionLogEntries(
            "session-1",
            [message("m1", 1), message("m2", 2)],
            [],
            {
              limit: 1,
              beforeCursor: `${latest.page.beforeCursor}${suffix}`,
            },
          ),
        (error: unknown) =>
          error instanceof SessionLogCursorError && error.status === 400,
      );
    }
  });

  it("keeps generated cursors bounded for huge session and entry ids", () => {
    const scope = `session-${"s".repeat(100_000)}`;
    const firstId = `message-${"a".repeat(100_000)}`;
    const latest = paginateSessionLogEntries(
      scope,
      [message(firstId, 1), message(`message-${"b".repeat(100_000)}`, 2)],
      [],
      { limit: 1 },
    );
    assert.ok(latest.page.beforeCursor);
    assert.ok(latest.page.beforeCursor.length < 512);

    const older = paginateSessionLogEntries(
      scope,
      [message(firstId, 1), message(`message-${"b".repeat(100_000)}`, 2)],
      [],
      { limit: 1, beforeCursor: latest.page.beforeCursor },
    );
    assert.deepEqual(older.messages.map((item) => item.id), [firstId]);
  });
});
