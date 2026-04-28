import { execFile } from "node:child_process";
import { access, mkdir } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import nodePath from "node:path";
import { promisify } from "node:util";

import { createCopilotSdkClient } from "./copilot-sdk-client.js";
import type {
  AgentProviderConfig,
  CopilotProviderConfig,
  FakeProviderConfig,
  NodeConfig,
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
      : "Run `sidemesh setup` to persist the current configuration.",
  });

  checks.push({
    severity: daemonReachable ? "ok" : "warn",
    label: "daemon",
    detail: daemonReachable
      ? `Daemon responded at ${healthUrl}`
      : `No daemon responded at ${healthUrl}`,
    remedy: daemonReachable
      ? undefined
      : "Start it with `sidemesh daemon` after setup completes.",
  });

  checks.push(await checkStateDir(config.stateDir));
  if (config.tokenSource === "generated") {
    checks.push({
      severity: "warn",
      label: "token",
      detail: "Token is generated from defaults, not loaded from config or env.",
      remedy:
        "Run `sidemesh setup` or `sidemesh token rotate` so the token persists across restarts.",
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
      return inspectCommandProvider("codex", "Codex", provider.bin, ["--version"]);
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
