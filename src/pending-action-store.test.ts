import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import type { AgentPendingAction } from "./agent-provider.js";
import {
  isRecoveredPendingAction,
  PendingActionStore,
} from "./pending-action-store.js";

describe("pending action store", () => {
  it("recovers user-input actions without provider-private payloads", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-actions-"));
    try {
      const filePath = nodePath.join(dir, "actions.json");
      const store = await PendingActionStore.open(filePath, {
        ttlMs: 60_000,
        limit: 10,
      });
      const action: AgentPendingAction = {
        id: "question-1",
        sessionId: "session-1",
        kind: "user_input",
        title: "Agent question",
        detail: "Which environment?",
        requestedAt: 123,
        canApprove: false,
        canApproveForSession: false,
        canDecline: false,
        relatedActivityId: "tool-ask-1",
        userInput: {
          question: "Which environment?",
          choices: ["staging", "production"],
          allowFreeform: true,
        },
        providerRequestId: "secret-request",
        providerRequestKind: "copilot/ask_user",
        providerPayload: { secret: true },
      };

      await store.put(action);
      const reopened = await PendingActionStore.open(filePath, {
        ttlMs: 60_000,
        limit: 10,
      });
      const recovered = reopened.recoveredActions();

      assert.equal(recovered.length, 1);
      assert.equal(recovered[0]?.id, "question-1");
      assert.equal(recovered[0]?.state, "recovered");
      assert.equal(recovered[0]?.recoverable, true);
      assert.equal(recovered[0]?.relatedActivityId, "tool-ask-1");
      assert.equal(isRecoveredPendingAction(recovered[0]!), true);
      assert.deepEqual(recovered[0]?.providerPayload, {
        recovered: true,
        originalRequestedAt: 123,
      });
      assert.deepEqual(recovered[0]?.userInput?.choices, [
        "staging",
        "production",
      ]);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("only persists recoverable interaction requests", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-actions-"));
    try {
      const store = await PendingActionStore.open(
        nodePath.join(dir, "actions.json"),
        {
          ttlMs: 60_000,
          limit: 10,
        },
      );

      await store.put({
        id: "approval-1",
        sessionId: "session-1",
        kind: "command",
        title: "Approval",
        detail: "npm test",
        requestedAt: 123,
        canApprove: true,
        canApproveForSession: false,
        canDecline: true,
        providerRequestId: "approval-1",
        providerRequestKind: "provider/approval",
      });

      await store.put({
        id: "question-1",
        sessionId: "session-1",
        kind: "user_input",
        title: "Agent question",
        detail: "Unsafe to replay",
        requestedAt: 124,
        canApprove: false,
        canApproveForSession: false,
        canDecline: false,
        recoverable: false,
        userInput: {
          question: "Unsafe to replay",
          choices: [],
          allowFreeform: true,
        },
        providerRequestId: "question-1",
        providerRequestKind: "provider/ask_user",
      });

      assert.deepEqual(store.recoveredActions(), []);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("deletes persisted actions for an archived session", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-actions-"));
    try {
      const filePath = nodePath.join(dir, "actions.json");
      const store = await PendingActionStore.open(filePath, {
        ttlMs: 60_000,
        limit: 10,
      });

      await store.put(userInputAction("question-1", "session-1"));
      await store.put(userInputAction("question-2", "session-2"));
      await store.deleteForSession("session-1");

      const reopened = await PendingActionStore.open(filePath, {
        ttlMs: 60_000,
        limit: 10,
      });
      const recovered = reopened.recoveredActions();

      assert.equal(recovered.length, 1);
      assert.equal(recovered[0]?.id, "question-2");
      assert.equal(recovered[0]?.sessionId, "session-2");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

function userInputAction(id: string, sessionId: string): AgentPendingAction {
  return {
    id,
    sessionId,
    kind: "user_input",
    title: "Agent question",
    detail: "Continue?",
    requestedAt: Date.now(),
    canApprove: false,
    canApproveForSession: false,
    canDecline: false,
    userInput: {
      question: "Continue?",
      choices: ["yes", "no"],
      allowFreeform: true,
    },
    providerRequestId: id,
    providerRequestKind: "provider/ask_user",
  };
}
