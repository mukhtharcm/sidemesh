import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import type { AgentPendingAction, AgentProviderLiveEvent } from "./agent-provider.js";
import {
  type CopilotSdkClient,
  type CopilotSdkClientFactory,
  type CopilotSdkMessageOptions,
  type CopilotSdkModelInfo,
  type CopilotSdkPermissionResult,
  type CopilotSdkResumeSessionConfig,
  type CopilotSdkSession,
  type CopilotSdkSessionConfig,
  type CopilotSdkSessionEvent,
  type CopilotSdkSessionMode,
  type CopilotSdkSessionMetadata,
} from "./copilot-sdk-client.js";
import { CopilotAgentProvider } from "./copilot-provider.js";

describe("Copilot provider", () => {
  it("lists SDK sessions, reads SDK history, and resumes through the SDK", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-sdk-history-"),
    );
    try {
      const sessionId = "11111111-2222-4333-8444-555555555555";
      const sdk = new FakeCopilotSdkClient({
        sessions: [
          {
            metadata: {
              sessionId,
              startTime: new Date("2026-04-01T00:00:00.000Z"),
              modifiedTime: new Date("2026-04-01T00:05:00.000Z"),
              summary: "SDK Copilot Session",
              isRemote: false,
              context: {
                cwd: dir,
                repository: "your-org/sidemesh",
                branch: "main",
              },
            },
            events: [
              event("session.model_change", { newModel: "gpt-5.2" }),
              event("session.mode_changed", { newMode: "autopilot" }),
              event("session.usage_info", {
                currentTokens: 3200,
                tokenLimit: 128000,
                messagesLength: 12,
                conversationTokens: 2800,
                systemTokens: 240,
                toolDefinitionsTokens: 160,
              }),
              event("user.message", { content: "hello sdk" }, "user-1"),
              event(
                "assistant.message",
                {
                  messageId: "assistant-message-1",
                  content: "hello back",
                },
                "assistant-1",
              ),
              event("tool.execution_start", {
                toolCallId: "tool-1",
                toolName: "view",
                arguments: { path: "README.md" },
              }),
              event("tool.execution_complete", {
                toolCallId: "tool-1",
                toolName: "view",
                success: true,
                result: { content: "README contents" },
              }),
              event("assistant.usage", {
                model: "gpt-5.2",
                inputTokens: 333,
                outputTokens: 44,
                reasoningTokens: 12,
                duration: 912,
                reasoningEffort: "medium",
                copilotUsage: {
                  totalNanoAiu: 77,
                  tokenDetails: [],
                },
              }),
              event("session.compaction_start", {
                conversationTokens: 2800,
                systemTokens: 240,
                toolDefinitionsTokens: 160,
              }),
              event("session.compaction_complete", {
                success: true,
                preCompactionTokens: 3200,
                postCompactionTokens: 1800,
                tokensRemoved: 1400,
                messagesRemoved: 4,
                compactionTokensUsed: {
                  model: "gpt-5.2",
                  duration: 650,
                  inputTokens: 120,
                  outputTokens: 30,
                  copilotUsage: {
                    totalNanoAiu: 11,
                    tokenDetails: [],
                  },
                },
              }),
            ],
          },
        ],
      });
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const sessions = await provider.listSessionThreads!({
        limit: 10,
        archived: false,
      });
      assert.equal(sessions.length, 1);
      assert.equal(sessions[0]?.id, sessionId);
      assert.equal(sessions[0]?.preview, "SDK Copilot Session");
      assert.equal(sessions[0]?.cwd, dir);
      assert.equal(sessions[0]?.gitInfo?.branch, "main");

      const log = await provider.readSessionLog!(sessions[0]!);
      assert.equal(log.messages.length, 2);
      assert.equal(log.messages[0]?.text, "hello sdk");
      assert.equal(log.messages[1]?.text, "hello back");
      assert.equal(log.activities.length, 2);
      assert.equal(log.activities[0]?.type, "tool");
      assert.equal(log.activities[0]?.semantic?.action, "mode_change");
      assert.deepEqual(log.activities[0]?.semantic?.targets, [
        { type: "mode", value: "autopilot" },
      ]);
      assert.equal(log.activities[1]?.type, "tool");
      assert.equal(log.activities[1]?.semantic?.category, "filesystem");
      assert.equal(log.activities[1]?.semantic?.action, "read");
      assert.deepEqual(log.activities[1]?.semantic?.targets, [
        { type: "file", path: "README.md", access: "read", role: "target" },
      ]);
      assert.equal(log.runtime?.model, "gpt-5.2");
      assert.equal(log.runtime?.mode, "autopilot");
      assert.equal(log.runtime?.telemetry?.contextWindow?.currentTokens, 3200);
      assert.equal(log.runtime?.telemetry?.lastUsage?.inputTokens, 333);
      assert.equal(log.runtime?.telemetry?.compaction?.tokensRemoved, 1400);

      const completed = waitForTurnCompleted(provider);
      await provider.submitInput!({
        sessionId,
        input: [{ type: "text", text: "continue sdk", text_elements: [] }],
        activeTurnId: null,
        overrides: emptyOverrides(),
      });
      await completed;

      assert.equal(sdk.resumed[0]?.sessionId, sessionId);
      const updated = await provider.readSessionLog!(sessions[0]!);
      assert.equal(updated.messages.at(-1)?.text, "resumed: continue sdk");
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("runs a text turn through SDK createSession/send", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      assert.equal(await provider.getVersion(), "GitHub Copilot SDK 9.9.9");

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.messages.length, 2);
      assert.equal(log.messages[0]?.role, "user");
      assert.equal(log.messages[0]?.text, "hello");
      assert.equal(log.messages[1]?.role, "assistant");
      assert.equal(log.messages[1]?.text, "copilot says: hello");
      assert.equal(log.runtime?.modelProvider, "copilot");
      assert.equal(log.runtime?.model, "gpt-5.2");
      assert.equal(log.runtime?.reasoningEffort, "medium");

      assert.equal(sdk.created.length, 1);
      assert.equal(sdk.created[0]?.config.model, undefined);
      assert.equal(sdk.created[0]?.config.reasoningEffort, undefined);
      assert.equal(sdk.created[0]?.config.enableConfigDiscovery, true);
      assert.equal(sdk.created[0]?.session.sent[0]?.prompt, "hello");

      const sessions = await provider.listSessionThreads!({
        limit: 10,
        archived: false,
      });
      assert.equal(sessions.length, 1);
      assert.equal(sessions[0]?.source, "copilot");
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("normalizes Copilot intent and planning signals without leaking internal tools", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-intent-plan-history-"),
    );
    try {
      const sessionId = "99999999-2222-4333-8444-555555555555";
      const sdk = new FakeCopilotSdkClient({
        sessions: [
          {
            metadata: {
              sessionId,
              startTime: new Date("2026-04-01T00:00:00.000Z"),
              modifiedTime: new Date("2026-04-01T00:05:00.000Z"),
              summary: "Planning session",
              isRemote: false,
              context: {
                cwd: dir,
                repository: "your-org/sidemesh",
                branch: "main",
              },
            },
            events: [
              event("assistant.intent", {
                intent: "Reviewing the repository and sketching a plan.",
              }),
              event(
                "assistant.message",
                {
                  messageId: "assistant-tool-request",
                  content: "",
                  toolRequests: [
                    {
                      toolCallId: "ask-user-tool-1",
                      name: "ask_user",
                      toolTitle: "Ask user",
                      intentionSummary:
                        "Ask the user which environment should be targeted.",
                    },
                  ],
                },
                "assistant-tool-request",
              ),
              event("tool.execution_start", {
                toolCallId: "ask-user-tool-1",
                toolName: "ask_user",
                arguments: {
                  question: "Which environment?",
                  choices: ["staging", "production"],
                },
              }),
              event("tool.execution_complete", {
                toolCallId: "ask-user-tool-1",
                toolName: "ask_user",
                success: true,
                result: {
                  answer: "staging",
                  wasFreeform: false,
                },
              }),
              event("session.plan_changed", { operation: "update" }),
              event("session.task_complete", {
                success: true,
                summary: "Captured the implementation plan and started execution.",
              }),
              event(
                "assistant.message",
                {
                  messageId: "assistant-final",
                  content: "Moving on to implementation.",
                },
                "assistant-final",
              ),
            ],
          },
        ],
      });
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const sessions = await provider.listSessionThreads!({
        limit: 10,
        archived: false,
      });
      const log = await provider.readSessionLog!(sessions[0]!);

      assert.equal(log.messages.length, 2);
      assert.equal(log.messages[0]?.phase, "commentary");
      assert.match(
        log.messages[0]?.text ?? "",
        /reviewing the repository and sketching a plan/i,
      );
      assert.equal(log.messages[1]?.text, "Moving on to implementation.");

      assert.equal(log.activities.length, 2);
      const [planActivity, taskActivity] = log.activities;
      assert.equal(planActivity?.type, "plan");
      assert.equal(taskActivity?.type, "task");
      if (planActivity?.type !== "plan" || taskActivity?.type !== "task") {
        assert.fail("Expected plan and task activities");
      }
      assert.equal(planActivity.title, "Updated session plan");
      assert.equal(
        taskActivity.title,
        "Captured the implementation plan and started execution.",
      );
      assert.ok(
        log.activities.every(
          (activity) => activity.type !== "tool" || activity.toolName != "ask_user",
        ),
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("migrates persisted Copilot pseudo-tool activities on load", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-stored-pseudo-tools-"),
    );
    try {
      const stateDir = nodePath.join(dir, "state");
      const sessionId = "stored-pseudo-tools";
      await mkdir(stateDir, { recursive: true });
      await writeFile(
        nodePath.join(stateDir, "sessions.json"),
        JSON.stringify({
          sessions: [
            {
              thread: {
                id: sessionId,
                name: null,
                preview: "stored",
                cwd: dir,
                createdAt: 1,
                updatedAt: 1,
                source: "copilot",
                path: null,
                status: { type: "idle" },
                turns: [],
              },
              messages: [],
              activities: [
                storedToolActivity({
                  id: "ask-user-tool",
                  toolName: "ask_user",
                  title: "ask_user {\"question\":\"Should I start?\"}",
                  args: { question: "Should I start?" },
                  seq: 0,
                }),
                storedToolActivity({
                  id: "report-intent-tool",
                  toolName: "tool",
                  title: "report_intent {\"intent\":\"Working\"}",
                  args: { intent: "Working" },
                  seq: 1,
                }),
                storedToolActivity({
                  id: "plan-tool",
                  toolName: "update_plan",
                  title: "update_plan",
                  result: { content: "Plan updated" },
                  seq: 2,
                }),
                storedToolActivity({
                  id: "read-tool",
                  toolName: "view",
                  title: "Read README.md",
                  args: { path: "README.md" },
                  seq: 3,
                }),
              ],
              turns: [],
              runtime: null,
              nextSeq: 4,
              copilotSessionId: sessionId,
              copilotSessionCreated: false,
            },
          ],
        }),
      );
      const provider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(new FakeCopilotSdkClient()),
      });
      await provider.start();

      const log = await provider.readSessionLog!({
        id: sessionId,
        name: null,
        preview: "",
        cwd: dir,
        createdAt: 0,
        updatedAt: 0,
        source: "copilot",
        path: null,
        status: { type: "idle" },
      });

      assert.deepEqual(
        log.activities.map((activity) => ({
          id: activity.id,
          type: activity.type,
          title:
            activity.type === "tool" || activity.type === "system_event"
              ? activity.title
              : undefined,
          ...(activity.type === "system_event"
            ? { detail: activity.detail }
            : {}),
        })),
        [
          {
            id: "question:ask-user-tool",
            type: "system_event",
            title: "Model asked: Should I start?",
            detail: null,
          },
          { id: "plan-tool", type: "plan", title: undefined },
          { id: "read-tool", type: "tool", title: "Read README.md" },
        ],
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("maps Copilot reasoning, subagents, plan review, and system events into neutral activities", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-neutral-events-history-"),
    );
    try {
      const sessionId = "aaaaaaaa-2222-4333-8444-555555555555";
      const sdk = new FakeCopilotSdkClient({
        sessions: [
          {
            metadata: {
              sessionId,
              startTime: new Date("2026-04-01T00:00:00.000Z"),
              modifiedTime: new Date("2026-04-01T00:05:00.000Z"),
              summary: "Neutral events",
              isRemote: false,
              context: { cwd: dir, repository: "your-org/sidemesh" },
            },
            events: [
              event("assistant.reasoning_delta", {
                reasoningId: "reasoning-1",
                deltaContent: "Thinking ",
              }),
              event("assistant.reasoning_delta", {
                reasoningId: "reasoning-1",
                deltaContent: "carefully",
              }),
              event("assistant.reasoning", {
                reasoningId: "reasoning-1",
                content: "Thinking carefully",
              }),
              event("subagent.started", {
                toolCallId: "subagent-tool-1",
                agentName: "repo-explorer",
                agentDisplayName: "Repo Explorer",
                agentDescription: "Inspect repository structure.",
              }),
              event("subagent.completed", {
                toolCallId: "subagent-tool-1",
                agentName: "repo-explorer",
                agentDisplayName: "Repo Explorer",
                durationMs: 1200,
                model: "gpt-5.2",
                totalTokens: 900,
                totalToolCalls: 3,
              }),
              event("exit_plan_mode.requested", {
                requestId: "plan-review-1",
                summary: "Ready to implement the neutral timeline plan.",
                planContent: "# Plan\n\nKeep provider concepts neutral.",
                recommendedAction: "approve",
                actions: ["approve", "edit", "reject"],
              }),
              event("exit_plan_mode.completed", {
                requestId: "plan-review-1",
                approved: false,
                feedback: "Keep it extensible across providers.",
                selectedAction: "edit",
              }),
              event("session.warning", {
                warningType: "mcp",
                message: "MCP server needs attention.",
                url: "https://example.com/mcp",
              }),
              event("mcp.oauth_required", {
                requestId: "oauth-1",
                serverName: "Linear",
                serverUrl: "https://mcp.example.com",
              }),
              event("mcp.oauth_completed", {
                requestId: "oauth-1",
              }),
              event("sampling.requested", {
                requestId: "sampling-1",
                mcpRequestId: 1,
                serverName: "Docs",
              }),
              event("sampling.completed", {
                requestId: "sampling-1",
              }),
              event("system.message", {
                role: "system",
                name: "core",
                content: "do not show raw system prompt",
              }),
              event("system.notification", {
                content:
                  "<system_notification>New background update.</system_notification>",
                kind: {
                  type: "new_inbox_message",
                  entryId: "inbox-1",
                  senderName: "background",
                  senderType: "ambient-agent",
                  summary: "Background update",
                },
              }),
            ],
          },
        ],
      });
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const [session] = await provider.listSessionThreads!({
        limit: 10,
        archived: false,
      });
      const log = await provider.readSessionLog!(session!);

      const reasoning = log.activities.find((activity) => activity.type === "reasoning");
      assert.equal(reasoning?.type, "reasoning");
      assert.equal(reasoning?.status, "completed");
      assert.equal(reasoning?.content, "Thinking carefully");

      const subagent = log.activities.find((activity) => activity.type === "subagent");
      assert.equal(subagent?.type, "subagent");
      assert.equal(subagent?.action, "completed");
      assert.equal(subagent?.description, "Inspect repository structure.");
      assert.equal(subagent?.totalToolCalls, 3);

      const plan = log.activities.find(
        (activity) => activity.type === "plan" && activity.action === "rejected",
      );
      assert.equal(plan?.type, "plan");
      assert.equal(plan?.content, "# Plan\n\nKeep provider concepts neutral.");
      assert.equal(plan?.summary, "Keep it extensible across providers.");

      const oauth = log.activities.find((activity) => activity.id === "copilot-mcp-oauth:oauth-1");
      assert.equal(oauth?.type, "system_event");
      assert.equal(oauth?.status, "completed");
      assert.equal(oauth?.title, "MCP authentication completed");

      const sampling = log.activities.find((activity) => activity.id === "copilot-sampling:sampling-1");
      assert.equal(sampling?.type, "system_event");
      assert.equal(sampling?.status, "completed");

      const systemMessage = log.activities.find(
        (activity) => activity.id.startsWith("copilot-system-message:"),
      );
      assert.equal(systemMessage?.type, "system_event");
      assert.doesNotMatch(systemMessage?.detail ?? "", /raw system prompt/);

      assert.ok(
        log.activities.some(
          (activity) =>
            activity.type === "system_event" &&
            activity.title === "New inbox message" &&
            activity.detail === "New background update.",
        ),
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("streams neutral Copilot activities during live turns", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-neutral-events-live-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const updated: string[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "activity_updated") {
          updated.push(liveEvent.activity.type);
        }
      });

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "neutral events", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await completed;

      assert.ok(updated.includes("reasoning"));
      assert.ok(updated.includes("subagent"));
      assert.ok(updated.includes("plan"));
      assert.ok(updated.includes("system_event"));

      const log = await provider.readSessionLog!(created.thread);
      assert.ok(log.activities.some((activity) => activity.type === "reasoning"));
      assert.ok(log.activities.some((activity) => activity.type === "subagent"));
      assert.ok(log.activities.some((activity) => activity.type === "plan"));
      assert.ok(
        log.activities.some(
          (activity) =>
            activity.type === "system_event" &&
            activity.title === "Copilot warning: mcp",
        ),
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("emits runtime updates for usage telemetry during live turns", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-runtime-telemetry-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const runtimeUpdates: AgentProviderLiveEvent[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "runtime_updated") {
          runtimeUpdates.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello telemetry", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await completed;

      assert.ok(runtimeUpdates.length >= 2);
      const runtime = await provider.readSessionRuntime!(created.thread);
      assert.equal(runtime?.telemetry?.contextWindow?.tokenLimit, 128000);
      assert.equal(runtime?.telemetry?.lastUsage?.outputTokens, 27);
      assert.equal(runtime?.telemetry?.lastUsage?.totalNanoAiu, 42);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("runs manual compaction through the Copilot SDK", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-compact-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await completed;

      const result = await provider.compactSession!(created.thread.id);
      const runtime = await provider.readSessionRuntime!(created.thread);

      assert.deepEqual(result, {
        success: true,
        tokensRemoved: 2048,
        messagesRemoved: 8,
      });
      assert.equal(sdk.created[0]?.session.compactCallCount, 1);
      assert.equal(runtime?.telemetry?.compaction?.status, "completed");
      assert.equal(runtime?.telemetry?.compaction?.tokensRemoved, 2048);
      assert.equal(runtime?.telemetry?.compaction?.messagesRemoved, 8);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("lists and toggles Copilot skills through SDK discovery", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-skills-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient({
        skills: [
          {
            name: "frontend-design",
            description: "Responsive UI patterns.",
            source: "project",
            enabled: true,
            userInvocable: true,
            path: nodePath.join(dir, ".github/skills/frontend-design/SKILL.md"),
            projectPath: dir,
          },
          {
            name: "release-checks",
            description: "Pre-release validation steps.",
            source: "personal-copilot",
            enabled: false,
            userInvocable: true,
            path: nodePath.join(
              process.env.HOME ?? dir,
              ".copilot/skills/release-checks/SKILL.md",
            ),
          },
        ],
      });
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const catalog = await provider.listSkills!({
        cwd: dir,
        forceReload: false,
      });
      assert.deepEqual(
        catalog.skills.map((skill) => ({
          name: skill.name,
          scope: skill.scope,
          enabled: skill.enabled,
        })),
        [
          { name: "frontend-design", scope: "repo", enabled: true },
          { name: "release-checks", scope: "user", enabled: false },
        ],
      );

      const liveEvents: string[] = [];
      provider.on("liveEvent", (event) => {
        if (event.type === "skills_changed") {
          liveEvents.push(event.type);
        }
      });

      await provider.writeSkillConfig!({
        name: "release-checks",
        path: null,
        enabled: true,
      });
      assert.deepEqual([...sdk.disabledSkills], []);
      assert.deepEqual(liveEvents, ["skills_changed"]);

      await provider.writeSkillConfig!({
        name: null,
        path: nodePath.join(dir, ".github/skills/frontend-design/SKILL.md"),
        enabled: false,
      });
      assert.deepEqual([...sdk.disabledSkills], ["frontend-design"]);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("formats Copilot skill inputs as slash invocations", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-skill-input-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [
          { type: "text", text: "Use this skill", text_elements: [] },
          {
            type: "skill",
            name: "frontend-design",
            path: "/tmp/skill/SKILL.md",
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      assert.equal(
        sdk.created[0]?.session.sent[0]?.prompt,
        "Use this skill\n/frontend-design",
      );
      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.messages[0]?.text, "Use this skill\n/frontend-design");
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("sends inline and local image attachments through the SDK", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-image-input-"),
    );
    try {
      const localImagePath = nodePath.join(dir, "screenshot.png");
      await writeFile(localImagePath, "fake image");

      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [
          { type: "text", text: "describe this", text_elements: [] },
          { type: "image", url: "data:image/png;base64,ZmFrZQ==" },
          { type: "localImage", path: localImagePath },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      assert.equal(sdk.created[0]?.session.sent[0]?.prompt, "describe this");
      assert.deepEqual(sdk.created[0]?.session.sent[0]?.attachments, [
        {
          type: "blob",
          data: "ZmFrZQ==",
          mimeType: "image/png",
          displayName: "pasted-image.png",
        },
        {
          type: "file",
          path: localImagePath,
          displayName: "screenshot.png",
        },
      ]);

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.messages[0]?.text, "describe this");
      assert.deepEqual(log.messages[0]?.attachments, [
        { type: "image", url: "data:image/png;base64,ZmFrZQ==" },
        { type: "localImage", path: localImagePath },
      ]);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("fetches remote image URLs into SDK blob attachments", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-remote-image-"),
    );
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (input: string | URL | Request) => {
      assert.equal(String(input), "https://example.com/cat.png");
      return new Response(Uint8Array.from([1, 2, 3]), {
        status: 200,
        headers: { "content-type": "image/png; charset=binary" },
      });
    };
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [{ type: "image", url: "https://example.com/cat.png" }],
        overrides: emptyOverrides(),
      });
      await completed;

      assert.equal(
        sdk.created[0]?.session.sent[0]?.prompt,
        "Please inspect the attached image.",
      );
      assert.deepEqual(sdk.created[0]?.session.sent[0]?.attachments, [
        {
          type: "blob",
          data: "AQID",
          mimeType: "image/png",
          displayName: "cat.png",
        },
      ]);
    } finally {
      globalThis.fetch = originalFetch;
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("lists SDK model metadata and filters disabled models", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-model-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient({
        models: [
          sdkModel("claude-haiku-4.5", {
            name: "Claude Haiku 4.5",
            multiplier: 1,
          }),
          sdkModel("deprecated-model", {
            name: "Deprecated Model",
            policy: "disabled",
          }),
          sdkModel("vision-model", {
            name: "Vision Model",
            vision: true,
            reasoning: false,
          }),
        ],
      });
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        configuredModel: "safe-test-model",
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const models = await provider.listModels!({
        cwd: dir,
        profile: null,
        provider: null,
      });
      assert.deepEqual(
        models.map((model) => ({
          model: model.model,
          source: model.source,
          isDefault: model.isDefault,
          inputModalities: model.inputModalities,
          reasoningEffortControl: model.reasoningEffortControl,
        })),
        [
          {
            model: "auto",
            source: "sdk",
            isDefault: false,
            inputModalities: ["text"],
            reasoningEffortControl: "provider",
          },
          {
            model: "safe-test-model",
            source: "config",
            isDefault: true,
            inputModalities: ["text"],
            reasoningEffortControl: "client",
          },
          {
            model: "claude-haiku-4.5",
            source: "sdk",
            isDefault: false,
            inputModalities: ["text"],
            reasoningEffortControl: "client",
          },
          {
            model: "vision-model",
            source: "sdk",
            isDefault: false,
            inputModalities: ["text", "image"],
            reasoningEffortControl: "provider",
          },
        ],
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("forwards explicitly configured SDK model controls", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-configured-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        configuredModel: "safe-test-model",
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await completed;

      assert.equal(sdk.created[0]?.config.model, "safe-test-model");
      assert.equal(
        sdk.created[0]?.session.selectedModels[0]?.model,
        "safe-test-model",
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("applies Copilot session mode overrides through the SDK", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-mode-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: {
          ...emptyOverrides(),
          mode: "plan",
        },
      });
      await completed;

      assert.deepEqual(sdk.created[0]?.session.selectedModes, ["plan"]);
      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.runtime?.mode, "plan");
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("falls back to SDK auto instead of stale persisted Copilot model defaults", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-stale-model-test-"),
    );
    try {
      const stateDir = nodePath.join(dir, "state");
      const sessionId = "stale-session";
      await mkdir(stateDir, { recursive: true });
      await writeFile(
        nodePath.join(stateDir, "sessions.json"),
        JSON.stringify({
          sessions: [
            {
              thread: {
                id: sessionId,
                name: null,
                preview: "stale",
                cwd: dir,
                createdAt: 1,
                updatedAt: 1,
                source: "copilot",
                path: null,
                status: { type: "idle" },
                turns: [],
              },
              messages: [],
              activities: [],
              turns: [],
              runtime: {
                model: "gpt-5.2",
                modelProvider: "copilot",
                reasoningEffort: "medium",
              },
              nextSeq: 0,
              copilotSessionId: sessionId,
              copilotSessionCreated: true,
            },
          ],
        }),
      );

      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      await provider.submitInput!({
        sessionId,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        activeTurnId: null,
        overrides: emptyOverrides(),
      });
      await completed;

      assert.equal(sdk.resumed[0]?.config.model, undefined);
      assert.equal(sdk.resumed[0]?.session.selectedModels.length, 0);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("bridges SDK permission requests into Sidemesh pending actions", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-approval-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const actionOpened = waitForActionOpened(provider);
      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "needs approval", text_elements: [] }],
        overrides: emptyOverrides(),
      });

      const action = await actionOpened;
      assert.equal(action.kind, "command");
      assert.equal(action.detail, "echo approval");
      assert.deepEqual(action.approval?.targets, [
        {
          type: "command",
          command: "echo approval",
          identifiers: ["echo"],
          possiblePaths: [],
          possibleUrls: [],
          intention: "Run test approval command",
          warning: undefined,
        },
      ]);
      assert.equal(provider.respondToPendingAction!(action, "accept"), true);
      await completed;

      const log = await provider.readSessionLog!({
        id: action.sessionId,
        name: null,
        preview: "",
        cwd: dir,
        createdAt: 0,
        updatedAt: 0,
        source: "copilot",
        path: null,
        status: { type: "idle" },
      });
      assert.equal(log.messages.at(-1)?.text, "copilot says: needs approval");
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("bridges Copilot ask-user requests into Sidemesh pending actions", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-ask-user-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const opened = waitForActionOpened(provider, "user_input");
      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "please ask user", text_elements: [] }],
        overrides: emptyOverrides(),
      });

      const action = await opened;
      assert.equal(action.userInput?.question, "Which environment should I use?");
      assert.deepEqual(action.userInput?.choices, ["staging", "production"]);
      assert.equal(
        provider.respondToPendingAction(action, {
          answer: "staging",
          wasFreeform: false,
        }),
        true,
      );
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.deepEqual(
        log.activities.map((activity) => ({
          type: activity.type,
          status: activity.status,
          title: activity.type === "system_event" ? activity.title : null,
          detail: activity.type === "system_event" ? activity.detail : null,
        })),
        [
          {
            type: "system_event",
            status: "completed",
            title: "Model asked: Which environment should I use?",
            detail: "Options: staging / production\nYou answered: staging",
          },
        ],
      );
      assert.match(log.messages.at(-1)?.text ?? "", /staging/);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("bridges Copilot elicitation requests into Sidemesh pending actions", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-elicitation-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const opened = waitForActionOpened(provider, "elicitation");
      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "needs elicitation", text_elements: [] }],
        overrides: emptyOverrides(),
      });

      const action = await opened;
      assert.equal(action.elicitation?.mode, "form");
      assert.equal(action.elicitation?.fields.length, 2);
      assert.equal(
        provider.respondToPendingAction(action, {
          action: "accept",
          content: {
            region: "us-east",
            dryRun: true,
          },
        }),
        true,
      );
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.match(log.messages.at(-1)?.text ?? "", /us-east/);
      assert.match(log.messages.at(-1)?.text ?? "", /dryRun/);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("stores SDK tool events as tool activities", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-tools-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "use tool", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.activities.length, 1);
      assert.equal(log.activities[0]?.type, "tool");
      assert.equal(log.activities[0]?.status, "completed");
      assert.match(log.activities[0]?.output ?? "", /tool output/);
      assert.equal(log.activities[0]?.semantic?.category, "filesystem");
      assert.equal(log.activities[0]?.semantic?.action, "read");
      assert.deepEqual(log.activities[0]?.semantic?.targets, [
        { type: "file", path: "README.md", access: "read", role: "target" },
      ]);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("uses SDK immediate mode for active-turn steering", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-steer-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient({ holdResponses: true });
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "initial task", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await waitFor(() => sdk.created[0]?.session.sent.length === 1);

      const steer = await provider.submitInput({
        sessionId: created.thread.id,
        input: [{ type: "text", text: "course correct", text_elements: [] }],
        activeTurnId: created.activeTurnId,
        overrides: emptyOverrides(),
      });

      assert.equal(steer.mode, "steer");
      assert.equal(steer.turnId, created.activeTurnId);
      assert.equal(sdk.created[0]?.session.sent.length, 2);
      assert.equal(sdk.created[0]?.session.sent[1]?.mode, "immediate");
      assert.equal(
        sdk.created[0]?.session.sent[1]?.prompt,
        "course correct",
      );

      const completed = waitForTurnCompleted(provider);
      sdk.flushHeldResponses();
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.messages[0]?.text, "initial task");
      assert.equal(log.messages[1]?.text, "course correct");
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("does not send reasoning effort when Copilot auto model is selected", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-auto-test-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: {
          ...emptyOverrides(),
          model: "auto",
          reasoningEffort: "medium",
        },
      });
      await completed;

      assert.equal(sdk.created[0]?.config.model, undefined);
      assert.equal(sdk.created[0]?.config.reasoningEffort, undefined);
      assert.equal(sdk.created[0]?.session.selectedModels.length, 0);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("auto-approves Copilot permission requests when approval policy is never", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-approval-never-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      const liveEventTypes: string[] = [];
      provider.on("liveEvent", (event) => {
        liveEventTypes.push(event.type);
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "approval please", text_elements: [] }],
        overrides: {
          ...emptyOverrides(),
          approvalPolicy: "never",
        },
      });
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.runtime?.approvalPolicy, "never");
      assert.equal(liveEventTypes.includes("action_opened"), false);
      assert.match(
        log.messages.at(-1)?.text ?? "",
        /copilot says: approval please/,
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("lets session approval overrides beat Copilot allow-all defaults", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-approval-override-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        allowAll: true,
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const opened = waitForActionOpened(provider);
      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "approval override", text_elements: [] }],
        overrides: {
          ...emptyOverrides(),
          approvalPolicy: "on-request",
        },
      });

      const action = await opened;
      assert.equal(provider.respondToPendingAction(action, "accept"), true);
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.runtime?.approvalPolicy, "on-request");
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("finishes the turn when SDK session creation fails", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-create-failure-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient({
        createSessionError: new Error("SDK unavailable"),
      });
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await completed;

      const thread = await provider.readSessionThread!(created.thread.id, true);
      const log = await provider.readSessionLog!(thread);
      assert.equal(thread.turns?.[0]?.status, "failed");
      assert.match(log.messages.at(-1)?.text ?? "", /SDK unavailable/);
    } finally {
      await settleProviderWrites();
      await rm(dir, { recursive: true, force: true });
    }
  });
});

