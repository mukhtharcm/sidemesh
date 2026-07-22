import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import { PushNotificationDispatcher } from "./push-notifications.js";

describe("PushNotificationDispatcher", () => {
  it("persists subscriptions without exposing their publish token", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-push-"));
    const dispatcher = await PushNotificationDispatcher.open(stateDir);
    const summary = await dispatcher.upsertSubscription({
      installationId: "installation_123456789",
      hostId: "host-1",
      relayUrl: "https://push.example.com/ignored?secret=no",
      publishToken: "publish_token_abcdefghijklmnopqrstuvwxyz123456",
    });

    assert.equal(summary.relayUrl, "https://push.example.com/ignored");
    assert.equal("publishToken" in summary, false);
    assert.equal(dispatcher.listSubscriptions().length, 1);
    const stored = await readFile(
      nodePath.join(stateDir, "push-notifications-v1.json"),
      "utf8",
    );
    assert.match(stored, /publish_token_/);
    await dispatcher.close();
  });

  it("retries transient relay failures and removes delivered events", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-push-"));
    let now = 1_000;
    let calls = 0;
    const dispatcher = await PushNotificationDispatcher.open(stateDir, {
      now: () => now,
      random: () => 0.5,
      fetch: async () => {
        calls += 1;
        return new Response(null, { status: calls === 1 ? 503 : 202 });
      },
    });
    await dispatcher.upsertSubscription({
      installationId: "installation_123456789",
      hostId: "host-1",
      relayUrl: "https://push.example.com",
      publishToken: "publish_token_abcdefghijklmnopqrstuvwxyz123456",
    });
    await dispatcher.enqueue({
      eventId: "event-1",
      kind: "turn_completed",
      sessionId: "session-1",
    });

    await dispatcher.flushDue();
    assert.equal(calls, 1);
    now = 3_000;
    await dispatcher.flushDue();
    assert.equal(calls, 2);
    await dispatcher.close();

    const reopened = await PushNotificationDispatcher.open(stateDir);
    const stored = JSON.parse(
      await readFile(
        nodePath.join(stateDir, "push-notifications-v1.json"),
        "utf8",
      ),
    ) as { deliveries: unknown[] };
    assert.deepEqual(stored.deliveries, []);
    await reopened.close();
  });

  it("removes a subscription rejected by the relay", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-push-"));
    const dispatcher = await PushNotificationDispatcher.open(stateDir, {
      fetch: async () => new Response(null, { status: 410 }),
    });
    await dispatcher.upsertSubscription({
      installationId: "installation_123456789",
      hostId: "host-1",
      relayUrl: "https://push.example.com",
      publishToken: "publish_token_abcdefghijklmnopqrstuvwxyz123456",
    });
    await dispatcher.enqueue({
      kind: "approval_required",
      sessionId: "session-1",
      actionId: "action-1",
    });

    await dispatcher.flushDue();
    assert.deepEqual(dispatcher.listSubscriptions(), []);
    await dispatcher.close();
  });
});
