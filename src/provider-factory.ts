import type { AgentProvider } from "./agent-provider.js";
import { MultiAgentProvider } from "./multi-provider.js";
import type { NodeConfig } from "./types.js";
import type { AgentProviderKind } from "./types.js";
import {
  createAgentProviderFromConfig,
  listAgentProviderDefinitionSummaries,
  summarizeAgentProviderConfig,
} from "./provider-registry.js";

export interface AgentProviderRuntimeEntry {
  id?: string;
  kind: AgentProviderKind;
  provider: AgentProvider;
  configSummary: ReturnType<typeof summarizeAgentProviderConfig>;
  definitionSummary: ReturnType<typeof listAgentProviderDefinitionSummaries>[number];
}

export interface AgentProviderRuntime {
  provider: AgentProvider;
  providers: AgentProviderRuntimeEntry[];
  defaultProviderKind: AgentProviderKind;
  defaultProviderId?: string;
  defaultProvider: AgentProviderRuntimeEntry;
  providerForKind(
    kind: string | null | undefined,
  ): AgentProviderRuntimeEntry | null;
  providerForSessionId(sessionId: string): AgentProviderRuntimeEntry | null;
}

export function createAgentProviderRuntime(
  config: NodeConfig,
): AgentProviderRuntime {
  const definitionSummaries = new Map(
    listAgentProviderDefinitionSummaries().map((summary) => [summary.kind, summary]),
  );
  const providers = config.providers.map((providerConfig) => {
    const definitionSummary = definitionSummaries.get(providerConfig.kind);
    if (!definitionSummary) {
      throw new Error(`Missing provider definition for "${providerConfig.kind}".`);
    }
    return {
      id: providerConfig.id ?? providerConfig.kind,
      kind: providerConfig.kind,
      provider: createAgentProviderFromConfig(providerConfig),
      configSummary: { ...summarizeAgentProviderConfig(providerConfig), id: providerConfig.id ?? providerConfig.kind },
      definitionSummary,
    };
  });
  const providersById = new Map(
    providers.map((entry) => [entry.id, entry]),
  );
  const defaultProviderId = config.defaultProviderId ?? config.defaultProviderKind;
  const defaultProvider = providersById.get(defaultProviderId);
  if (providersById.size !== providers.length) throw new Error("Provider instance IDs must be unique.");
  if (!defaultProvider) {
    throw new Error(
      `Default provider "${config.defaultProviderKind}" was not configured.`,
    );
  }
  const provider =
    providers.length === 1 && providers[0]!.id === providers[0]!.kind
        ? providers[0]!.provider
        : new MultiAgentProvider(
            providers.map((entry) => ({
              id: entry.id,
              kind: entry.kind,
              config: config.providers.find(
                (candidate) => (candidate.id ?? candidate.kind) === entry.id,
              )!,
              provider: entry.provider,
            })),
            defaultProviderId,
        );
  return {
    provider,
    providers,
    defaultProviderKind: defaultProvider.kind,
    defaultProviderId,
    defaultProvider,
    providerForKind(kind) {
      if (kind == null) {
        return defaultProvider;
      }
      const providerKind = kind.trim();
      if (!providerKind) {
        return null;
      }
      const matches = providers.filter((entry) => entry.kind === providerKind);
      return providersById.get(providerKind) ?? (matches.length === 1 ? matches[0]! : null);
    },
    providerForSessionId(sessionId) {
      if (provider instanceof MultiAgentProvider) {
        try {
          return providersById.get(
            provider.resolveSessionProvider(sessionId).id,
          ) ?? null;
        } catch {
          return null;
        }
      }
      return defaultProvider;
    },
  };
}
