import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { CodexAgentProvider } from "./codex-provider.js";
import { AgentProviderRequestError } from "./agent-provider.js";
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

describe("codex provider usage observations", () => {
  it("lists native permission profiles and reviewer choices", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const requests: Array<{ method: string; params: unknown }> = [];
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        requests.push({ method, params });
        if (method === "configRequirements/read") {
          return { requirements: null };
        }
        if (method === "experimentalFeature/list") {
          return {
            data: [{ name: "guardian_approval", enabled: true }],
            nextCursor: null,
          };
        }
        if (method === "config/read") {
          return {
            config: {
              default_permissions: ":workspace",
              approval_policy: "on-request",
              approvals_reviewer: "auto_review",
            },
          };
        }
        return {
          data: [
            {
              id: ":workspace",
              description: "Read and write the current workspace.",
              allowed: true,
            },
            {
              id: ":danger-full-access",
              description: "Unrestricted access.",
              allowed: false,
            },
          ],
          nextCursor: null,
        };
      },
    };

    const catalog = await provider.listPermissionProfiles({ cwd: "/tmp/project" });

    assert.deepEqual(requests, [
      {
        method: "permissionProfile/list",
        params: { cwd: "/tmp/project", cursor: null, limit: 100 },
      },
      { method: "configRequirements/read", params: undefined },
      {
        method: "experimentalFeature/list",
        params: { cursor: null, limit: 100 },
      },
      { method: "config/read", params: { cwd: "/tmp/project" } },
    ]);
    assert.deepEqual(catalog.profiles, [
      {
        id: ":workspace",
        label: "Workspace",
        description: "Read and write the current workspace.",
        allowed: true,
      },
      {
        id: ":danger-full-access",
        label: "Full access",
        description: "Unrestricted access.",
        allowed: false,
      },
    ]);
    assert.deepEqual(
      catalog.reviewerOptions.map((option: { id: string }) => option.id),
      ["user", "auto_review"],
    );
    assert.deepEqual(
      catalog.modes.map((mode: { id: string }) => mode.id),
      ["ask-for-approval", "approve-for-me", "custom"],
    );
    assert.equal(catalog.defaultMode, "approve-for-me");
  });

  it("respects managed reviewer constraints in permission modes", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    provider.bridge = {
      request: async (method: string) => {
        if (method === "permissionProfile/list") {
          return {
            data: [
              { id: ":workspace", allowed: true },
              { id: ":danger-full-access", allowed: true },
            ],
            nextCursor: null,
          };
        }
        if (method === "configRequirements/read") {
          return { requirements: { allowedApprovalsReviewers: ["user"] } };
        }
        if (method === "experimentalFeature/list") {
          return {
            data: [{ name: "guardian_approval", enabled: true }],
            nextCursor: null,
          };
        }
        return { config: {} };
      },
    };

    const catalog = await provider.listPermissionProfiles({ cwd: null });

    assert.deepEqual(
      catalog.modes.map((mode: { id: string }) => mode.id),
      ["ask-for-approval", "full-access", "custom"],
    );
    assert.deepEqual(
      catalog.reviewerOptions.map((option: { id: string }) => option.id),
      ["user"],
    );
  });

  it("publishes opaque access modes without leaking native permission tuples", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    provider.bridge = {
      request: async (method: string) => {
        if (method === "permissionProfile/list") {
          return {
            data: [
              { id: ":workspace", allowed: true },
              { id: ":danger-full-access", allowed: true },
            ],
            nextCursor: null,
          };
        }
        if (method === "configRequirements/read") {
          return { requirements: null };
        }
        if (method === "experimentalFeature/list") {
          return {
            data: [{ name: "guardian_approval", enabled: true }],
            nextCursor: null,
          };
        }
        return {
          config: {
            default_permissions: ":workspace",
            approval_policy: "on-request",
            approvals_reviewer: "user",
          },
        };
      },
    };

    const catalog = await provider.listAccessModes({ cwd: "/tmp/project" });

    assert.equal(catalog.strategy, "modes");
    assert.equal(catalog.defaultMode, "ask-for-approval");
    assert.deepEqual(
      catalog.modes.map(
        (mode: {
          id: string;
          enabled: boolean;
          tone: string;
          confirmation: unknown;
        }) => ({
          id: mode.id,
          enabled: mode.enabled,
          tone: mode.tone,
          hasConfirmation: mode.confirmation !== null,
        }),
      ),
      [
        {
          id: "ask-for-approval",
          enabled: true,
          tone: "default",
          hasConfirmation: false,
        },
        {
          id: "approve-for-me",
          enabled: true,
          tone: "default",
          hasConfirmation: false,
        },
        {
          id: "full-access",
          enabled: true,
          tone: "danger",
          hasConfirmation: true,
        },
        {
          id: "custom",
          enabled: true,
          tone: "default",
          hasConfirmation: false,
        },
      ],
    );
    for (const mode of catalog.modes) {
      assert.equal("permissionProfile" in mode, false);
      assert.equal("approvalPolicy" in mode, false);
      assert.equal("approvalsReviewer" in mode, false);
    }
  });

  it("describes built-in permission profiles when Codex omits descriptions", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    provider.bridge = {
      request: async () => ({
        data: [
          { id: ":read-only", description: null, allowed: true },
          { id: ":danger-full-access", description: null, allowed: true },
        ],
        nextCursor: null,
      }),
    };

    const catalog = await provider.listPermissionProfiles({ cwd: null });

    assert.deepEqual(
      catalog.profiles.map(
        (profile: { description: string | null }) => profile.description,
      ),
      [
        "Inspect files and run safe read-only commands without making changes.",
        "Access files and commands across the machine without sandbox limits.",
      ],
    );
  });

  it("normalizes account rate-limit RPC data", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const requests: Array<{ method: string; params: unknown }> = [];
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        requests.push({ method, params });
        if (method === "account/read") {
          return {
            account: {
              type: "chatgpt",
              email: "mukhtar@example.com",
              planType: "pro",
            },
          };
        }
        if (method === "account/rateLimits/read") {
          return {
            rateLimits: {
              primary: {
                usedPercent: 28,
                windowDurationMins: 300,
                resetsAt: 1777991945,
              },
              secondary: {
                usedPercent: 97,
                windowDurationMins: 10080,
                resetsAt: 1778542395,
              },
              credits: {
                hasCredits: true,
                unlimited: false,
                balance: "12.44",
              },
            },
          };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };

    const observations = await provider.readUsageObservations();

    assert.equal(observations.length, 1);
    const observation = observations[0]!;
    assert.equal(observation.health, "ok");
    assert.equal(observation.provider.kind, "codex");
    assert.equal(observation.account?.displayLabel, "mu***@example.com");
    assert.equal(observation.account?.planType, "pro");
    assert.equal(observation.subject.kind, "account");
    assert.equal(observation.subject.stableKeyHash?.length, 32);
    assert.equal(observation.windows.length, 2);
    assert.deepEqual(observation.windows[0], {
      id: "primary",
      label: "Primary",
      usedPercent: 28,
      remainingPercent: 72,
      windowMinutes: 300,
      resetsAt: 1777991945000,
      resetDescription: observation.windows[0]!.resetDescription,
    });
    assert.equal(observation.windows[1]?.usedPercent, 97);
    assert.equal(observation.credits?.balance, 12.44);
    assert.equal(observation.credits?.balanceLabel, "12.44");
    assert.deepEqual(requests, [
      { method: "account/read", params: {} },
      { method: "account/rateLimits/read", params: {} },
    ]);
  });

  it("keeps rate-limit observations when account metadata is unavailable", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    provider.bridge = {
      request: async (method: string) => {
        if (method === "account/read") {
          throw new Error("account unavailable");
        }
        if (method === "account/rateLimits/read") {
          return {
            rateLimits: {
              primary: {
                usedPercent: 10,
                windowDurationMins: 300,
                resetsAt: 1777991945,
              },
            },
          };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };

    const observations = await provider.readUsageObservations();

    assert.equal(observations.length, 1);
    assert.equal(observations[0]?.health, "ok");
    assert.equal(observations[0]?.subject.kind, "unknown");
    assert.equal(observations[0]?.windows[0]?.usedPercent, 10);
  });
});

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

  it("lists recent rollout fallback sessions without app-server hydration", async () => {
    const tempDir = await mkdtemp(path.join(tmpdir(), "sidemesh-codex-provider-"));
    try {
      const rolloutDir = path.join(tempDir, "sessions", "2026", "05", "01");
      const rolloutPath = path.join(
        rolloutDir,
        "rollout-2026-05-01T01-00-00-thread-1.jsonl",
      );
      await mkdir(rolloutDir, { recursive: true });
      await writeFile(
        rolloutPath,
        [
          JSON.stringify({
            timestamp: "2026-05-01T01:00:00.000Z",
            type: "session_meta",
            payload: {
              id: "thread-1",
              cwd: "/tmp/project",
              timestamp: "2026-05-01T01:00:00.000Z",
              source: "cli",
            },
          }),
          JSON.stringify({
            timestamp: "2026-05-01T01:00:01.000Z",
            type: "event_msg",
            payload: { type: "user_message", message: "hello" },
          }),
          "",
        ].join("\n"),
      );

      const provider = new CodexAgentProvider("codex") as any;
      let bridgeReads = 0;
      provider.bridge = {
        codexHome: tempDir,
        request: async () => {
          bridgeReads += 1;
          throw new Error("thread/read should not be called for rollout fallback");
        },
      };

      const threads = await provider.listRecentUnindexedSessionThreads(10);

      assert.equal(bridgeReads, 0);
      assert.equal(threads.length, 1);
      assert.equal(threads[0]?.id, "thread-1");
      assert.equal(threads[0]?.cwd, "/tmp/project");
      assert.equal(threads[0]?.preview, "hello");
    } finally {
      await rm(tempDir, { recursive: true, force: true });
    }
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

  it("uses native permission profiles instead of legacy sandbox controls", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const thread = createThread();
    let resumeOptions: AgentSessionResumeOptions | undefined;
    const bridgeCalls: Array<{ method: string; params: unknown }> = [];

    provider.isSessionThreadLoaded = async () => false;
    provider.readSessionThread = async () => thread;
    provider.readSessionRuntime = async () => ({
      permissionProfile: ":workspace",
      approvalsReviewer: "user",
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
    });
    provider.resumeSessionThread = async (
      _threadId: string,
      options?: AgentSessionResumeOptions,
    ) => {
      resumeOptions = options;
      return {};
    };
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        bridgeCalls.push({ method, params });
        return { turn: { id: "turn-1" } };
      },
    };

    await provider.submitInput(
      createSubmitRequest({
        permissionProfile: ":full-access",
        approvalsReviewer: "auto_review",
        approvalPolicy: "never",
        sandboxMode: "danger-full-access",
      }),
    );

    assert.deepEqual(resumeOptions, {
      persistExtendedHistory: true,
      permissions: ":full-access",
      approvalPolicy: "never",
      approvalsReviewer: "auto_review",
    });
    assert.deepEqual(bridgeCalls, [
      {
        method: "turn/start",
        params: {
          threadId: "thread-1",
          input: [{ type: "text", text: "ping", text_elements: [] }],
          permissions: ":full-access",
          approvalPolicy: "never",
          approvalsReviewer: "auto_review",
        },
      },
    ]);
  });

  it("resolves an opaque access mode inside the provider adapter", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const bridgeCalls: Array<{ method: string; params: unknown }> = [];

    provider.readSessionThread = async () => createThread();
    provider.isSessionThreadLoaded = async () => true;
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        bridgeCalls.push({ method, params });
        if (method === "permissionProfile/list") {
          return {
            data: [
              { id: ":workspace", allowed: true },
              { id: ":danger-full-access", allowed: true },
            ],
            nextCursor: null,
          };
        }
        if (method === "configRequirements/read") {
          return { requirements: null };
        }
        if (method === "experimentalFeature/list") {
          return { data: [], nextCursor: null };
        }
        if (method === "config/read") {
          return { config: {} };
        }
        return { turn: { id: "turn-1" } };
      },
    };

    await provider.submitInput(
      createSubmitRequest({ accessMode: "full-access" }),
    );

    assert.deepEqual(bridgeCalls.at(-1), {
      method: "turn/start",
      params: {
        threadId: "thread-1",
        input: [{ type: "text", text: "ping", text_elements: [] }],
        permissions: ":danger-full-access",
        approvalPolicy: "never",
        approvalsReviewer: "user",
      },
    });
  });

  it("rejects access modes that are unavailable for the current workspace", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    let turnStarted = false;

    provider.readSessionThread = async () => createThread();
    provider.isSessionThreadLoaded = async () => true;
    provider.bridge = {
      request: async (method: string) => {
        if (method === "permissionProfile/list") {
          return {
            data: [
              { id: ":workspace", allowed: true },
              { id: ":danger-full-access", allowed: false },
            ],
            nextCursor: null,
          };
        }
        if (method === "configRequirements/read") {
          return { requirements: null };
        }
        if (method === "experimentalFeature/list") {
          return { data: [], nextCursor: null };
        }
        if (method === "config/read") {
          return { config: {} };
        }
        if (method === "turn/start") {
          turnStarted = true;
        }
        return { turn: { id: "turn-1" } };
      },
    };

    await assert.rejects(
      provider.submitInput(
        createSubmitRequest({ accessMode: "full-access" }),
      ),
      (error) => {
        assert.ok(error instanceof AgentProviderRequestError);
        assert.equal(error.status, 400);
        assert.match(error.message, /access mode is unavailable/);
        return true;
      },
    );
    assert.equal(turnStarted, false);
  });

  it("forwards advertised reasoning efforts and drops removed approval policies", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const bridgeCalls: Array<{ method: string; params: unknown }> = [];

    provider.isSessionThreadLoaded = async () => true;
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        bridgeCalls.push({ method, params });
        return { turn: { id: "turn-1" } };
      },
    };

    await provider.submitInput(
      createSubmitRequest({
        reasoningEffort: "max",
        approvalPolicy: "on-failure",
      }),
    );

    assert.deepEqual(bridgeCalls, [
      {
        method: "turn/start",
        params: {
          threadId: "thread-1",
          input: [{ type: "text", text: "ping", text_elements: [] }],
          effort: "max",
        },
      },
    ]);
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

