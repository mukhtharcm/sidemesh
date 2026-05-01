import { hostname, homedir } from "node:os";
import { randomBytes } from "node:crypto";
import nodePath from "node:path";

import {
  confirm,
  intro,
  isCancel,
  multiselect,
  note,
  outro,
  select,
  text,
} from "@clack/prompts";

import { readResolvedPersistedConfig, saveConfig } from "./config.js";
import type {
  AgentProviderConfig,
  AgentProviderKind,
  HostBrowserPreviewConfig,
  HostPortForwardingConfig,
  HostTerminalConfig,
  NodeConfig,
} from "./types.js";
import { listSetupAgentProviderDefinitionSummaries } from "./provider-registry.js";

export interface SetupOptions {
  configPath?: string | null;
  includeDevProviders?: boolean;
}

export async function runSetup(options: SetupOptions = {}): Promise<NodeConfig> {
  const persisted = await readResolvedPersistedConfig({
    configPath: options.configPath,
  });
  const definitions = listSetupAgentProviderDefinitionSummaries({
    includeDev: options.includeDevProviders,
    includeKinds:
      persisted.value?.providers.map(
        (provider) => provider.kind as AgentProviderKind,
      ) ?? [],
  });
  const existing = persisted.value;

  intro("Sidemesh setup");
  note(
    persisted.exists
      ? `Editing ${persisted.path}`
      : `Creating ${persisted.path}`,
    "Config file",
  );

  const label = await promptText({
    message: "Host label",
    defaultValue: existing?.label || hostname(),
    validate: (value) =>
      value.trim() ? undefined : "Label cannot be empty.",
  });

  const portValue = await promptText({
    message: "Daemon port",
    defaultValue: String(existing?.port ?? 8787),
    validate: (value) => {
      const parsed = Number.parseInt(value, 10);
      if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) {
        return "Enter a port between 1 and 65535.";
      }
      return undefined;
    },
  });
  const port = Number.parseInt(portValue, 10);

  const stateDir = await promptText({
    message: "State directory",
    defaultValue: existing?.stateDir || nodePath.join(homedir(), ".sidemesh"),
    validate: (value) =>
      value.trim() ? undefined : "State directory cannot be empty.",
  });
  const terminal = await promptTerminalConfig(existing);
  const portForwarding = await promptPortForwardingConfig(existing);
  const browserPreview = await promptBrowserPreviewConfig(existing);

  const initialProviders =
    existing?.providers.map((provider) => provider.kind) ?? ["codex"];
  const providers = await multiselect<AgentProviderKind>({
    message: "Which providers should this daemon expose?",
    required: true,
    initialValues: initialProviders,
    options: definitions.map((definition) => ({
      value: definition.kind as AgentProviderKind,
      label: definition.displayName,
      hint: definition.defaultCommand,
    })),
  });
  if (isCancel(providers)) {
    throw new Error("Setup cancelled.");
  }

  const selectedProviders = providers as AgentProviderKind[];
  const defaultProvider = await select<AgentProviderKind>({
    message: "Default provider",
    initialValue:
      selectedProviders.includes(
        (existing?.defaultProviderKind as AgentProviderKind | undefined) ??
          "codex",
      )
        ? ((existing?.defaultProviderKind as AgentProviderKind | undefined) ??
          selectedProviders[0]!)
        : selectedProviders[0]!,
    options: selectedProviders.map((kind) => {
      const definition = definitions.find((entry) => entry.kind === kind)!;
      return { value: kind, label: definition.displayName };
    }),
  });
  if (isCancel(defaultProvider)) {
    throw new Error("Setup cancelled.");
  }

  const token = await promptText({
    message: "Shared token",
    defaultValue: existing?.token || randomBytes(24).toString("hex"),
    validate: (value) =>
      value.trim() ? undefined : "Token cannot be empty.",
  });

  const resolvedProviders: AgentProviderConfig[] = [];
  for (const kind of selectedProviders) {
    switch (kind) {
      case "codex":
        resolvedProviders.push(await promptCodexProvider(existing));
        break;
      case "pi":
        resolvedProviders.push(await promptPiProvider(existing, stateDir));
        break;
      case "copilot":
        resolvedProviders.push(await promptCopilotProvider(existing, stateDir));
        break;
      case "fake":
        resolvedProviders.push(await promptFakeProvider(existing));
        break;
    }
  }

  const shouldSave = await confirm({
    message: "Save this configuration?",
    initialValue: true,
  });
  if (isCancel(shouldSave) || !shouldSave) {
    throw new Error("Setup cancelled.");
  }

  const config: NodeConfig = {
    label: label.trim(),
    port,
    token: token.trim(),
    tokenSource: "file",
    provider:
      resolvedProviders.find((provider) => provider.kind === defaultProvider) ??
      resolvedProviders[0]!,
    providers: resolvedProviders,
    defaultProviderKind: defaultProvider as AgentProviderKind,
    stateDir: stateDir.trim(),
    terminal,
    portForwarding,
    browserPreview,
    configPath: persisted.path,
    configExists: true,
  };
  await saveConfig(config, { configPath: persisted.path });
  outro(
    [
      `Saved ${persisted.path}`,
      `Run: sidemesh daemon`,
      `Then pair with token ${config.token}`,
    ].join("\n"),
  );
  return config;
}

