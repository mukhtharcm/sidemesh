import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("emits plan updates, reasoning deltas, and provider warnings from SDK rich events", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-rich-events-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const liveEvents: AgentProviderLiveEvent[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (
          liveEvent.type === "plan_updated" ||
          liveEvent.type === "reasoning_delta" ||
          liveEvent.type === "provider_warning"
        ) {
          liveEvents.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello plan event reasoning warning",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;
      await waitFor(
        () =>
          liveEvents.some((liveEvent) => liveEvent.type === "plan_updated") &&
          liveEvents.some((liveEvent) => liveEvent.type === "reasoning_delta") &&
          liveEvents.filter((liveEvent) => liveEvent.type === "provider_warning")
                .length >= 2,
      );

      const planUpdated = liveEvents.find(
        (liveEvent) => liveEvent.type === "plan_updated",
      );
      if (planUpdated?.type !== "plan_updated") {
        throw new Error("Expected Copilot plan_updated event");
      }
      assert.equal(planUpdated.explanation, "Shipping plan Keep the rollout small and safe.");
      assert.deepEqual(planUpdated.plan, [
        { step: "Review the current state", status: "completed" },
        { step: "Wire the shared event envelope", status: "in_progress" },
        { step: "Validate on mobile", status: "pending" },
      ]);

      const reasoning = liveEvents.find(
        (liveEvent) => liveEvent.type === "reasoning_delta",
      );
      if (reasoning?.type !== "reasoning_delta") {
        throw new Error("Expected Copilot reasoning_delta event");
      }
      assert.equal(reasoning.reasoningId, "reasoning-1");
      assert.equal(reasoning.delta, "Thinking through the session state...");
      assert.equal(reasoning.summary, false);

      const warning = liveEvents.find(
        (liveEvent) =>
          liveEvent.type === "provider_warning" && liveEvent.level === "warning",
      );
      if (warning?.type !== "provider_warning") {
        throw new Error("Expected Copilot warning event");
      }
      assert.equal(warning.code, "policy");
      assert.equal(warning.message, "Copilot warning");
      assert.equal(warning.source, "copilot");

      const info = liveEvents.find(
        (liveEvent) =>
          liveEvent.type === "provider_warning" && liveEvent.level === "info",
      );
      if (info?.type !== "provider_warning") {
        throw new Error("Expected Copilot info event");
      }
      assert.equal(info.code, "mcp");
      assert.equal(info.message, "Copilot info");
      assert.equal(info.source, "copilot");
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("normalizes Copilot plan status markers without checkbox syntax", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-plan-markers-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const liveEvents: AgentProviderLiveEvent[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "plan_updated") {
          liveEvents.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello plan marker event",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      await waitFor(
        () => liveEvents.some((liveEvent) => liveEvent.type === "plan_updated"),
      );
      const planUpdated = liveEvents.find(
        (liveEvent) => liveEvent.type === "plan_updated",
      );
      if (planUpdated?.type !== "plan_updated") {
        throw new Error("Expected Copilot plan_updated event");
      }
      assert.deepEqual(planUpdated.plan, [
        { step: "Review the real plan format", status: "completed" },
        { step: "Wire parser support", status: "in_progress" },
        { step: "Validate mobile replay", status: "pending" },
      ]);
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("emits an empty plan update when Copilot deletes the plan file", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-plan-delete-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const liveEvents: AgentProviderLiveEvent[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "plan_updated") {
          liveEvents.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello plan delete event",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      await waitFor(
        () => liveEvents.some(
          (liveEvent) =>
            liveEvent.type === "plan_updated" && liveEvent.plan.length === 0,
        ),
      );
      const latest = liveEvents.at(-1);
      if (latest?.type !== "plan_updated") {
        throw new Error("Expected latest event to be plan_updated");
      }
      assert.deepEqual(latest.plan, []);
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("sends file and directory mentions through the SDK", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-file-input-"),
    );
    try {
      const filePath = nodePath.join(dir, "README.md");
      const directoryPath = nodePath.join(dir, "src");
      await writeFile(filePath, "readme");
      await mkdir(directoryPath);

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
          { type: "text", text: "inspect these", text_elements: [] },
          { type: "file", path: filePath },
          { type: "file", path: directoryPath, isDirectory: true },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      assert.equal(sdk.created[0]?.session.sent[0]?.prompt, "inspect these");
      assert.deepEqual(sdk.created[0]?.session.sent[0]?.attachments, [
        {
          type: "file",
          path: filePath,
          displayName: "README.md",
        },
        {
          type: "directory",
          path: directoryPath,
          displayName: "src",
        },
      ]);

      const log = await provider.readSessionLog!(created.thread);
      assert.equal(log.messages[0]?.text, "inspect these");
      assert.deepEqual(log.messages[0]?.attachments, [
        { type: "file", path: filePath },
        { type: "file", path: directoryPath },
      ]);
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("restores interrupted Copilot turns as idle after restart", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-restart-state-test-"),
    );
    const sdk = new FakeCopilotSdkClient({ holdResponses: true });
    try {
      const stateDir = nodePath.join(dir, "state");
      const provider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "hello", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await settleProviderWrites();

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
          toolName: "view",
          title: "View README",
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

      const activeThread = await provider.readSessionThread(created.thread.id, true);
      assert.equal(activeThread.status.type, "running");
      assert.equal(activeThread.turns?.at(-1)?.status, "inProgress");

      const restoredProvider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(new FakeCopilotSdkClient()),
      });
      await restoredProvider.start();

      const threads = await restoredProvider.listSessionThreads({
        limit: 10,
        archived: false,
      });
      assert.equal(threads.length, 1);
      assert.equal(threads[0]?.id, created.thread.id);
      assert.equal(threads[0]?.status.type, "idle");

      const restoredThread = await restoredProvider.readSessionThread(
        created.thread.id,
        true,
      );
      assert.equal(restoredThread.status.type, "idle");
      assert.equal(restoredThread.turns?.at(-1)?.status, "interrupted");
      const restoredLog = await restoredProvider.readSessionLog(restoredThread);
      assert.equal(restoredLog.activities[0]?.status, "failed");
      const restoredRuntime = await restoredProvider.readSessionRuntime(
        restoredThread,
      );
      assert.equal(restoredRuntime?.turnId ?? null, null);
      assert.equal(restoredRuntime?.telemetry?.compaction?.status, "failed");
    } finally {
      sdk.flushHeldResponses();
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("persists pending Copilot user input and restores it as an interrupted turn note", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-pending-restart-test-"),
    );
    try {
      const stateDir = nodePath.join(dir, "state");
      const provider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(new FakeCopilotSdkClient()),
      });
      await provider.start();

      const opened = waitForActionOpened(provider, "user_input");
      void provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "please ask user", text_elements: [] }],
        overrides: emptyOverrides(),
      });

      const action = await opened;
      await settleProviderWrites();

      const statePath = nodePath.join(stateDir, "sessions.json");
      const persistedBeforeRestart = JSON.parse(
        await readFile(statePath, "utf8"),
      ) as {
        sessions?: Array<{ pendingActions?: AgentPendingAction[] }>;
      };
      assert.equal(
        persistedBeforeRestart.sessions?.[0]?.pendingActions?.length,
        1,
      );
      assert.equal(
        persistedBeforeRestart.sessions?.[0]?.pendingActions?.[0]?.id,
        action.id,
      );

      const restoredProvider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(new FakeCopilotSdkClient()),
      });
      await restoredProvider.start();

      const restoredThread = await restoredProvider.readSessionThread(
        action.sessionId,
        true,
      );
      assert.equal(restoredThread.status.type, "idle");
      assert.equal(restoredThread.turns?.at(-1)?.status, "interrupted");

      const restoredLog = await restoredProvider.readSessionLog(restoredThread);
      const restoredNotice = restoredLog.messages.at(-1);
      assert.equal(restoredNotice?.role, "system");
      assert.match(restoredNotice?.text ?? "", /waiting for your answer/i);
      assert.match(restoredNotice?.text ?? "", /re-run your last request/i);

      const persistedAfterRestart = JSON.parse(
        await readFile(statePath, "utf8"),
      ) as {
        sessions?: Array<{ pendingActions?: AgentPendingAction[] }>;
      };
      assert.deepEqual(
        persistedAfterRestart.sessions?.[0]?.pendingActions ?? [],
        [],
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("restores partial Copilot assistant output after restart", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-partial-restart-test-"),
    );
    try {
      const stateDir = nodePath.join(dir, "state");
      const provider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(new FakeCopilotSdkClient()),
      });
      await provider.start();

      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "crash partial", text_elements: [] }],
        overrides: emptyOverrides(),
      });
      await settleProviderWrites();

      const activeThread = await provider.readSessionThread(created.thread.id, true);
      assert.equal(activeThread.status.type, "running");
      assert.equal(activeThread.turns?.at(-1)?.status, "inProgress");

      const restoredProvider = new CopilotAgentProvider({
        stateDir,
        sdkClientFactory: fakeSdkFactory(new FakeCopilotSdkClient()),
      });
      await restoredProvider.start();

      const restoredThread = await restoredProvider.readSessionThread(
        created.thread.id,
        true,
      );
      assert.equal(restoredThread.status.type, "idle");
      assert.equal(restoredThread.turns?.at(-1)?.status, "interrupted");

      const restoredLog = await restoredProvider.readSessionLog(restoredThread);
      assert.equal(restoredLog.messages.length, 2);
      const assistant = restoredLog.messages.at(-1);
      const reasoning = assistant?.content.find(
        (block): block is { type: "thinking"; thinking: string } =>
          block.type === "thinking",
      );
      assert.equal(assistant?.role, "assistant");
      assert.equal(assistant?.text, "copilot says: crash partial");
      assert.equal(reasoning?.type, "thinking");
      assert.equal(
        reasoning?.thinking,
        "Thinking through the interrupted response...",
      );
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("normalizes stale Copilot history activities and compaction on reload", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-history-restart-state-test-"),
    );
    try {
      const sessionId = "history-session";
      const sdk = new FakeCopilotSdkClient({
        sessions: [
          {
            metadata: {
              sessionId,
              startTime: new Date("2026-04-01T00:00:00.000Z"),
              modifiedTime: new Date("2026-04-01T00:05:00.000Z"),
              summary: "History session",
              isRemote: false,
              context: { cwd: dir },
            },
            events: [
              event("tool.execution_start", {
                toolCallId: "tool-1",
                toolName: "view",
                arguments: { path: "README.md" },
              }),
              event("session.compaction_start", {
                conversationTokens: 3600,
                systemTokens: 320,
                toolDefinitionsTokens: 176,
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

      const thread = await provider.readSessionThread(sessionId, false);
      assert.equal(thread.status.type, "idle");
      const log = await provider.readSessionLog(thread);
      assert.equal(log.activities[0]?.status, "failed");
      assert.equal(log.runtime?.telemetry?.compaction?.status, "failed");
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("normalizes Copilot history meta tools and suppresses report_intent", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-history-meta-tools-"),
    );
    try {
      const sessionId = "history-meta-tools";
      const sdk = new FakeCopilotSdkClient({
        sessions: [
          {
            metadata: {
              sessionId,
              startTime: new Date("2026-04-02T00:00:00.000Z"),
              modifiedTime: new Date("2026-04-02T00:05:00.000Z"),
              summary: "History meta tools",
              isRemote: false,
              context: { cwd: dir },
            },
            events: [
              event("tool.execution_start", {
                toolCallId: "intent-1",
                toolName: "report_intent",
                arguments: { intent: "Asking for environment" },
              }),
              event("tool.execution_complete", {
                toolCallId: "intent-1",
                toolName: "report_intent",
                success: true,
                result: {
                  content: "Intent logged",
                  detailedContent: "Asking for environment",
                },
              }),
              event("tool.execution_start", {
                toolCallId: "ask-1",
                toolName: "ask_user",
                arguments: {
                  question: "Which environment should I use?",
                  choices: ["staging", "production"],
                  allow_freeform: false,
                },
              }),
              event("tool.execution_complete", {
                toolCallId: "ask-1",
                toolName: "ask_user",
                success: true,
                result: {
                  content: "User selected: staging",
                  detailedContent: "User selected: staging",
                },
              }),
              event("tool.execution_complete", {
                toolCallId: "task-1",
                toolName: "task_complete",
                success: true,
                result: {
                  content: "Finished the work and handed off the PR.",
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

      const thread = await provider.readSessionThread(sessionId, false);
      const log = await provider.readSessionLog(thread);

      assert.equal(log.activities.length, 2);
      assert.equal(
        log.activities.some(
          (activity) =>
            activity.type === "tool" && activity.toolName === "report_intent",
        ),
        false,
      );

      const askUser = log.activities.find(
        (activity) => activity.type === "tool" && activity.toolName === "ask_user",
      );
      assert.ok(askUser, "Expected ask_user history activity");
      assert.equal(askUser.type, "tool");
      assert.equal(askUser.title, "Asked user: Which environment should I use?");
      assert.equal(askUser.args, null);
      assert.equal(askUser.output, "User selected: staging");
      assert.equal(askUser.result, null);
      assert.equal(askUser.semantic?.category, "task");

      const taskComplete = log.activities.find(
        (activity) =>
          activity.type === "tool" && activity.toolName === "task_complete",
      );
      assert.ok(taskComplete, "Expected task_complete history activity");
      assert.equal(taskComplete.type, "tool");
      assert.equal(taskComplete.title, "Task completed");
      assert.equal(taskComplete.output, "Finished the work and handed off the PR.");
      assert.equal(taskComplete.result, null);
      assert.equal(taskComplete.semantic?.category, "task");
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("normalizes high-volume Copilot tool families into readable activities", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-history-rich-tools-"),
    );
    try {
      const sessionId = "history-rich-tools";
      const filePath = nodePath.join(dir, "src", "feature.ts");
      const sdk = new FakeCopilotSdkClient({
        sessions: [
          {
            metadata: {
              sessionId,
              startTime: new Date("2026-04-03T00:00:00.000Z"),
              modifiedTime: new Date("2026-04-03T00:05:00.000Z"),
              summary: "History rich tools",
              isRemote: false,
              context: { cwd: dir },
            },
            events: [
              event("tool.execution_start", {
                toolCallId: "bash-1",
                toolName: "bash",
                arguments: {
                  command: "npm run typecheck",
                  description: "Run TypeScript checks",
                },
              }),
              event("tool.execution_complete", {
                toolCallId: "bash-1",
                toolName: "bash",
                success: true,
                result: {
                  content: "ok\n<exited with exit code 0>",
                  detailedContent: "ok\n<exited with exit code 0>",
                },
              }),
              event("tool.execution_start", {
                toolCallId: "view-1",
                toolName: "view",
                arguments: { path: filePath, view_range: [10, 20] },
              }),
              event("tool.execution_complete", {
                toolCallId: "view-1",
                toolName: "view",
                success: true,
                result: {
                  content: "  10. export const value = 1;\n",
                  detailedContent: "diff --git a/src/feature.ts b/src/feature.ts",
                },
              }),
              event("tool.execution_start", {
                toolCallId: "edit-1",
                toolName: "edit",
                arguments: {
                  path: filePath,
                  old_str: "value = 1",
                  new_str: "value = 2",
                },
              }),
              event("tool.execution_complete", {
                toolCallId: "edit-1",
                toolName: "edit",
                success: true,
                result: {
                  content: `File ${filePath} updated with changes.`,
                  detailedContent: "@@ -1 +1 @@\n-value = 1\n+value = 2",
                },
              }),
              event("tool.execution_start", {
                toolCallId: "agent-1",
                toolName: "read_agent",
                arguments: {
                  agent_id: "code-review",
                  wait: true,
                  timeout: 60,
                },
              }),
              event("tool.execution_complete", {
                toolCallId: "agent-1",
                toolName: "read_agent",
                success: true,
                result: {
                  content: "No blocking review findings.",
                  detailedContent: "No blocking review findings.\n\n(Full response provided to agent)",
                },
              }),
              event("tool.execution_start", {
                toolCallId: "task-1",
                toolName: "task",
                arguments: {
                  name: "code-review",
                  description: "Review branch diff",
                  prompt: "Long review prompt",
                },
              }),
              event("tool.execution_complete", {
                toolCallId: "task-1",
                toolName: "task",
                success: true,
                result: {
                  content: "Agent started in background with agent_id: code-review.",
                  detailedContent: "Prompt to code-review agent: Long review prompt",
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

      const thread = await provider.readSessionThread(sessionId, false);
      const log = await provider.readSessionLog(thread);

      const bash = log.activities.find((activity) => activity.id === "bash-1");
      assert.ok(bash, "Expected bash activity");
      assert.equal(bash.type, "command");
      assert.equal(bash.command, "npm run typecheck");
      assert.equal(bash.cwd, dir);
      assert.equal(bash.output, "ok\n<exited with exit code 0>");
      assert.equal(bash.exitCode, 0);

      const view = log.activities.find((activity) => activity.id === "view-1");
      assert.ok(view, "Expected view activity");
      assert.equal(view.type, "tool");
      assert.equal(view.title, "Viewed feature.ts:10-20");
      assert.equal(view.args, null);
      assert.equal(view.output, "  10. export const value = 1;\n");
      assert.equal(view.result, null);

      const edit = log.activities.find((activity) => activity.id === "edit-1");
      assert.ok(edit, "Expected edit activity");
      assert.equal(edit.type, "tool");
      assert.equal(edit.title, "Edited feature.ts");
      assert.equal(edit.args, null);
      assert.equal(edit.output, "@@ -1 +1 @@\n-value = 1\n+value = 2");
      assert.equal(edit.result, null);

      const readAgent = log.activities.find(
        (activity) => activity.id === "agent-1",
      );
      assert.ok(readAgent, "Expected read_agent activity");
      assert.equal(readAgent.type, "tool");
      assert.equal(readAgent.args, null);
      assert.equal(readAgent.output, "No blocking review findings.");
      assert.equal(readAgent.result, null);
      assert.equal(readAgent.semantic?.category, "task");

      const task = log.activities.find((activity) => activity.id === "task-1");
      assert.ok(task, "Expected task activity");
      assert.equal(task.type, "tool");
      assert.equal(task.title, "Review branch diff");
      assert.equal(task.args, null);
      assert.equal(
        task.output,
        "Agent started in background with agent_id: code-review.",
      );
      assert.equal(task.result, null);
      assert.equal(task.semantic?.category, "task");
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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

      const liveMessages: string[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "session_message_appended") {
          liveMessages.push(liveEvent.message.text);
        }
      });
      const opened = waitForActionOpened(provider, "user_input");
      const completed = waitForTurnCompleted(provider);
      const created = await provider.createSession({
        cwd: dir,
        input: [{ type: "text", text: "please ask user", text_elements: [] }],
        overrides: emptyOverrides(),
      });

      const action = await opened;
      const pendingThread = await provider.readSessionThread(
        created.thread.id,
        false,
      );
      assert.equal(pendingThread.preview, "please ask user");
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
      assert.equal(
        log.activities.some(
          (activity) =>
            activity.type === "tool" && activity.toolName === "ask_user",
        ),
        false,
      );
      assert.equal(
        log.activities.some(
          (activity) =>
            activity.type === "tool" && activity.toolName === "report_intent",
        ),
        false,
      );
      assert.ok(
        log.messages.some(
          (message) =>
            message.role === "system" &&
            message.text.includes(
              "Agent asked: Which environment should I use?",
            ),
        ),
      );
      assert.ok(
        log.messages.some(
          (message) =>
            message.role === "system" &&
            message.text.includes("User selected an option."),
        ),
      );
      const answerAuditMessage = log.messages.find(
        (message) =>
          message.role === "system" && message.text.includes("User selected"),
      );
      assert.ok(answerAuditMessage, "Expected ask-user response audit row");
      assert.doesNotMatch(answerAuditMessage.text, /staging/);
      assert.ok(
        liveMessages.some((message) =>
          message.includes("Agent asked: Which environment should I use?"),
        ),
      );
      assert.ok(
        liveMessages.some((message) =>
          message.includes("User selected an option."),
        ),
      );
      assert.match(log.messages.at(-1)?.text ?? "", /staging/);
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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

      const liveMessages: string[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "session_message_appended") {
          liveMessages.push(liveEvent.message.text);
        }
      });
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
      assert.ok(
        log.messages.some(
          (message) =>
            message.role === "system" &&
            message.text.includes("Agent requested structured input:"),
        ),
      );
      assert.ok(
        log.messages.some(
          (message) =>
            message.role === "system" &&
            message.text.includes("Structured input submitted"),
        ),
      );
      const structuredAuditMessage = log.messages.find(
        (message) =>
          message.role === "system" &&
          message.text.includes("Structured input submitted"),
      );
      assert.ok(structuredAuditMessage, "Expected structured input audit row");
      assert.doesNotMatch(structuredAuditMessage.text, /us-east/);
      assert.doesNotMatch(structuredAuditMessage.text, /dryRun/);
      assert.ok(
        liveMessages.some((message) =>
          message.includes("Agent requested structured input:"),
        ),
      );
      assert.ok(
        liveMessages.some((message) =>
          message.includes("Structured input submitted"),
        ),
      );
      assert.match(log.messages.at(-1)?.text ?? "", /us-east/);
      assert.match(log.messages.at(-1)?.text ?? "", /dryRun/);
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("redacts Copilot browser sign-in URLs from transcript audit rows", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-url-elicitation-test-"),
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
        input: [
          { type: "text", text: "needs browser sign-in", text_elements: [] },
        ],
        overrides: emptyOverrides(),
      });

      const action = await opened;
      assert.equal(action.elicitation?.mode, "url");
      assert.match(action.elicitation?.url ?? "", /secret-token/);
      assert.equal(
        provider.respondToPendingAction(action, {
          action: "cancel",
        }),
        true,
      );
      await completed;

      const log = await provider.readSessionLog!(created.thread);
      const systemText = log.messages
        .filter((message) => message.role === "system")
        .map((message) => message.text)
        .join("\n");
      assert.match(systemText, /Agent requested browser sign-in: Sign in to GitHub/);
      assert.doesNotMatch(systemText, /secret-token/);
      assert.doesNotMatch(systemText, /https:\/\/auth\.example/);
    } finally {
      await settleProviderWrites();
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
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
    plan: {
      read: async (): Promise<{
        exists: boolean;
        content: string | null;
        path: string | null;
      }> => ({
        exists: this.planContent != null,
        content: this.planContent,
        path: this.planContent == null ? null : `/tmp/${this.sessionId}/plan.md`,
      }),
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
  private planContent: string | null = null;
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
      userInputResult = await this.config.onUserInputRequest!(
        {
          question: "Which environment should I use?",
          choices: ["staging", "production"],
          allowFreeform: false,
        },
        { sessionId: this.sessionId },
      );
    }
    if (options.prompt.includes("browser sign-in")) {
      elicitationResult = await this.config.onElicitationRequest!({
        sessionId: this.sessionId,
        mode: "url",
        message: "Sign in to GitHub",
        elicitationSource: "github",
        url: "https://auth.example/login?token=secret-token",
        requestedSchema: { type: "object", properties: {} },
      });
    } else if (options.prompt.includes("elicitation")) {
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
      if (options.prompt.includes("ask user")) {
        this.emit(
          event("tool.execution_start", {
            toolCallId: "intent-call-1",
            toolName: "report_intent",
            arguments: { intent: "Asking for environment" },
          }),
        );
        this.emit(
          event("tool.execution_complete", {
            toolCallId: "intent-call-1",
            toolName: "report_intent",
            success: true,
            result: {
              content: "Intent logged",
              detailedContent: "Asking for environment",
            },
          }),
        );
        this.emit(
          event("tool.execution_start", {
            toolCallId: "ask-user-call-1",
            toolName: "ask_user",
            arguments: {
              question: "Which environment should I use?",
              choices: ["staging", "production"],
              allow_freeform: false,
            },
          }),
        );
        this.emit(
          event("tool.execution_complete", {
            toolCallId: "ask-user-call-1",
            toolName: "ask_user",
            success: true,
            result: {
              content: `User selected: ${userInputResult?.answer ?? ""}`,
              detailedContent: `User selected: ${userInputResult?.answer ?? ""}`,
            },
          }),
        );
      }
      if (options.prompt.includes("plan event")) {
        this.planContent = [
          "# Shipping plan",
          "",
          "Keep the rollout small and safe.",
          "",
          "- [x] Review the current state",
          "- [~] Wire the shared event envelope",
          "- [ ] Validate on mobile",
        ].join("\n");
        this.emit(event("session.plan_changed", { operation: "update" }));
      }
      if (options.prompt.includes("plan marker event")) {
        this.planContent = [
          "# Marker plan",
          "",
          "- \u2713 Review the real plan format",
          "- Wire parser support - in progress",
          "- Validate mobile replay - pending",
        ].join("\n");
        this.emit(event("session.plan_changed", { operation: "create" }));
      }
      if (options.prompt.includes("plan delete event")) {
        this.planContent = [
          "# Temporary plan",
          "",
          "- [ ] Remove the temporary plan",
        ].join("\n");
        this.emit(event("session.plan_changed", { operation: "create" }));
        queueMicrotask(() => {
          this.planContent = null;
          this.emit(event("session.plan_changed", { operation: "delete" }));
        });
      }
      if (options.prompt.includes("reasoning")) {
        this.emit(
          event("assistant.reasoning_delta", {
            reasoningId: "reasoning-1",
            deltaContent: "Thinking through the session state...",
          }),
        );
      }
      if (options.prompt.includes("warning")) {
        this.emit(
          event("session.warning", {
            warningType: "policy",
            message: "Copilot warning",
          }),
        );
        this.emit(
          event("session.info", {
            infoType: "mcp",
            message: "Copilot info",
          }),
        );
      }
      if (options.prompt.includes("subagent")) {
        this.emit(
          event("subagent.started", {
            toolCallId: "subagent-1",
            agentName: "docs-agent",
            agentDisplayName: "Documentation Agent",
            agentDescription: "Reads docs",
          }),
        );
        this.emit(
          event("subagent.completed", {
            toolCallId: "subagent-1",
            agentName: "docs-agent",
            agentDisplayName: "Documentation Agent",
            durationMs: 3400,
            totalTokens: 120,
          }),
        );
      }
      if (options.prompt.includes("subagent fail")) {
        this.emit(
          event("subagent.started", {
            toolCallId: "subagent-2",
            agentName: "search-agent",
            agentDisplayName: "Search Agent",
            agentDescription: "Searches",
          }),
        );
        this.emit(
          event("subagent.failed", {
            toolCallId: "subagent-2",
            agentName: "search-agent",
            agentDisplayName: "Search Agent",
            error: "Search timeout",
            durationMs: 5000,
          }),
        );
      }
      if (options.prompt.includes("background")) {
        this.emit(event("session.background_tasks_changed", {}));
      }
      if (options.prompt.includes("mcp status")) {
        this.emit(
          event("session.mcp_server_status_changed", {
            serverName: "github",
            status: "failed",
          }),
        );
        this.emit(
          event("session.mcp_servers_loaded", {
            servers: [
              { name: "github", status: "failed", error: "Connection refused" },
              { name: "postgres", status: "ok" },
            ],
          }),
        );
      }
      if (options.prompt.includes("capabilities")) {
        this.emit(
          event("capabilities.changed", {
            ui: { elicitation: true },
          }),
        );
      }
      if (options.prompt.includes("oauth")) {
        this.emit(
          event("mcp.oauth_required", {
            requestId: "oauth-1",
            serverName: "github",
            serverUrl: "https://github.com/login",
          }),
        );
        this.emit(
          event("mcp.oauth_completed", {
            requestId: "oauth-1",
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
      if (options.prompt.includes("crash partial")) {
        this.emit(
          event("assistant.reasoning_delta", {
            reasoningId: "reasoning-interrupted",
            deltaContent: "Thinking through the interrupted response...",
          }),
        );
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
        return;
      }
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

describe("copilot rich event cleanup", () => {
  it("maps subagent started and completed to activity rows", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-subagent-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const activities: any[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "activity_updated") {
          activities.push(liveEvent.activity);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello subagent",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      const started = activities.find((a) => a.id === "subagent-1" && a.status === "in_progress");
      assert.ok(started, "Expected subagent started activity");
      assert.equal(started?.type, "tool");
      assert.equal(started?.toolName, "docs-agent");
      assert.equal(started?.title, "Documentation Agent");

      const completedActivity = activities.find(
        (a) => a.id === "subagent-1" && a.status === "completed",
      );
      assert.ok(completedActivity, "Expected subagent completed activity");
      assert.equal(completedActivity?.result?.type, "success");
    } finally {
      await new Promise((r) => setTimeout(r, 50));
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("maps subagent failed to activity row with error", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-subagent-fail-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const activities: any[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "activity_updated") {
          activities.push(liveEvent.activity);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello subagent fail",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      const failed = activities.find((a) => a.id === "subagent-2" && a.status === "failed");
      assert.ok(failed, "Expected subagent failed activity");
      assert.equal(failed?.result?.type, "error");
      assert.equal((failed?.result as any)?.summary, "Search timeout");
    } finally {
      await new Promise((r) => setTimeout(r, 50));
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("emits provider_warning for background_tasks_changed", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-bg-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const warnings: any[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "provider_warning") {
          warnings.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello background",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      const bg = warnings.find(
        (w) => w.type === "provider_warning" && w.code === "background_tasks_changed",
      );
      assert.ok(bg);
      assert.equal(bg?.level, "info");
      assert.equal(bg?.message, "Background tasks changed");
    } finally {
      await new Promise((r) => setTimeout(r, 50));
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("emits provider_warning for MCP status and load errors", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-mcp-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const warnings: any[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "provider_warning") {
          warnings.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello mcp status",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      const statusWarning = warnings.find(
        (w) => w.code === "mcp_server_status_changed" && w.level === "error",
      );
      assert.ok(statusWarning);
      assert.ok(statusWarning?.message.includes("github"));
      assert.ok(statusWarning?.message.includes("failed"));

      const loadWarning = warnings.find(
        (w) => w.code === "mcp_servers_loaded" && w.level === "warning",
      );
      assert.ok(loadWarning);
      assert.ok(loadWarning?.message.includes("Connection refused"));
    } finally {
      await new Promise((r) => setTimeout(r, 50));
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("emits provider_warning for capabilities.changed", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-capabilities-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const warnings: any[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "provider_warning") {
          warnings.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello capabilities",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      const cap = warnings.find((w) => w.code === "capabilities_changed");
      assert.ok(cap);
      assert.equal(cap?.level, "info");
      assert.equal(cap?.message, "Elicitation enabled");
    } finally {
      await new Promise((r) => setTimeout(r, 50));
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("emits provider_warning for mcp.oauth_required", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-copilot-oauth-"),
    );
    try {
      const sdk = new FakeCopilotSdkClient();
      const provider = new CopilotAgentProvider({
        stateDir: nodePath.join(dir, "state"),
        sdkClientFactory: fakeSdkFactory(sdk),
      });
      await provider.start();

      const warnings: any[] = [];
      provider.on("liveEvent", (liveEvent) => {
        if (liveEvent.type === "provider_warning") {
          warnings.push(liveEvent);
        }
      });

      const completed = waitForTurnCompleted(provider);
      await provider.createSession({
        cwd: dir,
        input: [
          {
            type: "text",
            text: "hello oauth",
            text_elements: [],
          },
        ],
        overrides: emptyOverrides(),
      });
      await completed;

      const oauth = warnings.find((w) => w.code === "mcp_oauth_required");
      assert.ok(oauth);
      assert.equal(oauth?.level, "info");
      assert.ok(oauth?.message.includes("github"));
      assert.equal(oauth?.source, "copilot/mcp");
    } finally {
      await new Promise((r) => setTimeout(r, 50));
      await rm(dir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });
});
