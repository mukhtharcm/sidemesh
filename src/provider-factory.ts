import { EventEmitter } from "node:events";

import { AgentProviderRequestError, type AgentProvider, type AgentProviderCapabilities, type AgentProviderLiveEvent, type AgentHostServices } from "./agent-provider.js";
import { capabilitiesForFakeProfile } from "./fake-provider.js";
import type { SessionStore } from "./session-store.js";
import { extendProviderOwnership, resolveSessionReference, wrapProviderScopedId, type ProviderOwnership, type SessionReference } from "./session-identity.js";
import type { AgentProviderKind, NodeConfig, ThreadRecord } from "./types.js";
import {
  createAgentProviderFromConfig,
  listAgentProviderDefinitionSummaries,
  summarizeAgentProviderConfig,
} from "./provider-registry.js";

export interface AgentProviderRuntimeEntry {
  id: string;
  kind: AgentProviderKind;
  configSummary: ReturnType<typeof summarizeAgentProviderConfig>;
  definitionSummary: ReturnType<typeof listAgentProviderDefinitionSummaries>[number];
  create(store?: SessionStore): AgentProvider;
  instance: AgentProvider | null;
  state: "idle" | "starting" | "ready" | "unavailable" | "closed";
  version: string | null;
  error: string | null;
  readonly capabilities: AgentProviderCapabilities;
  readonly displayName: string;
}

type ProviderRuntimeEvents = {
  liveEvent: [AgentProviderLiveEvent];
  stderr: [string];
  state: [AgentProviderRuntimeEntry];
};

/** Configured instances and their owned connections. This is not an agent provider. */
export class AgentProviderRuntime extends EventEmitter<ProviderRuntimeEvents> {
  readonly providers: AgentProviderRuntimeEntry[];
  readonly defaultProvider: AgentProviderRuntimeEntry;
  readonly defaultProviderKind: AgentProviderKind;
  private readonly byId: Map<string, AgentProviderRuntimeEntry>;
  private readonly starting = new Map<string, Promise<AgentProvider>>();
  private readonly detach = new Map<string, () => void>();
  private readonly stopping = new Map<string, Promise<void>>();
  private readonly restarting = new Set<string>();
  private store?: SessionStore;
  private hostServices?: AgentHostServices;
  private ownership: ProviderOwnership;
  private closed = false;
  private closing?: Promise<void>;

  constructor(
    entries: Array<Pick<AgentProviderRuntimeEntry, "id" | "kind" | "configSummary" | "definitionSummary" | "create">>,
    readonly defaultProviderId: string,
    store?: SessionStore,
  ) {
    super();
    this.providers = entries.map((source) => {
      const entry: AgentProviderRuntimeEntry = { ...source, instance: null, state: "idle", version: null, error: null,
        get capabilities() {
          const capabilities = entry.instance?.capabilities ?? entry.definitionSummary.capabilities;
          return { ...capabilities, lifecycle: { restart: true } };
        },
        get displayName() { return entry.instance?.displayName ?? entry.definitionSummary.displayName; },
      };
      return entry;
    });
    this.byId = new Map(this.providers.map((entry) => [entry.id, entry]));
    this.ownership = extendProviderOwnership(null, this.providers, defaultProviderId);
    this.defaultProvider = this.byId.get(defaultProviderId)!;
    this.defaultProviderKind = this.defaultProvider.kind;
    if (store) this.attachStore(store);
  }

  attachStore(store: SessionStore): void {
    if (this.store === store) return;
    if (this.store || this.providers.some((entry) => entry.instance)) throw new Error("Provider storage is already in use");
    this.ownership = store.configureProviderOwnership(this.providers, this.defaultProviderId);
    this.store = store;
  }

  attachHostServices(services: AgentHostServices): void {
    this.hostServices = services;
    for (const entry of this.providers) if (entry.instance) this.attachProviderHostServices(entry, entry.instance);
  }

  private attachProviderHostServices(entry: AgentProviderRuntimeEntry, provider: AgentProvider): void {
    if (this.hostServices) provider.attachHostServices?.({
      runAuthenticationTerminal: (request) => this.hostServices!.runAuthenticationTerminal({
        ...request, sessionId: wrapProviderScopedId(entry.id, request.sessionId),
      }),
    });
  }

  get sessionAliases(): ProviderOwnership { return structuredClone(this.ownership); }

