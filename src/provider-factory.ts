import type { AgentProvider } from "./agent-provider.js";
import type { NodeConfig } from "./types.js";
import { createAgentProviderFromConfig } from "./provider-registry.js";

export function createAgentProvider(config: NodeConfig): AgentProvider {
  return createAgentProviderFromConfig(config.provider);
}
