import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import type { AgentProviderLiveEvent } from "./agent-provider.js";
import {
  createOpenCodeServer,
  OpenCodeAgentProvider,
} from "./opencode-provider.js";

describe("OpenCode provider", () => {
  it("launches OpenCode serve with the supported upstream arguments", async () => {
    const tempDir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-opencode-launch-test-"),
    );
    const fakeBin = nodePath.join(tempDir, "fake-opencode");
    await writeFile(
      fakeBin,
      `#!/bin/sh
if [ "$1" = "serve" ] && [ "$2" = "--hostname" ] && [ "$3" = "127.0.0.1" ] && [ "$4" = "--port" ] && [ "$5" = "0" ] && [ "$#" -eq 5 ]; then
  echo "opencode server listening on http://127.0.0.1:4318"
  exit 0
fi
echo "unexpected args: $@" >&2
exit 1
`,
      "utf8",
    );
    await chmod(fakeBin, 0o755);

    const output: string[] = [];
    const handle = await createOpenCodeServer({
      bin: fakeBin,
      stateDir: null,
      onOutput: (line) => output.push(line),
      onExit: () => {},
    });

    assert.equal(handle.baseUrl.href, "http://127.0.0.1:4318/");
    assert.deepEqual(output, []);

    await handle.close();
  });

  it("times out when OpenCode never reports a ready server", async () => {
    const tempDir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-opencode-timeout-test-"),
    );
    const fakeBin = nodePath.join(tempDir, "fake-opencode-hang");
    await writeFile(
      fakeBin,
      `#!/bin/sh
sleep 10
`,
      "utf8",
    );
    await chmod(fakeBin, 0o755);

    await assert.rejects(
      () =>
        createOpenCodeServer({
          bin: fakeBin,
          stateDir: null,
          readyTimeoutMs: 50,
          onOutput: () => {},
          onExit: () => {},
        }),
      /did not become ready within 50ms/,
    );
  });

  it("detects /api-prefixed OpenCode HTTP routes on startup", async () => {
    const server = createHttpServer((request, response) => {
      if (request.url === "/api/global/health") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ healthy: true, version: "9.9.9" }));
        return;
      }
      response.writeHead(404, { "content-type": "text/plain" });
      response.end("not found");
    });
    await new Promise<void>((resolve, reject) => {
      server.listen(0, "127.0.0.1", (error?: Error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("Expected TCP server address");
    }

    const provider = new OpenCodeAgentProvider({
      defaultDirectory: "/repo/app",
      serverFactory: async () => ({
        baseUrl: new URL(`http://127.0.0.1:${address.port}`),
        close: async () => {
          await new Promise<void>((resolve, reject) => {
            server.close((error) => {
              if (error) {
                reject(error);
                return;
              }
              resolve();
            });
          });
        },
      }),
    });

    try {
      assert.equal(await provider.getVersion(), "OpenCode 9.9.9");
    } finally {
      await provider.close();
    }
  });

  it("fails fast when the OpenCode build does not expose the required HTTP API", async () => {
    const server = createHttpServer((_request, response) => {
      response.writeHead(404, { "content-type": "text/plain" });
      response.end("not found");
    });
    await new Promise<void>((resolve, reject) => {
      server.listen(0, "127.0.0.1", (error?: Error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve();
      });
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("Expected TCP server address");
    }
    let closeCalls = 0;

    const provider = new OpenCodeAgentProvider({
      defaultDirectory: "/repo/app",
      serverFactory: async () => ({
        baseUrl: new URL(`http://127.0.0.1:${address.port}`),
        close: async () => {
          closeCalls += 1;
          await new Promise<void>((resolve, reject) => {
            server.close((error) => {
              if (error) {
                reject(error);
                return;
              }
              resolve();
            });
          });
        },
      }),
    });

    try {
      await assert.rejects(
        () => provider.start(),
        /did not expose a supported headless HTTP API/,
      );
      assert.equal(closeCalls, 1);
    } finally {
      await provider.close();
      assert.equal(closeCalls, 1);
    }
  });

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
    assert.equal(client.createSessionInputs[0]?.model, undefined);
    assert.deepEqual(client.promptInputs[0]?.input.model, {
      providerID: "opencode",
      modelID: "big-pickle",
    });
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

  it("reopens a pending action when the upstream permission reply fails", async () => {
    const client = new FakeOpenCodeClient();
    const provider = createProvider(client);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));

    client.onPrompt = ({ directory, sessionID }) => {
      client.permissionsByDirectory.set(directory, [
        {
          id: "perm-fail",
          sessionID,
          permission: "read",
          patterns: ["src/server.ts"],
          metadata: {},
        },
      ]);
      client.statusesByDirectory.set(directory, {
        [sessionID]: { type: "busy" },
      });
    };
    client.permissionReplyError = new Error("permission reply failed");

    try {
      await provider.start();
      await provider.createSession({
        cwd: "/repo/app",
        input: [{ type: "text", text: "Trigger permission failure", text_elements: [] }],
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
        (action) => action.id === "permission:perm-fail",
      );
      assert.equal(
        provider.respondToPendingAction(permissionAction, {
          decision: "approve",
          scope: "location",
        }),
        true,
      );

      const reopened = await waitForNthOpenedAction(events, permissionAction.id, 2);
      assert.equal(reopened.id, permissionAction.id);
      assert.ok(
        events.some(
          (event) =>
            event.type === "provider_warning" &&
            event.sessionId === permissionAction.sessionId &&
            event.message.includes("permission reply failed"),
        ),
      );
    } finally {
      await provider.close();
    }
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
    const openAiOnly = await provider.listModels({
      cwd: "/repo/app",
      profile: null,
      provider: "openai",
    });
    assert.deepEqual(openAiOnly.map((model) => model.id), ["openai/gpt-4.1"]);

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

  it("does not emit a started turn when prompt submission fails", async () => {
    const client = new FakeOpenCodeClient();
    client.promptAsyncError = new Error("OpenCode prompt_async returned 500");
    const provider = createProvider(client);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));

    await provider.start();
    await assert.rejects(
      () =>
        provider.createSession({
          cwd: "/repo/app",
          input: [{ type: "text", text: "Fail this prompt", text_elements: [] }],
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
        }),
      /prompt_async returned 500/,
    );
    assert.equal(events.some((event) => event.type === "turn_started"), false);
    assert.equal(
      events.some((event) => event.type === "thread_status_changed"),
      false,
    );
  });

  it("finds uncached sessions beyond the first 200 global results", async () => {
    const client = new FakeOpenCodeClient();
    for (let index = 0; index < 205; index += 1) {
      const id = `ses_${index}`;
      client.sessions.set(id, {
        id,
        directory: "/repo/app",
        title: `Session ${index}`,
        agent: "build",
        model: { providerID: "opencode", modelID: "big-pickle" },
        time: {
          created: index,
          updated: 10_000 - index,
        },
      });
      client.messages.set(id, []);
    }

    const provider = createProvider(client);
    const resumed = await provider.resumeSessionThread("ses_204");

    assert.deepEqual(resumed, { resumed: true });
    assert.deepEqual(await provider.listLoadedSessionIds(), ["ses_204"]);
    const thread = await provider.readSessionThread("ses_204", false);
    assert.equal(thread.name, "Session 204");
  });

  it("marks the latest turn in progress while OpenCode is still busy", async () => {
    const client = new FakeOpenCodeClient();
    const session = await client.createSession({
      directory: "/repo/app",
      title: "Running turn",
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
        parts: [{ id: "user-text", type: "text", text: "still running" }],
      },
    ]);
    client.statusesByDirectory.set("/repo/app", {
      [session.id]: { type: "busy" },
    });

    const provider = createProvider(client);
    await provider.start();
    const thread = await provider.readSessionThread(session.id, true);

    assert.equal(thread.turns?.[0]?.status, "in_progress");
    assert.equal(thread.turns?.[0]?.completedAt, null);
  });

  it("normalizes busy OpenCode sessions to a generic running phase", async () => {
    const client = new FakeOpenCodeClient();
    const session = await client.createSession({
      directory: "/repo/app",
      title: "Busy session",
      agent: "build",
      model: { providerID: "opencode", modelID: "big-pickle" },
    });
    client.statusesByDirectory.set("/repo/app", {
      [session.id]: { type: "busy" },
    });

    const provider = createProvider(client);
    await provider.start();
    const thread = await provider.readSessionThread(session.id, false);

    assert.equal(thread.status.type, "busy");
    assert.equal(thread.status.phase, "running");
  });

  it("marks incomplete assistant turns interrupted once OpenCode reports idle", async () => {
    const client = new FakeOpenCodeClient();
    const session = await client.createSession({
      directory: "/repo/app",
      title: "Interrupted turn",
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
        parts: [{ id: "user-text", type: "text", text: "got interrupted" }],
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
          time: { created: 200 },
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
        parts: [],
      },
    ]);
    client.statusesByDirectory.set("/repo/app", {
      [session.id]: { type: "idle" },
    });

    const provider = createProvider(client);
    await provider.start();
    const thread = await provider.readSessionThread(session.id, true);

    assert.equal(thread.turns?.[0]?.status, "interrupted");
    assert.equal(thread.turns?.[0]?.completedAt, 200);
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

async function waitForNthOpenedAction(
  events: AgentProviderLiveEvent[],
  actionId: string,
  count: number,
  timeoutMs = 2_000,
): Promise<Extract<AgentProviderLiveEvent, { type: "action_opened" }>["action"]> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const matches = events.filter(
      (event): event is Extract<AgentProviderLiveEvent, { type: "action_opened" }> =>
        event.type === "action_opened" && event.action.id === actionId,
    );
    if (matches.length >= count) {
      return matches[count - 1]!.action;
    }
    await delay(10);
  }
  throw new Error("Timed out waiting for reopened action.");
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
  public readonly createSessionInputs: Array<{
    directory: string;
    title?: string | null;
    agent?: string | null;
    model?: { providerID: string; modelID: string } | null;
  }> = [];
  public readonly promptInputs: Array<{
    directory: string;
    sessionID: string;
    input: {
      agent?: string;
      model?: { providerID: string; modelID: string };
      parts: any[];
    };
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
  public promptAsyncError: Error | null = null;
  public permissionReplyError: Error | null = null;

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
    cursor?: number | null;
  }) {
    const sessions = [...this.sessions.values()]
      .filter((session) => options.archived === Boolean(session.time.archived))
      .sort((left, right) => right.time.updated - left.time.updated);
    const start = Math.max(0, options.cursor ?? 0);
    const page = sessions.slice(start, start + options.limit);
    return {
      sessions: page,
      nextCursor: start + page.length < sessions.length ? start + page.length : null,
    };
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
    this.createSessionInputs.push({
      directory: options.directory,
      title: options.title,
      agent: options.agent,
      ...(options.model ? { model: options.model } : {}),
    });
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
    this.promptInputs.push({
      directory: options.directory,
      sessionID: options.sessionID,
      input: options.input,
    });
    if (this.promptAsyncError) {
      throw this.promptAsyncError;
    }
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
    if (this.permissionReplyError) {
      throw this.permissionReplyError;
    }
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
