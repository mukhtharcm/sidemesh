import assert from "node:assert/strict";
import { mkdtemp, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import type { InstallInfo } from "./install-info.js";
import {
  assertUpdateLockOwner,
  createQueuedUpdateStatus,
  patchUpdateStatus,
  readUpdateStatus,
  releaseUpdateLock,
  reserveUpdateLock,
  UpdateAlreadyInProgressError,
  updateStatusPath,
  writeUpdateStatus,
} from "./update-status.js";

function installInfo(packageRoot: string): InstallInfo {
  return {
    packageVersion: "0.2.2",
    latestVersion: null,
    currentCommitSha: "a".repeat(40),
    latestCommitSha: "b".repeat(40),
    updateChannel: "bleeding-edge",
    updateAvailable: true,
    packageRoot,
    installType: "git",
    updateSupported: true,
    updateCommand: "unused",
    restoreCommand: null,
    isManagedService: true,
    serviceName: "sidemesh",
  };
}

describe("update status persistence", () => {
  it("writes, reads, and patches private update status atomically", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-update-status-"));
    const queued = createQueuedUpdateStatus(
      installInfo("/opt/sidemesh"),
      "bleeding-edge",
      { id: "update-1", now: 100 },
    );

    await writeUpdateStatus(stateDir, queued);
    const running = await patchUpdateStatus(
      stateDir,
      queued.id,
      { state: "running", phase: "staging", logPath: "/tmp/update.log" },
      200,
    );

    assert.equal(running.startedAt, 100);
    assert.equal(running.updatedAt, 200);
    assert.equal(running.phase, "staging");
    assert.equal(running.cutoverStarted, false);
    assert.deepEqual(await readUpdateStatus(stateDir), running);
    assert.equal((await stat(updateStatusPath(stateDir))).mode & 0o777, 0o600);
  });

  it("defaults legacy status records to no cutover", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-update-status-"));
    const queued = createQueuedUpdateStatus(
      installInfo("/opt/sidemesh"),
      "bleeding-edge",
      { id: "legacy-update", now: 100 },
    );
    const legacy = { ...queued } as Partial<typeof queued>;
    delete legacy.cutoverStarted;
    await writeFile(updateStatusPath(stateDir), `${JSON.stringify(legacy)}\n`);

    assert.equal((await readUpdateStatus(stateDir))?.cutoverStarted, false);
  });

  it("rejects corrupted status files", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-update-status-"));
    await writeFile(updateStatusPath(stateDir), "{}\n");
    await assert.rejects(() => readUpdateStatus(stateDir), /Invalid update status/);
  });
});

describe("update lock ownership", () => {
  it("allows only the owning update to release the lock", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-update-lock-"));
    await reserveUpdateLock(stateDir, "update-1", 100);
    await assertUpdateLockOwner(stateDir, "update-1");
    await assert.rejects(
      () => reserveUpdateLock(stateDir, "update-2", 200),
      (error: unknown) =>
        error instanceof UpdateAlreadyInProgressError &&
        error.updateId === "update-1",
    );

    await releaseUpdateLock(stateDir, "update-2");
    await assertUpdateLockOwner(stateDir, "update-1");
    await releaseUpdateLock(stateDir, "update-1");
    await assert.rejects(
      () => assertUpdateLockOwner(stateDir, "update-1"),
      /does not own the update lock/,
    );
  });

  it("reclaims locks older than the bounded update window", async () => {
    const stateDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-update-lock-"));
    await reserveUpdateLock(stateDir, "stale-update", 100);
    await reserveUpdateLock(stateDir, "new-update", 31 * 60_000);
    await assertUpdateLockOwner(stateDir, "new-update");
  });
});
