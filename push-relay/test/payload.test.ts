import { describe, expect, it } from "vitest";

import { testing } from "../src/index";

describe("APNs payloads", () => {
  it("uses generic copy and carries only routing metadata", () => {
    const payload = testing.apnsPayload({
      eventId: "event-1",
      kind: "turn_completed",
      hostId: "host-1",
      sessionId: "session-1",
      turnId: "turn-1",
      createdAt: Date.now(),
      expiresAt: Date.now() + 60_000,
    });

    expect(payload).toEqual({
      aps: {
        alert: {
          title: "Agent finished",
          body: "Agent work completed.",
        },
        sound: "default",
        "thread-id": "sidemesh-session-1",
        "interruption-level": "active",
      },
      sidemesh: {
        eventId: "event-1",
        type: "turn_completed",
        hostId: "host-1",
        sessionId: "session-1",
        turnId: "turn-1",
      },
    });
  });

  it("rejects expired and oversized events", () => {
    expect(
      testing.parsePushEvent({
        eventId: "event-1",
        kind: "approval_required",
        hostId: "host-1",
        sessionId: "session-1",
        createdAt: Date.now() - 10_000,
        expiresAt: Date.now() - 1,
      }),
    ).toBeNull();
  });
});
