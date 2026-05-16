import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type {
  AcpRuntime,
  AcpRuntimeEnsureInput,
  AcpPermissionRequest,
  AcpRuntimeHandle,
  AcpRuntimeOptions,
  AcpRuntimeTurn,
  AcpRuntimeTurnInput,
  AcpSessionRecord,
  AcpSessionStore,
} from "acpx/runtime";

import {
  AcpxAgentProvider,
  mapAcpxRecordToSessionLog,
  mapAcpxRecordToThread,
} from "./acpx-provider.js";
import type { AgentProviderLiveEvent } from "./agent-provider.js";

const DEFAULT_OVERRIDES = {
  model: null,
  mode: null,
  reasoningEffort: null,
  fastMode: null,
  approvalPolicy: null,
  sandboxMode: null,
  networkAccess: null,
  webSearch: null,
  profile: null,
};

describe("AcpxAgentProvider", () => {
  it("maps acpx session records to Sidemesh thread and log snapshots", () => {
    const record = makeRecord({
      id: "session-1",
      messages: [
        {
          User: {
            id: "user-1",
            content: [{ Text: "Please inspect the repo" }],
          },
        },
        {
          Agent: {
            content: [
              { Thinking: { text: "I should inspect files." } },
              {
                ToolUse: {
                  id: "tool-1",
                  name: "read_file",
                  raw_input: JSON.stringify({ path: "README.md" }),
                  input: { path: "README.md" },
                  is_input_complete: true,
                },
              },
              { Text: "The README explains the project." },
            ],
            tool_results: {
              "tool-1": {
                tool_use_id: "tool-1",
                tool_name: "read_file",
                is_error: false,
                content: { Text: "# Project" },
                output: { bytes: 9 },
              },
            },
          },
        },
      ],
    });

    const thread = mapAcpxRecordToThread(record);
    assert.equal(thread.id, "session-1");
    assert.equal(thread.source, "acpx");
    assert.equal(thread.status.phase, "idle");

    const log = mapAcpxRecordToSessionLog(record);
    assert.equal(log.messages.length, 2);
    assert.equal(log.messages[0]?.role, "user");
    assert.equal(log.messages[0]?.text, "Please inspect the repo");
    assert.equal(log.messages[1]?.role, "assistant");
    assert.equal(log.messages[1]?.content[0]?.type, "thinking");
    assert.equal(log.messages[1]?.text, "The README explains the project.");
    assert.equal(log.activities.length, 1);
    assert.equal(log.activities[0]?.type, "tool");
    assert.equal(log.activities[0]?.status, "completed");
    assert.equal(log.nextSeq, 3);
  });

  it("starts acpx turns and forwards normalized live events", async () => {
    const store = new MemoryAcpSessionStore();
    const runtime = new FakeAcpRuntime(store);
    const provider = new AcpxAgentProvider(
      {
        agent: "gemini",
        command: "gemini --acp",
        stateDir: "/tmp/sidemesh-acpx-test",
      },
      {
        runtime,
        sessionStore: store,
        agentRegistry: {
          resolve: () => "gemini --acp",
          list: () => ["gemini"],
        },
      },
    );

    const events: AgentProviderLiveEvent[] = [];
    const completed = new Promise<void>((resolve) => {
      provider.on("liveEvent", (event) => {
        events.push(event);
        if (event.type === "turn_completed") {
          resolve();
        }
      });
    });

    const result = await provider.createSession({
      cwd: "/workspace",
      input: [{ type: "text", text: "hello", text_elements: [] }],
      overrides: DEFAULT_OVERRIDES,
    });
    assert.ok(result.activeTurnId);
    await completed;

    assert.equal(events.some((event) => event.type === "turn_started"), true);
    assert.equal(
      events.some(
        (event) => event.type === "assistant_delta" && event.delta === "Hello from ACP",
      ),
      true,
    );
    assert.equal(events.some((event) => event.type === "activity_updated"), true);
    assert.equal(
      events.some(
        (event) => event.type === "assistant_message_completed" && event.message.text === "Hello from ACP",
      ),
      true,
    );

    const thread = await provider.readSessionThread(result.thread.id, false);
    const log = await provider.readSessionLog(thread);
    assert.equal(log.messages.at(-1)?.text, "Hello from ACP");
    assert.equal(log.activities[0]?.type, "tool");
  });

  it("bridges acpx permission requests to Sidemesh approvals", async () => {
    const store = new MemoryAcpSessionStore();
    await store.save(makeRecord({
      id: "session-approval",
      messages: [],
    }));
    const runtime = new FakeAcpRuntime(store);
    let permissionHook: NonNullable<AcpRuntimeOptions["onPermissionRequest"]> | null = null;
    const provider = new AcpxAgentProvider(
      {
        agent: "gemini",
        command: "gemini --acp",
        stateDir: "/tmp/sidemesh-acpx-test",
      },
      {
        runtimeFactory: (options) => {
          permissionHook = options.onPermissionRequest ?? null;
          return runtime;
        },
        sessionStore: store,
        agentRegistry: {
          resolve: () => "gemini --acp",
          list: () => ["gemini"],
        },
      },
    );

    const opened = new Promise<Extract<AgentProviderLiveEvent, { type: "action_opened" }>>(
      (resolve) => {
        provider.on("liveEvent", (event) => {
          if (event.type === "action_opened") {
            resolve(event);
          }
        });
      },
    );

    const hook = permissionHook as NonNullable<AcpRuntimeOptions["onPermissionRequest"]> | null;
    assert.ok(hook);
    const decisionPromise = hook(makePermissionRequest(), {
      signal: new AbortController().signal,
    });
    const openedEvent = await opened;
    assert.equal(openedEvent.action.sessionId, "session-approval");
    assert.equal(openedEvent.action.kind, "command");
    assert.equal(openedEvent.action.approval?.category, "command");

    assert.equal(
      provider.respondToPendingAction(openedEvent.action, {
        decision: "approve",
        scope: "session",
      }),
      true,
    );
    assert.deepEqual(await decisionPromise, { outcome: "allow_always" });
  });
});

