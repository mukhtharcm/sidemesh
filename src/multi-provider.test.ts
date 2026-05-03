import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { describe, it } from "node:test";

import type {
  AgentCreateSessionRequest,
  AgentCreateSessionResult,
  AgentPendingAction,
  AgentProvider,
  AgentProviderCapabilities,
  AgentProviderEvents,
  AgentProviderLiveEvent,
  AgentSessionListOptions,
  AgentSubmitInputRequest,
  AgentSubmitInputResult,
} from "./agent-provider.js";
import { MultiAgentProvider } from "./multi-provider.js";
import type { SessionLogSnapshot } from "./types.js";

describe("MultiAgentProvider", () => {
  it("wraps session ids and routes reads and writes back to the owning provider", async () => {
    const codex = new StubProvider("codex", "Codex");
    const copilot = new StubProvider("copilot", "GitHub Copilot");
    codex.seedThread("codex-thread", "/repo/codex");
    copilot.seedThread("copilot-thread", "/repo/copilot");

    const provider = new MultiAgentProvider(
      [
        {
          kind: "codex",
          config: { kind: "codex", bin: "codex" },
          provider: codex,
        },
        {
          kind: "copilot",
          config: {
            kind: "copilot",
            bin: "copilot",
            stateDir: null,
            allowAll: false,
            configuredModel: null,
          },
          provider: copilot,
        },
      ],
      "codex",
    );

    const threads = await provider.listSessionThreads({
      limit: 10,
      archived: false,
    });
    assert.deepEqual(
      threads.map((thread) => thread.source),
      ["copilot", "codex"],
    );
    const codexThread = threads.find((thread) => thread.source === "codex");
    const copilotThread = threads.find((thread) => thread.source === "copilot");
    assert.ok(codexThread);
    assert.ok(copilotThread);
    assert.match(codexThread.id, /^codex:/);
    assert.match(copilotThread.id, /^copilot:/);

    await provider.submitInput({
      sessionId: copilotThread.id,
      activeTurnId: null,
      input: [{ type: "text", text: "hello", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.equal(copilot.lastSubmit?.sessionId, "copilot-thread");
    assert.equal(codex.lastSubmit, null);

    const created = await provider.createSession({
      cwd: "/repo/new",
      input: [{ type: "text", text: "ship it", text_elements: [] }],
      overrides: emptyOverrides(),
      provider: "copilot",
    });
    assert.match(created.thread.id, /^copilot:/);
    assert.equal(copilot.createdSessions.at(-1)?.provider, null);
    assert.equal(copilot.createdSessions.at(-1)?.cwd, "/repo/new");
  });

  it("wraps live approval events so the server can route them safely", async () => {
    const codex = new StubProvider("codex", "Codex");
    const provider = new MultiAgentProvider(
      [
        {
          kind: "codex",
          config: { kind: "codex", bin: "codex" },
          provider: codex,
        },
      ],
      "codex",
    );

    const opened = new Promise<AgentPendingAction>((resolve) => {
      provider.on("liveEvent", (event) => {
        if (event.type === "action_opened") {
          resolve(event.action);
        }
      });
    });

    codex.emit("liveEvent", {
      type: "action_opened",
      action: {
        id: "approve-1",
        sessionId: "thread-1",
        kind: "command",
        title: "Command approval",
        detail: "npm test",
        requestedAt: Date.now(),
        canApprove: true,
        canApproveForSession: true,
        canDecline: true,
        providerRequestId: "approve-1",
        providerRequestKind: "command",
      },
    });

    const action = await opened;
    assert.match(action.id, /^codex:/);
    assert.match(action.sessionId, /^codex:/);
  });

  it("wraps rich session live events from child providers", async () => {
    const codex = new StubProvider("codex", "Codex");
    const provider = new MultiAgentProvider(
      [
        {
          kind: "codex",
          config: { kind: "codex", bin: "codex" },
          provider: codex,
        },
      ],
      "codex",
    );

    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => {
      if (
        event.type === "provider_warning" ||
        event.type === "thread_status_changed" ||
        event.type === "plan_updated" ||
        event.type === "reasoning_delta" ||
        event.type === "queue_updated" ||
        event.type === "auto_retry_updated"
      ) {
        events.push(event);
      }
    });

    codex.emit("liveEvent", {
      type: "provider_warning",
      sessionId: "thread-1",
      level: "warning",
      code: "warning-1",
      message: "Heads up",
      source: "codex",
    });
    codex.emit("liveEvent", {
      type: "thread_status_changed",
      sessionId: "thread-1",
      status: "waiting_for_approval",
      pendingActionKind: "command",
    });
    codex.emit("liveEvent", {
      type: "plan_updated",
      sessionId: "thread-1",
      turnId: "turn-1",
      explanation: "Do the work",
      plan: [
        { step: "Read the docs", status: "completed" },
        { step: "Ship the change", status: "in_progress" },
      ],
    });
    codex.emit("liveEvent", {
      type: "reasoning_delta",
      sessionId: "thread-1",
      turnId: "turn-1",
      itemId: "item-1",
      reasoningId: "reason-1",
      delta: "Thinking...",
      summary: true,
    });
    codex.emit("liveEvent", {
      type: "queue_updated",
      sessionId: "thread-1",
      steeringCount: 1,
      followUpCount: 2,
      steeringPreview: ["Keep it neutral"],
      followUpPreview: ["Add tests", "Run typecheck"],
    });
    codex.emit("liveEvent", {
      type: "auto_retry_updated",
      sessionId: "thread-1",
      phase: "started",
      attempt: 2,
      maxAttempts: 3,
      delayMs: 2000,
      errorMessage: "Overloaded",
    });

    assert.equal(events.length, 6);
    for (const event of events) {
      if ("sessionId" in event && typeof event.sessionId === "string") {
        assert.match(event.sessionId, /^codex:/);
      }
    }
    const warning = events.find((event) => event.type === "provider_warning");
    if (warning?.type !== "provider_warning") {
      throw new Error("Expected provider_warning event");
    }
    assert.equal(warning.code, "warning-1");
    const plan = events.find((event) => event.type === "plan_updated");
    if (plan?.type !== "plan_updated") {
      throw new Error("Expected plan_updated event");
    }
    assert.equal(plan.plan[1]?.step, "Ship the change");
  });

  it("advertises default provider capabilities instead of provider union", async () => {
    const codex = new StubProvider("codex", "Codex");
    codex.capabilities.configuration.profiles = false;
    const copilot = new StubProvider("copilot", "GitHub Copilot");
    copilot.capabilities.configuration.profiles = true;

    const provider = new MultiAgentProvider(
      [
        {
          kind: "codex",
          config: { kind: "codex", bin: "codex" },
          provider: codex,
        },
        {
          kind: "copilot",
          config: {
            kind: "copilot",
            bin: "copilot",
            stateDir: null,
            allowAll: false,
            configuredModel: null,
          },
          provider: copilot,
        },
      ],
      "codex",
    );

    assert.equal(provider.capabilities.configuration.profiles, false);
    assert.equal(
      provider.getProviderEntries().find((entry) => entry.kind === "copilot")
        ?.provider.capabilities.configuration.profiles,
      true,
    );
  });
});

class StubProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  public readonly capabilities: AgentProviderCapabilities = {
    sessions: {
      create: true,
      resume: true,
      rename: true,
      archive: true,
      compact: true,
      interrupt: true,
      history: true,
      eventReplay: true,
      recentFallback: true,
    searchSessions: true,
    },
    input: {
      fileMentions: true,
      text: true,
      imageUrl: false,
      localImage: false,
      skills: false,
    },
    interaction: {
      userInput: false,
      elicitation: false,
    },
    approvals: {
      command: true,
      tool: false,
      fileChange: false,
      permissions: false,
      approveForSession: true,
    },
    configuration: {
      models: true,
      profiles: false,
      skills: false,
      skillManagement: false,
    },
    runtimeControls: {
      model: true,
      mode: false,
      reasoningEffort: true,
      fastMode: false,
      approvalPolicy: true,
      sandboxMode: true,
      networkAccess: true,
      webSearch: false,
    },
    workspace: {
      remoteGitDiff: false,
    },
    lifecycle: {
      restart: true,
    },
  };

  public readonly createdSessions: AgentCreateSessionRequest[] = [];
  public lastSubmit: AgentSubmitInputRequest | null = null;
  private readonly threads = new Map<string, ReturnType<typeof stubThread>>();

  public constructor(
    public readonly kind: string,
    public readonly displayName: string,
  ) {
    super();
  }

  public seedThread(id: string, cwd: string): void {
    this.threads.set(id, stubThread(id, cwd, this.kind));
  }

  public async start(): Promise<void> {}

  public async getVersion(): Promise<string> {
    return `${this.displayName} 1.0.0`;
  }

  public async listSessionThreads(
    _options: AgentSessionListOptions,
  ): Promise<ReturnType<typeof stubThread>[]> {
    return [...this.threads.values()];
  }

  public async readSessionThread(
    id: string,
    _includeTurns: boolean,
  ): Promise<ReturnType<typeof stubThread>> {
    const thread = this.threads.get(id);
    if (!thread) {
      throw new Error(`Unknown thread ${id}`);
    }
    return thread;
  }

  public async listRecentUnindexedSessionThreads(
    _limit: number,
  ): Promise<ReturnType<typeof stubThread>[]> {
    return [...this.threads.values()];
  }

  public async readSessionLog(): Promise<SessionLogSnapshot> {
    return {
      messages: [],
      activities: [],
      runtime: null,
      totalMessages: 0,
      totalActivities: 0,
      nextSeq: 0,
    };
  }

  public async readSessionRuntime() {
    return null;
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    return [...this.threads.keys()];
  }

  public async resumeSessionThread(): Promise<unknown> {
    return { resumed: true };
  }

  public async setSessionName(): Promise<unknown> {
    return { renamed: true };
  }

  public async archiveSession(): Promise<unknown> {
    return { archived: true };
  }

  public async unarchiveSession(): Promise<unknown> {
    return { unarchived: true };
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    this.createdSessions.push(request);
    const id = `${this.kind}-created-${this.createdSessions.length}`;
    const thread = stubThread(id, request.cwd, this.kind);
    this.threads.set(id, thread);
    return {
      thread,
      activeTurnId: null,
      runtime: null,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    this.lastSubmit = request;
    return { mode: "turn", turnId: "turn-1" };
  }

  public async interruptTurn(): Promise<unknown> {
    return { interrupted: true };
  }

  public respondToPendingAction(): boolean {
    return true;
  }

  public restartCalls = 0;
  public async restart(): Promise<void> {
    this.restartCalls++;
  }
}

function stubThread(id: string, cwd: string, source: string) {
  return {
    id,
    name: id,
    preview: id,
    createdAt: 10,
    updatedAt: source == "codex" ? 10 : 20,
    cwd,
    source,
    path: null,
    status: { type: "idle" },
    gitInfo: null,
  };
}

function emptyOverrides() {
  return {
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
}

describe("MultiAgentProvider restart", () => {
  it("routes restartProvider to the correct child", async () => {
    const codex = new StubProvider("codex", "Codex");
    const copilot = new StubProvider("copilot", "GitHub Copilot");

    const provider = new MultiAgentProvider(
      [
        { kind: "codex", config: { kind: "codex", bin: "codex" }, provider: codex },
        { kind: "copilot", config: { kind: "copilot", bin: "copilot", stateDir: null, allowAll: false, configuredModel: null }, provider: copilot },
      ],
      "codex",
    );

    await provider.restartProvider("codex");
    assert.equal(codex.restartCalls, 1);
    assert.equal(copilot.restartCalls, 0);
  });

  it("throws for unknown provider kind", async () => {
    const codex = new StubProvider("codex", "Codex");
    const provider = new MultiAgentProvider(
      [
        { kind: "codex", config: { kind: "codex", bin: "codex" }, provider: codex },
      ],
      "codex",
    );

    await assert.rejects(
      () => provider.restartProvider("copilot" as any),
      /Unknown provider "copilot"/,
    );
  });

  it("throws for provider without restart support", async () => {
    const codex = new StubProvider("codex", "Codex");
    codex.capabilities.lifecycle.restart = false;
    (codex as any).restart = undefined;

    const provider = new MultiAgentProvider(
      [
        { kind: "codex", config: { kind: "codex", bin: "codex" }, provider: codex },
      ],
      "codex",
    );

    await assert.rejects(
      () => provider.restartProvider("codex"),
      /does not support restart/,
    );
  });
});
