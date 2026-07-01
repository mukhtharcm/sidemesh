import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import { SessionManager } from "@earendil-works/pi-coding-agent";

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
      await rm(tempDir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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

  it("reuses cached idle history without persisting state again", async () => {
    const cwd = nodePath.join(tempDir, "repo");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_session-1.jsonl");
    await writePiSessionHistory(
      sessionPath,
      minimalPiHistoryLines(cwd),
      "2026-05-01T10:00:02.100Z",
    );

    const provider = new PiAgentProvider({ agentDir, stateDir });
    await provider.start();

    const threads = await provider.listSessionThreads({
      limit: 10,
      archived: false,
    });
    const thread = threads[0];
    assert.ok(thread);

    const firstLog = await provider.readSessionLog(thread);
    assert.equal(firstLog.messages.length, 2);
    assert.equal(firstLog.activities.length, 0);

    let saveStateCalls = 0;
    const providerWithInternals = provider as unknown as {
      saveState: () => Promise<void>;
    };
    const originalSaveState = providerWithInternals.saveState.bind(provider);
    providerWithInternals.saveState = async () => {
      saveStateCalls += 1;
      await originalSaveState();
    };

    const secondLog = await provider.readSessionLog(thread);
    assert.equal(secondLog.messages.length, 2);
    assert.equal(saveStateCalls, 0);
    assert.equal(thread.path, sessionPath);
  });

  it("reloads idle history when the file changes within the same second", async () => {
    const cwd = nodePath.join(tempDir, "repo");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_session-1.jsonl");
    const baseLines = minimalPiHistoryLines(cwd);
    await writePiSessionHistory(
      sessionPath,
      baseLines,
      "2026-05-01T10:00:02.100Z",
    );

    const provider = new PiAgentProvider({ agentDir, stateDir });
    await provider.start();

    const threads = await provider.listSessionThreads({
      limit: 10,
      archived: false,
    });
    const thread = threads[0];
    assert.ok(thread);

    const firstLog = await provider.readSessionLog(thread);
    assert.equal(firstLog.messages.length, 2);

    let saveStateCalls = 0;
    const providerWithInternals = provider as unknown as {
      saveState: () => Promise<void>;
    };
    const originalSaveState = providerWithInternals.saveState.bind(provider);
    providerWithInternals.saveState = async () => {
      saveStateCalls += 1;
      await originalSaveState();
    };

    await writePiSessionHistory(
      sessionPath,
      [
        ...baseLines,
        JSON.stringify(
          minimalPiAssistantMessage(
            "m3",
            "m2",
            "2026-05-01T10:00:02.900Z",
            "Still working.",
            12,
            24,
            36,
          ),
        ),
      ],
      "2026-05-01T10:00:02.900Z",
    );

    const secondLog = await provider.readSessionLog(thread);
    assert.equal(secondLog.messages.length, 3);
    assert.equal(saveStateCalls, 1);
    assert.equal(secondLog.messages[2]?.content[0]?.type, "text");
    assert.equal(
      secondLog.messages[2]?.content[0]?.type === "text"
        ? secondLog.messages[2].content[0].text
        : null,
      "Still working.",
    );
  });

  it("does not block history reads on persistence", async () => {
    const cwd = nodePath.join(tempDir, "repo");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_session-1.jsonl");
    await writePiSessionHistory(
      sessionPath,
      minimalPiHistoryLines(cwd),
      "2026-05-01T10:00:02.100Z",
    );

    const provider = new PiAgentProvider({ agentDir, stateDir });
    await provider.start();

    const threads = await provider.listSessionThreads({
      limit: 10,
      archived: false,
    });
    const thread = threads[0];
    assert.ok(thread);

    let releaseSaveState = () => {};
    const saveStateBlocked = new Promise<void>((resolve) => {
      releaseSaveState = resolve;
    });
    let saveStateCalls = 0;
    const providerWithInternals = provider as unknown as {
      saveState: () => Promise<void>;
    };
    providerWithInternals.saveState = async () => {
      saveStateCalls += 1;
      await saveStateBlocked;
    };

    try {
      const outcome = await Promise.race([
        provider.readSessionLog(thread).then((log) => ({ type: "resolved" as const, log })),
        delay(50).then(() => ({ type: "timed_out" as const })),
      ]);
      assert.equal(outcome.type, "resolved");
      assert.equal(outcome.log.messages.length, 2);

      await delay(0);
      assert.equal(saveStateCalls, 1);
    } finally {
      releaseSaveState();
      await delay(0);
    }
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
            type: "message_update",
            message: partialAssistant,
            assistantMessageEvent: {
              type: "thinking_delta",
              contentIndex: 0,
              delta: "Let me analyze...",
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
    assert.ok(eventTypes.includes("reasoning_delta"));
    assert.ok(eventTypes.includes("assistant_message_completed"));
    assert.ok(eventTypes.includes("activity_updated"));
    assert.ok(eventTypes.includes("activity_output_delta"));
    assert.ok(eventTypes.includes("runtime_updated"));
    assert.ok(eventTypes.includes("queue_updated"));
    assert.ok(eventTypes.includes("auto_retry_updated"));
    assert.ok(eventTypes.includes("turn_completed"));

    const reasoningDelta = liveEvents.find((event) => event.type === "reasoning_delta");
    assert.ok(reasoningDelta);
    assert.equal(reasoningDelta?.type, "reasoning_delta");
    assert.equal(reasoningDelta?.sessionId, "pi-live-1");
    assert.equal(reasoningDelta?.delta, "Let me analyze...");
    assert.equal(reasoningDelta?.summary, false);
    assert.ok(typeof reasoningDelta?.turnId === "string");

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

  it("completes Pi turns on terminal assistant message_end even without agent_end", async () => {
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
      sessionId: "pi-terminal-stop-1",
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
      async prompt(_text: string) {
        for (const listener of listeners) {
          listener({
            type: "message_end",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "Done." }],
              provider: "anthropic",
              model: "claude-sonnet-4-5",
              usage: {
                input: 5,
                output: 10,
                cacheRead: 0,
                cacheWrite: 0,
                totalTokens: 15,
                cost: {
                  input: 0,
                  output: 0,
                  cacheRead: 0,
                  cacheWrite: 0,
                  total: 0,
                },
              },
              stopReason: "stop",
              timestamp: 1_777_770_010_000,
            },
          });
        }
      },
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Finish", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    await delay(0);

    const thread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(thread.status.type, "idle");
    assert.equal(thread.turns?.at(-1)?.status, "completed");

    const runtime = await provider.readSessionRuntime(created.thread);
    assert.equal(runtime?.turnId, undefined);
    assert.ok(
      liveEvents.some(
        (event) =>
          event.type === "turn_completed" &&
          event.turnId === created.activeTurnId &&
          event.status === "completed",
      ),
    );

    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)?.text, "Done.");
  });

  it("clears Pi running state when prompt resolves without terminal events", async () => {
    const liveEvents: Array<{ type: string; [key: string]: unknown }> = [];
    const listeners = new Set<(event: unknown) => void>();
    const cwd = nodePath.join(tempDir, "repo");
    await mkdir(cwd, { recursive: true });
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory(cwd);
    const fakeSession = {
      sessionId: "",
      sessionFile: null as string | null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        for (const listener of listeners) {
          listener({
            type: "message_update",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "Resolved from draft." }],
            },
            assistantMessageEvent: {
              type: "text_delta",
              contentIndex: 0,
              delta: "Resolved from draft.",
              partial: {
                role: "assistant",
                content: [{ type: "text", text: "Resolved from draft." }],
              },
            },
          });
        }
      },
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async (options: { sessionManager: SessionManager }) => {
        fakeSession.sessionId = options.sessionManager.getSessionId();
        fakeSession.sessionFile = options.sessionManager.getSessionFile() ?? null;
        fakeSession.sessionManager = options.sessionManager;
        return {
          session: fakeSession,
          extensionsResult: { extensions: [], errors: [], runtime: {} as never },
        };
      }) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    const created = await provider.createSession({
      cwd,
      input: [{ type: "text", text: "Handled before model", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    const runningThread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(runningThread.status.type, "running");
    assert.equal(runningThread.turns?.at(-1)?.status, "in_progress");

    await delay(150);

    const thread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(thread.status.type, "idle");
    assert.equal(thread.turns?.at(-1)?.status, "completed");

    const runtime = await provider.readSessionRuntime(created.thread);
    assert.equal(runtime?.turnId, undefined);
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)?.text, "Resolved from draft.");
    assert.equal(
      liveEvents.filter((event) => event.type === "turn_completed").length,
      1,
    );
    assert.ok(
      liveEvents.some(
        (event) =>
          event.type === "turn_completed" &&
          event.turnId === created.activeTurnId &&
          event.status === "completed",
      ),
    );
    const assistantCompletedIndex = liveEvents.findIndex(
      (event) =>
        event.type === "assistant_message_completed" &&
        event.turnId === created.activeTurnId,
    );
    const turnCompletedIndex = liveEvents.findIndex(
      (event) =>
        event.type === "turn_completed" &&
        event.turnId === created.activeTurnId,
    );
    assert.notEqual(assistantCompletedIndex, -1);
    assert.notEqual(turnCompletedIndex, -1);
    assert.ok(assistantCompletedIndex < turnCompletedIndex);

    assert.ok(fakeSession.sessionFile);
    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
      ],
      "2026-05-01T10:00:01.000Z",
    );

    const headerOnlyLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      headerOnlyLog.messages.map((message) => message.text),
      ["Handled before model", "Resolved from draft."],
    );
    const headerOnlyThread = await provider.readSessionThread(
      created.thread.id,
      false,
    );
    assert.equal(headerOnlyThread.preview, "Resolved from draft.");

    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Handled before model" }],
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
            content: [],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: {
              input: 5,
              output: 7,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 12,
              cost: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0,
              },
            },
            stopReason: "stop",
            timestamp: 1_777_770_002_000,
          },
        }),
      ],
      "2026-05-01T10:00:02.000Z",
    );

    const emptyHistoryLog = await provider.readSessionLog(created.thread);
    assert.equal(emptyHistoryLog.messages.at(-1)?.text, "Resolved from draft.");

    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Handled before model" }],
            timestamp: 1_777_770_001_000,
          },
        }),
        JSON.stringify(
          minimalPiAssistantMessage(
            "m2",
            "m1",
            "2026-05-01T10:00:02.000Z",
            "History truncated.",
            5,
            7,
            12,
            "length",
          ),
        ),
      ],
      "2026-05-01T10:00:02.500Z",
    );

    const lengthStopLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      lengthStopLog.messages.map((message) => message.text),
      ["Handled before model", "History truncated."],
    );

    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Handled before model" }],
            timestamp: 1_777_770_001_000,
          },
        }),
        JSON.stringify(
          minimalPiAssistantMessage(
            "m2",
            "m1",
            "2026-05-01T10:00:02.000Z",
            "History terminal.",
            5,
            7,
            12,
          ),
        ),
      ],
      "2026-05-01T10:00:03.000Z",
    );

    const refreshedLog = await provider.readSessionLog(created.thread);
    assert.equal(refreshedLog.messages.at(-1)?.text, "History terminal.");
  });

  it("preserves prompt-only Pi turns when prompt resolves without events", async () => {
    const cwd = nodePath.join(tempDir, "repo");
    await mkdir(cwd, { recursive: true });
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory(cwd);
    const fakeSession = {
      sessionId: "",
      sessionFile: null as string | null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt(_text: string) {},
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async (options: { sessionManager: SessionManager }) => {
        fakeSession.sessionId = options.sessionManager.getSessionId();
        fakeSession.sessionFile = options.sessionManager.getSessionFile() ?? null;
        fakeSession.sessionManager = options.sessionManager;
        return {
          session: fakeSession,
          extensionsResult: { extensions: [], errors: [], runtime: {} as never },
        };
      }) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd,
      input: [{ type: "text", text: "Prompt only", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    await delay(150);

    const thread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(thread.status.type, "idle");
    assert.equal(thread.turns?.at(-1)?.status, "completed");

    assert.ok(fakeSession.sessionFile);
    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
      ],
      "2026-05-01T10:00:01.000Z",
    );

    const reloadedLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      reloadedLog.messages.map((message) => message.text),
      ["Prompt only"],
    );
    const reloadedThread = await provider.readSessionThread(
      created.thread.id,
      false,
    );
    assert.equal(reloadedThread.preview, "Prompt only");
    assert.ok(
      reloadedThread.updatedAt >= thread.updatedAt,
      "sidecar history reload must not move updatedAt backward",
    );

    const repeatedPromptAtMs = (thread.updatedAt + 10) * 1000;
    const repeatedAnswerAtMs = repeatedPromptAtMs + 1_000;
    const repeatedMtime = new Date(repeatedAnswerAtMs + 1_000).toISOString();
    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
        JSON.stringify({
          type: "message",
          id: "later-user",
          parentId: null,
          timestamp: new Date(repeatedPromptAtMs).toISOString(),
          message: {
            role: "user",
            content: [{ type: "text", text: "Prompt only" }],
            timestamp: repeatedPromptAtMs,
          },
        }),
        JSON.stringify(
          minimalPiAssistantMessage(
            "later-assistant",
            "later-user",
            new Date(repeatedAnswerAtMs).toISOString(),
            "Later answer",
            10,
            20,
            30,
          ),
        ),
      ],
      repeatedMtime,
    );

    const laterLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      laterLog.messages.map((message) => message.text),
      ["Prompt only", "Prompt only", "Later answer"],
    );
    const laterThread = await provider.readSessionThread(created.thread.id, false);
    assert.equal(laterThread.preview, "Later answer");
  });

  it("matches empty-text preserved user sidecars on history reload", async () => {
    const cwd = nodePath.join(tempDir, "repo-empty-anchor");
    await mkdir(cwd, { recursive: true });
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory(cwd);
    const fakeSession = {
      sessionId: "",
      sessionFile: null as string | null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt(_text: string) {},
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async (options: { sessionManager: SessionManager }) => {
        fakeSession.sessionId = options.sessionManager.getSessionId();
        fakeSession.sessionFile = options.sessionManager.getSessionFile() ?? null;
        fakeSession.sessionManager = options.sessionManager;
        return {
          session: fakeSession,
          extensionsResult: { extensions: [], errors: [], runtime: {} as never },
        };
      }) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd,
      input: [{ type: "text", text: "   ", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    await delay(150);

    assert.ok(fakeSession.sessionFile);
    const historyUserAtMs = Date.now();
    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
          timestamp: new Date(historyUserAtMs - 1_000).toISOString(),
          cwd,
        }),
        JSON.stringify({
          type: "message",
          id: "empty-user",
          parentId: null,
          timestamp: new Date(historyUserAtMs).toISOString(),
          message: {
            role: "user",
            content: [{ type: "thinking", thinking: "image attachment" }],
            timestamp: historyUserAtMs,
          },
        }),
      ],
      new Date(historyUserAtMs + 1_000).toISOString(),
    );

    const reloadedLog = await provider.readSessionLog(created.thread);
    assert.equal(reloadedLog.messages.length, 1);
    assert.equal(reloadedLog.messages[0]?.role, "user");
    assert.equal(reloadedLog.messages[0]?.text, "");
  });

  it("finishes prompt-resolved Pi turns after a slow event queue drains", async () => {
    const listeners = new Set<(event: unknown) => void>();
    let resolveEventQueue!: () => void;
    const eventQueue = new Promise<void>((resolve) => {
      resolveEventQueue = resolve;
    });
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-slow-event-queue-1",
      sessionFile: null,
      sessionManager,
      _agentEventQueue: eventQueue,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        for (const listener of listeners) {
          listener({
            type: "message_update",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "Queued draft." }],
            },
            assistantMessageEvent: {
              type: "text_delta",
              contentIndex: 0,
              delta: "Queued draft.",
              partial: {
                role: "assistant",
                content: [{ type: "text", text: "Queued draft." }],
              },
            },
          });
        }
      },
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Slow queue", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    await delay(1_150);

    const pendingThread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(pendingThread.status.type, "running");
    assert.equal(pendingThread.turns?.at(-1)?.status, "in_progress");

    resolveEventQueue();
    await delay(50);

    const completedThread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(completedThread.status.type, "idle");
    assert.equal(completedThread.turns?.at(-1)?.status, "completed");
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)?.text, "Queued draft.");
  });

  it("materializes draft assistant output when terminal message_end has no final content", async () => {
    const liveEvents: Array<{ type: string; [key: string]: unknown }> = [];
    const listeners = new Set<(event: unknown) => void>();
    const cwd = nodePath.join(tempDir, "repo-terminal-draft");
    await mkdir(cwd, { recursive: true });
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory(cwd);
    const partialAssistant = {
      role: "assistant",
      content: [{ type: "text", text: "Done from draft." }],
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      usage: {
        input: 5,
        output: 10,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 15,
        cost: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          total: 0,
        },
      },
      timestamp: 1_777_770_010_000,
    };
    const fakeSession = {
      sessionId: "",
      sessionFile: null as string | null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        for (const listener of listeners) {
          listener({
            type: "message_update",
            message: partialAssistant,
            assistantMessageEvent: {
              type: "text_delta",
              contentIndex: 0,
              delta: "Done from draft.",
              partial: partialAssistant,
            },
          });
          listener({
            type: "message_end",
            message: {
              role: "assistant",
              content: [],
              provider: "anthropic",
              model: "claude-sonnet-4-5",
              usage: partialAssistant.usage,
              stopReason: "stop",
              timestamp: 1_777_770_011_000,
            },
          });
        }
      },
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async (options: { sessionManager: SessionManager }) => {
        fakeSession.sessionId = options.sessionManager.getSessionId();
        fakeSession.sessionFile = options.sessionManager.getSessionFile() ?? null;
        fakeSession.sessionManager = options.sessionManager;
        return {
          session: fakeSession,
          extensionsResult: { extensions: [], errors: [], runtime: {} as never },
        };
      }) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    provider.on("liveEvent", (event) => liveEvents.push(event as never));
    await provider.start();

    const created = await provider.createSession({
      cwd,
      input: [{ type: "text", text: "Finish", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    await delay(0);

    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)?.text, "Done from draft.");

    const completedMessageEvent = liveEvents.find(
      (event) => event.type === "assistant_message_completed",
    );
    assert.equal(
      (
        completedMessageEvent?.message as { text?: string } | undefined
      )?.text,
      "Done from draft.",
    );

    const thread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(thread.status.type, "idle");
    assert.equal(thread.turns?.at(-1)?.status, "completed");

    assert.ok(fakeSession.sessionFile);
    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Finish" }],
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
            content: [],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: partialAssistant.usage,
            stopReason: "stop",
            timestamp: 1_777_770_002_000,
          },
        }),
      ],
      "2026-05-01T10:00:02.000Z",
    );

    const snapshotLog = await provider.readSessionLog(created.thread);
    assert.equal(snapshotLog.messages.at(-1)?.text, "Done from draft.");

    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Finish" }],
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
              { type: "text", text: "Checking tool." },
              {
                type: "toolCall",
                id: "call-read",
                name: "read",
                arguments: { path: "README.md" },
              },
            ],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: partialAssistant.usage,
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
            content: [],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: partialAssistant.usage,
            stopReason: "stop",
            timestamp: 1_777_770_004_000,
          },
        }),
      ],
      "2026-05-01T10:00:03.000Z",
    );

    const toolLog = await provider.readSessionLog(created.thread);
    const toolActivity = toolLog.activities.find(
      (activity) => activity.type === "tool" && activity.toolName === "read",
    );
    const recoveredMessage = toolLog.messages.find(
      (message) => message.text === "Done from draft.",
    );
    assert.ok(toolActivity);
    assert.ok(recoveredMessage);
    assert.equal(toolLog.messages.at(-1)?.text, "Done from draft.");
    assert.ok(recoveredMessage.seq > toolActivity.seq);

    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Finish" }],
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
            content: [],
            errorMessage: "Overloaded",
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: partialAssistant.usage,
            stopReason: "error",
            timestamp: 1_777_770_002_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m3",
          parentId: "m2",
          timestamp: "2026-05-01T10:00:03.000Z",
          message: {
            role: "assistant",
            content: [],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: partialAssistant.usage,
            stopReason: "stop",
            timestamp: 1_777_770_003_000,
          },
        }),
      ],
      "2026-05-01T10:00:03.500Z",
    );

    const retryLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      retryLog.messages.map((message) => message.text),
      ["Finish", "Overloaded", "Done from draft."],
    );

    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Finish" }],
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
            content: [],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: partialAssistant.usage,
            stopReason: "stop",
            timestamp: 1_777_770_002_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m3",
          parentId: "m2",
          timestamp: "2026-05-01T10:00:03.000Z",
          message: {
            role: "user",
            content: [{ type: "text", text: "Next" }],
            timestamp: 1_777_770_003_000,
          },
        }),
        JSON.stringify(
          minimalPiAssistantMessage(
            "m4",
            "m3",
            "2026-05-01T10:00:04.000Z",
            "Done from draft.",
            3,
            4,
            7,
          ),
        ),
      ],
      "2026-05-01T10:00:04.000Z",
    );

    const appendedLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      appendedLog.messages.map((message) => message.text),
      ["Finish", "Done from draft.", "Next", "Done from draft."],
    );

    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Finish" }],
            timestamp: 1_777_770_001_000,
          },
        }),
        JSON.stringify(
          minimalPiAssistantMessage(
            "m2",
            "m1",
            "2026-05-01T10:00:02.000Z",
            "Done from draft.",
            5,
            10,
            15,
          ),
        ),
        JSON.stringify({
          type: "message",
          id: "m3",
          parentId: "m2",
          timestamp: "2026-05-01T10:00:03.000Z",
          message: {
            role: "bashExecution",
            command: "echo ok",
            output: "ok\n",
            exitCode: 0,
            cancelled: false,
            timestamp: 1_777_770_003_000,
          },
        }),
        JSON.stringify({
          type: "compaction",
          id: "c1",
          parentId: "m3",
          timestamp: "2026-05-01T10:00:04.000Z",
          summary: "Compacted after final answer.",
          firstKeptEntryId: "m1",
          tokensBefore: 1234,
        }),
      ],
      "2026-05-01T10:00:05.000Z",
    );

    const compactionLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      compactionLog.messages.map((message) => message.text),
      ["Finish", "Done from draft."],
    );
    assert.ok(
      compactionLog.activities.some(
        (activity) => activity.type === "command" && activity.command === "echo ok",
      ),
    );
  });

  it("does not preserve failed draft assistant output across history reloads", async () => {
    const listeners = new Set<(event: unknown) => void>();
    const cwd = nodePath.join(tempDir, "repo-terminal-error-draft");
    await mkdir(cwd, { recursive: true });
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory(cwd);
    const partialAssistant = {
      role: "assistant",
      content: [{ type: "text", text: "Failed draft." }],
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      usage: {
        input: 5,
        output: 10,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 15,
        cost: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          total: 0,
        },
      },
      timestamp: 1_777_770_010_000,
    };
    const fakeSession = {
      sessionId: "",
      sessionFile: null as string | null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: false,
      messages: [],
      subscribe(listener: (event: unknown) => void) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
      async prompt(_text: string) {
        for (const listener of listeners) {
          listener({
            type: "message_update",
            message: partialAssistant,
            assistantMessageEvent: {
              type: "text_delta",
              contentIndex: 0,
              delta: "Failed draft.",
              partial: partialAssistant,
            },
          });
          listener({
            type: "message_end",
            message: {
              role: "assistant",
              content: [],
              provider: "anthropic",
              model: "claude-sonnet-4-5",
              usage: partialAssistant.usage,
              stopReason: "error",
              timestamp: 1_777_770_011_000,
            },
          });
        }
      },
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async (options: { sessionManager: SessionManager }) => {
        fakeSession.sessionId = options.sessionManager.getSessionId();
        fakeSession.sessionFile = options.sessionManager.getSessionFile() ?? null;
        fakeSession.sessionManager = options.sessionManager;
        return {
          session: fakeSession,
          extensionsResult: { extensions: [], errors: [], runtime: {} as never },
        };
      }) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd,
      input: [{ type: "text", text: "Fail", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    await delay(0);

    const liveLog = await provider.readSessionLog(created.thread);
    assert.equal(liveLog.messages.at(-1)?.text, "Failed draft.");
    const thread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(thread.status.type, "idle");
    assert.equal(thread.turns?.at(-1)?.status, "failed");

    assert.ok(fakeSession.sessionFile);
    await writePiSessionHistory(
      fakeSession.sessionFile,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: created.thread.id,
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
            content: [{ type: "text", text: "Fail" }],
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
            content: [],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: partialAssistant.usage,
            stopReason: "error",
            timestamp: 1_777_770_002_000,
          },
        }),
      ],
      "2026-05-01T10:00:02.000Z",
    );

    const reloadedLog = await provider.readSessionLog(created.thread);
    assert.deepEqual(
      reloadedLog.messages.map((message) => message.text),
      ["Fail"],
    );
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
      createServices: (async () => fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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

  it("acknowledges active Pi steer sends after the next coalesced state save", async () => {
    const steerCalls: Array<{ text: string; images: unknown[] }> = [];
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const fakeSession = {
      sessionId: "pi-steer-pending-1",
      sessionFile: null,
      sessionManager,
      model: fakeModel,
      thinkingLevel: "medium",
      isStreaming: true,
      messages: [],
      subscribe() {
        return () => {};
      },
      async prompt(_text: string) {
        await new Promise<void>(() => {});
      },
      async steer(text: string, images?: unknown[]) {
        steerCalls.push({ text, images: images ?? [] });
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "First", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    assert.ok(created.activeTurnId);

    let saveStateCalls = 0;
    const saveStateReleases: Array<() => void> = [];
    const providerWithInternals = provider as unknown as {
      saveState: () => Promise<void>;
      persistEventually: () => void;
    };
    providerWithInternals.saveState = async () => {
      saveStateCalls += 1;
      await new Promise<void>((resolve) => {
        saveStateReleases.push(resolve);
      });
    };
    const waitForSaveStateCalls = async (count: number) => {
      for (let attempt = 0; attempt < 20; attempt++) {
        if (saveStateCalls >= count) {
          return;
        }
        await delay(5);
      }
      assert.fail(`Timed out waiting for ${count} Pi state save calls.`);
    };

    for (let i = 0; i < 5; i++) {
      providerWithInternals.persistEventually();
    }
    await waitForSaveStateCalls(1);

    const submitPromise = provider.submitInput({
      sessionId: created.thread.id,
      input: [{ type: "text", text: "Steer me", text_elements: [] }],
      activeTurnId: created.activeTurnId,
      overrides: emptyOverrides(),
    });
    try {
      await delay(0);
      assert.equal(steerCalls.length, 1);
      assert.equal(steerCalls[0]?.text, "Steer me");
      assert.equal(saveStateCalls, 1);

      saveStateReleases[0]?.();
      await waitForSaveStateCalls(2);
      const blockedUntilDurable = await Promise.race([
        submitPromise.then(() => "resolved" as const),
        delay(25).then(() => "waiting" as const),
      ]);
      assert.equal(blockedUntilDurable, "waiting");

      saveStateReleases[1]?.();
      const result = await Promise.race([
        submitPromise,
        delay(50).then(() => null),
      ]);
      assert.ok(result);
      assert.equal(result.mode, "steer");
      assert.equal(result.turnId, created.activeTurnId);
      assert.equal(saveStateCalls, 2);
    } finally {
      for (const release of saveStateReleases) {
        release();
      }
      providerWithInternals.saveState = async () => {
        saveStateCalls += 1;
      };
      await provider.close().catch(() => undefined);
      await delay(0);
    }
  });

  it("drains and reports pending Pi state persistence failures on close", async () => {
    const provider = new PiAgentProvider({ agentDir, stateDir });
    const stderr: string[] = [];
    provider.on("stderr", (line) => stderr.push(line));
    const providerWithInternals = provider as unknown as {
      saveState: () => Promise<void>;
      persistEventually: () => void;
    };
    providerWithInternals.saveState = async () => {
      throw new Error("disk full");
    };

    providerWithInternals.persistEventually();
    await provider.close();
    await delay(0);

    assert.equal(stderr.length, 2);
    assert.ok(stderr.includes("Pi provider state persistence failed: disk full"));
    assert.ok(stderr.includes("Pi provider final state persistence failed: disk full"));
  });

  it("retries later Pi state generations after a coalesced save failure", async () => {
    const provider = new PiAgentProvider({ agentDir, stateDir });
    const stderr: string[] = [];
    provider.on("stderr", (line) => stderr.push(line));
    const providerWithInternals = provider as unknown as {
      saveState: () => Promise<void>;
      persistEventually: () => void;
      persistSoon: () => Promise<void>;
    };
    let releaseFirstSave = () => {};
    let saveStateCalls = 0;
    providerWithInternals.saveState = async () => {
      saveStateCalls += 1;
      if (saveStateCalls === 1) {
        await new Promise<void>((resolve) => {
          releaseFirstSave = resolve;
        });
        throw new Error("transient write failure");
      }
    };

    providerWithInternals.persistEventually();
    for (let attempt = 0; attempt < 20; attempt++) {
      if (saveStateCalls >= 1) {
        break;
      }
      await delay(5);
    }
    assert.equal(saveStateCalls, 1);

    const durableSave = providerWithInternals.persistSoon();
    releaseFirstSave();
    await durableSave;
    await delay(0);

    assert.equal(saveStateCalls, 2);
    assert.deepEqual(stderr, [
      "Pi provider state persistence failed: transient write failure",
    ]);
    await provider.close();
  });

  it("drains Pi state saves queued during close", async () => {
    const provider = new PiAgentProvider({ agentDir, stateDir });
    const stderr: string[] = [];
    provider.on("stderr", (line) => stderr.push(line));
    const providerWithInternals = provider as unknown as {
      saveState: () => Promise<void>;
      persistEventually: () => void;
    };
    let queuedDuringClose = false;
    let saveStateCalls = 0;
    providerWithInternals.saveState = async () => {
      saveStateCalls += 1;
      if (saveStateCalls === 1) {
        throw new Error("initial write failure");
      }
      if (saveStateCalls === 2 && !queuedDuringClose) {
        queuedDuringClose = true;
        providerWithInternals.persistEventually();
      }
    };

    providerWithInternals.persistEventually();
    await delay(0);
    await provider.close();
    await delay(0);

    assert.equal(saveStateCalls, 3);
    assert.deepEqual(stderr, [
      "Pi provider state persistence failed: initial write failure",
    ]);
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Hello", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    await provider.close();

    const statePath = nodePath.join(stateDir, "sessions.json");
    const persisted = JSON.parse(await readFile(statePath, "utf8")) as {
      sessions?: Array<Record<string, unknown>>;
    };
    const persistedSession = persisted.sessions?.[0];
    assert.ok(persistedSession);
    persistedSession.activities = [
      {
        id: "stale-tool",
        type: "tool",
        turnId: created.activeTurnId,
        createdAt: 1_777_770_010_000,
        seq: 99,
        status: "in_progress",
        toolName: "read",
        title: "Read README",
        args: { path: "README.md" },
        output: "partial",
        result: null,
        isError: null,
        semantic: null,
      },
    ];
    persistedSession.runtime = {
      ...(persistedSession.runtime as Record<string, unknown> | null ?? {}),
      turnId: created.activeTurnId,
      telemetry: {
        ...((persistedSession.runtime as { telemetry?: Record<string, unknown> } | null)
          ?.telemetry ?? {}),
        compaction: {
          status: "running",
          startedAt: 1_777_770_011_000,
          updatedAt: 1_777_770_011_000,
        },
      },
    };
    await writeFile(statePath, JSON.stringify(persisted, null, 2));

    // start a fresh provider instance pointing at the same state dir
    const provider2 = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider2.start();

    const threads = await provider2.listSessionThreads({ limit: 10, archived: false });
    assert.equal(threads.length, 1);
    assert.equal(threads[0]?.id, created.thread.id);
    assert.equal(threads[0]?.status.type, "idle");
    const restoredThread = await provider2.readSessionThread(created.thread.id, true);
    assert.equal(restoredThread.turns?.[0]?.status, "interrupted");
    const restoredLog = await provider2.readSessionLog(restoredThread);
    assert.equal(restoredLog.activities[0]?.status, "failed");
    const restoredRuntime = await provider2.readSessionRuntime(restoredThread);
    assert.equal(restoredRuntime?.turnId ?? null, null);
    assert.equal(restoredRuntime?.telemetry?.compaction?.status, "failed");
  });

  it("restores partial Pi assistant output after restart", async () => {
    const fakeModel = {
      id: "claude-sonnet-4-5",
      name: "Claude Sonnet 4.5",
      provider: "anthropic",
      reasoning: true,
      input: ["text"],
    };
    const sessionManager = SessionManager.inMemory("/repo");
    const listeners = new Set<(event: unknown) => void>();
    const fakeSession = {
      sessionId: "pi-partial-restore-1",
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
        const partial = {
          role: "assistant",
          content: [
            { type: "thinking", thinking: "Still reasoning..." },
            { type: "text", text: "Partial Pi answer" },
          ],
          provider: "anthropic",
          model: "claude-sonnet-4-5",
          timestamp: 1_777_770_020_000,
        };
        for (const listener of listeners) {
          listener({
            type: "message_update",
            message: partial,
            assistantMessageEvent: {
              type: "text_delta",
              contentIndex: 1,
              delta: "Partial Pi answer",
              partial,
            },
          });
        }
      },
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd: "/repo",
      input: [{ type: "text", text: "Hello", text_elements: [] }],
      overrides: emptyOverrides(),
    });
    await provider.close();

    const provider2 = new PiAgentProvider({
      agentDir,
      stateDir,
      createServices: (async () =>
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
    });
    await provider2.start();

    const restoredThread = await provider2.readSessionThread(created.thread.id, true);
    assert.equal(restoredThread.status.type, "idle");
    assert.equal(restoredThread.turns?.[0]?.status, "interrupted");

    const restoredLog = await provider2.readSessionLog(restoredThread);
    assert.equal(restoredLog.messages.length, 2);
    const assistant = restoredLog.messages.at(-1);
    const thinking = assistant?.content.find(
      (block): block is { type: "thinking"; thinking: string } =>
        block.type === "thinking",
    );
    assert.equal(assistant?.role, "assistant");
    assert.equal(assistant?.text, "Partial Pi answer");
    assert.equal(thinking?.thinking, "Still reasoning...");
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: makeFakeSession("pi-multi-1"),
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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
    })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices;

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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
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
        fakeServices) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionServices,
      createSessionFromServices: (async () => ({
        session: fakeSession,
        extensionsResult: { extensions: [], errors: [], runtime: {} as never },
      })) as unknown as typeof import("@earendil-works/pi-coding-agent").createAgentSessionFromServices,
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

async function writePiSessionHistory(
  sessionPath: string,
  lines: string[],
  modifiedAt: string,
): Promise<void> {
  await writeFile(sessionPath, lines.join("\n") + "\n");
  const timestamp = new Date(modifiedAt);
  await utimes(sessionPath, timestamp, timestamp);
}

function minimalPiHistoryLines(cwd: string): string[] {
  return [
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
    JSON.stringify(
      minimalPiAssistantMessage(
        "m2",
        "m1",
        "2026-05-01T10:00:02.000Z",
        "Done.",
        10,
        20,
        30,
      ),
    ),
  ];
}

function minimalPiAssistantMessage(
  id: string,
  parentId: string,
  timestamp: string,
  text: string,
  inputTokens: number,
  outputTokens: number,
  totalTokens: number,
  stopReason = "stop",
): Record<string, unknown> {
  return {
    type: "message",
    id,
    parentId,
    timestamp,
    message: {
      role: "assistant",
      content: [{ type: "text", text }],
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      usage: {
        input: inputTokens,
        output: outputTokens,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens,
        cost: {
          input: 0.001,
          output: 0.002,
          cacheRead: 0,
          cacheWrite: 0,
          total: 0.003,
        },
      },
      stopReason,
      timestamp: Date.parse(timestamp),
    },
  };
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
