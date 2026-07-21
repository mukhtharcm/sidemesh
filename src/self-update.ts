import { execFile } from "node:child_process";
import {
  access,
  cp,
  mkdir,
  readdir,
  realpath,
  rm,
  writeFile,
} from "node:fs/promises";
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
import {
  BLEEDING_EDGE_GIT_REF,
  detectInstallInfo,
  resolveNpmExecutable,
} from "./install-info.js";
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
import {
  assertUpdateLockOwner,
  createQueuedUpdateStatus,
  patchUpdateStatus,
  readUpdateStatus,
  releaseUpdateLock,
  reserveUpdateLock,
  writeUpdateStatus,
  type UpdateStatus,
} from "./update-status.js";

const execFileAsync = promisify(execFile);
const UPDATE_COMMAND_TIMEOUT_MS = 10 * 60_000;

export interface SelfUpdateOptions {
  config: NodeConfig;
  packageDir?: string | null;
  managedService?: string | null;
  updateId?: string | null;
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
  env?: NodeJS.ProcessEnv;
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
  pause(milliseconds: number): Promise<void>;
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
  pause: async (milliseconds) => delay(milliseconds),
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
  const requestedUpdateId = options.updateId?.trim() || null;
  let info: InstallInfo;
  try {
    info = await dependencies.detectInstallInfo({
      packageRoot: requestedPackageDir,
      config,
    });
  } catch (error) {
    if (requestedUpdateId) {
      await failReservedUpdate(
        config.stateDir,
        requestedUpdateId,
        error,
        logPath,
      );
    }
    throw error;
  }

  const status = await prepareUpdateStatus(
    config.stateDir,
    info,
    requestedUpdateId,
  );
  try {
    await patchUpdateStatus(config.stateDir, status.id, {
      state: "running",
      phase: "preflight",
      logPath,
    });
  } catch (error) {
    await releaseUpdateLock(config.stateDir, status.id).catch(() => undefined);
    throw error;
  }
  let statusCompleted = false;
  const finish = async (
    result: SelfUpdateResult,
    installedCommitSha: string | null = null,
  ): Promise<SelfUpdateResult> => {
    await patchUpdateStatus(config.stateDir, status.id, {
      state: result.success ? "succeeded" : "failed",
      phase: "completed",
      finishedAt: Date.now(),
      installedVersion:
        result.newVersion ?? (result.restored ? result.oldVersion : null),
      installedCommitSha:
        installedCommitSha ?? (result.restored ? info.currentCommitSha : null),
      restored: result.restored,
      error: result.error,
      logPath: result.logPath,
    });
    statusCompleted = true;
    return result;
  };

  try {
    const packageDir = info.packageRoot;
    const oldVersion = info.packageVersion;

    if (!info.updateSupported && !dryRun) {
      return await finish({
        success: false,
        oldVersion,
        newVersion: null,
        restored: false,
        logPath,
        error: `Update not supported for install type: ${info.installType}`,
      });
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
    const useAtomicManagedGitUpdate =
      info.installType === "git" &&
      info.updateChannel === "bleeding-edge" &&
      info.currentCommitSha !== null &&
      managedService !== null &&
      managedServiceInstalled === true;

    if (info.installType === "git" && !dryRun && !useAtomicManagedGitUpdate) {
      try {
        await assertGitCheckoutClean(packageDir, dependencies.runCommand);
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        await appendLog(logPath, `[self-update] ERROR: ${message}`);
        return await finish({
          success: false,
          oldVersion,
          newVersion: null,
          restored: false,
          logPath,
          error: message,
        });
      }
    }

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
      return await finish({
        success: true,
        oldVersion,
        newVersion: oldVersion,
        restored: false,
        logPath,
        error: null,
      });
    }

    if (useAtomicManagedGitUpdate && managedService) {
      const atomicResult = await runAtomicManagedGitUpdate(
        {
          config,
          info,
          packageDir,
          managedService,
          logPath,
          updateId: status.id,
        },
        dependencies,
      );
      return await finish(
        atomicResult.result,
        atomicResult.installedCommitSha,
      );
    }

    try {
      await patchUpdateStatus(config.stateDir, status.id, {
        phase: "stopping",
        cutoverStarted: true,
      });
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
        await dependencies.pause(1000);
      } else {
        const stopped = await dependencies.stopDaemon(config, { yes: true });
        if (!stopped) {
          await appendLog(
            logPath,
            `[self-update] Daemon was not running, continuing anyway.`,
          );
        }
        await dependencies.pause(500);
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

      return await finish({
        success: true,
        oldVersion,
        newVersion: newInfo.packageVersion,
        restored: false,
        logPath,
        error: null,
      }, newInfo.currentCommitSha);
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

      return await finish({
        success: false,
        oldVersion,
        newVersion: null,
        restored,
        logPath,
        error: message,
      });
    }
  } catch (error) {
    if (!statusCompleted) {
      const message = error instanceof Error ? error.message : String(error);
      await patchUpdateStatus(config.stateDir, status.id, {
        state: "failed",
        phase: "completed",
        finishedAt: Date.now(),
        restored: false,
        error: message,
        logPath,
      }).catch(() => undefined);
    }
    throw error;
  } finally {
    await releaseUpdateLock(config.stateDir, status.id);
  }
}

