import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  parsePendingActionDecision,
  toPublicPendingAction,
} from "./approvals.js";
import type { AgentPendingAction } from "./agent-provider.js";

describe("provider-neutral approvals", () => {
  it("normalizes legacy decision strings", () => {
    assert.deepEqual(parsePendingActionDecision("accept"), {
      decision: "approve",
      scope: "once",
      legacyDecision: "accept",
    });
    assert.deepEqual(parsePendingActionDecision("acceptForSession"), {
      decision: "approve",
      scope: "session",
      legacyDecision: "acceptForSession",
    });
    assert.deepEqual(parsePendingActionDecision("decline"), {
      decision: "decline",
      scope: "once",
      legacyDecision: "decline",
    });
    assert.equal(parsePendingActionDecision("bogus"), null);
  });

  it("normalizes structured decision payloads", () => {
    assert.deepEqual(
      parsePendingActionDecision({ decision: "approve", scope: "session" }),
      {
        decision: "approve",
        scope: "session",
        legacyDecision: "acceptForSession",
      },
    );
    assert.deepEqual(parsePendingActionDecision({ decision: "cancel" }), {
      decision: "cancel",
      scope: "once",
      legacyDecision: "cancel",
    });
    assert.equal(parsePendingActionDecision({ decision: "approve", scope: "forever" }), null);
  });

  it("strips provider-private fields from public pending actions", () => {
    const action: AgentPendingAction = {
      id: "action-1",
      sessionId: "session-1",
      kind: "command",
      title: "Command approval",
      detail: "npm test",
      requestedAt: 123,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      providerRequestId: 42,
      providerRequestKind: "provider/request",
      providerPayload: { secret: true },
      approval: {
        category: "command",
        operation: "test.command",
        summary: "Run tests",
        supportedScopes: ["once", "session"],
        targets: [{ type: "command", command: "npm test" }],
      },
    };

    assert.deepEqual(toPublicPendingAction(action), {
      id: "action-1",
      sessionId: "session-1",
      kind: "command",
      title: "Command approval",
      detail: "npm test",
      requestedAt: 123,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      approval: {
        category: "command",
        operation: "test.command",
        summary: "Run tests",
        supportedScopes: ["once", "session"],
        targets: [{ type: "command", command: "npm test" }],
      },
    });
  });
});
