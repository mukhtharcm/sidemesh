import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { CodexAgentProvider } from "./codex-provider.js";
import type {
  AgentSessionResumeOptions,
  AgentSubmitInputRequest,
} from "./agent-provider.js";
import type { SessionRuntimeSummary, ThreadRecord } from "./types.js";

function createSubmitRequest(
  overrides: Partial<AgentSubmitInputRequest["overrides"]> = {},
): AgentSubmitInputRequest {
  return {
    sessionId: "thread-1",
    input: [{ type: "text", text: "ping", text_elements: [] }],
    activeTurnId: null,
    overrides: {
      model: null,
      mode: null,
      reasoningEffort: null,
      fastMode: null,
      approvalPolicy: null,
      sandboxMode: null,
      networkAccess: null,
      webSearch: null,
      profile: null,
      ...overrides,
    },
  };
}

function createThread(): ThreadRecord {
  return {
    id: "thread-1",
    name: null,
    preview: "",
    createdAt: 0,
    updatedAt: 0,
    cwd: "/tmp/project",
    source: "cli",
    path: "/tmp/rollout.jsonl",
    status: { type: "idle" },
    gitInfo: null,
  };
}

describe("codex provider resume runtime restore", () => {
  it("emits runtime telemetry from Codex token usage notifications", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexNotification("thread/tokenUsage/updated", {
      threadId: "thread-1",
      turnId: "turn-1",
      tokenUsage: {
        modelContextWindow: 128000,
        total: {
          inputTokens: 9000,
          cachedInputTokens: 3000,
          outputTokens: 200,
          reasoningOutputTokens: 50,
          totalTokens: 9200,
        },
        last: {
          inputTokens: 64000,
          cachedInputTokens: 12000,
          outputTokens: 800,
          reasoningOutputTokens: 300,
          totalTokens: 64800,
        },
      },
    });

    assert.equal(events.length, 1);
    assert.deepEqual(events[0], {
      type: "runtime_updated",
      sessionId: "thread-1",
      runtime: {
        telemetry: {
          contextWindow: {
            currentTokens: 64800,
            tokenLimit: 128000,
            messagesLength: 0,
            updatedAt: (events[0] as any).runtime.telemetry.contextWindow.updatedAt,
          },
          lastUsage: {
            inputTokens: 64000,
            outputTokens: 800,
            reasoningTokens: 300,
            cacheReadTokens: 12000,
            updatedAt: (events[0] as any).runtime.telemetry.lastUsage.updatedAt,
          },
        },
        updatedAt: (events[0] as any).runtime.updatedAt,
        turnId: "turn-1",
      },
    });
  });

  it("restores persisted runtime when resuming an unloaded session", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const thread = createThread();
    const runtime: SessionRuntimeSummary = {
      model: "kimi-k2.6:cloud",
      modelProvider: "ollama-launch",
      serviceTier: "fast",
      reasoningEffort: "medium",
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    };
    let resume:
      | { threadId: string; options: AgentSessionResumeOptions | undefined }
      | null = null;
    const bridgeCalls: Array<{ method: string; params: unknown }> = [];

    provider.isSessionThreadLoaded = async () => false;
    provider.readSessionThread = async () => thread;
    provider.readSessionRuntime = async () => runtime;
    provider.resumeSessionThread = async (
      threadId: string,
      options?: AgentSessionResumeOptions,
    ) => {
      resume = { threadId, options };
      return {};
    };
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        bridgeCalls.push({ method, params });
        return { turn: { id: "turn-1" } };
      },
    };

    const result = await provider.submitInput(createSubmitRequest());

    assert.deepEqual(resume, {
      threadId: "thread-1",
      options: {
        persistExtendedHistory: true,
        model: "kimi-k2.6:cloud",
        modelProvider: "ollama-launch",
        serviceTier: "fast",
        approvalPolicy: "never",
        sandbox: "danger-full-access",
        config: {
          model_reasoning_effort: "medium",
        },
      },
    });
    assert.deepEqual(bridgeCalls, [
      {
        method: "turn/start",
        params: {
          threadId: "thread-1",
          input: [{ type: "text", text: "ping", text_elements: [] }],
        },
      },
    ]);
    assert.deepEqual(result, { mode: "turn", turnId: "turn-1" });
  });

  it("lets explicit send overrides win over persisted runtime", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const thread = createThread();
    const runtime: SessionRuntimeSummary = {
      model: "kimi-k2.6:cloud",
      modelProvider: "ollama-launch",
      serviceTier: "slow",
      reasoningEffort: "medium",
      approvalPolicy: "never",
      sandboxMode: "read-only",
    };
    let resumeOptions: AgentSessionResumeOptions | undefined;

    provider.isSessionThreadLoaded = async () => false;
    provider.readSessionThread = async () => thread;
    provider.readSessionRuntime = async () => runtime;
    provider.resumeSessionThread = async (
      _threadId: string,
      options?: AgentSessionResumeOptions,
    ) => {
      resumeOptions = options;
      return {};
    };
    provider.bridge = {
      request: async () => ({ turn: { id: "turn-1" } }),
    };

    await provider.submitInput(
      createSubmitRequest({
        model: "gpt-5.4",
        fastMode: true,
        reasoningEffort: "high",
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
      }),
    );

    assert.deepEqual(resumeOptions, {
      persistExtendedHistory: true,
      model: "gpt-5.4",
      modelProvider: "ollama-launch",
      serviceTier: "fast",
      approvalPolicy: "on-request",
      sandbox: "workspace-write",
      config: {
        model_reasoning_effort: "high",
      },
    });
  });

  it("restores persisted runtime before compacting an unloaded session", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const thread = createThread();
    const runtime: SessionRuntimeSummary = {
      model: "kimi-k2.6:cloud",
      modelProvider: "ollama-launch",
      reasoningEffort: "xhigh",
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    };
    let resume:
      | { threadId: string; options: AgentSessionResumeOptions | undefined }
      | null = null;
    const bridgeCalls: Array<{ method: string; params: unknown }> = [];

    provider.isSessionThreadLoaded = async () => false;
    provider.readSessionThread = async () => thread;
    provider.readSessionRuntime = async () => runtime;
    provider.resumeSessionThread = async (
      threadId: string,
      options?: AgentSessionResumeOptions,
    ) => {
      resume = { threadId, options };
      return {};
    };
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        bridgeCalls.push({ method, params });
        return { started: true };
      },
    };

    const result = await provider.compactSession("thread-1");

    assert.deepEqual(resume, {
      threadId: "thread-1",
      options: {
        persistExtendedHistory: true,
        model: "kimi-k2.6:cloud",
        modelProvider: "ollama-launch",
        approvalPolicy: "never",
        sandbox: "danger-full-access",
        config: {
          model_reasoning_effort: "xhigh",
        },
      },
    });
    assert.deepEqual(bridgeCalls, [
      {
        method: "thread/compact/start",
        params: { threadId: "thread-1" },
      },
    ]);
    assert.deepEqual(result, { started: true });
  });
});