async function prepareUpdateStatus(
  stateDir: string,
  info: InstallInfo,
  requestedUpdateId: string | null,
): Promise<UpdateStatus> {
  if (requestedUpdateId) {
    await assertUpdateLockOwner(stateDir, requestedUpdateId);
    const existing = await readUpdateStatus(stateDir);
    if (!existing || existing.id !== requestedUpdateId) {
      await releaseUpdateLock(stateDir, requestedUpdateId);
      throw new Error(`Update status ${requestedUpdateId} is unavailable`);
    }
    return existing;
  }

  const status = createQueuedUpdateStatus(info, info.updateChannel);
  await reserveUpdateLock(stateDir, status.id, status.startedAt);
  try {
    await writeUpdateStatus(stateDir, status);
    return status;
  } catch (error) {
    await releaseUpdateLock(stateDir, status.id);
    throw error;
  }
}

async function failReservedUpdate(
  stateDir: string,
  updateId: string,
  error: unknown,
  logPath: string,
): Promise<void> {
  const message = error instanceof Error ? error.message : String(error);
  try {
    await assertUpdateLockOwner(stateDir, updateId);
    await patchUpdateStatus(stateDir, updateId, {
      state: "failed",
      phase: "completed",
      finishedAt: Date.now(),
      restored: false,
      error: message,
      logPath,
    }).catch(() => undefined);
  } finally {
    await releaseUpdateLock(stateDir, updateId);
  }
}

interface AtomicManagedGitUpdateResult {
  result: SelfUpdateResult;
  installedCommitSha: string | null;
}

