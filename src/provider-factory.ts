import { CodexAgentProvider } from "./codex-provider.js";
import type { AgentProvider } from "./agent-provider.js";
import type { NodeConfig } from "./types.js";

export function createAgentProvider(config: NodeConfig): AgentProvider {
  switch (config.provider.kind) {
    case "codex":
      return new CodexAgentProvider(config.provider.bin);
    default:
      throw new Error(`Unsupported Sidemesh agent provider config: ${String(config.provider)}`);
  }
}
