import { execFile } from "node:child_process";
import { access, cp, mkdir, rm, writeFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import nodePath from "node:path";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";

import type { NodeConfig, UpdateChannel } from "./types.js";
import type { InstallInfo } from "./install-info.js";
import { isTermuxEnvironment } from "./host-environment.js";
import type { LaunchdPaths } from "./launchd-service.js";
import type { ServicePaths } from "./systemd-service.js";
import type { TermuxServicePaths } from "./termux-service.js";
import { assertGitCheckoutClean } from "./update-preflight.js";
import { detectInstallInfo } from "./install-info.js";
import {
  startDaemon,
  stopDaemon,
  waitForDaemonHealth,
} from "./daemon-control.js";
import {
  installLaunchdService,
  isLaunchdServiceInstalled,
  isServiceWrapperStale as isLaunchdServiceWrapperStale,
  resolveInstalledLaunchdPaths,
} from "./launchd-service.js";
import {
  installSystemdService,
  isServiceWrapperStale as isSystemdServiceWrapperStale,
  isSystemdServiceEnabled,
  readSystemdUnitLimits,
  resolveInstalledServicePaths,
} from "./systemd-service.js";
import {
  installTermuxService,
  isServiceWrapperStale as isTermuxServiceWrapperStale,
  isTermuxServiceEnabled,
  isTermuxServiceInstalled,
  resolveInstalledTermuxServicePaths,
  startTermuxService,
  stopTermuxService,
} from "./termux-service.js";

const execFileAsync = promisify(execFile);
const UPDATE_COMMAND_TIMEOUT_MS = 10 * 60_000;

export interface SelfUpdateOptions {
  config: NodeConfig;
  packageDir?: string | null;
  managedService?: string | null;
  dryRun?: boolean;
}

export interface SelfUpdateResult {
  success: boolean;
  oldVersion: string;
  newVersion: string | null;
  restored: boolean;
  logPath: string;
  error: string | null;
}

interface CommandOptions {
  cwd?: string;
  encoding?: BufferEncoding;
  timeout?: number;
}

interface CommandResult {
  stdout: string;
  stderr: string;
}

export interface SelfUpdateDependencies {
  detectInstallInfo: typeof detectInstallInfo;
  stopDaemon: typeof stopDaemon;
  startDaemon: typeof startDaemon;
  waitForDaemonHealth: typeof waitForDaemonHealth;
  installSystemdService: typeof installSystemdService;
  isSystemdServiceEnabled: typeof isSystemdServiceEnabled;
  isSystemdServiceWrapperStale: typeof isSystemdServiceWrapperStale;
  readSystemdUnitLimits: typeof readSystemdUnitLimits;
  resolveInstalledServicePaths: typeof resolveInstalledServicePaths;
  installLaunchdService: typeof installLaunchdService;
  isLaunchdServiceInstalled: typeof isLaunchdServiceInstalled;
  isLaunchdServiceWrapperStale: typeof isLaunchdServiceWrapperStale;
  resolveInstalledLaunchdPaths: typeof resolveInstalledLaunchdPaths;
  installTermuxService: typeof installTermuxService;
  isTermuxServiceInstalled: typeof isTermuxServiceInstalled;
  isTermuxServiceEnabled: typeof isTermuxServiceEnabled;
  isTermuxServiceWrapperStale: typeof isTermuxServiceWrapperStale;
  resolveInstalledTermuxServicePaths: typeof resolveInstalledTermuxServicePaths;
  startTermuxService: typeof startTermuxService;
  stopTermuxService: typeof stopTermuxService;
  runCommand: (
    file: string,
    args: string[],
    options?: CommandOptions,
  ) => Promise<CommandResult>;
  resolveUpdatedPackageDir: (
    info: InstallInfo,
    fallbackPackageDir: string,
  ) => Promise<string>;
}

const DEFAULT_SELF_UPDATE_DEPENDENCIES: SelfUpdateDependencies = {
  detectInstallInfo,
  stopDaemon,
  startDaemon,
  waitForDaemonHealth,
  installSystemdService,
  isSystemdServiceEnabled,
  isSystemdServiceWrapperStale,
  readSystemdUnitLimits,
  resolveInstalledServicePaths,
  installLaunchdService,
  isLaunchdServiceInstalled,
  isLaunchdServiceWrapperStale,
  resolveInstalledLaunchdPaths,
  installTermuxService,
  isTermuxServiceInstalled,
  isTermuxServiceEnabled,
  isTermuxServiceWrapperStale,
  resolveInstalledTermuxServicePaths,
  startTermuxService,
  stopTermuxService,
  runCommand: async (file, args, options = {}) => {
    const { stdout = "", stderr = "" } = await execFileAsync(file, args, options);
    return { stdout, stderr };
  },
  resolveUpdatedPackageDir: resolveUpdatedPackageDir,
};

export function applyUpdateChannelOverrideFromEnv(
  config: NodeConfig,
  env: { SIDEMESH_UPDATE_CHANNEL?: string } = process.env,
): NodeConfig {
  const updateChannel = parseUpdateChannelOverride(env.SIDEMESH_UPDATE_CHANNEL);
  return updateChannel ? { ...config, updateChannel } : config;
}

export async function runSelfUpdate(
  options: SelfUpdateOptions,
  dependencyOverrides: Partial<SelfUpdateDependencies> = {},
): Promise<SelfUpdateResult> {
  const dependencies = {
    ...DEFAULT_SELF_UPDATE_DEPENDENCIES,
    ...dependencyOverrides,
  } satisfies SelfUpdateDependencies;
  const config = applyUpdateChannelOverrideFromEnv(options.config);
  const { dryRun = false } = options;
  const requestedPackageDir = options.packageDir?.trim() || undefined;
  const managedService = options.managedService?.trim() || null;
  const logDir = nodePath.join(config.stateDir, "logs");
  await mkdir(logDir, { recursive: true });
  const logPath = nodePath.join(logDir, `self-update-${Date.now()}.log`);

  const lockPath = nodePath.join(config.stateDir, "update.lock");
  try {
    await writeFile(lockPath, JSON.stringify({ startedAt: Date.now() }), {
      flag: "wx",
      mode: 0o600,
    });
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "EEXIST") {
      return {
        success: false,
        oldVersion: "unknown",
        newVersion: null,
        restored: false,
        logPath,
        error: "Update already in progress",
      };
    }
    throw error;
  }

  try {
    const info = await dependencies.detectInstallInfo({
      packageRoot: requestedPackageDir,
      config,
    });
    const packageDir = info.packageRoot;
    const oldVersion = info.packageVersion;

    if (!info.updateSupported && !dryRun) {
      return {
        success: false,
        oldVersion,
        newVersion: null,
        restored: false,
        logPath,
        error: `Update not supported for install type: ${info.installType}`,
      };
    }

    if (info.installType === "git" && !dryRun) {
      try {
        await assertGitCheckoutClean(packageDir, dependencies.runCommand);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        await appendLog(logPath, `[self-update] ERROR: ${message}`);
        return {
          success: false,
          oldVersion,
          newVersion: null,
          restored: false,
          logPath,
          error: message,
        };
      }
    }

    const managedServiceInstalled = managedService
      ? await getManagedServiceInstalledState(
          {
            config,
            packageDir,
            managedService,
          },
          dependencies,
        )
      : null;

    await appendLog(logPath, `[self-update] Starting from ${oldVersion}`);
    await appendLog(logPath, `[self-update] Install type: ${info.installType}`);
    await appendLog(logPath, `[self-update] Update channel: ${info.updateChannel}`);
    await appendLog(logPath, `[self-update] Package dir: ${packageDir}`);
    if (info.currentCommitSha) {
      await appendLog(
        logPath,
        `[self-update] Current commit: ${info.currentCommitSha}`,
      );
    }

    if (dryRun) {
      await appendLog(logPath, `[dry-run] Would run: ${info.updateCommand}`);
      await logManagedServiceReinstallPlan(
        {
          config,
          info,
          packageDir,
          managedService,
          logPath,
          installed: managedServiceInstalled,
        },
        dependencies,
      );
      return {
        success: true,
        oldVersion,
        newVersion: oldVersion,
        restored: false,
        logPath,
        error: null,
      };
    }

    try {
      await appendLog(logPath, `[self-update] Stopping daemon...`);
      if (managedService) {
        await stopManagedService(
          {
            config,
            managedService,
            packageDir,
          },
          dependencies,
        );
        await appendLog(
          logPath,
          `[self-update] Stopped managed service ${managedService}`,
        );
        await delay(1000);
      } else {
        const stopped = await dependencies.stopDaemon(config, { yes: true });
        if (!stopped) {
          await appendLog(
            logPath,
            `[self-update] Daemon was not running, continuing anyway.`,
          );
        }
        await delay(500);
      }

      const distPath = nodePath.join(packageDir, "dist");
      const backupPath = nodePath.join(config.stateDir, "dist-backup-v1");
      await appendLog(logPath, `[self-update] Backing up dist to ${backupPath}...`);
      await rm(backupPath, { recursive: true, force: true });
      const distExists = await pathExists(distPath);
      if (distExists) {
        await cp(distPath, backupPath, {
          recursive: true,
          preserveTimestamps: true,
        });
      }

      await appendLog(logPath, `[self-update] Running update...`);
      await runUpdateCommand(info, packageDir, logPath);

      const updatedPackageDir = await dependencies.resolveUpdatedPackageDir(
        info,
        packageDir,
      );
      if (updatedPackageDir !== packageDir) {
        await appendLog(
          logPath,
          `[self-update] Updated package dir resolved to ${updatedPackageDir}`,
        );
      }

      const newCliPath = nodePath.join(updatedPackageDir, "dist", "cli.js");
      const newCliExists = await pathExists(newCliPath);
      if (!newCliExists) {
        throw new Error(`Compiled CLI not found at ${newCliPath} after update.`);
      }

      await reinstallManagedServiceIfNeeded(
        {
          config,
          info,
          packageDir: updatedPackageDir,
          managedService,
          logPath,
          installed: managedServiceInstalled,
        },
        dependencies,
      );

      await appendLog(logPath, `[self-update] Starting daemon...`);
      if (managedService) {
        await startManagedService(
          {
            config,
            managedService,
            packageDir: updatedPackageDir,
          },
          dependencies,
        );
        await appendLog(
          logPath,
          `[self-update] Started managed service ${managedService}`,
        );
      } else {
        await dependencies.startDaemon(config, { configPath: config.configPath });
      }

      await appendLog(logPath, `[self-update] Waiting for healthz...`);
      const healthy = await dependencies.waitForDaemonHealth(config.port, 15_000);
      if (!healthy) {
        throw new Error("Daemon did not become healthy within 15s after update.");
      }

      const newInfo = await dependencies.detectInstallInfo({
        packageRoot: updatedPackageDir,
        config,
      });
      await appendLog(
        logPath,
        `[self-update] Success! Updated ${oldVersion} → ${newInfo.packageVersion}`,
      );
      if (newInfo.currentCommitSha && newInfo.currentCommitSha !== info.currentCommitSha) {
        await appendLog(
          logPath,
          `[self-update] New commit: ${newInfo.currentCommitSha}`,
        );
      }

      await rm(backupPath, { recursive: true, force: true });

      return {
        success: true,
        oldVersion,
        newVersion: newInfo.packageVersion,
        restored: false,
        logPath,
        error: null,
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await appendLog(logPath, `[self-update] ERROR: ${message}`);

      const backupPath = nodePath.join(config.stateDir, "dist-backup-v1");
      const distPath = nodePath.join(packageDir, "dist");
      let restored = false;

      if (info.restoreCommand) {
        await appendLog(logPath, `[self-update] Restoring git checkout...`);
        try {
          await runShellCommand(info.restoreCommand, packageDir, logPath, 30_000);
          await appendLog(logPath, `[self-update] Git checkout restored.`);
        } catch (restoreError) {
          const restoreMessage =
            restoreError instanceof Error ? restoreError.message : String(restoreError);
          await appendLog(
            logPath,
            `[self-update] WARNING: Failed to restore git checkout: ${restoreMessage}`,
          );
        }
      }

      await appendLog(logPath, `[self-update] Restoring backup...`);
      const backupExists = await pathExists(backupPath);
      if (backupExists) {
        await rm(distPath, { recursive: true, force: true });
        await cp(backupPath, distPath, {
          recursive: true,
          preserveTimestamps: true,
        });
        await rm(backupPath, { recursive: true, force: true });
        await appendLog(logPath, `[self-update] Backup restored.`);
        restored = true;
      }

      try {
        await appendLog(logPath, `[self-update] Starting old daemon...`);
        if (managedService) {
          await startManagedService(
            {
              config,
              managedService,
              packageDir,
            },
            dependencies,
          );
        } else {
          await dependencies.startDaemon(config, { configPath: config.configPath });
        }
        const healthy = await dependencies.waitForDaemonHealth(config.port, 15_000);
        if (!healthy) {
          await appendLog(
            logPath,
            `[self-update] WARNING: Old daemon did not become healthy.`,
          );
        }
      } catch (startError) {
        const startMessage =
          startError instanceof Error ? startError.message : String(startError);
        await appendLog(
          logPath,
          `[self-update] WARNING: Failed to start old daemon: ${startMessage}`,
        );
      }

      return {
        success: false,
        oldVersion,
        newVersion: null,
        restored,
        logPath,
        error: message,
      };
    }
  } finally {
    await rm(lockPath, { force: true });
  }
}

async function runUpdateCommand(
  info: InstallInfo,
  packageDir: string,
  logPath: string,
): Promise<void> {
  if (!info.updateCommand) {
    return;
  }
  await runShellCommand(
    info.updateCommand,
    packageDir,
    logPath,
    UPDATE_COMMAND_TIMEOUT_MS,
  );
}

async function runShellCommand(
  command: string,
  packageDir: string,
  logPath: string,
  timeout: number,
): Promise<void> {
  const shell = process.env.SHELL || "/bin/sh";
  const env = buildSelfUpdateCommandEnv();
  await appendLog(logPath, `[self-update] $ ${command}`);

  try {
    const { stdout, stderr } = await execFileAsync(shell, ["-c", command], {
      cwd: packageDir,
      timeout,
      encoding: "utf8",
      env,
    });
    if (stdout) await appendLog(logPath, stdout);
    if (stderr) await appendLog(logPath, stderr);
  } catch (error) {
    const typed = error as {
      stdout?: string;
      stderr?: string;
      message?: string;
    };
    if (typed.stdout) await appendLog(logPath, typed.stdout);
    if (typed.stderr) await appendLog(logPath, typed.stderr);
    throw new Error(typed.message || "Command failed.");
  }
}

function buildSelfUpdateCommandEnv(
  baseEnv: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const pathKey =
    Object.keys(baseEnv).find((key) => key.toLowerCase() === "path") ?? "PATH";
  const nodeDir = nodePath.dirname(process.execPath);
  const currentPath = baseEnv[pathKey];
  const pathEntries =
    typeof currentPath === "string" && currentPath.length > 0
      ? currentPath.split(nodePath.delimiter).filter(Boolean)
      : [];
  const normalizedNodeDir = process.platform === "win32"
    ? nodeDir.toLowerCase()
    : nodeDir;
  const hasNodeDir = pathEntries.some((entry) => {
    if (process.platform === "win32") {
      return entry.toLowerCase() === normalizedNodeDir;
    }
    return entry === nodeDir;
  });

  return {
    ...baseEnv,
    [pathKey]: hasNodeDir
      ? pathEntries.join(nodePath.delimiter)
      : [nodeDir, ...pathEntries].join(nodePath.delimiter),
  };
}

async function stopManagedService(
  options: {
    config: NodeConfig;
    managedService: string;
    packageDir: string;
  },
  dependencies: SelfUpdateDependencies,
): Promise<void> {
  if (isTermuxEnvironment()) {
    await dependencies.stopTermuxService(options.managedService);
    return;
  }
  if (process.platform === "darwin") {
    const paths = await dependencies.resolveInstalledLaunchdPaths(options.config, {
      label: options.managedService,
      packageDir: options.packageDir,
      nodeBin: process.execPath,
    });
    await dependencies.runCommand(
      "launchctl",
      ["bootout", launchdTarget(), paths.plistPath],
      { encoding: "utf8", timeout: 15_000 },
    );
    return;
  }

  await dependencies.runCommand(
    "systemctl",
    ["stop", `${options.managedService}.service`],
    { encoding: "utf8", timeout: 15_000 },
  );
}

async function startManagedService(
  options: {
    config: NodeConfig;
    managedService: string;
    packageDir: string;
  },
  dependencies: SelfUpdateDependencies,
): Promise<void> {
  if (isTermuxEnvironment()) {
    await dependencies.startTermuxService(options.managedService);
    return;
  }
  if (process.platform === "darwin") {
    const paths = await dependencies.resolveInstalledLaunchdPaths(options.config, {
      label: options.managedService,
      packageDir: options.packageDir,
      nodeBin: process.execPath,
    });
    await dependencies.runCommand(
      "launchctl",
      ["bootstrap", launchdTarget(), paths.plistPath],
      { encoding: "utf8", timeout: 15_000 },
    );
    await dependencies.runCommand(
      "launchctl",
      ["enable", `${launchdTarget()}/${paths.label}`],
      { encoding: "utf8", timeout: 15_000 },
    ).catch(() => undefined);
    await dependencies.runCommand(
      "launchctl",
      ["kickstart", "-k", `${launchdTarget()}/${paths.label}`],
      { encoding: "utf8", timeout: 15_000 },
    );
    return;
  }

  await dependencies.runCommand(
    "systemctl",
    ["start", `${options.managedService}.service`],
    { encoding: "utf8", timeout: 15_000 },
  );
}

async function getManagedServiceInstalledState(
  options: {
    config: NodeConfig;
    packageDir: string;
    managedService: string;
  },
  dependencies: SelfUpdateDependencies,
): Promise<boolean> {
  if (isTermuxEnvironment()) {
    const paths = await dependencies.resolveInstalledTermuxServicePaths({
      serviceName: options.managedService,
      packageDir: options.packageDir,
      nodeBin: process.execPath,
    });
    return dependencies.isTermuxServiceInstalled(paths.serviceName);
  }
  if (process.platform === "darwin") {
    const paths = await dependencies.resolveInstalledLaunchdPaths(options.config, {
      label: options.managedService,
      packageDir: options.packageDir,
      nodeBin: process.execPath,
    });
    return dependencies.isLaunchdServiceInstalled(paths.label);
  }

  const paths = await dependencies.resolveInstalledServicePaths({
    serviceName: options.managedService,
    packageDir: options.packageDir,
    nodeBin: process.execPath,
  });
  return dependencies.isSystemdServiceEnabled(paths.serviceName);
}

async function logManagedServiceReinstallPlan(
  options: {
    config: NodeConfig;
    info: InstallInfo;
    packageDir: string;
    managedService: string | null;
    logPath: string;
    installed: boolean | null;
  },
  dependencies: SelfUpdateDependencies,
): Promise<void> {
  if (!options.managedService) {
    return;
  }
  const staleState = await getManagedServiceReinstallState(
    {
      ...options,
      managedService: options.managedService,
    },
    dependencies,
  );
  if (!staleState.installed) {
    await appendLog(
      options.logPath,
      `[dry-run] Managed service ${staleState.serviceId} is not installed, skipping wrapper reinstall.`,
    );
    return;
  }
  if (!staleState.stale) {
    await appendLog(
      options.logPath,
      `[dry-run] Managed service ${staleState.serviceId} wrapper is up to date.`,
    );
    return;
  }
  await appendLog(
    options.logPath,
    `[dry-run] Service wrapper is stale, will reinstall ${staleState.serviceId}.`,
  );
}

async function reinstallManagedServiceIfNeeded(
  options: {
    config: NodeConfig;
    info: InstallInfo;
    packageDir: string;
    managedService: string | null;
    logPath: string;
    installed: boolean | null;
  },
  dependencies: SelfUpdateDependencies,
): Promise<void> {
  if (!options.managedService) {
    return;
  }

  const staleState = await getManagedServiceReinstallState(
    {
      ...options,
      managedService: options.managedService,
    },
    dependencies,
  );
  if (!staleState.installed) {
    await appendLog(
      options.logPath,
      `[self-update] Managed service ${staleState.serviceId} is not installed, skipping wrapper reinstall.`,
    );
    return;
  }
  if (!staleState.stale) {
    await appendLog(
      options.logPath,
      `[self-update] Managed service ${staleState.serviceId} wrapper is up to date.`,
    );
    return;
  }

  await appendLog(
    options.logPath,
    `[self-update] Service wrapper is stale, will reinstall ${staleState.serviceId}.`,
  );
  try {
    if (staleState.kind === "systemd") {
      await dependencies.installSystemdService(options.config, {
        serviceName: staleState.paths.serviceName,
        packageDir: staleState.paths.packageDir,
        nodeBin: staleState.paths.nodeBin,
        unitPath: staleState.paths.unitPath,
        envPath: staleState.paths.envPath,
        launcherPath: staleState.paths.launcherPath,
        memoryHigh: staleState.limits.memoryHigh,
        memoryMax: staleState.limits.memoryMax,
        start: false,
      });
    } else if (staleState.kind === "termux") {
      await dependencies.installTermuxService(options.config, {
        serviceName: staleState.paths.serviceName,
        packageDir: staleState.paths.packageDir,
        nodeBin: staleState.paths.nodeBin,
        serviceDir: staleState.paths.serviceDir,
        envPath: staleState.paths.envPath,
        launcherPath: staleState.paths.launcherPath,
        enabled: staleState.enabled,
        start: false,
      });
    } else {
      await dependencies.installLaunchdService(options.config, {
        label: staleState.paths.label,
        packageDir: staleState.paths.packageDir,
        nodeBin: staleState.paths.nodeBin,
        plistPath: staleState.paths.plistPath,
        envPath: staleState.paths.envPath,
        launcherPath: staleState.paths.launcherPath,
        start: false,
      });
    }
    await appendLog(
      options.logPath,
      `[self-update] Reinstalled managed service wrapper ${staleState.serviceId}.`,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await appendLog(
      options.logPath,
      `[self-update] WARNING: Failed to reinstall service wrapper ${staleState.serviceId}: ${message}`,
    );
  }
}

type ManagedServiceReinstallState =
  | {
      kind: "systemd";
      installed: boolean;
      stale: boolean;
      serviceId: string;
      paths: ServicePaths;
      limits: { memoryHigh: string | null; memoryMax: string | null };
    }
  | {
      kind: "launchd";
      installed: boolean;
      stale: boolean;
      serviceId: string;
      paths: LaunchdPaths;
    }
  | {
      kind: "termux";
      installed: boolean;
      stale: boolean;
      serviceId: string;
      enabled: boolean;
      paths: TermuxServicePaths;
    };

async function getManagedServiceReinstallState(
  options: {
    config: NodeConfig;
    info: InstallInfo;
    packageDir: string;
    managedService: string;
    logPath: string;
    installed: boolean | null;
  },
  dependencies: SelfUpdateDependencies,
): Promise<ManagedServiceReinstallState> {
  if (isTermuxEnvironment()) {
    const paths = await dependencies.resolveInstalledTermuxServicePaths({
      serviceName: options.managedService,
      packageDir: options.packageDir,
      nodeBin: process.execPath,
    });
    const installed =
      options.installed ??
      (await dependencies.isTermuxServiceInstalled(paths.serviceName));
    const enabled =
      installed &&
      (await dependencies.isTermuxServiceEnabled(paths.serviceName));
    const stale =
      installed &&
      (await dependencies.isTermuxServiceWrapperStale(paths, options.config));
    return {
      kind: "termux",
      installed,
      stale,
      serviceId: paths.serviceName,
      enabled,
      paths,
    };
  }
  if (process.platform === "darwin") {
    const paths = await dependencies.resolveInstalledLaunchdPaths(options.config, {
      label: options.managedService,
      packageDir: options.packageDir,
      nodeBin: process.execPath,
    });
    const installed =
      options.installed ??
      (await dependencies.isLaunchdServiceInstalled(paths.label));
    const stale =
      installed &&
      (await dependencies.isLaunchdServiceWrapperStale(paths, options.config));
    return {
      kind: "launchd",
      installed,
      stale,
      serviceId: paths.label,
      paths,
    };
  }

  const paths = await dependencies.resolveInstalledServicePaths({
    serviceName: options.managedService,
    packageDir: options.packageDir,
    nodeBin: process.execPath,
  });
  const installed =
    options.installed ??
    (await dependencies.isSystemdServiceEnabled(paths.serviceName));
  const limits = installed
    ? await dependencies.readSystemdUnitLimits(paths)
    : { memoryHigh: null, memoryMax: null };
  const stale =
    installed &&
    (await dependencies.isSystemdServiceWrapperStale(
      paths,
      options.config,
      limits,
    ));
  return {
    kind: "systemd",
    installed,
    stale,
    serviceId: `${paths.serviceName}.service`,
    paths,
    limits,
  };
}

async function resolveUpdatedPackageDir(
  info: InstallInfo,
  fallbackPackageDir: string,
): Promise<string> {
  if (info.installType !== "npm-global") {
    return fallbackPackageDir;
  }

  try {
    const { stdout } = await execFileAsync("npm", ["root", "-g"], {
      encoding: "utf8",
      timeout: 10_000,
    });
    const globalRoot = stdout.trim();
    if (!globalRoot) {
      return fallbackPackageDir;
    }
    return nodePath.join(globalRoot, "sidemesh");
  } catch {
    return fallbackPackageDir;
  }
}

function parseUpdateChannelOverride(
  value: string | undefined,
): UpdateChannel | null {
  const channel = value?.trim();
  if (channel === "stable" || channel === "bleeding-edge") {
    return channel;
  }
  return null;
}

async function appendLog(path: string, message: string): Promise<void> {
  const line = `[${new Date().toISOString()}] ${message}\n`;
  await writeFile(path, line, { flag: "a" });
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

function launchdTarget(): string {
  return `gui/${process.getuid?.() ?? 501}`;
}
