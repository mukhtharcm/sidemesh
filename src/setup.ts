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
  UpdateChannel,
} from "./types.js";
import { listSetupAgentProviderDefinitionSummaries } from "./provider-registry.js";
import { inferInstalledProviderConfigs } from "./provider-autodetect.js";

export interface SetupOptions {
  configPath?: string | null;
  includeDevProviders?: boolean;
  /** Show advanced prompts for daemon port and state directory. */
  advanced?: boolean;
}

type HostFeature = "terminal" | "portForwarding" | "browserPreview";

export async function runSetup(options: SetupOptions = {}): Promise<NodeConfig> {
  const persisted = await readResolvedPersistedConfig({
    configPath: options.configPath,
  });
  const definitions = listSetupAgentProviderDefinitionSummaries({
    includeDev: options.includeDevProviders,
    includeKinds: [
      ...(persisted.value?.providers.map(
        (provider) => provider.kind as AgentProviderKind,
      ) ?? []),
    ],
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

  // Port and state dir are advanced — accept defaults silently unless --advanced is passed.
  let port = existing?.port ?? 8787;
  let stateDir = existing?.stateDir || nodePath.join(homedir(), ".sidemesh");
  if (options.advanced) {
    const portValue = await promptText({
      message: "Daemon port",
      defaultValue: String(port),
      validate: (value) => {
        const parsed = Number.parseInt(value, 10);
        if (!Number.isFinite(parsed) || parsed < 1 || parsed > 65535) {
          return "Enter a port between 1 and 65535.";
        }
        return undefined;
      },
    });
    port = Number.parseInt(portValue, 10);

    stateDir = await promptText({
      message: "State directory",
      defaultValue: stateDir,
      validate: (value) =>
        value.trim() ? undefined : "State directory cannot be empty.",
    });
  }

  const inferredProviders =
    existing == null
      ? await inferInstalledProviderConfigs({
          env: process.env,
          stateDir,
          includeDev: options.includeDevProviders === true,
        })
      : null;
  if (existing == null && inferredProviders && inferredProviders.providers.length > 0) {
    note(
      `Detected ready providers: ${inferredProviders.candidates
        .filter((candidate) => candidate.readiness === "ready")
        .map((candidate) => candidate.displayName)
        .join(", ")}`,
      "Provider detection",
    );
  }

  // Providers
  const initialProviders =
    existing?.providers.map((provider) => provider.kind) ??
    inferredProviders?.providers.map((provider) => provider.kind) ??
    ["codex"];
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

  // Only ask for a default when there is a real choice.
  let defaultProvider: AgentProviderKind = selectedProviders[0]!;
  if (selectedProviders.length > 1) {
    const picked = await select<AgentProviderKind>({
      message: "Default provider",
      initialValue: selectedProviders.includes(
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
    if (isCancel(picked)) {
      throw new Error("Setup cancelled.");
    }
    defaultProvider = picked as AgentProviderKind;
  }

  // Per-provider configuration
  const resolvedProviders: AgentProviderConfig[] = [];
  for (const kind of selectedProviders) {
    switch (kind) {
      case "codex":
        resolvedProviders.push(
          await promptCodexProvider(existing, {
            advanced: options.advanced === true,
          }),
        );
        break;
      case "pi":
        resolvedProviders.push(await promptPiProvider(existing, stateDir));
        break;
      case "copilot":
        resolvedProviders.push(await promptCopilotProvider(existing, stateDir));
        break;
      case "opencode":
        resolvedProviders.push(
          await promptOpenCodeProvider(existing, stateDir, {
            advanced: options.advanced === true,
          }),
        );
        break;
      case "acpx":
        resolvedProviders.push(await promptAcpxProvider(existing, stateDir));
        break;
      case "fake":
        resolvedProviders.push(await promptFakeProvider(existing));
        break;
    }
  }

  // Optional host features — single multiselect with inline descriptions so
  // users understand what each feature does before opting in.
  const currentlyEnabled: HostFeature[] = [];
  if (existing?.terminal?.enabled) currentlyEnabled.push("terminal");
  if (existing?.portForwarding?.enabled) currentlyEnabled.push("portForwarding");
  if (existing?.browserPreview?.enabled) currentlyEnabled.push("browserPreview");

  const selectedFeatures = await multiselect<HostFeature>({
    message: "Optional host features  (space to toggle, enter to confirm)",
    required: false,
    initialValues: currentlyEnabled,
    options: [
      {
        value: "terminal",
        label: "Integrated terminal",
        hint: "Expose an interactive shell to authenticated clients",
      },
      {
        value: "portForwarding",
        label: "Port forwarding",
        hint: "Let clients preview local services running on this host's ports",
      },
      {
        value: "browserPreview",
        label: "Remote browser preview",
        hint: "Stream screenshots of localhost web apps to clients (requires Chromium)",
      },
    ],
  });
  if (isCancel(selectedFeatures)) {
    throw new Error("Setup cancelled.");
  }
  const features = selectedFeatures as HostFeature[];

  const terminal = features.includes("terminal")
    ? await promptTerminalDetails(existing)
    : defaultTerminalConfig(existing);

  const portForwarding = features.includes("portForwarding")
    ? await promptPortForwardingDetails(existing)
    : defaultPortForwardingConfig(existing);

  const browserPreview = features.includes("browserPreview")
    ? await promptBrowserPreviewDetails(existing)
    : defaultBrowserPreviewConfig(existing);

  let updateChannel: UpdateChannel = existing?.updateChannel ?? "stable";
  if (shouldPromptForUpdateChannel(existing, options)) {
    note(
      "Stable gets tagged releases. Bleeding edge gets the newest commits on origin/main for git installs.",
      "Update channel",
    );
    const selectedUpdateChannel = await select<UpdateChannel>({
      message: "Update channel",
      initialValue: updateChannel,
      options: [
        {
          value: "stable",
          label: "Stable",
          hint: "Tagged releases",
        },
        {
          value: "bleeding-edge",
          label: "Bleeding edge",
          hint: "Latest commits on main (git installs only)",
        },
      ],
    });
    if (isCancel(selectedUpdateChannel)) {
      throw new Error("Setup cancelled.");
    }
    updateChannel = selectedUpdateChannel as UpdateChannel;
  }

  // Token is auto-generated on first setup and preserved on re-runs.
  // Use `sidemesh pair` to display it for pairing.
  const token = existing?.token || randomBytes(24).toString("hex");

  const config: NodeConfig = {
    label: label.trim(),
    port,
    token,
    tokenSource: "file",
    provider:
      resolvedProviders.find((provider) => provider.kind === defaultProvider) ??
      resolvedProviders[0]!,
    providers: resolvedProviders,
    defaultProviderKind: defaultProvider as AgentProviderKind,
    updateChannel,
    stateDir: stateDir.trim(),
    terminal,
    portForwarding,
    browserPreview,
    configPath: persisted.path,
    configExists: true,
  };
  await saveConfig(config, { configPath: persisted.path });
  const lifecycleNote =
    process.platform === "darwin"
      ? "\n\nOn macOS, use `sidemesh service install` if you want the app's Restart and Update buttons to bring the host back on their own."
      : process.platform === "linux"
        ? "\n\nOn Linux, use `sudo sidemesh service install` if you want the app's Restart and Update buttons to bring the host back on their own."
        : "";
  outro(
    `Saved ${persisted.path}\n\n  ❯ sidemesh up${lifecycleNote}`,
  );
  return config;
}

// ── Terminal ─────────────────────────────────────────────────────────────────

function defaultTerminalConfig(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): HostTerminalConfig {
  return {
    enabled: false,
    shell: existing?.terminal?.shell ?? null,
    requirePty: existing?.terminal?.requirePty ?? false,
  };
}

async function promptTerminalDetails(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<HostTerminalConfig> {
  note(
    "Terminal access exposes an interactive shell through authenticated Sidemesh clients. Enable it only on hosts you trust.",
    "Integrated terminal",
  );
  const current = existing?.terminal;
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

// ── Port forwarding ───────────────────────────────────────────────────────────

function defaultPortForwardingConfig(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): HostPortForwardingConfig {
  return {
    enabled: false,
    allowNonLoopbackTargets:
      existing?.portForwarding?.allowNonLoopbackTargets ?? false,
  };
}

async function promptPortForwardingDetails(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<HostPortForwardingConfig> {
  note(
    "Port forwarding lets authenticated Sidemesh clients preview services running on this host. By default it can only reach this host's localhost ports.",
    "Port forwarding",
  );
  const current = existing?.portForwarding;
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

// ── Browser preview ───────────────────────────────────────────────────────────

function defaultBrowserPreviewConfig(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): HostBrowserPreviewConfig {
  const current = existing?.browserPreview;
  return {
    enabled: false,
    chromePath: current?.chromePath ?? null,
    maxPreviews: current?.maxPreviews ?? 8,
    idleTtlMs: current?.idleTtlMs ?? 60 * 60 * 1000,
    frameIntervalMs: current?.frameIntervalMs ?? 900,
    quality: current?.quality ?? 55,
  };
}

async function promptBrowserPreviewDetails(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
): Promise<HostBrowserPreviewConfig> {
  note(
    "Remote browser preview starts Chromium on this host and streams page pixels to authenticated Sidemesh clients. Keep it disabled unless this host should render localhost web apps.",
    "Remote browser preview",
  );
  const current = existing?.browserPreview;
  const chromePath = await promptText({
    message: "Chrome/Chromium path (leave blank to auto-detect)",
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
        message: "Idle cleanup after (milliseconds)",
        defaultValue: defaults.idleTtlMs,
        min: 30_000,
        max: 24 * 60 * 60 * 1000,
      })
    : defaults.idleTtlMs;
  const frameIntervalMs = tuneResources
    ? await promptInteger({
        message: "Screenshot interval (milliseconds)",
        defaultValue: defaults.frameIntervalMs,
        min: 250,
        max: 10_000,
      })
    : defaults.frameIntervalMs;
  const quality = tuneResources
    ? await promptInteger({
        message: "JPEG quality (20–95)",
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
  options: {
    advanced: boolean;
  },
): Promise<AgentProviderConfig> {
  const current =
    existing?.providers.find((provider) => provider.kind === "codex") ?? null;
  const currentBin = current?.kind === "codex" ? current.bin : null;
  if (!shouldPromptForCodexCommand(currentBin, options)) {
    return { kind: "codex", bin: "codex" };
  }
  const bin = await promptText({
    message: "Codex command",
    defaultValue: currentBin ?? "codex",
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

async function promptOpenCodeProvider(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
  stateDir: string,
  options: {
    advanced: boolean;
  },
): Promise<AgentProviderConfig> {
  const current =
    existing?.providers.find((provider) => provider.kind === "opencode") ??
    null;
  const bin = await promptText({
    message: "OpenCode command",
    defaultValue: current?.kind === "opencode" ? current.bin : "opencode",
    validate: (value) =>
      value.trim() ? undefined : "OpenCode command cannot be empty.",
  });
  if (!options.advanced && current?.kind !== "opencode") {
    return {
      kind: "opencode",
      bin: bin.trim(),
      stateDir: null,
    };
  }
  const opencodeStateDir = await promptText({
    message: "OpenCode state directory (leave blank to use default OpenCode paths)",
    defaultValue:
      current?.kind === "opencode"
        ? (current.stateDir ?? "")
        : nodePath.join(stateDir, "opencode-provider"),
    fallbackToDefaultOnEmpty: false,
  });
  return {
    kind: "opencode",
    bin: bin.trim(),
    stateDir: opencodeStateDir.trim() || null,
  };
}

async function promptAcpxProvider(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
  stateDir: string,
): Promise<AgentProviderConfig> {
  const current =
    existing?.providers.find((provider) => provider.kind === "acpx") ?? null;
  note(
    "acpx bridges Sidemesh to ACP-compatible agents. Reads/searches may be auto-approved; writes and commands still go through Sidemesh approvals.",
    "ACP via acpx",
  );
  const agentOptions = [
    { value: "gemini", label: "Gemini CLI", hint: "gemini --acp" },
    { value: "claude", label: "Claude Code", hint: "claude-agent-acp" },
    { value: "qwen", label: "Qwen Code", hint: "qwen --acp" },
    { value: "cursor", label: "Cursor Agent", hint: "cursor-agent acp" },
    { value: "kimi", label: "Kimi", hint: "kimi acp" },
    { value: "copilot", label: "GitHub Copilot", hint: "copilot --acp --stdio" },
    { value: "opencode", label: "OpenCode", hint: "opencode-ai acp" },
    { value: "custom", label: "Custom ACP command" },
  ];
  const currentAgent = current?.kind === "acpx" ? current.agent : "gemini";
  const agent = await select<string>({
    message: "ACP agent",
    initialValue: agentOptions.some((option) => option.value === currentAgent)
      ? currentAgent
      : "custom",
    options: agentOptions,
  });
  if (isCancel(agent)) {
    throw new Error("Setup cancelled.");
  }
  let resolvedAgent = agent;
  if (agent === "custom") {
    resolvedAgent = await promptText({
      message: "Custom agent id",
      defaultValue: current?.kind === "acpx" ? current.agent : "custom",
      validate: (value) =>
        value.trim() ? undefined : "ACP agent id cannot be empty.",
    });
  }
  const command = await promptText({
    message: "ACP command override (leave blank for acpx built-in registry)",
    defaultValue: current?.kind === "acpx" ? (current.command ?? "") : "",
    fallbackToDefaultOnEmpty: false,
  });
  const acpxStateDir = await promptText({
    message: "acpx state directory",
    defaultValue:
      current?.kind === "acpx"
        ? (current.stateDir ?? nodePath.join(stateDir, "acpx-provider", resolvedAgent))
        : nodePath.join(stateDir, "acpx-provider", resolvedAgent),
    validate: (value) =>
      value.trim() ? undefined : "acpx state directory cannot be empty.",
  });
  const permissionMode = await select<"approve-reads" | "deny-all">({
    message: "acpx permission mode",
    initialValue:
      current?.kind === "acpx" ? current.permissionMode : "approve-reads",
    options: [
      {
        value: "approve-reads",
        label: "Approve reads/searches only",
        hint: "Writes and commands ask Sidemesh for approval",
      },
      {
        value: "deny-all",
        label: "Deny all ACP permission requests",
        hint: "Safest, but many agents will be limited",
      },
    ],
  });
  if (isCancel(permissionMode)) {
    throw new Error("Setup cancelled.");
  }
  return {
    kind: "acpx",
    agent: resolvedAgent.trim(),
    command: command.trim() || null,
    stateDir: acpxStateDir.trim() || null,
    permissionMode,
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

export function shouldPromptForCodexCommand(
  currentBin: string | null,
  options: {
    advanced: boolean;
  },
): boolean {
  if (options.advanced) {
    return true;
  }
  if (!currentBin) {
    return false;
  }
  return currentBin.trim() !== "codex";
}

export function shouldPromptForUpdateChannel(
  existing: Awaited<ReturnType<typeof readResolvedPersistedConfig>>["value"],
  options: SetupOptions,
): boolean {
  if (options.advanced === true) {
    return true;
  }
  return existing != null;
}
