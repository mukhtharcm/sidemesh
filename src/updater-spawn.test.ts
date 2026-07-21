import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import type { InstallInfo } from "./install-info.js";
import { spawnSelfUpdater } from "./updater-spawn.js";
import {
  readUpdateStatus,
  releaseUpdateLock,
  reserveUpdateLock,
} from "./update-status.js";
import type { NodeConfig } from "./types.js";

function createConfig(dir: string): NodeConfig {
  return {
    label: "test",
    port: 9999,
    token: "test-token",
    tokenSource: "generated",
    provider: {
      kind: "fake",
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: null,
      capabilityProfile: "full",
    },
    providers: [
      {
        kind: "fake",
        latencyMs: 0,
        seedSessions: false,
        workspaceRoot: null,
        capabilityProfile: "full",
      },
    ],
    defaultProviderKind: "fake",
    updateChannel: "stable",
    stateDir: nodePath.join(dir, "state"),
    workspaceRoots: [],
    terminal: { enabled: false, shell: null, requirePty: false },
    browserPreview: {
      enabled: false,
      chromePath: null,
      maxPreviews: 8,
      idleTtlMs: 3_600_000,
      frameIntervalMs: 900,
      quality: 55,
    },
    configPath: nodePath.join(dir, "config.json"),
    configExists: true,
  };
}

function createInstallInfo(
  packageDir: string,
  options: { managedService?: boolean } = {},
): InstallInfo {
  return {
    packageVersion: "0.1.0",
    latestVersion: "0.2.0",
    currentCommitSha: null,
    latestCommitSha: null,
    updateChannel: "stable",
    updateAvailable: true,
    packageRoot: packageDir,
    installType: "git",
    updateSupported: true,
    updateCommand: "git pull && npm install && npm run build",
    restoreCommand: "git checkout HEAD",
    isManagedService: options.managedService ?? false,
    serviceName: options.managedService === false ? null : "sidemesh",
  };
}

