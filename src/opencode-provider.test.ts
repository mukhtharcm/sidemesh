import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { describe, it } from "node:test";

import type { AgentProviderLiveEvent } from "./agent-provider.js";
import { OpenCodeAgentProvider } from "./opencode-provider.js";

describe("OpenCode provider", () => {
  it("creates a session, completes a prompt, and maps history/runtime", async () => {
    const client = new FakeOpenCodeClient();
    const provider = createProvider(client);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));

    await provider.start();
    const created = await provider.createSession({
      cwd: "/repo/app",
      input: [{ type: "text", text: "Ship the fix", text_elements: [] }],
      overrides: {
        model: "opencode/big-pickle",
        mode: "build",
        reasoningEffort: null,
        fastMode: null,
        approvalPolicy: null,
        sandboxMode: null,
        networkAccess: null,
        webSearch: null,
        profile: null,
      },
    });

    assert.ok(created.activeTurnId);
    await waitForEvent(events, (event) => event.type === "turn_completed");

    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.length, 2);
    assert.equal(log.messages[0]?.role, "user");
    assert.equal(log.messages[1]?.role, "assistant");
    assert.equal(log.messages[1]?.text, "done");
    assert.equal(log.runtime?.model, "opencode/big-pickle");
    assert.equal(log.runtime?.modelProvider, "opencode");
    assert.equal(log.runtime?.mode, "build");

    const completed = events.find(
      (event) => event.type === "assistant_message_completed",
    );
    assert.ok(completed);
    assert.equal(
      completed.type === "assistant_message_completed"
        ? completed.message.text
        : null,
      "done",
    );
  });

  it("maps permissions and multi-question replies through pending actions", async () => {
    const client = new FakeOpenCodeClient();
    const provider = createProvider(client);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));

    client.onPrompt = ({ directory, sessionID, userMessageID }) => {
      client.permissionsByDirectory.set(directory, [
        {
          id: "perm-1",
          sessionID,
          permission: "read",
          patterns: ["src/opencode-provider.ts"],
          metadata: { reason: "Need to inspect provider implementation" },
        },
      ]);
      client.statusesByDirectory.set(directory, {
        [sessionID]: { type: "busy" },
      });
      client.onPermissionReply = ({ directory: nextDirectory, sessionID: nextSessionID }) => {
        client.permissionsByDirectory.set(nextDirectory, []);
        client.questionsByDirectory.set(nextDirectory, [
          {
            id: "question-1",
            sessionID: nextSessionID,
            questions: [
              {
                header: "Color",
                question: "Pick a color",
                options: [
                  { label: "red", description: "Warm" },
                  { label: "blue", description: "Cool" },
                ],
              },
              {
                header: "Regions",
                question: "Pick two regions",
                multiple: true,
                options: [
                  { label: "north", description: "North" },
                  { label: "south", description: "South" },
                  { label: "west", description: "West" },
                ],
              },
            ],
          },
        ]);
      };
      client.onQuestionReply = ({
        directory: nextDirectory,
        sessionID: nextSessionID,
      }) => {
        client.questionsByDirectory.set(nextDirectory, []);
        client.finishPrompt({
          directory: nextDirectory,
          sessionID: nextSessionID,
          userMessageID,
          text: "workflow finished",
        });
      };
    };

    await provider.start();
    const created = await provider.createSession({
      cwd: "/repo/app",
      input: [{ type: "text", text: "Handle approvals", text_elements: [] }],
      overrides: {
        model: null,
        mode: "build",
        reasoningEffort: null,
        fastMode: null,
        approvalPolicy: null,
        sandboxMode: null,
        networkAccess: null,
        webSearch: null,
        profile: null,
      },
    });

    const permissionAction = await waitForOpenedAction(
      events,
      (action) => action.kind === "permissions",
    );
    assert.equal(
      provider.respondToPendingAction(permissionAction, {
        decision: "approve",
        scope: "location",
      }),
      true,
    );

    const questionAction = await waitForOpenedAction(
      events,
      (action) => action.kind === "elicitation",
    );
    assert.equal(
      provider.respondToPendingAction(questionAction, {
        action: "accept",
        content: {
          "0": "red",
          "1": ["north", "south"],
        },
      }),
      true,
    );

    await waitForEvent(events, (event) => event.type === "turn_completed");

    assert.deepEqual(client.permissionReplies, [
      { directory: "/repo/app", requestID: "perm-1", reply: "always" },
    ]);
    assert.deepEqual(client.questionReplies, [
      {
        directory: "/repo/app",
        requestID: "question-1",
        answers: [["red"], ["north", "south"]],
      },
    ]);

    const completed = events.find(
      (event) =>
        event.type === "assistant_message_completed" &&
        event.sessionId === created.thread.id,
    );
    assert.ok(completed);
  });

  it("keeps a pending action after an invalid response so it can be retried", async () => {
    const client = new FakeOpenCodeClient();
    const provider = createProvider(client);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));

    client.onPrompt = ({ directory, sessionID, userMessageID }) => {
      client.permissionsByDirectory.set(directory, [
        {
          id: "perm-retry",
          sessionID,
          permission: "read",
          patterns: ["src/provider-registry.ts"],
          metadata: {},
        },
      ]);
      client.statusesByDirectory.set(directory, {
        [sessionID]: { type: "busy" },
      });
      client.onPermissionReply = ({ directory: nextDirectory, sessionID: nextSessionID }) => {
        client.permissionsByDirectory.set(nextDirectory, []);
        client.finishPrompt({
          directory: nextDirectory,
          sessionID: nextSessionID,
          userMessageID,
          text: "retried successfully",
        });
      };
    };

    await provider.start();
    await provider.createSession({
      cwd: "/repo/app",
      input: [{ type: "text", text: "Retry this action", text_elements: [] }],
      overrides: {
        model: null,
        mode: "build",
        reasoningEffort: null,
        fastMode: null,
        approvalPolicy: null,
        sandboxMode: null,
        networkAccess: null,
        webSearch: null,
        profile: null,
      },
    });

    const permissionAction = await waitForOpenedAction(
      events,
      (action) => action.kind === "permissions",
    );
    assert.equal(
      provider.respondToPendingAction(permissionAction, {
        action: "accept",
      }),
      false,
    );
    assert.equal(
      provider.respondToPendingAction(permissionAction, {
        decision: "approve",
        scope: "location",
      }),
      true,
    );

    await waitForEvent(events, (event) => event.type === "turn_completed");
    assert.deepEqual(client.permissionReplies, [
      { directory: "/repo/app", requestID: "perm-retry", reply: "always" },
    ]);
  });

  it("lists models and skills from OpenCode metadata", async () => {
    const client = new FakeOpenCodeClient();
    client.providerList = {
      all: [
        {
          id: "opencode",
          name: "OpenCode",
          models: {
            "big-pickle": {
              id: "big-pickle",
              name: "Big Pickle",
              providerID: "opencode",
              capabilities: { reasoning: true, input: { text: true, image: true } },
            },
          },
        },
        {
          id: "openai",
          name: "OpenAI",
          models: {
            "gpt-4.1": {
              id: "gpt-4.1",
              name: "GPT-4.1",
              providerID: "openai",
              capabilities: { reasoning: false, input: { text: true } },
            },
          },
        },
      ],
      default: {
        opencode: "big-pickle",
        openai: "gpt-4.1",
      },
      connected: ["opencode", "openai"],
    } as any;
    client.skills = [
      {
        name: "release-checks",
        description: "Run the release checklist",
        location: "/repo/app/.agents/skills/release-checks/SKILL.md",
      },
    ];

    const provider = createProvider(client);
    await provider.start();

    const models = await provider.listModels({ cwd: "/repo/app", profile: null, provider: null });
    assert.equal(models.length, 2);
    assert.deepEqual(
      models.map((model) => model.id),
      ["openai/gpt-4.1", "opencode/big-pickle"],
    );
    assert.deepEqual(
      models.filter((model) => model.isDefault).map((model) => model.id),
      ["openai/gpt-4.1", "opencode/big-pickle"],
    );
    assert.ok(
      models.find((model) => model.id === "opencode/big-pickle")
        ?.supportedReasoningEfforts.length,
    );

    const skills = await provider.listSkills({
      cwd: "/repo/app",
      forceReload: false,
    });
    assert.equal(skills.skills[0]?.name, "release-checks");
    assert.equal(skills.skills[0]?.scope, "repo");
  });

  it("starts lazily when resuming a known session", async () => {
    const client = new FakeOpenCodeClient();
    const session = await client.createSession({
      directory: "/repo/app",
      title: "Resume me",
      agent: "build",
      model: { providerID: "opencode", modelID: "big-pickle" },
    });
    const provider = createProvider(client);

    const resumed = await provider.resumeSessionThread(session.id);
    assert.deepEqual(resumed, { resumed: true });
    assert.deepEqual(await provider.listLoadedSessionIds(), [session.id]);
  });

  it("keeps activity timestamps stable for parts without explicit timing", async () => {
    const client = new FakeOpenCodeClient();
    const session = await client.createSession({
      directory: "/repo/app",
      title: "Stable activities",
      agent: "build",
      model: { providerID: "opencode", modelID: "big-pickle" },
    });
    client.messages.set(session.id, [
      {
        info: {
          id: "msg-user",
          sessionID: session.id,
          role: "user",
          time: { created: 100 },
          agent: "build",
          model: { providerID: "opencode", modelID: "big-pickle" },
        },
        parts: [{ id: "user-text", type: "text", text: "hello" }],
      },
      {
        info: {
          id: "msg-assistant",
          sessionID: session.id,
          role: "assistant",
          parentID: "msg-user",
          providerID: "opencode",
          modelID: "big-pickle",
          agent: "build",
          mode: "build",
          time: { created: 200, completed: 210 },
          cost: 0,
          finish: "stop",
          tokens: {
            total: 0,
            input: 0,
            output: 0,
            reasoning: 0,
            cache: { read: 0, write: 0 },
          },
        },
        parts: [
          {
            id: "tool-no-time",
            type: "tool",
            tool: "read",
            callID: "call-1",
            state: {
              status: "pending",
              input: { path: "src/opencode-provider.ts" },
            },
          },
          {
            id: "compact-no-time",
            type: "compaction",
          },
        ],
      },
    ]);

    const provider = createProvider(client);
    await provider.start();
    const thread = await provider.readSessionThread(session.id, false);

    const first = await provider.readSessionLog(thread);
    await delay(20);
    const second = await provider.readSessionLog(thread);

    assert.deepEqual(
      second.activities.map((activity) => ({
        id: activity.id,
        createdAt: activity.createdAt,
        seq: activity.seq,
      })),
      first.activities.map((activity) => ({
        id: activity.id,
        createdAt: activity.createdAt,
        seq: activity.seq,
      })),
    );
  });
});

