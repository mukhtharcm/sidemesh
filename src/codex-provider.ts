import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { access, stat } from "node:fs/promises";
import nodePath from "node:path";

import {
  AgentProviderRequestError,
  type AgentAccessModeListOptions,
  type AgentModelListOptions,
  type AgentProfileListOptions,
  type AgentPermissionProfileListOptions,
  type AgentSkillConfigWriteRequest,
  type AgentSkillListOptions,
  type AgentSessionListOptions,
  type AgentSessionResumeOptions,
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
  type AgentPendingAction,
  type AgentProvider,
  type AgentProviderCapabilities,
  type AgentProviderEvents,
  type AgentSessionLogOptions,
  type AgentSessionActivityDraft,
  type AgentSubmitInputRequest,
  type AgentSubmitInputResult,
} from "./agent-provider.js";
import {
  normalizePendingActionDecision,
  parsePendingActionElicitationResponse,
  parsePendingActionUserInputResponse,
  type PendingActionDecisionInput,
  type PendingActionResponseInput,
} from "./approvals.js";
import {
  buildActivityFromThreadItem,
  buildFileChangeChanges,
  buildTurnDiffActivity,
} from "./activity.js";
import { CodexBridge } from "./codex-client.js";
import {
  listRecentRolloutThreads,
  loadRolloutLog,
  loadSessionRuntime,
  subAgentInfoFromCodexSource,
} from "./codex-history.js";
import type {
  LivePlanStep,
  LiveThreadStatus,
  ModelSummary,
  PendingActionKind,
  ProviderAccessModeCatalog,
  ProviderAccessModeSummary,
  ProviderProfileCatalog,
  ProviderPermissionProfileCatalog,
  ProviderPermissionModeSummary,
  ProviderPermissionProfileSummary,
  ProviderProfileSummary,
  ProviderWarningLevel,
  SessionActivity,
  SessionLogSnapshot,
  SessionRuntimeSummary,
  SkillCatalogEntry,
  SkillErrorInfo,
  SkillSummary,
  ThreadRecord,
  SessionMessageContentBlock,
  SessionMessageContentBlockThinking,
  PendingActionElicitationField,
  UsageAccountRef,
  UsageCredits,
  UsageObservation,
  UsageWindow,
} from "./types.js";
import type { AgentSessionInputItem } from "./agent-provider.js";

const PROVIDER_MODEL_LIST_TIMEOUT_MS = 2500;
const CODEX_THREAD_SOURCES = [
  "cli",
  "vscode",
  "exec",
  "appServer",
  "subAgentThreadSpawn",
] as const;

interface ConfigModelProviderSummary {
  id: string;
  name: string | null;
  baseUrl: string | null;
  envKey: string | null;
}

interface CodexProfileConfig {
  defaultProfile: string | null;
  profiles: ProviderProfileSummary[];
  modelProvider: string | null;
  openaiBaseUrl: string | null;
  modelProviders: Map<string, ConfigModelProviderSummary>;
}

export class CodexAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  private readonly bridge: CodexBridge;
  private readonly turnReasoningBlocks = new Map<
    string,
    SessionMessageContentBlock[]
  >();

  public readonly kind = "codex";
  public readonly displayName = "Codex";
  public readonly capabilities = CODEX_PROVIDER_CAPABILITIES;

  public constructor(private readonly codexBin: string) {
    super();
    this.bridge = new CodexBridge(codexBin);
    this.bridge.on("notification", (message) => {
      this.emitCodexNotification(message.method, message.params);
    });
    this.bridge.on("serverRequest", (message) => {
      this.emitCodexServerRequest(message.id, message.method, message.params);
    });
    this.bridge.on("stderr", (line) => this.emit("stderr", line));
    this.bridge.on("exit", (code) => this.emit("exit", code));
  }

  public get runtimeHome(): string | null {
    return this.bridge.codexHome;
  }

  public async start(): Promise<void> {
    await this.bridge.start();
  }

  public async close(): Promise<void> {
    await this.bridge.close();
  }

  public async restart(): Promise<void> {
    this.emit("stderr", "[codex-provider] Restarting app-server...\n");
    await this.bridge.close();
    await this.bridge.start();
  }

