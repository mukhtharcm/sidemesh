import { inspectProviderConfig, type DoctorProviderReport } from "./doctor.js";
import {
  loadAgentProviderConfig,
  listSetupAgentProviderDefinitionSummaries,
} from "./provider-registry.js";
import type { AgentProviderConfig, AgentProviderKind } from "./types.js";

type Environment = Record<string, string | undefined>;

export type ProviderAutoDetectReadiness =
  | "ready"
  | "detected"
  | "unavailable";

export interface AutoDetectedProviderCandidate {
  kind: AgentProviderKind;
  displayName: string;
  config: AgentProviderConfig;
  report: DoctorProviderReport;
  readiness: ProviderAutoDetectReadiness;
}

export interface AutoDetectedProviders {
  defaultProviderKind: AgentProviderKind | null;
  providers: AgentProviderConfig[];
  candidates: AutoDetectedProviderCandidate[];
}

export async function inferInstalledProviderConfigs(options: {
  env?: Environment;
  stateDir: string;
  includeDev?: boolean;
  includeKinds?: readonly AgentProviderKind[];
}): Promise<AutoDetectedProviders> {
  const env = options.env ?? process.env;
  const definitions = listSetupAgentProviderDefinitionSummaries({
    includeDev: options.includeDev,
    includeKinds: options.includeKinds,
  });
  const candidates = await Promise.all(
    definitions.map(async (definition) => {
      const kind = definition.kind as AgentProviderKind;
      const config = loadAgentProviderConfig(kind, env);
      const report = await inspectProviderConfig(config, options.stateDir, {
        env,
      });
      return {
        kind,
        displayName: definition.displayName,
        config,
        report,
        readiness: classifyProviderAutoDetectReadiness(report),
      } satisfies AutoDetectedProviderCandidate;
    }),
  );
  const readyCandidates = candidates.filter(
    (candidate) => candidate.readiness === "ready",
  );
  const defaultProviderKind =
    readyCandidates.find((candidate) => candidate.kind === "codex")?.kind ??
    readyCandidates[0]?.kind ??
    null;
  const providers =
    defaultProviderKind == null
      ? []
      : reorderProviderConfigs(
          readyCandidates.map((candidate) => candidate.config),
          defaultProviderKind,
        );
  return {
    defaultProviderKind,
    providers,
    candidates,
  };
}

export function classifyProviderAutoDetectReadiness(
  report: DoctorProviderReport,
): ProviderAutoDetectReadiness {
  switch (report.kind) {
    case "codex":
    case "copilot":
      if (hasCheck(report, "binary", "error")) {
        return "unavailable";
      }
      return report.auth?.status === "authenticated" ? "ready" : "detected";
    case "pi":
      return hasCheck(report, "agentDir", "ok") ? "ready" : "unavailable";
    case "fake":
      return "unavailable";
    default:
      return "unavailable";
  }
}

function hasCheck(
  report: DoctorProviderReport,
  label: string,
  severity: DoctorProviderReport["checks"][number]["severity"],
): boolean {
  return report.checks.some(
    (check) => check.label === label && check.severity === severity,
  );
}

function reorderProviderConfigs(
  providers: AgentProviderConfig[],
  defaultProviderKind: AgentProviderKind,
): AgentProviderConfig[] {
  const defaultProvider = providers.find(
    (provider) => provider.kind === defaultProviderKind,
  );
  if (!defaultProvider) {
    return providers;
  }
  return [
    defaultProvider,
    ...providers.filter((provider) => provider.kind !== defaultProviderKind),
  ];
}
