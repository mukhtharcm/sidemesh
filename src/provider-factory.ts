import { CodexAgentProvider } from "./codex-provider.js";
import type { AgentProvider } from "./agent-provider.js";
import type { NodeConfig } from "./types.js";

export function createAgentProvider(config: NodeConfig): AgentProvider {
  switch (config.provider) {
    case "codex":
      return new CodexAgentProvider(config.codexBin);
    default:
      throw new Error(`Unsupported Sidemesh agent provider: ${config.provider}`);
  }
}