  providerForKind(value: string | null | undefined): AgentProviderRuntimeEntry | null {
    if (value == null) return this.defaultProvider;
    const id = value.trim();
    if (!id) return null;
    const matches = this.providers.filter((entry) => entry.kind === id);
    return this.byId.get(id) ?? (matches.length === 1 ? matches[0]! : null);
  }

  providerForSessionId(sessionId: string): AgentProviderRuntimeEntry | null {
    const reference = resolveSessionReference(sessionId, this.ownership);
    return reference ? this.byId.get(reference.providerId) ?? null : null;
  }

  resolveSession(sessionId: string): SessionReference & { entry: AgentProviderRuntimeEntry } {
    const reference = resolveSessionReference(sessionId, this.ownership);
    const entry = reference ? this.byId.get(reference.providerId) : null;
    if (!entry || !reference) throw new AgentProviderRequestError("The session provider is not configured", 404, true);
    return { ...reference, entry };
  }

  wrapThread(entry: AgentProviderRuntimeEntry, thread: ThreadRecord): ThreadRecord {
    return { ...thread, id: wrapProviderScopedId(entry.id, thread.id), providerId: entry.id, providerKind: entry.kind,
      subAgent: thread.subAgent ? { ...thread.subAgent,
        parentSessionId: thread.subAgent.parentSessionId ? wrapProviderScopedId(entry.id, thread.subAgent.parentSessionId) : null,
      } : thread.subAgent };
  }

  ensure(entry: AgentProviderRuntimeEntry): Promise<AgentProvider> {
    if (this.closed) return Promise.reject(new AgentProviderRequestError("The host is stopping", 503, true));
    const pending = this.starting.get(entry.id);
    if (pending) return pending;
    if (entry.state === "ready" && entry.instance) return Promise.resolve(entry.instance);
    if (entry.state === "unavailable") return Promise.reject(new AgentProviderRequestError(`${entry.displayName} is unavailable: ${entry.error}`, 503, true));
    const starting = Promise.resolve().then(() => this.startEntry(entry));
    this.starting.set(entry.id, starting);
    void starting.finally(() => this.starting.delete(entry.id)).catch(() => undefined);
    return starting;
  }

  private async startEntry(entry: AgentProviderRuntimeEntry): Promise<AgentProvider> {
    if (this.closed) throw new AgentProviderRequestError("The host is stopping", 503, true);
    entry.state = "starting";
    entry.error = null;
    try {
      const provider = entry.create(this.store);
      entry.instance = provider;
      this.listen(entry, provider);
      this.attachProviderHostServices(entry, provider);
      await provider.start();
      if (this.closed || entry.error !== null) throw new Error(entry.error ?? "Provider stopped during startup");
      entry.version = await provider.getVersion().catch(() => "unknown");
      if (this.closed || entry.error !== null) throw new Error(entry.error ?? "The host is stopping");
      this.setState(entry, "ready");
      return provider;
    } catch (error) {
      await this.closeEntry(entry).catch(() => undefined);
      if (!this.closed) this.setState(entry, "unavailable", error);
      throw new AgentProviderRequestError(`${entry.displayName} could not start: ${error instanceof Error ? error.message : String(error)}`, 503, true);
    }
  }

  async restart(entry: AgentProviderRuntimeEntry): Promise<void> {
    if (this.closed) throw new AgentProviderRequestError("The host is stopping", 503, true);
    if (this.starting.has(entry.id)) throw new AgentProviderRequestError("Provider startup is already in progress", 409, true);
    this.restarting.add(entry.id);
    const starting = Promise.resolve().then(async () => {
      try {
        // Recreate the adapter so failed connections cannot retain stale session handles.
        await this.closeEntry(entry);
        this.restarting.delete(entry.id);
        if (this.closed) throw new Error("The host is stopping");
        return await this.startEntry(entry);
      } catch (error) {
        if (!this.closed) this.setState(entry, "unavailable", error);
        throw error;
      } finally { this.restarting.delete(entry.id); }
    });
    this.starting.set(entry.id, starting);
    this.setState(entry, "starting");
    try { await starting; } finally { this.starting.delete(entry.id); }
  }