async function runAtomicManagedGitUpdate(
  options: {
    config: NodeConfig;
    info: InstallInfo;
    packageDir: string;
    managedService: string;
    logPath: string;
    updateId: string;
  },
  dependencies: SelfUpdateDependencies,
): Promise<AtomicManagedGitUpdateResult> {
  let releaseRoot = nodePath.resolve(options.config.stateDir, "releases");
  let activePackageDir = nodePath.resolve(options.packageDir);
  let candidateDir: string | null = null;
  let targetCommitSha: string | null = null;
  let cutoverStarted = false;
  const currentCommitSha = options.info.currentCommitSha;
  try {
    if (currentCommitSha === null) {
      throw new Error("Atomic Git update requires the active commit SHA.");
    }
    const [realStateDir, realPackageDir] = await Promise.all([
      realpath(options.config.stateDir),
      realpath(options.packageDir),
    ]);
    releaseRoot = nodePath.join(realStateDir, "releases");
    activePackageDir = realPackageDir;
    assertReleaseRootOutsideCheckout(realPackageDir, releaseRoot);
    await mkdir(releaseRoot, { recursive: true, mode: 0o700 });
    await patchUpdateStatus(options.config.stateDir, options.updateId, {
      phase: "staging",
    });
    await appendLog(
      options.logPath,
      `[self-update] Staging an atomic release while the daemon stays online...`,
    );
    const candidate = await stageBleedingEdgeRelease(
      {
        packageDir: options.packageDir,
        releaseRoot,
        logPath: options.logPath,
        currentCommitSha,
      },
      dependencies,
    );
    candidateDir = candidate.packageDir;
    targetCommitSha = candidate.commitSha;
    await patchUpdateStatus(options.config.stateDir, options.updateId, {
      targetCommitSha,
    });
    if (candidate.alreadyActive) {
      await appendLog(
        options.logPath,
        `[self-update] Verified commit ${targetCommitSha} is already active.`,
      );
      return {
        result: {
          success: true,
          oldVersion: options.info.packageVersion,
          newVersion: options.info.packageVersion,
          restored: false,
          logPath: options.logPath,
          error: null,
        },
        installedCommitSha: targetCommitSha,
      };
    }

    await patchUpdateStatus(options.config.stateDir, options.updateId, {
      phase: "stopping",
      cutoverStarted: true,
    });
    cutoverStarted = true;
    await appendLog(options.logPath, `[self-update] Stopping daemon for cutover...`);
    await stopManagedService(
      {
        config: options.config,
        managedService: options.managedService,
        packageDir: options.packageDir,
      },
      dependencies,
    );
    await dependencies.pause(1000);

    await patchUpdateStatus(options.config.stateDir, options.updateId, {
      phase: "switching",
    });
    await reinstallManagedServiceIfNeeded(
      {
        config: options.config,
        info: options.info,
        packageDir: candidateDir,
        managedService: options.managedService,
        logPath: options.logPath,
        installed: true,
        force: true,
        failOnError: true,
      },
      dependencies,
    );

    await patchUpdateStatus(options.config.stateDir, options.updateId, {
      phase: "starting",
    });
    await startManagedService(
      {
        config: options.config,
        managedService: options.managedService,
        packageDir: candidateDir,
      },
      dependencies,
    );

    await patchUpdateStatus(options.config.stateDir, options.updateId, {
      phase: "verifying",
    });
    const healthy = await dependencies.waitForDaemonHealth(
      options.config.port,
      15_000,
    );
    if (!healthy) {
      throw new Error("Daemon did not become healthy within 15s after cutover.");
    }

    const newInfo = await dependencies.detectInstallInfo({
      packageRoot: candidateDir,
      config: options.config,
    });
    if (newInfo.currentCommitSha !== targetCommitSha) {
      throw new Error(
        `Candidate commit mismatch after cutover: expected ${targetCommitSha}, got ${newInfo.currentCommitSha ?? "unknown"}`,
      );
    }
    await appendLogBestEffort(
      options.logPath,
      `[self-update] Atomic cutover succeeded at ${targetCommitSha}.`,
    );
    await cleanupOldReleases(
      options.packageDir,
      releaseRoot,
      new Set([
        activePackageDir,
        nodePath.resolve(candidateDir),
      ]),
      options.logPath,
      dependencies,
    ).catch(async (error) => {
      const message = error instanceof Error ? error.message : String(error);
      await appendLogBestEffort(
        options.logPath,
        `[self-update] WARNING: Failed to clean old releases: ${message}`,
      );
    });

    return {
      result: {
        success: true,
        oldVersion: options.info.packageVersion,
        newVersion: newInfo.packageVersion,
        restored: false,
        logPath: options.logPath,
        error: null,
      },
      installedCommitSha: targetCommitSha,
    };
  } catch (error) {
    const updateMessage = error instanceof Error ? error.message : String(error);
    await appendLogBestEffort(
      options.logPath,
      `[self-update] ERROR: ${updateMessage}`,
    );
    let restored = false;
    let rollbackError: string | null = null;

    if (cutoverStarted) {
      await patchUpdateStatus(options.config.stateDir, options.updateId, {
        phase: "rolling_back",
        error: updateMessage,
      }).catch(() => undefined);
      await appendLogBestEffort(
        options.logPath,
        `[self-update] Rolling service wrapper back to ${options.packageDir}...`,
      );
      try {
        if (candidateDir) {
          await stopManagedService(
            {
              config: options.config,
              managedService: options.managedService,
              packageDir: candidateDir,
            },
            dependencies,
          ).catch(() => undefined);
        }
        await reinstallManagedServiceIfNeeded(
          {
            config: options.config,
            info: options.info,
            packageDir: options.packageDir,
            managedService: options.managedService,
            logPath: options.logPath,
            installed: true,
            force: true,
            failOnError: true,
          },
          dependencies,
        );
        await startManagedService(
          {
            config: options.config,
            managedService: options.managedService,
            packageDir: options.packageDir,
          },
          dependencies,
        );
        restored = await dependencies.waitForDaemonHealth(
          options.config.port,
          15_000,
        );
        if (!restored) {
          throw new Error("Previous daemon did not become healthy after rollback.");
        }
        await appendLogBestEffort(
          options.logPath,
          `[self-update] Previous release restored and healthy.`,
        );
      } catch (rollbackFailure) {
        rollbackError = rollbackFailure instanceof Error
          ? rollbackFailure.message
          : String(rollbackFailure);
        await appendLogBestEffort(
          options.logPath,
          `[self-update] ERROR: Rollback failed: ${rollbackError}`,
        );
      }
    }

    if (candidateDir && (!cutoverStarted || restored)) {
      await removeReleaseWorktree(
        options.packageDir,
        releaseRoot,
        candidateDir,
        options.logPath,
        dependencies,
      ).catch(() => undefined);
    }

    const errorMessage = rollbackError
      ? `${updateMessage}; rollback failed: ${rollbackError}`
      : updateMessage;
    return {
      result: {
        success: false,
        oldVersion: options.info.packageVersion,
        newVersion: null,
        restored,
        logPath: options.logPath,
        error: errorMessage,
      },
      installedCommitSha: restored ? options.info.currentCommitSha : null,
    };
  }
}