class FakeCopilotSdkClient implements CopilotSdkClient {
  public readonly created: Array<{
    config: CopilotSdkSessionConfig;
    session: FakeCopilotSdkSession;
  }> = [];
  public readonly resumed: Array<{
    sessionId: string;
    config: CopilotSdkResumeSessionConfig;
    session: FakeCopilotSdkSession;
  }> = [];
  public readonly disabledSkills = new Set<string>();
  private readonly sessions = new Map<string, FakeCopilotSdkSession>();
  private readonly models: CopilotSdkModelInfo[];
  private readonly createSessionError: Error | null;
  private readonly discoveredSkills: Array<{
    name: string;
    description: string;
    source: string;
    enabled: boolean;
    userInvocable: boolean;
    path?: string;
    projectPath?: string;
  }>;
  private readonly sessionMetadata = new Map<
    string,
    CopilotSdkSessionMetadata
  >();
  private readonly sessionEvents = new Map<string, CopilotSdkSessionEvent[]>();

  public constructor(
    options: {
      models?: CopilotSdkModelInfo[];
      createSessionError?: Error;
      holdResponses?: boolean;
      skills?: Array<{
        name: string;
        description: string;
        source: string;
        enabled: boolean;
        userInvocable: boolean;
        path?: string;
        projectPath?: string;
      }>;
      sessions?: Array<{
        metadata: CopilotSdkSessionMetadata;
        events: CopilotSdkSessionEvent[];
      }>;
    } = {},
  ) {
    this.models = options.models ?? [];
    this.createSessionError = options.createSessionError ?? null;
    this.holdResponses = options.holdResponses === true;
    this.discoveredSkills = options.skills ?? [];
    for (const skill of this.discoveredSkills) {
      if (skill.enabled === false) {
        this.disabledSkills.add(skill.name);
      }
    }
    for (const session of options.sessions ?? []) {
      this.sessionMetadata.set(session.metadata.sessionId, session.metadata);
      this.sessionEvents.set(session.metadata.sessionId, session.events);
    }
  }

