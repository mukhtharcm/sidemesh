import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import nodePath from "node:path";

import { detectInstallInfo } from "./install-info.js";
import type { NodeConfig } from "./types.js";

const execFileAsync = promisify(execFile);

export async function spawnSelfUpdater(config: NodeConfig): Promise<void> {
  const info = await detectInstallInfo();
  const packageDir = info.packageRoot;
  const cliPath = nodePath.join(packageDir, "dist", "cli.js");

  if (process.platform === "linux" && info.isManagedService) {
    const args = [
      "--unit=sidemesh-self-update",
      "--remain-after-exit",
      "--property=KillMode=process",
      "--setenv=SIDEMESH_CONFIG=" + config.configPath,
      process.execPath,
      cliPath,
      "self-update",
      "--config",
      config.configPath,
      "--package-dir",
      packageDir,
      "--managed-service",
      info.serviceName ?? "sidemesh",
      "--yes",
    ];
    try {
      await execFileAsync("systemd-run", args, {
        encoding: "utf8",
        timeout: 5_000,
      });
      return;
    } catch {
      console.error("[update] systemd-run failed, falling back to detached spawn");
    }
  }

  const child = spawn(process.execPath, [
    cliPath,
    "self-update",
    "--config",
    config.configPath,
    "--package-dir",
    packageDir,
    "--yes",
  ], {
    detached: true,
    stdio: ["ignore", "ignore", "ignore"],
    env: {
      ...process.env,
      SIDEMESH_CONFIG: config.configPath,
    },
  });
  child.unref();
}
