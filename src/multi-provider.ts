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
import type {
  AgentFsDirectoryListing,
  AgentFsFile,
  AgentFsMetadata,
  AgentFsWatchResult,
  AgentModelListOptions,
  AgentProfileListOptions,
  AgentRemoteGitDiff,
  AgentSkillConfigWriteRequest,
  AgentSkillListOptions,
} from "./agent-provider.js";
import type { PendingActionResponseInput } from "./approvals.js";
import type {
  AgentProviderConfig,
  AgentProviderKind,
  ModelSummary,
  ProviderProfileCatalog,
  SessionLogSnapshot,
  SessionRuntimeSummary,
  SkillCatalogEntry,
  ThreadRecord,
} from "./types.js";

interface ProviderEntry {
  kind: AgentProviderKind;
  config: AgentProviderConfig;
  provider: AgentProvider;
}

interface ResolvedProviderEntry {
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

  private readonly entriesByKind: Map<AgentProviderKind, ProviderEntry>;
  private readonly orderedEntries: ProviderEntry[];

  public constructor(
    entries: ProviderEntry[],
    private readonly defaultProviderKind: AgentProviderKind,
  ) {
    super();
    this.orderedEntries = [...entries];
    this.entriesByKind = new Map(entries.map((entry) => [entry.kind, entry]));
    const defaultEntry = this.entriesByKind.get(defaultProviderKind);
    if (!defaultEntry) {
      throw new Error(
        `Default provider "${defaultProviderKind}" was not configured.`,
      );
    }
    this.kind = defaultEntry.provider.kind;
    this.displayName = defaultEntry.provider.displayName;
    this.capabilities = mergeCapabilities(
      entries.map((entry) => entry.provider.capabilities),
    );
    for (const entry of this.orderedEntries) {
      entry.provider.on("liveEvent", (event) => {
        this.emit("liveEvent", this.wrapLiveEvent(entry.kind, event));
      });
      entry.provider.on("stderr", (line) => {
        const prefix =
          entry.kind === this.defaultProviderKind ? "" : `[${entry.kind}] `;
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
    await Promise.all(
      this.orderedEntries.map((entry) => entry.provider.close?.() ?? Promise.resolve()),
    );
  }

  public async getVersion(): Promise<string> {
    return this.defaultEntry().provider.getVersion();
  }

  public async listSessionThreads(
    options: AgentSessionListOptions,
  ): Promise<ThreadRecord[]> {
    const threads = await Promise.all(
      this.orderedEntries
        .filter(
          (entry) =>
            hasProviderMethod(entry.provider, "listSessionThreads") &&
            entry.provider.capabilities.sessions.history,
        )
        .map(async (entry) =>
          (await entry.provider.listSessionThreads!(options)).map((thread) =>
            this.wrapThread(entry.kind, thread),
          ),
        ),
    );
    return threads
      .flat()
      .sort((left, right) => right.updatedAt - left.updatedAt)
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
    return this.wrapThread(resolved.kind, thread);
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
          ).map((thread) => this.wrapThread(entry.kind, thread)),
        ),
    );
    return threads
      .flat()
      .sort((left, right) => right.updatedAt - left.updatedAt)
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
            wrapProviderScopedId(entry.kind, id),
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
      thread: this.wrapThread(entry.kind, result.thread),
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

  public async listSkills(options: AgentSkillListOptions): Promise<SkillCatalogEntry> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "listSkills",
      "skills",
    ).call(entry.provider, options);
  }

  public async writeSkillConfig(
    request: AgentSkillConfigWriteRequest,
  ): Promise<unknown> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "writeSkillConfig",
      "skill management",
    ).call(entry.provider, request);
  }

  public async listModels(
    options: AgentModelListOptions,
  ): Promise<ModelSummary[]> {
    const entry = this.resolveProviderKind(options.provider);
    return requireProviderMethod(
      entry.provider,
      "listModels",
      "model catalog",
    ).call(entry.provider, {
      ...options,
      provider: null,
    });
  }

  public async listProfiles(
    options: AgentProfileListOptions,
  ): Promise<ProviderProfileCatalog> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "listProfiles",
      "profiles",
    ).call(entry.provider, options);
  }

  public async readRemoteGitDiff(cwd: string): Promise<AgentRemoteGitDiff> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "readRemoteGitDiff",
      "remote git diff",
    ).call(entry.provider, cwd);
  }

  public async fsReadDirectory(path: string): Promise<AgentFsDirectoryListing> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsReadDirectory",
      "filesystem",
    ).call(entry.provider, path);
  }

  public async fsGetMetadata(path: string): Promise<AgentFsMetadata> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsGetMetadata",
      "filesystem",
    ).call(entry.provider, path);
  }

  public async fsReadFile(path: string): Promise<AgentFsFile> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsReadFile",
      "filesystem",
    ).call(entry.provider, path);
  }

  public async fsWriteFile(path: string, dataBase64: string): Promise<unknown> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsWriteFile",
      "filesystem",
    ).call(entry.provider, path, dataBase64);
  }

  public async fsCreateDirectory(
    path: string,
    recursive: boolean,
  ): Promise<unknown> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsCreateDirectory",
      "filesystem",
    ).call(entry.provider, path, recursive);
  }

  public async fsRemove(
    path: string,
    options: { recursive: boolean; force: boolean },
  ): Promise<unknown> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsRemove",
      "filesystem",
    ).call(entry.provider, path, options);
  }

  public async fsCopy(params: {
    sourcePath: string;
    destinationPath: string;
    recursive: boolean;
  }): Promise<unknown> {
    const entry = this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsCopy",
      "filesystem",
    ).call(entry.provider, params);
  }

  public async fsWatch(path: string): Promise<AgentFsWatchResult> {
    const entry = this.defaultEntry();
    const result = await requireProviderMethod(
      entry.provider,
      "fsWatch",
      "filesystem",
    ).call(entry.provider, path);
    return {
      watchId: wrapProviderScopedId(entry.kind, result.watchId),
    };
  }

  public async fsUnwatch(watchId: string): Promise<unknown> {
    const resolved = unwrapProviderScopedId(watchId);
    const entry = resolved
      ? this.resolveProviderKind(resolved.kind)
      : this.defaultEntry();
    return requireProviderMethod(
      entry.provider,
      "fsUnwatch",
      "filesystem",
    ).call(entry.provider, resolved?.rawId ?? watchId);
  }

  public getProviderEntries(): ProviderEntry[] {
    return [...this.orderedEntries];
  }

  public resolveSessionProvider(threadId: string): ResolvedProviderEntry {
    return this.resolveSessionId(threadId);
  }

  private wrapLiveEvent(
    kind: AgentProviderKind,
    event: AgentProviderLiveEvent,
  ): AgentProviderLiveEvent {
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
    if (
      event.type === "fs_changed" &&
      typeof event.watchId === "string" &&
      event.watchId.length > 0
    ) {
      return {
        ...event,
        watchId: wrapProviderScopedId(kind, event.watchId),
      };
    }
    return event;
  }

  private wrapThread(kind: AgentProviderKind, thread: ThreadRecord): ThreadRecord {
    return {
      ...thread,
      id: wrapProviderScopedId(kind, thread.id),
    };
  }

  private wrapAction(
    kind: AgentProviderKind,
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
        kind: this.defaultProviderKind,
        rawId: threadId,
        provider: this.defaultEntry().provider,
      };
    }
    const entry = this.resolveProviderKind(resolved.kind);
    return {
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

  private resolveProviderKind(kind: string | null | undefined): ProviderEntry {
    const providerKind = (kind?.trim() || this.defaultProviderKind) as AgentProviderKind;
    const entry = this.entriesByKind.get(providerKind);
    if (!entry) {
      throw new Error(`Unknown Sidemesh provider "${providerKind}".`);
    }
    return entry;
  }

  private defaultEntry(): ProviderEntry {
    return this.resolveProviderKind(this.defaultProviderKind);
  }
}