  private readonly holdResponses: boolean;

  public readonly rpc = {
    skills: {
      config: {
        setDisabledSkills: async ({
          disabledSkills,
        }: {
          disabledSkills: string[];
        }): Promise<void> => {
          this.disabledSkills.clear();
          for (const skill of disabledSkills) {
            this.disabledSkills.add(skill);
          }
        },
      },
      discover: async ({
        projectPaths,
      }: {
        projectPaths?: string[];
        skillDirectories?: string[];
      }): Promise<{
        skills: Array<{
          name: string;
          description: string;
          source: string;
          enabled: boolean;
          userInvocable: boolean;
          path?: string;
          projectPath?: string;
        }>;
      }> => {
        const projectFilter = new Set(projectPaths ?? []);
        return {
          skills: this.discoveredSkills
            .filter((skill) => {
              if (projectFilter.size === 0) {
                return true;
              }
              return !skill.projectPath || projectFilter.has(skill.projectPath);
            })
            .map((skill) => ({
              ...skill,
              enabled: !this.disabledSkills.has(skill.name),
            })),
        };
      },
    },
  };

  public async start(): Promise<void> {
    /* fake */
  }

  public async getStatus(): Promise<{
    version: string;
    protocolVersion: number;
  }> {
    return { version: "9.9.9", protocolVersion: 1 };
  }