describe("codex rich live event mappings", () => {
  it("normalizes raw Codex thread phases for list and read APIs", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    provider.bridge = {
      request: async (method: string) => {
        if (method === "thread/list") {
          return {
            data: [
              {
                ...createThread(),
                id: "thread-active",
                status: { type: "active", activeFlags: ["waitingOnApproval"] },
              },
              {
                ...createThread(),
                id: "thread-unloaded",
                status: { type: "notLoaded" },
              },
            ],
          };
        }
        if (method === "thread/read") {
          return {
            thread: {
              ...createThread(),
              id: "thread-read",
              status: { type: "systemError" },
            },
          };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };

    const listed = await provider.listSessionThreads({ limit: 10, archived: false });
    const read = await provider.readSessionThread("thread-read", false);

    assert.equal(listed[0]?.status.phase, "waiting_for_approval");
    assert.equal(listed[1]?.status.phase, "closed");
    assert.equal(read.status.phase, "errored");
  });

  it("requests spawned sub-agent threads and preserves their lineage metadata", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const requests: Array<{ method: string; params: unknown }> = [];
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        requests.push({ method, params });
        if (method === "thread/list") {
          return {
            data: [
              {
                ...createThread(),
                id: "thread-child",
                source: {
                  subAgent: {
                    thread_spawn: {
                      parent_thread_id: "thread-parent",
                      agent_role: "explorer",
                      agent_nickname: "scout",
                      depth: 2,
                    },
                  },
                },
                agentRole: "explorer",
                agentNickname: "scout",
              },
            ],
          };
        }
        throw new Error(`unexpected method ${method}`);
      },
    };

    const listed = await provider.listSessionThreads({
      limit: 10,
      archived: false,
      includeSubAgents: true,
      subAgentParentId: "thread-parent",
    });

    assert.deepEqual(requests, [
      {
        method: "thread/list",
        params: {
          limit: 200,
          sortKey: "updated_at",
          sortDirection: "desc",
          sourceKinds: [
            "cli",
            "vscode",
            "exec",
            "appServer",
            "subAgentThreadSpawn",
          ],
          archived: false,
        },
      },
    ]);
    assert.deepEqual(listed[0]?.subAgent, {
      parentSessionId: "thread-parent",
      sourceKind: "thread_spawn",
      agentRole: "explorer",
      agentNickname: "scout",
      depth: 2,
    });
  });

  it("paginates past child-only pages when listing top-level sessions", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const requests: unknown[] = [];
    provider.bridge = {
      request: async (method: string, params: unknown) => {
        assert.equal(method, "thread/list");
        requests.push(params);
        if (requests.length === 1) {
          return {
            data: [
              {
                ...createThread(),
                id: "thread-child",
                source: {
                  subAgent: {
                    thread_spawn: { parent_thread_id: "thread-parent" },
                  },
                },
              },
            ],
            nextCursor: "page-2",
          };
        }
        return {
          data: [{ ...createThread(), id: "thread-primary" }],
          nextCursor: null,
        };
      },
    };

    const listed = await provider.listSessionThreads({
      limit: 1,
      archived: false,
    });

    assert.deepEqual(listed.map((thread: ThreadRecord) => thread.id), [
      "thread-primary",
    ]);
    assert.equal((requests[1] as { cursor?: string }).cursor, "page-2");
  });

  it("normalizes Codex thread status, plan, reasoning, and warning notifications", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexNotification("thread/status/changed", {
      threadId: "thread-1",
      status: {
        type: "active",
        activeFlags: ["waitingOnApproval"],
      },
    });
    provider.emitCodexNotification("turn/plan/updated", {
      threadId: "thread-1",
      turnId: "turn-1",
      explanation: "Follow the rollout plan.",
      plan: [
        { step: "Read the docs", status: "completed" },
        { step: "Ship the change", status: "inProgress" },
      ],
    });
    provider.emitCodexNotification("item/reasoning/summaryTextDelta", {
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "reasoning-item-1",
      delta: "Summarizing the approach...",
      summaryIndex: 0,
    });
    provider.emitCodexNotification("item/reasoning/textDelta", {
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "reasoning-item-1",
      delta: "Inspecting the current state...",
      contentIndex: 0,
    });
    provider.emitCodexNotification("warning", {
      threadId: "thread-1",
      message: "Codex warning",
    });
    provider.emitCodexNotification("configWarning", {
      summary: "Config warning",
      details: "Unsupported key detected.",
      path: "/tmp/config.toml",
    });

    assert.deepEqual(events[0], {
      type: "thread_status_changed",
      sessionId: "thread-1",
      status: "waiting_for_approval",
      message: undefined,
      pendingActionKind: undefined,
    });
    assert.deepEqual(events[1], {
      type: "plan_updated",
      sessionId: "thread-1",
      turnId: "turn-1",
      explanation: "Follow the rollout plan.",
      plan: [
        { step: "Read the docs", status: "completed" },
        { step: "Ship the change", status: "in_progress" },
      ],
    });
    assert.deepEqual(events[2], {
      type: "reasoning_delta",
      sessionId: "thread-1",
      turnId: "turn-1",
      itemId: "reasoning-item-1",
      reasoningId: "reasoning-item-1",
      delta: "Summarizing the approach...",
      summary: true,
    });
    assert.deepEqual(events[3], {
      type: "reasoning_delta",
      sessionId: "thread-1",
      turnId: "turn-1",
      itemId: "reasoning-item-1",
      reasoningId: "reasoning-item-1",
      delta: "Inspecting the current state...",
      summary: false,
    });
    assert.deepEqual(events[4], {
      type: "provider_warning",
      sessionId: "thread-1",
      level: "warning",
      code: "warning",
      message: "Codex warning",
      source: "codex",
    });
    assert.deepEqual(events[5], {
      type: "provider_warning",
      level: "warning",
      code: "configWarning",
      message: "Config warning\n\nUnsupported key detected.\n\nPath: /tmp/config.toml",
      source: "codex/config",
    });
  });

  it("derives activity status from Codex item lifecycle notifications", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: any[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));
    const item = { id: "compact-1", type: "contextCompaction" };

    provider.emitCodexNotification("item/started", {
      threadId: "thread-1",
      turnId: "turn-1",
      startedAtMs: 1000,
      item,
    });
    provider.emitCodexNotification("item/completed", {
      threadId: "thread-1",
      turnId: "turn-1",
      completedAtMs: 2000,
      item,
    });
    provider.emitCodexNotification("item/completed", {
      threadId: "thread-1",
      turnId: "turn-1",
      completedAtMs: 3000,
      item: {
        id: "command-1",
        type: "commandExecution",
        status: "failed",
        command: "false",
        cwd: "/tmp/project",
      },
    });

    assert.equal(events.length, 3);
    assert.equal(events[0]?.type, "activity_updated");
    assert.equal(events[0]?.activity.status, "in_progress");
    assert.equal(events[1]?.type, "activity_updated");
    assert.equal(events[1]?.activity.status, "completed");
    assert.equal(events[2]?.type, "activity_updated");
    assert.equal(events[2]?.activity.status, "failed");
  });
});