  async checkHealth(): Promise<void> {
    await Promise.all(this.providers.filter((entry) => entry.instance && entry.state !== "starting").map(async (entry) => {
      const provider = entry.instance!;
      let timer: NodeJS.Timeout | undefined;
      try {
        const healthy = await Promise.race([
          provider.health ? provider.health() : provider.getVersion().then(() => true),
          new Promise<boolean>((resolve) => { timer = setTimeout(() => resolve(false), 5_000); }),
        ]);
        if (!this.closed && entry.instance === provider && !this.restarting.has(entry.id)) {
          this.setState(entry, healthy ? "ready" : "unavailable", healthy ? undefined : new Error("Provider health check failed"));
        }
      } catch (error) {
        if (!this.closed && entry.instance === provider) this.setState(entry, "unavailable", error);
      } finally { if (timer) clearTimeout(timer); }
    }));
  }

  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.closed = true;
    this.closing = (async () => {
      const results = await Promise.allSettled(this.providers.map((entry) => this.closeEntry(entry)));
      await Promise.allSettled(this.starting.values());
      for (const entry of this.providers) entry.state = "closed";
      const errors = results.flatMap((result) => result.status === "rejected" ? [result.reason] : []);
      if (errors.length) throw new AggregateError(errors, "Failed to close one or more agent providers");
    })();
    return this.closing;
  }

  private closeEntry(entry: AgentProviderRuntimeEntry): Promise<void> {
    const pending = this.stopping.get(entry.id);
    if (pending) return pending;
    const provider = entry.instance;
    if (!provider) return Promise.resolve();
    const stopping = (async () => {
      try { await provider.close?.(); }
      finally {
        this.detach.get(entry.id)?.();
        this.detach.delete(entry.id);
        if (entry.instance === provider) entry.instance = null;
      }
    })();
    this.stopping.set(entry.id, stopping);
    void stopping.finally(() => this.stopping.delete(entry.id)).catch(() => undefined);
    return stopping;
  }

  private setState(entry: AgentProviderRuntimeEntry, state: AgentProviderRuntimeEntry["state"], error?: unknown): void {
    const message = error == null ? null : error instanceof Error ? error.message : String(error);
    if (entry.state === state && entry.error === message) return;
    entry.state = state;
    entry.error = message;
    this.emit("state", entry);
  }

  private listen(entry: AgentProviderRuntimeEntry, provider: AgentProvider): void {
    if (this.detach.has(entry.id)) return;
    const live = (event: AgentProviderLiveEvent) => {
      if (event.type === "action_opened") this.emit("liveEvent", { ...event, action: { ...event.action,
        id: wrapProviderScopedId(entry.id, event.action.id), sessionId: wrapProviderScopedId(entry.id, event.action.sessionId) } });
      else if (event.type === "action_resolved") this.emit("liveEvent", { ...event,
        sessionId: wrapProviderScopedId(entry.id, event.sessionId), actionId: wrapProviderScopedId(entry.id, event.actionId) });
      else if ("sessionId" in event && event.sessionId) this.emit("liveEvent", { ...event, sessionId: wrapProviderScopedId(entry.id, event.sessionId) });
      else this.emit("liveEvent", event.type === "provider_warning" ? { ...event, source: entry.id } : event);
    };
    const stderr = (line: string) => this.emit("stderr", `[${entry.id}] ${line}`);
    const exit = (code: number | null) => {
      if (!this.closed && !this.restarting.has(entry.id)) this.setState(entry, "unavailable", new Error(`Provider exited (${code ?? "unknown"})`));
    };
    provider.on("liveEvent", live);
    provider.on("stderr", stderr);
    provider.on("exit", exit);
    this.detach.set(entry.id, () => { provider.off("liveEvent", live); provider.off("stderr", stderr); provider.off("exit", exit); });
  }
}

export function createAgentProviderRuntime(config: NodeConfig, sessionStore?: SessionStore): AgentProviderRuntime {
  const definitions = new Map(listAgentProviderDefinitionSummaries().map((summary) => [summary.kind, summary]));
  return new AgentProviderRuntime(config.providers.map((providerConfig) => {
    const definition = definitions.get(providerConfig.kind);
    const definitionSummary = definition && providerConfig.kind === "fake"
      ? { ...definition, capabilities: capabilitiesForFakeProfile(providerConfig.capabilityProfile) } : definition;
    if (!definitionSummary) throw new Error(`Missing provider definition for "${providerConfig.kind}"`);
    const id = providerConfig.id ?? providerConfig.kind;
    return { id, kind: providerConfig.kind,
      create: (store?: SessionStore) => createAgentProviderFromConfig(providerConfig, store),
      configSummary: { ...summarizeAgentProviderConfig(providerConfig), id }, definitionSummary };
  }), config.defaultProviderId ?? config.defaultProviderKind, sessionStore);
}