  public async listModels(): Promise<CopilotSdkModelInfo[]> {
    return this.models;
  }

  public async listSessions(): Promise<CopilotSdkSessionMetadata[]> {
    return [...this.sessionMetadata.values()];
  }

  public async getSessionMetadata(
    sessionId: string,
  ): Promise<CopilotSdkSessionMetadata | undefined> {
    return this.sessionMetadata.get(sessionId);
  }

  public async createSession(
    config: CopilotSdkSessionConfig,
  ): Promise<CopilotSdkSession> {
    if (this.createSessionError) {
      throw this.createSessionError;
    }
    const session = new FakeCopilotSdkSession(
      this,
      config.sessionId ?? `sdk-session-${this.created.length + 1}`,
      config,
      false,
      [],
      this.holdResponses,
    );
    this.sessionMetadata.set(session.sessionId, {
      sessionId: session.sessionId,
      startTime: new Date(),
      modifiedTime: new Date(),
      isRemote: false,
      context: { cwd: config.workingDirectory ?? process.cwd() },
    });
    this.created.push({ config, session });
    this.sessions.set(session.sessionId, session);
    return session;
  }

  public async resumeSession(
    sessionId: string,
    config: CopilotSdkResumeSessionConfig,
  ): Promise<CopilotSdkSession> {
    const session = new FakeCopilotSdkSession(
      this,
      sessionId,
      config,
      true,
      this.sessionEvents.get(sessionId) ?? [],
      this.holdResponses,
    );
    this.resumed.push({ sessionId, config, session });
    this.sessions.set(sessionId, session);
    return session;
  }

