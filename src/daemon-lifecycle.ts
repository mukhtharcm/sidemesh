import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

import type { NodeConfig } from "./types.js";

const DAEMON_STATE_FILE = "daemon-state-v1.json";

export interface DaemonState {
  pid: number;
  port: number;
  label: string;
  configPath: string;
  stateDir: string;
  startedAt: number;
  command: string[];
}

export interface DaemonInspection {
  statePath: string;
  state: DaemonState | null;
  pidAlive: boolean;
  healthReachable: boolean;
}

export function daemonStatePath(config: Pick<NodeConfig, "stateDir">): string {
  return join(config.stateDir, DAEMON_STATE_FILE);
}

export async function inspectDaemon(
  config: Pick<NodeConfig, "stateDir" | "port">,
): Promise<DaemonInspection> {
  const statePath = daemonStatePath(config);
  const state = await readDaemonStatePath(statePath);
  return {
    statePath,
    state,
    pidAlive: state ? isPidAlive(state.pid) : false,
    healthReachable: await checkHealth(config.port),
  };
}

export async function writeDaemonState(
  config: Pick<NodeConfig, "stateDir">,
  state: DaemonState,
): Promise<void> {
  await mkdir(config.stateDir, { recursive: true });
  await writeFile(daemonStatePath(config), `${JSON.stringify(state, null, 2)}\n`, {
    mode: 0o600,
  });
}

export async function removeDaemonState(
  config: Pick<NodeConfig, "stateDir">,
  expectedPid?: number | null,
): Promise<void> {
  const statePath = daemonStatePath(config);
  if (expectedPid !== undefined && expectedPid !== null) {
    const state = await readDaemonStatePath(statePath);
    if (state && state.pid !== expectedPid) {
      return;
    }
  }
  await rm(statePath, { force: true });
}

export function isPidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

async function readDaemonStatePath(path: string): Promise<DaemonState | null> {
  let raw: string;
  try {
    raw = await readFile(path, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return null;
    }
    throw error;
  }
  try {
    const parsed = JSON.parse(raw) as Partial<DaemonState>;
    if (
      typeof parsed.pid !== "number" ||
      typeof parsed.port !== "number" ||
      typeof parsed.label !== "string" ||
      typeof parsed.configPath !== "string" ||
      typeof parsed.stateDir !== "string" ||
      typeof parsed.startedAt !== "number" ||
      !Array.isArray(parsed.command)
    ) {
      return null;
    }
    return {
      pid: Math.trunc(parsed.pid),
      port: Math.trunc(parsed.port),
      label: parsed.label,
      configPath: parsed.configPath,
      stateDir: parsed.stateDir,
      startedAt: parsed.startedAt,
      command: parsed.command.map((item) => String(item)),
    };
  } catch {
    return null;
  }
}

async function checkHealth(port: number): Promise<boolean> {
  try {
    const response = await fetch(`http://127.0.0.1:${port}/healthz`, {
      signal: AbortSignal.timeout(1500),
    });
    return response.ok;
  } catch {
    return false;
  }
}