class MemoryAcpSessionStore implements AcpSessionStore {
  private readonly records = new Map<string, AcpSessionRecord>();

  async load(sessionId: string): Promise<AcpSessionRecord | undefined> {
    return this.records.get(sessionId);
  }

  async save(record: AcpSessionRecord): Promise<void> {
    this.records.set(record.acpxRecordId, structuredClone(record));
  }

  async listRecords(): Promise<AcpSessionRecord[]> {
    return [...this.records.values()].map((record) => structuredClone(record));
  }
}

class FakeAcpRuntime implements AcpRuntime {
  constructor(private readonly store: MemoryAcpSessionStore) {}

  async ensureSession(input: AcpRuntimeEnsureInput): Promise<AcpRuntimeHandle> {
    const existing = await this.store.load(input.sessionKey);
    const record = existing ?? makeRecord({
      id: input.sessionKey,
      cwd: input.cwd ?? "/workspace",
      agentCommand: "gemini --acp",
      messages: [],
    });
    record.closed = false;
    await this.store.save(record);
    return {
      sessionKey: input.sessionKey,
      backend: "acpx",
      runtimeSessionName: "fake",
      cwd: record.cwd,
      acpxRecordId: record.acpxRecordId,
      backendSessionId: record.acpSessionId,
    };
  }

  startTurn(input: AcpRuntimeTurnInput): AcpRuntimeTurn {
    void this.appendTurn(input.handle.acpxRecordId ?? input.handle.sessionKey, input.text);
    return {
      requestId: input.requestId,
      events: (async function* () {
        yield {
          type: "text_delta" as const,
          stream: "output" as const,
          text: "Hello from ACP",
        };
        yield {
          type: "tool_call" as const,
          text: "Inspect README",
          title: "read_file",
          toolCallId: "tool-live-1",
          status: "completed",
          kind: "read" as const,
          rawInput: { path: "README.md" },
          rawOutput: { text: "# Project" },
        };
      })(),
      result: Promise.resolve({ status: "completed" as const, stopReason: "end_turn" }),
      cancel: async () => {},
      closeStream: async () => {},
    };
  }

  runTurn(input: AcpRuntimeTurnInput): AsyncIterable<never> {
    void input;
    return (async function* () {})();
  }

  async cancel(): Promise<void> {}

  async close(): Promise<void> {}

  private async appendTurn(sessionId: string, prompt: string): Promise<void> {
    const record = await this.store.load(sessionId);
    if (!record) return;
    record.messages.push({
      User: {
        id: "user-live-1",
        content: [{ Text: prompt }],
      },
    });
    record.messages.push({
      Agent: {
        content: [
          {
            ToolUse: {
              id: "tool-live-1",
              name: "read_file",
              raw_input: JSON.stringify({ path: "README.md" }),
              input: { path: "README.md" },
              is_input_complete: true,
            },
          },
          { Text: "Hello from ACP" },
        ],
        tool_results: {
          "tool-live-1": {
            tool_use_id: "tool-live-1",
            tool_name: "read_file",
            is_error: false,
            content: { Text: "# Project" },
            output: { text: "# Project" },
          },
        },
      },
    });
    record.updated_at = new Date().toISOString();
    record.lastUsedAt = record.updated_at;
    await this.store.save(record);
  }
}

function makePermissionRequest(): AcpPermissionRequest {
  return {
    sessionId: "backend-session-approval",
    inferredKind: "execute",
    raw: {
      sessionId: "backend-session-approval",
      toolCall: {
        toolCallId: "tool-approval-1",
        title: "Run shell command",
        kind: "execute",
        rawInput: { command: "npm", args: ["test"] },
      },
      options: [],
    },
  } as unknown as AcpPermissionRequest;
}

function makeRecord(input: {
  id: string;
  cwd?: string;
  agentCommand?: string;
  messages: AcpSessionRecord["messages"];
}): AcpSessionRecord {
  const now = new Date("2026-01-01T00:00:00.000Z").toISOString();
  return {
    schema: "acpx.session.v1",
    acpxRecordId: input.id,
    acpSessionId: `backend-${input.id}`,
    agentCommand: input.agentCommand ?? "gemini --acp",
    cwd: input.cwd ?? "/workspace",
    createdAt: now,
    lastUsedAt: now,
    lastSeq: 0,
    eventLog: {
      active_path: "events.jsonl",
      segment_count: 1,
      max_segment_bytes: 1024,
      max_segments: 1,
    },
    closed: false,
    title: "Test ACP session",
    messages: input.messages,
    updated_at: now,
    cumulative_token_usage: {},
    request_token_usage: {},
    acpx: {
      current_model_id: "test-model",
      available_models: ["test-model"],
    },
  };
}
