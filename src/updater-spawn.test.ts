import assert from "node:assert/strict";
import nodePath from "node:path";
import { describe, it } from "node:test";

import type { InstallInfo } from "./install-info.js";
import { spawnSelfUpdater } from "./updater-spawn.js";
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
    const config = createConfig("/tmp/sidemesh-updater");
    const packageDir = "/opt/sidemesh";
    const calls: string[][] = [];

    const runOnce = async (now: number) => {
      await spawnSelfUpdater(
        config,
        { updateChannel: "bleeding-edge" },
        {
          platform: "linux",
          now: () => now,
          detectInstallInfo: async () =>
            createInstallInfo(packageDir, { managedService: true }),
          execFile: async (_file, args) => {
            calls.push(args);
            return { stdout: "", stderr: "" };
          },
          spawnDetached: () => {
            throw new Error("detached fallback should not run");
          },
        },
      );
    };

    await runOnce(1001);
    await runOnce(1002);

    assert.equal(calls.length, 2);
    assert.match(calls[0]![0]!, /^--unit=sidemesh-self-update-/);
    assert.match(calls[1]![0]!, /^--unit=sidemesh-self-update-/);
    assert.notEqual(calls[0]![0], calls[1]![0]);
    assert.ok(calls[0]!.includes("--collect"));
    assert.ok(
      calls[0]!.includes("--setenv=SIDEMESH_UPDATE_CHANNEL=bleeding-edge"),
    );
  });

  it("throws when systemd-run fails for managed Linux installs", async () => {
    const config = createConfig("/tmp/sidemesh-updater");
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
            execFile: async () => {
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
  });

  it("falls back to a detached child for unmanaged installs", async () => {
    const config = createConfig("/tmp/sidemesh-updater");
    let spawnedFile: string | null = null;
    let spawnedArgs: string[] | null = null;
    const spawnedEnv: Record<string, string | undefined> = {};

    await spawnSelfUpdater(
      config,
      { updateChannel: "bleeding-edge" },
      {
        platform: "linux",
        detectInstallInfo: async () =>
          createInstallInfo("/opt/sidemesh", { managedService: false }),
        execFile: async () => {
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
      "--yes",
    ]);
    assert.equal(spawnedEnv.SIDEMESH_CONFIG, config.configPath);
    assert.equal(spawnedEnv.SIDEMESH_UPDATE_CHANNEL, "bleeding-edge");
  });

  it("uses a detached child for managed Termux installs and preserves the service name", async () => {
    const config = createConfig("/tmp/sidemesh-updater");
    let spawnedArgs: string[] | null = null;
    const originalPrefix = process.env.PREFIX;

    process.env.PREFIX = "/data/data/com.termux/files/usr";
    try {
      await spawnSelfUpdater(
        config,
        { updateChannel: "bleeding-edge" },
        {
          platform: "linux",
          detectInstallInfo: async () =>
            createInstallInfo("/opt/sidemesh", { managedService: true }),
          execFile: async () => {
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
      "--yes",
    ]);
  });
});