public async health(): Promise<boolean> {
    return this.bridge.isAlive;
  }

  public async getVersion(): Promise<string> {
    try {
      return execFileSync(this.codexBin, ["--version"], { encoding: "utf8" }).trim();
    } catch {
      return "unknown";
    }
  }

  public async readUsageObservations(): Promise<UsageObservation[]> {
    const observedAt = Date.now();
    let accountResult: unknown = null;
    try {
      accountResult = await this.bridge.request<unknown>("account/read", {});
    } catch {
      // Rate-limit data is still useful without identity metadata.
    }
    try {
      const limitsResult = await this.bridge.request<unknown>(
        "account/rateLimits/read",
        {},
      );
      const observation = buildCodexUsageObservation(
        accountResult,
        limitsResult,
        observedAt,
      );
      return [observation];
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return [buildCodexUsageErrorObservation(observedAt, message)];
    }
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    const threads: ThreadRecord[] = [];
    let cursor: string | null = null;
    do {
      const result = (await this.bridge.request("thread/list", {
        limit: options.limit,
        ...(cursor ? { cursor } : {}),
        sortKey: "updated_at",
        sortDirection: "desc",
        sourceKinds: CODEX_THREAD_SOURCES,
        archived: options.archived,
      })) as { data?: unknown[]; nextCursor?: unknown };
      const page = Array.isArray(result.data)
        ? (result.data as ThreadRecord[]).map(normalizeCodexThreadRecord)
        : [];
      threads.push(
        ...page.filter((thread) => {
          if (options.subAgentParentId) {
            return thread.subAgent?.parentSessionId === options.subAgentParentId;
          }
          return options.includeSubAgents || thread.subAgent == null;
        }),
      );
      cursor = asString(result.nextCursor);
    } while (threads.length < options.limit && cursor);
    return threads.slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    const result = (await this.bridge.request("thread/read", {
      threadId,
      includeTurns,
    })) as { thread?: unknown };
    if (!result.thread || typeof result.thread !== "object") {
      throw new Error("thread/read did not return a thread");
    }
    return normalizeCodexThreadRecord(result.thread as ThreadRecord);
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    const result = (await this.bridge.request("thread/loaded/list", {})) as {
      data?: unknown[];
    };
    return Array.isArray(result.data)
      ? result.data.filter((item): item is string => typeof item === "string")
      : [];
  }

  public resumeSessionThread(
    threadId: string,
    options?: AgentSessionResumeOptions,
  ): Promise<unknown> {
    return this.bridge.request("thread/resume", { threadId, ...(options ?? {}) });
  }

  public setSessionName(threadId: string, name: string): Promise<unknown> {
    return this.bridge.request("thread/name/set", { threadId, name });
  }

  public archiveSession(threadId: string): Promise<unknown> {
    return this.bridge.request("thread/archive", { threadId });
  }

  public unarchiveSession(threadId: string): Promise<unknown> {
    return this.bridge.request("thread/unarchive", { threadId });
  }

  public async compactSession(threadId: string): Promise<unknown> {
    if (!(await this.isSessionThreadLoaded(threadId))) {
      await this.resumeSessionThread(
        threadId,
        await this.buildResumeOptionsForThread(threadId, null),
      );
    }
    return this.bridge.request("thread/compact/start", { threadId });
  }

  public async listRecentUnindexedSessionThreads(limit: number): Promise<ThreadRecord[]> {
    return listRecentRolloutThreads(this.runtimeHome, limit);
  }

  public readSessionLog(
    thread: ThreadRecord,
    options: AgentSessionLogOptions = {},
  ): Promise<SessionLogSnapshot> {
    return loadRolloutLog(
      thread.id,
      thread.path,
      this.runtimeHome,
      options.messageLimit ?? null,
      options.activityLimit ?? null,
    );
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    const runtime = await loadSessionRuntime(
      thread.id,
      thread.path,
      this.runtimeHome,
    );
    if (runtime) {
      runtime.accessMode = codexAccessModeFromRuntime(runtime);
    }
    return runtime;
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    const resolvedRequest = {
      ...request,
      overrides: await this.resolveAccessModeOverrides(
        request.overrides,
        request.cwd,
      ),
    };
    const started = (await this.bridge.request(
      "thread/start",
      buildCodexThreadStartParams(resolvedRequest),
    )) as Record<string, unknown>;
    const thread = started.thread as ThreadRecord;
    const runtime = buildRuntimeFromThreadStart(started);
    if (runtime && !runtime.accessMode) {
      runtime.accessMode = cleanOptionalString(request.overrides.accessMode) ?? undefined;
    }

    let activeTurnId: string | null = null;
    if (request.input.length > 0) {
      const turn = (await this.bridge.request("turn/start", {
        threadId: thread.id,
        input: normalizeCodexInput(request.input),
      })) as Record<string, unknown>;
      activeTurnId = asString(
        (turn.turn as Record<string, unknown> | undefined)?.id,
      );
    }

    return {
      thread,
      activeTurnId,
      runtime,
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    if (request.activeTurnId) {
      const steer = (await this.bridge.request("turn/steer", {
        threadId: request.sessionId,
        input: normalizeCodexInput(request.input),
        expectedTurnId: request.activeTurnId,
      })) as Record<string, unknown>;
      return {
        mode: "steer",
        turnId: asString(steer.turnId) || request.activeTurnId,
      };
    }

    const resolvedRequest = {
      ...request,
      overrides: await this.resolveAccessModeOverridesForSession(
        request.sessionId,
        request.overrides,
      ),
    };

    if (!(await this.isSessionThreadLoaded(request.sessionId))) {
      await this.resumeSessionThread(
        request.sessionId,
        await this.buildResumeOptionsForSubmit(resolvedRequest),
      );
    }

    const turn = (await this.bridge.request(
      "turn/start",
      buildCodexTurnStartParams(resolvedRequest),
    )) as Record<string, unknown>;
    return {
      mode: "turn",
      turnId: asString(
        (turn.turn as Record<string, unknown> | undefined)?.id,
      ),
    };
  }

  public interruptTurn(threadId: string, turnId: string): Promise<unknown> {
    return this.bridge.request("turn/interrupt", { threadId, turnId });
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean {
    const result = buildCodexActionResponse(action, decision);
    if (!result) {
      return false;
    }
    this.bridge.respond(action.providerRequestId, result);
    return true;
  }

  public async listSkills(options: AgentSkillListOptions): Promise<SkillCatalogEntry> {
    return listCodexSkills(this.bridge, options);
  }

  public writeSkillConfig(request: AgentSkillConfigWriteRequest): Promise<unknown> {
    return this.bridge.request("skills/config/write", {
      path: request.path ?? undefined,
      name: request.name ?? undefined,
      enabled: request.enabled,
    });
  }

  public listModels(options: AgentModelListOptions): Promise<ModelSummary[]> {
    return listCodexModels(this.bridge, options);
  }

  public async listProfiles(
    options: AgentProfileListOptions,
  ): Promise<ProviderProfileCatalog> {
    const profileConfig = await readCodexProfileConfig(this.bridge, options.cwd);
    return {
      defaultProfile: profileConfig.defaultProfile,
      profiles: profileConfig.profiles,
    };
  }

  public async listAccessModes(
    options: AgentAccessModeListOptions,
  ): Promise<ProviderAccessModeCatalog> {
    const catalog = await this.listPermissionProfiles(options);
    return {
      strategy: "modes",
      modes: catalog.modes.map(codexAccessModeSummary),
      defaultMode: catalog.defaultMode,
    };
  }

  public async listPermissionProfiles(
    options: AgentPermissionProfileListOptions,
  ): Promise<ProviderPermissionProfileCatalog> {
    const profiles: ProviderPermissionProfileSummary[] = [];
    let cursor: string | null = null;
    do {
      const response = (await this.bridge.request("permissionProfile/list", {
        cwd: options.cwd,
        cursor,
        limit: 100,
      })) as Record<string, unknown>;
      const data = Array.isArray(response.data) ? response.data : [];
      for (const item of data) {
        if (!item || typeof item !== "object") {
          continue;
        }
        const typed = item as Record<string, unknown>;
        const id = asString(typed.id);
        if (!id) {
          continue;
        }
        profiles.push({
          id,
          label: codexPermissionProfileLabel(id),
          description:
            asString(typed.description) ?? codexPermissionProfileDescription(id),
          allowed: typed.allowed === true,
        });
      }
      cursor = asString(response.nextCursor);
    } while (cursor);

    const [requirementsResponse, featuresResponse, configResponse] =
      await Promise.all([
        this.bridge
          .request("configRequirements/read", undefined)
          .catch(() => ({ requirements: null })),
        this.bridge
          .request("experimentalFeature/list", {
            cursor: null,
            limit: 100,
          })
          .catch(() => ({ data: [] })),
        this.bridge
          .request("config/read", { cwd: options.cwd })
          .catch(() => ({ config: {} })),
      ]);
    const requirements = asRecord(
      asRecord(requirementsResponse)?.requirements,
    );
    const allowedReviewers = asStringArray(
      requirements?.allowedApprovalsReviewers,
    );
    const allowedApprovalPolicies = asStringArray(
      requirements?.allowedApprovalPolicies,
    );
    const reviewerAllowed = (id: string) =>
      allowedReviewers === null || allowedReviewers.includes(id);
    const approvalPolicyAllowed = (id: string) =>
      allowedApprovalPolicies === null || allowedApprovalPolicies.includes(id);
    const features = Array.isArray(asRecord(featuresResponse)?.data)
      ? (asRecord(featuresResponse)!.data as unknown[])
      : [];
    const autoReviewEnabled = features.some((feature) => {
      const typed = asRecord(feature);
      return typed?.name === "guardian_approval" && typed.enabled === true;
    });
    const reviewerOptions = [
      ...(reviewerAllowed("user")
        ? [
            {
              id: "user",
              label: "Ask for approval",
              description:
                "Always ask before editing external files or using the internet.",
            },
          ]
        : []),
      ...(autoReviewEnabled && reviewerAllowed("auto_review")
        ? [
            {
              id: "auto_review",
              label: "Approve for me",
              description:
                "Only ask for actions detected as potentially unsafe.",
            },
          ]
        : []),
    ];
    const allowedProfileIds = new Set(
      profiles.filter((profile) => profile.allowed).map((profile) => profile.id),
    );
    const modes: ProviderPermissionModeSummary[] = [];
    if (
      allowedProfileIds.has(":workspace") &&
      reviewerAllowed("user") &&
      approvalPolicyAllowed("on-request")
    ) {
      modes.push({
        id: "ask-for-approval",
        label: "Ask for approval",
        description:
          "Always ask before editing external files or using the internet.",
        permissionProfile: ":workspace",
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        dangerous: false,
        usesProviderDefaults: false,
      });
    }
    if (
      allowedProfileIds.has(":workspace") &&
      autoReviewEnabled &&
      reviewerAllowed("auto_review") &&
      approvalPolicyAllowed("on-request")
    ) {
      modes.push({
        id: "approve-for-me",
        label: "Approve for me",
        description: "Only ask for actions detected as potentially unsafe.",
        permissionProfile: ":workspace",
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review",
        dangerous: false,
        usesProviderDefaults: false,
      });
    }
    if (
      allowedProfileIds.has(":read-only") &&
      reviewerAllowed("user") &&
      approvalPolicyAllowed("on-request")
    ) {
      modes.push({
        id: "read-only",
        label: "Read only",
        description:
          "Inspect the workspace without changing files or accessing the internet.",
        permissionProfile: ":read-only",
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        dangerous: false,
        usesProviderDefaults: false,
      });
    }
    if (
      allowedProfileIds.has(":danger-full-access") &&
      reviewerAllowed("user") &&
      approvalPolicyAllowed("never")
    ) {
      modes.push({
        id: "full-access",
        label: "Full access",
        description:
          "Unrestricted access to the internet and any file on this computer.",
        permissionProfile: ":danger-full-access",
        approvalPolicy: "never",
        approvalsReviewer: "user",
        dangerous: true,
        usesProviderDefaults: false,
      });
    }
    modes.push({
      id: "custom",
      label: "Provider configuration",
      description: "Use the permissions configured for Codex on this host.",
      permissionProfile: null,
      approvalPolicy: null,
      approvalsReviewer: null,
      dangerous: false,
      usesProviderDefaults: true,
    });

    const config = asRecord(asRecord(configResponse)?.config);
    const configuredProfile = asString(config?.default_permissions);
    const configuredApproval = asString(config?.approval_policy);
    const configuredReviewer =
      parseCodexApprovalsReviewer(asString(config?.approvals_reviewer)) ?? "user";
    const defaultMode =
      modes.find(
        (mode) =>
          !mode.usesProviderDefaults &&
          mode.permissionProfile === configuredProfile &&
          mode.approvalPolicy === configuredApproval &&
          mode.approvalsReviewer === configuredReviewer,
      )?.id ?? "custom";

    return {
      strategy: "profiles",
      profiles,
      reviewerOptions,
      modes,
      defaultMode,
    };
  }

  private async resolveAccessModeOverridesForSession(
    sessionId: string,
    overrides: AgentSubmitInputRequest["overrides"],
  ): Promise<AgentSubmitInputRequest["overrides"]> {
    if (!cleanOptionalString(overrides.accessMode)) {
      return overrides;
    }
    const thread = await this.readSessionThread(sessionId, false);
    return this.resolveAccessModeOverrides(overrides, thread.cwd ?? null);
  }

  private async resolveAccessModeOverrides(
    overrides: AgentCreateSessionRequest["overrides"],
    cwd: string | null,
  ): Promise<AgentCreateSessionRequest["overrides"]> {
    const accessMode = cleanOptionalString(overrides.accessMode);
    if (!accessMode) {
      return overrides;
    }
    const catalog = await this.listPermissionProfiles({ cwd });
    const mode = catalog.modes.find((candidate) => candidate.id === accessMode);
    if (!mode) {
      throw new AgentProviderRequestError(
        `Codex access mode is unavailable: ${accessMode}`,
      );
    }
    if (mode.usesProviderDefaults) {
      const response = await this.bridge.request("config/read", { cwd });
      const config = asRecord(asRecord(response)?.config);
      return {
        ...overrides,
        approvalPolicy: asString(config?.approval_policy) ?? "on-request",
        sandboxMode: null,
        networkAccess: null,
        permissionProfile:
          asString(config?.default_permissions) ?? ":workspace",
        approvalsReviewer:
          parseCodexApprovalsReviewer(asString(config?.approvals_reviewer)) ??
          "user",
      };
    }
    return {
      ...overrides,
      approvalPolicy: mode.approvalPolicy,
      sandboxMode: null,
      networkAccess: null,
      permissionProfile: mode.permissionProfile,
      approvalsReviewer: mode.approvalsReviewer,
    };
  }

  private async isSessionThreadLoaded(sessionId: string): Promise<boolean> {
    const data = await this.listLoadedSessionIds();
    return data.includes(sessionId);
  }

  private async buildResumeOptionsForSubmit(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSessionResumeOptions> {
    return this.buildResumeOptionsForThread(request.sessionId, request.overrides);
  }

  private async buildResumeOptionsForThread(
    threadId: string,
    overrides: AgentSubmitInputRequest["overrides"] | null,
  ): Promise<AgentSessionResumeOptions> {
    const options: AgentSessionResumeOptions = {
      persistExtendedHistory: true,
    };
    const thread = await this.readSessionThread(threadId, false).catch(() => null);
    if (!thread) {
      return options;
    }
    const runtime = await this.readSessionRuntime(thread).catch(() => null);
    if (!runtime) {
      return options;
    }

    const model = overrides?.model || runtime.model || null;
    if (model) {
      options.model = model;
    }

    if (runtime.modelProvider) {
      options.modelProvider = runtime.modelProvider;
    }

    if (overrides?.fastMode !== null && overrides?.fastMode !== undefined) {
      options.serviceTier = overrides.fastMode ? "fast" : null;
    } else if (runtime.serviceTier) {
      options.serviceTier = runtime.serviceTier;
    }

    const approvalPolicy = parseCodexApprovalPolicy(
      overrides?.approvalPolicy ?? runtime.approvalPolicy ?? null,
    );
    const permissionProfile =
      overrides?.permissionProfile ?? runtime.permissionProfile ?? null;
    if (permissionProfile) {
      options.permissions = permissionProfile;
    }
    if (approvalPolicy) {
      options.approvalPolicy = approvalPolicy;
    }

    const approvalsReviewer = parseCodexApprovalsReviewer(
      overrides?.approvalsReviewer ?? runtime.approvalsReviewer ?? null,
    );
    if (approvalsReviewer) {
      options.approvalsReviewer = approvalsReviewer;
    }

    const sandboxMode = parseCodexSandboxMode(
      overrides?.sandboxMode ?? runtime.sandboxMode ?? null,
    );
    if (!permissionProfile && sandboxMode) {
      options.sandbox = sandboxMode;
    }

    const config: Record<string, unknown> = {};
    const reasoningEffort = parseCodexReasoningEffort(
      overrides?.reasoningEffort ?? runtime.reasoningEffort ?? null,
    );
    if (reasoningEffort) {
      config.model_reasoning_effort = reasoningEffort;
    }
    if (Object.keys(config).length > 0) {
      options.config = config;
    }

    return options;
  }

  private emitCodexNotification(method: string, params: unknown): void {
    if (method === "skills/changed") {
      this.emit("liveEvent", { type: "skills_changed" });
      return;
    }

    if (method === "thread/tokenUsage/updated") {
      const runtime = buildRuntimeFromCodexTokenUsage(params);
      if (runtime) {
        this.emit("liveEvent", {
          type: "runtime_updated",
          sessionId: runtime.sessionId,
          runtime: runtime.runtime,
        });
      }
      return;
    }

    if (
      method === "warning" ||
      method === "guardianWarning" ||
      method === "deprecationNotice" ||
      method === "configWarning"
    ) {
      const warning = buildCodexProviderWarning(method, params);
      if (warning) {
        this.emit("liveEvent", warning);
      }
      return;
    }

    const sessionId = extractSessionId(method, params);
    if (!sessionId) {
      return;
    }

    const typed = params && typeof params === "object"
      ? (params as Record<string, unknown>)
      : {};

    if (method === "turn/started") {
      const turn = typed.turn && typeof typed.turn === "object"
        ? (typed.turn as Record<string, unknown>)
        : null;
      const turnId = asString(turn?.id);
      if (turnId) {
        this.turnReasoningBlocks.delete(turnId);
        this.emit("liveEvent", { type: "turn_started", sessionId, turnId });
      }
      return;
    }

    if (method === "thread/status/changed") {
      const normalized = normalizeCodexThreadStatus(typed.status);
      this.emit("liveEvent", {
        type: "thread_status_changed",
        sessionId,
        status: normalized.status,
        message: normalized.message,
        pendingActionKind: normalized.pendingActionKind,
      });
      return;
    }

    if (method === "turn/plan/updated") {
      this.emit("liveEvent", {
        type: "plan_updated",
        sessionId,
        turnId: asString(typed.turnId) || undefined,
        explanation: asString(typed.explanation) || undefined,
        plan: buildCodexPlanSteps(typed.plan),
      });
      return;
    }

    if (
      method === "item/reasoning/summaryTextDelta" ||
      method === "item/reasoning/textDelta"
    ) {
      const delta = asString(typed.delta);
      const itemId = asString(typed.itemId);
      const turnId = asString(typed.turnId) || sessionId;
      if (!delta || !itemId) {
        return;
      }
      let blocks = this.turnReasoningBlocks.get(turnId);
      if (!blocks) {
        blocks = [];
        this.turnReasoningBlocks.set(turnId, blocks);
      }
      const existing = blocks.find(
        (b): b is SessionMessageContentBlockThinking =>
          b.type === "thinking" && b.reasoningId === itemId,
      );
      if (existing) {
        existing.thinking += delta;
      } else {
        blocks.push({
          type: "thinking",
          thinking: delta,
          reasoningId: itemId,
          summary: method === "item/reasoning/summaryTextDelta",
        });
      }
      this.emit("liveEvent", {
        type: "reasoning_delta",
        sessionId,
        turnId: asString(typed.turnId) || undefined,
        itemId,
        reasoningId: itemId,
        delta,
        summary: method === "item/reasoning/summaryTextDelta",
      });
      return;
    }

    if (method === "item/agentMessage/delta") {
      const delta = asString(typed.delta);
      if (delta) {
        this.emit("liveEvent", {
          type: "assistant_delta",
          sessionId,
          delta,
          turnId: asString(typed.turnId) || undefined,
          itemId: asString(typed.itemId) || undefined,
        });
      }
      return;
    }

    if (method === "item/started" || method === "item/completed") {
      const item = typed.item && typeof typed.item === "object"
        ? (typed.item as Record<string, unknown>)
        : null;
      const turnId = asString(typed.turnId);
      if (!item) {
        return;
      }

      const itemType = asString(item.type);
      if (method === "item/completed" && itemType === "agentMessage") {
        const content = turnId
          ? this.turnReasoningBlocks.get(turnId) ?? []
          : [];
        const message = buildCodexAssistantMessageDraft(item, content);
        if (turnId) {
          this.turnReasoningBlocks.delete(turnId);
        }
        if (message) {
          this.emit("liveEvent", {
            type: "assistant_message_completed",
            sessionId,
            turnId: turnId || undefined,
            message,
          });
        }
        return;
      }

      const activity = buildActivityFromThreadItem(item as any, {
        turnId,
        createdAt: 0,
        seq: 0,
        lifecycleStatus: codexItemLifecycleStatus(method, item.status),
      });
      const draft = activity ? toActivityDraft(activity) : null;
      if (draft) {
        this.emit("liveEvent", {
          type: "activity_updated",
          sessionId,
          turnId: turnId || undefined,
          activity: draft,
        });
      }
      return;
    }

    if (method === "item/commandExecution/outputDelta") {
      const delta = asString(typed.delta);
      const activityId = asString(typed.itemId);
      if (delta && activityId) {
        this.emit("liveEvent", {
          type: "activity_output_delta",
          sessionId,
          turnId: asString(typed.turnId) || undefined,
          activityId,
          delta,
        });
      }
      return;
    }

    if (method === "item/commandExecution/terminalInteraction") {
      const stdin = asString(typed.stdin);
      const activityId = asString(typed.itemId);
      if (stdin && activityId) {
        this.emit("liveEvent", {
          type: "activity_terminal_input",
          sessionId,
          turnId: asString(typed.turnId) || undefined,
          activityId,
          stdin,
        });
      }
      return;
    }

    if (method === "item/fileChange/patchUpdated") {
      const activityId = asString(typed.itemId);
      if (activityId) {
        this.emit("liveEvent", {
          type: "activity_updated",
          sessionId,
          turnId: asString(typed.turnId) || undefined,
          activity: {
            id: activityId,
            type: "file_change",
            turnId: asString(typed.turnId),
            status: "in_progress",
            changes: buildFileChangeChanges(typed.changes),
          },
        });
      }
      return;
    }

    if (method === "turn/diff/updated") {
      const turnId = asString(typed.turnId);
      const diff = asString(typed.diff);
      if (!turnId || !diff) {
        return;
      }
      const activity = buildTurnDiffActivity(turnId, diff, 0, 0);
      const draft = activity ? toActivityDraft(activity) : null;
      if (draft) {
        this.emit("liveEvent", {
          type: "activity_updated",
          sessionId,
          turnId,
          activity: draft,
        });
      }
      return;
    }

    if (method === "turn/completed") {
      const turn = typed.turn && typeof typed.turn === "object"
        ? (typed.turn as Record<string, unknown>)
        : null;
      const turnId = asString(turn?.id);
      if (turnId) {
        this.turnReasoningBlocks.delete(turnId);
        this.emit("liveEvent", {
          type: "turn_completed",
          sessionId,
          turnId,
          status: asString(turn?.status) || "completed",
        });
      }
    }
  }

  private emitCodexServerRequest(
    id: number | string,
    method: string,
    params: unknown,
  ): void {
    if (
      method !== "item/commandExecution/requestApproval" &&
      method !== "item/fileChange/requestApproval" &&
      method !== "item/permissions/requestApproval" &&
      method !== "item/tool/requestUserInput" &&
      method !== "mcpServer/elicitation/request"
    ) {
      const sessionId = extractSessionId(method, params);
      if (sessionId) {
        this.emit("liveEvent", {
          type: "provider_warning",
          sessionId,
          level: "warning",
          code: "unsupported_request",
          message: `Unsupported Codex server request: ${method}`,
          source: "codex",
        });
      }
      this.emit(
        "stderr",
        `[codex-provider] Unsupported server request: ${method}\n`,
      );
      this.bridge.error(id, -32601, "Method not found");
      return;
    }

    const sessionId = extractSessionId(method, params);
    if (!sessionId) {
      this.bridge.error(id, -32600, "Invalid request params");
      return;
    }

    let action: AgentPendingAction | null = null;
    if (
      method === "item/commandExecution/requestApproval" ||
      method === "item/fileChange/requestApproval" ||
      method === "item/permissions/requestApproval"
    ) {
      action = buildCodexPendingAction(method, params, id, sessionId);
    } else if (method === "item/tool/requestUserInput") {
      action = buildCodexUserInputAction(params, id, sessionId);
    } else if (method === "mcpServer/elicitation/request") {
      action = buildCodexElicitationAction(params, id, sessionId);
    }

    if (!action) {
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId,
        level: "warning",
        code: "invalid_request",
        message: `Malformed ${method} request params`,
        source: "codex",
      });
      this.bridge.error(id, -32600, "Invalid request params");
      return;
    }

    if (
      method === "item/tool/requestUserInput" &&
      Array.isArray((params as Record<string, any>)?.questions) &&
      (params as Record<string, any>).questions.length > 1
    ) {
      this.emit("liveEvent", {
        type: "provider_warning",
        sessionId,
        level: "info",
        code: "multi_question_truncated",
        message: "Codex sent multiple questions; only the first is shown.",
        source: "codex",
      });
    }

    this.emit("liveEvent", {
      type: "action_opened",
      action,
    });
  }
}

