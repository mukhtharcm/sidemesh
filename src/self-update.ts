import { execFile } from "node:child_process";
import { access, cp, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { tmpdir } from "node:os";
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

export async function runSelfUpdate(options: SelfUpdateOptions): Promise<SelfUpdateResult> {
  const { config, dryRun = false } = options;
  const packageDir = options.packageDir ?? config.stateDir;
  const logDir = nodePath.join(config.stateDir, "logs");
  await mkdir(logDir, { recursive: true });
  const logPath = nodePath.join(logDir, `self-update-${Date.now()}.log`);

  const info = await detectInstallInfo(packageDir);
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
  await appendLog(logPath, `[self-update] Package dir: ${packageDir}`);

  const managedService = options.managedService;
  
  try {
    // 1. Stop the daemon
    await appendLog(logPath, `[self-update] Stopping daemon...`);
    if (managedService) {
      await execFileAsync("systemctl", ["stop", `${managedService}.service`], { encoding: "utf8", timeout: 15_000 });
      await appendLog(logPath, `[self-update] Stopped systemd service ${managedService}.service`);
      await delay(1000);
    } else {
      const stopped = await stopDaemon(config, { yes: true });
      if (!stopped) {
        await appendLog(logPath, `[self-update] Daemon was not running, continuing anyway.`);
      }
      await delay(500);
    }

    // 2. Backup dist/
    const distPath = nodePath.join(packageDir, "dist");
    const backupPath = nodePath.join(config.stateDir, "dist-backup-v1");
    await appendLog(logPath, `[self-update] Backing up dist to ${backupPath}...`);
    await rm(backupPath, { recursive: true, force: true });
    const distExists = await pathExists(distPath);
    if (distExists) {
      await cp(distPath, backupPath, { recursive: true, preserveTimestamps: true });
    }

    // 3. Run the update command
    await appendLog(logPath, `[self-update] Running update...`);
    await runUpdateCommand(info, packageDir, logPath);

    // 4. Build (git only)
    if (info.installType === "git") {
      await appendLog(logPath, `[self-update] Building...`);
      await runBuildCommand(packageDir, logPath);
    }

    // 5. Verify new binary exists
    const newCliPath = nodePath.join(packageDir, "dist", "cli.js");
    const newCliExists = await pathExists(newCliPath);
    if (!newCliExists) {
      throw new Error(`Compiled CLI not found at ${newCliPath} after update.`);
    }

    // 6. Start the daemon
    await appendLog(logPath, `[self-update] Starting daemon...`);
    if (managedService) {
      await execFileAsync("systemctl", ["start", `${managedService}.service`], { encoding: "utf8", timeout: 15_000 });
      await appendLog(logPath, `[self-update] Started systemd service ${managedService}.service`);
    } else {
      await startDaemon(config, { configPath: config.configPath });
    }

    // 7. Wait for healthz
    await appendLog(logPath, `[self-update] Waiting for healthz...`);
    const healthy = await waitForDaemonHealth(config.port, 15_000);
    if (!healthy) {
      throw new Error("Daemon did not become healthy within 15s after update.");
    }

    // 8. Read new version
    const newInfo = await detectInstallInfo(packageDir);
    await appendLog(logPath, `[self-update] Success! Updated ${oldVersion} → ${newInfo.packageVersion}`);

    // 9. Remove backup
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

    // Try to restore
    await appendLog(logPath, `[self-update] Restoring backup...`);
    const backupPath = nodePath.join(config.stateDir, "dist-backup-v1");
    const distPath = nodePath.join(packageDir, "dist");
    const backupExists = await pathExists(backupPath);
    if (backupExists) {
      await rm(distPath, { recursive: true, force: true });
      await cp(backupPath, distPath, { recursive: true, preserveTimestamps: true });
      await rm(backupPath, { recursive: true, force: true });
      await appendLog(logPath, `[self-update] Backup restored.`);
    }

    // Try to start the old daemon
    try {
      await appendLog(logPath, `[self-update] Starting old daemon...`);
      if (managedService) {
        await execFileAsync("systemctl", ["start", `${managedService}.service`], { encoding: "utf8", timeout: 15_000 });
      } else {
        await startDaemon(config, { configPath: config.configPath });
      }
      const healthy = await waitForDaemonHealth(config.port, 15_000);
      if (!healthy) {
        await appendLog(logPath, `[self-update] WARNING: Old daemon did not become healthy.`);
      }
    } catch (startError) {
      const startMessage = startError instanceof Error ? startError.message : String(startError);
      await appendLog(logPath, `[self-update] WARNING: Failed to start old daemon: ${startMessage}`);
    }

    return {
      success: false,
      oldVersion,
      newVersion: null,
      restored: backupExists,
      logPath,
      error: message,
    };
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

  const shell = process.env.SHELL || "/bin/sh";
  await appendLog(logPath, `[self-update] $ ${info.updateCommand}`);

  try {
    const { stdout, stderr } = await execFileAsync(shell, ["-c", info.updateCommand], {
      cwd: packageDir,
      timeout: 120_000,
      encoding: "utf8",
    });
    if (stdout) await appendLog(logPath, stdout);
    if (stderr) await appendLog(logPath, stderr);
  } catch (error) {
    const typed = error as { stdout?: string; stderr?: string; message?: string };
    if (typed.stdout) await appendLog(logPath, typed.stdout);
    if (typed.stderr) await appendLog(logPath, typed.stderr);
    throw new Error(typed.message || "Update command failed.");
  }
}

async function runBuildCommand(packageDir: string, logPath: string): Promise<void> {
  const buildCmd = "npm run build";
  const shell = process.env.SHELL || "/bin/sh";
  await appendLog(logPath, `[self-update] $ ${buildCmd}`);

  try {
    const { stdout, stderr } = await execFileAsync(shell, ["-c", buildCmd], {
      cwd: packageDir,
      timeout: 120_000,
      encoding: "utf8",
    });
    if (stdout) await appendLog(logPath, stdout);
    if (stderr) await appendLog(logPath, stderr);
  } catch (error) {
    const typed = error as { stdout?: string; stderr?: string; message?: string };
    if (typed.stdout) await appendLog(logPath, typed.stdout);
    if (typed.stderr) await appendLog(logPath, typed.stderr);
    throw new Error(typed.message || "Build command failed.");
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