  public flushHeldResponses(): void {
    for (const session of this.sessions.values()) {
      session.flushHeldResponses();
    }
  }
}

class FakeCopilotSdkSession implements CopilotSdkSession {
  public readonly sent: CopilotSdkMessageOptions[] = [];
  public readonly rpc = {
    mode: {
      get: async (): Promise<CopilotSdkSessionMode> => this.currentMode,
      set: async ({ mode }: { mode: CopilotSdkSessionMode }): Promise<void> => {
        const previousMode = this.currentMode;
        this.currentMode = mode;
        this.selectedModes.push(mode);
        this.emit(
          event("session.mode_changed", { previousMode, newMode: mode }),
        );
      },
    },
    skills: {
      list: async (): Promise<{
        skills: Array<{
          name: string;
          description: string;
          source: string;
          enabled: boolean;
          userInvocable: boolean;
          path?: string;
        }>;
      }> => {
        const discovered = await this.client.rpc.skills.discover({});
        return {
          skills: discovered.skills.map((skill) => ({
            name: skill.name,
            description: skill.description,
            source: skill.source,
            enabled: skill.enabled,
            userInvocable: skill.userInvocable,
            path: skill.path,
          })),
        };
      },
      enable: async ({ name }: { name: string }): Promise<void> => {
        this.client.disabledSkills.delete(name);
      },
      disable: async ({ name }: { name: string }): Promise<void> => {
        this.client.disabledSkills.add(name);
      },
      reload: async (): Promise<void> => {
        this.skillReloadCount += 1;
      },
    },
    compaction: {
      compact: async (): Promise<{
        success: boolean;
        tokensRemoved: number;
        messagesRemoved: number;
      }> => {
        this.compactCallCount += 1;
        this.emit(
          event("session.compaction_start", {
            conversationTokens: 3600,
            systemTokens: 320,
            toolDefinitionsTokens: 176,
          }),
        );
        this.emit(
          event("session.compaction_complete", {
            success: true,
            preCompactionTokens: 4096,
            postCompactionTokens: 2048,
            tokensRemoved: 2048,
            messagesRemoved: 8,
          }),
        );
        return {
          success: true,
          tokensRemoved: 2048,
          messagesRemoved: 8,
        };
      },
    },
  };
  public readonly selectedModels: Array<{
    model: string;
    reasoningEffort: string | undefined;
  }> = [];
  public readonly selectedModes: CopilotSdkSessionMode[] = [];
  public aborted = false;
  public skillReloadCount = 0;
  public compactCallCount = 0;
  private currentMode: CopilotSdkSessionMode = "interactive";
  private readonly holdResponses: boolean;
  private readonly heldResponses: Array<() => void> = [];

