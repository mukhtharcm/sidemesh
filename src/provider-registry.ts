import {
  CODEX_PROVIDER_CAPABILITIES,
  CodexAgentProvider,
} from "./codex-provider.js";
import {
  COPILOT_PROVIDER_CAPABILITIES,
  CopilotAgentProvider,
} from "./copilot-provider.js";
import {
  FAKE_PROVIDER_CAPABILITIES,
  FakeAgentProvider,
} from "./fake-provider.js";
import type {
  AgentProvider,
  AgentProviderCapabilities,
} from "./agent-provider.js";
import type {
  AgentProviderConfig,
  AgentProviderConfigSummary,
  AgentProviderKind,
  CodexProviderConfig,
  CopilotProviderConfig,
  FakeCapabilityProfile,
  FakeProviderConfig,
} from "./types.js";

type ProviderEnvironment = Record<string, string | undefined>;

interface AgentProviderDefinition {
  readonly kind: AgentProviderKind;
  readonly displayName: string;
  readonly setupAudience: "public" | "dev";
  readonly defaultCommand: string;
  readonly capabilities: AgentProviderCapabilities;
  readonly commandEnvironmentVariables: readonly string[];
  readonly supportedApprovalPolicies: readonly string[];

  create(config: AgentProviderConfig): AgentProvider;
  loadConfig(env: ProviderEnvironment): AgentProviderConfig;
  resolveConfig(
    env: ProviderEnvironment,
    base: AgentProviderConfig | null,
  ): AgentProviderConfig;
  summarizeConfig(config: AgentProviderConfig): AgentProviderConfigSummary;
}

export interface AgentProviderDefinitionSummary {
  kind: string;
  displayName: string;
  defaultCommand: string;
  commandEnvironmentVariables: string[];
  capabilities: AgentProviderCapabilities;
  supportedApprovalPolicies: string[];
  setupAudience: "public" | "dev";
}

export const DEFAULT_AGENT_PROVIDER_KIND: AgentProviderKind = "codex";
const CODEX_DEFAULT_COMMAND = "codex";
const FAKE_DEFAULT_COMMAND = "builtin";
const COPILOT_DEFAULT_COMMAND = "copilot";

