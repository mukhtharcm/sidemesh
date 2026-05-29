import { execFile } from "node:child_process";
import {
  access,
  chmod,
  lstat,
  mkdir,
  readFile,
  readlink,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";

import {
  isTermuxEnvironment,
  isTermuxRuntimePlatform,
  resolveTermuxPrefix,
  supportsTermuxServiceManagement,
} from "./host-environment.js";
import {
  DEFAULT_SERVICE_NAME,
  renderServiceEnv,
} from "./systemd-service.js";
import type { NodeConfig } from "./types.js";

const execFileAsync = promisify(execFile);

const SERVICE_DAEMON_NAME = "service-daemon";
const SERVICE_DAEMON_START_TIMEOUT_MS = 3_000;
const SERVICE_SUPERVISE_TIMEOUT_MS = 3_000;

export const DEFAULT_TERMUX_SERVICE_NAME = DEFAULT_SERVICE_NAME;

export interface TermuxServicePaths {
  prefix: string;
  serviceName: string;
  packageDir: string;
  nodeBin: string;
  serviceDir: string;
  envPath: string;
  launcherPath: string;
  logRunPath: string;
  logDir: string;
  downPath: string;
  svloggerPath: string;
  pidPath: string;
}

export interface InstallTermuxServiceOptions {
  serviceName?: string | null;
  packageDir: string;
  nodeBin: string;
  serviceDir?: string | null;
  envPath?: string | null;
  launcherPath?: string | null;
  start: boolean;
  enabled?: boolean | null;
}

export interface UninstallTermuxServiceOptions {
  serviceName?: string | null;
  serviceDir?: string | null;
  envPath?: string | null;
  launcherPath?: string | null;
  removeFiles: boolean;
}

export function resolveTermuxServicePaths(options: {
  serviceName?: string | null;
  packageDir: string;
  nodeBin: string;
  serviceDir?: string | null;
  envPath?: string | null;
  launcherPath?: string | null;
  prefix?: string | null;
}): TermuxServicePaths {
  const prefix = options.prefix?.trim() || resolveTermuxPrefix();
  const serviceName = normalizeTermuxServiceName(options.serviceName);
  const inferredServiceDir =
    options.serviceDir?.trim() ||
    dirname(
      options.launcherPath?.trim() ||
        options.envPath?.trim() ||
        join(prefix, "var", "service", serviceName, "run"),
    );
  return {
    prefix,
    serviceName,
    packageDir: options.packageDir,
    nodeBin: options.nodeBin,
    serviceDir: inferredServiceDir,
    envPath: options.envPath?.trim() || join(inferredServiceDir, "env"),
    launcherPath:
      options.launcherPath?.trim() || join(inferredServiceDir, "run"),
    logRunPath: join(inferredServiceDir, "log", "run"),
    logDir: join(prefix, "var", "log", "sv", serviceName),
    downPath: join(inferredServiceDir, "down"),
    svloggerPath: join(prefix, "share", "termux-services", "svlogger"),
    pidPath: join(prefix, "var", "run", `${SERVICE_DAEMON_NAME}.pid`),
  };
}

export function renderTermuxServiceLauncher(
  paths: TermuxServicePaths,
  config: Pick<NodeConfig, "configPath">,
): string {
  const shellPath = join(paths.prefix, "bin", "sh");
  const termuxHome = join(dirname(paths.prefix), "home");
  return `#!${shellPath}
set -eu
if [ -z "\${PREFIX:-}" ]; then export PREFIX=${shellQuote(paths.prefix)}; fi
if [ -z "\${HOME:-}" ]; then export HOME=${shellQuote(termuxHome)}; fi
if [ -z "\${USER:-}" ]; then export USER="$(id -un)"; fi
if [ -z "\${LOGNAME:-}" ]; then export LOGNAME="\${USER}"; fi
if [ -z "\${SHELL:-}" ]; then export SHELL=${shellQuote(shellPath)}; fi
set -a
. ${shellQuote(paths.envPath)}
set +a
export PATH=${shellQuote(dirname(paths.nodeBin))}:$PATH
cd ${shellQuote(paths.packageDir)}
exec ${shellQuote(paths.nodeBin)} ${shellQuote(join(paths.packageDir, "dist", "cli.js"))} daemon --config ${shellQuote(config.configPath)} 2>&1
`;
}

export async function installTermuxService(
  config: NodeConfig,
  options: InstallTermuxServiceOptions,
): Promise<TermuxServicePaths> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths(options);
  await assertCompiledCli(paths.packageDir);

  const existingEnabled =
    (await pathExists(paths.launcherPath)) && !(await pathExists(paths.downPath));
  const desiredEnabled =
    options.start === true
      ? true
      : options.enabled ?? existingEnabled;

  await mkdir(paths.serviceDir, { recursive: true, mode: 0o700 });
  await mkdir(dirname(paths.logRunPath), { recursive: true, mode: 0o700 });
  await mkdir(paths.logDir, { recursive: true, mode: 0o700 });
  await writeFile(paths.envPath, renderServiceEnv(config), { mode: 0o600 });
  await writeFile(
    paths.launcherPath,
    renderTermuxServiceLauncher(paths, config),
    { mode: 0o700 },
  );
  await chmod(paths.launcherPath, 0o700);
  await ensureSvloggerLink(paths);

  if (desiredEnabled) {
    await rm(paths.downPath, { force: true });
  } else {
    await writeFile(paths.downPath, "", { mode: 0o600 });
  }

  if (options.start) {
    await ensureTermuxServiceReady(paths);
    await sv(paths, ["up", paths.serviceName]);
  }

  return paths;
}