  public constructor(
    private readonly client: FakeCopilotSdkClient,
    public readonly sessionId: string,
    private readonly config:
      | CopilotSdkSessionConfig
      | CopilotSdkResumeSessionConfig,
    private readonly resumed: boolean,
    private readonly historyEvents: CopilotSdkSessionEvent[],
    holdResponses = false,
  ) {
    this.holdResponses = holdResponses;
  }

  public async getMessages(): Promise<CopilotSdkSessionEvent[]> {
    return this.historyEvents;
  }

  public async send(options: CopilotSdkMessageOptions): Promise<string> {
    this.sent.push(options);
    const sendIndex = this.sent.length;
    let userInputResult:
      | {
          answer: string;
          wasFreeform: boolean;
        }
      | undefined;
    let elicitationResult:
      | {
          action: string;
          content?: Record<string, unknown>;
        }
      | undefined;
    if (options.prompt.includes("approval")) {
      const result = await this.config.onPermissionRequest(
        {
          kind: "shell",
          canOfferSessionApproval: true,
          commands: [{ identifier: "echo", readOnly: false }],
          fullCommandText: "echo approval",
          hasWriteFileRedirection: false,
          intention: "Run test approval command",
          possiblePaths: [],
          possibleUrls: [],
        } as any,
        { sessionId: this.sessionId },
      );
      if (result.kind === "reject" || result.kind === "user-not-available") {
        this.emit(
          event("session.error", {
            errorType: "permission",
            warningType: "permission",
            message: "Permission rejected",
          }),
        );
        return `message-${sendIndex}`;
      }
    }
    if (options.prompt.includes("ask user")) {
      this.emit(
        event("assistant.message", {
          messageId: `assistant-ask-user-${sendIndex}`,
          content: "",
          toolRequests: [
            {
              toolCallId: "ask-user-tool-call",
              name: "ask_user",
              toolTitle: "Ask user",
              intentionSummary: "Ask the user which environment to use.",
            },
          ],
        }),
      );
      this.emit(
        event("tool.execution_start", {
          toolCallId: "ask-user-tool-call",
          toolName: "ask_user",
          arguments: {
            question: "Which environment should I use?",
            choices: ["staging", "production"],
          },
        }),
      );
      this.emit(
        event("user_input.requested", {
          requestId: "user-input-request-1",
          toolCallId: "ask-user-tool-call",
          question: "Which environment should I use?",
          choices: ["staging", "production"],
          allowFreeform: false,
        }),
      );
      userInputResult = await this.config.onUserInputRequest!(
        {
          question: "Which environment should I use?",
          choices: ["staging", "production"],
          allowFreeform: false,
        },
        { sessionId: this.sessionId },
      );
      this.emit(
        event("user_input.completed", {
          requestId: "user-input-request-1",
          answer: userInputResult.answer,
          wasFreeform: userInputResult.wasFreeform,
        }),
      );
      this.emit(
        event("tool.execution_complete", {
          toolCallId: "ask-user-tool-call",
          toolName: "ask_user",
          success: true,
          result: {
            answer: userInputResult.answer,
            wasFreeform: userInputResult.wasFreeform,
          },
        }),
      );
    }
    if (options.prompt.includes("elicitation")) {
      elicitationResult = await this.config.onElicitationRequest!({
        sessionId: this.sessionId,
        mode: "form",
        message: "Choose deployment options",
        elicitationSource: "deploy",
        requestedSchema: {
          type: "object",
          required: ["region"],
          properties: {
            region: {
              type: "string",
              title: "Region",
              oneOf: [
                { const: "us-east", title: "US East" },
                { const: "eu-west", title: "EU West" },
              ],
            },
            dryRun: {
              type: "boolean",
              title: "Dry run",
              default: true,
            },
          },
        },
      });
    }

    const emitResponse = () => {
      if (this.aborted) {
        return;
      }
      const messageId = `assistant-${sendIndex}`;
      this.emit(
        event("session.usage_info", {
          currentTokens: 4096,
          tokenLimit: 128000,
          messagesLength: sendIndex * 2,
          conversationTokens: 3600,
          systemTokens: 320,
          toolDefinitionsTokens: 176,
        }),
      );
      if (options.prompt.includes("neutral events")) {
        this.emit(
          event("assistant.reasoning_delta", {
            reasoningId: "live-reasoning-1",
            deltaContent: "Checking ",
          }),
        );
        this.emit(
          event("assistant.reasoning", {
            reasoningId: "live-reasoning-1",
            content: "Checking neutral provider events.",
          }),
        );
        this.emit(
          event("subagent.started", {
            toolCallId: "live-subagent-tool",
            agentName: "repo-explorer",
            agentDisplayName: "Repo Explorer",
            agentDescription: "Inspect repository structure.",
          }),
        );
        this.emit(
          event("subagent.completed", {
            toolCallId: "live-subagent-tool",
            agentName: "repo-explorer",
            agentDisplayName: "Repo Explorer",
            totalToolCalls: 2,
          }),
        );
        this.emit(
          event("exit_plan_mode.requested", {
            requestId: "live-plan-review",
            summary: "Review neutral plan.",
            planContent: "# Live plan",
            recommendedAction: "approve",
            actions: ["approve", "reject"],
          }),
        );
        this.emit(
          event("exit_plan_mode.completed", {
            requestId: "live-plan-review",
            approved: true,
            selectedAction: "approve",
          }),
        );
        this.emit(
          event("session.warning", {
            warningType: "mcp",
            message: "MCP warning",
          }),
        );
      }
      if (options.prompt.includes("compact")) {
        this.emit(
          event("session.compaction_start", {
            conversationTokens: 3600,
            systemTokens: 320,
            toolDefinitionsTokens: 176,
          }),
        );
        this.emit(
          event("session.compaction_complete", {
            success: true,
            preCompactionTokens: 4096,
            postCompactionTokens: 2200,
            tokensRemoved: 1896,
            messagesRemoved: 6,
            compactionTokensUsed: {
              model: this.selectedModels.at(-1)?.model ?? "gpt-5.2",
              duration: 740,
              inputTokens: 140,
              outputTokens: 31,
              copilotUsage: {
                totalNanoAiu: 15,
                tokenDetails: [],
              },
            },
          }),
        );
      }
      if (options.prompt.includes("tool")) {
        this.emit(
          event("tool.execution_start", {
            toolCallId: "tool-call-1",
            toolName: "view",
            arguments: { path: "README.md" },
          }),
        );
        this.emit(
          event("tool.execution_partial_result", {
            toolCallId: "tool-call-1",
            partialOutput: "partial ",
          }),
        );
        this.emit(
          event("tool.execution_complete", {
            toolCallId: "tool-call-1",
            success: true,
            result: { content: "tool output" },
          }),
        );
      }
      const suffix = userInputResult != null
          ? ` -> ${userInputResult.answer}`
          : elicitationResult != null
            ? ` -> ${JSON.stringify(elicitationResult.content ?? {})}`
            : "";
      const text =
        `${this.resumed ? "resumed" : "copilot says"}: ${options.prompt}${suffix}`;
      this.emit(
        event("assistant.message_delta", {
          messageId,
          deltaContent: text.slice(0, 8),
        }),
      );
      this.emit(
        event("assistant.message_delta", {
          messageId,
          deltaContent: text.slice(8),
        }),
      );
      this.emit(
        event("assistant.message", {
          messageId,
          content: text,
        }),
      );
      this.emit(
        event("assistant.usage", {
          model: this.selectedModels.at(-1)?.model ?? "gpt-5.2",
          inputTokens: 214,
          outputTokens: 27,
          reasoningTokens: 9,
          cacheReadTokens: 16,
          cacheWriteTokens: 8,
          duration: 880,
          ttftMs: 120,
          interTokenLatencyMs: 32,
          reasoningEffort:
            this.selectedModels.at(-1)?.reasoningEffort ??
            this.config.reasoningEffort ??
            "medium",
          copilotUsage: {
            totalNanoAiu: 42,
            tokenDetails: [],
          },
        }),
      );
      this.emit(event("assistant.turn_end", { turnId: "sdk-turn-1" }));
      this.emit(event("session.idle", {}));
    };
    if (this.holdResponses) {
      this.heldResponses.push(emitResponse);
    } else {
      queueMicrotask(emitResponse);
    }
    return `message-${sendIndex}`;
  }

