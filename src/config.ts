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
  const { defaultProviderKind, providers } = loadProviderConfigs();
  const provider =
    providers.find((candidate) => candidate.kind === defaultProviderKind) ??
    providers[0];
  if (!provider) {
    throw new Error("No Sidemesh providers were configured.");
  }
  return {
    label: process.env.SIDEMESH_LABEL?.trim() || hostname(),
    port: parseInteger(process.env.SIDEMESH_PORT, 8787),
    token: token || randomBytes(24).toString("hex"),
    tokenSource: token ? "env" : "generated",
    provider,
    providers,
    defaultProviderKind,
    stateDir:
      process.env.SIDEMESH_STATE_DIR?.trim() || join(homedir(), ".sidemesh"),
  };
}

export function summarizeProviderConfig(
  provider: AgentProviderConfig,
): AgentProviderConfigSummary {
  return summarizeAgentProviderConfig(provider);
}

function loadProviderConfigs(): {
  defaultProviderKind: AgentProviderKind;
  providers: AgentProviderConfig[];
} {
  const configuredKinds = parseProviderKinds(process.env.SIDEMESH_PROVIDERS);
  const defaultProviderKind = process.env.SIDEMESH_PROVIDER?.trim()
    ? parseProviderKind(process.env.SIDEMESH_PROVIDER)
    : (configuredKinds[0] ?? DEFAULT_AGENT_PROVIDER_KIND);
  const kinds = dedupeProviderKinds([
    defaultProviderKind,
    ...(configuredKinds.length > 0 ? configuredKinds : [defaultProviderKind]),
  ]);
  return {
    defaultProviderKind,
    providers: kinds.map((kind) => loadAgentProviderConfig(kind, process.env)),
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

function parseProviderKinds(value: string | undefined): AgentProviderKind[] {
  if (!value?.trim()) {
    return [];
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
