import type { AgentProvider } from "./agent-provider.js";
import { MultiAgentProvider } from "./multi-provider.js";
import type { NodeConfig } from "./types.js";
import type { AgentProviderKind } from "./types.js";
import {
  createAgentProviderFromConfig,
  isAgentProviderKind,
  listAgentProviderDefinitionSummaries,
  summarizeAgentProviderConfig,
} from "./provider-registry.js";

export interface AgentProviderRuntimeEntry {
  kind: AgentProviderKind;
  provider: AgentProvider;
  configSummary: ReturnType<typeof summarizeAgentProviderConfig>;
  definitionSummary: ReturnType<typeof listAgentProviderDefinitionSummaries>[number];
}

export interface AgentProviderRuntime {
  provider: AgentProvider;
  providers: AgentProviderRuntimeEntry[];
  defaultProviderKind: AgentProviderKind;
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
      kind: providerConfig.kind,
      provider: createAgentProviderFromConfig(providerConfig),
      configSummary: summarizeAgentProviderConfig(providerConfig),
      definitionSummary,
    };
  });
  const providersByKind = new Map(
    providers.map((entry) => [entry.kind, entry]),
  );
  const defaultProvider = providersByKind.get(config.defaultProviderKind);
  if (!defaultProvider) {
    throw new Error(
      `Default provider "${config.defaultProviderKind}" was not configured.`,
    );
  }
  const provider =
    providers.length === 1
        ? providers[0]!.provider
        : new MultiAgentProvider(
            providers.map((entry) => ({
              kind: entry.kind,
              config: config.providers.find(
                (candidate) => candidate.kind === entry.kind,
              )!,
              provider: entry.provider,
            })),
            config.defaultProviderKind,
        );
  return {
    provider,
    providers,
    defaultProviderKind: config.defaultProviderKind,
    defaultProvider,
    providerForKind(kind) {
      const providerKind = kind?.trim() ?? "";
      if (!providerKind) {
        return defaultProvider;
      }
      if (!isAgentProviderKind(providerKind)) {
        return null;
      }
      return providersByKind.get(providerKind) ?? null;
    },
    providerForSessionId(sessionId) {
      if (provider instanceof MultiAgentProvider) {
        try {
          return providersByKind.get(
            provider.resolveSessionProvider(sessionId).kind,
          ) ?? null;
        } catch {
          return null;
        }
      }
      return defaultProvider;
    },
  };
}

export function createAgentProvider(config: NodeConfig): AgentProvider {
  return createAgentProviderRuntime(config).provider;
}
