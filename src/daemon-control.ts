import { spawn } from "node:child_process";
import { closeSync, openSync, writeSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import nodePath from "node:path";
import { realpathSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";

import {
  inspectDaemon,
  removeDaemonState,
  isPidAlive,
} from "./daemon-lifecycle.js";
import type { NodeConfig } from "./types.js";
import type { RunningServer } from "./server.js";

export interface StartDaemonOptions {
  configPath?: string | null;
}

export interface StopDaemonOptions {
  yes?: boolean;
}

export interface RestartDaemonOptions {
  configPath?: string | null;
  yes?: boolean;
}

export async function assertNoManagedDaemon(config: NodeConfig): Promise<void> {
  const daemon = await inspectDaemon(config);
  if (daemon.pidAlive && daemon.healthReachable) {
    throw new Error(
      `Sidemesh is already running on port ${config.port} as pid ${daemon.state?.pid}. Run \`sidemesh status\`, \`sidemesh restart\`, or use \`sidemesh daemon --allow-duplicate\` only if you know why.`,
    );
  }
  if (daemon.pidAlive && daemon.state) {
    throw new Error(
      `Sidemesh state says pid ${daemon.state.pid} is still alive, but health did not respond. Refusing to start a second instance; run \`sidemesh stop --yes\` or inspect ${daemon.statePath}.`,
    );
  }
  if (daemon.state) {
    await removeDaemonState(config, daemon.state.pid);
  }
  if (daemon.healthReachable) {
    throw new Error(
      `Something is already responding on http://127.0.0.1:${config.port}/healthz. Refusing to start another daemon on the same port.`,
    );
  }
}

export async function startDaemon(
  config: NodeConfig,
  options: StartDaemonOptions = {},
): Promise<void> {
  await assertNoManagedDaemon(config);
  await mkdir(config.stateDir, { recursive: true });
  const logPath = nodePath.join(config.stateDir, "daemon.log");
  const logFd = openSync(logPath, "a");
  try {
    writeSync(logFd, `\n[sidemesh] starting at ${new Date().toISOString()}\n`);
    const invocation = daemonInvocation(options.configPath ?? config.configPath);
    const child = spawn(invocation.command, invocation.args, {
      cwd: process.cwd(),
      detached: true,
      env: {
        ...process.env,
        SIDEMESH_CONFIG: options.configPath ?? config.configPath,
      },
      stdio: ["ignore", logFd, logFd],
    });
    child.unref();

    const started = await waitForDaemonHealth(config.port, 12_000);
    if (!started) {
      throw new Error(
        `Daemon did not become healthy on port ${config.port}. Check ${logPath}.`,
      );
    }
    console.log(`Started Sidemesh daemon on port ${config.port} (pid ${child.pid}).`);
    console.log(`Logs: ${logPath}`);
  } finally {
    closeSync(logFd);
  }
}

export async function stopDaemon(
  config: NodeConfig,
  options: StopDaemonOptions = {},
): Promise<boolean> {
  const daemon = await inspectDaemon(config);
  if (!daemon.state) {
    if (daemon.healthReachable) {
      throw new Error(
        `A daemon responds on port ${config.port}, but no managed state file exists. Stop it manually or inspect the process using that port.`,
      );
    }
    console.log("Sidemesh daemon is not running.");
    return false;
  }
  if (!daemon.pidAlive) {
    await removeDaemonState(config, daemon.state.pid);
    console.log("Removed stale daemon state; no running daemon was found.");
    return false;
  }
  if (daemon.state.pid === process.pid) {
    throw new Error("Refusing to stop the current CLI process.");
  }
  try {
    process.kill(daemon.state.pid, "SIGTERM");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to stop daemon pid ${daemon.state.pid}: ${message}`);
  }
  const stopped = await waitForDaemonStop(config.port, daemon.state.pid, 10_000);
  if (!stopped) {
    throw new Error(
      `Daemon pid ${daemon.state.pid} did not stop within 10s. Inspect it before forcing termination.`,
    );
  }
  await removeDaemonState(config, daemon.state.pid);
  console.log(`Stopped Sidemesh daemon pid ${daemon.state.pid}.`);
  return true;
}

export async function restartDaemon(
  config: NodeConfig,
  options: RestartDaemonOptions = {},
): Promise<void> {
  const daemon = await inspectDaemon(config);
  if (daemon.pidAlive || daemon.healthReachable) {
    await stopDaemon(config, { yes: options.yes });
  } else if (daemon.state) {
    await removeDaemonState(config, daemon.state.pid);
  }
  await startDaemon(config, { configPath: options.configPath ?? config.configPath });
}

export function daemonInvocation(configPath: string): { command: string; args: string[] } {
  const entry = process.argv[1] ? realPathOrResolve(process.argv[1]) : "";
  const args =
    entry.endsWith(".ts")
      ? ["--import", "tsx", entry, "daemon"]
      : [entry, "daemon"];
  args.push("--config", configPath);
  return { command: process.execPath, args };
}

export async function waitForDaemonHealth(
  port: number,
  timeoutMs: number,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await checkHealth(`http://127.0.0.1:${port}/healthz`)) {
      return true;
    }
    await delay(250);
  }
  return false;
}

export async function waitForDaemonStop(
  port: number,
  pid: number,
  timeoutMs: number,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const alive = isPidAlive(pid);
    const reachable = await checkHealth(`http://127.0.0.1:${port}/healthz`);
    if (!alive && !reachable) {
      return true;
    }
    await delay(250);
  }
  return false;
}

export async function checkHealth(url: string): Promise<boolean> {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(1500) });
    return response.ok;
  } catch {
    return false;
  }
}

export function registerShutdownHandlers(
  config: NodeConfig,
  getServer: () => RunningServer | null,
): void {
  let shuttingDown = false;
  const shutdown = (signal: NodeJS.Signals) => {
    if (shuttingDown) return;
    shuttingDown = true;
    void (async () => {
      try {
        await closeWithDeadline(getServer(), 8_000);
      } finally {
        await removeDaemonState(config, process.pid).catch(() => undefined);
        process.exit(signal === "SIGINT" ? 130 : 0);
      }
    })();
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

async function closeWithDeadline(
  server: RunningServer | null,
  timeoutMs: number,
): Promise<void> {
  if (!server) return;
  let timeout: NodeJS.Timeout | null = null;
  try {
    await Promise.race([
      server.close(),
      new Promise<void>((resolve) => {
        timeout = setTimeout(resolve, timeoutMs);
        timeout.unref?.();
      }),
    ]);
  } finally {
    if (timeout) {
      clearTimeout(timeout);
    }
  }
}

function realPathOrResolve(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return nodePath.resolve(path);
  }
}