export async function startTermuxService(
  serviceName?: string | null,
): Promise<void> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths({
    serviceName,
    packageDir: "",
    nodeBin: process.execPath,
  });
  await assertTermuxServiceInstalled(paths);
  await rm(paths.downPath, { force: true });
  await ensureTermuxServiceReady(paths);
  await sv(paths, ["up", paths.serviceName]);
}

export async function stopTermuxService(
  serviceName?: string | null,
): Promise<void> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths({
    serviceName,
    packageDir: "",
    nodeBin: process.execPath,
  });
  if (!(await isTermuxServiceInstalled(paths.serviceName))) {
    return;
  }
  if (!(await isTermuxServiceDaemonRunning(paths))) {
    return;
  }
  await waitForServiceSupervise(paths).catch(() => undefined);
  await sv(paths, ["down", paths.serviceName]).catch(() => undefined);
}

export async function restartTermuxService(
  serviceName?: string | null,
): Promise<void> {
  assertTermuxServicesHost();
  await stopTermuxService(serviceName);
  await startTermuxService(serviceName);
}

export async function uninstallTermuxService(
  options: UninstallTermuxServiceOptions,
): Promise<TermuxServicePaths> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths({
    serviceName: options.serviceName,
    packageDir: "",
    nodeBin: process.execPath,
    serviceDir: options.serviceDir,
    envPath: options.envPath,
    launcherPath: options.launcherPath,
  });

  if (await pathExists(paths.launcherPath)) {
    await writeFile(paths.downPath, "", { mode: 0o600 }).catch(() => undefined);
    await stopTermuxService(paths.serviceName);
  }
  if (options.removeFiles) {
    await rm(paths.serviceDir, { recursive: true, force: true });
  }
  return paths;
}

export async function termuxServiceStatus(
  serviceName?: string | null,
): Promise<string> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths({
    serviceName,
    packageDir: "",
    nodeBin: process.execPath,
  });
  if (!(await isTermuxServiceInstalled(paths.serviceName))) {
    return `${paths.serviceName} is not installed.\n`;
  }
  if (!(await isTermuxServiceDaemonRunning(paths))) {
    const enabled = await isTermuxServiceEnabled(paths.serviceName);
    const state = enabled ? "enabled" : "disabled";
    return `${paths.serviceName} is ${state}, but ${SERVICE_DAEMON_NAME} is not running.\n`;
  }
  await waitForServiceSupervise(paths).catch(() => undefined);
  try {
    const { stdout, stderr } = await execFileAsync(
      "sv",
      ["status", paths.serviceName],
      {
        env: termuxServiceEnv(paths),
        encoding: "utf8",
        timeout: 10_000,
      },
    );
    return `${stdout}${stderr}`;
  } catch (error) {
    const typed = error as NodeJS.ErrnoException & {
      stdout?: string;
      stderr?: string;
    };
    const output = `${typed.stdout ?? ""}${typed.stderr ?? ""}`;
    if (output) return output;
    throw error;
  }
}