const CODEX_PROVIDER_DEFINITION: AgentProviderDefinition = {
  kind: "codex",
  displayName: "Codex",
  setupAudience: "public",
  defaultCommand: CODEX_DEFAULT_COMMAND,
  capabilities: CODEX_PROVIDER_CAPABILITIES,
  commandEnvironmentVariables: [
    "SIDEMESH_CODEX_BIN",
    "SIDEMESH_PROVIDER_COMMAND",
  ],
  supportedApprovalPolicies: ["untrusted", "on-failure", "on-request", "never"],

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

  resolveConfig(env, base) {
    const codex = base?.kind === "codex" ? base : null;
    return {
      kind: "codex",
      bin:
        env.SIDEMESH_CODEX_BIN?.trim() ||
        env.SIDEMESH_PROVIDER_COMMAND?.trim() ||
        codex?.bin ||
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
  setupAudience: "dev",
  defaultCommand: FAKE_DEFAULT_COMMAND,
  capabilities: FAKE_PROVIDER_CAPABILITIES,
  commandEnvironmentVariables: [
    "SIDEMESH_FAKE_LATENCY_MS",
    "SIDEMESH_FAKE_SEED",
    "SIDEMESH_FAKE_WORKSPACE_ROOT",
    "SIDEMESH_FAKE_CAPABILITY_PROFILE",
  ],
  supportedApprovalPolicies: ["untrusted", "on-failure", "on-request", "never"],

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

  resolveConfig(env, base) {
    const fake = base?.kind === "fake" ? base : null;
    return {
      kind: "fake",
      latencyMs: parseInteger(
        env.SIDEMESH_FAKE_LATENCY_MS,
        fake?.latencyMs ?? 15,
      ),
      seedSessions:
        env.SIDEMESH_FAKE_SEED === undefined
          ? fake?.seedSessions ?? true
          : env.SIDEMESH_FAKE_SEED?.trim() !== "0",
      workspaceRoot:
        env.SIDEMESH_FAKE_WORKSPACE_ROOT?.trim() ??
        fake?.workspaceRoot ??
        null,
      capabilityProfile:
        env.SIDEMESH_FAKE_CAPABILITY_PROFILE === undefined
          ? fake?.capabilityProfile ?? "full"
          : parseFakeCapabilityProfile(env.SIDEMESH_FAKE_CAPABILITY_PROFILE),
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

const COPILOT_PROVIDER_DEFINITION: AgentProviderDefinition = {
  kind: "copilot",
  displayName: "GitHub Copilot",
  setupAudience: "public",
  defaultCommand: COPILOT_DEFAULT_COMMAND,
  capabilities: COPILOT_PROVIDER_CAPABILITIES,
  commandEnvironmentVariables: [
    "SIDEMESH_COPILOT_BIN",
    "SIDEMESH_PROVIDER_COMMAND",
    "SIDEMESH_COPILOT_STATE_DIR",
    "SIDEMESH_COPILOT_ALLOW_ALL",
    "SIDEMESH_COPILOT_MODEL",
    "COPILOT_MODEL",
    "COPILOT_PROVIDER_MODEL_ID",
    "COPILOT_PROVIDER_WIRE_MODEL",
  ],
  supportedApprovalPolicies: ["on-request", "never"],

  create(config) {
    const copilot = expectCopilotProviderConfig(config);
    return new CopilotAgentProvider({
      bin: copilot.bin,
      stateDir: copilot.stateDir,
      allowAll: copilot.allowAll,
      configuredModel: copilot.configuredModel,
    });
  },

  loadConfig(env) {
    return {
      kind: "copilot",
      bin:
        env.SIDEMESH_COPILOT_BIN?.trim() ||
        env.SIDEMESH_PROVIDER_COMMAND?.trim() ||
        COPILOT_DEFAULT_COMMAND,
      stateDir: env.SIDEMESH_COPILOT_STATE_DIR?.trim() || null,
      allowAll: parseBoolean(env.SIDEMESH_COPILOT_ALLOW_ALL, false),
      configuredModel:
        env.SIDEMESH_COPILOT_MODEL?.trim() ||
        env.COPILOT_MODEL?.trim() ||
        env.COPILOT_PROVIDER_MODEL_ID?.trim() ||
        env.COPILOT_PROVIDER_WIRE_MODEL?.trim() ||
        null,
    };
  },

  resolveConfig(env, base) {
    const copilot = base?.kind === "copilot" ? base : null;
    return {
      kind: "copilot",
      bin:
        env.SIDEMESH_COPILOT_BIN?.trim() ||
        env.SIDEMESH_PROVIDER_COMMAND?.trim() ||
        copilot?.bin ||
        COPILOT_DEFAULT_COMMAND,
      stateDir:
        env.SIDEMESH_COPILOT_STATE_DIR === undefined
          ? copilot?.stateDir ?? null
          : env.SIDEMESH_COPILOT_STATE_DIR?.trim() || null,
      allowAll:
        env.SIDEMESH_COPILOT_ALLOW_ALL === undefined
          ? copilot?.allowAll ?? false
          : parseBoolean(env.SIDEMESH_COPILOT_ALLOW_ALL, false),
      configuredModel:
        env.SIDEMESH_COPILOT_MODEL?.trim() ||
        env.COPILOT_MODEL?.trim() ||
        env.COPILOT_PROVIDER_MODEL_ID?.trim() ||
        env.COPILOT_PROVIDER_WIRE_MODEL?.trim() ||
        copilot?.configuredModel ||
        null,
    };
  },

  summarizeConfig(config) {
    const copilot = expectCopilotProviderConfig(config);
    return {
      kind: copilot.kind,
      command: copilot.bin,
    };
  },
};

const AGENT_PROVIDER_DEFINITIONS = [
  CODEX_PROVIDER_DEFINITION,
  FAKE_PROVIDER_DEFINITION,
  COPILOT_PROVIDER_DEFINITION,
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
    capabilities: definition.capabilities,
    supportedApprovalPolicies: [...definition.supportedApprovalPolicies],
    setupAudience: definition.setupAudience,
  }));
}

export function listSetupAgentProviderDefinitionSummaries(options: {
  includeDev?: boolean;
  includeKinds?: readonly AgentProviderKind[];
} = {}): AgentProviderDefinitionSummary[] {
  const includedKinds = new Set(options.includeKinds ?? []);
  return listAgentProviderDefinitionSummaries().filter(
    (definition) =>
      options.includeDev ||
      definition.setupAudience === "public" ||
      includedKinds.has(definition.kind as AgentProviderKind),
  );
}

export function supportedAgentProviderKinds(): AgentProviderKind[] {
  return AGENT_PROVIDER_DEFINITIONS.map((definition) => definition.kind);
}

export function isAgentProviderKind(value: string): value is AgentProviderKind {
  return AGENT_PROVIDER_DEFINITIONS.some(
    (definition) => definition.kind === value,
  );
}

export function loadAgentProviderConfig(
  kind: AgentProviderKind,
  env: ProviderEnvironment,
): AgentProviderConfig {
  return getAgentProviderDefinition(kind).loadConfig(env);
}

export function resolveAgentProviderConfig(
  kind: AgentProviderKind,
  env: ProviderEnvironment,
  base: AgentProviderConfig | null,
): AgentProviderConfig {
  return getAgentProviderDefinition(kind).resolveConfig(env, base);
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

function getAgentProviderDefinition(
  kind: AgentProviderKind,
): AgentProviderDefinition {
  const definition = AGENT_PROVIDER_DEFINITIONS.find(
    (candidate) => candidate.kind === kind,
  );
  if (!definition) {
    throw new Error(
      `Unsupported Sidemesh agent provider "${kind}". Supported providers: ${supportedAgentProviderKinds().join(", ")}`,
    );
  }
  return definition;
}

function expectCodexProviderConfig(
  config: AgentProviderConfig,
): CodexProviderConfig {
  if (config.kind !== "codex") {
    throw new Error(`Expected Codex provider config, got "${config.kind}"`);
  }
  return config;
}

function expectFakeProviderConfig(
  config: AgentProviderConfig,
): FakeProviderConfig {
  if (config.kind !== "fake") {
    throw new Error(`Expected fake provider config, got "${config.kind}"`);
  }
  return config;
}

function expectCopilotProviderConfig(
  config: AgentProviderConfig,
): CopilotProviderConfig {
  if (config.kind !== "copilot") {
    throw new Error(`Expected Copilot provider config, got "${config.kind}"`);
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

function parseBoolean(value: string | undefined, fallback: boolean): boolean {
  if (!value) {
    return fallback;
  }
  return ["1", "true", "yes", "on"].includes(value.trim().toLowerCase());
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