async function stageBleedingEdgeRelease(
  options: {
    packageDir: string;
    releaseRoot: string;
    logPath: string;
    currentCommitSha: string;
  },
  dependencies: SelfUpdateDependencies,
): Promise<{
  packageDir: string;
  commitSha: string;
  alreadyActive: boolean;
}> {
  await runLoggedCommand(
    "git",
    ["fetch", "origin", BLEEDING_EDGE_GIT_REF],
    options.packageDir,
    options.logPath,
    UPDATE_COMMAND_TIMEOUT_MS,
    dependencies,
  );
  const { stdout } = await runLoggedCommand(
    "git",
    ["rev-parse", "FETCH_HEAD"],
    options.packageDir,
    options.logPath,
    10_000,
    dependencies,
  );
  const commitSha = stdout.trim().toLowerCase();
  if (!/^[0-9a-f]{40}$/.test(commitSha)) {
    throw new Error(`Fetched update target is not a full Git commit SHA: ${commitSha}`);
  }
  if (!/^[0-9a-f]{40}$/.test(options.currentCommitSha)) {
    throw new Error(
      `Active release is not a full Git commit SHA: ${options.currentCommitSha}`,
    );
  }
  if (commitSha === options.currentCommitSha) {
    return {
      packageDir: options.packageDir,
      commitSha,
      alreadyActive: true,
    };
  }
  try {
    await runLoggedCommand(
      "git",
      [
        "merge-base",
        "--is-ancestor",
        options.currentCommitSha,
        commitSha,
      ],
      options.packageDir,
      options.logPath,
      10_000,
      dependencies,
    );
  } catch {
    throw new Error(
      `Refusing to replace ${options.currentCommitSha} with non-descendant verified commit ${commitSha}.`,
    );
  }

  const candidateDir = nodePath.join(options.releaseRoot, commitSha);
  assertReleasePath(options.releaseRoot, candidateDir);
  if (nodePath.resolve(candidateDir) === nodePath.resolve(options.packageDir)) {
    throw new Error(`Fetched commit ${commitSha} is already the active release.`);
  }
  if (await pathExists(candidateDir)) {
    await removeReleaseWorktree(
      options.packageDir,
      options.releaseRoot,
      candidateDir,
      options.logPath,
      dependencies,
    );
  }

  let worktreeCreated = false;
  try {
    await runLoggedCommand(
      "git",
      ["worktree", "add", "--detach", candidateDir, commitSha],
      options.packageDir,
      options.logPath,
      30_000,
      dependencies,
    );
    worktreeCreated = true;
    const npmExecutable = resolveNpmExecutable();
    await runLoggedCommand(
      npmExecutable,
      ["ci"],
      candidateDir,
      options.logPath,
      UPDATE_COMMAND_TIMEOUT_MS,
      dependencies,
    );
    await runLoggedCommand(
      npmExecutable,
      ["run", "build"],
      candidateDir,
      options.logPath,
      UPDATE_COMMAND_TIMEOUT_MS,
      dependencies,
    );
    const cliPath = nodePath.join(candidateDir, "dist", "cli.js");
    await access(cliPath, fsConstants.R_OK);
    return { packageDir: candidateDir, commitSha, alreadyActive: false };
  } catch (error) {
    if (worktreeCreated) {
      await removeReleaseWorktree(
        options.packageDir,
        options.releaseRoot,
        candidateDir,
        options.logPath,
        dependencies,
      ).catch(() => undefined);
    }
    throw error;
  }
}

async function runLoggedCommand(
  file: string,
  args: string[],
  cwd: string,
  logPath: string,
  timeout: number,
  dependencies: SelfUpdateDependencies,
): Promise<CommandResult> {
  await appendLog(
    logPath,
    `[self-update] $ ${[file, ...args].map(formatCommandArgument).join(" ")}`,
  );
  try {
    const result = await dependencies.runCommand(file, args, {
      cwd,
      encoding: "utf8",
      env: buildSelfUpdateCommandEnv(),
      timeout,
    });
    if (result.stdout) await appendLog(logPath, result.stdout);
    if (result.stderr) await appendLog(logPath, result.stderr);
    return result;
  } catch (error) {
    const typed = error as {
      stdout?: string;
      stderr?: string;
      message?: string;
    };
    if (typed.stdout) await appendLog(logPath, typed.stdout);
    if (typed.stderr) await appendLog(logPath, typed.stderr);
    throw new Error(typed.message || `${file} failed`);
  }
}

