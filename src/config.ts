import { hostname, homedir } from "node:os";
import { randomBytes } from "node:crypto";
import { join } from "node:path";

import type {
  AgentProviderConfig,
  AgentProviderConfigSummary,
  AgentProviderKind,
  NodeConfig,
} from "./types.js";
import {
  persistedConfigFromNodeConfig,
  providerConfigByKind,
  readPersistedConfig,
  resolveConfigPath,
  type PersistedNodeConfig,
  writePersistedConfig,
} from "./config-store.js";
import {
  DEFAULT_AGENT_PROVIDER_KIND,
  isAgentProviderKind,
  resolveAgentProviderConfig,
  summarizeAgentProviderConfig,
  supportedAgentProviderKinds,
} from "./provider-registry.js";

type Environment = Record<string, string | undefined>;

export interface LoadConfigOptions {
  env?: Environment;
  configPath?: string | null;
  persistGeneratedToken?: boolean;
}

export interface SaveConfigOptions {
  configPath?: string | null;
}

export async function loadConfig(
  options: LoadConfigOptions = {},
): Promise<NodeConfig> {
  const env = options.env ?? process.env;
  const configPath = resolveConfigPath(options.configPath, env);
  const persisted = await readPersistedConfig(configPath);
  const label =
    env.SIDEMESH_LABEL?.trim() ||
    persisted.value?.label ||
    hostname();
  const stateDir =
    env.SIDEMESH_STATE_DIR?.trim() ||
    persisted.value?.stateDir ||
    join(homedir(), ".sidemesh");
  const port = parseInteger(
    env.SIDEMESH_PORT,
    persisted.value?.port ?? 8787,
  );
  const { defaultProviderKind, providers } = resolveProviderConfigs(
    persisted.value,
    env,
  );
  const provider =
    providers.find((candidate) => candidate.kind === defaultProviderKind) ??
    providers[0];
  if (!provider) {
    throw new Error("No Sidemesh providers were configured.");
  }

  let tokenSource: NodeConfig["tokenSource"];
  let token = env.SIDEMESH_TOKEN?.trim() || null;
  if (token) {
    tokenSource = "env";
  } else if (persisted.value?.token?.trim()) {
    token = persisted.value.token.trim();
    tokenSource = "file";
  } else {
    token = randomBytes(24).toString("hex");
    tokenSource = "generated";
  }

  const config: NodeConfig = {
    label,
    port,
    token,
    tokenSource,
    provider,
    providers,
    defaultProviderKind,
    stateDir,
    configPath,
    configExists: persisted.exists,
  };

  if (tokenSource === "generated" && options.persistGeneratedToken === true) {
    await saveConfig(config, { configPath });
    return {
      ...config,
      tokenSource: "file",
      configExists: true,
    };
  }

  return config;
}

export async function saveConfig(
  config: NodeConfig,
  options: SaveConfigOptions = {},
): Promise<void> {
  const configPath = resolveConfigPath(options.configPath ?? config.configPath);
  await writePersistedConfig(configPath, persistedConfigFromNodeConfig(config));
}

export async function readResolvedPersistedConfig(
  options: { env?: Environment; configPath?: string | null } = {},
): Promise<{
  path: string;
  exists: boolean;
  value: PersistedNodeConfig | null;
}> {
  const env = options.env ?? process.env;
  const configPath = resolveConfigPath(options.configPath, env);
  return readPersistedConfig(configPath);
}

export async function rotatePersistedToken(
  options: { env?: Environment; configPath?: string | null } = {},
): Promise<NodeConfig> {
  const config = await loadConfig({
    env: options.env,
    configPath: options.configPath,
    persistGeneratedToken: false,
  });
  const rotated: NodeConfig = {
    ...config,
    token: randomBytes(24).toString("hex"),
    tokenSource: "file",
  };
  await saveConfig(rotated, { configPath: rotated.configPath });
  return { ...rotated, configExists: true };
}

export function summarizeProviderConfig(
  provider: AgentProviderConfig,
): AgentProviderConfigSummary {
  return summarizeAgentProviderConfig(provider);
}

function resolveProviderConfigs(
  persisted: PersistedNodeConfig | null,
  env: Environment,
): {
  defaultProviderKind: AgentProviderKind;
  providers: AgentProviderConfig[];
} {
  const configuredKinds = parseProviderKinds(
    env.SIDEMESH_PROVIDERS,
    persisted,
  );
  const defaultProviderKind = env.SIDEMESH_PROVIDER?.trim()
    ? parseProviderKind(env.SIDEMESH_PROVIDER)
    : persisted?.defaultProviderKind ||
      configuredKinds[0] ||
      DEFAULT_AGENT_PROVIDER_KIND;
  const kinds = dedupeProviderKinds([
    defaultProviderKind,
    ...(configuredKinds.length > 0 ? configuredKinds : [defaultProviderKind]),
  ]);
  return {
    defaultProviderKind,
    providers: kinds.map((kind) =>
      resolveAgentProviderConfig(kind, env, providerConfigByKind(persisted, kind)),
    ),
  };
}

function parseProviderKind(value: string | undefined): AgentProviderKind {
  const provider = value?.trim() || DEFAULT_AGENT_PROVIDER_KIND;
  if (isAgentProviderKind(provider)) {
    return provider;
  }
  throw new Error(
    `Unsupported SIDEMESH_PROVIDER "${provider}". Supported providers: ${supportedAgentProviderKinds().join(", ")}`,
  );
}

function parseProviderKinds(
  value: string | undefined,
  persisted: PersistedNodeConfig | null,
): AgentProviderKind[] {
  if (!value?.trim()) {
    return persisted?.providers
      .map((provider) => provider.kind)
      .filter(isAgentProviderKind) ?? [];
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean)
    .map((item) => {
      if (isAgentProviderKind(item)) {
        return item;
      }
      throw new Error(
        `Unsupported SIDEMESH_PROVIDERS entry "${item}". Supported providers: ${supportedAgentProviderKinds().join(", ")}`,
      );
    });
}

function dedupeProviderKinds(
  kinds: AgentProviderKind[],
): AgentProviderKind[] {
  const seen = new Set<AgentProviderKind>();
  return kinds.filter((kind) => {
    if (seen.has(kind)) {
      return false;
    }
    seen.add(kind);
    return true;
  });
}

function parseInteger(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}
