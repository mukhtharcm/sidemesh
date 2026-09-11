import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { mkdtempSync } from "node:fs";
import { createOpencodeClient } from "@opencode-ai/sdk/v2/client";
import { createServer as createHttpServer } from "node:http";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, describe, it } from "node:test";

import type { AgentProviderLiveEvent } from "./agent-provider.js";
import {
  createOpenCodeServer,
  OpenCodeAgentProvider,
} from "./opencode-provider.js";

const providers: OpenCodeAgentProvider[] = [];
const storeDirectories: string[] = [];
function testStoreDirectory(): string {
  const directory = mkdtempSync(nodePath.join(tmpdir(), "sidemesh-opencode-store-"));
  storeDirectories.push(directory);
  return directory;
}
afterEach(async () => {
  await Promise.all(providers.splice(0).map((provider) => provider.close()));
  await Promise.all(storeDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

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
      if (request.url === "/api/global/event") {
        response.writeHead(200, { "content-type": "text/event-stream" });
        response.write('data: {"payload":{"type":"server.connected","properties":{}}}\n\n');
        return;
      }
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
    hostStateDir: testStoreDirectory(),
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
    hostStateDir: testStoreDirectory(),
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
    assert.deepEqual(client.createSessionInputs[0]?.model, { providerID: "opencode", id: "big-pickle" });
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
    assert.deepEqual(permissionAction.approval?.providerOptions, [
      { id: "once", label: "Allow once", kind: "allow_once" },
      {
        id: "always",
        label: "Allow matching requests",
        kind: "allow_always",
        description: "Remember the suggested patterns for this OpenCode session.",
      },
      { id: "reject", label: "Reject", kind: "reject_once" },
    ]);
    assert.equal(
      provider.respondToPendingAction(permissionAction, {
        providerOptionId: "always",
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
              variants: { high: {}, minimal: {} },
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
    assert.equal(models.length, 4);
    assert.deepEqual(
      models.map((model) => model.id),
      [
        "openai/gpt-4.1",
        "opencode/big-pickle",
        "opencode/big-pickle/high",
        "opencode/big-pickle/minimal",
      ],
    );
    assert.deepEqual(
      models.filter((model) => model.isDefault).map((model) => model.id),
      ["openai/gpt-4.1", "opencode/big-pickle"],
    );
    assert.ok(
      models.find((model) => model.id === "opencode/big-pickle")
        ?.supportedReasoningEfforts.length,
    );
    assert.equal(
      models.find((model) => model.id === "opencode/big-pickle/high")
        ?.defaultReasoningEffort,
      "medium",
    );
    const openAiOnly = await provider.listModels({
      cwd: "/repo/app",
      profile: null,
      provider: "openai",
    });
    assert.deepEqual(openAiOnly.map((model) => model.id), ["openai/gpt-4.1"]);
    assert.equal(
      models.find((model) => model.id === "opencode/big-pickle/high")?.displayName,
      "OpenCode / Big Pickle (High)",
    );

    const skills = await provider.listSkills({
      cwd: "/repo/app",
      forceReload: false,
    });
    assert.equal(skills.skills[0]?.name, "release-checks");
    assert.equal(skills.skills[0]?.scope, "repo");
  });

  it("lists OpenCode provider-defined modes", async () => {
    const client = new FakeOpenCodeClient();
    client.agents = [
      { name: "build", mode: "primary" },
      { name: "plan", mode: "all" },
      { name: "review", mode: "subagent" },
      { name: "hidden", mode: "primary", hidden: true },
    ];
    const provider = createProvider(client);
    await provider.start();

    const modes = await provider.listModes({ cwd: "/repo/app" });
    assert.deepEqual(modes, {
      defaultMode: null,
      modes: [
        { id: "build", label: "Build" },
        { id: "plan", label: "Plan" },
      ],
    });
  });

  it("marks child sessions as sub-agent sessions when parentID is present", async () => {
    const client = new FakeOpenCodeClient();
    client.sessions.set("session-child", {
      id: "session-child",
      directory: "/repo/app",
      parentID: "session-parent",
      title: "Delegated explorer",
      agent: "explore",
      time: {
        created: 1,
        updated: 2,
      },
    });
    client.statusesByDirectory.set("/repo/app", {
      "session-child": { type: "idle" },
    });
    const provider = createProvider(client);
    await provider.start();

    const threads = await provider.listSessionThreads({
      limit: 10,
      archived: false,
      includeSubAgents: true,
    });

    assert.deepEqual(threads[0]?.subAgent, {
      parentSessionId: "session-parent",
      sourceKind: "child_session",
      agentName: "explore",
      agentDisplayName: "Explore",
    });
  });

  it("serializes image inputs and model variants for prompt_async", async () => {
    const client = new FakeOpenCodeClient();
    const provider = createProvider(client);

    await provider.start();
    const created = await provider.createSession({
      cwd: "/repo/app",
      input: [
        { type: "text", text: "Review these images", text_elements: [] },
        { type: "image", url: "https://example.com/diagram.png" },
        { type: "localImage", path: "/repo/app/assets/screenshot.jpg" },
      ],
      overrides: {
        model: "opencode/big-pickle/high",
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
    assert.deepEqual(client.promptInputs[0]?.input.model, {
      providerID: "opencode",
      modelID: "big-pickle",
    });
    assert.equal(client.promptInputs[0]?.input.variant, "high");
    assert.deepEqual(client.promptInputs[0]?.input.parts.slice(1), [
      {
        type: "file",
        mime: "image/png",
        filename: "diagram.png",
        url: "https://example.com/diagram.png",
      },
      {
        type: "file",
        mime: "image/jpeg",
        filename: "screenshot.jpg",
        url: "file:///repo/app/assets/screenshot.jpg",
        source: {
          type: "file",
          path: "/repo/app/assets/screenshot.jpg",
          text: { start: 0, end: 0, value: "" },
        },
      },
    ]);
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
      events.some((event) => event.type === "thread_status_changed" && event.status === "running"),
      false,
    );
    assert.ok(events.some((event) => event.type === "provider_warning" && event.code === "opencode_input_uncertain"));
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

describe("OpenCode SDK event boundary", () => {
  const overrides = { model: null, mode: null, reasoningEffort: null, fastMode: null, approvalPolicy: null,
    sandboxMode: null, networkAccess: null, webSearch: null, profile: null };

  it("checks the selected native server with isolated storage and no model prompt", { skip: !process.env.SIDEMESH_TEST_OPENCODE_BIN }, async () => {
    const root = testStoreDirectory();
    const provider = new OpenCodeAgentProvider({ bin: process.env.SIDEMESH_TEST_OPENCODE_BIN,
      stateDir: nodePath.join(root, "native"), hostStateDir: nodePath.join(root, "host"), defaultDirectory: root });
    providers.push(provider);
    await provider.start();
    assert.equal(await provider.getVersion(), "OpenCode 1.18.4");
    assert.equal(await provider.health(), true);
    const created = await provider.createSession({ cwd: root, input: [], overrides });
    assert.equal(created.activeTurnId, null);
    assert.equal((await provider.readSessionLog(created.thread)).messages.length, 0);
    await provider.setSessionName(created.thread.id, "SDK compatibility check");
    assert.equal((await provider.readSessionThread(created.thread.id, true)).name, "SDK compatibility check");
    assert.ok((await provider.listSessionThreads({ limit: 10, archived: false })).some((item) => item.id === created.thread.id));
    assert.ok((await provider.listModes({ cwd: root })).modes.length > 0);
    await provider.listModels({ cwd: root, profile: null, provider: null });
    await provider.listSkills({ cwd: root, forceReload: false });
    await provider.archiveSession(created.thread.id);
    assert.ok((await provider.listSessionThreads({ limit: 10, archived: true })).some((item) => item.id === created.thread.id));
    await provider.unarchiveSession(created.thread.id);
    await provider.close();
    assert.equal(await provider.health(), false);
  });

  it("subscribes before reads, retains tool cycles, and does not poll idle sessions", async () => {
    const client = new FakeOpenCodeClient();
    client.onPrompt = () => {};
    const provider = createProvider(client);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    const created = await provider.createSession({ cwd: "/repo/日本語 app", input: [], overrides });
    assert.ok(client.requests.findIndex((value) => value.includes("/global/event")) < client.requests.findIndex((value) => value.startsWith("POST /session?")));
    const id = created.thread.id;
    await provider.submitInput({ sessionId: id, activeTurnId: null, clientMessageId: "client-1",
      input: [{ type: "text", text: "check", text_elements: [] }], overrides });
    const userId = client.promptInputs[0]!.input.messageID!;
    const tool = { id: "tool-1", sessionID: id, messageID: "assistant-1", type: "tool", callID: "call-1", tool: "browser",
      state: { status: "completed", input: {}, title: "Screenshot", output: "captured", metadata: {}, time: { start: 10, end: 20 },
        attachments: [{ type: "file", id: "image-1", sessionID: id, messageID: "assistant-1", mime: "image/png", url: "data:image/png;base64,YQ==" }] } };
    client.messages.get(id)!.push({ info: { id: "assistant-1", sessionID: id, role: "assistant", parentID: userId,
      providerID: "opencode", modelID: "big-pickle", agent: "build", mode: "build", cost: 0,
      tokens: { input: 1, output: 1, reasoning: 0, cache: { read: 0, write: 0 } }, time: { created: Date.now(), completed: Date.now() + 1 } },
      parts: [{ id: "text-1", type: "text", text: "first step" }, tool] });
    client.publish();
    await waitForEvent(events, (event) => event.type === "assistant_message_completed");
    assert.equal(events.some((event) => event.type === "turn_completed"), false);
    const activity = await waitForEvent(events, (event) => event.type === "activity_updated" && event.activity.id === "tool-1");
    assert.ok(activity.type === "activity_updated" && activity.activity.type === "tool");
    assert.equal(activity.activity.attachments?.[0]?.url, "data:image/png;base64,YQ==");
    await assert.rejects(provider.submitInput({ sessionId: id, activeTurnId: userId, input: [], overrides }), /busy/);
    assert.equal(client.promptInputs.length, 1);
    client.statusesByDirectory.set(created.thread.cwd, { [id]: { type: "idle" } }); client.publish();
    await waitForEvent(events, (event) => event.type === "turn_completed");
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages[0]?.id, "client-1");
    assert.equal(log.messages[1]?.text, "first step");
    const requests = client.requests.length;
    await delay(650);
    assert.equal(client.requests.length, requests);
    await provider.close();
    assert.equal(client.streams.size, 0);
  });

  it("recovers missed completion and external permission replies after reconnect", async () => {
    const client = new FakeOpenCodeClient();
    client.onPrompt = ({ directory, sessionID }) => client.permissionsByDirectory.set(directory,
      [{ id: "offline-permission", sessionID, permission: "read", patterns: ["file"], metadata: {} }]);
    const provider = createProvider(client);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    const created = await provider.createSession({ cwd: "/repo/app", input: [{ type: "text", text: "work", text_elements: [] }], overrides });
    await waitForEvent(events, (event) => event.type === "action_opened");
    client.disconnect();
    client.permissionsByDirectory.set("/repo/app", []);
    client.finishPrompt({ directory: "/repo/app", sessionID: created.thread.id, userMessageID: created.activeTurnId!, text: "completed while disconnected" });
    await waitForEvent(events, (event) => event.type === "turn_completed");
    await waitForEvent(events, (event) => event.type === "action_resolved");
    assert.ok(client.requests.filter((value) => value.includes("/global/event")).length >= 2);
    assert.equal((await provider.readSessionLog(created.thread)).messages.at(-1)?.text, "completed while disconnected");
  });

  it("rejects unsupported controls before dispatch and closes active input without new work", async () => {
    const client = new FakeOpenCodeClient(); client.onPrompt = () => {};
    const provider = createProvider(client);
    const created = await provider.createSession({ cwd: "/repo/app", input: [], overrides });
    for (const invalid of [{ model: "unknown/model" }, { model: "opencode/big-pickle/missing" }, { mode: "missing" }]) {
      await assert.rejects(provider.submitInput({ sessionId: created.thread.id, activeTurnId: null, input: [], overrides: { ...overrides, ...invalid } }), /not available/);
    }
    assert.equal(client.promptInputs.length, 0);
    await provider.submitInput({ sessionId: created.thread.id, activeTurnId: null, input: [{ type: "text", text: "work", text_elements: [] }], overrides });
    await provider.close();
    assert.equal(client.promptInputs.length, 1);
    assert.equal(client.streams.size, 0);
    await assert.rejects(provider.submitInput({ sessionId: created.thread.id, activeTurnId: null, input: [], overrides }), /closed/);
  });

  it("uses native archive and compaction methods", async () => {
    const client = new FakeOpenCodeClient(); const provider = createProvider(client);
    const created = await provider.createSession({ cwd: "/repo/app", input: [], overrides });
    await provider.compactSession(created.thread.id);
    assert.ok(client.requests.some((value) => value.includes("/summarize")));
    await provider.archiveSession(created.thread.id);
    assert.equal((await provider.listSessionThreads({ archived: true, limit: 10 }))[0]?.id, created.thread.id);
    await provider.unarchiveSession(created.thread.id);
    assert.equal((await provider.listSessionThreads({ archived: false, limit: 10 }))[0]?.id, created.thread.id);
  });

  it("keeps slashes in catalog model IDs and preserves their variants", async () => {
    const client = new FakeOpenCodeClient(); client.onPrompt = () => {};
    client.providerList.all[0]!.models["big-pickle"].id = "vendor/big-pickle";
    const provider = createProvider(client);
    await provider.createSession({ cwd: "/repo/app", input: [{ type: "text", text: "work", text_elements: [] }],
      overrides: { ...overrides, model: "opencode/vendor/big-pickle/high" } });
    assert.deepEqual(client.promptInputs[0]!.input.model, { providerID: "opencode", modelID: "vendor/big-pickle" });
    assert.equal(client.promptInputs[0]!.input.variant, "high");
  });
});

function createProvider(client: FakeOpenCodeClient) {
  const provider = new OpenCodeAgentProvider({
    hostStateDir: testStoreDirectory(),
    defaultDirectory: "/repo/app",
    serverFactory: async ({ onExit: _onExit, onOutput: _onOutput }) => ({
      baseUrl: new URL("http://127.0.0.1:1"),
      close: async () => {},
    }),
    clientFactory: (options) => createOpencodeClient({ ...options, fetch: client.fetch }),
  });
  providers.push(provider);
  return provider;
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
  readonly requests: string[] = [];
  readonly streams = new Set<ReadableStreamDefaultController<Uint8Array>>();
  private readonly published = new Map<string, string>();
  private readonly publishedActions = new Map<string, { directory: string; sessionID: string; kind: "permission" | "question" }>();
  readonly fetch: typeof fetch = async (input, init) => {
    const request = input instanceof Request ? input : new Request(input, init);
    const url = new URL(request.url);
    const path = url.pathname.replace(/^\/api(?=\/)/, "");
    const directory = url.searchParams.get("directory") ?? decodeURIComponent(request.headers.get("x-opencode-directory") ?? "/repo/app");
    const segments = path.split("/").filter(Boolean).map(decodeURIComponent);
    const body = request.method === "GET" || request.method === "HEAD" ? {} : JSON.parse(await request.text() || "{}");
    this.requests.push(`${request.method} ${url.pathname}${url.search}`);
    const json = (data: unknown, status = 200, headers: Record<string, string> = {}) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", ...headers } });
    try {
      if (path === "/global/event") {
        let controller: ReadableStreamDefaultController<Uint8Array>;
        return new Response(new ReadableStream({
          start: (stream) => {
            controller = stream;
            this.streams.add(stream);
            stream.enqueue(new TextEncoder().encode('data: {"payload":{"type":"server.connected","properties":{}}}\n\n'));
            request.signal.addEventListener("abort", () => { if (this.streams.delete(stream)) stream.close(); }, { once: true });
          }, cancel: () => { this.streams.delete(controller); },
        }), { headers: { "content-type": "text/event-stream" } });
      }
      if (path === "/global/health") return json(await this.getHealth(directory));
      if (path === "/experimental/session") {
        const page = await this.listGlobalSessions({ archived: url.searchParams.get("archived") === "true", limit: Number(url.searchParams.get("limit") ?? 100), cursor: Number(url.searchParams.get("cursor") ?? 0) });
        return json(page.sessions, 200, page.nextCursor == null ? {} : { "x-next-cursor": String(page.nextCursor) });
      }
      if (path === "/provider") return json(this.providerList);
      if (path === "/agent") return json(this.agents);
      if (path === "/skill") return json(this.skills);
      if (path === "/session/status") return json(await this.getSessionStatuses(directory));
      if (path === "/session" && request.method === "POST") {
        const session = await this.createSession({ directory, ...body }); this.publish(); return json(session);
      }
      if (segments[0] === "session") {
        const sessionID = segments[1]!;
        if (segments.length === 2 && request.method === "GET") return json(await this.getSession({ sessionID }));
        if (segments.length === 2 && request.method === "PATCH") {
          const session = await this.getSession({ sessionID }); Object.assign(session, { ...body, time: { ...session.time, ...body.time } }); this.publish(); return json(session);
        }
        if (segments[2] === "message") {
          const messages = await this.listMessages({ sessionID });
          const normalized = messages.map((message) => ({ ...message, parts: message.parts.map((part: any, index: number) => ({ ...part, id: part.id ?? `${message.info.id}:part:${index}`, sessionID, messageID: message.info.id })) }));
          return json(segments[3] ? normalized.find((message) => message.info.id === segments[3]) : normalized);
        }
        if (segments[2] === "prompt_async") {
          await this.promptAsync({ directory, sessionID, input: body }); this.publish(); return new Response(null, { status: 204 });
        }
        if (segments[2] === "abort") { await this.abortSession({ directory, sessionID }); this.publish(); return json(true); }
        if (segments[2] === "summarize") return json(true);
      }
      if (path === "/permission") return json(await this.listPermissions(directory));
      if (path === "/question") return json(await this.listQuestions(directory));
      if (segments[0] === "permission" && segments[2] === "reply") {
        const result = await this.replyPermission({ directory, requestID: segments[1]!, reply: body.reply });
        this.permissionsByDirectory.set(directory, (this.permissionsByDirectory.get(directory) ?? []).filter((item) => item.id !== segments[1]));
        this.publish(); return json(result);
      }
      if (segments[0] === "question") {
        const result = segments[2] === "reject" ? await this.rejectQuestion({ directory, requestID: segments[1]! })
          : await this.replyQuestion({ directory, requestID: segments[1]!, answers: body.answers });
        this.questionsByDirectory.set(directory, (this.questionsByDirectory.get(directory) ?? []).filter((item) => item.id !== segments[1]));
        this.publish(); return json(result);
      }
      return json({ message: `Unknown fixture route ${request.method} ${path}` }, 404);
    } catch (error) { return json({ message: error instanceof Error ? error.message : String(error) }, 500); }
  };

  emitEvent(directory: string, type: string, properties: unknown): void {
    const bytes = new TextEncoder().encode(`data: ${JSON.stringify({ directory, payload: { id: randomUUID(), type, properties } })}\n\n`);
    for (const stream of this.streams) stream.enqueue(bytes);
  }
  disconnect(): void {
    for (const stream of this.streams) stream.close();
    this.streams.clear();
  }
  publish(): void {
    const changed = (key: string, value: unknown) => {
      const text = JSON.stringify(value);
      if (this.published.get(key) === text) return false;
      this.published.set(key, text);
      return true;
    };
    for (const session of this.sessions.values()) {
      const directory = session.directory;
      if (changed(`session:${session.id}`, session)) this.emitEvent(directory, "session.updated", { info: session });
      for (const message of this.messages.get(session.id) ?? []) {
        const updated = changed(`message:${message.info.id}`, message.info);
        if (updated) this.emitEvent(directory, "message.updated", { info: { ...message.info, time: { created: message.info.time.created } } });
        for (const [index, value] of message.parts.entries()) {
          const part = { ...value, id: value.id ?? `${message.info.id}:part:${index}`, sessionID: session.id, messageID: message.info.id };
          if (!changed(`part:${part.id}`, part)) continue;
          if (updated && message.info.role === "assistant" && (part.type === "text" || part.type === "reasoning")) {
            this.emitEvent(directory, "message.part.updated", { part: { ...part, text: "" }, sessionID: session.id, time: Date.now() });
            this.emitEvent(directory, "message.part.delta", { sessionID: session.id, messageID: message.info.id, partID: part.id, field: "text", delta: part.text });
          }
          this.emitEvent(directory, "message.part.updated", { part, sessionID: session.id, time: Date.now() });
        }
        if (updated && message.info.time.completed) this.emitEvent(directory, "message.updated", { info: message.info });
      }
      const actions = new Set<string>();
      for (const [kind, values] of [["permission", this.permissionsByDirectory.get(directory) ?? []], ["question", this.questionsByDirectory.get(directory) ?? []]] as const) {
        for (const action of values.filter((item) => item.sessionID === session.id)) {
          const key = `${kind}:${action.id}`;
          actions.add(key);
          if (!this.publishedActions.has(key)) { this.publishedActions.set(key, { directory, sessionID: session.id, kind }); this.emitEvent(directory, `${kind}.asked`, action); }
        }
      }
      for (const [key, action] of this.publishedActions) {
        if (action.sessionID !== session.id || actions.has(key)) continue;
        this.publishedActions.delete(key); this.emitEvent(directory, `${action.kind}.replied`, { sessionID: session.id, requestID: key.slice(key.indexOf(":") + 1), reply: "once", answers: [] });
      }
      const status = this.statusesByDirectory.get(directory)?.[session.id] ?? { type: "idle" };
      if (changed(`status:${session.id}`, status)) this.emitEvent(directory, "session.status", { sessionID: session.id, status });
    }
  }
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
            variants: { high: {} },
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
  public agents: Array<{
    name: string;
    mode: "primary" | "subagent" | "all";
    hidden?: boolean;
  }> = [
    { name: "build", mode: "primary" },
    { name: "plan", mode: "primary" },
  ];

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
      messageID?: string;
      agent?: string;
      model?: { providerID: string; modelID: string };
      variant?: string;
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
      model: options.model ?? { providerID: "opencode", id: "big-pickle" },
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

  public async promptAsync(options: {
    directory: string;
    sessionID: string;
    input: {
      messageID?: string;
      agent?: string;
      model?: { providerID: string; modelID: string };
      variant?: string;
      parts: any[];
    };
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
    const userMessageID = options.input.messageID ?? `msg_${randomUUID()}`;
    const userMessage = {
      info: {
        id: userMessageID,
        sessionID: options.sessionID,
        role: "user" as const,
        time: { created: Date.now() },
        agent: options.input.agent ?? session.agent ?? "build",
        model: {
          ...(options.input.model ?? { providerID: session.model.providerID, modelID: session.model.id ?? session.model.modelID }),
          ...(options.input.variant ? { variant: options.input.variant } : {}),
        },
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
      this.publish();
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
    return this.agents;
  }

  public async listSkills(_directory: string) {
    return this.skills;
  }
}
