import { hostname, homedir } from "node:os";
import { randomBytes } from "node:crypto";
import { join } from "node:path";

import type {
  AgentProviderConfig,
  AgentProviderConfigSummary,
  AgentProviderKind,
  NodeConfig,
} from "./types.js";

export function loadConfig(): NodeConfig {
  const token = process.env.SIDEMESH_TOKEN?.trim();
  return {
    label: process.env.SIDEMESH_LABEL?.trim() || hostname(),
    port: parseInteger(process.env.SIDEMESH_PORT, 8787),
    token: token || randomBytes(24).toString("hex"),
    tokenSource: token ? "env" : "generated",
    provider: loadProviderConfig(),
    stateDir:
      process.env.SIDEMESH_STATE_DIR?.trim() || join(homedir(), ".sidemesh"),
  };
}

export function summarizeProviderConfig(
  provider: AgentProviderConfig,
): AgentProviderConfigSummary {
  switch (provider.kind) {
    case "codex":
      return {
        kind: provider.kind,
        command: provider.bin,
      };
    default:
      throw new Error(`Unhandled provider config: ${String(provider)}`);
  }
}

function loadProviderConfig(): AgentProviderConfig {
  const kind = parseProviderKind(process.env.SIDEMESH_PROVIDER);
  switch (kind) {
    case "codex":
      return {
        kind,
        bin:
          process.env.SIDEMESH_CODEX_BIN?.trim() ||
          process.env.SIDEMESH_PROVIDER_COMMAND?.trim() ||
          "codex",
      };
    default:
      throw new Error(`Unhandled provider kind: ${String(kind)}`);
  }
}

function parseProviderKind(value: string | undefined): AgentProviderKind {
  const provider = value?.trim() || "codex";
  switch (provider) {
    case "codex":
      return provider;
    default:
      throw new Error(`Unsupported SIDEMESH_PROVIDER "${provider}". Supported providers: codex`);
  }
}

function parseInteger(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}