export async function isTermuxServiceInstalled(
  serviceName?: string | null,
): Promise<boolean> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths({
    serviceName,
    packageDir: "",
    nodeBin: process.execPath,
  });
  return pathExists(paths.launcherPath);
}

export async function isTermuxServiceEnabled(
  serviceName?: string | null,
): Promise<boolean> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths({
    serviceName,
    packageDir: "",
    nodeBin: process.execPath,
  });
  return (
    (await pathExists(paths.launcherPath)) &&
    !(await pathExists(paths.downPath))
  );
}

export async function isTermuxServiceActive(
  serviceName?: string | null,
): Promise<boolean> {
  assertTermuxServicesHost();
  const paths = resolveTermuxServicePaths({
    serviceName,
    packageDir: "",
    nodeBin: process.execPath,
  });
  if (!(await pathExists(paths.launcherPath))) {
    return false;
  }
  if (!(await isTermuxServiceDaemonRunning(paths))) {
    return false;
  }
  await waitForServiceSupervise(paths).catch(() => undefined);
  try {
    const { stdout, stderr } = await execFileAsync(
      "sv",
      ["status", paths.serviceName],
      {
        env: termuxServiceEnv(paths),
        encoding: "utf8",
        timeout: 10_000,
      },
    );
    return parseTermuxServiceRunning(`${stdout}${stderr}`);
  } catch (error) {
    const typed = error as NodeJS.ErrnoException & {
      stdout?: string;
      stderr?: string;
    };
    return parseTermuxServiceRunning(
      `${typed.stdout ?? ""}${typed.stderr ?? ""}`,
    );
  }
}

export async function resolveInstalledTermuxServicePaths(options: {
  serviceName?: string | null;
  packageDir: string;
  nodeBin: string;
  serviceDir?: string | null;
  envPath?: string | null;
  launcherPath?: string | null;
  prefix?: string | null;
}): Promise<TermuxServicePaths> {
  const fallbackPaths = resolveTermuxServicePaths(options);
  if (options.serviceDir || options.envPath || options.launcherPath) {
    return fallbackPaths;
  }

  try {
    const launcherContent = await readFile(fallbackPaths.launcherPath, "utf8");
    return {
      ...fallbackPaths,
      envPath:
        readTermuxLauncherEnvPath(launcherContent) ?? fallbackPaths.envPath,
    };
  } catch {
    return fallbackPaths;
  }
}

export async function isServiceWrapperStale(
  paths: TermuxServicePaths,
  config: NodeConfig,
): Promise<boolean> {
  try {
    const [existingLauncher, existingEnv, loggerTarget] = await Promise.all([
      readFile(paths.launcherPath, "utf8"),
      readFile(paths.envPath, "utf8"),
      readlink(paths.logRunPath).catch(() => null),
    ]);
    return (
      existingLauncher !== renderTermuxServiceLauncher(paths, config) ||
      existingEnv !== renderServiceEnv(config) ||
      loggerTarget !== paths.svloggerPath
    );
  } catch {
    return true;
  }
}

export function assertTermuxServicesHost(): void {
  if (!isTermuxRuntimePlatform() || !isTermuxEnvironment()) {
    throw new Error(
      "Sidemesh Termux service helpers currently support Termux only.",
    );
  }
  if (!supportsTermuxServiceManagement()) {
    throw new Error(
      "Sidemesh Termux service helpers require `termux-services`. Install it with `pkg install termux-services` and try again.",
    );
  }
}

async function ensureSvloggerLink(paths: TermuxServicePaths): Promise<void> {
  const existing = await lstat(paths.logRunPath).catch(() => null);
  if (existing) {
    if (existing.isSymbolicLink()) {
      const currentTarget = await readlink(paths.logRunPath).catch(() => null);
      if (currentTarget === paths.svloggerPath) {
        return;
      }
    }
    await rm(paths.logRunPath, { recursive: true, force: true });
  }
  await symlink(paths.svloggerPath, paths.logRunPath);
}