function buildCodexUsageObservation(
  accountResult: unknown,
  limitsResult: unknown,
  observedAt: number,
): UsageObservation {
  const account = normalizeCodexUsageAccount(accountResult);
  const limits = objectRecord(limitsResult);
  const rateLimits = objectRecord(limits?.rateLimits) ?? limits;
  const windows = [
    buildCodexUsageWindow(
      objectRecord(rateLimits?.primary),
      "primary",
      "Primary",
    ),
    buildCodexUsageWindow(
      objectRecord(rateLimits?.secondary),
      "secondary",
      "Secondary",
    ),
  ].filter((window): window is UsageWindow => window !== null);
  const credits = buildCodexUsageCredits(objectRecord(rateLimits?.credits));
  const stableKeyHash =
    account.accountIdHash ?? account.emailHash ?? null;
  const displayLabel =
    account.displayLabel ||
    (account.planType ? `Codex ${capitalizeLabel(account.planType)}` : "Codex account");

  return {
    id: stableKeyHash ? `codex:${stableKeyHash}` : "codex:account",
    observedAt,
    expiresAt: observedAt + 5 * 60_000,
    provider: {
      kind: "codex",
      displayName: "Codex",
    },
    account,
    subject: {
      kind: stableKeyHash ? "account" : "unknown",
      displayName: displayLabel,
      stableKeyHash,
    },
    windows,
    credits,
    health: windows.length > 0 || credits ? "ok" : "unavailable",
    source: {
      id: "codex.accountRateLimits",
      label: "Codex account limits",
      kind: "providerRpc",
      priority: 100,
    },
    message:
      windows.length > 0 || credits
        ? undefined
        : "Codex did not return account usage windows.",
  };
}

function buildCodexUsageErrorObservation(
  observedAt: number,
  message: string,
): UsageObservation {
  return {
    id: "codex:account:error",
    observedAt,
    expiresAt: observedAt + 60_000,
    provider: {
      kind: "codex",
      displayName: "Codex",
    },
    account: null,
    subject: {
      kind: "unknown",
      displayName: "Codex account",
      stableKeyHash: null,
    },
    windows: [],
    health: "error",
    source: {
      id: "codex.accountRateLimits",
      label: "Codex account limits",
      kind: "providerRpc",
      priority: 100,
    },
    message,
  };
}

function normalizeCodexUsageAccount(accountResult: unknown): UsageAccountRef {
  const root = objectRecord(accountResult);
  const account = objectRecord(root?.account) ?? root;
  const email = normalizeOptionalString(
    account?.email ?? root?.email,
  );
  const accountId = normalizeOptionalString(
    account?.id ?? account?.accountId ?? account?.account_id ?? root?.accountId,
  );
  const planType = normalizeOptionalString(
    account?.planType ?? account?.plan_type ?? root?.planType ?? root?.plan_type,
  );
  const type = normalizeOptionalString(account?.type ?? root?.type);
  const normalizedType = type?.toLowerCase() ?? null;
  const accountIdHash = accountId ? hashUsageIdentity(`codex:account:${accountId}`) : null;
  const emailHash = email ? hashUsageIdentity(`codex:email:${email.toLowerCase()}`) : null;
  return {
    displayLabel: email ? maskEmail(email) : normalizedType === "apikey" ? "API key" : null,
    accountIdHash,
    emailHash,
    planType,
    loginMethod: type,
  };
}

