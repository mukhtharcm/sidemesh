import { randomUUID } from "node:crypto";
import {
  chmod,
  link,
  mkdir,
  readFile,
  rename,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import nodePath from "node:path";

import type { InstallInfo } from "./install-info.js";
import type { UpdateChannel } from "./types.js";

const UPDATE_STATUS_VERSION = 1;
const UPDATE_LOCK_STALE_MS = 30 * 60_000;

export type UpdateExecutionState =
  | "queued"
  | "running"
  | "succeeded"
  | "failed";

export type UpdatePhase =
  | "queued"
  | "preflight"
  | "staging"
  | "stopping"
  | "switching"
  | "starting"
  | "verifying"
  | "rolling_back"
  | "completed";

export interface UpdateStatus {
  version: 1;
  id: string;
  state: UpdateExecutionState;
  phase: UpdatePhase;
  channel: UpdateChannel;
  startedAt: number;
  updatedAt: number;
  finishedAt: number | null;
  previousVersion: string;
  previousCommitSha: string | null;
  targetVersion: string | null;
  targetCommitSha: string | null;
  installedVersion: string | null;
  installedCommitSha: string | null;
  restored: boolean;
  error: string | null;
  logPath: string | null;
}

interface UpdateLock {
  id: string;
  startedAt: number;
}

export class UpdateAlreadyInProgressError extends Error {
  constructor(readonly updateId: string | null) {
    super(
      updateId
        ? `Update ${updateId} is already in progress`
        : "An update is already in progress",
    );
    this.name = "UpdateAlreadyInProgressError";
  }
}

export function createQueuedUpdateStatus(
  info: InstallInfo,
  channel: UpdateChannel,
  options: { id?: string; now?: number } = {},
): UpdateStatus {
  const now = options.now ?? Date.now();
  return {
    version: UPDATE_STATUS_VERSION,
    id: options.id ?? randomUUID(),
    state: "queued",
    phase: "queued",
    channel,
    startedAt: now,
    updatedAt: now,
    finishedAt: null,
    previousVersion: info.packageVersion,
    previousCommitSha: info.currentCommitSha,
    targetVersion: info.latestVersion,
    targetCommitSha: info.latestCommitSha,
    installedVersion: null,
    installedCommitSha: null,
    restored: false,
    error: null,
    logPath: null,
  };
}

export function updateStatusPath(stateDir: string): string {
  return nodePath.join(stateDir, "update-status.json");
}

export async function readUpdateStatus(
  stateDir: string,
): Promise<UpdateStatus | null> {
  try {
    const raw = await readFile(updateStatusPath(stateDir), "utf8");
    return parseUpdateStatus(JSON.parse(raw) as unknown);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

export async function writeUpdateStatus(
  stateDir: string,
  status: UpdateStatus,
): Promise<void> {
  await mkdir(stateDir, { recursive: true, mode: 0o700 });
  const path = updateStatusPath(stateDir);
  const tempPath = `${path}.${randomUUID()}.tmp`;
  await writeFile(tempPath, `${JSON.stringify(status, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  await rename(tempPath, path);
  await chmod(path, 0o600).catch(() => undefined);
}

export async function patchUpdateStatus(
  stateDir: string,
  updateId: string,
  patch: Partial<Omit<UpdateStatus, "version" | "id" | "startedAt">>,
  now = Date.now(),
): Promise<UpdateStatus> {
  const current = await readUpdateStatus(stateDir);
  if (!current || current.id !== updateId) {
    throw new Error(`Update status ${updateId} is unavailable`);
  }
  const next: UpdateStatus = {
    ...current,
    ...patch,
    version: UPDATE_STATUS_VERSION,
    id: current.id,
    startedAt: current.startedAt,
    updatedAt: now,
  };
  await writeUpdateStatus(stateDir, next);
  return next;
}

export async function reserveUpdateLock(
  stateDir: string,
  updateId: string,
  now = Date.now(),
): Promise<void> {
  await mkdir(stateDir, { recursive: true, mode: 0o700 });
  const path = updateLockPath(stateDir);
  const lock: UpdateLock = { id: updateId, startedAt: now };
  try {
    await writeFile(path, `${JSON.stringify(lock)}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    return;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
      throw error;
    }
  }

  const existing = await readUpdateLock(path);
  if (existing.lock?.id === updateId) {
    return;
  }
  const staleSince = existing.lock?.startedAt ?? existing.mtimeMs;
  if (staleSince !== null && now - staleSince > UPDATE_LOCK_STALE_MS) {
    const stalePath = `${path}.stale-${randomUUID()}`;
    try {
      await rename(path, stalePath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        await reserveUpdateLock(stateDir, updateId, now);
        return;
      }
      throw error;
    }
    const moved = await readUpdateLock(stalePath);
    if (!sameUpdateLock(existing, moved)) {
      await restoreMovedLock(stalePath, path, moved);
      throw new UpdateAlreadyInProgressError(moved.lock?.id ?? null);
    }
    await rm(stalePath, { force: true });
    await reserveUpdateLock(stateDir, updateId, now);
    return;
  }
  throw new UpdateAlreadyInProgressError(existing.lock?.id ?? null);
}

export async function assertUpdateLockOwner(
  stateDir: string,
  updateId: string,
): Promise<void> {
  const { lock } = await readUpdateLock(updateLockPath(stateDir));
  if (!lock || lock.id !== updateId) {
    throw new Error(`Update ${updateId} does not own the update lock`);
  }
}

export async function releaseUpdateLock(
  stateDir: string,
  updateId: string,
): Promise<void> {
  const path = updateLockPath(stateDir);
  const existing = await readUpdateLock(path);
  const { lock } = existing;
  if (lock?.id === updateId) {
    const releasePath = `${path}.release-${randomUUID()}`;
    try {
      await rename(path, releasePath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        return;
      }
      throw error;
    }
    const moved = await readUpdateLock(releasePath);
    if (sameUpdateLock(existing, moved)) {
      await rm(releasePath, { force: true });
    } else {
      await restoreMovedLock(releasePath, path, moved);
    }
  }
}

function updateLockPath(stateDir: string): string {
  return nodePath.join(stateDir, "update.lock");
}

async function readUpdateLock(
  path: string,
): Promise<{ lock: UpdateLock | null; mtimeMs: number | null }> {
  try {
    const [raw, metadata] = await Promise.all([
      readFile(path, "utf8"),
      stat(path),
    ]);
    const value = JSON.parse(raw) as unknown;
    if (
      typeof value === "object" &&
      value !== null &&
      typeof (value as { id?: unknown }).id === "string" &&
      typeof (value as { startedAt?: unknown }).startedAt === "number"
    ) {
      return { lock: value as UpdateLock, mtimeMs: metadata.mtimeMs };
    }
    return { lock: null, mtimeMs: metadata.mtimeMs };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return { lock: null, mtimeMs: null };
    }
    if (error instanceof SyntaxError) {
      const metadata = await stat(path).catch(() => null);
      return { lock: null, mtimeMs: metadata?.mtimeMs ?? null };
    }
    throw error;
  }
}

function sameUpdateLock(
  left: { lock: UpdateLock | null; mtimeMs: number | null },
  right: { lock: UpdateLock | null; mtimeMs: number | null },
): boolean {
  if (left.lock && right.lock) {
    return left.lock.id === right.lock.id &&
      left.lock.startedAt === right.lock.startedAt;
  }
  return left.lock === null && right.lock === null &&
    left.mtimeMs !== null && left.mtimeMs === right.mtimeMs;
}

async function restoreMovedLock(
  movedPath: string,
  lockPath: string,
  moved: { lock: UpdateLock | null; mtimeMs: number | null },
): Promise<void> {
  try {
    await link(movedPath, lockPath);
    await rm(movedPath, { force: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") {
      throw error;
    }
    const current = await readUpdateLock(lockPath);
    if (sameUpdateLock(moved, current)) {
      await rm(movedPath, { force: true });
    }
  }
}

function parseUpdateStatus(value: unknown): UpdateStatus {
  if (typeof value !== "object" || value === null) {
    throw new Error("Invalid update status: expected an object");
  }
  const status = value as Partial<UpdateStatus>;
  if (
    status.version !== UPDATE_STATUS_VERSION ||
    typeof status.id !== "string" ||
    !isExecutionState(status.state) ||
    !isUpdatePhase(status.phase) ||
    (status.channel !== "stable" && status.channel !== "bleeding-edge") ||
    typeof status.startedAt !== "number" ||
    typeof status.updatedAt !== "number" ||
    !isNullableNumber(status.finishedAt) ||
    typeof status.previousVersion !== "string" ||
    !isNullableString(status.previousCommitSha) ||
    !isNullableString(status.targetVersion) ||
    !isNullableString(status.targetCommitSha) ||
    !isNullableString(status.installedVersion) ||
    !isNullableString(status.installedCommitSha) ||
    typeof status.restored !== "boolean" ||
    !isNullableString(status.error) ||
    !isNullableString(status.logPath)
  ) {
    throw new Error("Invalid update status: missing required fields");
  }
  return status as UpdateStatus;
}

function isNullableString(value: unknown): value is string | null {
  return value === null || typeof value === "string";
}

function isNullableNumber(value: unknown): value is number | null {
  return value === null || typeof value === "number";
}

function isExecutionState(value: unknown): value is UpdateExecutionState {
  return value === "queued" || value === "running" ||
    value === "succeeded" || value === "failed";
}

function isUpdatePhase(value: unknown): value is UpdatePhase {
  return value === "queued" || value === "preflight" || value === "staging" ||
    value === "stopping" || value === "switching" || value === "starting" ||
    value === "verifying" || value === "rolling_back" || value === "completed";
}
