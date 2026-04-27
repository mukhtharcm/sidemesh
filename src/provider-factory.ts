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
  kind: AgentProviderKind;
  provider: AgentProvider;
  configSummary: ReturnType<typeof summarizeAgentProviderConfig>;
  definitionSummary: ReturnType<typeof listAgentProviderDefinitionSummaries>[number];
}

export interface AgentProviderRuntime {
  provider: AgentProvider;
  providers: AgentProviderRuntimeEntry[];
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
  return {
    provider:
      providers.length === 1
        ? providers[0]!.provider
        : new MultiAgentProvider(
            providers.map((entry) => ({
              kind: entry.kind,
              config: config.providers.find((candidate) => candidate.kind === entry.kind)!,
              provider: entry.provider,
            })),
            config.defaultProviderKind,
          ),
    providers,
  };
}

export function createAgentProvider(config: NodeConfig): AgentProvider {
  return createAgentProviderRuntime(config).provider;
}