async function ensureTermuxServiceReady(
  paths: TermuxServicePaths,
): Promise<void> {
  await ensureTermuxServiceDaemonRunning(paths);
  await waitForServiceSupervise(paths);
}

async function ensureTermuxServiceDaemonRunning(
  paths: TermuxServicePaths,
): Promise<void> {
  if (await isTermuxServiceDaemonRunning(paths)) {
    return;
  }
  await execFileAsync(SERVICE_DAEMON_NAME, ["start"], {
    env: termuxServiceEnv(paths),
    encoding: "utf8",
    timeout: 15_000,
  });
  const deadline = Date.now() + SERVICE_DAEMON_START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await isTermuxServiceDaemonRunning(paths)) {
      return;
    }
    await delay(100);
  }
  throw new Error("Termux service-daemon did not start within 3 seconds.");
}

async function waitForServiceSupervise(
  paths: TermuxServicePaths,
): Promise<void> {
  const superviseOkPath = join(paths.serviceDir, "supervise", "ok");
  const deadline = Date.now() + SERVICE_SUPERVISE_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await pathExists(superviseOkPath)) {
      return;
    }
    await delay(100);
  }
  throw new Error(
    `Termux supervision did not become ready for ${paths.serviceName} within 3 seconds.`,
  );
}

async function isTermuxServiceDaemonRunning(
  paths: Pick<TermuxServicePaths, "pidPath">,
): Promise<boolean> {
  try {
    const pidValue = (await readFile(paths.pidPath, "utf8")).trim();
    const pid = Number.parseInt(pidValue, 10);
    if (!Number.isInteger(pid) || pid <= 0) {
      return false;
    }
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function assertCompiledCli(packageDir: string): Promise<void> {
  try {
    await access(join(packageDir, "dist", "cli.js"), fsConstants.F_OK);
  } catch {
    throw new Error(
      `Compiled CLI not found at ${join(packageDir, "dist", "cli.js")}. Run \`npm install\` and \`npm run build\` first.`,
    );
  }
}

async function assertTermuxServiceInstalled(
  paths: TermuxServicePaths,
): Promise<void> {
  if (!(await pathExists(paths.launcherPath))) {
    throw new Error(
      `Termux service ${paths.serviceName} is not installed at ${paths.serviceDir}. Run \`sidemesh service install\` first.`,
    );
  }
}

async function sv(paths: TermuxServicePaths, args: string[]): Promise<void> {
  await execFileAsync("sv", args, {
    env: termuxServiceEnv(paths),
    encoding: "utf8",
    timeout: 15_000,
  });
}

function parseTermuxServiceRunning(output: string): boolean {
  return /^run:/m.test(output.trim());
}

function normalizeTermuxServiceName(value: string | null | undefined): string {
  const serviceName = value?.trim() || DEFAULT_TERMUX_SERVICE_NAME;
  if (!/^[A-Za-z0-9_.@-]+$/.test(serviceName)) {
    throw new Error(`Invalid Termux service name: ${serviceName}`);
  }
  return serviceName;
}

function readTermuxLauncherEnvPath(content: string): string | null {
  const match = content.match(/^\.\s+'([^']+)'\s*$/m);
  return match?.[1]?.trim() ?? null;
}

function termuxServiceEnv(
  paths: Pick<TermuxServicePaths, "prefix">,
): NodeJS.ProcessEnv {
  return {
    ...process.env,
    PREFIX: paths.prefix,
    TERMUX__PREFIX: paths.prefix,
    SVDIR: join(paths.prefix, "var", "service"),
    LOGDIR: join(paths.prefix, "var", "log"),
    PATH: prependPathEntry(process.env.PATH ?? "", join(paths.prefix, "bin")),
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

function prependPathEntry(pathValue: string, entry: string): string {
  const entries = pathValue
    .split(":")
    .map((value) => value.trim())
    .filter(Boolean);
  if (!entries.includes(entry)) {
    entries.unshift(entry);
  }
  return entries.join(":");
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`;
}
