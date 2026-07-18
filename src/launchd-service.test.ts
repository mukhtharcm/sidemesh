import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import {
  isServiceWrapperStale,
  renderLaunchdEnv,
  renderLaunchdLauncher,
  renderLaunchdPlist,
  resolveLaunchdPaths,
} from "./launchd-service.js";
import type { NodeConfig } from "./types.js";

describe("launchd service rendering", () => {
  it("renders a user LaunchAgent, launcher, and private env content", () => {
    const config: NodeConfig = {
      label: "Mac Dev",
      port: 8899,
      token: "test-token",
      tokenSource: "file",
      provider: { kind: "codex", bin: "codex" },
      providers: [{ kind: "codex", bin: "codex" }],
      defaultProviderKind: "codex",
      updateChannel: "stable",
      stateDir: "/Users/example/.sidemesh",
      workspaceRoots: [],
      terminal: { enabled: true, shell: "/bin/zsh", requirePty: false },
      browserPreview: {
        enabled: true,
        chromePath: "/Applications/Chromium.app/Contents/MacOS/Chromium",
        maxPreviews: 2,
        idleTtlMs: 120000,
        frameIntervalMs: 1000,
        quality: 60,
      },
      configPath: "/Users/example/.sidemesh/config.json",
      configExists: true,
    };
    const paths = resolveLaunchdPaths(config, {
      label: "dev.sidemesh.test",
      packageDir: "/Users/example/dev/sidemesh",
      nodeBin: "/Users/example/.nvm/versions/node/v24.14.0/bin/node",
    });

    assert.equal(paths.label, "dev.sidemesh.test");
    assert.match(
      paths.plistPath,
      /Library\/LaunchAgents\/dev\.sidemesh\.test\.plist$/,
    );
    assert.equal(
      paths.envPath,
      "/Users/example/.sidemesh/launchd/dev.sidemesh.test.env",
    );

    const plist = renderLaunchdPlist(paths);
    assert.match(plist, /<key>RunAtLoad<\/key>\n  <true\/>/);
    assert.match(plist, /<key>KeepAlive<\/key>\n  <true\/>/);
    assert.match(plist, /dev\.sidemesh\.test/);

    const launcher = renderLaunchdLauncher(paths, config);
    assert.match(launcher, /set -a\n\. '/);
    assert.match(launcher, /dist\/cli\.js' daemon --config/);
    assert.match(launcher, /\/Users\/example\/\.sidemesh\/config\.json/);

    const env = renderLaunchdEnv(config);
    assert.match(env, /SIDEMESH_TOKEN=test-token/);
    assert.match(env, /SIDEMESH_TERMINAL=1/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW=1/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS=2/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_IDLE_TTL_MS=120000/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_FRAME_INTERVAL_MS=1000/);
    assert.match(env, /SIDEMESH_BROWSER_PREVIEW_QUALITY=60/);
    assert.match(env, /SIDEMESH_LABEL="Mac Dev"/);
  });

  it("resolves custom uninstall paths from the configured state dir", () => {
    const paths = resolveLaunchdPaths(
      { stateDir: "/Users/example/.sidemesh" },
      {
        label: "dev.sidemesh.custom",
        packageDir: "",
        nodeBin: "",
        plistPath: "/tmp/dev.sidemesh.custom.plist",
        envPath: "/tmp/dev.sidemesh.custom.env",
        launcherPath: "/tmp/dev.sidemesh.custom.sh",
      },
    );

    assert.equal(paths.label, "dev.sidemesh.custom");
    assert.equal(paths.plistPath, "/tmp/dev.sidemesh.custom.plist");
    assert.equal(paths.envPath, "/tmp/dev.sidemesh.custom.env");
    assert.equal(paths.launcherPath, "/tmp/dev.sidemesh.custom.sh");
  });

  it("detects stale launcher and plist files", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-launchd-service-test-"));
    const config: NodeConfig = {
      label: "Mac Dev",
      port: 8899,
      token: "test-token",
      tokenSource: "file",
      provider: { kind: "codex", bin: "codex" },
      providers: [{ kind: "codex", bin: "codex" }],
      defaultProviderKind: "codex",
      updateChannel: "stable",
      stateDir: "/Users/example/.sidemesh",
      workspaceRoots: [],
      terminal: { enabled: true, shell: "/bin/zsh", requirePty: false },
      browserPreview: {
        enabled: true,
        chromePath: "/Applications/Chromium.app/Contents/MacOS/Chromium",
        maxPreviews: 2,
        idleTtlMs: 120000,
        frameIntervalMs: 1000,
        quality: 60,
      },
      configPath: "/Users/example/.sidemesh/config.json",
      configExists: true,
    };
    const paths = resolveLaunchdPaths(config, {
      label: "dev.sidemesh.test",
      packageDir: "/Users/example/dev/sidemesh",
      nodeBin: "/usr/local/bin/node",
      plistPath: nodePath.join(dir, "dev.sidemesh.test.plist"),
      envPath: nodePath.join(dir, "dev.sidemesh.test.env"),
      launcherPath: nodePath.join(dir, "dev.sidemesh.test.sh"),
    });

    await writeFile(paths.launcherPath, renderLaunchdLauncher(paths, config));
    await writeFile(paths.plistPath, renderLaunchdPlist(paths));
    assert.equal(await isServiceWrapperStale(paths, config), false);

    await writeFile(
      paths.launcherPath,
      renderLaunchdLauncher({ ...paths, packageDir: "/Users/example/old-sidemesh" }, config),
    );
    assert.equal(await isServiceWrapperStale(paths, config), true);

    await writeFile(paths.launcherPath, renderLaunchdLauncher(paths, config));
    await writeFile(
      paths.plistPath,
      renderLaunchdPlist({ ...paths, launcherPath: "/tmp/old-sidemesh.sh" }),
    );
    assert.equal(await isServiceWrapperStale(paths, config), true);
  });
});
