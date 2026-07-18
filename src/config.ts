import { hostname, homedir } from "node:os";
import { randomBytes } from "node:crypto";
import { isAbsolute, join } from "node:path";

import type {
  AgentProviderConfig,
  AgentProviderConfigSummary,
  AgentProviderKind,
  HostBrowserPreviewConfig,
  HostTerminalConfig,
  NodeConfig,
  UpdateChannel,
} from "./types.js";
import {
  MOBILE_CLIENT_VERSION_PATTERN,
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
import { inferInstalledProviderConfigs } from "./provider-autodetect.js";

type Environment = Record<string, string | undefined>;

const DEFAULT_BROWSER_PREVIEW_MAX_PREVIEWS = 8;
const DEFAULT_BROWSER_PREVIEW_IDLE_TTL_MS = 60 * 60 * 1000;
const DEFAULT_BROWSER_PREVIEW_FRAME_INTERVAL_MS = 900;
const DEFAULT_BROWSER_PREVIEW_QUALITY = 55;

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
  const workspaceRoots = resolveWorkspaceRoots(
    env.SIDEMESH_WORKSPACE_ROOTS,
    persisted.value?.workspaceRoots ?? [],
  );
  const port = parseInteger(
    env.SIDEMESH_PORT,
    persisted.value?.port ?? 8787,
  );
  const { defaultProviderKind, providers } = await resolveProviderConfigs(
    persisted.value,
    env,
    stateDir,
  );
  const terminal = resolveTerminalConfig(persisted.value, env);
  const browserPreview = resolveBrowserPreviewConfig(persisted.value, env);
  const updateChannel = parseUpdateChannel(
    env.SIDEMESH_UPDATE_CHANNEL,
    persisted.value?.updateChannel ?? "stable",
  );
  const recommendedMobileClientVersion = parseOptionalMobileClientVersion(
    "SIDEMESH_RECOMMENDED_MOBILE_CLIENT_VERSION",
    env.SIDEMESH_RECOMMENDED_MOBILE_CLIENT_VERSION,
    persisted.value?.recommendedMobileClientVersion ?? null,
  );
  const minimumMobileClientVersion = parseOptionalMobileClientVersion(
    "SIDEMESH_MINIMUM_MOBILE_CLIENT_VERSION",
    env.SIDEMESH_MINIMUM_MOBILE_CLIENT_VERSION,
    persisted.value?.minimumMobileClientVersion ?? null,
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
    updateChannel,
    recommendedMobileClientVersion,
    minimumMobileClientVersion,
    stateDir,
    workspaceRoots,
    terminal,
    browserPreview,
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

function resolveWorkspaceRoots(
  environmentValue: string | undefined,
  persistedRoots: string[],
): string[] {
  const roots = environmentValue?.trim()
    ? environmentValue.split(",")
    : persistedRoots;
  const normalized = roots
    .map((root) => root.trim())
    .filter((root) => root.length > 0);
  const invalid = normalized.find((root) => !isAbsolute(root));
  if (invalid) {
    throw new Error(`Workspace root must be an absolute path: ${invalid}`);
  }
  return [...new Set(normalized)];
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

async function resolveProviderConfigs(
  persisted: PersistedNodeConfig | null,
  env: Environment,
  stateDir: string,
): Promise<{
  defaultProviderKind: AgentProviderKind;
  providers: AgentProviderConfig[];
}> {
  const explicitProviderKinds = parseProviderKinds(
    env.SIDEMESH_PROVIDERS,
    persisted,
    env,
  );
  let configuredKinds = explicitProviderKinds;
  const hasExplicitProviderSelection = Boolean(
    env.SIDEMESH_PROVIDER?.trim() || env.SIDEMESH_PROVIDERS?.trim(),
  );
  if (!hasExplicitProviderSelection && configuredKinds.length === 0) {
    const inferred = await inferInstalledProviderConfigs({
      env,
      stateDir,
    });
    if (inferred.providers.length > 0 && inferred.defaultProviderKind) {
      return {
        defaultProviderKind: inferred.defaultProviderKind,
        providers: inferred.providers,
      };
    }
  }
  const persistedDefaultProviderKind =
    persisted?.defaultProviderKind ?? null;
  const defaultProviderKind = env.SIDEMESH_PROVIDER?.trim()
    ? parseProviderKind(env.SIDEMESH_PROVIDER, env)
    : persistedDefaultProviderKind ||
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

function parseProviderKind(
  value: string | undefined,
  _env: Environment,
): AgentProviderKind {
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
  _env: Environment,
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

function parseUpdateChannel(
  value: string | undefined,
  fallback: UpdateChannel,
): UpdateChannel {
  const channel = value?.trim() || fallback;
  if (channel === "stable" || channel === "bleeding-edge") {
    return channel;
  }
  throw new Error(
    `Unsupported SIDEMESH_UPDATE_CHANNEL "${channel}". Supported channels: stable, bleeding-edge`,
  );
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

function parseOptionalMobileClientVersion(
  name: string,
  value: string | undefined,
  fallback: string | null,
): string | null {
  if (value === undefined) {
    return fallback;
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) {
    return null;
  }
  if (!MOBILE_CLIENT_VERSION_PATTERN.test(trimmed)) {
    throw new Error(
      `${name} must be a mobile client version like 1.2.0, v1.2.0, or 1.2.0+3`,
    );
  }
  return trimmed;
}

function resolveTerminalConfig(
  persisted: PersistedNodeConfig | null,
  env: Environment,
): HostTerminalConfig {
  const terminal = persisted?.terminal;
  const envEnabled = parseOptionalBoolean(
    env.SIDEMESH_TERMINAL ?? env.SIDEMESH_ENABLE_TERMINAL,
  );
  const envRequirePty = parseOptionalBoolean(env.SIDEMESH_TERMINAL_REQUIRE_PTY);
  const envShell = env.SIDEMESH_TERMINAL_SHELL?.trim();
  return {
    enabled: envEnabled ?? terminal?.enabled ?? false,
    shell:
      env.SIDEMESH_TERMINAL_SHELL !== undefined
        ? envShell || null
        : terminal?.shell ?? null,
    requirePty: envRequirePty ?? terminal?.requirePty ?? false,
  };
}

function resolveBrowserPreviewConfig(
  persisted: PersistedNodeConfig | null,
  env: Environment,
): HostBrowserPreviewConfig {
  const browserPreview = persisted?.browserPreview;
  const envEnabled = parseOptionalBoolean(
    env.SIDEMESH_BROWSER_PREVIEW ?? env.SIDEMESH_ENABLE_BROWSER_PREVIEW,
  );
  const envChromePath = env.SIDEMESH_BROWSER_PREVIEW_CHROME_PATH?.trim();
  const maxPreviews = parseBoundedInteger(
    env.SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS,
    browserPreview?.maxPreviews ?? DEFAULT_BROWSER_PREVIEW_MAX_PREVIEWS,
    1,
    32,
  );
  const idleTtlMs = parseBoundedInteger(
    env.SIDEMESH_BROWSER_PREVIEW_IDLE_TTL_MS,
    browserPreview?.idleTtlMs ?? DEFAULT_BROWSER_PREVIEW_IDLE_TTL_MS,
    30_000,
    24 * 60 * 60 * 1000,
  );
  const frameIntervalMs = parseBoundedInteger(
    env.SIDEMESH_BROWSER_PREVIEW_FRAME_INTERVAL_MS,
    browserPreview?.frameIntervalMs ?? DEFAULT_BROWSER_PREVIEW_FRAME_INTERVAL_MS,
    250,
    10_000,
  );
  const quality = parseBoundedInteger(
    env.SIDEMESH_BROWSER_PREVIEW_QUALITY,
    browserPreview?.quality ?? DEFAULT_BROWSER_PREVIEW_QUALITY,
    20,
    95,
  );
  return {
    enabled: envEnabled ?? browserPreview?.enabled ?? false,
    chromePath:
      env.SIDEMESH_BROWSER_PREVIEW_CHROME_PATH !== undefined
        ? envChromePath || null
        : browserPreview?.chromePath ?? null,
    maxPreviews,
    idleTtlMs,
    frameIntervalMs,
    quality,
  };
}

function parseOptionalBoolean(value: string | undefined): boolean | null {
  if (value === undefined) return null;
  const normalized = value.trim().toLowerCase();
  if (!normalized) return null;
  if (["1", "true", "yes", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "off"].includes(normalized)) return false;
  return null;
}

function parseInteger(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseBoundedInteger(
  value: string | undefined,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = parseInteger(value, fallback);
  return Math.max(min, Math.min(max, parsed));
}
