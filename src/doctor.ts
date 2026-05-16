import { execFile } from "node:child_process";
import { access, mkdir, readFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { homedir } from "node:os";
import nodePath from "node:path";
import { promisify } from "node:util";

import { VERSION as PI_VERSION } from "@mariozechner/pi-coding-agent";
import { createAgentRegistry } from "acpx/runtime";

import { createCopilotSdkClient } from "./copilot-sdk-client.js";
import type {
  AgentProviderConfig,
  AcpxProviderConfig,
  CopilotProviderConfig,
  FakeProviderConfig,
  NodeConfig,
  OpenCodeProviderConfig,
  PiProviderConfig,
} from "./types.js";

const execFileAsync = promisify(execFile);
type DoctorEnvironment = Record<string, string | undefined>;

export interface DoctorRuntimeOptions {
  env?: DoctorEnvironment;
  cwd?: string;
}

export interface DoctorCheck {
  severity: "ok" | "warn" | "error";
  label: string;
  detail: string;
  remedy?: string;
}

export interface DoctorProviderReport {
  kind: string;
  displayName: string;
  command: string | null;
  resolvedCommandPath: string | null;
  version: string | null;
  auth:
    | {
        status: "authenticated" | "unauthenticated" | "unknown";
        source?: string | null;
        login?: string | null;
        host?: string | null;
        message?: string | null;
      }
    | null;
  checks: DoctorCheck[];
}

export interface DoctorReport {
  configPath: string;
  configExists: boolean;
  healthUrl: string;
  daemonReachable: boolean;
  checks: DoctorCheck[];
  providers: DoctorProviderReport[];
}

export async function runDoctor(
  config: NodeConfig,
  options: DoctorRuntimeOptions = {},
): Promise<DoctorReport> {
  const checks: DoctorCheck[] = [];
  const providers: DoctorProviderReport[] = [];
  const healthUrl = `http://127.0.0.1:${config.port}/healthz`;
  const daemonReachable = await checkHealth(healthUrl);

  checks.push({
    severity: config.configExists ? "ok" : "warn",
    label: "config",
    detail: config.configExists
      ? `Using ${config.configPath}`
      : `No config file found at ${config.configPath}`,
    remedy: config.configExists
      ? undefined
      : "Run `sidemesh up` or `sidemesh setup` to persist the current configuration.",
  });

  checks.push({
    severity: daemonReachable ? "ok" : "warn",
    label: "daemon",
    detail: daemonReachable
      ? `Daemon responded at ${healthUrl}`
      : `No daemon responded at ${healthUrl}`,
    remedy: daemonReachable
      ? undefined
      : "Start it with `sidemesh up` or `sidemesh start`, or install the macOS/Linux service if you want the app's Restart and Update buttons to bring it back on their own.",
  });

  checks.push(await checkStateDir(config.stateDir));
  if (config.tokenSource === "generated") {
    checks.push({
      severity: "warn",
      label: "token",
      detail: "Token is generated from defaults, not loaded from config or env.",
      remedy:
        "Run `sidemesh up`, `sidemesh setup`, or `sidemesh token rotate` so the token persists across restarts.",
    });
  } else {
    checks.push({
      severity: "ok",
      label: "token",
      detail: `Token source: ${config.tokenSource}`,
    });
  }

  for (const provider of config.providers) {
    providers.push(
      await inspectProviderConfig(provider, config.stateDir, options),
    );
  }

  return { configPath: config.configPath, configExists: config.configExists, healthUrl, daemonReachable, checks, providers };
}

export async function inspectProviderConfig(
  provider: AgentProviderConfig,
  stateDir: string,
  options: DoctorRuntimeOptions = {},
): Promise<DoctorProviderReport> {
  const context = createDoctorRuntimeContext(options);
  switch (provider.kind) {
    case "codex":
      return inspectCodexProvider(provider, context);
    case "pi":
      return inspectPiProvider(provider, context);
    case "fake":
      return inspectFakeProvider(provider, stateDir);
    case "copilot":
      return inspectCopilotProvider(provider, context);
    case "opencode":
      return inspectOpenCodeProvider(provider, context);
    case "acpx":
      return inspectAcpxProvider(provider, context);
  }
}

async function inspectCommandProvider(
  kind: string,
  displayName: string,
  command: string,
  args: string[],
  context: ResolvedDoctorRuntimeContext,
): Promise<DoctorProviderReport> {
  const resolvedCommandPath = await resolveCommandPath(command, context);
  const checks: DoctorCheck[] = [];
  let version: string | null = null;
  if (!resolvedCommandPath) {
    checks.push({
      severity: "error",
      label: "binary",
      detail: `Command not found: ${command}`,
      remedy: `Install ${displayName} or configure the correct binary path.`,
    });
  } else {
    checks.push({
      severity: "ok",
      label: "binary",
      detail: `Resolved ${command} to ${resolvedCommandPath}`,
    });
    try {
      const { stdout } = await execFileAsync(resolvedCommandPath, args, {
        encoding: "utf8",
      });
      version = stdout.trim() || null;
      checks.push({
        severity: version ? "ok" : "warn",
        label: "version",
        detail: version || `${displayName} returned an empty version string.`,
      });
    } catch (error) {
      checks.push({
        severity: "error",
        label: "version",
        detail: formatError(error),
        remedy: `Run \`${command} ${args.join(" ")}\` manually to confirm it works.`,
      });
    }
  }
  return {
    kind,
    displayName,
    command,
    resolvedCommandPath,
    version,
    auth: null,
    checks,
  };
}

async function inspectCodexProvider(
  provider: { bin: string },
  context: ResolvedDoctorRuntimeContext,
): Promise<DoctorProviderReport> {
  const base = await inspectCommandProvider(
    "codex",
    "Codex",
    provider.bin,
    ["--version"],
    context,
  );
  const checks = [...base.checks];
  let auth: DoctorProviderReport["auth"] = null;

  if (base.resolvedCommandPath) {
    const homeDir = context.homeDir;
    const authPath = homeDir
      ? nodePath.join(homeDir, ".codex", "auth.json")
      : null;
    if (!authPath) {
      auth = {
        status: "unknown",
        source: null,
        login: null,
        host: null,
        message: "No home directory available for auth inspection",
      };
      checks.push({
        severity: "warn",
        label: "auth",
        detail: "No home directory available for auth inspection",
      });
      return {
        ...base,
        checks,
        auth,
      };
    }
    try {
      const raw = await readFile(authPath, "utf8");
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const tokens = parsed.tokens as Record<string, unknown> | undefined;
      const hasAccessToken = typeof tokens?.access_token === "string";
      const hasRefreshToken = typeof tokens?.refresh_token === "string";
      if (hasAccessToken && hasRefreshToken) {
        auth = {
          status: "authenticated",
          source: (parsed.auth_mode as string) || null,
          login: (tokens?.email as string) || null,
          host: null,
          message: "Auth file present with tokens",
        };
        checks.push({
          severity: "ok",
          label: "auth",
          detail: "Auth file present with tokens",
        });
      } else {
        auth = {
          status: "unauthenticated",
          source: null,
          login: null,
          host: null,
          message: "Auth file missing tokens",
        };
        checks.push({
          severity: "error",
          label: "auth",
          detail: "Auth file missing tokens",
          remedy: "Run `codex auth login` to authenticate.",
        });
      }
    } catch (error) {
      const isMissing =
        error instanceof Error &&
        (error as NodeJS.ErrnoException).code === "ENOENT";
      auth = {
        status: "unauthenticated",
        source: null,
        login: null,
        host: null,
        message: isMissing ? "No auth file found" : "Auth file unreadable",
      };
      checks.push({
        severity: "error",
        label: "auth",
        detail: isMissing
          ? "No auth file found"
          : `Auth file unreadable: ${formatError(error)}`,
        remedy: isMissing
          ? "Run `codex auth login` to authenticate."
          : "Check permissions on ~/.codex/auth.json.",
      });
    }
  }

  return {
    ...base,
    checks,
    auth,
  };
}

async function inspectFakeProvider(
  provider: FakeProviderConfig,
  stateDir: string,
): Promise<DoctorProviderReport> {
  const checks: DoctorCheck[] = [
    {
      severity: "ok",
      label: "provider",
      detail: `Fake profile: ${provider.capabilityProfile}`,
    },
    {
      severity: "ok",
      label: "state",
      detail: `Using Sidemesh state dir ${stateDir}`,
    },
  ];
  return {
    kind: "fake",
    displayName: "Fake Test Provider",
    command: "builtin",
    resolvedCommandPath: "builtin",
    version: "builtin",
    auth: null,
    checks,
  };
}

async function inspectPiProvider(
  provider: PiProviderConfig,
  context: ResolvedDoctorRuntimeContext,
): Promise<DoctorProviderReport> {
  const fallbackHomeDir = context.homeDir;
  const agentDir = nodePath.resolve(
    provider.agentDir ||
      (fallbackHomeDir ? nodePath.join(fallbackHomeDir, ".pi", "agent") : ".pi-missing-home"),
  );
  const providerStateDir = nodePath.resolve(
    provider.stateDir ||
      (fallbackHomeDir
        ? nodePath.join(fallbackHomeDir, ".sidemesh", "pi-provider")
        : ".sidemesh-pi-missing-home"),
  );
  const sessionsDir = nodePath.join(agentDir, "sessions");
  const agentDirExists = fallbackHomeDir || provider.agentDir
    ? await pathExists(agentDir)
    : false;
  const sessionsDirExists = fallbackHomeDir || provider.agentDir
    ? await pathExists(sessionsDir)
    : false;
  const providerStateDirExists = fallbackHomeDir || provider.stateDir
    ? await pathExists(providerStateDir)
    : false;
  const checks: DoctorCheck[] = [
    {
      severity: "ok",
      label: "sdk",
      detail: `Using Pi SDK ${PI_VERSION}`,
    },
    {
      severity: agentDirExists ? "ok" : "warn",
      label: "agentDir",
      detail: `Pi agent dir: ${agentDir}`,
      remedy: agentDirExists
        ? undefined
        : fallbackHomeDir || provider.agentDir
          ? "Create the Pi agent directory by running Pi once or configuring SIDEMESH_PI_AGENT_DIR."
          : "Set HOME or SIDEMESH_PI_AGENT_DIR so Sidemesh can inspect Pi readiness.",
    },
    {
      severity: sessionsDirExists ? "ok" : "warn",
      label: "sessions",
      detail: `Pi sessions dir: ${sessionsDir}`,
      remedy: sessionsDirExists
        ? undefined
        : "Pi will create the sessions directory after the first persisted session.",
    },
    {
      severity: providerStateDirExists ? "ok" : "warn",
      label: "state",
      detail: `Sidemesh Pi state dir: ${providerStateDir}`,
      remedy: providerStateDirExists
        ? undefined
        : "The state directory will be created automatically on first use.",
    },
  ];
  return {
    kind: "pi",
    displayName: "Pi",
    command: null,
    resolvedCommandPath: null,
    version: `Pi ${PI_VERSION}`,
    auth: null,
    checks,
  };
}

async function inspectCopilotProvider(
  provider: CopilotProviderConfig,
  context: ResolvedDoctorRuntimeContext,
): Promise<DoctorProviderReport> {
  const resolvedCommandPath = await resolveCommandPath(provider.bin, context);
  const checks: DoctorCheck[] = [];
  let version: string | null = null;
  let auth: DoctorProviderReport["auth"] = null;

  if (!resolvedCommandPath) {
    checks.push({
      severity: "error",
      label: "binary",
      detail: `Command not found: ${provider.bin}`,
      remedy: "Install GitHub Copilot CLI or configure SIDEMESH_COPILOT_BIN.",
    });
    return {
      kind: "copilot",
      displayName: "GitHub Copilot",
      command: provider.bin,
      resolvedCommandPath,
      version,
      auth,
      checks,
    };
  }

  checks.push({
    severity: "ok",
    label: "binary",
    detail: `Resolved ${provider.bin} to ${resolvedCommandPath}`,
  });

  const client = await createCopilotSdkClient({
    bin: provider.bin,
    cwd: context.cwd,
    env: context.env,
  });
  try {
    await client.start();
    const status = await client.getStatus?.();
    version = status?.version ? `GitHub Copilot SDK ${status.version}` : null;
    checks.push({
      severity: version ? "ok" : "warn",
      label: "version",
      detail: version || "Copilot SDK did not report a version.",
    });
    const authStatus = await client.getAuthStatus?.();
    if (authStatus?.isAuthenticated) {
      auth = {
        status: "authenticated",
        source: authStatus.authType ?? null,
        login: authStatus.login ?? null,
        host: authStatus.host ?? null,
        message: authStatus.statusMessage ?? null,
      };
      checks.push({
        severity: "ok",
        label: "auth",
        detail: buildCopilotAuthDetail(authStatus),
      });
    } else if (authStatus) {
      auth = {
        status: "unauthenticated",
        source: authStatus.authType ?? null,
        login: authStatus.login ?? null,
        host: authStatus.host ?? null,
        message: authStatus.statusMessage ?? null,
      };
      checks.push({
        severity: "error",
        label: "auth",
        detail: buildCopilotAuthDetail(authStatus),
        remedy: "Run the Copilot CLI login flow on this machine, then rerun `sidemesh doctor`.",
      });
    } else {
      auth = { status: "unknown" };
      checks.push({
        severity: "warn",
        label: "auth",
        detail: "Copilot SDK did not expose auth status.",
      });
    }
  } catch (error) {
    checks.push({
      severity: "error",
      label: "sdk",
      detail: formatError(error),
      remedy: "Check Copilot CLI install/auth, then rerun `sidemesh doctor`.",
    });
  } finally {
    await client.stop?.().catch(() => {});
  }

  return {
    kind: "copilot",
    displayName: "GitHub Copilot",
    command: provider.bin,
    resolvedCommandPath,
    version,
    auth,
    checks,
  };
}

async function inspectOpenCodeProvider(
  provider: OpenCodeProviderConfig,
  context: ResolvedDoctorRuntimeContext,
): Promise<DoctorProviderReport> {
  const base = await inspectCommandProvider(
    "opencode",
    "OpenCode",
    provider.bin,
    ["--version"],
    context,
  );
  const checks = [...base.checks];
  if (provider.stateDir) {
    checks.push({
      severity: "ok",
      label: "state",
      detail: `Isolated OpenCode state dir: ${provider.stateDir}`,
    });
  } else {
    checks.push({
      severity: "warn",
      label: "state",
      detail: "Using the operator's default OpenCode XDG state/config paths.",
      remedy:
        "Set SIDEMESH_OPENCODE_STATE_DIR if you want Sidemesh to isolate the OpenCode server state.",
    });
  }
  return {
    ...base,
    checks,
    auth: { status: "unknown", message: "OpenCode auth readiness is not inspected yet." },
  };
}

async function inspectAcpxProvider(
  provider: AcpxProviderConfig,
  context: ResolvedDoctorRuntimeContext,
): Promise<DoctorProviderReport> {
  const registry = createAgentRegistry({
    overrides: provider.command ? { [provider.agent]: provider.command } : undefined,
  });
  const commandLine = registry.resolve(provider.agent);
  const commandHead = commandLine.split(/\s+/, 1)[0] ?? commandLine;
  const resolvedCommandPath = commandHead
    ? await resolveCommandPath(commandHead, context)
    : null;
  const stateDir = provider.stateDir || "~/.sidemesh/acpx-provider/<agent>";
  const checks: DoctorCheck[] = [
    {
      severity: "ok",
      label: "sdk",
      detail: `Using embedded acpx runtime`,
    },
    {
      severity: "ok",
      label: "agent",
      detail: `ACP agent: ${provider.agent} (${commandLine})`,
    },
    {
      severity: provider.permissionMode === "approve-reads" ? "ok" : "warn",
      label: "permissions",
      detail:
        provider.permissionMode === "approve-reads"
          ? "Read/search ACP permissions auto-approve; writes and commands require Sidemesh approval."
          : "All ACP permission requests are denied by default.",
    },
    {
      severity: provider.stateDir ? "ok" : "warn",
      label: "state",
      detail: `ACP session state dir: ${stateDir}`,
      remedy: provider.stateDir
        ? undefined
        : "Set SIDEMESH_ACPX_STATE_DIR or rerun setup if you want an explicit persisted acpx state path.",
    },
  ];
  if (provider.command) {
    checks.push({
      severity: resolvedCommandPath ? "ok" : "warn",
      label: "command",
      detail: resolvedCommandPath
        ? `Resolved ${commandHead} to ${resolvedCommandPath}`
        : `Could not resolve command head: ${commandHead}`,
      remedy: resolvedCommandPath
        ? undefined
        : "Install the configured ACP agent command or update SIDEMESH_ACPX_COMMAND.",
    });
  } else {
    checks.push({
      severity: "warn",
      label: "command",
      detail:
        "Agent command is managed by acpx's built-in registry and is not probed during doctor.",
      remedy:
        "Run the agent's own login/install flow if the first acpx session fails to start.",
    });
  }
  return {
    kind: "acpx",
    displayName: "ACP via acpx",
    command: commandLine,
    resolvedCommandPath,
    version: "acpx runtime",
    auth: {
      status: "unknown",
      message: "ACP agent authentication is provider-specific and is not inspected yet.",
    },
    checks,
  };
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function checkStateDir(stateDir: string): Promise<DoctorCheck> {
  try {
    await mkdir(stateDir, { recursive: true });
    await access(stateDir, fsConstants.R_OK | fsConstants.W_OK);
    return {
      severity: "ok",
      label: "state dir",
      detail: `Writable: ${stateDir}`,
    };
  } catch (error) {
    return {
      severity: "error",
      label: "state dir",
      detail: formatError(error),
      remedy: "Choose a writable SIDEMESH_STATE_DIR or fix filesystem permissions.",
    };
  }
}

async function resolveCommandPath(
  command: string,
  context: ResolvedDoctorRuntimeContext,
): Promise<string | null> {
  const trimmed = command.trim();
  if (!trimmed) {
    return null;
  }
  if (trimmed.includes(nodePath.sep)) {
    const absolute = nodePath.resolve(trimmed);
    try {
      await access(absolute, fsConstants.X_OK);
      return absolute;
    } catch {
      return null;
    }
  }
  const pathValue = context.pathValue;
  for (const dir of pathValue.split(nodePath.delimiter)) {
    if (!dir) {
      continue;
    }
    const candidate = nodePath.join(dir, trimmed);
    try {
      await access(candidate, fsConstants.X_OK);
      return candidate;
    } catch {}
  }
  return null;
}

interface ResolvedDoctorRuntimeContext {
  env: DoctorEnvironment;
  cwd: string;
  homeDir: string | null;
  pathValue: string;
}

function createDoctorRuntimeContext(
  options: DoctorRuntimeOptions,
): ResolvedDoctorRuntimeContext {
  const explicitEnv = options.env ?? null;
  const env = explicitEnv ?? process.env;
  const homeDir =
    env.HOME?.trim() ||
    env.USERPROFILE?.trim() ||
    (env.HOMEDRIVE && env.HOMEPATH
      ? `${env.HOMEDRIVE}${env.HOMEPATH}`
      : null) ||
    (explicitEnv ? null : homedir());
  const pathValue =
    env.PATH ??
    env.Path ??
    (explicitEnv ? "" : process.env.PATH ?? "");
  return {
    env,
    cwd: options.cwd ?? process.cwd(),
    homeDir,
    pathValue,
  };
}

async function checkHealth(url: string): Promise<boolean> {
  try {
    const response = await fetch(url);
    return response.ok;
  } catch {
    return false;
  }
}

function buildCopilotAuthDetail(authStatus: {
  isAuthenticated: boolean;
  authType?: string;
  login?: string;
  host?: string;
  statusMessage?: string;
}): string {
  const fragments = [
    authStatus.isAuthenticated ? "Authenticated" : "Not authenticated",
  ];
  if (authStatus.login) {
    fragments.push(`as ${authStatus.login}`);
  }
  if (authStatus.authType) {
    fragments.push(`via ${authStatus.authType}`);
  }
  if (authStatus.host) {
    fragments.push(`on ${authStatus.host}`);
  }
  if (authStatus.statusMessage) {
    fragments.push(`(${authStatus.statusMessage})`);
  }
  return fragments.join(" ");
}

function formatError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}