describe("codex provider restart", () => {
  it("calls bridge.close() then bridge.start() on restart", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const calls: string[] = [];
    provider.bridge = {
      close: async () => { calls.push("close"); },
      start: async () => { calls.push("start"); },
    };

    await provider.restart();

    assert.deepEqual(calls, ["close", "start"]);
  });

  it("emits stderr when restarting", async () => {
    const provider = new CodexAgentProvider("codex") as any;
    const stderrLines: string[] = [];
    provider.on("stderr", (line: string) => stderrLines.push(line));

    provider.bridge = {
      close: async () => {},
      start: async () => {},
    };

    await provider.restart();

    assert.equal(stderrLines.length, 1);
    assert.ok(stderrLines[0].includes("Restarting app-server"));
  });
});

describe("codex interaction bridge", () => {
  it("rejects unsupported server requests instead of leaving them pending", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const errors: unknown[] = [];
    const stderrLines: string[] = [];
    const events: unknown[] = [];
    provider.bridge = {
      error: (id: number | string, code: number, message: string) => {
        errors.push({ id, code, message });
      },
    };
    provider.on("stderr", (line: string) => stderrLines.push(line));
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(42, "item/tool/call", {
      threadId: "thread-1",
    });

    assert.deepEqual(errors, [
      { id: 42, code: -32601, message: "Method not found" },
    ]);
    assert.equal(stderrLines.length, 1);
    assert.match(stderrLines[0]!, /item\/tool\/call/);
    assert.equal(events.length, 1);
    assert.equal((events[0] as any).type, "provider_warning");
    assert.equal((events[0] as any).code, "unsupported_request");
  });

  it("rejects supported server requests without a thread id", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const errors: unknown[] = [];
    provider.bridge = {
      error: (id: number | string, code: number, message: string) => {
        errors.push({ id, code, message });
      },
    };

    provider.emitCodexServerRequest(7, "item/tool/requestUserInput", {
      questions: [],
    });

    assert.deepEqual(errors, [
      { id: 7, code: -32600, message: "Invalid request params" },
    ]);
  });

  it("emits user_input pending action for tool requestUserInput", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(42, "item/tool/requestUserInput", {
      threadId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      questions: [
        {
          id: "q1",
          header: "Header text",
          question: "What is your name?",
          is_other: false,
          is_secret: false,
          options: ["Alice", "Bob"],
        },
      ],
    });

    assert.equal(events.length, 1);
    const event = events[0] as any;
    assert.equal(event.type, "action_opened");
    assert.equal(event.action.kind, "user_input");
    assert.equal(event.action.sessionId, "thread-1");
    assert.equal(event.action.userInput.question, "What is your name?");
    assert.deepEqual(event.action.userInput.choices, ["Alice", "Bob"]);
    assert.equal(event.action.userInput.allowFreeform, false);
    assert.equal(event.action.providerRequestId, 42);
    assert.equal(event.action.providerRequestKind, "item/tool/requestUserInput");
    assert.equal(event.action.providerPayload.questionId, "q1");
    assert.equal(event.action.providerPayload.itemId, "item-1");
    assert.equal(event.action.providerPayload.isSecret, undefined);
  });

  it("emits user_input with allowFreeform when is_other is true", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(1, "item/tool/requestUserInput", {
      threadId: "thread-1",
      questions: [
        {
          id: "q1",
          question: "Describe the issue",
          is_other: true,
          is_secret: false,
          options: [],
        },
      ],
    });

    const event = events[0] as any;
    assert.equal(event.action.userInput.allowFreeform, true);
    assert.deepEqual(event.action.userInput.choices, []);
  });

  it("warns and errors on malformed userInput params", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const errors: unknown[] = [];
    provider.bridge = {
      error: (_id: number | string, code: number, message: string) => {
        errors.push({ code, message });
      },
    };
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(1, "item/tool/requestUserInput", {
      threadId: "thread-1",
      questions: [],
    });

    assert.equal(events.length, 1);
    assert.equal((events[0] as any).type, "provider_warning");
    assert.equal(errors.length, 1);
    assert.equal((errors[0] as any).code, -32600);
  });

  it("emits elicitation pending action for MCP url mode", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(42, "mcpServer/elicitation/request", {
      threadId: "thread-1",
      server_name: "github",
      mode: "url",
      message: "Sign in to GitHub",
      url: "https://github.com/login",
      elicitation_id: "elic-1",
    });

    assert.equal(events.length, 1);
    const event = events[0] as any;
    assert.equal(event.type, "action_opened");
    assert.equal(event.action.kind, "elicitation");
    assert.equal(event.action.sessionId, "thread-1");
    assert.equal(event.action.elicitation.mode, "url");
    assert.equal(event.action.elicitation.message, "Sign in to GitHub");
    assert.equal(event.action.elicitation.url, "https://github.com/login");
    assert.equal(event.action.elicitation.source, "github");
    assert.equal(event.action.canDecline, true);
    assert.equal(event.action.providerRequestId, 42);
  });

  it("emits elicitation pending action for MCP form mode", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(42, "mcpServer/elicitation/request", {
      threadId: "thread-1",
      server_name: "postgres",
      mode: "form",
      message: "Enter connection details",
      requested_schema: {
        type: "object",
        required: ["host"],
        properties: {
          host: {
            type: "string",
            title: "Host",
            description: "Database host",
          },
          port: {
            type: "integer",
            title: "Port",
            default: 5432,
          },
          ssl: {
            type: "boolean",
            title: "Use SSL",
            default: true,
          },
          tags: {
            type: "array",
            items: {
              enum: ["prod", "dev"],
            },
            title: "Tags",
          },
        },
      },
    });

    assert.equal(events.length, 1);
    const event = events[0] as any;
    assert.equal(event.action.kind, "elicitation");
    assert.equal(event.action.elicitation.mode, "form");
    assert.equal(event.action.elicitation.fields.length, 4);

    const hostField = event.action.elicitation.fields.find(
      (f: any) => f.key === "host",
    );
    assert.equal(hostField.type, "string");
    assert.equal(hostField.required, true);
    assert.equal(hostField.title, "Host");

    const portField = event.action.elicitation.fields.find(
      (f: any) => f.key === "port",
    );
    assert.equal(portField.type, "number");
    assert.equal(portField.integer, true);
    assert.equal(portField.defaultValue, 5432);

    const sslField = event.action.elicitation.fields.find(
      (f: any) => f.key === "ssl",
    );
    assert.equal(sslField.type, "boolean");
    assert.equal(sslField.defaultValue, true);

    const tagsField = event.action.elicitation.fields.find(
      (f: any) => f.key === "tags",
    );
    assert.equal(tagsField.type, "string[]");
    assert.deepEqual(tagsField.options, [
      { value: "prod", label: "prod" },
      { value: "dev", label: "dev" },
    ]);
  });

  it("warns and errors on malformed elicitation params", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const errors: unknown[] = [];
    provider.bridge = {
      error: (_id: number | string, code: number, message: string) => {
        errors.push({ code, message });
      },
    };
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(1, "mcpServer/elicitation/request", {
      threadId: "thread-1",
      mode: "url",
      // missing url
    });

    assert.equal(events.length, 1);
    assert.equal((events[0] as any).type, "provider_warning");
    assert.equal(errors.length, 1);
    assert.equal((errors[0] as any).code, -32600);
  });

  it("serializes user_input response with answers map", () => {
    const provider = new CodexAgentProvider("codex") as any;
    let responded: unknown = null;
    provider.bridge = {
      respond: (_id: number | string, result: unknown) => {
        responded = result;
      },
    };

    const action: any = {
      providerRequestId: 42,
      providerRequestKind: "item/tool/requestUserInput",
      providerPayload: { questionId: "q1" },
    };

    const handled = provider.respondToPendingAction(action, {
      answer: "Alice",
      wasFreeform: false,
    });

    assert.equal(handled, true);
    assert.deepEqual(responded, {
      answers: {
        q1: { answers: ["Alice"] },
      },
    });
  });

  it("serializes elicitation accept response", () => {
    const provider = new CodexAgentProvider("codex") as any;
    let responded: unknown = null;
    provider.bridge = {
      respond: (_id: number | string, result: unknown) => {
        responded = result;
      },
    };

    const action: any = {
      providerRequestId: 42,
      providerRequestKind: "mcpServer/elicitation/request",
    };

    const handled = provider.respondToPendingAction(action, {
      action: "accept",
      content: { host: "localhost" },
    });

    assert.equal(handled, true);
    assert.deepEqual(responded, {
      action: "accept",
      content: { host: "localhost" },
    });
  });

  it("serializes elicitation decline without content", () => {
    const provider = new CodexAgentProvider("codex") as any;
    let responded: unknown = null;
    provider.bridge = {
      respond: (_id: number | string, result: unknown) => {
        responded = result;
      },
    };

    const action: any = {
      providerRequestId: 42,
      providerRequestKind: "mcpServer/elicitation/request",
    };

    const handled = provider.respondToPendingAction(action, {
      action: "decline",
    });

    assert.equal(handled, true);
    assert.deepEqual(responded, {
      action: "decline",
    });
  });

  it("serializes elicitation cancel without content", () => {
    const provider = new CodexAgentProvider("codex") as any;
    let responded: unknown = null;
    provider.bridge = {
      respond: (_id: number | string, result: unknown) => {
        responded = result;
      },
    };

    const action: any = {
      providerRequestId: 42,
      providerRequestKind: "mcpServer/elicitation/request",
    };

    const handled = provider.respondToPendingAction(action, {
      action: "cancel",
    });

    assert.equal(handled, true);
    assert.deepEqual(responded, {
      action: "cancel",
    });
  });



  it("warns when Codex sends multiple questions but uses only the first", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(1, "item/tool/requestUserInput", {
      threadId: "thread-1",
      questions: [
        { id: "q1", question: "First?", is_other: false, is_secret: false, options: [] },
        { id: "q2", question: "Second?", is_other: false, is_secret: false, options: [] },
      ],
    });

    assert.equal(events.length, 2);
    assert.equal((events[0] as any).type, "provider_warning");
    assert.equal((events[0] as any).code, "multi_question_truncated");
    assert.equal((events[1] as any).type, "action_opened");
    assert.equal((events[1] as any).action.userInput.question, "First?");
  });
  it("rejects secret user input requests", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const errors: unknown[] = [];
    provider.bridge = {
      error: (_id: number | string, code: number, message: string) => {
        errors.push({ code, message });
      },
    };
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(1, "item/tool/requestUserInput", {
      threadId: "thread-1",
      questions: [
        {
          id: "q1",
          question: "What is your password?",
          is_other: false,
          is_secret: true,
          options: [],
        },
      ],
    });

    assert.equal(events.length, 1);
    assert.equal((events[0] as any).type, "provider_warning");
    assert.equal(errors.length, 1);
    assert.equal((errors[0] as any).code, -32600);
  });

  it("serializes user_input response with default questionId when missing", () => {
    const provider = new CodexAgentProvider("codex") as any;
    let responded: unknown = null;
    provider.bridge = {
      respond: (_id: number | string, result: unknown) => {
        responded = result;
      },
    };

    const action: any = {
      providerRequestId: 42,
      providerRequestKind: "item/tool/requestUserInput",
      providerPayload: {},
    };

    const handled = provider.respondToPendingAction(action, {
      answer: "Freeform answer",
      wasFreeform: true,
    });

    assert.equal(handled, true);
    assert.deepEqual(responded, {
      answers: {
        default: { answers: ["Freeform answer"] },
      },
    });
  });

  it("declines elicitation form with unknown required field type", () => {
    const provider = new CodexAgentProvider("codex") as any;
    const errors: unknown[] = [];
    provider.bridge = {
      error: (_id: number | string, code: number, message: string) => {
        errors.push({ code, message });
      },
    };
    const events: unknown[] = [];
    provider.on("liveEvent", (event: unknown) => events.push(event));

    provider.emitCodexServerRequest(1, "mcpServer/elicitation/request", {
      threadId: "thread-1",
      server_name: "bad",
      mode: "form",
      message: "Bad schema",
      requested_schema: {
        type: "object",
        required: ["nested"],
        properties: {
          nested: {
            type: "object",
            title: "Nested object",
          },
        },
      },
    });

    assert.equal(events.length, 1);
    assert.equal((events[0] as any).type, "provider_warning");
    assert.equal(errors.length, 1);
    assert.equal((errors[0] as any).code, -32600);
  });

  it("returns false for unsupported decisions on new action kinds", () => {
    const provider = new CodexAgentProvider("codex") as any;

    const action: any = {
      providerRequestId: 42,
      providerRequestKind: "item/tool/requestUserInput",
    };

    const handled = provider.respondToPendingAction(action, {
      decision: "approve",
    } as any);

    assert.equal(handled, false);
  });
});
