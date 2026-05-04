import { execFile } from "node:child_process";
import { access, cp, mkdir, rm, writeFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import nodePath from "node:path";
import { promisify } from "node:util";
import { setTimeout as delay } from "node:timers/promises";

import type { NodeConfig } from "./types.js";
import { detectInstallInfo, type InstallInfo } from "./install-info.js";
import {
  startDaemon,
  stopDaemon,
  waitForDaemonHealth,
} from "./daemon-control.js";

const execFileAsync = promisify(execFile);

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

export async function runSelfUpdate(
  options: SelfUpdateOptions,
): Promise<SelfUpdateResult> {
  const { config, dryRun = false } = options;
  const requestedPackageDir = options.packageDir?.trim() || undefined;
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
    const info = await detectInstallInfo({
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

    if (dryRun) {
      await appendLog(logPath, `[dry-run] Would run: ${info.updateCommand}`);
      return {
        success: true,
        oldVersion,
        newVersion: oldVersion,
        restored: false,
        logPath,
        error: null,
      };
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

    const managedService = options.managedService;

    try {
      await appendLog(logPath, `[self-update] Stopping daemon...`);
      if (managedService) {
        await execFileAsync(
          "systemctl",
          ["stop", `${managedService}.service`],
          { encoding: "utf8", timeout: 15_000 },
        );
        await appendLog(
          logPath,
          `[self-update] Stopped systemd service ${managedService}.service`,
        );
        await delay(1000);
      } else {
        const stopped = await stopDaemon(config, { yes: true });
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

      const newCliPath = nodePath.join(packageDir, "dist", "cli.js");
      const newCliExists = await pathExists(newCliPath);
      if (!newCliExists) {
        throw new Error(`Compiled CLI not found at ${newCliPath} after update.`);
      }

      await appendLog(logPath, `[self-update] Starting daemon...`);
      if (managedService) {
        await execFileAsync(
          "systemctl",
          ["start", `${managedService}.service`],
          { encoding: "utf8", timeout: 15_000 },
        );
        await appendLog(
          logPath,
          `[self-update] Started systemd service ${managedService}.service`,
        );
      } else {
        await startDaemon(config, { configPath: config.configPath });
      }

      await appendLog(logPath, `[self-update] Waiting for healthz...`);
      const healthy = await waitForDaemonHealth(config.port, 15_000);
      if (!healthy) {
        throw new Error("Daemon did not become healthy within 15s after update.");
      }

      const newInfo = await detectInstallInfo({
        packageRoot: packageDir,
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
          await execFileAsync(
            "systemctl",
            ["start", `${managedService}.service`],
            { encoding: "utf8", timeout: 15_000 },
          );
        } else {
          await startDaemon(config, { configPath: config.configPath });
        }
        const healthy = await waitForDaemonHealth(config.port, 15_000);
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
  await runShellCommand(info.updateCommand, packageDir, logPath, 120_000);
}

async function runShellCommand(
  command: string,
  packageDir: string,
  logPath: string,
  timeout: number,
): Promise<void> {
  const shell = process.env.SHELL || "/bin/sh";
  await appendLog(logPath, `[self-update] $ ${command}`);

  try {
    const { stdout, stderr } = await execFileAsync(shell, ["-c", command], {
      cwd: packageDir,
      timeout,
      encoding: "utf8",
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
