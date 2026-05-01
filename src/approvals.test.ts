import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildPendingActionQuestionMessage,
  buildPendingActionResponseMessage,
  parsePendingActionDecision,
  parsePendingActionResponseBody,
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
    assert.deepEqual(parsePendingActionDecision({ decision: "decline", scope: "session" }), {
      decision: "decline",
      scope: "once",
      legacyDecision: "decline",
    });
    assert.equal(parsePendingActionDecision({ decision: "approve", scope: "forever" }), null);
  });

  it("normalizes legacy and structured response bodies", () => {
    assert.deepEqual(parsePendingActionResponseBody({ decision: "accept" }), {
      decision: "approve",
      scope: "once",
      legacyDecision: "accept",
    });
    assert.deepEqual(
      parsePendingActionResponseBody({
        approvalDecision: { decision: "approve", scope: "session" },
      }),
      {
        decision: "approve",
        scope: "session",
        legacyDecision: "acceptForSession",
      },
    );
    assert.deepEqual(
      parsePendingActionResponseBody({ decision: "approve", scope: "session" }),
      {
        decision: "approve",
        scope: "session",
        legacyDecision: "acceptForSession",
      },
    );
    assert.deepEqual(
      parsePendingActionResponseBody({
        approvalDecision: null,
        decision: "acceptForSession",
      }),
      {
        decision: "approve",
        scope: "session",
        legacyDecision: "acceptForSession",
      },
    );
    assert.equal(parsePendingActionResponseBody({ decision: "approve", scope: "forever" }), null);
  });

  it("parses user-input and elicitation responses with action context", () => {
    assert.deepEqual(
      parsePendingActionResponseBody(
        { answer: "staging", wasFreeform: false },
        { kind: "user_input" },
      ),
      {
        answer: "staging",
        wasFreeform: false,
      },
    );
    assert.deepEqual(
      parsePendingActionResponseBody(
        {
          action: "accept",
          content: { region: "us-east", dryRun: true, tags: ["blue"] },
        },
        { kind: "elicitation" },
      ),
      {
        action: "accept",
        content: { region: "us-east", dryRun: true, tags: ["blue"] },
      },
    );
    assert.equal(
      parsePendingActionResponseBody({ content: { region: "us-east" } }, {
        kind: "elicitation",
      }),
      null,
    );
  });

  it("strips provider-private fields from public pending actions", () => {
    const action = {
      id: "action-1",
      sessionId: "session-1",
      kind: "command",
      title: "Command approval",
      detail: "npm test",
      requestedAt: 123,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      providerSecretFutureField: "must not leak",
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
    } as AgentPendingAction & { providerSecretFutureField: string };

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

  it("keeps structured user-input requests in public payloads", () => {
    const action = {
      id: "question-1",
      sessionId: "session-2",
      kind: "user_input",
      title: "Agent question",
      detail: "Which environment?",
      requestedAt: 456,
      canApprove: false,
      canApproveForSession: false,
      canDecline: false,
      userInput: {
        question: "Which environment?",
        choices: ["staging", "prod"],
        allowFreeform: false,
      },
      providerRequestId: 43,
      providerRequestKind: "copilot/ask_user",
    } as AgentPendingAction;

    assert.deepEqual(toPublicPendingAction(action), {
      id: "question-1",
      sessionId: "session-2",
      kind: "user_input",
      title: "Agent question",
      detail: "Which environment?",
      requestedAt: 456,
      canApprove: false,
      canApproveForSession: false,
      canDecline: false,
      userInput: {
        question: "Which environment?",
        choices: ["staging", "prod"],
        allowFreeform: false,
      },
    });
  });

  it("builds visible user messages for question and form responses", () => {
    assert.deepEqual(
      buildPendingActionResponseMessage(
        {
          kind: "user_input",
          title: "Agent question",
          userInput: {
            question: "Which environment?",
            choices: ["staging", "production"],
            allowFreeform: false,
          },
        },
        {
          answer: "staging",
          wasFreeform: false,
        },
        {
          id: "msg-1",
          createdAt: 123,
          seq: 7,
        },
      ),
      {
        id: "msg-1",
        role: "user",
        text: "staging",
        attachments: [],
        createdAt: 123,
        seq: 7,
      },
    );

    assert.deepEqual(
      buildPendingActionResponseMessage(
        {
          kind: "elicitation",
          title: "Structured input requested",
          elicitation: {
            mode: "form",
            message: "Choose deployment options",
            fields: [
              {
                key: "region",
                type: "string",
                title: "Region",
                required: true,
              },
              {
                key: "dryRun",
                type: "boolean",
                title: "Dry run",
                required: false,
              },
            ],
          },
        },
        {
          action: "accept",
          content: { region: "us-east", dryRun: true },
        },
        {
          id: "msg-2",
          createdAt: 456,
          seq: 8,
        },
      ),
      {
        id: "msg-2",
        role: "user",
        text: "Region: us-east\nDry run: Yes",
        attachments: [],
        createdAt: 456,
        seq: 8,
      },
    );

    assert.equal(
      buildPendingActionResponseMessage(
        {
          kind: "elicitation",
          title: "Structured input requested",
          elicitation: {
            mode: "form",
            message: "Choose deployment options",
            fields: [],
          },
        },
        { action: "decline" },
        {
          id: "msg-3",
          createdAt: 789,
          seq: 9,
        },
      ),
      null,
    );
  });

  it("builds durable assistant question messages for user input and forms", () => {
    assert.deepEqual(
      buildPendingActionQuestionMessage(
        {
          kind: "user_input",
          title: "Agent question",
          detail: "Which environment?",
          userInput: {
            question: "Which environment?",
            choices: ["staging", "production"],
            allowFreeform: false,
          },
        },
        { id: "question-msg-1", createdAt: 123, seq: 7 },
      ),
      {
        id: "question-msg-1",
        role: "assistant",
        text: "**Model asked:** Which environment?\n\n**Options:**\n- staging\n- production",
        attachments: [],
        createdAt: 123,
        seq: 7,
        phase: "question",
      },
    );

    assert.deepEqual(
      buildPendingActionQuestionMessage(
        {
          kind: "elicitation",
          title: "Structured input requested",
          detail: "Choose deployment options",
          elicitation: {
            mode: "form",
            message: "Choose deployment options",
            fields: [
              {
                key: "region",
                type: "string",
                title: "Region",
                required: true,
              },
            ],
          },
        },
        { id: "question-msg-2", createdAt: 456, seq: 8 },
      ),
      {
        id: "question-msg-2",
        role: "assistant",
        text: "**Model requested input:** Choose deployment options\n\n**Fields:**\n- Region (required)",
        attachments: [],
        createdAt: 456,
        seq: 8,
        phase: "question",
      },
    );
  });
});
