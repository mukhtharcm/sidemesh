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
  DEFAULT_AGENT_PROVIDER_KIND,
  isAgentProviderKind,
  loadAgentProviderConfig,
  summarizeAgentProviderConfig,
  supportedAgentProviderKinds,
} from "./provider-registry.js";

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
  return summarizeAgentProviderConfig(provider);
}

function loadProviderConfig(): AgentProviderConfig {
  const kind = parseProviderKind(process.env.SIDEMESH_PROVIDER);
  return loadAgentProviderConfig(kind, process.env);
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

function parseInteger(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}