async function cleanupOldReleases(
  repositoryDir: string,
  releaseRoot: string,
  keepPaths: Set<string>,
  logPath: string,
  dependencies: SelfUpdateDependencies,
): Promise<void> {
  const entries = await readdir(releaseRoot, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory() || !/^[0-9a-f]{40}$/.test(entry.name)) {
      continue;
    }
    const releasePath = nodePath.join(releaseRoot, entry.name);
    if (keepPaths.has(nodePath.resolve(releasePath))) {
      continue;
    }
    await removeReleaseWorktree(
      repositoryDir,
      releaseRoot,
      releasePath,
      logPath,
      dependencies,
    );
  }
}

async function removeReleaseWorktree(
  repositoryDir: string,
  releaseRoot: string,
  releasePath: string,
  logPath: string,
  dependencies: SelfUpdateDependencies,
): Promise<void> {
  assertReleasePath(releaseRoot, releasePath);
  await runLoggedCommand(
    "git",
    ["worktree", "remove", "--force", releasePath],
    repositoryDir,
    logPath,
    30_000,
    dependencies,
  ).catch(() => undefined);
  await rm(releasePath, { recursive: true, force: true });
}

function assertReleaseRootOutsideCheckout(
  packageDir: string,
  releaseRoot: string,
): void {
  const relative = nodePath.relative(
    nodePath.resolve(packageDir),
    nodePath.resolve(releaseRoot),
  );
  if (
    relative === "" ||
    (relative !== ".." && !relative.startsWith(`..${nodePath.sep}`))
  ) {
    throw new Error(
      `Atomic release directory must be outside the active Git checkout: ${releaseRoot}`,
    );
  }
}

function assertReleasePath(releaseRoot: string, releasePath: string): void {
  const relative = nodePath.relative(
    nodePath.resolve(releaseRoot),
    nodePath.resolve(releasePath),
  );
  if (!/^[0-9a-f]{40}$/.test(relative)) {
    throw new Error(`Refusing to modify unsafe release path: ${releasePath}`);
  }
}

function formatCommandArgument(value: string): string {
  return /^[A-Za-z0-9_./:=+-]+$/.test(value)
    ? value
    : JSON.stringify(value);
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
    force?: boolean;
    failOnError?: boolean;
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
    await (options.force === true ? appendLogBestEffort : appendLog)(
      options.logPath,
      `[self-update] Managed service ${staleState.serviceId} is not installed, skipping wrapper reinstall.`,
    );
    return;
  }
  if (!staleState.stale && options.force !== true) {
    await appendLog(
      options.logPath,
      `[self-update] Managed service ${staleState.serviceId} wrapper is up to date.`,
    );
    return;
  }

  await (options.force === true ? appendLogBestEffort : appendLog)(
    options.logPath,
    options.force === true
      ? `[self-update] Switching managed service wrapper ${staleState.serviceId} to ${options.packageDir}.`
      : `[self-update] Service wrapper is stale, will reinstall ${staleState.serviceId}.`,
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
    await (options.force === true ? appendLogBestEffort : appendLog)(
      options.logPath,
      `[self-update] Reinstalled managed service wrapper ${staleState.serviceId}.`,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await (options.force === true ? appendLogBestEffort : appendLog)(
      options.logPath,
      `[self-update] WARNING: Failed to reinstall service wrapper ${staleState.serviceId}: ${message}`,
    );
    if (options.failOnError === true) {
      throw error;
    }
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
    force?: boolean;
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
    const enabled = installed && (
      options.force === true
        ? await dependencies.isTermuxServiceEnabled(paths.serviceName)
            .catch(() => true)
        : await dependencies.isTermuxServiceEnabled(paths.serviceName)
    );
    const stale = installed && (
      options.force === true ||
      (await dependencies.isTermuxServiceWrapperStale(paths, options.config))
    );
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
    const stale = installed && (
      options.force === true ||
      (await dependencies.isLaunchdServiceWrapperStale(paths, options.config))
    );
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
    ? options.force === true
      ? await dependencies.readSystemdUnitLimits(paths)
          .catch(() => ({ memoryHigh: null, memoryMax: null }))
      : await dependencies.readSystemdUnitLimits(paths)
    : { memoryHigh: null, memoryMax: null };
  const stale = installed && (
    options.force === true ||
    (await dependencies.isSystemdServiceWrapperStale(
      paths,
      options.config,
      limits,
    ))
  );
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

async function appendLogBestEffort(
  path: string,
  message: string,
): Promise<void> {
  await appendLog(path, message).catch(() => undefined);
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