describe("spawnSelfUpdater", () => {
  it("uses unique transient systemd units for managed Linux installs", async () => {
    const config = createConfig(
      await mkdtemp(nodePath.join(tmpdir(), "sidemesh-updater-")),
    );
    const packageDir = "/opt/sidemesh";
    const calls: string[][] = [];
    let preflightCalls = 0;

    const runOnce = async (now: number) => {
      const status = await spawnSelfUpdater(
        config,
        { updateChannel: "bleeding-edge" },
        {
          platform: "linux",
          now: () => now,
          createUpdateId: () => `update-${now}`,
          detectInstallInfo: async () =>
            createInstallInfo(packageDir, { managedService: true }),
          execFile: async (file, args) => {
            if (file === "git") {
              preflightCalls += 1;
              return { stdout: "", stderr: "" };
            }
            assert.equal(file, "systemd-run");
            calls.push(args);
            return { stdout: "", stderr: "" };
          },
          spawnDetached: () => {
            throw new Error("detached fallback should not run");
          },
        },
      );
      await releaseUpdateLock(config.stateDir, status.id);
    };

    await runOnce(1001);
    await runOnce(1002);

    assert.equal(preflightCalls, 2);
    assert.equal(calls.length, 2);
    assert.match(calls[0]![0]!, /^--unit=sidemesh-self-update-/);
    assert.match(calls[1]![0]!, /^--unit=sidemesh-self-update-/);
    assert.notEqual(calls[0]![0], calls[1]![0]);
    assert.ok(calls[0]!.includes("--collect"));
    assert.ok(
      calls[0]!.includes("--setenv=SIDEMESH_UPDATE_CHANNEL=bleeding-edge"),
    );
    assert.ok(calls[0]!.includes("--update-id"));
    assert.ok(calls[0]!.includes("update-1001"));
  });

  it("throws when systemd-run fails for managed Linux installs", async () => {
    const config = createConfig(
      await mkdtemp(nodePath.join(tmpdir(), "sidemesh-updater-")),
    );
    let detachedSpawned = false;

    await assert.rejects(
      () =>
        spawnSelfUpdater(
          config,
          { updateChannel: "bleeding-edge" },
          {
            platform: "linux",
            detectInstallInfo: async () =>
              createInstallInfo("/opt/sidemesh", { managedService: true }),
            execFile: async (file) => {
              if (file === "git") {
                return { stdout: "", stderr: "" };
              }
              throw new Error("Unit sidemesh-self-update.service already exists");
            },
            spawnDetached: () => {
              detachedSpawned = true;
            },
          },
        ),
      /systemd-run failed/,
    );
    assert.equal(detachedSpawned, false);
    const status = await readUpdateStatus(config.stateDir);
    assert.equal(status?.state, "failed");
    assert.match(status?.error ?? "", /already exists/);
    await reserveUpdateLock(config.stateDir, "retry-update");
    await releaseUpdateLock(config.stateDir, "retry-update");
  });

  it("does not block atomic managed updates on tracked checkout changes", async () => {
    const config = createConfig(
      await mkdtemp(nodePath.join(tmpdir(), "sidemesh-updater-")),
    );
    const packageDir = "/opt/sidemesh";
    let gitStatusCalls = 0;
    const status = await spawnSelfUpdater(
      config,
      { updateChannel: "bleeding-edge" },
      {
        platform: "linux",
        createUpdateId: () => "atomic-update",
        detectInstallInfo: async () => ({
          ...createInstallInfo(packageDir, { managedService: true }),
          currentCommitSha: "a".repeat(40),
        }),
        execFile: async (file) => {
          if (file === "git") {
            gitStatusCalls += 1;
            return { stdout: " M package-lock.json\n", stderr: "" };
          }
          assert.equal(file, "systemd-run");
          return { stdout: "", stderr: "" };
        },
        spawnDetached: () => {
          throw new Error("detached fallback should not run");
        },
      },
    );

    assert.equal(gitStatusCalls, 0);
    assert.equal(status.id, "atomic-update");
    await releaseUpdateLock(config.stateDir, status.id);
  });

  it("falls back to a detached child for unmanaged installs", async () => {
    const config = createConfig(
      await mkdtemp(nodePath.join(tmpdir(), "sidemesh-updater-")),
    );
    let spawnedFile: string | null = null;
    let spawnedArgs: string[] | null = null;
    const spawnedEnv: Record<string, string | undefined> = {};

    await spawnSelfUpdater(
      config,
      { updateChannel: "bleeding-edge" },
      {
        platform: "linux",
        createUpdateId: () => "detached-update",
        detectInstallInfo: async () =>
          createInstallInfo("/opt/sidemesh", { managedService: false }),
        execFile: async (file) => {
          if (file === "git") {
            return { stdout: "", stderr: "" };
          }
          throw new Error("systemd-run should not be called");
        },
        spawnDetached: (file, args, env) => {
          spawnedFile = file;
          spawnedArgs = args;
          Object.assign(spawnedEnv, env);
        },
      },
    );

    assert.equal(spawnedFile, process.execPath);
    assert.deepEqual(spawnedArgs, [
      nodePath.join("/opt/sidemesh", "dist", "cli.js"),
      "self-update",
      "--config",
      config.configPath,
      "--package-dir",
      "/opt/sidemesh",
      "--update-id",
      "detached-update",
      "--yes",
    ]);
    assert.equal(spawnedEnv.SIDEMESH_CONFIG, config.configPath);
    assert.equal(spawnedEnv.SIDEMESH_UPDATE_CHANNEL, "bleeding-edge");
  });

  it("uses a detached child for managed Termux installs and preserves the service name", async () => {
    const config = createConfig(
      await mkdtemp(nodePath.join(tmpdir(), "sidemesh-updater-")),
    );
    let spawnedArgs: string[] | null = null;
    const originalPrefix = process.env.PREFIX;

    process.env.PREFIX = "/data/data/com.termux/files/usr";
    try {
      await spawnSelfUpdater(
        config,
        { updateChannel: "bleeding-edge" },
        {
          platform: "linux",
          createUpdateId: () => "termux-update",
          detectInstallInfo: async () =>
            createInstallInfo("/opt/sidemesh", { managedService: true }),
          execFile: async (file) => {
            if (file === "git") {
              return { stdout: "", stderr: "" };
            }
            throw new Error("systemd-run should not be called for Termux");
          },
          spawnDetached: (_file, args) => {
            spawnedArgs = args;
          },
        },
      );
    } finally {
      if (originalPrefix === undefined) {
        delete process.env.PREFIX;
      } else {
        process.env.PREFIX = originalPrefix;
      }
    }

    assert.deepEqual(spawnedArgs, [
      nodePath.join("/opt/sidemesh", "dist", "cli.js"),
      "self-update",
      "--config",
      config.configPath,
      "--package-dir",
      "/opt/sidemesh",
      "--managed-service",
      "sidemesh",
      "--update-id",
      "termux-update",
      "--yes",
    ]);
  });

  it("rejects dirty git installs before spawning an updater", async () => {
    const config = createConfig(
      await mkdtemp(nodePath.join(tmpdir(), "sidemesh-updater-")),
    );
    let systemdRunCalls = 0;
    let detachedCalls = 0;

    await assert.rejects(
      () =>
        spawnSelfUpdater(
          config,
          { updateChannel: "bleeding-edge" },
          {
            platform: "linux",
            detectInstallInfo: async () =>
              createInstallInfo("/opt/sidemesh", { managedService: true }),
            execFile: async (file) => {
              if (file === "git") {
                return {
                  stdout: " M package-lock.json\n",
                  stderr: "",
                };
              }
              systemdRunCalls += 1;
              return { stdout: "", stderr: "" };
            },
            spawnDetached: () => {
              detachedCalls += 1;
            },
          },
        ),
      /Git update blocked by tracked local changes: package-lock\.json/,
    );

    assert.equal(systemdRunCalls, 0);
    assert.equal(detachedCalls, 0);
  });
});
