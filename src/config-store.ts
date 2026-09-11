import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import nodePath from "node:path";
import { randomBytes } from "node:crypto";

import { z } from "zod";

import type {
  AgentProviderConfig,
  AcpxPermissionMode,
  FakeCapabilityProfile,
  NodeConfig,
  UpdateChannel,
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

const providerInstanceIdSchema = z.string().regex(/^[a-z][a-z0-9_-]{0,63}$/);

const codexProviderConfigSchema = z.object({
  kind: z.literal("codex"),
  id: providerInstanceIdSchema.optional(),
  bin: z.string().trim().min(1),
});

const piProviderConfigSchema = z.object({
  kind: z.literal("pi"),
  id: providerInstanceIdSchema.optional(),
  agentDir: z.string().trim().min(1).nullable(),
  stateDir: z.string().trim().min(1).nullable(),
});

const copilotProviderConfigSchema = z.object({
  kind: z.literal("copilot"),
  id: providerInstanceIdSchema.optional(),
  bin: z.string().trim().min(1),
  stateDir: z.string().trim().min(1).nullable(),
  allowAll: z.boolean(),
  configuredModel: z.string().trim().min(1).nullable(),
});

const opencodeProviderConfigSchema = z.object({
  kind: z.literal("opencode"),
  id: providerInstanceIdSchema.optional(),
  bin: z.string().trim().min(1),
  stateDir: z.string().trim().min(1).nullable(),
});

const acpxPermissionModeSchema = z.enum([
  "approve-reads",
  "deny-all",
] satisfies readonly AcpxPermissionMode[]);

const acpxProviderConfigSchema = z.object({
  kind: z.literal("acpx"),
  id: providerInstanceIdSchema.optional(),
  agent: z.string().trim().min(1),
  command: z.string().trim().min(1).nullable(),
  stateDir: z.string().trim().min(1).nullable(),
  permissionMode: acpxPermissionModeSchema.default("approve-reads"),
});

const fakeProviderConfigSchema = z.object({
  kind: z.literal("fake"),
  id: providerInstanceIdSchema.optional(),
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
  piProviderConfigSchema,
  copilotProviderConfigSchema,
  opencodeProviderConfigSchema,
  acpxProviderConfigSchema,
  fakeProviderConfigSchema,
]);

const updateChannelSchema = z.enum([
  "stable",
  "bleeding-edge",
] satisfies readonly UpdateChannel[]);

export const MOBILE_CLIENT_VERSION_PATTERN = /^[vV]?\d+(?:\.\d+)*(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;
const mobileClientVersionSchema = z
  .string()
  .trim()
  .min(1)
  .regex(
    MOBILE_CLIENT_VERSION_PATTERN,
    "must be a mobile client version like 1.2.0, v1.2.0, or 1.2.0+3",
  );

const persistedNodeConfigSchema = z.object({
  version: z.literal(CONFIG_VERSION).default(CONFIG_VERSION),
  label: z.string().trim().min(1).optional(),
  port: z.number().int().min(1).max(65535).optional(),
  token: z.string().trim().min(1).optional(),
  updateChannel: updateChannelSchema.default("stable"),
  recommendedMobileClientVersion: mobileClientVersionSchema.nullable().optional(),
  minimumMobileClientVersion: mobileClientVersionSchema.nullable().optional(),
  stateDir: z.string().trim().min(1).optional(),
  workspaceRoots: z
    .array(
      z
        .string()
        .trim()
        .min(1)
        .refine((value) => nodePath.isAbsolute(value), {
          message: "workspace roots must be absolute paths",
        }),
    )
    .optional(),
  allowedBrowserOrigins: z
    .array(
      z
        .string()
        .trim()
        .url()
        .refine(isHttpOrigin, {
          message: "browser origins must be HTTP(S) origins without a path",
        }),
    )
    .optional(),
  terminal: terminalConfigSchema.optional(),
  browserPreview: browserPreviewConfigSchema.optional(),
  defaultProviderId: providerInstanceIdSchema.optional(),
  defaultProviderKind: z
    .enum(["codex", "pi", "copilot", "opencode", "acpx", "fake"])
    .optional(),
  providers: z.array(persistedProviderConfigSchema).default([]).superRefine((providers, ctx) => {
    const ids = new Set<string>();
    for (const [index, provider] of providers.entries()) {
      const id = provider.id ?? provider.kind;
      if (ids.has(id)) ctx.addIssue({ code: "custom", path: [index, "id"], message: "provider instance IDs must be unique" });
      ids.add(id);
    }
  }),
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
          .map((issue) => {
            const path = issue.path.join(".");
            return path ? `${path}: ${issue.message}` : issue.message;
          })
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
    port:
      Number.isInteger(config.port) &&
      config.port >= 1 &&
      config.port <= 65535
        ? config.port
        : undefined,
    token: config.token,
    updateChannel: config.updateChannel,
    recommendedMobileClientVersion: config.recommendedMobileClientVersion,
    minimumMobileClientVersion: config.minimumMobileClientVersion,
    stateDir: config.stateDir,
    workspaceRoots: config.workspaceRoots,
    allowedBrowserOrigins:
      config.allowedBrowserOrigins?.length
        ? config.allowedBrowserOrigins
        : undefined,
    terminal: config.terminal,
    browserPreview: config.browserPreview,
    defaultProviderKind: config.defaultProviderKind,
    defaultProviderId: config.defaultProviderId,
    providers: config.providers.map((provider) =>
      normalizePersistedProviderConfig(provider),
    ),
  };
}

function isHttpOrigin(value: string): boolean {
  try {
    const parsed = new URL(value);
    return (
      (parsed.protocol === "http:" || parsed.protocol === "https:") &&
      parsed.origin === value.replace(/\/$/, "")
    );
  } catch {
    return false;
  }
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
  return persistedProviderConfigSchema.parse(provider);
}
