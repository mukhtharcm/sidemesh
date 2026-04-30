import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import nodePath from "node:path";
import { randomBytes } from "node:crypto";

import { z } from "zod";

import type {
  AgentProviderConfig,
  AgentProviderKind,
  FakeCapabilityProfile,
  NodeConfig,
} from "./types.js";

const CONFIG_VERSION = 1;
const DEFAULT_CONFIG_DIR = nodePath.join(homedir(), ".sidemesh");
const DEFAULT_CONFIG_PATH = nodePath.join(DEFAULT_CONFIG_DIR, "config.json");

const fakeCapabilityProfileSchema = z.enum([
  "full",
  "chat-only",
  "no-files",
  "no-model-controls",
  "no-approvals",
  "minimal",
] satisfies readonly FakeCapabilityProfile[]);

const codexProviderConfigSchema = z.object({
  kind: z.literal("codex"),
  bin: z.string().trim().min(1),
});

const copilotProviderConfigSchema = z.object({
  kind: z.literal("copilot"),
  bin: z.string().trim().min(1),
  stateDir: z.string().trim().min(1).nullable(),
  allowAll: z.boolean(),
  configuredModel: z.string().trim().min(1).nullable(),
});

const fakeProviderConfigSchema = z.object({
  kind: z.literal("fake"),
  latencyMs: z.number().int().min(0),
  seedSessions: z.boolean(),
  workspaceRoot: z.string().trim().min(1).nullable(),
  capabilityProfile: fakeCapabilityProfileSchema,
});

const terminalConfigSchema = z.object({
  enabled: z.boolean().default(false),
  shell: z.string().trim().min(1).nullable().default(null),
  requirePty: z.boolean().default(false),
});

const portForwardingConfigSchema = z.object({
  enabled: z.boolean().default(false),
  allowNonLoopbackTargets: z.boolean().default(false),
});

const browserPreviewConfigSchema = z.object({
  enabled: z.boolean().default(false),
  chromePath: z.string().trim().min(1).nullable().default(null),
  maxPreviews: z.number().int().min(1).max(32).default(8),
  idleTtlMs: z
    .number()
    .int()
    .min(30_000)
    .max(24 * 60 * 60 * 1000)
    .default(60 * 60 * 1000),
  frameIntervalMs: z.number().int().min(250).max(10_000).default(900),
  quality: z.number().int().min(20).max(95).default(55),
});

const persistedProviderConfigSchema = z.discriminatedUnion("kind", [
  codexProviderConfigSchema,
  copilotProviderConfigSchema,
  fakeProviderConfigSchema,
]);

const persistedNodeConfigSchema = z.object({
  version: z.literal(CONFIG_VERSION).default(CONFIG_VERSION),
  label: z.string().trim().min(1).optional(),
  port: z.number().int().min(1).max(65535).optional(),
  token: z.string().trim().min(1).optional(),
  stateDir: z.string().trim().min(1).optional(),
  terminal: terminalConfigSchema.optional(),
  portForwarding: portForwardingConfigSchema.optional(),
  browserPreview: browserPreviewConfigSchema.optional(),
  defaultProviderKind: z.enum(["codex", "copilot", "fake"]).optional(),
  providers: z.array(persistedProviderConfigSchema).default([]),
});

export type PersistedProviderConfig = z.infer<typeof persistedProviderConfigSchema>;
export type PersistedNodeConfig = z.infer<typeof persistedNodeConfigSchema>;

export interface ResolvedConfigSource {
  path: string;
  exists: boolean;
  value: PersistedNodeConfig | null;
}

export function defaultConfigPath(): string {
  return DEFAULT_CONFIG_PATH;
}

export function resolveConfigPath(
  explicitPath?: string | null,
  env: Record<string, string | undefined> = process.env,
): string {
  const candidate = explicitPath?.trim() || env.SIDEMESH_CONFIG?.trim();
  if (candidate) {
    return nodePath.resolve(candidate);
  }
  return DEFAULT_CONFIG_PATH;
}

export async function readPersistedConfig(
  configPath: string,
): Promise<ResolvedConfigSource> {
  try {
    const raw = await readFile(configPath, "utf8");
    const parsed = JSON.parse(raw) as unknown;
    return {
      path: configPath,
      exists: true,
      value: persistedNodeConfigSchema.parse(parsed),
    };
  } catch (error) {
    if ((error as NodeJS.ErrnoException | undefined)?.code === "ENOENT") {
      return { path: configPath, exists: false, value: null };
    }
    if (error instanceof SyntaxError) {
      throw new Error(
        `Invalid Sidemesh config at ${configPath}: ${error.message}`,
      );
    }
    if (error instanceof z.ZodError) {
      throw new Error(
        `Invalid Sidemesh config at ${configPath}: ${error.issues
          .map((issue) => issue.message)
          .join("; ")}`,
      );
    }
    throw error;
  }
}

export async function writePersistedConfig(
  configPath: string,
  config: PersistedNodeConfig,
): Promise<void> {
  await mkdir(nodePath.dirname(configPath), { recursive: true });
  const normalized = persistedNodeConfigSchema.parse(config);
  const payload = `${JSON.stringify(normalized, null, 2)}\n`;
  const tmpPath = `${configPath}.${randomBytes(6).toString("hex")}.tmp`;
  await writeFile(tmpPath, payload, { encoding: "utf8", mode: 0o600 });
  await rename(tmpPath, configPath);
  await chmod(configPath, 0o600).catch(() => {});
}

export function persistedConfigFromNodeConfig(
  config: NodeConfig,
): PersistedNodeConfig {
  return {
    version: CONFIG_VERSION,
    label: config.label,
    port: config.port,
    token: config.token,
    stateDir: config.stateDir,
    terminal: config.terminal,
    portForwarding: config.portForwarding,
    browserPreview: config.browserPreview,
    defaultProviderKind: config.defaultProviderKind,
    providers: config.providers.map((provider) =>
      normalizePersistedProviderConfig(provider),
    ),
  };
}

export function redactPersistedConfig(
  config: PersistedNodeConfig,
): Record<string, unknown> {
  return {
    ...config,
    token: config.token ? redactSecret(config.token) : undefined,
  };
}

export function redactSecret(value: string): string {
  if (value.length <= 8) {
    return `${value.slice(0, 2)}…${value.slice(-2)}`;
  }
  return `${value.slice(0, 4)}…${value.slice(-4)}`;
}

export function tokenFingerprint(token: string): string {
  return `${token.slice(0, 6)}…${token.slice(-4)}`;
}

export function normalizePersistedProviderConfig(
  provider: AgentProviderConfig,
): PersistedProviderConfig {
  switch (provider.kind) {
    case "codex":
      return { kind: "codex", bin: provider.bin };
    case "copilot":
      return {
        kind: "copilot",
        bin: provider.bin,
        stateDir: provider.stateDir,
        allowAll: provider.allowAll,
        configuredModel: provider.configuredModel,
      };
    case "fake":
      return {
        kind: "fake",
        latencyMs: provider.latencyMs,
        seedSessions: provider.seedSessions,
        workspaceRoot: provider.workspaceRoot,
        capabilityProfile: provider.capabilityProfile,
      };
  }
}

export function providerConfigByKind(
  config: PersistedNodeConfig | null,
  kind: AgentProviderKind,
): PersistedProviderConfig | null {
  return (
    config?.providers.find(
      (provider): provider is PersistedProviderConfig => provider.kind === kind,
    ) ?? null
  );
}
