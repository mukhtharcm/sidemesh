import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { SessionManager } from "@mariozechner/pi-coding-agent";

import { PiAgentProvider } from "./pi-provider.js";
import type { AgentCreateSessionRequest } from "./agent-provider.js";

describe("PiAgentProvider", () => {
  let tempDir = "";
  let agentDir = "";
  let stateDir = "";

  beforeEach(async () => {
    tempDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-pi-provider-"));
    agentDir = nodePath.join(tempDir, "pi-agent");
    stateDir = nodePath.join(tempDir, "pi-state");
    await mkdir(agentDir, { recursive: true });
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  it("lists and parses persisted Pi session history", async () => {
    const cwd = nodePath.join(tempDir, "repo");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_session-1.jsonl");
    await writeFile(
      sessionPath,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: "session-1",
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
        JSON.stringify({
          type: "message",
          id: "m1",
          parentId: null,
          timestamp: "2026-05-01T10:00:01.000Z",
          message: {
            role: "user",
            content: [{ type: "text", text: "Inspect README" }],
            timestamp: 1_777_770_001_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m2",
          parentId: "m1",
          timestamp: "2026-05-01T10:00:02.000Z",
          message: {
            role: "assistant",
            content: [
              { type: "text", text: "Checking the file." },
              {
                type: "toolCall",
                id: "call-read",
                name: "read",
                arguments: { path: "README.md" },
              },
            ],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: {
              input: 10,
              output: 20,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 30,
              cost: {
                input: 0.001,
                output: 0.002,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0.003,
              },
            },
            stopReason: "toolUse",
            timestamp: 1_777_770_002_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m3",
          parentId: "m2",
          timestamp: "2026-05-01T10:00:03.000Z",
          message: {
            role: "toolResult",
            toolCallId: "call-read",
            toolName: "read",
            content: [{ type: "text", text: "# README" }],
            isError: false,
            timestamp: 1_777_770_003_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m4",
          parentId: "m3",
          timestamp: "2026-05-01T10:00:04.000Z",
          message: {
            role: "assistant",
            content: [
              { type: "text", text: "Updating the intro." },
              {
                type: "toolCall",
                id: "call-edit",
                name: "edit",
                arguments: { path: "README.md" },
              },
            ],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: {
              input: 11,
              output: 21,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 32,
              cost: {
                input: 0.001,
                output: 0.002,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0.003,
              },
            },
            stopReason: "toolUse",
            timestamp: 1_777_770_004_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m5",
          parentId: "m4",
          timestamp: "2026-05-01T10:00:05.000Z",
          message: {
            role: "toolResult",
            toolCallId: "call-edit",
            toolName: "edit",
            content: [{ type: "text", text: "README updated" }],
            details: {
              diff: "@@ -1 +1 @@\n-Old\n+New",
              firstChangedLine: 1,
            },
            isError: false,
            timestamp: 1_777_770_005_000,
          },
        }),
        JSON.stringify({
          type: "compaction",
          id: "c1",
          parentId: "m5",
          timestamp: "2026-05-01T10:00:06.000Z",
          summary: "Compacted earlier context.",
          firstKeptEntryId: "m3",
          tokensBefore: 1200,
        }),
        JSON.stringify({
          type: "session_info",
          id: "s1",
          parentId: "c1",
          timestamp: "2026-05-01T10:00:07.000Z",
          name: "Pi README session",
        }),
        JSON.stringify({
          type: "message",
          id: "m6",
          parentId: "s1",
          timestamp: "2026-05-01T10:00:08.000Z",
          message: {
            role: "assistant",
            content: [{ type: "text", text: "Done." }],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: {
              input: 12,
              output: 22,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 34,
              cost: {
                input: 0.001,
                output: 0.002,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0.003,
              },
            },
            stopReason: "stop",
            timestamp: 1_777_770_008_000,
          },
        }),
      ].join("\n") + "\n",
    );

    const provider = new PiAgentProvider({ agentDir, stateDir });
    await provider.start();

    const threads = await provider.listSessionThreads({
      limit: 10,
      archived: false,
    });
    assert.equal(threads.length, 1);
    assert.equal(threads[0]?.id, "session-1");
    assert.equal(threads[0]?.name, "Pi README session");
    assert.equal(threads[0]?.source, "pi");
    assert.equal(threads[0]?.path, sessionPath);

    const log = await provider.readSessionLog(threads[0]!);
    assert.deepEqual(
      log.messages.map((message) => message.role),
      ["user", "assistant", "assistant", "assistant"],
    );
    assert.equal(log.messages[0]?.text, "Inspect README");
    assert.equal(log.messages[3]?.text, "Done.");
    assert.equal(log.runtime?.model, "anthropic/claude-sonnet-4-5");
    assert.equal(log.runtime?.modelProvider, "anthropic");
    assert.equal(log.runtime?.telemetry?.lastUsage?.outputTokens, 22);

    const activityTypes = log.activities.map((activity) => activity.type).sort();
    assert.deepEqual(activityTypes, [
      "context_compaction",
      "file_change",
      "tool",
      "tool",
    ]);

    const readActivity = log.activities.find(
      (activity) => activity.type === "tool" && activity.toolName === "read",
    ) as Extract<(typeof log.activities)[number], { type: "tool" }> | undefined;
    assert.equal(readActivity?.semantic?.category, "filesystem");
    assert.equal(readActivity?.semantic?.action, "read");

    const fileChange = log.activities.find(
      (activity) => activity.type === "file_change",
    );
    assert.ok(fileChange);

    if (readActivity?.semantic?.targets[0]?.type === "file") {
      readActivity.semantic.targets[0].path = "mutated.md";
    }
    if (fileChange?.type === "file_change") {
      fileChange.changes[0]!.diff = "mutated diff";
    }

    const reloadedLog = await provider.readSessionLog(threads[0]!);
    const reloadedReadActivity = reloadedLog.activities.find(
      (activity) => activity.type === "tool" && activity.toolName === "read",
    ) as Extract<(typeof reloadedLog.activities)[number], { type: "tool" }> | undefined;
    const reloadedFileChange = reloadedLog.activities.find(
      (activity) => activity.type === "file_change",
    );
    if (reloadedReadActivity?.semantic?.targets[0]?.type === "file") {
      assert.equal(reloadedReadActivity.semantic.targets[0].path, "README.md");
    } else {
      throw new Error("expected file semantic target");
    }
    assert.equal(
      reloadedFileChange?.type === "file_change"
        ? reloadedFileChange.changes[0]?.diff
        : null,
      "@@ -1 +1 @@\n-Old\n+New",
    );
  });

  it("maps live Pi session events onto Sidemesh events", async () => {
    const liveEvents: Array<{ type: string; [key: string]: unknown }> = [];
    const listeners = new Set<(event: unknown) => void>();
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-live-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      getContextUsage() {
        return { tokens: 42, contextWindow: 200_000, percent: 0.021 };
      },
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        const partialAssistant = {
          role: "assistant",
          content: [{ type: "text", text: "Working" }],
          provider: "anthropic",
          model: "claude-sonnet-4-5",
          usage: {
            input: 5,
            output: 10,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 15,
            cost: {
              input: 0.001,
              output: 0.002,
              cacheRead: 0,
              cacheWrite: 0,
              total: 0.003,
            },
          },
          stopReason: "stop",
          timestamp: 1_777_770_010_000,
        };
        for (const listener of listeners) {
          listener({
            type: "tool_execution_start",
            toolCallId: "call-read",
            toolName: "read",
            args: { path: "README.md" },
          });
          listener({
            type: "tool_execution_update",
            toolCallId: "call-read",
            toolName: "read",
            args: { path: "README.md" },
            partialResult: { content: [{ type: "text", text: "# README" }] },
          });
          listener({
            type: "message_update",
            message: partialAssistant,
            assistantMessageEvent: {
              type: "text_delta",
              contentIndex: 0,
              delta: "Working",
              partial: partialAssistant,
            },
          });
          listener({
            type: "queue_update",
            steering: ["Focus on README parsing"],
            followUp: [
              "Summarize the result",
              "Mention the testing outcome",
            ],
          });
          listener({
            type: "auto_retry_start",
            attempt: 1,
            maxAttempts: 3,
            delayMs: 1200,
            errorMessage: "Temporary Pi overload",
          });
          listener({
            type: "auto_retry_end",
            attempt: 1,
            success: true,
          });
          listener({
            type: "message_end",
            message: {
              role: "toolResult",
              toolCallId: "call-read",
              toolName: "read",
              content: [{ type: "text", text: "# README" }],
              isError: false,
              timestamp: 1_777_770_011_000,
            },
          });
          listener({
            type: "message_end",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "Done." }],
              provider: "anthropic",
              model: "claude-sonnet-4-5",
              usage: {
                input: 6,
                output: 12,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: 18,
                cost: {
                  input: 0.001,
                  output: 0.002,
                  cacheRead: 0,
                  cacheWrite: 0,
                  total: 0.003,
                },
              },
              stopReason: "stop",
              timestamp: 1_777_770_012_000,
            },
          });
          listener({ type: "agent_end", messages: [] });
        }
      },
      async steer() {},
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel(level: string) {
        this.thinkingLevel = level;
      },
      async setModel(model: typeof fakeModel) {
        this.model = model;
      },
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () => fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    const request: AgentCreateSessionRequest = {
      cwd: "/repo",
      input: [
        {
          type: "text",
          text: "Inspect README",
          text_elements: [],
        },
      ],
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
      },
    };

    const created = await provider.createSession(request);
    assert.equal(created.thread.id, "pi-live-1");
    assert.ok(created.activeTurnId);

    const eventTypes = liveEvents.map((event) => event.type);
    assert.ok(eventTypes.includes("turn_started"));
    assert.ok(eventTypes.includes("assistant_delta"));
    assert.ok(eventTypes.includes("assistant_message_completed"));
    assert.ok(eventTypes.includes("activity_updated"));
    assert.ok(eventTypes.includes("activity_output_delta"));
    assert.ok(eventTypes.includes("runtime_updated"));
    assert.ok(eventTypes.includes("queue_updated"));
    assert.ok(eventTypes.includes("auto_retry_updated"));
    assert.ok(eventTypes.includes("turn_completed"));

    const queueUpdated = liveEvents.find((event) => event.type === "queue_updated");
    assert.deepEqual(queueUpdated, {
      type: "queue_updated",
      sessionId: "pi-live-1",
      steeringCount: 1,
      followUpCount: 2,
      steeringPreview: ["Focus on README parsing"],
      followUpPreview: [
        "Summarize the result",
        "Mention the testing outcome",
      ],
    });
    const autoRetryStarted = liveEvents.find(
      (event) =>
        event.type === "auto_retry_updated" && event.phase === "started",
    );
    assert.deepEqual(autoRetryStarted, {
      type: "auto_retry_updated",
      sessionId: "pi-live-1",
      phase: "started",
      attempt: 1,
      maxAttempts: 3,
      delayMs: 1200,
      errorMessage: "Temporary Pi overload",
    });

    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)?.text, "Done.");
    assert.equal(log.runtime?.telemetry?.contextWindow?.currentTokens, 42);
    assert.equal(log.runtime?.telemetry?.contextWindow?.tokenLimit, 200_000);
    assert.equal(log.runtime?.telemetry?.contextWindow?.messagesLength, 0);
    const activity = log.activities.find((candidate) => candidate.type === "tool");
    assert.equal(activity?.type, "tool");
  });

  it("emits provider warnings when Pi auto-retry gives up", async () => {
    const listeners = new Set<(event: unknown) => void>();
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-retry-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt() {
        for (const listener of listeners) {
          listener({
            type: "auto_retry_start",
            attempt: 3,
            maxAttempts: 3,
            delayMs: 8000,
            errorMessage: "Still overloaded",
          });
          listener({
            type: "auto_retry_end",
            attempt: 3,
            success: false,
            finalError: "Retry budget exhausted",
          });
          listener({ type: "agent_end", messages: [] });
        }
      },
      async steer() {},
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel(level: string) {
        this.thinkingLevel = level;
      },
      async setModel(model: typeof fakeModel) {
        this.model = model;
      },
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
    };

    const liveEvents: Array<{ type: string; [key: string]: unknown }> = [];
    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () => fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "retry please", text_elements: [] }],
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
      },
    });

    const retryWarning = liveEvents.find(
      (event) =>
        event.type === "provider_warning" &&
        event.code === "pi_auto_retry_failed",
    );
    assert.deepEqual(retryWarning, {
      type: "provider_warning",
      sessionId: "pi-retry-1",
      level: "error",
      code: "pi_auto_retry_failed",
      message: "Retry budget exhausted",
      source: "pi/retry",
    });
  });

  it("only exposes authenticated Pi models and rejects unavailable overrides", async () => {
    const availableModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const unavailableModel = {
      id: "gpt-5",
      name: "GPT-5",
      provider: "openai",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const setModels: string[] = [];
    const fakeSession = {
      sessionId: "pi-model-1",
      sessionFile: null,
      sessionManager,
      model: availableModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt() {},
      async steer() {},
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel(level: string) {
        this.thinkingLevel = level;
      },
      async setModel(model: typeof availableModel) {
        setModels.push(`${model.provider}/${model.id}`);
        this.model = model;
      },
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [availableModel, unavailableModel],
        getAvailable: () => [availableModel],
        getProviderDisplayName: (provider: string) => provider,
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const models = await provider.listModels({
      cwd: "/repo",
      profile: null,
      provider: null,
    });
    assert.deepEqual(models.map((model) => model.model), [
      "anthropic/claude-sonnet-4-5",
    ]);

    await assert.rejects(
      () =>
        provider.createSession({
          cwd: "/repo",
          input: [],
          overrides: {
            ...emptyOverrides(),
            model: "openai/gpt-5",
          },
        }),
      /Unknown or unavailable Pi model "openai\/gpt-5"\./,
    );
    assert.deepEqual(setModels, []);
  });

  it("ignores image URL inputs with a warning instead of failing", async () => {
    const warnings: string[] = [];
    const prompts: Array<{ text: string; imageCount: number }> = [];
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-image-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt(
        text: string,
        options?: { images?: Array<{ type: string }> },
      ) {
        prompts.push({
          text,
          imageCount: options?.images?.length ?? 0,
        });
      },
      async steer() {},
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel(level: string) {
        this.thinkingLevel = level;
      },
      async setModel(model: typeof fakeModel) {
        this.model = model;
      },
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("stderr", (line) => warnings.push(line));
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "image", url: "https://example.com/image.png" }],
      overrides: emptyOverrides(),
    });

    assert.ok(created.activeTurnId);
    assert.deepEqual(prompts, [
      {
        text:
          "The request only included an unsupported image URL attachment. Tell the user that Pi only supports local image attachments.",
        imageCount: 0,
      },
    ]);
    assert.deepEqual(warnings, [
      "Ignoring 1 image URL attachment because Pi only supports local image attachments.",
    ]);

    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages[0]?.text, prompts[0]?.text);
    assert.deepEqual(log.messages[0]?.attachments ?? [], []);
  });

  it("reports corrupt Pi sidecar state and continues startup", async () => {
    await mkdir(stateDir, { recursive: true });
    await writeFile(nodePath.join(stateDir, "sessions.json"), "{broken-json");
    const errors: string[] = [];

    const provider = new PiAgentProvider({ agentDir, stateDir });
    provider.on("stderr", (line) => errors.push(line));

    await provider.start();

    assert.equal(errors.length, 1);
    assert.match(
      errors[0] ?? "",
      /Pi provider state reset after failing to load .*sessions\.json:/,
    );
    const threads = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.deepEqual(threads, []);
  });




  it("steers an active Pi turn instead of starting a new one", async () => {
    const liveEvents: Array<{ type: string; [key: string]: unknown }> = [];
    const steerCalls: Array<{ text: string; images: unknown[] }> = [];
    const listeners = new Set<(event: unknown) => void>();
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-steer-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: true,
      messages: [],
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        // simulate a long-running prompt
      },
      async steer(text: string, images?: unknown[]) {
        steerCalls.push({ text, images: images ?? [] });
        for (const listener of listeners) {
          listener({
            type: "message_update",
            message: { role: "assistant", content: [{ type: "text", text: "Steered." }] },
            assistantMessageEvent: {
              type: "text_delta",
              contentIndex: 0,
              delta: "Steered.",
              partial: { role: "assistant", content: [{ type: "text", text: "Steered." }] },
            },
          });
          listener({
            type: "message_end",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "Steered." }],
              provider: "anthropic",
              model: "claude-sonnet-4-5",
              usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
              stopReason: "stop",
              timestamp: 1_777_770_010_000,
            },
          });
          listener({ type: "agent_end", messages: [] });
        }
      },
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel() {},
      async setModel() {},
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "First", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    // steer while the turn is still active
    const result = await provider.submitInput({
      sessionId: created.thread.id,
      input: [{ type: "text", text: "Steer me", text_elements: [] }],
      activeTurnId: created.activeTurnId,
      overrides: emptyOverrides(),
    });
    assert.equal(result.mode, "steer");
    assert.equal(result.turnId, created.activeTurnId);
    assert.equal(steerCalls.length, 1);
    assert.equal(steerCalls[0]?.text, "Steer me");

    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)?.text, "Steered.");
  });

  it("interrupts an active Pi turn", async () => {
    const liveEvents: Array<{ type: string; [key: string]: unknown }> = [];
    const listeners = new Set<(event: unknown) => void>();
    const abortCalls: string[] = [];
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-interrupt-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: true,
      messages: [],
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        // never completes
      },
      async steer() {},
      async abort() {
        abortCalls.push("abort");
      },
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel() {},
      async setModel() {},
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Long task", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    const result = await provider.interruptTurn(created.thread.id, created.activeTurnId!);
    assert.deepEqual(result, { interrupted: true });
    assert.equal(abortCalls.length, 1);

    const eventTypes = liveEvents.map((event) => event.type);
    assert.ok(eventTypes.includes("turn_completed"));
    const turnCompleted = liveEvents.find((event) => event.type === "turn_completed");
    assert.equal(turnCompleted?.status, "interrupted");

    // second interrupt should be a no-op
    const result2 = await provider.interruptTurn(created.thread.id, created.activeTurnId!);
    assert.deepEqual(result2, { interrupted: false });
  });

  it("archives and unarchives a Pi session", async () => {
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-archive-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt() {},
      async steer() {},
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel() {},
      async setModel() {},
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Hello", text_elements: [] }],
      overrides: emptyOverrides(),
    });

    await provider.archiveSession(created.thread.id);
    const archived = await provider.listSessionThreads({ limit: 10, archived: true });
    assert.equal(archived.length, 1);
    assert.equal(archived[0]?.id, created.thread.id);

    const unarchived = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.equal(unarchived.length, 0);

    await provider.unarchiveSession(created.thread.id);
    const restored = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.equal(restored.length, 1);
    assert.equal(restored[0]?.id, created.thread.id);
  });

  it("compacts a Pi session", async () => {
    const compactCalls: string[] = [];
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-compact-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt() {},
      async steer() {},
      async abort() {},
      async compact() {
        compactCalls.push("compact");
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel() {},
      async setModel() {},
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Hello", text_elements: [] }],
      overrides: emptyOverrides(),
    });

    const result = await provider.compactSession(created.thread.id);
    assert.deepEqual(result, { ok: true });
    assert.equal(compactCalls.length, 1);
  });

  it("sets a Pi session name via the path branch", async () => {
    const cwd = nodePath.join(tempDir, "repo");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_name-test.jsonl");
    await writeFile(
      sessionPath,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: "name-test",
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
        JSON.stringify({
          type: "message",
          id: "m1",
          parentId: null,
          timestamp: "2026-05-01T10:00:01.000Z",
          message: {
            role: "user",
            content: [{ type: "text", text: "Hello" }],
            timestamp: 1_777_770_001_000,
          },
        }),
      ].join("\n") + "\n",
    );

    const provider = new PiAgentProvider({ agentDir, stateDir });
    await provider.start();

    await provider.setSessionName("name-test", "Renamed via path");
    const threads = await provider.listSessionThreads({ limit: 10, archived: false });
    const thread = threads.find((t) => t.id === "name-test");
    assert.equal(thread?.name, "Renamed via path");
  });

  it("restores Pi sidecar state across provider restarts", async () => {
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-restore-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt() {},
      async steer() {},
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel() {},
      async setModel() {},
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Hello", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    await provider.close();

    // start a fresh provider instance pointing at the same state dir
    const provider2 = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider2.start();

    const threads = await provider2.listSessionThreads({ limit: 10, archived: false });
    assert.equal(threads.length, 1);
    assert.equal(threads[0]?.id, created.thread.id);
  });

  it("isolates multiple concurrent Pi sessions", async () => {
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const makeFakeSession = (id: string) => ({
      sessionId: id,
      sessionFile: null,
      sessionManager: SessionManager.inMemory("/repo"),
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt() {},
      async steer() {},
      async abort() {},
      async compact() {
        return { ok: true };
      },
      setSessionName() {},
      setThinkingLevel() {},
      async setModel() {},
      dispose() {},
    });
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: makeFakeSession("pi-multi-1"),
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const a = await provider.createSession({
      cwd: "/repo/a",
      input: [{ type: "text", text: "A", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    // override internal factory for second session to return a different ID
    (provider as unknown as Record<string, unknown>)["createSessionFromServicesFactory"] = (async () => ({
      session: makeFakeSession("pi-multi-2"),
      extensionsResult: { extensions: [], errors: [], runtime: {} as never },
    })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices;

    const b = await provider.createSession({
      cwd: "/repo/b",
      input: [{ type: "text", text: "B", text_elements: [] }],
      overrides: emptyOverrides(),
    });

    const threads = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.equal(threads.length, 2);
    const ids = threads.map((t) => t.id).sort();
    assert.deepEqual(ids, ["pi-multi-1", "pi-multi-2"]);

    // archive one, the other remains
    await provider.archiveSession(a.thread.id);
    const active = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.equal(active.length, 1);
    assert.equal(active[0]?.id, b.thread.id);
  });

  it("reconstructs context window from persisted Pi session history via model registry", async () => {
    const cwd = nodePath.join(tempDir, "repo-context");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_session-context.jsonl");
    await writeFile(
      sessionPath,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: "session-context",
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
        JSON.stringify({
          type: "model_change",
          id: "mc1",
          parentId: null,
          timestamp: "2026-05-01T10:00:01.000Z",
          provider: "anthropic",
          modelId: "claude-sonnet-4-5",
        }),
        JSON.stringify({
          type: "message",
          id: "m1",
          parentId: "mc1",
          timestamp: "2026-05-01T10:00:02.000Z",
          message: {
            role: "assistant",
            content: [{ type: "text", text: "Hello." }],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: { input: 10, output: 20, totalTokens: 30 },
            stopReason: "stop",
            timestamp: 1_777_770_002_000,
          },
        }),
      ].join("\n") + "\n",
    );

    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
      contextWindow: 400_000,
    };
    const fakeServices = {
      cwd,
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
    });
    await provider.start();

    const threads = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.equal(threads.length, 1);
    const log = await provider.readSessionLog(threads[0]!);
    assert.ok(log.runtime?.telemetry?.contextWindow, "contextWindow should be reconstructed from model registry");
    assert.equal(log.runtime?.telemetry?.contextWindow?.tokenLimit, 400_000);
    assert.equal(log.runtime?.telemetry?.contextWindow?.currentTokens, null);
    assert.equal(log.runtime?.telemetry?.contextWindow?.messagesLength, 1);
  });

  it("preserves existing runtime context window when reloading from history", async () => {
    const cwd = nodePath.join(tempDir, "repo-preserve");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_session-preserve.jsonl");
    await writeFile(
      sessionPath,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: "session-preserve",
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
        JSON.stringify({
          type: "message",
          id: "m1",
          parentId: null,
          timestamp: "2026-05-01T10:00:01.000Z",
          message: {
            role: "assistant",
            content: [{ type: "text", text: "Hello." }],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: { input: 10, output: 20, totalTokens: 30 },
            stopReason: "stop",
            timestamp: 1_777_770_001_000,
          },
        }),
      ].join("\n") + "\n",
    );

    const provider = new PiAgentProvider({ agentDir, stateDir });
    await provider.start();

    const threads = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.equal(threads.length, 1);

    // First read loads the session into memory
    await provider.readSessionLog(threads[0]!);

    // Simulate a prior loaded session that had context window info
    const state = (provider as any).sessions.get("session-preserve");
    assert.ok(state);
    state.runtime = {
      model: "anthropic/claude-sonnet-4-5",
      modelProvider: "anthropic",
      telemetry: {
        contextWindow: {
          currentTokens: 1234,
          tokenLimit: 200_000,
          messagesLength: 1,
          updatedAt: Date.now(),
        },
      },
    };

    // Reload from history should preserve the contextWindow
    const log = await provider.readSessionLog(threads[0]!);
    assert.equal(log.runtime?.telemetry?.contextWindow?.currentTokens, 1234);
    assert.equal(log.runtime?.telemetry?.contextWindow?.tokenLimit, 200_000);
  });

  it("records null tokens in context window after post-compaction getContextUsage", async () => {
    const liveEvents: Array<{ type: string; [key: string]: unknown }> = [];
    const listeners = new Set<(event: unknown) => void>();
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-null-tokens-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [{ role: "user", content: [{ type: "text", text: "hi" }] }],
      getContextUsage() {
        return { tokens: null, contextWindow: 400_000, percent: null };
      },
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        const assistant = {
          role: "assistant",
          content: [{ type: "text", text: "Done." }],
          provider: "anthropic",
          model: "claude-sonnet-4-5",
          usage: { input: 5, output: 10, totalTokens: 15 },
          stopReason: "stop",
          timestamp: 1_777_770_010_000,
        };
        for (const listener of listeners) {
          listener({ type: "message_update", message: assistant, assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Done.", partial: assistant } });
          listener({ type: "message_end", message: assistant });
          listener({ type: "agent_end", messages: [] });
        }
      },
      async steer() {},
      async abort() {},
      async compact() { return { ok: true }; },
      setSessionName() {},
      setThinkingLevel() {},
      async setModel() {},
      dispose() {},
    };
    const fakeServices = {
      cwd: "/repo",
      agentDir,
      authStorage: {},
      modelRegistry: {
        getAll: () => [fakeModel],
        getAvailable: () => [fakeModel],
        getProviderDisplayName: () => "Anthropic",
      },
      settingsManager: {
        getDefaultProvider: () => "anthropic",
        getDefaultModel: () => "claude-sonnet-4-5",
        getDefaultThinkingLevel: () => "medium",
      },
      resourceLoader: {
        getSkills: () => ({ skills: [], diagnostics: [] }),
      },
      diagnostics: [],
    };

    const provider = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@mariozechner/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    const request: AgentCreateSessionRequest = {
      cwd: "/repo",
      input: [{ type: "text", text: "Hello", text_elements: [] }],
      overrides: emptyOverrides(),
    };
    const created = await provider.createSession(request);
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.runtime?.telemetry?.contextWindow?.currentTokens, null);
    assert.equal(log.runtime?.telemetry?.contextWindow?.tokenLimit, 400_000);
    assert.equal(log.runtime?.telemetry?.contextWindow?.messagesLength, 1);
  });
});


function piSessionDirForCwd(cwd: string, agentDir: string): string {
  const safePath = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
  return nodePath.join(agentDir, "sessions", safePath);
}

function emptyOverrides(): AgentCreateSessionRequest["overrides"] {
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