function buildCodexUsageWindow(
  raw: Record<string, unknown> | null,
  id: string,
  label: string,
): UsageWindow | null {
  if (!raw) {
    return null;
  }
  const usedPercent = clampPercent(
    asNumber(raw.usedPercent) ?? asNumber(raw.used_percent),
  );
  const windowMinutes = integerOrNull(
    asNumber(raw.windowDurationMins) ??
      asNumber(raw.window_duration_mins) ??
      asNumber(raw.windowMinutes) ??
      asNumber(raw.window_minutes) ??
      secondsToMinutes(asNumber(raw.limitWindowSeconds) ?? asNumber(raw.limit_window_seconds)),
  );
  const resetsAt = normalizeEpochMillis(
    asNumber(raw.resetsAt) ?? asNumber(raw.resets_at) ?? asNumber(raw.resetAt) ?? asNumber(raw.reset_at),
  );
  if (usedPercent == null && windowMinutes == null && resetsAt == null) {
    return null;
  }
  return {
    id,
    label,
    usedPercent,
    remainingPercent: usedPercent == null ? null : clampPercent(100 - usedPercent),
    windowMinutes,
    resetsAt,
    resetDescription: resetsAt == null ? null : resetDescription(resetsAt),
  };
}

function buildCodexUsageCredits(raw: Record<string, unknown> | null): UsageCredits | null {
  if (!raw) {
    return null;
  }
  const balanceValue = raw.balance;
  const balanceLabel =
    typeof balanceValue === "string"
      ? balanceValue
      : typeof balanceValue === "number" && Number.isFinite(balanceValue)
        ? String(balanceValue)
        : null;
  const balance =
    typeof balanceValue === "number" && Number.isFinite(balanceValue)
      ? balanceValue
      : typeof balanceValue === "string"
        ? Number.parseFloat(balanceValue)
        : null;
  const hasCredits = typeof raw.hasCredits === "boolean" ? raw.hasCredits : null;
  const unlimited = typeof raw.unlimited === "boolean" ? raw.unlimited : null;
  if (balance == null && balanceLabel == null && hasCredits == null && unlimited == null) {
    return null;
  }
  return {
    balance: balance == null || Number.isNaN(balance) ? null : balance,
    balanceLabel,
    hasCredits,
    unlimited,
  };
}

function objectRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function normalizeOptionalString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0
    ? value.trim()
    : null;
}

function hashUsageIdentity(value: string): string {
  return createHash("sha256").update(value).digest("hex").slice(0, 32);
}

function maskEmail(email: string): string {
  const [name, domain] = email.split("@", 2);
  if (!name || !domain) {
    return email;
  }
  const prefix = name.slice(0, Math.min(2, name.length));
  return `${prefix}${name.length > 2 ? "***" : "*"}@${domain}`;
}

function clampPercent(value: number | null): number | null {
  if (value == null) {
    return null;
  }
  return Math.max(0, Math.min(100, value));
}

function secondsToMinutes(value: number | null): number | null {
  return value == null ? null : value / 60;
}

function integerOrNull(value: number | null): number | null {
  return value == null ? null : Math.round(value);
}

function normalizeEpochMillis(value: number | null): number | null {
  if (value == null || value <= 0) {
    return null;
  }
  return value < 10_000_000_000 ? Math.round(value * 1000) : Math.round(value);
}

function resetDescription(resetsAt: number): string {
  const deltaMs = resetsAt - Date.now();
  if (deltaMs <= 0) {
    return "now";
  }
  const minutes = Math.round(deltaMs / 60_000);
  if (minutes < 60) {
    return `${minutes}m`;
  }
  const hours = Math.round(minutes / 60);
  if (hours < 48) {
    return `${hours}h`;
  }
  const days = Math.round(hours / 24);
  return `${days}d`;
}

function capitalizeLabel(value: string): string {
  return value.length === 0 ? value : `${value[0]!.toUpperCase()}${value.slice(1)}`;
}

function buildRuntimeFromCodexTokenUsage(
  params: unknown,
): { sessionId: string; runtime: SessionRuntimeSummary } | null {
  const typed = params && typeof params === "object"
    ? (params as Record<string, unknown>)
    : null;
  const sessionId = asString(typed?.threadId);
  if (!typed || !sessionId) {
    return null;
  }

  const usage = typed.tokenUsage && typeof typed.tokenUsage === "object"
    ? (typed.tokenUsage as Record<string, unknown>)
    : null;
  if (!usage) {
    return null;
  }

  const last = usage.last && typeof usage.last === "object"
    ? (usage.last as Record<string, unknown>)
    : null;
  const total = usage.total && typeof usage.total === "object"
    ? (usage.total as Record<string, unknown>)
    : null;
  const tokenLimit = asNumber(usage.modelContextWindow) ?? 0;
  const currentTokens = asNumber(last?.totalTokens) ?? asNumber(total?.totalTokens) ?? 0;
  const updatedAt = Date.now();

  return {
    sessionId,
    runtime: {
      telemetry: {
        contextWindow: {
          currentTokens,
          tokenLimit,
          messagesLength: 0,
          updatedAt,
        },
        lastUsage: {
          inputTokens: asNumber(last?.inputTokens) ?? undefined,
          outputTokens: asNumber(last?.outputTokens) ?? undefined,
          reasoningTokens: asNumber(last?.reasoningOutputTokens) ?? undefined,
          cacheReadTokens: asNumber(last?.cachedInputTokens) ?? undefined,
          updatedAt,
        },
      },
      updatedAt,
      turnId: asString(typed.turnId) ?? undefined,
    },
  };
}

function buildCodexAssistantMessageDraft(
  item: Record<string, unknown>,
  content: SessionMessageContentBlock[] = [],
): { id: string; text: string; phase?: "commentary" | "final_answer"; content: SessionMessageContentBlock[] } | null {
  const id = asString(item.id);
  const text = asString(item.text);
  if (!id || !text) {
    return null;
  }

  const phase = asString(item.phase);
  const blocks: SessionMessageContentBlock[] = [...content];
  if (text.trim()) {
    blocks.push({ type: "text", text });
  }
  return {
    id,
    text,
    phase:
      phase === "commentary" || phase === "final_answer"
        ? phase
        : undefined,
    content: blocks,
  };
}

async function listCodexSkills(
  bridge: CodexBridge,
  options: AgentSkillListOptions,
): Promise<SkillCatalogEntry> {
  const workspaceSkillRoots = await findWorkspaceSkillRoots(options.cwd);
  const payload = (await bridge.request("skills/list", {
    cwds: [options.cwd],
    forceReload: options.forceReload || workspaceSkillRoots.length > 0,
    perCwdExtraUserRoots:
      workspaceSkillRoots.length > 0
        ? [{ cwd: options.cwd, extraUserRoots: workspaceSkillRoots }]
        : null,
  })) as { data?: unknown[] };
  const rawEntries = Array.isArray(payload.data) ? payload.data : [];
  const rawEntry =
    rawEntries.find(
      (entry) => asString((entry as Record<string, unknown>)?.cwd) === options.cwd,
    ) ?? rawEntries[0];

  return normalizeSkillCatalogEntry(rawEntry, options.cwd, workspaceSkillRoots);
}

async function findWorkspaceSkillRoots(cwd: string): Promise<string[]> {
  const workspaceRoot = await findWorkspaceRoot(cwd);
  if (!workspaceRoot) {
    return [];
  }

  const cwdDir = await resolveDirectoryPath(cwd);
  const dirs = dirsBetween(workspaceRoot, cwdDir ?? workspaceRoot);
  const roots: string[] = [];
  const seen = new Set<string>();
  for (const dir of dirs) {
    const candidate = nodePath.join(dir, "skills");
    if (seen.has(candidate)) {
      continue;
    }
    seen.add(candidate);
    if (await isDirectory(candidate)) {
      roots.push(candidate);
    }
  }
  return roots;
}

async function findWorkspaceRoot(cwd: string): Promise<string | null> {
  let current = await resolveDirectoryPath(cwd);
  if (!current) {
    current = nodePath.resolve(cwd);
  }

  for (;;) {
    if (
      (await pathExists(nodePath.join(current, ".git"))) ||
      (await pathExists(nodePath.join(current, ".jj"))) ||
      (await pathExists(nodePath.join(current, ".hg")))
    ) {
      return current;
    }
    const parent = nodePath.dirname(current);
    if (parent === current) {
      return null;
    }
    current = parent;
  }
}

async function resolveDirectoryPath(rawPath: string): Promise<string | null> {
  const resolved = nodePath.resolve(rawPath);
  try {
    const metadata = await stat(resolved);
    return metadata.isDirectory() ? resolved : nodePath.dirname(resolved);
  } catch {
    return null;
  }
}

function dirsBetween(root: string, cwd: string): string[] {
  const resolvedRoot = nodePath.resolve(root);
  const resolvedCwd = nodePath.resolve(cwd);
  const dirs: string[] = [];
  let current = resolvedCwd;
  for (;;) {
    dirs.push(current);
    if (current === resolvedRoot) {
      break;
    }
    const parent = nodePath.dirname(current);
    if (parent === current) {
      return [resolvedRoot];
    }
    current = parent;
  }
  return dirs.reverse();
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}

function normalizeSkillCatalogEntry(
  raw: unknown,
  cwd: string,
  workspaceSkillRoots: string[] = [],
): SkillCatalogEntry {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  return {
    cwd: asString(typed.cwd) || cwd,
    skills: Array.isArray(typed.skills)
      ? typed.skills
          .map((skill) => normalizeSkillSummary(skill, workspaceSkillRoots))
          .filter((skill): skill is SkillSummary => skill !== null)
      : [],
    errors: Array.isArray(typed.errors)
      ? typed.errors
          .map(normalizeSkillErrorInfo)
          .filter((item): item is SkillErrorInfo => item !== null)
      : [],
  };
}

function normalizeSkillSummary(
  raw: unknown,
  workspaceSkillRoots: string[] = [],
): SkillSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const name = asString(typed.name);
  const description = asString(typed.description);
  const path = asString(typed.path);
  if (!name || !description || !path) {
    return null;
  }

  const interfaceValue =
    typed.interface && typeof typed.interface === "object"
      ? (typed.interface as Record<string, unknown>)
      : null;

  return {
    name,
    description,
    shortDescription: asString(typed.shortDescription) || asString(typed.short_description),
    interface: interfaceValue
      ? {
          displayName:
            asString(interfaceValue.displayName) || asString(interfaceValue.display_name),
          shortDescription:
            asString(interfaceValue.shortDescription) ||
            asString(interfaceValue.short_description),
          brandColor:
            asString(interfaceValue.brandColor) || asString(interfaceValue.brand_color),
          defaultPrompt:
            asString(interfaceValue.defaultPrompt) || asString(interfaceValue.default_prompt),
        }
      : null,
    path,
    scope: isUnderAnyPath(path, workspaceSkillRoots)
      ? "repo"
      : asString(typed.scope) || "user",
    enabled: typed.enabled !== false,
  };
}

function isUnderAnyPath(path: string, roots: string[]): boolean {
  if (roots.length === 0) {
    return false;
  }
  const resolvedPath = nodePath.resolve(path);
  return roots.some((root) => {
    const resolvedRoot = nodePath.resolve(root);
    return (
      resolvedPath === resolvedRoot ||
      resolvedPath.startsWith(`${resolvedRoot}${nodePath.sep}`)
    );
  });
}

function normalizeSkillErrorInfo(raw: unknown): SkillErrorInfo | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const path = asString(typed.path);
  const message = asString(typed.message);
  if (!path || !message) {
    return null;
  }

  return { path, message };
}

