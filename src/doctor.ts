import { execFile } from "node:child_process";
import { access, mkdir, readFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { homedir } from "node:os";
import nodePath from "node:path";
import { promisify } from "node:util";

import { VERSION as PI_VERSION } from "@mariozechner/pi-coding-agent";

import { createCopilotSdkClient } from "./copilot-sdk-client.js";
import type {
  AgentProviderConfig,
  CopilotProviderConfig,
  FakeProviderConfig,
  NodeConfig,
  PiProviderConfig,
} from "./types.js";

const execFileAsync = promisify(execFile);

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

export async function runDoctor(config: NodeConfig): Promise<DoctorReport> {
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
    providers.push(await inspectProvider(provider, config.stateDir));
  }

  return { configPath: config.configPath, configExists: config.configExists, healthUrl, daemonReachable, checks, providers };
}

async function inspectProvider(
  provider: AgentProviderConfig,
  stateDir: string,
): Promise<DoctorProviderReport> {
  switch (provider.kind) {
    case "codex":
      return inspectCodexProvider(provider);
    case "pi":
      return inspectPiProvider(provider);
    case "fake":
      return inspectFakeProvider(provider, stateDir);
    case "copilot":
      return inspectCopilotProvider(provider);
  }
}

async function inspectCommandProvider(
  kind: string,
  displayName: string,
  command: string,
  args: string[],
): Promise<DoctorProviderReport> {
  const resolvedCommandPath = await resolveCommandPath(command);
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
      const { stdout } = await execFileAsync(command, args, { encoding: "utf8" });
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
): Promise<DoctorProviderReport> {
  const base = await inspectCommandProvider("codex", "Codex", provider.bin, ["--version"]);
  const checks = [...base.checks];
  let auth: DoctorProviderReport["auth"] = null;

  if (base.resolvedCommandPath) {
    const authPath = nodePath.join(homedir(), ".codex", "auth.json");
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
): Promise<DoctorProviderReport> {
  const agentDir = nodePath.resolve(
    provider.agentDir || nodePath.join(homedir(), ".pi", "agent"),
  );
  const providerStateDir = nodePath.resolve(
    provider.stateDir || nodePath.join(homedir(), ".sidemesh", "pi-provider"),
  );
  const sessionsDir = nodePath.join(agentDir, "sessions");
  const checks: DoctorCheck[] = [
    {
      severity: "ok",
      label: "sdk",
      detail: `Using Pi SDK ${PI_VERSION}`,
    },
    {
      severity: (await pathExists(agentDir)) ? "ok" : "warn",
      label: "agentDir",
      detail: `Pi agent dir: ${agentDir}`,
      remedy: (await pathExists(agentDir))
        ? undefined
        : "Create the Pi agent directory by running Pi once or configuring SIDEMESH_PI_AGENT_DIR.",
    },
    {
      severity: (await pathExists(sessionsDir)) ? "ok" : "warn",
      label: "sessions",
      detail: `Pi sessions dir: ${sessionsDir}`,
      remedy: (await pathExists(sessionsDir))
        ? undefined
        : "Pi will create the sessions directory after the first persisted session.",
    },
    {
      severity: (await pathExists(providerStateDir)) ? "ok" : "warn",
      label: "state",
      detail: `Sidemesh Pi state dir: ${providerStateDir}`,
      remedy: (await pathExists(providerStateDir))
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
): Promise<DoctorProviderReport> {
  const resolvedCommandPath = await resolveCommandPath(provider.bin);
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
    cwd: process.cwd(),
    env: process.env,
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

async function resolveCommandPath(command: string): Promise<string | null> {
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
  const pathValue = process.env.PATH ?? "";
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
