import assert from "node:assert/strict";
import {
  access,
  chmod,
  mkdtemp,
  mkdir,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import { renderServiceEnv } from "./systemd-service.js";
import {
  isServiceWrapperStale,
  renderTermuxServiceLauncher,
  resolveTermuxServicePaths,
  startTermuxService,
} from "./termux-service.js";
import type { NodeConfig } from "./types.js";

function createConfig(): NodeConfig {
  return {
    label: "Lab Node",
    port: 8899,
    token: "test-token",
    tokenSource: "file",
    provider: { kind: "codex", bin: "codex" },
    providers: [{ kind: "codex", bin: "codex" }],
    defaultProviderKind: "codex",
    updateChannel: "stable",
    stateDir: "/root/.sidemesh",
    workspaceRoots: [],
    terminal: { enabled: true, shell: "/bin/zsh", requirePty: false },
    browserPreview: {
      enabled: true,
      chromePath: "/usr/bin/chromium",
      maxPreviews: 2,
      idleTtlMs: 120000,
      frameIntervalMs: 1000,
      quality: 60,
    },
    configPath: "/root/.sidemesh/config.json",
    configExists: true,
  };
}

describe("termux service rendering", () => {
  it("resolves default runit paths and renders a launcher", () => {
    const paths = resolveTermuxServicePaths({
      serviceName: "sidemesh-test",
      packageDir: "/opt/sidemesh",
      nodeBin: "/data/data/com.termux/files/usr/bin/node",
      prefix: "/data/data/com.termux/files/usr",
    });

    assert.equal(
      paths.serviceDir,
      "/data/data/com.termux/files/usr/var/service/sidemesh-test",
    );
    assert.equal(
      paths.launcherPath,
      "/data/data/com.termux/files/usr/var/service/sidemesh-test/run",
    );
    assert.equal(
      paths.envPath,
      "/data/data/com.termux/files/usr/var/service/sidemesh-test/env",
    );

    const launcher = renderTermuxServiceLauncher(paths, createConfig());
    assert.match(
      launcher,
      /^#!\/data\/data\/com\.termux\/files\/usr\/bin\/sh/m,
    );
    assert.match(
      launcher,
      /export PREFIX='\/data\/data\/com\.termux\/files\/usr'/,
    );
    assert.match(
      launcher,
      /\. '\/data\/data\/com\.termux\/files\/usr\/var\/service\/sidemesh-test\/env'/,
    );
    assert.match(launcher, /dist\/cli\.js' daemon --config/);
  });

  it("detects stale launcher, env, and logger wrappers", async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-termux-service-test-"),
    );
    const prefix = nodePath.join(dir, "prefix");
    const config = createConfig();
    const paths = resolveTermuxServicePaths({
      serviceName: "sidemesh-test",
      packageDir: "/opt/sidemesh",
      nodeBin: nodePath.join(prefix, "bin", "node"),
      prefix,
    });

    await mkdir(nodePath.dirname(paths.launcherPath), { recursive: true });
    await mkdir(nodePath.dirname(paths.logRunPath), { recursive: true });
    await mkdir(nodePath.dirname(paths.svloggerPath), { recursive: true });
    await writeFile(paths.svloggerPath, "#!/bin/sh\nexit 0\n");
    await writeFile(
      paths.launcherPath,
      renderTermuxServiceLauncher(paths, config),
    );
    await writeFile(paths.envPath, renderServiceEnv(config));
    await symlink(paths.svloggerPath, paths.logRunPath);

    assert.equal(await isServiceWrapperStale(paths, config), false);

    await writeFile(
      paths.launcherPath,
      renderTermuxServiceLauncher(
        { ...paths, packageDir: "/opt/old-sidemesh" },
        config,
      ),
    );
    assert.equal(await isServiceWrapperStale(paths, config), true);

    await writeFile(
      paths.launcherPath,
      renderTermuxServiceLauncher(paths, config),
    );
    await writeFile(
      paths.envPath,
      renderServiceEnv({ ...config, label: "Changed Node" }),
    );
    assert.equal(await isServiceWrapperStale(paths, config), true);
  });

  it("removes the runit down marker when starting an installed service", {
    skip: process.platform !== "linux" && process.platform !== "android",
  }, async () => {
    const dir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-termux-service-test-"),
    );
    const prefix = nodePath.join(dir, "prefix");
    const binDir = nodePath.join(prefix, "bin");
    const paths = resolveTermuxServicePaths({
      serviceName: "sidemesh-test",
      packageDir: "/opt/sidemesh",
      nodeBin: nodePath.join(binDir, "node"),
      prefix,
    });
    const originalPrefix = process.env.PREFIX;
    const originalTermuxVersion = process.env.TERMUX_VERSION;
    const originalPath = process.env.PATH;

    await mkdir(binDir, { recursive: true });
    await mkdir(nodePath.join(paths.serviceDir, "supervise"), {
      recursive: true,
    });
    await mkdir(nodePath.dirname(paths.svloggerPath), { recursive: true });
    await mkdir(nodePath.dirname(paths.pidPath), { recursive: true });
    await writeExecutable(nodePath.join(binDir, "sv"), "#!/bin/sh\nexit 0\n");
    await writeExecutable(
      nodePath.join(binDir, "service-daemon"),
      "#!/bin/sh\nexit 0\n",
    );
    await writeFile(paths.svloggerPath, "#!/bin/sh\nexit 0\n");
    await writeFile(paths.launcherPath, "#!/bin/sh\nexit 0\n");
    await writeFile(paths.downPath, "");
    await writeFile(nodePath.join(paths.serviceDir, "supervise", "ok"), "");
    await writeFile(paths.pidPath, String(process.pid));

    try {
      process.env.PREFIX = prefix;
      process.env.TERMUX_VERSION = "0.118.1";
      process.env.PATH = "/usr/bin";

      await startTermuxService(paths.serviceName);

      assert.equal(await pathExists(paths.downPath), false);
    } finally {
      restoreEnv("PREFIX", originalPrefix);
      restoreEnv("TERMUX_VERSION", originalTermuxVersion);
      restoreEnv("PATH", originalPath);
    }
  });
});

async function writeExecutable(path: string, content: string): Promise<void> {
  await writeFile(path, content);
  await chmod(path, 0o755);
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