async function listCodexModels(
  bridge: CodexBridge,
  options: AgentModelListOptions,
): Promise<ModelSummary[]> {
  const profileName = options.profile?.trim() || null;
  const providerName = options.provider?.trim() || null;
  if (profileName || providerName) {
    const profileConfig = await readCodexProfileConfig(bridge, options.cwd);
    if (profileName) {
      const profile = profileConfig.profiles.find((entry) => entry.name === profileName);
      if (!profile) {
        return [];
      }
      return listCodexProfileScopedModels(bridge, profileConfig, profile);
    }
    if (providerName) {
      return listCodexProviderScopedModels(bridge, profileConfig, providerName);
    }
  }

  return listCodexHostModels(bridge);
}

async function listCodexHostModels(bridge: CodexBridge): Promise<ModelSummary[]> {
  const models: ModelSummary[] = [];
  const seen = new Set<string>();
  let cursor: string | null = null;

  for (;;) {
    const payload = (await bridge.request("model/list", {
      includeHidden: false,
      cursor: cursor ?? undefined,
    })) as { data?: unknown[]; nextCursor?: unknown };
    const rawEntries = Array.isArray(payload.data) ? payload.data : [];

    for (const entry of rawEntries) {
      const model = normalizeCodexModelSummary(entry);
      if (!model || seen.has(model.model)) {
        continue;
      }
      seen.add(model.model);
      models.push({ ...model, source: "host", profileName: null });
    }

    const nextCursor = asString(payload.nextCursor);
    if (!nextCursor) {
      break;
    }
    cursor = nextCursor;
  }

  return models;
}

async function listCodexProfileScopedModels(
  bridge: CodexBridge,
  config: CodexProfileConfig,
  profile: ProviderProfileSummary,
): Promise<ModelSummary[]> {
  const profileProvider = profile.modelProvider?.trim() || null;
  const defaultProvider = config.modelProvider?.trim() || null;
  const configProvider = profileProvider ? config.modelProviders.get(profileProvider) : null;

  if (!profileProvider || profileProvider === defaultProvider || profileProvider === "openai") {
    return mergeCodexProfileModel([...(await listCodexHostModels(bridge))], profile);
  }

  const baseUrl = configProvider?.baseUrl || profile.modelProviderBaseUrl || null;
  const providerModels = baseUrl
    ? await fetchOpenAiCompatibleProviderModels({
        baseUrl,
        envKey: configProvider?.envKey ?? null,
        profileName: profile.name,
        providerName: configProvider?.name || profileProvider,
        defaultReasoningEffort: profile.reasoningEffort,
      })
    : [];

  return mergeCodexProfileModel(providerModels, profile);
}

async function listCodexProviderScopedModels(
  bridge: CodexBridge,
  config: CodexProfileConfig,
  providerName: string,
): Promise<ModelSummary[]> {
  const defaultProvider = config.modelProvider?.trim() || null;
  if (providerName === defaultProvider || providerName === "openai") {
    return listCodexHostModels(bridge);
  }

  const configProvider = config.modelProviders.get(providerName);
  if (!configProvider?.baseUrl) {
    return [];
  }
  return fetchOpenAiCompatibleProviderModels({
    baseUrl: configProvider.baseUrl,
    envKey: configProvider.envKey,
    profileName: null,
    providerName: configProvider.name || providerName,
    defaultReasoningEffort: null,
  });
}

function mergeCodexProfileModel(
  models: ModelSummary[],
  profile: ProviderProfileSummary,
): ModelSummary[] {
  const model = normalizeCodexProfileModelSummary(profile);
  if (!model) {
    return models;
  }
  const seen = new Set(models.map((entry) => entry.model));
  if (!seen.has(model.model)) {
    return [model, ...models];
  }
  return models.map((entry) =>
    entry.model === model.model && entry.source !== "profile"
      ? { ...entry, isDefault: true }
      : entry,
  );
}

function normalizeCodexProfileModelSummary(
  profile: ProviderProfileSummary,
): ModelSummary | null {
  const model = profile.model?.trim();
  if (!model) {
    return null;
  }

  const profileDetails = [
    profile.modelProvider ? `provider ${profile.modelProvider}` : null,
    profile.reasoningEffort ? `${profile.reasoningEffort} reasoning` : null,
    profile.serviceTier ? `tier ${profile.serviceTier}` : null,
  ].filter((value): value is string => Boolean(value));

  const suffix =
    profileDetails.length > 0 ? ` (${profileDetails.join(", ")})` : "";

  return {
    id: `profile:${profile.name}:${model}`,
    model,
    displayName: model,
    description: `Declared by Codex profile ${profile.name}${suffix}.`,
    defaultReasoningEffort: profile.reasoningEffort ?? "medium",
    supportedReasoningEfforts: [
      { reasoningEffort: "low", description: "Fast responses with lighter reasoning" },
      { reasoningEffort: "medium", description: "Balances speed and reasoning depth for everyday tasks" },
      { reasoningEffort: "high", description: "Greater reasoning depth for complex problems" },
      { reasoningEffort: "xhigh", description: "Extra high reasoning depth for complex problems" },
    ],
    reasoningEffortControl: "client",
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: ["text", "image"],
    isDefault: false,
    sortOrder: null,
    source: "profile",
    profileName: profile.name,
  };
}

async function fetchOpenAiCompatibleProviderModels(options: {
  baseUrl: string;
  envKey: string | null;
  profileName: string | null;
  providerName: string;
  defaultReasoningEffort: string | null;
}): Promise<ModelSummary[]> {
  const url = providerModelsUrl(options.baseUrl);
  if (!url) {
    return [];
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), PROVIDER_MODEL_LIST_TIMEOUT_MS);
  try {
    const headers: Record<string, string> = { Accept: "application/json" };
    const apiKey = options.envKey ? process.env[options.envKey]?.trim() : "";
    if (apiKey) {
      headers.Authorization = `Bearer ${apiKey}`;
    }
    const response = await fetch(url, {
      method: "GET",
      headers,
      signal: controller.signal,
    });
    if (!response.ok) {
      return [];
    }
    const payload = (await response.json()) as unknown;
    const payloadObject =
      payload && typeof payload === "object" ? (payload as { data?: unknown }) : null;
    const rawModels: unknown[] = Array.isArray(payloadObject?.data)
      ? payloadObject.data
      : Array.isArray(payload)
        ? payload
        : [];
    const models = rawModels
      .map((entry: unknown) =>
        normalizeProviderModelSummary(entry, {
          profileName: options.profileName,
          providerName: options.providerName,
          defaultReasoningEffort: options.defaultReasoningEffort,
        }),
      )
      .filter((entry: ModelSummary | null): entry is ModelSummary => entry !== null);
    const seen = new Set<string>();
    return models.filter((entry: ModelSummary) => {
      if (seen.has(entry.model)) {
        return false;
      }
      seen.add(entry.model);
      return true;
    });
  } catch {
    return [];
  } finally {
    clearTimeout(timeout);
  }
}

function providerModelsUrl(baseUrl: string): string | null {
  try {
    const url = new URL(baseUrl);
    const path = url.pathname.replace(/\/+$/, "");
    url.pathname = `${path}/models`;
    url.search = "";
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

function normalizeProviderModelSummary(
  raw: unknown,
  options: {
    profileName: string | null;
    providerName: string;
    defaultReasoningEffort: string | null;
  },
): ModelSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  const model = asString(typed?.id) || asString(typed?.model) || asString(raw);
  if (!model) {
    return null;
  }
  const profileSuffix = options.profileName ? ` via profile ${options.profileName}` : "";
  return {
    id: `${options.profileName ? `profile:${options.profileName}` : `provider:${options.providerName}`}:${model}`,
    model,
    displayName: model,
    description: `Available from ${options.providerName}${profileSuffix}.`,
    defaultReasoningEffort: options.defaultReasoningEffort ?? "medium",
    supportedReasoningEfforts: [
      { reasoningEffort: "low", description: "Fast responses with lighter reasoning" },
      { reasoningEffort: "medium", description: "Balances speed and reasoning depth for everyday tasks" },
      { reasoningEffort: "high", description: "Greater reasoning depth for complex problems" },
      { reasoningEffort: "xhigh", description: "Extra high reasoning depth for complex problems" },
    ],
    reasoningEffortControl: "client",
    supportsPersonality: false,
    additionalSpeedTiers: [],
    inputModalities: ["text", "image"],
    isDefault: false,
    sortOrder: null,
    source: options.profileName ? "profile" : "host",
    profileName: options.profileName,
  };
}

async function readCodexProfileConfig(
  bridge: CodexBridge,
  cwd: string | null,
): Promise<CodexProfileConfig> {
  const payload = (await bridge.request("config/read", {
    includeLayers: false,
    cwd: cwd ?? undefined,
  })) as { config?: unknown };
  return normalizeCodexProfileConfig(payload.config);
}

function normalizeCodexModelSummary(raw: unknown): ModelSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const model = asString(typed.model);
  const id = asString(typed.id);
  const displayName = asString(typed.displayName) || model;
  const description = asString(typed.description);
  const defaultReasoningEffort =
    asString(typed.defaultReasoningEffort) || asString(typed.default_reasoning_effort);
  if (!id || !model || !displayName || !description || !defaultReasoningEffort) {
    return null;
  }

  const supportedReasoningEfforts = Array.isArray(typed.supportedReasoningEfforts)
    ? typed.supportedReasoningEfforts
        .map((entry) => {
          const item =
            entry && typeof entry === "object" ? (entry as Record<string, unknown>) : null;
          const reasoningEffort =
            asString(item?.reasoningEffort) || asString(item?.reasoning_effort);
          const summaryDescription = asString(item?.description);
          if (!reasoningEffort || !summaryDescription) {
            return null;
          }
          return { reasoningEffort, description: summaryDescription };
        })
        .filter((entry): entry is ModelSummary["supportedReasoningEfforts"][number] => entry !== null)
    : [];

  return {
    id,
    model,
    displayName,
    description,
    defaultReasoningEffort,
    supportedReasoningEfforts,
    reasoningEffortControl: normalizeModelReasoningEffortControl(
      typed.reasoningEffortControl ?? typed.reasoning_effort_control,
      model,
    ),
    supportsPersonality: typed.supportsPersonality === true,
    additionalSpeedTiers: Array.isArray(typed.additionalSpeedTiers)
      ? typed.additionalSpeedTiers.map((entry) => asString(entry)).filter((entry): entry is string => Boolean(entry))
      : [],
    inputModalities: Array.isArray(typed.inputModalities)
      ? typed.inputModalities.map((entry) => asString(entry)).filter((entry): entry is string => Boolean(entry))
      : [],
    isDefault: typed.isDefault === true,
    sortOrder:
      asOptionalNumber(typed.sortOrder ?? typed.sort_order) ??
      codexModelSortOrder(model),
  };
}

function normalizeModelReasoningEffortControl(
  raw: unknown,
  model: string,
): ModelSummary["reasoningEffortControl"] {
  const value = asString(raw);
  if (value === "provider" || value === "provider-managed") {
    return "provider";
  }
  if (value === "client" || value === "client-controlled") {
    return "client";
  }
  return model.startsWith("codex-auto-") ? "provider" : "client";
}

function codexModelSortOrder(model: string): number | null {
  switch (model) {
    case "codex-auto-fast":
      return 0;
    case "codex-auto-balanced":
      return 1;
    case "codex-auto-thorough":
      return 2;
    default:
      return null;
  }
}

