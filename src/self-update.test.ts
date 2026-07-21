import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import { detectInstallInfo, type InstallInfo } from "./install-info.js";
import { runSelfUpdate } from "./self-update.js";
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
    configExists: false,
  };
}

function createInstallInfo(
  packageRoot: string,
  updateChannel: NodeConfig["updateChannel"] = "stable",
): InstallInfo {
  return {
    packageVersion: "0.1.0",
    latestVersion: "0.2.0",
    currentCommitSha: null,
    latestCommitSha: null,
    updateChannel,
    updateAvailable: true,
    packageRoot,
    installType: "npm-global",
    updateSupported: true,
    updateCommand: null,
    restoreCommand: null,
    isManagedService: true,
    serviceName: "sidemesh",
  };
}

describe("runSelfUpdate", () => {
  it("returns unsupported for npm-local install", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const nested = nodePath.join(dir, "node_modules", "sidemesh");
    await mkdir(nested, { recursive: true });
    await writeFile(
      nodePath.join(nested, "package.json"),
      JSON.stringify({ name: "sidemesh", version: "0.1.0" }),
    );

    const result = await runSelfUpdate({
      config: createConfig(dir),
      packageDir: nested,
      dryRun: true,
    });

    assert.equal(result.success, true); // dry-run succeeds
    assert.equal(result.oldVersion, "0.1.0");
  });

  it("returns unsupported for unknown install", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const result = await runSelfUpdate({
      config: createConfig(dir),
      packageDir: dir,
      dryRun: false,
    });

    assert.equal(result.success, false);
    assert.ok(result.error?.includes("not supported"));
  });

  it("prefers SIDEMESH_UPDATE_CHANNEL over the persisted config", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const packageDir = nodePath.join(dir, "package");
    const seenChannels: NodeConfig["updateChannel"][] = [];
    const originalChannel = process.env.SIDEMESH_UPDATE_CHANNEL;
    process.env.SIDEMESH_UPDATE_CHANNEL = "bleeding-edge";

    const detectInstallInfoOverride: typeof detectInstallInfo = async (
      packageRootOrOptions = {},
    ) => {
      const options =
        typeof packageRootOrOptions === "string"
          ? { packageRoot: packageRootOrOptions }
          : packageRootOrOptions;
      const updateChannel = options.config?.updateChannel ?? "stable";
      seenChannels.push(updateChannel);
      return {
        ...createInstallInfo(options.packageRoot ?? packageDir, updateChannel),
        updateCommand: "npm update -g sidemesh",
      };
    };

    try {
      const result = await runSelfUpdate(
        {
          config: createConfig(dir),
          packageDir,
          dryRun: true,
        },
        {
          detectInstallInfo: detectInstallInfoOverride,
        },
      );

      assert.equal(result.success, true);
      assert.deepEqual(seenChannels, ["bleeding-edge"]);

      const log = await readFile(result.logPath, "utf8");
      assert.match(log, /Update channel: bleeding-edge/);
    } finally {
      if (originalChannel === undefined) {
        delete process.env.SIDEMESH_UPDATE_CHANNEL;
      } else {
        process.env.SIDEMESH_UPDATE_CHANNEL = originalChannel;
      }
    }
  });

  it("prepends the running node directory to PATH for update commands", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const packageDir = nodePath.join(dir, "package");
    const config = createConfig(dir);
    const pathCapture = nodePath.join(dir, "path.txt");
    const originalPath = process.env.PATH;

    await mkdir(nodePath.join(packageDir, "dist"), { recursive: true });
    await writeFile(nodePath.join(packageDir, "dist", "cli.js"), "#!/usr/bin/env node\n");

    process.env.PATH = "";
    try {
      const result = await runSelfUpdate(
        {
          config,
          packageDir,
        },
        {
          detectInstallInfo: async () => ({
            ...createInstallInfo(packageDir),
            installType: "git",
            updateCommand: `node -e 'require("node:fs").writeFileSync(${JSON.stringify(
              pathCapture,
            )}, process.env.PATH ?? "")'`,
          }),
          stopDaemon: async () => true,
          startDaemon: async () => undefined,
          waitForDaemonHealth: async () => true,
          resolveUpdatedPackageDir: async () => packageDir,
          runCommand: async (file, args) => {
            assert.equal(file, "git");
            assert.deepEqual(args, [
              "status",
              "--porcelain=v1",
              "--untracked-files=no",
            ]);
            return { stdout: "", stderr: "" };
          },
        },
      );

      assert.equal(result.success, true);
      const capturedPath = await readFile(pathCapture, "utf8");
      assert.ok(
        capturedPath.split(nodePath.delimiter).includes(nodePath.dirname(process.execPath)),
      );
    } finally {
      if (originalPath === undefined) {
        delete process.env.PATH;
      } else {
        process.env.PATH = originalPath;
      }
    }
  });

  it("rejects tracked git changes before stopping the daemon", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const packageDir = nodePath.join(dir, "package");
    const config = createConfig(dir);
    let stopCalls = 0;
    let startCalls = 0;

    const result = await runSelfUpdate(
      {
        config,
        packageDir,
      },
      {
        detectInstallInfo: async () => ({
          ...createInstallInfo(packageDir),
          installType: "git",
          currentCommitSha: "a".repeat(40),
          latestCommitSha: "b".repeat(40),
          updateCommand: "should not run",
          restoreCommand: `git checkout ${"a".repeat(40)}`,
        }),
        runCommand: async (file, args) => {
          assert.equal(file, "git");
          assert.deepEqual(args, [
            "status",
            "--porcelain=v1",
            "--untracked-files=no",
          ]);
          return {
            stdout: " M package-lock.json\nM  src/local-change.ts\n",
            stderr: "",
          };
        },
        stopDaemon: async () => {
          stopCalls += 1;
          return true;
        },
        startDaemon: async () => {
          startCalls += 1;
        },
      },
    );

    assert.equal(result.success, false);
    assert.equal(result.restored, false);
    assert.equal(stopCalls, 0);
    assert.equal(startCalls, 0);
    assert.match(result.error ?? "", /package-lock\.json/);
    assert.match(result.error ?? "", /src\/local-change\.ts/);
    assert.match(result.error ?? "", /did not stop the daemon/);

    const log = await readFile(result.logPath, "utf8");
    assert.match(log, /Git update blocked by tracked local changes/);
  });

  it("reinstalls a stale managed service wrapper after update", {
    skip: process.platform !== "linux",
  }, async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const packageDir = nodePath.join(dir, "package");
    const config = createConfig(dir);
    await mkdir(nodePath.join(packageDir, "dist"), { recursive: true });
    await writeFile(nodePath.join(packageDir, "dist", "cli.js"), "#!/usr/bin/env node\n");

    const installCalls: Array<Record<string, unknown>> = [];
    const commandCalls: Array<{ file: string; args: string[] }> = [];
    let detectCalls = 0;

    const result = await runSelfUpdate(
      {
        config,
        packageDir,
        managedService: "sidemesh",
      },
      {
        detectInstallInfo: async () => {
          detectCalls += 1;
          return createInstallInfo(packageDir);
        },
        waitForDaemonHealth: async () => true,
        resolveUpdatedPackageDir: async () => packageDir,
        runCommand: async (file, args) => {
          commandCalls.push({ file, args });
          return { stdout: "", stderr: "" };
        },
        resolveInstalledServicePaths: async (options) => ({
          serviceName: options.serviceName ?? "sidemesh",
          packageDir: options.packageDir,
          nodeBin: options.nodeBin,
          unitPath: nodePath.join(dir, "sidemesh.service"),
          envPath: nodePath.join(dir, "sidemesh.env"),
          launcherPath: nodePath.join(dir, "sidemesh.sh"),
        }),
        isSystemdServiceEnabled: async () => true,
        readSystemdUnitLimits: async () => ({ memoryHigh: "2G", memoryMax: null }),
        isSystemdServiceWrapperStale: async () => true,
        installSystemdService: async (_config, options) => {
          installCalls.push(options as unknown as Record<string, unknown>);
          return {
            serviceName: options.serviceName ?? "sidemesh",
            packageDir: options.packageDir,
            nodeBin: options.nodeBin,
            unitPath: options.unitPath ?? nodePath.join(dir, "sidemesh.service"),
            envPath: options.envPath ?? nodePath.join(dir, "sidemesh.env"),
            launcherPath: options.launcherPath ?? nodePath.join(dir, "sidemesh.sh"),
          };
        },
      },
    );

    assert.equal(result.success, true);
    assert.equal(detectCalls, 2);
    assert.equal(installCalls.length, 1);
    assert.equal(installCalls[0]?.start, false);
    assert.equal(installCalls[0]?.memoryHigh, "2G");
    assert.equal(installCalls[0]?.serviceName, "sidemesh");
    assert.deepEqual(
      commandCalls.map(({ file, args }) => `${file} ${args.join(" ")}`),
      [
        "systemctl stop sidemesh.service",
        "systemctl start sidemesh.service",
      ],
    );

    const log = await readFile(result.logPath, "utf8");
    assert.match(log, /Service wrapper is stale, will reinstall sidemesh\.service/);
    assert.match(log, /Reinstalled managed service wrapper sidemesh\.service/);
  });

  it("reinstalls a stale managed Termux service wrapper after update", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const packageDir = nodePath.join(dir, "package");
    const config = createConfig(dir);
    await mkdir(nodePath.join(packageDir, "dist"), { recursive: true });
    await writeFile(nodePath.join(packageDir, "dist", "cli.js"), "#!/usr/bin/env node\n");

    const termuxPrefix = nodePath.join(dir, "termux-prefix");
    const originalPrefix = process.env.PREFIX;
    const originalTermuxVersion = process.env.TERMUX_VERSION;
    const installCalls: Array<Record<string, unknown>> = [];
    const lifecycleCalls: string[] = [];
    let detectCalls = 0;

    try {
      process.env.PREFIX = termuxPrefix;
      process.env.TERMUX_VERSION = "0.118.1";
      const result = await runSelfUpdate(
        {
          config,
          packageDir,
          managedService: "sidemesh",
        },
        {
          detectInstallInfo: async () => {
            detectCalls += 1;
            return createInstallInfo(packageDir);
          },
          waitForDaemonHealth: async () => true,
          resolveUpdatedPackageDir: async () => packageDir,
          resolveInstalledTermuxServicePaths: async (options) => ({
            prefix: termuxPrefix,
            serviceName: options.serviceName ?? "sidemesh",
            packageDir: options.packageDir,
            nodeBin: options.nodeBin,
            serviceDir: nodePath.join(termuxPrefix, "var", "service", "sidemesh"),
            envPath: nodePath.join(termuxPrefix, "var", "service", "sidemesh", "env"),
            launcherPath: nodePath.join(termuxPrefix, "var", "service", "sidemesh", "run"),
            logRunPath: nodePath.join(termuxPrefix, "var", "service", "sidemesh", "log", "run"),
            logDir: nodePath.join(termuxPrefix, "var", "log", "sv", "sidemesh"),
            downPath: nodePath.join(termuxPrefix, "var", "service", "sidemesh", "down"),
            svloggerPath: nodePath.join(termuxPrefix, "share", "termux-services", "svlogger"),
            pidPath: nodePath.join(termuxPrefix, "var", "run", "service-daemon.pid"),
          }),
          isTermuxServiceInstalled: async () => true,
          isTermuxServiceEnabled: async () => true,
          isTermuxServiceWrapperStale: async () => true,
          installTermuxService: async (_config, options) => {
            installCalls.push(options as unknown as Record<string, unknown>);
            return {
              prefix: termuxPrefix,
              serviceName: options.serviceName ?? "sidemesh",
              packageDir: options.packageDir,
              nodeBin: options.nodeBin,
              serviceDir:
                options.serviceDir ??
                nodePath.join(termuxPrefix, "var", "service", "sidemesh"),
              envPath:
                options.envPath ??
                nodePath.join(termuxPrefix, "var", "service", "sidemesh", "env"),
              launcherPath:
                options.launcherPath ??
                nodePath.join(termuxPrefix, "var", "service", "sidemesh", "run"),
              logRunPath: nodePath.join(termuxPrefix, "var", "service", "sidemesh", "log", "run"),
              logDir: nodePath.join(termuxPrefix, "var", "log", "sv", "sidemesh"),
              downPath: nodePath.join(termuxPrefix, "var", "service", "sidemesh", "down"),
              svloggerPath: nodePath.join(termuxPrefix, "share", "termux-services", "svlogger"),
              pidPath: nodePath.join(termuxPrefix, "var", "run", "service-daemon.pid"),
            };
          },
          stopTermuxService: async () => {
            lifecycleCalls.push("stop");
          },
          startTermuxService: async () => {
            lifecycleCalls.push("start");
          },
        },
      );

      assert.equal(result.success, true);
      assert.equal(detectCalls, 2);
      assert.equal(installCalls.length, 1);
      assert.equal(installCalls[0]?.start, false);
      assert.equal(installCalls[0]?.enabled, true);
      assert.equal(installCalls[0]?.serviceName, "sidemesh");
      assert.deepEqual(lifecycleCalls, ["stop", "start"]);

      const log = await readFile(result.logPath, "utf8");
      assert.match(log, /Service wrapper is stale, will reinstall sidemesh/);
      assert.match(log, /Reinstalled managed service wrapper sidemesh/);
    } finally {
      if (originalPrefix === undefined) {
        delete process.env.PREFIX;
      } else {
        process.env.PREFIX = originalPrefix;
      }
      if (originalTermuxVersion === undefined) {
        delete process.env.TERMUX_VERSION;
      } else {
        process.env.TERMUX_VERSION = originalTermuxVersion;
      }
    }
  });
});