async function promptTerminalConfig(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<HostTerminalConfig> {
  note(
    "Terminal access exposes an interactive shell through authenticated Sidemesh clients. Enable it only on hosts you trust.",
    "Integrated terminal",
  );
  const current = existing?.terminal;
  const enabled = await confirm({
    message: "Enable integrated terminal on this host?",
    initialValue: current?.enabled ?? false,
  });
  if (isCancel(enabled)) {
    throw new Error("Setup cancelled.");
  }
  if (!enabled) {
    return {
      enabled: false,
      shell: current?.shell ?? null,
      requirePty: current?.requirePty ?? false,
    };
  }
  const shell = await promptText({
    message: "Terminal shell (leave blank for login shell)",
    defaultValue: current?.shell ?? process.env.SHELL ?? "",
    fallbackToDefaultOnEmpty: false,
  });
  const requirePty = await confirm({
    message: "Require a real PTY instead of falling back to pipes?",
    initialValue: current?.requirePty ?? false,
  });
  if (isCancel(requirePty)) {
    throw new Error("Setup cancelled.");
  }
  return {
    enabled: true,
    shell: shell.trim() || null,
    requirePty,
  };
}

async function promptPortForwardingConfig(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<HostPortForwardingConfig> {
  note(
    "Port forwarding lets authenticated Sidemesh clients preview services running on this host. By default it can only reach this host's localhost ports.",
    "Port forwarding",
  );
  const current = existing?.portForwarding;
  const enabled = await confirm({
    message: "Enable port forwarding on this host?",
    initialValue: current?.enabled ?? false,
  });
  if (isCancel(enabled)) {
    throw new Error("Setup cancelled.");
  }
  if (!enabled) {
    return {
      enabled: false,
      allowNonLoopbackTargets: current?.allowNonLoopbackTargets ?? false,
    };
  }
  const allowNonLoopbackTargets = await confirm({
    message: "Allow forwarding to non-localhost targets from this host?",
    initialValue: current?.allowNonLoopbackTargets ?? false,
  });
  if (isCancel(allowNonLoopbackTargets)) {
    throw new Error("Setup cancelled.");
  }
  return {
    enabled: true,
    allowNonLoopbackTargets,
  };
}

async function promptBrowserPreviewConfig(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<HostBrowserPreviewConfig> {
  note(
    "Remote browser preview starts Chromium on this host and streams page pixels to authenticated Sidemesh clients. Keep it disabled unless this host should render localhost web apps.",
    "Remote browser preview",
  );
  const current = existing?.browserPreview;
  const enabled = await confirm({
    message: "Enable remote browser preview on this host?",
    initialValue: current?.enabled ?? false,
  });
  if (isCancel(enabled)) {
    throw new Error("Setup cancelled.");
  }
  if (!enabled) {
    return {
      enabled: false,
      chromePath: current?.chromePath ?? null,
      maxPreviews: current?.maxPreviews ?? 8,
      idleTtlMs: current?.idleTtlMs ?? 60 * 60 * 1000,
      frameIntervalMs: current?.frameIntervalMs ?? 900,
      quality: current?.quality ?? 55,
    };
  }
  const chromePath = await promptText({
    message: "Chrome/Chromium path",
    defaultValue: current?.chromePath ?? "",
  });
  const defaults = {
    maxPreviews: current?.maxPreviews ?? 8,
    idleTtlMs: current?.idleTtlMs ?? 60 * 60 * 1000,
    frameIntervalMs: current?.frameIntervalMs ?? 900,
    quality: current?.quality ?? 55,
  };
  const tuneResources = await confirm({
    message: "Tune browser preview resource limits?",
    initialValue:
      defaults.maxPreviews !== 8 ||
      defaults.idleTtlMs !== 60 * 60 * 1000 ||
      defaults.frameIntervalMs !== 900 ||
      defaults.quality !== 55,
  });
  if (isCancel(tuneResources)) {
    throw new Error("Setup cancelled.");
  }
  const maxPreviews = tuneResources
    ? await promptInteger({
        message: "Max simultaneous browser previews",
        defaultValue: defaults.maxPreviews,
        min: 1,
        max: 32,
      })
    : defaults.maxPreviews;
  const idleTtlMs = tuneResources
    ? await promptInteger({
        message: "Idle cleanup after milliseconds",
        defaultValue: defaults.idleTtlMs,
        min: 30_000,
        max: 24 * 60 * 60 * 1000,
      })
    : defaults.idleTtlMs;
  const frameIntervalMs = tuneResources
    ? await promptInteger({
        message: "Screenshot interval milliseconds",
        defaultValue: defaults.frameIntervalMs,
        min: 250,
        max: 10_000,
      })
    : defaults.frameIntervalMs;
  const quality = tuneResources
    ? await promptInteger({
        message: "JPEG quality",
        defaultValue: defaults.quality,
        min: 20,
        max: 95,
      })
    : defaults.quality;
  return {
    enabled: true,
    chromePath: chromePath.trim() || null,
    maxPreviews,
    idleTtlMs,
    frameIntervalMs,
    quality,
  };
}

async function promptCodexProvider(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<AgentProviderConfig> {
  const current =
    existing?.providers.find((provider) => provider.kind === "codex") ?? null;
  const bin = await promptText({
    message: "Codex command",
    defaultValue: current?.kind === "codex" ? current.bin : "codex",
    validate: (value) =>
      value.trim() ? undefined : "Codex command cannot be empty.",
  });
  return { kind: "codex", bin: bin.trim() };
}

async function promptCopilotProvider(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
  stateDir: string,
): Promise<AgentProviderConfig> {
  const current =
    existing?.providers.find((provider) => provider.kind === "copilot") ?? null;
  const bin = await promptText({
    message: "Copilot command",
    defaultValue: current?.kind === "copilot" ? current.bin : "copilot",
    validate: (value) =>
      value.trim() ? undefined : "Copilot command cannot be empty.",
  });
  const copilotStateDir = await promptText({
    message: "Copilot state directory",
    defaultValue:
      current?.kind === "copilot"
        ? (current.stateDir ?? nodePath.join(stateDir, "copilot-provider"))
        : nodePath.join(stateDir, "copilot-provider"),
    validate: (value) =>
      value.trim() ? undefined : "Copilot state directory cannot be empty.",
  });
  const allowAll = await confirm({
    message: "Allow Copilot to auto-approve everything on this host?",
    initialValue: current?.kind === "copilot" ? current.allowAll : false,
  });
  if (isCancel(allowAll)) {
    throw new Error("Setup cancelled.");
  }
  const configuredModel = await promptText({
    message: "Default Copilot model (leave blank for auto)",
    defaultValue:
      current?.kind === "copilot" ? (current.configuredModel ?? "") : "",
    fallbackToDefaultOnEmpty: false,
  });
  return {
    kind: "copilot",
    bin: bin.trim(),
    stateDir: copilotStateDir.trim() || null,
    allowAll,
    configuredModel: configuredModel.trim() || null,
  };
}

async function promptPiProvider(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
  stateDir: string,
): Promise<AgentProviderConfig> {
  const current =
    existing?.providers.find((provider) => provider.kind === "pi") ?? null;
  const agentDir = await promptText({
    message: "Pi agent directory",
    defaultValue:
      current?.kind === "pi"
        ? (current.agentDir ?? nodePath.join(homedir(), ".pi", "agent"))
        : nodePath.join(homedir(), ".pi", "agent"),
    validate: (value) =>
      value.trim() ? undefined : "Pi agent directory cannot be empty.",
  });
  const piStateDir = await promptText({
    message: "Pi provider state directory",
    defaultValue:
      current?.kind === "pi"
        ? (current.stateDir ?? nodePath.join(stateDir, "pi-provider"))
        : nodePath.join(stateDir, "pi-provider"),
    validate: (value) =>
      value.trim() ? undefined : "Pi provider state directory cannot be empty.",
  });
  return {
    kind: "pi",
    agentDir: agentDir.trim() || null,
    stateDir: piStateDir.trim() || null,
  };
}

async function promptFakeProvider(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<AgentProviderConfig> {
  const current =
    existing?.providers.find((provider) => provider.kind === "fake") ?? null;
  const capabilityProfile = await select<
    "full" | "chat-only" | "no-files" | "no-model-controls" | "no-approvals" | "minimal"
  >({
    message: "Fake provider capability profile",
    initialValue:
      current?.kind === "fake" ? current.capabilityProfile : "full",
    options: [
      { value: "full", label: "full" },
      { value: "chat-only", label: "chat-only" },
      { value: "no-files", label: "no-files" },
      { value: "no-model-controls", label: "no-model-controls" },
      { value: "no-approvals", label: "no-approvals" },
      { value: "minimal", label: "minimal" },
    ],
  });
  if (isCancel(capabilityProfile)) {
    throw new Error("Setup cancelled.");
  }
  const workspaceRoot = await promptText({
    message: "Fake workspace root (optional)",
    defaultValue:
      current?.kind === "fake" ? (current.workspaceRoot ?? "") : "",
    fallbackToDefaultOnEmpty: false,
  });
  const latency = await promptText({
    message: "Fake latency in milliseconds",
    defaultValue: String(current?.kind === "fake" ? current.latencyMs : 15),
    validate: (value) => {
      const parsed = Number.parseInt(value, 10);
      if (!Number.isFinite(parsed) || parsed < 0) {
        return "Enter a non-negative integer.";
      }
      return undefined;
    },
  });
  const seedSessions = await confirm({
    message: "Seed the fake provider with demo sessions?",
    initialValue: current?.kind === "fake" ? current.seedSessions : true,
  });
  if (isCancel(seedSessions)) {
    throw new Error("Setup cancelled.");
  }
  return {
    kind: "fake",
    latencyMs: Number.parseInt(latency, 10),
    seedSessions,
    workspaceRoot: workspaceRoot.trim() || null,
    capabilityProfile,
  };
}

async function promptText(options: {
  message: string;
  defaultValue?: string;
  fallbackToDefaultOnEmpty?: boolean;
  validate?: (value: string) => string | Error | undefined;
}): Promise<string> {
  const value = await text({
    ...options,
    validate: options.validate
      ? (rawValue) =>
          options.validate!(
            normalizePromptTextValue(String(rawValue), {
              defaultValue: options.defaultValue,
              fallbackToDefaultOnEmpty: options.fallbackToDefaultOnEmpty,
            }),
          )
      : undefined,
  });
  if (isCancel(value)) {
    throw new Error("Setup cancelled.");
  }
  return normalizePromptTextValue(String(value), {
    defaultValue: options.defaultValue,
    fallbackToDefaultOnEmpty: options.fallbackToDefaultOnEmpty,
  });
}

async function promptInteger(options: {
  message: string;
  defaultValue: number;
  min: number;
  max: number;
}): Promise<number> {
  const value = await promptText({
    message: options.message,
    defaultValue: String(options.defaultValue),
    validate: (raw) => {
      const parsed = Number.parseInt(raw, 10);
      if (
        !Number.isFinite(parsed) ||
        parsed < options.min ||
        parsed > options.max
      ) {
        return `Enter a number between ${options.min} and ${options.max}.`;
      }
      return undefined;
    },
  });
  return Number.parseInt(value, 10);
}

export function normalizePromptTextValue(
  value: string,
  options: {
    defaultValue?: string;
    fallbackToDefaultOnEmpty?: boolean;
  } = {},
): string {
  const shouldFallback =
    options.fallbackToDefaultOnEmpty !== false &&
    options.defaultValue !== undefined &&
    value.trim() === "";
  if (shouldFallback) {
    return options.defaultValue!;
  }
  return value;
}
