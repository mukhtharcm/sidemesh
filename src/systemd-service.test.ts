import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import {
  isServiceWrapperStale,
  renderServiceEnv,
  renderServiceLauncher,
  renderSystemdUnit,
  resolveServicePaths,
} from "./systemd-service.js";
import type { NodeConfig } from "./types.js";

describe("systemd service rendering", () => {
  it("renders unit, launcher, and private env content", () => {
    const config: NodeConfig = {
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
    const paths = resolveServicePaths({
      serviceName: "sidemesh-test",
      packageDir: "/opt/sidemesh",
      nodeBin: "/root/.nvm/versions/node/v24.14.0/bin/node",
    });

    assert.equal(paths.unitPath, "/etc/systemd/system/sidemesh-test.service");
    assert.equal(paths.envPath, "/etc/sidemesh/sidemesh-test.env");
    assert.equal(paths.launcherPath, "/etc/sidemesh/sidemesh-test.sh");

    const unit = renderSystemdUnit(paths);
    assert.match(unit, /EnvironmentFile=\/etc\/sidemesh\/sidemesh-test\.env/);
    assert.match(unit, /ExecStart=\/etc\/sidemesh\/sidemesh-test\.sh/);
    assert.match(unit, /Restart=always/);
    assert.match(unit, /KillMode=mixed/);
    assert.match(unit, /TimeoutStopSec=15s/);
    assert.match(unit, /MemoryAccounting=yes/);

    const launcher = renderServiceLauncher(paths, config);
    assert.match(launcher, /export HOME=/);
    assert.match(launcher, /export LOGNAME=/);
    assert.match(launcher, /export SHELL=/);
    assert.match(launcher, /dist\/cli\.js' daemon --config/);
    assert.match(launcher, /\/root\/\.sidemesh\/config\.json/);

    const env = renderServiceEnv(config);
    assert.match(env, /SIDEMESH_TOKEN=test-token/);
    assert.match(env, /SIDEMESH_TERMINAL=1/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW=1/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS=2/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_IDLE_TTL_MS=120000/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_FRAME_INTERVAL_MS=1000/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_QUALITY=60/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_CHROME_PATH=\/usr\/bin\/chromium/);
    assert.match(env, /SIDEMESH_TERMINAL_SHELL=\/bin\/zsh/);
    assert.match(env, /SIDEMESH_LABEL="Lab Node"/);
  });

  it("resolves custom uninstall paths without needing package metadata", () => {
    const paths = resolveServicePaths({
      serviceName: "sidemesh-custom.service",
      packageDir: "",
      nodeBin: "",
      unitPath: "/tmp/sidemesh/custom.service",
      envPath: "/tmp/sidemesh/custom.env",
      launcherPath: "/tmp/sidemesh/custom.sh",
    });

    assert.equal(paths.serviceName, "sidemesh-custom");
    assert.equal(paths.unitPath, "/tmp/sidemesh/custom.service");
    assert.equal(paths.envPath, "/tmp/sidemesh/custom.env");
    assert.equal(paths.launcherPath, "/tmp/sidemesh/custom.sh");
  });

  it("renders optional memory pressure and hard cap limits", () => {
    const paths = resolveServicePaths({
      serviceName: "sidemesh-test",
      packageDir: "/opt/sidemesh",
      nodeBin: "/usr/bin/node",
    });

    const unit = renderSystemdUnit(paths, {
      memoryHigh: "2G",
      memoryMax: "3G",
    });

    assert.match(unit, /MemoryHigh=2G/);
    assert.match(unit, /MemoryMax=3G/);
  });

  it("detects stale launcher and unit files", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-systemd-service-test-"));
    const config: NodeConfig = {
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
    const paths = resolveServicePaths({
      serviceName: "sidemesh-test",
      packageDir: "/opt/sidemesh",
      nodeBin: "/usr/bin/node",
      unitPath: nodePath.join(dir, "sidemesh.service"),
      envPath: nodePath.join(dir, "sidemesh.env"),
      launcherPath: nodePath.join(dir, "sidemesh.sh"),
    });

    await writeFile(paths.launcherPath, renderServiceLauncher(paths, config));
    await writeFile(paths.unitPath, renderSystemdUnit(paths));
    assert.equal(await isServiceWrapperStale(paths, config), false);

    await writeFile(
      paths.launcherPath,
      renderServiceLauncher({ ...paths, packageDir: "/opt/old-sidemesh" }, config),
    );
    assert.equal(await isServiceWrapperStale(paths, config), true);

    await writeFile(paths.launcherPath, renderServiceLauncher(paths, config));
    await writeFile(
      paths.unitPath,
      renderSystemdUnit({ ...paths, launcherPath: "/etc/sidemesh/old.sh" }),
    );
    assert.equal(await isServiceWrapperStale(paths, config), true);
  });
});
