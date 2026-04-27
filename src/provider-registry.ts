import { CodexAgentProvider } from "./codex-provider.js";
import { FakeAgentProvider } from "./fake-provider.js";
import type { AgentProvider } from "./agent-provider.js";
import type {
  AgentProviderConfig,
  AgentProviderConfigSummary,
  AgentProviderKind,
  CodexProviderConfig,
  FakeCapabilityProfile,
  FakeProviderConfig,
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

export interface AgentProviderDefinitionSummary {
  kind: string;
  displayName: string;
  defaultCommand: string;
  commandEnvironmentVariables: string[];
}

export const DEFAULT_AGENT_PROVIDER_KIND: AgentProviderKind = "codex";
const CODEX_DEFAULT_COMMAND = "codex";
const FAKE_DEFAULT_COMMAND = "builtin";

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

const FAKE_PROVIDER_DEFINITION: AgentProviderDefinition = {
  kind: "fake",
  displayName: "Fake Test Provider",
  defaultCommand: FAKE_DEFAULT_COMMAND,
  commandEnvironmentVariables: [
    "SIDEMESH_FAKE_LATENCY_MS",
    "SIDEMESH_FAKE_SEED",
    "SIDEMESH_FAKE_WORKSPACE_ROOT",
    "SIDEMESH_FAKE_CAPABILITY_PROFILE",
  ],

  create(config) {
    const fake = expectFakeProviderConfig(config);
    return new FakeAgentProvider({
      latencyMs: fake.latencyMs,
      seedSessions: fake.seedSessions,
      workspaceRoot: fake.workspaceRoot,
      capabilityProfile: fake.capabilityProfile,
    });
  },

  loadConfig(env) {
    return {
      kind: "fake",
      latencyMs: parseInteger(env.SIDEMESH_FAKE_LATENCY_MS, 15),
      seedSessions: env.SIDEMESH_FAKE_SEED?.trim() !== "0",
      workspaceRoot: env.SIDEMESH_FAKE_WORKSPACE_ROOT?.trim() || null,
      capabilityProfile: parseFakeCapabilityProfile(
        env.SIDEMESH_FAKE_CAPABILITY_PROFILE,
      ),
    };
  },

  summarizeConfig(config) {
    const fake = expectFakeProviderConfig(config);
    return {
      kind: fake.kind,
      command: FAKE_DEFAULT_COMMAND,
    };
  },
};

const AGENT_PROVIDER_DEFINITIONS = [
  CODEX_PROVIDER_DEFINITION,
  FAKE_PROVIDER_DEFINITION,
] as const;

export function listAgentProviderDefinitions(): readonly AgentProviderDefinition[] {
  return AGENT_PROVIDER_DEFINITIONS;
}

export function listAgentProviderDefinitionSummaries(): AgentProviderDefinitionSummary[] {
  return AGENT_PROVIDER_DEFINITIONS.map((definition) => ({
    kind: definition.kind,
    displayName: definition.displayName,
    defaultCommand: definition.defaultCommand,
    commandEnvironmentVariables: [...definition.commandEnvironmentVariables],
  }));
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

function expectFakeProviderConfig(config: AgentProviderConfig): FakeProviderConfig {
  if (config.kind !== "fake") {
    throw new Error(`Expected fake provider config, got "${config.kind}"`);
  }
  return config;
}

function parseInteger(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

const FAKE_CAPABILITY_PROFILES = [
  "full",
  "chat-only",
  "no-files",
  "no-model-controls",
  "no-approvals",
  "minimal",
] as const satisfies readonly FakeCapabilityProfile[];

function parseFakeCapabilityProfile(
  value: string | undefined,
): FakeCapabilityProfile {
  const profile = value?.trim() || "full";
  if (
    FAKE_CAPABILITY_PROFILES.includes(
      profile as (typeof FAKE_CAPABILITY_PROFILES)[number],
    )
  ) {
    return profile as FakeCapabilityProfile;
  }
  throw new Error(
    `Unsupported SIDEMESH_FAKE_CAPABILITY_PROFILE "${profile}". Supported profiles: ${FAKE_CAPABILITY_PROFILES.join(", ")}`,
  );
}
