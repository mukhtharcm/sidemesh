import { CodexAgentProvider } from "./codex-provider.js";
import type { AgentProvider } from "./agent-provider.js";
import type {
  AgentProviderConfig,
  AgentProviderConfigSummary,
  AgentProviderKind,
  CodexProviderConfig,
} from "./types.js";

type ProviderEnvironment = Record<string, string | undefined>;

interface AgentProviderDefinition {
  readonly kind: AgentProviderKind;
  readonly displayName: string;
  readonly defaultCommand: string;
  readonly commandEnvironmentVariables: readonly string[];

  create(config: AgentProviderConfig): AgentProvider;
  loadConfig(env: ProviderEnvironment): AgentProviderConfig;
  summarizeConfig(config: AgentProviderConfig): AgentProviderConfigSummary;
}

export const DEFAULT_AGENT_PROVIDER_KIND: AgentProviderKind = "codex";
const CODEX_DEFAULT_COMMAND = "codex";

const CODEX_PROVIDER_DEFINITION: AgentProviderDefinition = {
  kind: "codex",
  displayName: "Codex",
  defaultCommand: CODEX_DEFAULT_COMMAND,
  commandEnvironmentVariables: [
    "SIDEMESH_CODEX_BIN",
    "SIDEMESH_PROVIDER_COMMAND",
  ],

  create(config) {
    const codex = expectCodexProviderConfig(config);
    return new CodexAgentProvider(codex.bin);
  },

  loadConfig(env) {
    return {
      kind: "codex",
      bin:
        env.SIDEMESH_CODEX_BIN?.trim() ||
        env.SIDEMESH_PROVIDER_COMMAND?.trim() ||
        CODEX_DEFAULT_COMMAND,
    };
  },

  summarizeConfig(config) {
    const codex = expectCodexProviderConfig(config);
    return {
      kind: codex.kind,
      command: codex.bin,
    };
  },
};

const AGENT_PROVIDER_DEFINITIONS = [CODEX_PROVIDER_DEFINITION] as const;

export function listAgentProviderDefinitions(): readonly AgentProviderDefinition[] {
  return AGENT_PROVIDER_DEFINITIONS;
}

export function supportedAgentProviderKinds(): AgentProviderKind[] {
  return AGENT_PROVIDER_DEFINITIONS.map((definition) => definition.kind);
}

export function isAgentProviderKind(value: string): value is AgentProviderKind {
  return AGENT_PROVIDER_DEFINITIONS.some((definition) => definition.kind === value);
}

export function loadAgentProviderConfig(
  kind: AgentProviderKind,
  env: ProviderEnvironment,
): AgentProviderConfig {
  return getAgentProviderDefinition(kind).loadConfig(env);
}

export function createAgentProviderFromConfig(
  config: AgentProviderConfig,
): AgentProvider {
  return getAgentProviderDefinition(config.kind).create(config);
}

export function summarizeAgentProviderConfig(
  config: AgentProviderConfig,
): AgentProviderConfigSummary {
  return getAgentProviderDefinition(config.kind).summarizeConfig(config);
}

function getAgentProviderDefinition(kind: AgentProviderKind): AgentProviderDefinition {
  const definition = AGENT_PROVIDER_DEFINITIONS.find((candidate) => candidate.kind === kind);
  if (!definition) {
    throw new Error(
      `Unsupported Sidemesh agent provider "${kind}". Supported providers: ${supportedAgentProviderKinds().join(", ")}`,
    );
  }
  return definition;
}

function expectCodexProviderConfig(config: AgentProviderConfig): CodexProviderConfig {
  if (config.kind !== "codex") {
    throw new Error(`Expected Codex provider config, got "${config.kind}"`);
  }
  return config;
}