function normalizeCodexProfileConfig(raw: unknown): CodexProfileConfig {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const defaultProfile = asString(typed.profile);
  const modelProvider = readStringKey(typed, "modelProvider", "model_provider");
  const openaiBaseUrl = readStringKey(typed, "openaiBaseUrl", "openai_base_url");
  const modelProviders = normalizeModelProviders(typed.modelProviders ?? typed.model_providers);
  const rawProfiles =
    typed.profiles && typeof typed.profiles === "object"
      ? (typed.profiles as Record<string, unknown>)
      : {};

  const profiles = Object.entries(rawProfiles)
    .map(([name, profile]) =>
      normalizeCodexProfileSummary(name, profile, defaultProfile, modelProviders),
    )
    .filter((profile): profile is ProviderProfileSummary => profile !== null)
    .sort(compareCodexProfiles);

  return { defaultProfile, profiles, modelProvider, openaiBaseUrl, modelProviders };
}

function normalizeModelProviders(raw: unknown): Map<string, ConfigModelProviderSummary> {
  const providers = new Map<string, ConfigModelProviderSummary>();
  if (!raw || typeof raw !== "object") {
    return providers;
  }

  for (const [id, value] of Object.entries(raw as Record<string, unknown>)) {
    const typed = value && typeof value === "object" ? (value as Record<string, unknown>) : null;
    if (!id || !typed) {
      continue;
    }
    providers.set(id, {
      id,
      name: readStringKey(typed, "name"),
      baseUrl: readStringKey(typed, "baseUrl", "base_url"),
      envKey: readStringKey(typed, "envKey", "env_key"),
    });
  }

  return providers;
}

function normalizeCodexProfileSummary(
  name: string,
  raw: unknown,
  defaultProfile: string | null,
  modelProviders: Map<string, ConfigModelProviderSummary>,
): ProviderProfileSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed || !name) {
    return null;
  }

  const modelProvider = readStringKey(typed, "modelProvider", "model_provider");
  const provider = modelProvider ? modelProviders.get(modelProvider) : null;

  return {
    name,
    isDefault: name === defaultProfile,
    model: readStringKey(typed, "model"),
    modelProvider,
    modelProviderName: provider?.name ?? null,
    modelProviderBaseUrl:
      provider?.baseUrl ?? readStringKey(typed, "openaiBaseUrl", "openai_base_url"),
    approvalPolicy: readStringKey(typed, "approvalPolicy", "approval_policy"),
    sandboxMode: readStringKey(typed, "sandboxMode", "sandbox_mode"),
    serviceTier: readStringKey(typed, "serviceTier", "service_tier"),
    reasoningEffort: readStringKey(
      typed,
      "modelReasoningEffort",
      "model_reasoning_effort",
    ),
    reasoningSummary: readStringKey(
      typed,
      "modelReasoningSummary",
      "model_reasoning_summary",
    ),
    verbosity: readStringKey(typed, "modelVerbosity", "model_verbosity"),
    webSearch: readStringKey(typed, "webSearch", "web_search"),
    personality: readStringKey(typed, "personality"),
  };
}

function compareCodexProfiles(
  left: ProviderProfileSummary,
  right: ProviderProfileSummary,
): number {
  if (left.isDefault !== right.isDefault) {
    return left.isDefault ? -1 : 1;
  }
  return left.name.toLowerCase().localeCompare(right.name.toLowerCase());
}

function readStringKey(
  typed: Record<string, unknown>,
  camelKey: string,
  snakeKey?: string,
): string | null {
  return asString(typed[camelKey]) ?? (snakeKey ? asString(typed[snakeKey]) : null);
}

function asOptionalNumber(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  return value;
}

function normalizeCodexInput(input: AgentSessionInputItem[]): AgentSessionInputItem[] {
  const result: AgentSessionInputItem[] = [];
  for (const item of input) {
    if (item.type === "file") {
      result.push({
        type: "text",
        text: item.isDirectory ? `@${item.path}/` : `@${item.path}`,
        text_elements: [],
      });
    } else {
      result.push(item);
    }
  }
  return result;
}

function buildCodexThreadStartParams(
  request: AgentCreateSessionRequest,
): Record<string, unknown> {
  const params: Record<string, unknown> = {
    cwd: request.cwd,
    experimentalRawEvents: false,
    persistExtendedHistory: true,
  };
  const overrides = request.overrides;
  if (overrides.model) {
    params.model = overrides.model;
  }
  if (overrides.fastMode !== null) {
    params.serviceTier = overrides.fastMode ? "fast" : null;
  }
  const permissionProfile = cleanOptionalString(overrides.permissionProfile);
  if (permissionProfile) {
    params.permissions = permissionProfile;
  }
  const approvalPolicy = parseCodexApprovalPolicy(overrides.approvalPolicy);
  if (approvalPolicy) {
    params.approvalPolicy = approvalPolicy;
  }
  if (!permissionProfile) {
    const sandboxMode = parseCodexSandboxMode(overrides.sandboxMode);
    if (sandboxMode) {
      params.sandbox = sandboxMode;
    }
  }
  const approvalsReviewer = parseCodexApprovalsReviewer(
    overrides.approvalsReviewer,
  );
  if (approvalsReviewer) {
    params.approvalsReviewer = approvalsReviewer;
  }
  const config = buildCodexThreadConfigOverrides(overrides);
  if (config) {
    params.config = config;
  }
  return params;
}

function buildCodexTurnStartParams(
  request: AgentSubmitInputRequest,
): Record<string, unknown> {
  const overrides = request.overrides;
  const params: Record<string, unknown> = {
    threadId: request.sessionId,
    input: normalizeCodexInput(request.input),
  };
  const permissionProfile = cleanOptionalString(overrides.permissionProfile);
  if (permissionProfile) {
    params.permissions = permissionProfile;
  }
  const approvalPolicy = parseCodexApprovalPolicy(overrides.approvalPolicy);
  if (approvalPolicy) {
    params.approvalPolicy = approvalPolicy;
  }
  const approvalsReviewer = parseCodexApprovalsReviewer(
    overrides.approvalsReviewer,
  );
  if (approvalsReviewer) {
    params.approvalsReviewer = approvalsReviewer;
  }
  if (overrides.model) {
    params.model = overrides.model;
  }
  const reasoningEffort = parseCodexReasoningEffort(overrides.reasoningEffort);
  if (reasoningEffort) {
    params.effort = reasoningEffort;
  }
  if (overrides.fastMode !== null) {
    params.serviceTier = overrides.fastMode ? "fast" : null;
  }
  const sandboxMode = parseCodexSandboxMode(overrides.sandboxMode);
  if (!permissionProfile && (sandboxMode || overrides.networkAccess !== null)) {
    const sandboxPolicy = buildCodexSandboxPolicyV2(
      sandboxMode,
      overrides.networkAccess,
    );
    if (sandboxPolicy) {
      params.sandboxPolicy = sandboxPolicy;
    }
  }
  return params;
}

function buildRuntimeFromThreadStart(raw: unknown): SessionRuntimeSummary | null {
  const typed = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : null;
  if (!typed) {
    return null;
  }

  const runtime: SessionRuntimeSummary = {
    model: asString(typed.model) ?? undefined,
    modelProvider:
      asString(typed.modelProvider) ??
      asString(typed.model_provider) ??
      undefined,
    serviceTier:
      asString(typed.serviceTier) ??
      asString(typed.service_tier) ??
      undefined,
    reasoningEffort:
      asString(typed.reasoningEffort) ??
      asString(typed.reasoning_effort) ??
      undefined,
    approvalPolicy:
      asString(typed.approvalPolicy) ??
      asString(typed.approval_policy) ??
      undefined,
    sandboxMode:
      asString((typed.sandbox as Record<string, unknown> | undefined)?.type) ??
      asString(
        (typed.permissionProfile as Record<string, unknown> | undefined)
          ?.sandboxMode,
      ) ??
      undefined,
    networkAccess:
      asOptionalBoolean(
        (typed.sandbox as Record<string, unknown> | undefined)?.networkAccess,
      ) ??
      asOptionalBoolean(
        (typed.sandbox as Record<string, unknown> | undefined)?.network_access,
      ) ??
      undefined,
    permissionProfile:
      asString(
        (typed.activePermissionProfile as Record<string, unknown> | undefined)?.id,
      ) ?? undefined,
    approvalsReviewer:
      asString(typed.approvalsReviewer) ??
      asString(typed.approvals_reviewer) ??
      undefined,
  };
  runtime.accessMode = codexAccessModeFromRuntime(runtime);

  if (
    !runtime.model &&
    !runtime.modelProvider &&
    !runtime.serviceTier &&
    !runtime.reasoningEffort &&
    !runtime.approvalPolicy &&
    !runtime.sandboxMode &&
    runtime.networkAccess === undefined &&
    !runtime.accessMode &&
    !runtime.permissionProfile &&
    !runtime.approvalsReviewer
  ) {
    return null;
  }

  return runtime;
}

function buildCodexThreadConfigOverrides(
  overrides: AgentCreateSessionRequest["overrides"],
): Record<string, unknown> | null {
  const config: Record<string, unknown> = {};
  if (overrides.profile) {
    config.profile = overrides.profile;
  }
  const webSearch = parseCodexWebSearchMode(overrides.webSearch);
  if (webSearch) {
    config.web_search = webSearch;
  }
  const reasoningEffort = parseCodexReasoningEffort(overrides.reasoningEffort);
  if (reasoningEffort) {
    config.model_reasoning_effort = reasoningEffort;
  }
  return Object.keys(config).length > 0 ? config : null;
}

function buildCodexSandboxPolicyV2(
  mode: CodexSandboxModeValue | null,
  networkAccess: boolean | null,
): Record<string, unknown> | null {
  if (!mode) {
    return null;
  }
  switch (mode) {
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    case "read-only":
      return {
        type: "readOnly",
        networkAccess: networkAccess ?? false,
      };
    case "workspace-write":
      return {
        type: "workspaceWrite",
        networkAccess: networkAccess ?? false,
      };
  }
}

type CodexApprovalPolicyValue = "untrusted" | "on-request" | "never";
type CodexSandboxModeValue = "read-only" | "workspace-write" | "danger-full-access";
type CodexWebSearchModeValue = "disabled" | "cached" | "live";
type CodexApprovalsReviewerValue = "user" | "auto_review";

function parseCodexApprovalsReviewer(
  value: string | null | undefined,
): CodexApprovalsReviewerValue | null {
  if (value === "user" || value === "auto_review") {
    return value;
  }
  return value === "guardian_subagent" ? "auto_review" : null;
}

function cleanOptionalString(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? "";
  return trimmed || null;
}

function codexAccessModeSummary(
  mode: ProviderPermissionModeSummary,
): ProviderAccessModeSummary {
  const icon = (() => {
    switch (mode.id) {
      case "ask-for-approval":
        return "prompt";
      case "approve-for-me":
        return "automatic";
      case "read-only":
        return "read-only";
      case "full-access":
        return "unrestricted";
      default:
        return "settings";
    }
  })();
  return {
    id: mode.id,
    label: mode.label,
    description: mode.description,
    icon,
    tone: mode.dangerous ? "danger" : "default",
    enabled: true,
    disabledReason: null,
    confirmation: mode.dangerous
      ? {
          title: `Enable ${mode.label.toLowerCase()}?`,
          description:
            "This mode can edit any file on this computer and use the internet without approval. It substantially increases the risk of data loss or leaks.",
          confirmLabel: `Enable ${mode.label.toLowerCase()}`,
          danger: true,
        }
      : null,
  };
}