function mergeCapabilities(
  capabilitiesList: AgentProviderCapabilities[],
): AgentProviderCapabilities {
  const any = (selector: (caps: AgentProviderCapabilities) => boolean) =>
    capabilitiesList.some(selector);
  return {
    sessions: {
      create: any((caps) => caps.sessions.create),
      resume: any((caps) => caps.sessions.resume),
      rename: any((caps) => caps.sessions.rename),
      archive: any((caps) => caps.sessions.archive),
      compact: any((caps) => caps.sessions.compact),
      interrupt: any((caps) => caps.sessions.interrupt),
      history: any((caps) => caps.sessions.history),
      eventReplay: any((caps) => caps.sessions.eventReplay),
      recentFallback: any((caps) => caps.sessions.recentFallback),
    },
    input: {
      text: any((caps) => caps.input.text),
      imageUrl: any((caps) => caps.input.imageUrl),
      localImage: any((caps) => caps.input.localImage),
      skills: any((caps) => caps.input.skills),
      fileMentions: any((caps) => caps.input.fileMentions),
    },
    interaction: {
      userInput: any((caps) => caps.interaction.userInput),
      elicitation: any((caps) => caps.interaction.elicitation),
    },
    approvals: {
      command: any((caps) => caps.approvals.command),
      tool: any((caps) => caps.approvals.tool),
      fileChange: any((caps) => caps.approvals.fileChange),
      permissions: any((caps) => caps.approvals.permissions),
      approveForSession: any((caps) => caps.approvals.approveForSession),
    },
    configuration: {
      models: any((caps) => caps.configuration.models),
      profiles: any((caps) => caps.configuration.profiles),
      skills: any((caps) => caps.configuration.skills),
      skillManagement: any((caps) => caps.configuration.skillManagement),
    },
    runtimeControls: {
      model: any((caps) => caps.runtimeControls.model),
      mode: any((caps) => caps.runtimeControls.mode),
      reasoningEffort: any((caps) => caps.runtimeControls.reasoningEffort),
      fastMode: any((caps) => caps.runtimeControls.fastMode),
      approvalPolicy: any((caps) => caps.runtimeControls.approvalPolicy),
      sandboxMode: any((caps) => caps.runtimeControls.sandboxMode),
      networkAccess: any((caps) => caps.runtimeControls.networkAccess),
      webSearch: any((caps) => caps.runtimeControls.webSearch),
    },
    workspace: {
      filesystem: any((caps) => caps.workspace.filesystem),
      remoteGitDiff: any((caps) => caps.workspace.remoteGitDiff),
    },
  };
}

function wrapProviderScopedId(kind: AgentProviderKind, rawId: string): string {
  return `${kind}:${Buffer.from(rawId, "utf8").toString("base64url")}`;
}

function unwrapProviderScopedId(
  value: string,
): { kind: AgentProviderKind; rawId: string } | null {
  const separator = value.indexOf(":");
  if (separator <= 0) {
    return null;
  }
  const kind = value.slice(0, separator) as AgentProviderKind;
  const encoded = value.slice(separator + 1);
  if (!encoded) {
    return null;
  }
  try {
    return {
      kind,
      rawId: Buffer.from(encoded, "base64url").toString("utf8"),
    };
  } catch {
    return null;
  }
}