  public async abort(): Promise<void> {
    this.aborted = true;
  }

  public async setModel(
    model: string,
    options?: { reasoningEffort?: string },
  ): Promise<void> {
    this.selectedModels.push({
      model,
      reasoningEffort: options?.reasoningEffort,
    });
  }

  private emit(event: CopilotSdkSessionEvent): void {
    this.config.onEvent?.(event);
  }

  public flushHeldResponses(): void {
    while (this.heldResponses.length > 0) {
      const next = this.heldResponses.shift();
      next?.();
    }
  }
}

function fakeSdkFactory(sdk: FakeCopilotSdkClient): CopilotSdkClientFactory {
  return () => sdk;
}

function sdkModel(
  id: string,
  options: {
    name: string;
    multiplier?: number;
    policy?: "enabled" | "disabled" | "unconfigured";
    vision?: boolean;
    reasoning?: boolean;
  },
): CopilotSdkModelInfo {
  const reasoning = options.reasoning ?? true;
  return {
    id,
    name: options.name,
    capabilities: {
      supports: {
        vision: options.vision === true,
        reasoningEffort: reasoning,
      },
      limits: {
        max_context_window_tokens: 100000,
      },
    },
    policy: {
      state: options.policy ?? "enabled",
      terms: "",
    },
    billing:
      options.multiplier == null
        ? undefined
        : { multiplier: options.multiplier },
    supportedReasoningEfforts: reasoning
      ? ["low", "medium", "high"]
      : undefined,
    defaultReasoningEffort: reasoning ? "medium" : undefined,
  };
}