function codexAccessModeFromRuntime(
  runtime: SessionRuntimeSummary,
): string | undefined {
  const permissionProfile = cleanOptionalString(runtime.permissionProfile);
  const approvalPolicy = cleanOptionalString(runtime.approvalPolicy);
  const approvalsReviewer =
    parseCodexApprovalsReviewer(runtime.approvalsReviewer) ?? "user";
  if (
    permissionProfile === ":workspace" &&
    approvalPolicy === "on-request"
  ) {
    return approvalsReviewer === "auto_review"
      ? "approve-for-me"
      : "ask-for-approval";
  }
  if (
    permissionProfile === ":read-only" &&
    approvalPolicy === "on-request"
  ) {
    return "read-only";
  }
  if (
    permissionProfile === ":danger-full-access" &&
    approvalPolicy === "never"
  ) {
    return "full-access";
  }
  return undefined;
}

function codexPermissionProfileLabel(id: string): string {
  switch (id) {
    case ":read-only":
      return "Read only";
    case ":workspace":
      return "Workspace";
    case ":workspace_roots":
      return "Selected workspaces";
    case ":danger-full-access":
      return "Full access";
  }
  return id
    .replace(/^:/, "")
    .replace(/[-_]+/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function codexPermissionProfileDescription(id: string): string | null {
  switch (id) {
    case ":read-only":
      return "Inspect files and run safe read-only commands without making changes.";
    case ":workspace":
    case ":workspace_roots":
      return "Read and change files inside the selected workspace.";
    case ":danger-full-access":
      return "Access files and commands across the machine without sandbox limits.";
    default:
      return null;
  }
}

function parseCodexApprovalPolicy(value: string | null): CodexApprovalPolicyValue | null {
  switch (value) {
    case "untrusted":
    case "on-request":
    case "never":
      return value;
    default:
      return null;
  }
}

function parseCodexSandboxMode(value: string | null): CodexSandboxModeValue | null {
  switch (value) {
    case "read-only":
    case "workspace-write":
    case "danger-full-access":
      return value;
    default:
      return null;
  }
}

function parseCodexWebSearchMode(value: string | null): CodexWebSearchModeValue | null {
  switch (value) {
    case "disabled":
    case "cached":
    case "live":
      return value;
    default:
      return null;
  }
}

function parseCodexReasoningEffort(value: string | null): string | null {
  const normalized = value?.trim() ?? "";
  return normalized || null;
}

function toActivityDraft(activity: SessionActivity): AgentSessionActivityDraft {
  const { createdAt: _createdAt, seq: _seq, ...draft } = activity;
  return draft as AgentSessionActivityDraft;
}

function normalizeCodexThreadStatus(status: unknown): {
  status: LiveThreadStatus;
  message?: string;
  pendingActionKind?: PendingActionKind;
} {
  const typed = status && typeof status === "object"
    ? (status as Record<string, unknown>)
    : null;
  const type = asString(typed?.type);
  if (type === "idle") {
    return { status: "idle" };
  }
  if (type === "notLoaded") {
    return { status: "closed" };
  }
  if (type === "systemError") {
    return {
      status: "errored",
      message: "Codex reported a system error.",
    };
  }
  if (type !== "active") {
    return { status: "unknown" };
  }
  const activeFlags = Array.isArray(typed?.activeFlags)
    ? typed.activeFlags.map((value) => asString(value)).filter((value): value is string => !!value)
    : [];
  if (activeFlags.includes("waitingOnApproval")) {
    return { status: "waiting_for_approval" };
  }
  if (activeFlags.includes("waitingOnUserInput")) {
    return { status: "waiting_for_input" };
  }
  return { status: "running" };
}

function normalizeCodexThreadRecord(thread: ThreadRecord): ThreadRecord {
  const normalized = normalizeCodexThreadStatus(thread.status);
  return {
    ...thread,
    status: {
      ...thread.status,
      phase: normalized.status,
    },
    subAgent:
      thread.subAgent ??
      subAgentInfoFromCodexSource(thread.source, {
        agentRole: thread.agentRole ?? undefined,
        agentNickname: thread.agentNickname ?? undefined,
      }),
  };
}

function buildCodexPlanSteps(plan: unknown): LivePlanStep[] {
  if (!Array.isArray(plan)) {
    return [];
  }
  return plan.flatMap((entry) => {
    const typed = entry && typeof entry === "object"
      ? (entry as Record<string, unknown>)
      : null;
    const step = asString(typed?.step);
    if (!step) {
      return [];
    }
    return [{
      step,
      status: normalizeCodexPlanStepStatus(typed?.status),
    } satisfies LivePlanStep];
  });
}

function normalizeCodexPlanStepStatus(status: unknown): LivePlanStep["status"] {
  switch (asString(status)) {
    case "completed":
      return "completed";
    case "inProgress":
    case "in_progress":
      return "in_progress";
    default:
      return "pending";
  }
}

function buildCodexProviderWarning(
  method: string,
  params: unknown,
): {
  type: "provider_warning";
  sessionId?: string;
  level: ProviderWarningLevel;
  code?: string;
  message: string;
  source?: string;
} | null {
  const typed = params && typeof params === "object"
    ? (params as Record<string, unknown>)
    : null;
  if (!typed) {
    return null;
  }

  if (method === "warning" || method === "guardianWarning") {
    const message = asString(typed.message);
    if (!message) {
      return null;
    }
    return {
      type: "provider_warning",
      sessionId: asString(typed.threadId) || undefined,
      level: method === "guardianWarning" ? "error" : "warning",
      code: method,
      message,
      source: "codex",
    };
  }

  if (method === "deprecationNotice") {
    const summary = asString(typed.summary);
    const details = asString(typed.details);
    const message = [summary, details].filter(Boolean).join("\n\n");
    if (!message) {
      return null;
    }
    return {
      type: "provider_warning",
      level: "info",
      code: "deprecationNotice",
      message,
      source: "codex/config",
    };
  }

  if (method === "configWarning") {
    const summary = asString(typed.summary);
    const details = asString(typed.details);
    const path = asString(typed.path);
    const message = [summary, details, path ? `Path: ${path}` : null]
      .filter(Boolean)
      .join("\n\n");
    if (!message) {
      return null;
    }
    return {
      type: "provider_warning",
      level: "warning",
      code: "configWarning",
      message,
      source: "codex/config",
    };
  }

  return null;
}

function extractSessionId(method: string, params: unknown): string | null {
  if (!params || typeof params !== "object") {
    return null;
  }
  const typed = params as Record<string, any>;
  if (typeof typed.threadId === "string") {
    return typed.threadId;
  }
  if (typeof typed.thread_id === "string") {
    return typed.thread_id;
  }
  if (method === "turn/started" && typeof typed.turn?.threadId === "string") {
    return typed.turn.threadId;
  }
  if (method === "turn/completed" && typeof typed.threadId === "string") {
    return typed.threadId;
  }
  return null;
}

function buildCodexPendingAction(
  method: string,
  params: unknown,
  providerRequestId: number | string,
  sessionId: string,
): AgentPendingAction {
  const typed = (params || {}) as Record<string, any>;
  const requestedAt = Date.now();

  if (method === "item/commandExecution/requestApproval") {
    const command = asString(typed.command) || "Command approval";
    const cwd = asString(typed.cwd) ?? undefined;
    const reason = asString(typed.reason) ?? undefined;
    const networkTarget = codexNetworkApprovalTarget(typed.networkApprovalContext);
    const networkSummary = networkTarget ? approvalTargetSummary(networkTarget) : null;
    const title = networkTarget ? "Network approval" : "Command approval";
    const summary = networkSummary ?? command;
    return {
      id: asString(typed.approvalId) || randomFallbackId(),
      sessionId,
      kind: "command",
      title,
      detail: command === "Command approval" && networkSummary ? networkSummary : command,
      requestedAt,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      cwd,
      approval: {
        category: networkTarget ? "network" : "command",
        operation: networkTarget ? "codex.network" : "codex.commandExecution",
        summary,
        detail: reason,
        cwd,
        supportedScopes: ["once", "session"],
        suggestedScope: "once",
        targets: networkTarget
          ? [networkTarget]
          : [
              {
                type: "command",
                command,
                cwd,
                intention: reason,
              },
            ],
      },
      providerRequestId,
      providerRequestKind: method,
    };
  }

  if (method === "item/fileChange/requestApproval") {
    const reason = asString(typed.reason) || "Codex wants to modify files.";
    const grantRoot = asString(typed.grantRoot);
    const targets: NonNullable<AgentPendingAction["approval"]>["targets"] =
      grantRoot
        ? [
            {
              type: "file",
              path: grantRoot,
              access: "write",
              intention: reason,
            },
          ]
        : [{ type: "unknown", label: "Codex file change" }];
    return {
      id: randomFallbackId(),
      sessionId,
      kind: "file_change",
      title: "File change approval",
      detail: reason,
      requestedAt,
      canApprove: true,
      canApproveForSession: true,
      canDecline: true,
      approval: {
        category: "file_change",
        operation: "codex.fileChange",
        summary: reason,
        detail: reason,
        supportedScopes: ["once", "session"],
        suggestedScope: "once",
        targets,
      },
      providerRequestId,
      providerRequestKind: method,
    };
  }

  const cwd = asString(typed.cwd) ?? undefined;
  const reason = asString(typed.reason) ?? undefined;
  const detail = formatPermissionRequestDetail(typed.reason, typed.permissions);
  return {
    id: randomFallbackId(),
    sessionId,
    kind: "permissions",
    title: "Permission request",
    detail,
    requestedAt,
    canApprove: true,
    canApproveForSession: true,
    canDecline: true,
    cwd,
    approval: {
      category: "permissions",
      operation: "codex.requestPermissions",
      summary: reason || "Codex requested additional permissions.",
      detail,
      cwd,
      supportedScopes: ["once", "session"],
      suggestedScope: "once",
      targets: [
        {
          type: "permission_profile",
          permissions: typed.permissions,
          cwd,
          reason,
        },
      ],
    },
    providerRequestId,
    providerRequestKind: method,
    providerPayload: typed.permissions,
  };
}

function codexNetworkApprovalTarget(
  value: unknown,
): NonNullable<AgentPendingAction["approval"]>["targets"][number] | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const typed = value as Record<string, unknown>;
  const host = asString(typed.host);
  if (!host) {
    return null;
  }
  const protocol = asString(typed.protocol) ?? "network";
  if (protocol === "http" || protocol === "https") {
    return { type: "url", url: `${protocol}://${host}` };
  }
  return { type: "unknown", label: `${protocol}:${host}` };
}

function approvalTargetSummary(
  target: NonNullable<AgentPendingAction["approval"]>["targets"][number],
): string {
  switch (target.type) {
    case "url":
      return target.url;
    case "unknown":
      return target.label;
    case "command":
      return target.command;
    case "file":
      return target.path;
    case "tool":
      return target.title ?? target.name;
    case "memory":
      return target.fact ?? target.subject ?? "memory";
    case "hook":
      return target.message ?? target.toolName ?? "hook";
    case "permission_profile":
      return target.reason ?? "permissions";
  }
}

export const CODEX_PROVIDER_CAPABILITIES: AgentProviderCapabilities = {
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
    text: true,
    imageUrl: true,
    localImage: true,
    skills: true,
    fileMentions: true,
  },
  interaction: {
    userInput: true,
    elicitation: true,
  },
  approvals: {
    command: true,
    tool: false,
    fileChange: true,
    permissions: true,
    approveForSession: true,
  },
  configuration: {
    models: true,
    profiles: true,
    accessModes: true,
    permissionProfiles: true,
    skills: true,
    skillManagement: true,
  },
  runtimeControls: {
    model: true,
    mode: false,
    reasoningEffort: true,
    fastMode: true,
    approvalPolicy: true,
    sandboxMode: true,
    networkAccess: true,
    webSearch: true,
    accessMode: true,
    permissionProfile: true,
    approvalsReviewer: true,
  },
  lifecycle: {
    restart: true,
  },
  usage: {
    accountLimits: true,
    localTelemetry: false,
    credits: true,
    resetWindows: true,
  },
};


