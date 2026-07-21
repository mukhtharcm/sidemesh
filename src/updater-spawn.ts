import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import nodePath from "node:path";

import { isTermuxEnvironment } from "./host-environment.js";
import { detectInstallInfo } from "./install-info.js";
import type { NodeConfig, UpdateChannel } from "./types.js";
import { assertGitCheckoutClean } from "./update-preflight.js";

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
  platform: process.platform,
};

export async function spawnSelfUpdater(
  config: NodeConfig,
  options: { updateChannel?: UpdateChannel | null } = {},
  dependencyOverrides: Partial<UpdaterSpawnDependencies> = {},
): Promise<void> {
  const dependencies = {
    ...DEFAULT_UPDATER_SPAWN_DEPENDENCIES,
    ...dependencyOverrides,
  } satisfies UpdaterSpawnDependencies;
  const info = await dependencies.detectInstallInfo({ config });
  const packageDir = info.packageRoot;
  if (info.installType === "git") {
    await assertGitCheckoutClean(packageDir, dependencies.execFile);
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
    const unitName = `sidemesh-self-update-${dependencies.now().toString(36)}`;
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
      "--yes",
    ];
    try {
      await dependencies.execFile("systemd-run", args, {
        encoding: "utf8",
        timeout: 5_000,
      });
      return;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new Error(`[update] systemd-run failed: ${message}`);
    }
  }

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
      "--yes",
    ],
    env,
  );
}