function createProvider(client: FakeOpenCodeClient) {
  return new OpenCodeAgentProvider({
    defaultDirectory: "/repo/app",
    pollIntervalMs: 5,
    serverFactory: async ({ onExit: _onExit, onOutput: _onOutput }) => ({
      baseUrl: new URL("http://127.0.0.1:1"),
      close: async () => {},
    }),
    clientFactory: () => client as any,
  });
}

async function waitForEvent(
  events: AgentProviderLiveEvent[],
  predicate: (event: AgentProviderLiveEvent) => boolean,
  timeoutMs = 2_000,
): Promise<AgentProviderLiveEvent> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const match = events.find(predicate);
    if (match) {
      return match;
    }
    await delay(10);
  }
  throw new Error("Timed out waiting for live event.");
}

async function waitForOpenedAction(
  events: AgentProviderLiveEvent[],
  predicate: (action: Extract<AgentProviderLiveEvent, { type: "action_opened" }>["action"]) => boolean,
): Promise<Extract<AgentProviderLiveEvent, { type: "action_opened" }>["action"]> {
  const event = await waitForEvent(
    events,
    (candidate) => candidate.type === "action_opened" && predicate(candidate.action),
  );
  if (event.type !== "action_opened") {
    throw new Error("Expected action_opened event.");
  }
  return event.action;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

class FakeOpenCodeClient {
  public providerList = {
    all: [
      {
        id: "opencode",
        name: "OpenCode",
        models: {
          "big-pickle": {
            id: "big-pickle",
            name: "Big Pickle",
            providerID: "opencode",
            capabilities: { reasoning: true, input: { text: true } },
          },
        },
      },
    ],
    default: { opencode: "big-pickle" },
    connected: ["opencode"],
  };

  public skills: Array<{
    name: string;
    description: string;
    location: string;
  }> = [];

  public readonly permissionReplies: Array<{
    directory: string;
    requestID: string;
    reply: string;
  }> = [];

  public readonly questionReplies: Array<{
    directory: string;
    requestID: string;
    answers: string[][];
  }> = [];

  public readonly sessions = new Map<string, any>();
  public readonly messages = new Map<string, any[]>();
  public readonly statusesByDirectory = new Map<string, Record<string, any>>();
  public readonly permissionsByDirectory = new Map<string, any[]>();
  public readonly questionsByDirectory = new Map<string, any[]>();

  public onPrompt:
    | ((input: {
        directory: string;
        sessionID: string;
        userMessageID: string;
        prompt: any;
      }) => void)
    | null = null;
  public onPermissionReply:
    | ((input: {
        directory: string;
        sessionID: string;
        requestID: string;
        reply: string;
      }) => void)
    | null = null;
  public onQuestionReply:
    | ((input: {
        directory: string;
        sessionID: string;
        requestID: string;
        answers: string[][];
      }) => void)
    | null = null;

  public async getHealth(_directory: string) {
    return { healthy: true as const, version: "1.2.3" };
  }

  public async listGlobalSessions(options: {
    archived: boolean;
    limit: number;
  }) {
    const sessions = [...this.sessions.values()]
      .filter((session) => options.archived === Boolean(session.time.archived))
      .sort((left, right) => right.time.updated - left.time.updated)
      .slice(0, options.limit);
    return { sessions, nextCursor: null };
  }

  public async getSession(options: { sessionID: string }) {
    const session = this.sessions.get(options.sessionID);
    if (!session) {
      throw new Error(`Missing session ${options.sessionID}`);
    }
    return session;
  }

  public async getSessionStatuses(directory: string) {
    return this.statusesByDirectory.get(directory) ?? {};
  }

  public async listMessages(options: { sessionID: string }) {
    return this.messages.get(options.sessionID) ?? [];
  }

  public async createSession(options: {
    directory: string;
    title?: string | null;
    agent?: string | null;
    model?: { providerID: string; modelID: string } | null;
  }) {
    const id = `ses_${randomUUID()}`;
    const session = {
      id,
      directory: options.directory,
      title: options.title ?? "Untitled",
      agent: options.agent ?? "build",
      model: options.model ?? { providerID: "opencode", modelID: "big-pickle" },
      time: {
        created: Date.now(),
        updated: Date.now(),
      },
    };
    this.sessions.set(id, session);
    this.messages.set(id, []);
    this.statusesByDirectory.set(options.directory, { [id]: { type: "idle" } });
    this.permissionsByDirectory.set(options.directory, []);
    this.questionsByDirectory.set(options.directory, []);
    return session;
  }

  public async setSessionName(options: { sessionID: string; title: string }) {
    const session = await this.getSession({ sessionID: options.sessionID });
    session.title = options.title;
    session.time.updated = Date.now();
    return session;
  }

  public async archiveSession(options: { sessionID: string; archivedAt: number }) {
    const session = await this.getSession({ sessionID: options.sessionID });
    session.time.archived = options.archivedAt;
    session.time.updated = Date.now();
    return session;
  }

  public async promptAsync(options: {
    directory: string;
    sessionID: string;
    input: { agent?: string; model?: { providerID: string; modelID: string }; parts: any[] };
  }) {
    const session = await this.getSession({ sessionID: options.sessionID });
    session.time.updated = Date.now();
    const userMessageID = `msg_${randomUUID()}`;
    const userMessage = {
      info: {
        id: userMessageID,
        sessionID: options.sessionID,
        role: "user" as const,
        time: { created: Date.now() },
        agent: options.input.agent ?? session.agent ?? "build",
        model: options.input.model ?? session.model,
      },
      parts: options.input.parts,
    };
    this.messages.set(options.sessionID, [
      ...(this.messages.get(options.sessionID) ?? []),
      userMessage,
    ]);
    this.statusesByDirectory.set(options.directory, {
      ...(this.statusesByDirectory.get(options.directory) ?? {}),
      [options.sessionID]: { type: "busy" },
    });

    if (this.onPrompt) {
      this.onPrompt({
        directory: options.directory,
        sessionID: options.sessionID,
        userMessageID,
        prompt: options.input,
      });
      return;
    }

    this.finishPrompt({
      directory: options.directory,
      sessionID: options.sessionID,
      userMessageID,
      text: "done",
    });
  }

  public finishPrompt(input: {
    directory: string;
    sessionID: string;
    userMessageID: string;
    text: string;
  }) {
    setTimeout(() => {
      const assistantMessage = {
        info: {
          id: `msg_${randomUUID()}`,
          sessionID: input.sessionID,
          role: "assistant" as const,
          parentID: input.userMessageID,
          providerID: "opencode",
          modelID: "big-pickle",
          agent: "build",
          mode: "build",
          time: {
            created: Date.now(),
            completed: Date.now() + 1,
          },
          cost: 0,
          finish: "stop",
          tokens: {
            total: 42,
            input: 24,
            output: 8,
            reasoning: 10,
            cache: { read: 0, write: 0 },
          },
        },
        parts: [
          {
            id: `prt_${randomUUID()}`,
            type: "reasoning",
            text: "thinking",
          },
          {
            id: `prt_${randomUUID()}`,
            type: "text",
            text: input.text,
          },
        ],
      };
      this.messages.set(input.sessionID, [
        ...(this.messages.get(input.sessionID) ?? []),
        assistantMessage,
      ]);
      const session = this.sessions.get(input.sessionID);
      if (session) {
        session.time.updated = Date.now();
      }
      this.statusesByDirectory.set(input.directory, {
        ...(this.statusesByDirectory.get(input.directory) ?? {}),
        [input.sessionID]: { type: "idle" },
      });
    }, 10);
  }

  public async abortSession(options: { directory: string; sessionID: string }) {
    this.statusesByDirectory.set(options.directory, {
      ...(this.statusesByDirectory.get(options.directory) ?? {}),
      [options.sessionID]: { type: "idle" },
    });
    return true;
  }

  public async listPermissions(directory: string) {
    return this.permissionsByDirectory.get(directory) ?? [];
  }

  public async replyPermission(options: {
    directory: string;
    requestID: string;
    reply: "once" | "always" | "reject";
  }) {
    this.permissionReplies.push({
      directory: options.directory,
      requestID: options.requestID,
      reply: options.reply,
    });
    const permission = (this.permissionsByDirectory.get(options.directory) ?? []).find(
      (candidate) => candidate.id === options.requestID,
    );
    if (permission && this.onPermissionReply) {
      this.onPermissionReply({
        directory: options.directory,
        sessionID: permission.sessionID,
        requestID: options.requestID,
        reply: options.reply,
      });
    }
    return true;
  }

  public async listQuestions(directory: string) {
    return this.questionsByDirectory.get(directory) ?? [];
  }

  public async replyQuestion(options: {
    directory: string;
    requestID: string;
    answers: string[][];
  }) {
    this.questionReplies.push({
      directory: options.directory,
      requestID: options.requestID,
      answers: options.answers,
    });
    const question = (this.questionsByDirectory.get(options.directory) ?? []).find(
      (candidate) => candidate.id === options.requestID,
    );
    if (question && this.onQuestionReply) {
      this.onQuestionReply({
        directory: options.directory,
        sessionID: question.sessionID,
        requestID: options.requestID,
        answers: options.answers,
      });
    }
    return true;
  }

  public async rejectQuestion(options: { directory: string; requestID: string }) {
    this.questionReplies.push({
      directory: options.directory,
      requestID: options.requestID,
      answers: [],
    });
    return true;
  }

  public async listProviders(_directory: string) {
    return this.providerList;
  }

  public async listAgents(_directory: string) {
    return [
      { name: "build", mode: "primary" as const },
      { name: "plan", mode: "primary" as const },
    ];
  }

  public async listSkills(_directory: string) {
    return this.skills;
  }
}