function buildCodexUserInputAction(
  params: unknown,
  providerRequestId: number | string,
  sessionId: string,
): AgentPendingAction | null {
  const typed = (params || {}) as Record<string, any>;
  const questions = typed.questions;
  if (!Array.isArray(questions) || questions.length === 0) {
    return null;
  }

  const firstQuestion = questions[0];
  if (!firstQuestion || typeof firstQuestion !== "object") {
    return null;
  }

  if (firstQuestion.is_secret === true) {
    return null;
  }

  const questionText =
    asString(firstQuestion.question) ||
    asString(firstQuestion.header) ||
    "Agent question";
  const options = Array.isArray(firstQuestion.options)
    ? firstQuestion.options.filter(
        (opt: unknown): opt is string =>
          typeof opt === "string" && opt.trim().length > 0,
      )
    : [];
  const isOther = firstQuestion.is_other === true;

  return {
    id: randomFallbackId(),
    sessionId,
    kind: "user_input",
    title: "Agent question",
    detail: questionText,
    requestedAt: Date.now(),
    canApprove: false,
    canApproveForSession: false,
    canDecline: false,
    userInput: {
      question: questionText,
      choices: options,
      allowFreeform: isOther || options.length === 0,
    },
    providerRequestId,
    providerRequestKind: "item/tool/requestUserInput",
    providerPayload: {
      threadId: sessionId,
      turnId: asString(typed.turnId) || asString(typed.turn_id) || undefined,
      itemId: asString(typed.itemId) || asString(typed.item_id) || undefined,
      questionId: asString(firstQuestion.id) || "default",
    },
  };
}

function buildCodexElicitationAction(
  params: unknown,
  providerRequestId: number | string,
  sessionId: string,
): AgentPendingAction | null {
  const typed = (params || {}) as Record<string, any>;
  const mode = asString(typed.mode);
  const message = asString(typed.message) || "Structured input requested";
  const source = asString(typed.server_name) || asString(typed.serverName) || undefined;

  if (mode === "url") {
    const url = asString(typed.url);
    if (!url) {
      return null;
    }
    return {
      id: randomFallbackId(),
      sessionId,
      kind: "elicitation",
      title: "Browser sign-in required",
      detail: message,
      requestedAt: Date.now(),
      canApprove: false,
      canApproveForSession: false,
      canDecline: true,
      elicitation: {
        mode: "url",
        message,
        ...(source ? { source } : {}),
        url,
        fields: [],
      },
      providerRequestId,
      providerRequestKind: "mcpServer/elicitation/request",
      providerPayload: {
        threadId: sessionId,
        turnId: asString(typed.turnId) || asString(typed.turn_id) || undefined,
        elicitationId:
          asString(typed.elicitation_id) || asString(typed.elicitationId) || undefined,
        serverName: source,
      },
    };
  }

  if (mode === "form") {
    const schema =
      typed.requested_schema && typeof typed.requested_schema === "object"
        ? (typed.requested_schema as Record<string, any>)
        : null;
    const fields = schema ? normalizeCodexElicitationFields(schema) : [];

    if (schema && Array.isArray(schema.required)) {
      const producedKeys = new Set(fields.map((f) => f.key));
      for (const req of schema.required as string[]) {
        if (!producedKeys.has(req)) {
          return null;
        }
      }
    }

    return {
      id: randomFallbackId(),
      sessionId,
      kind: "elicitation",
      title: "Structured input requested",
      detail: message,
      requestedAt: Date.now(),
      canApprove: false,
      canApproveForSession: false,
      canDecline: true,
      elicitation: {
        mode: "form",
        message,
        ...(source ? { source } : {}),
        fields,
      },
      providerRequestId,
      providerRequestKind: "mcpServer/elicitation/request",
      providerPayload: {
        threadId: sessionId,
        turnId: asString(typed.turnId) || asString(typed.turn_id) || undefined,
        elicitationId:
          asString(typed.elicitation_id) || asString(typed.elicitationId) || undefined,
        serverName: source,
      },
    };
  }

  return null;
}

function normalizeCodexElicitationFields(
  schema: Record<string, any>,
): PendingActionElicitationField[] {
  if (schema.type !== "object" || !schema.properties) {
    return [];
  }
  const required = new Set(Array.isArray(schema.required) ? schema.required : []);
  return Object.entries(schema.properties as Record<string, any>)
    .map(([key, field]) => normalizeCodexElicitationField(key, field, required))
    .filter((field): field is PendingActionElicitationField => field !== null);
}

function normalizeCodexElicitationField(
  key: string,
  field: Record<string, any>,
  required: Set<string>,
): PendingActionElicitationField | null {
  const title = asString(field.title) || key;
  const description = asString(field.description) ?? undefined;
  const isRequired = required.has(key);

  if (field.type === "boolean") {
    return {
      key,
      type: "boolean",
      title,
      description,
      required: isRequired,
      ...(typeof field.default === "boolean" ? { defaultValue: field.default } : {}),
    };
  }

  if (field.type === "number" || field.type === "integer") {
    return {
      key,
      type: "number",
      title,
      description,
      required: isRequired,
      integer: field.type === "integer",
      ...(typeof field.default === "number" ? { defaultValue: field.default } : {}),
      ...(typeof field.minimum === "number" ? { minimum: field.minimum } : {}),
      ...(typeof field.maximum === "number" ? { maximum: field.maximum } : {}),
    };
  }

  if (field.type === "array" && field.items && typeof field.items === "object") {
    const items = field.items as Record<string, any>;
    const options = Array.isArray(items.enum)
      ? items.enum
          .filter((v: unknown): v is string => typeof v === "string")
          .map((value: string) => ({ value, label: value }))
      : undefined;
    return {
      key,
      type: "string[]",
      title,
      description,
      required: isRequired,
      options: options ?? [],
      ...(Array.isArray(field.default) ? { defaultValue: field.default } : {}),
      ...(typeof field.minItems === "number" ? { minItems: field.minItems } : {}),
      ...(typeof field.maxItems === "number" ? { maxItems: field.maxItems } : {}),
    };
  }

  if (field.type !== "string" && field.type !== undefined && field.type !== null) {
    return null;
  }

  const options = Array.isArray(field.enum)
    ? field.enum
        .filter((v: unknown): v is string => typeof v === "string")
        .map((value: string) => ({ value, label: value }))
    : undefined;

  return {
    key,
    type: "string",
    title,
    description,
    required: isRequired,
    ...(typeof field.default === "string" ? { defaultValue: field.default } : {}),
    ...(options && options.length > 0 ? { options } : {}),
    ...(typeof field.minLength === "number" ? { minLength: field.minLength } : {}),
    ...(typeof field.maxLength === "number" ? { maxLength: field.maxLength } : {}),
    ...(asString(field.format) ? { format: asString(field.format) as any } : {}),
  };
}

function buildCodexActionResponse(
  action: AgentPendingAction,
  input: PendingActionResponseInput,
): unknown | null {
  if (action.providerRequestKind === "item/tool/requestUserInput") {
    const userInput = parsePendingActionUserInputResponse(input);
    if (!userInput) {
      return null;
    }
    const payload = action.providerPayload as Record<string, any> | undefined;
    const questionId = asString(payload?.questionId) || "default";
    return {
      answers: {
        [questionId]: { answers: [userInput.answer] },
      },
    };
  }

  if (action.providerRequestKind === "mcpServer/elicitation/request") {
    const elicitation = parsePendingActionElicitationResponse(input);
    if (!elicitation) {
      return null;
    }
    const result: Record<string, unknown> = {
      action: elicitation.action,
    };
    if (elicitation.action === "accept" && elicitation.content) {
      result.content = elicitation.content;
    }
    return result;
  }

  const decision = normalizePendingActionDecision(
    input as PendingActionDecisionInput,
  );
  if (!decision) {
    return null;
  }

  if (
    action.providerRequestKind === "item/commandExecution/requestApproval" ||
    action.providerRequestKind === "item/fileChange/requestApproval"
  ) {
    if (decision.legacyDecision === "acceptForLocation") {
      return null;
    }
    return { decision: decision.legacyDecision };
  }

  if (action.providerRequestKind === "item/permissions/requestApproval") {
    if (decision.decision === "approve") {
      if (decision.scope === "location") {
        return null;
      }
      return {
        scope: decision.scope === "session" ? "session" : "turn",
        permissions: action.providerPayload || {},
      };
    }
    if (decision.decision === "decline" || decision.decision === "cancel") {
      return { scope: "turn", permissions: {} };
    }
  }

  return null;
}

function formatPermissionRequestDetail(reason: unknown, permissions: unknown): string {
  const parts = [asString(reason) || "Codex requested additional permissions."];
  const summary = summarizePermissions(permissions);
  if (summary) {
    parts.push(summary);
  }
  return parts.join("\n\n");
}

function summarizePermissions(permissions: unknown): string | null {
  if (!permissions || typeof permissions !== "object") {
    return null;
  }

  const typed = permissions as Record<string, any>;
  const lines: string[] = [];

  const fileSystem = typed.fileSystem as Record<string, any> | undefined;
  if (fileSystem) {
    appendPermissionPaths(lines, "File read", fileSystem.read);
    appendPermissionPaths(lines, "File write", fileSystem.write);
  }

  const network = typed.network as Record<string, any> | undefined;
  if (network) {
    if (typeof network.mode === "string") {
      lines.push(`Network: ${network.mode}`);
    } else if (network.enabled === true) {
      lines.push("Network: enabled");
    }
  }

  if (lines.length === 0) {
    const fallback = JSON.stringify(permissions, null, 2);
    return fallback === "{}" ? null : fallback;
  }

  return lines.join("\n");
}

function appendPermissionPaths(lines: string[], label: string, paths: unknown): void {
  if (!Array.isArray(paths) || paths.length === 0) {
    return;
  }
  const normalized = paths.filter((path): path is string => typeof path === "string" && path.length > 0);
  if (normalized.length === 0) {
    return;
  }
  lines.push(`${label}: ${normalized.join(", ")}`);
}

function codexItemLifecycleStatus(
  method: "item/started" | "item/completed",
  itemStatus: unknown,
): "in_progress" | "completed" | "failed" | "declined" {
  if (method === "item/started") {
    return "in_progress";
  }
  if (itemStatus === "failed") {
    return "failed";
  }
  if (itemStatus === "declined") {
    return "declined";
  }
  return "completed";
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object"
    ? (value as Record<string, unknown>)
    : null;
}

function asStringArray(value: unknown): string[] | null {
  if (!Array.isArray(value)) {
    return null;
  }
  return value.filter((item): item is string => typeof item === "string");
}

function asNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asOptionalBoolean(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function randomFallbackId(): string {
  return randomUUID();
}