function storedToolActivity(options: {
  id: string;
  toolName: string;
  title: string;
  args?: unknown;
  result?: unknown;
  seq: number;
}) {
  return {
    id: options.id,
    type: "tool",
    turnId: null,
    createdAt: Date.now(),
    seq: options.seq,
    status: "completed",
    toolName: options.toolName,
    title: options.title,
    args: options.args ?? null,
    output: null,
    result: options.result ?? null,
    isError: false,
    semantic: null,
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

function waitForTurnCompleted(provider: CopilotAgentProvider): Promise<void> {
  return new Promise((resolve) => {
    provider.on("liveEvent", (liveEvent) => {
      if (liveEvent.type === "turn_completed") {
        resolve();
      }
    });
  });
}

function waitForActionOpened(
  provider: CopilotAgentProvider,
  kind?: string,
): Promise<AgentPendingAction> {
  return new Promise((resolve) => {
    provider.on("liveEvent", (liveEvent) => {
      if (
        liveEvent.type === "action_opened" &&
        (kind == null || liveEvent.action.kind === kind)
      ) {
        resolve(liveEvent.action);
      }
    });
  });
}

async function settleProviderWrites(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 100));
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs = 500,
): Promise<void> {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error("Timed out waiting for test condition.");
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function event(
  type: string,
  data: unknown,
  id = `${type}-${Math.random().toString(16).slice(2)}`,
): CopilotSdkSessionEvent {
  return {
    id,
    parentId: null,
    timestamp: new Date().toISOString(),
    type,
    data,
  } as CopilotSdkSessionEvent;
}
