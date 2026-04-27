import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import type { AgentPendingAction } from "./agent-provider.js";
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
                repository: "mukhtharcm/sidemesh",
                branch: "main",
              },
            },
            events: [
              event("session.model_change", { newModel: "gpt-5.2" }),
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
      assert.equal(log.activities.length, 1);
      assert.equal(log.activities[0]?.type, "command");
      assert.equal(log.runtime?.model, "gpt-5.2");

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
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-copilot-test-"));
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
      assert.equal(log.runtime?.model, "auto");
      assert.equal(log.runtime?.reasoningEffort, undefined);

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

  it("stores SDK tool events as command activities", async () => {
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
      assert.equal(log.activities[0]?.type, "command");
      assert.equal(log.activities[0]?.status, "completed");
      assert.match(log.activities[0]?.output ?? "", /tool output/);
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
  private readonly sessions = new Map<string, FakeCopilotSdkSession>();
  private readonly models: CopilotSdkModelInfo[];
  private readonly createSessionError: Error | null;
  private readonly sessionMetadata = new Map<string, CopilotSdkSessionMetadata>();
  private readonly sessionEvents = new Map<string, CopilotSdkSessionEvent[]>();

  public constructor(
    options: {
      models?: CopilotSdkModelInfo[];
      createSessionError?: Error;
      sessions?: Array<{
        metadata: CopilotSdkSessionMetadata;
        events: CopilotSdkSessionEvent[];
      }>;
    } = {},
  ) {
    this.models = options.models ?? [];
    this.createSessionError = options.createSessionError ?? null;
    for (const session of options.sessions ?? []) {
      this.sessionMetadata.set(session.metadata.sessionId, session.metadata);
      this.sessionEvents.set(session.metadata.sessionId, session.events);
    }
  }

  public async start(): Promise<void> {
    /* fake */
  }

  public async getStatus(): Promise<{ version: string; protocolVersion: number }> {
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
      config.sessionId ?? `sdk-session-${this.created.length + 1}`,
      config,
      false,
      [],
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
      sessionId,
      config,
      true,
      this.sessionEvents.get(sessionId) ?? [],
    );
    this.resumed.push({ sessionId, config, session });
    this.sessions.set(sessionId, session);
    return session;
  }
}

class FakeCopilotSdkSession implements CopilotSdkSession {
  public readonly sent: CopilotSdkMessageOptions[] = [];
  public readonly selectedModels: Array<{
    model: string;
    reasoningEffort: string | undefined;
  }> = [];
  public aborted = false;

  public constructor(
    public readonly sessionId: string,
    private readonly config:
      | CopilotSdkSessionConfig
      | CopilotSdkResumeSessionConfig,
    private readonly resumed: boolean,
    private readonly historyEvents: CopilotSdkSessionEvent[],
  ) {}

  public async getMessages(): Promise<CopilotSdkSessionEvent[]> {
    return this.historyEvents;
  }

  public async send(options: CopilotSdkMessageOptions): Promise<string> {
    this.sent.push(options);
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
        return `message-${this.sent.length}`;
      }
    }

    queueMicrotask(() => {
      if (this.aborted) {
        return;
      }
      const messageId = `assistant-${this.sent.length}`;
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
      const text = `${this.resumed ? "resumed" : "copilot says"}: ${options.prompt}`;
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
      this.emit(event("assistant.turn_end", { turnId: "sdk-turn-1" }));
      this.emit(event("session.idle", {}));
    });
    return `message-${this.sent.length}`;
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
    supportedReasoningEfforts: reasoning ? ["low", "medium", "high"] : undefined,
    defaultReasoningEffort: reasoning ? "medium" : undefined,
  };
}

function emptyOverrides() {
  return {
    model: null,
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
): Promise<AgentPendingAction> {
  return new Promise((resolve) => {
    provider.on("liveEvent", (liveEvent) => {
      if (liveEvent.type === "action_opened") {
        resolve(liveEvent.action);
      }
    });
  });
}

async function settleProviderWrites(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 20));
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
