import { Buffer } from "node:buffer";
import { EventEmitter } from "node:events";

import {
  hasProviderMethod,
  requireProviderMethod,
  type AgentCreateSessionRequest,
  type AgentCreateSessionResult,
  type AgentPendingAction,
  type AgentProvider,
  type AgentProviderCapabilities,
  type AgentProviderEvents,
  type AgentProviderLiveEvent,
  type AgentSessionListOptions,
  type AgentSessionLogOptions,
  type AgentSessionResumeOptions,
  type AgentSubmitInputRequest,
  type AgentSubmitInputResult,
} from "./agent-provider.js";
import type { PendingActionResponseInput } from "./approvals.js";
import type {
  AgentProviderConfig,
  AgentProviderKind,
  SessionLogSnapshot,
  SessionRuntimeSummary,
  ThreadRecord,
  UsageObservation,
} from "./types.js";

interface ProviderEntry {
  id?: string;
  kind: AgentProviderKind;
  config: AgentProviderConfig;
  provider: AgentProvider;
}

interface ResolvedProviderEntry {
  id: string;
  kind: AgentProviderKind;
  rawId: string;
  provider: AgentProvider;
}

export class MultiAgentProvider
  extends EventEmitter<AgentProviderEvents>
  implements AgentProvider
{
  public readonly kind: string;
  public readonly displayName: string;
  public readonly capabilities: AgentProviderCapabilities;

  private readonly entriesById: Map<string, ProviderEntry & { id: string }>;
  private readonly orderedEntries: Array<ProviderEntry & { id: string }>;

  public constructor(
    entries: ProviderEntry[],
    private readonly defaultProviderId: string,
  ) {
    super();
    this.orderedEntries = entries.map((entry) => ({ ...entry, id: entry.id ?? entry.kind }));
    this.entriesById = new Map(this.orderedEntries.map((entry) => [entry.id, entry]));
    if (this.entriesById.size !== entries.length) throw new Error("Provider instance IDs must be unique.");
    const defaultEntry = this.entriesById.get(defaultProviderId);
    if (!defaultEntry) {
      throw new Error(
        `Default provider "${defaultProviderId}" was not configured.`,
      );
    }
    this.kind = defaultEntry.provider.kind;
    this.displayName = defaultEntry.provider.displayName;
    // Session fan-out methods (listSessionThreads, listRecentUnindexedSessionThreads,
    // /api/sessions/search) operate across all configured providers, so reflect the
    // union of those flags while keeping everything else default-provider-scoped.
    const anyProvider = (selector: (caps: AgentProviderCapabilities) => boolean) =>
      entries.some((entry) => selector(entry.provider.capabilities));
    this.capabilities = {
      ...defaultEntry.provider.capabilities,
      sessions: {
        ...defaultEntry.provider.capabilities.sessions,
        history: anyProvider((caps) => caps.sessions.history),
        recentFallback: anyProvider((caps) => caps.sessions.recentFallback),
        searchSessions: anyProvider((caps) => caps.sessions.searchSessions),
      },
      usage: {
        accountLimits: anyProvider((caps) => caps.usage.accountLimits),
        localTelemetry: anyProvider((caps) => caps.usage.localTelemetry),
        credits: anyProvider((caps) => caps.usage.credits),
        resetWindows: anyProvider((caps) => caps.usage.resetWindows),
      },
    };
    for (const entry of this.orderedEntries) {
      entry.provider.on("liveEvent", (event) => {
        this.emit("liveEvent", this.wrapLiveEvent(entry.id, event));
      });
      entry.provider.on("stderr", (line) => {
        const prefix =
          entry.id === this.defaultProviderId ? "" : `[${entry.id}] `;
        this.emit("stderr", `${prefix}${line}`);
      });
      entry.provider.on("exit", (code) => {
        this.emit("exit", code);
      });
    }
  }

  public async start(): Promise<void> {
    await Promise.all(this.orderedEntries.map((entry) => entry.provider.start()));
  }

  public async close(): Promise<void> {
    const results = await Promise.allSettled(
      this.orderedEntries.map(async (entry) => { await entry.provider.close?.(); }),
    );
    const errors = results.flatMap((result) => result.status === "rejected" ? [result.reason] : []);
    if (errors.length > 0) {
      throw new AggregateError(errors, "Failed to close one or more agent providers.");
    }
  }

  public async restartProvider(kind: string): Promise<void> {
    const entry = this.entriesById.get(kind);
    if (!entry) {
      throw new Error(`Unknown provider "${kind}".`);
    }
    if (
      !entry.provider.capabilities.lifecycle.restart ||
      !entry.provider.restart
    ) {
      throw new Error(`${entry.provider.displayName} does not support restart.`);
    }
    await entry.provider.restart();
  }

  public async getVersion(): Promise<string> {
    return this.defaultEntry().provider.getVersion();
  }

  public async readUsageObservations(): Promise<UsageObservation[]> {
    const observations = await Promise.all(
      this.orderedEntries
        .filter((entry) => hasProviderMethod(entry.provider, "readUsageObservations"))
        .map(async (entry) =>
          (await entry.provider.readUsageObservations!()).map((observation) => ({
            ...observation,
            provider: {
              ...observation.provider,
              kind: observation.provider.kind || entry.kind,
            },
          })),
        ),
    );
    return observations.flat();
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    const parentOwner = options.subAgentParentId
      ? this.resolveSessionId(options.subAgentParentId)
      : null;
    const threads = await Promise.all(
      this.orderedEntries
        .filter(
          (entry) =>
            (!parentOwner || entry.provider === parentOwner.provider) &&
            hasProviderMethod(entry.provider, "listSessionThreads") &&
            entry.provider.capabilities.sessions.history,
        )
        .map(async (entry) =>
          (
            await entry.provider.listSessionThreads!({
              ...options,
              subAgentParentId: parentOwner?.rawId,
            })
          ).map((thread) => this.wrapThread(entry.id, thread)),
        ),
    );
    return threads
      .flat()
      .sort((left, right) =>
        normalizeThreadTimestamp(right.updatedAt) -
        normalizeThreadTimestamp(left.updatedAt),
      )
      .slice(0, options.limit);
  }

  public async readSessionThread(
    threadId: string,
    includeTurns: boolean,
  ): Promise<ThreadRecord> {
    const resolved = this.resolveSessionId(threadId);
    const thread = await requireProviderMethod(
      resolved.provider,
      "readSessionThread",
      "session history",
    ).call(resolved.provider, resolved.rawId, includeTurns);
    return this.wrapThread(resolved.id, thread);
  }

  public async listRecentUnindexedSessionThreads(
    limit: number,
  ): Promise<ThreadRecord[]> {
    const threads = await Promise.all(
      this.orderedEntries
        .filter(
          (entry) =>
            hasProviderMethod(entry.provider, "listRecentUnindexedSessionThreads") &&
            entry.provider.capabilities.sessions.recentFallback,
        )
        .map(async (entry) =>
          (
            await entry.provider.listRecentUnindexedSessionThreads!(limit)
          ).map((thread) => this.wrapThread(entry.id, thread)),
        ),
    );
    return threads
      .flat()
      .sort((left, right) =>
        normalizeThreadTimestamp(right.updatedAt) -
        normalizeThreadTimestamp(left.updatedAt),
      )
      .slice(0, limit);
  }

  public async readSessionLog(
    thread: ThreadRecord,
    options?: AgentSessionLogOptions,
  ): Promise<SessionLogSnapshot> {
    const resolved = this.resolveSessionId(thread.id);
    const childThread = await requireProviderMethod(
      resolved.provider,
      "readSessionThread",
      "session history",
    ).call(resolved.provider, resolved.rawId, false);
    return requireProviderMethod(
      resolved.provider,
      "readSessionLog",
      "session transcript",
    ).call(resolved.provider, childThread, options);
  }

  public async readSessionRuntime(
    thread: ThreadRecord,
  ): Promise<SessionRuntimeSummary | null> {
    const resolved = this.resolveSessionId(thread.id);
    const childThread = await requireProviderMethod(
      resolved.provider,
      "readSessionThread",
      "session history",
    ).call(resolved.provider, resolved.rawId, false);
    return requireProviderMethod(
      resolved.provider,
      "readSessionRuntime",
      "session runtime",
    ).call(resolved.provider, childThread);
  }

  public async listLoadedSessionIds(): Promise<string[]> {
    const ids = await Promise.all(
      this.orderedEntries
        .filter((entry) => hasProviderMethod(entry.provider, "listLoadedSessionIds"))
        .map(async (entry) =>
          (await entry.provider.listLoadedSessionIds!()).map((id) =>
            wrapProviderScopedId(entry.id, id),
          ),
        ),
    );
    return ids.flat();
  }

  public async resumeSessionThread(
    threadId: string,
    options?: AgentSessionResumeOptions,
  ): Promise<unknown> {
    const resolved = this.resolveSessionId(threadId);
    return requireProviderMethod(
      resolved.provider,
      "resumeSessionThread",
      "session resume",
    ).call(resolved.provider, resolved.rawId, options);
  }

  public async setSessionName(threadId: string, name: string): Promise<unknown> {
    const resolved = this.resolveSessionId(threadId);
    return requireProviderMethod(
      resolved.provider,
      "setSessionName",
      "session rename",
    ).call(resolved.provider, resolved.rawId, name);
  }

  public async archiveSession(threadId: string): Promise<unknown> {
    const resolved = this.resolveSessionId(threadId);
    return requireProviderMethod(
      resolved.provider,
      "archiveSession",
      "session archive",
    ).call(resolved.provider, resolved.rawId);
  }

  public async unarchiveSession(threadId: string): Promise<unknown> {
    const resolved = this.resolveSessionId(threadId);
    return requireProviderMethod(
      resolved.provider,
      "unarchiveSession",
      "session unarchive",
    ).call(resolved.provider, resolved.rawId);
  }

  public async compactSession(threadId: string): Promise<unknown> {
    const resolved = this.resolveSessionId(threadId);
    return requireProviderMethod(
      resolved.provider,
      "compactSession",
      "session compaction",
    ).call(resolved.provider, resolved.rawId);
  }

  public async createSession(
    request: AgentCreateSessionRequest,
  ): Promise<AgentCreateSessionResult> {
    const entry = this.resolveProviderKind(request.provider);
    const result = await requireProviderMethod(
      entry.provider,
      "createSession",
      "session creation",
    ).call(entry.provider, {
      ...request,
      provider: null,
    });
    return {
      ...result,
      thread: this.wrapThread(entry.id, result.thread),
    };
  }

  public async submitInput(
    request: AgentSubmitInputRequest,
  ): Promise<AgentSubmitInputResult> {
    const resolved = this.resolveSessionId(request.sessionId);
    return requireProviderMethod(
      resolved.provider,
      "submitInput",
      "session input",
    ).call(resolved.provider, {
      ...request,
      sessionId: resolved.rawId,
    });
  }

  public async interruptTurn(
    threadId: string,
    turnId: string,
  ): Promise<unknown> {
    const resolved = this.resolveSessionId(threadId);
    return requireProviderMethod(
      resolved.provider,
      "interruptTurn",
      "turn interruption",
    ).call(resolved.provider, resolved.rawId, turnId);
  }

  public respondToPendingAction(
    action: AgentPendingAction,
    decision: PendingActionResponseInput,
  ): boolean {
    const resolved = this.resolveAction(action);
    return requireProviderMethod(
      resolved.provider,
      "respondToPendingAction",
      "approval response",
    ).call(resolved.provider, resolved.action, decision);
  }

  public getProviderEntries(): ProviderEntry[] {
    return [...this.orderedEntries];
  }

  public resolveSessionProvider(threadId: string): ResolvedProviderEntry {
    return this.resolveSessionId(threadId);
  }

  private wrapLiveEvent(
    kind: string,
    event: AgentProviderLiveEvent,
  ): AgentProviderLiveEvent {
    if (event.type === "action_resolved") {
      return { ...event, sessionId: wrapProviderScopedId(kind, event.sessionId),
        actionId: wrapProviderScopedId(kind, event.actionId) };
    }
    if ("sessionId" in event && typeof event.sessionId === "string") {
      return {
        ...event,
        sessionId: wrapProviderScopedId(kind, event.sessionId),
      };
    }
    if (
      event.type === "action_opened" &&
      event.action &&
      typeof event.action === "object"
    ) {
      return {
        ...event,
        action: this.wrapAction(kind, event.action as AgentPendingAction),
      };
    }
    return event;
  }

  private wrapThread(kind: string, thread: ThreadRecord): ThreadRecord {
    return {
      ...thread,
      id: wrapProviderScopedId(kind, thread.id),
      providerId: kind,
      providerKind: this.resolveProviderKind(kind).kind,
      subAgent: thread.subAgent
        ? {
            ...thread.subAgent,
            parentSessionId: thread.subAgent.parentSessionId
              ? wrapProviderScopedId(kind, thread.subAgent.parentSessionId)
              : null,
          }
        : thread.subAgent,
    };
  }

  private wrapAction(
    kind: string,
    action: AgentPendingAction,
  ): AgentPendingAction {
    return {
      ...action,
      id: wrapProviderScopedId(kind, action.id),
      sessionId: wrapProviderScopedId(kind, action.sessionId),
    };
  }

  private resolveSessionId(threadId: string): ResolvedProviderEntry {
    const resolved = unwrapProviderScopedId(threadId);
    if (!resolved) {
      return {
        id: this.defaultProviderId,
        kind: this.defaultEntry().kind,
        rawId: threadId,
        provider: this.defaultEntry().provider,
      };
    }
    const entry = this.resolveProviderKind(resolved.kind);
    return {
      id: entry.id,
      kind: entry.kind,
      rawId: resolved.rawId,
      provider: entry.provider,
    };
  }

  private resolveAction(action: AgentPendingAction): {
    provider: AgentProvider;
    action: AgentPendingAction;
  } {
    const resolved = unwrapProviderScopedId(action.id) ??
      unwrapProviderScopedId(action.sessionId);
    const entry = resolved
      ? this.resolveProviderKind(resolved.kind)
      : this.defaultEntry();
    const nextAction = {
      ...action,
      id: unwrapProviderScopedId(action.id)?.rawId ?? action.id,
      sessionId: unwrapProviderScopedId(action.sessionId)?.rawId ?? action.sessionId,
    };
    return { provider: entry.provider, action: nextAction };
  }

  private resolveProviderKind(kind: string | null | undefined): ProviderEntry & { id: string } {
    const id = kind?.trim() || this.defaultProviderId;
    const matches = this.orderedEntries.filter((entry) => entry.kind === id);
    const entry = this.entriesById.get(id) ?? (matches.length === 1 ? matches[0] : undefined);
    if (!entry) throw new Error(`Unknown or ambiguous Sidemesh provider instance "${id}".`);
    return entry;
  }

  private defaultEntry(): ProviderEntry & { id: string } {
    return this.resolveProviderKind(this.defaultProviderId);
  }
}

export function wrapProviderScopedId(kind: string, rawId: string): string {
  return `${kind}:${Buffer.from(rawId, "utf8").toString("base64url")}`;
}

export function unwrapProviderScopedId(
  value: string,
): { kind: string; rawId: string } | null {
  const separator = value.indexOf(":");
  if (separator <= 0) {
    return null;
  }
  const kind = value.slice(0, separator);
  const encoded = value.slice(separator + 1);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) {
    return null;
  }
  try {
    const rawId = Buffer.from(encoded, "base64url").toString("utf8");
    if (!rawId || Buffer.from(rawId, "utf8").toString("base64url") !== encoded) return null;
    return { kind, rawId };
  } catch {
    return null;
  }
}

function normalizeThreadTimestamp(value: number): number {
  const timestamp = Math.trunc(value);
  return timestamp >= 1_000_000_000_000 ? timestamp : timestamp * 1000;
}
