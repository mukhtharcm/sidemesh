import { execFile, spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { promisify } from "node:util";
import nodePath from "node:path";

import { isTermuxEnvironment } from "./host-environment.js";
import { detectInstallInfo } from "./install-info.js";
import type { NodeConfig, UpdateChannel } from "./types.js";
import { assertGitCheckoutClean } from "./update-preflight.js";
import {
  createQueuedUpdateStatus,
  patchUpdateStatus,
  releaseUpdateLock,
  reserveUpdateLock,
  writeUpdateStatus,
  type UpdateStatus,
} from "./update-status.js";

const execFileAsync = promisify(execFile);

interface UpdaterSpawnDependencies {
  detectInstallInfo: typeof detectInstallInfo;
  execFile(
    file: string,
    args: string[],
    options: {
      cwd?: string;
      encoding: "utf8";
      timeout: number;
    },
  ): Promise<{ stdout: string; stderr: string }>;
  spawnDetached(
    file: string,
    args: string[],
    env: NodeJS.ProcessEnv,
  ): void;
  now(): number;
  createUpdateId(): string;
  platform: NodeJS.Platform;
}

const DEFAULT_UPDATER_SPAWN_DEPENDENCIES: UpdaterSpawnDependencies = {
  detectInstallInfo,
  execFile: execFileAsync,
  spawnDetached: (file, args, env) => {
    const child = spawn(file, args, {
      detached: true,
      stdio: ["ignore", "ignore", "ignore"],
      env,
    });
    child.unref();
  },
  now: () => Date.now(),
  createUpdateId: () => randomUUID(),
  platform: process.platform,
};

export async function spawnSelfUpdater(
  config: NodeConfig,
  options: { updateChannel?: UpdateChannel | null } = {},
  dependencyOverrides: Partial<UpdaterSpawnDependencies> = {},
): Promise<UpdateStatus> {
  const dependencies = {
    ...DEFAULT_UPDATER_SPAWN_DEPENDENCIES,
    ...dependencyOverrides,
  } satisfies UpdaterSpawnDependencies;
  const info = await dependencies.detectInstallInfo({ config });
  const packageDir = info.packageRoot;
  const effectiveChannel = options.updateChannel ?? info.updateChannel;
  const expectsAtomicManagedUpdate =
    info.installType === "git" &&
    effectiveChannel === "bleeding-edge" &&
    info.currentCommitSha !== null &&
    info.isManagedService;
  if (info.installType === "git" && !expectsAtomicManagedUpdate) {
    await assertGitCheckoutClean(packageDir, dependencies.execFile);
  }
  const now = dependencies.now();
  const status = createQueuedUpdateStatus(
    info,
    effectiveChannel,
    { id: dependencies.createUpdateId(), now },
  );
  await reserveUpdateLock(config.stateDir, status.id, now);
  try {
    await writeUpdateStatus(config.stateDir, status);
  } catch (error) {
    await releaseUpdateLock(config.stateDir, status.id);
    throw error;
  }
  const cliPath = nodePath.join(packageDir, "dist", "cli.js");
  const env = {
    ...process.env,
    SIDEMESH_CONFIG: config.configPath,
    ...(options.updateChannel
      ? { SIDEMESH_UPDATE_CHANNEL: options.updateChannel }
      : {}),
  };
  const managedService = info.isManagedService
    ? info.serviceName ?? "sidemesh"
    : null;

  if (
    dependencies.platform === "linux" &&
    managedService &&
    !isTermuxEnvironment()
  ) {
    const unitName =
      `sidemesh-self-update-${now.toString(36)}-${status.id.slice(0, 8)}`;
    const args = [
      `--unit=${unitName}`,
      "--collect",
      "--property=KillMode=process",
      "--setenv=SIDEMESH_CONFIG=" + config.configPath,
      ...(options.updateChannel
        ? [`--setenv=SIDEMESH_UPDATE_CHANNEL=${options.updateChannel}`]
        : []),
      process.execPath,
      cliPath,
      "self-update",
      "--config",
      config.configPath,
      "--package-dir",
      packageDir,
      "--managed-service",
      managedService,
      "--update-id",
      status.id,
      "--yes",
    ];
    try {
      await dependencies.execFile("systemd-run", args, {
        encoding: "utf8",
        timeout: 5_000,
      });
      return status;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await markSpawnFailed(config.stateDir, status, message, dependencies.now());
      throw new Error(`[update] systemd-run failed: ${message}`);
    }
  }

  try {
    dependencies.spawnDetached(
      process.execPath,
      [
        cliPath,
        "self-update",
        "--config",
        config.configPath,
        "--package-dir",
        packageDir,
        ...(managedService ? ["--managed-service", managedService] : []),
        "--update-id",
        status.id,
        "--yes",
      ],
      env,
    );
    return status;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await markSpawnFailed(config.stateDir, status, message, dependencies.now());
    throw error;
  }
}

async function markSpawnFailed(
  stateDir: string,
  status: UpdateStatus,
  error: string,
  now: number,
): Promise<void> {
  await patchUpdateStatus(
    stateDir,
    status.id,
    {
      state: "failed",
      phase: "completed",
      finishedAt: now,
      error,
    },
    now,
  ).catch(() => undefined);
  await releaseUpdateLock(stateDir, status.id).catch(() => undefined);
}
