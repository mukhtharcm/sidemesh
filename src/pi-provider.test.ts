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
    assert.ok(eventTypes.includes("turn_completed"));

    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)?.text, "Done.");
    const activity = log.activities.find((candidate) => candidate.type === "tool");
    assert.equal(activity?.type, "tool");
  });
});

function piSessionDirForCwd(cwd: string, agentDir: string): string {
  const safePath = `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`;
  return nodePath.join(agentDir, "sessions", safePath);
}
