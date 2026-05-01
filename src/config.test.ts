import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { loadConfig, rotatePersistedToken } from "./config.js";

describe("loadConfig", () => {
  let tempDir = "";
  let configPath = "";

  beforeEach(async () => {
    tempDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-config-test-"));
    configPath = nodePath.join(tempDir, "config.json");
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  it("loads multiple providers and keeps the requested default first", async () => {
    const config = await loadConfig({
      configPath,
      env: {
        SIDEMESH_TOKEN: "test-token",
        SIDEMESH_ENABLE_COPILOT: "1",
        SIDEMESH_PROVIDER: "copilot",
        SIDEMESH_PROVIDERS: "codex,copilot",
      },
    });

    assert.equal(config.defaultProviderKind, "copilot");
    assert.equal(config.provider.kind, "copilot");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["copilot", "codex"],
    );
  });

  it("defaults to the first enabled provider in the persisted config", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        defaultProviderKind: "fake",
        providers: [
          {
            kind: "fake",
            latencyMs: 15,
            seedSessions: true,
            workspaceRoot: null,
            capabilityProfile: "full",
          },
          {
            kind: "copilot",
            bin: "copilot",
            stateDir: null,
            allowAll: false,
            configuredModel: null,
          },
        ],
      }),
    );

    const config = await loadConfig({ configPath, env: {} });

    assert.equal(config.defaultProviderKind, "fake");
    assert.equal(config.provider.kind, "fake");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["fake"],
    );
    assert.equal(config.token, "file-token");
    assert.equal(config.tokenSource, "file");
    assert.deepEqual(config.terminal, {
      enabled: false,
      shell: null,
      requirePty: false,
    });
    assert.deepEqual(config.portForwarding, {
      enabled: false,
      allowNonLoopbackTargets: false,
    });
    assert.deepEqual(config.browserPreview, {
      enabled: false,
      chromePath: null,
      maxPreviews: 8,
      idleTtlMs: 60 * 60 * 1000,
      frameIntervalMs: 900,
      quality: 55,
    });
  });

  it("loads terminal settings from persisted config and env overrides", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        terminal: {
          enabled: true,
          shell: "/bin/zsh",
          requirePty: false,
        },
        providers: [{ kind: "codex", bin: "codex" }],
      }),
    );

    const persisted = await loadConfig({ configPath, env: {} });
    assert.deepEqual(persisted.terminal, {
      enabled: true,
      shell: "/bin/zsh",
      requirePty: false,
    });

    const overridden = await loadConfig({
      configPath,
      env: {
        SIDEMESH_TERMINAL: "0",
        SIDEMESH_TERMINAL_SHELL: "/bin/bash",
        SIDEMESH_TERMINAL_REQUIRE_PTY: "1",
      },
    });
    assert.deepEqual(overridden.terminal, {
      enabled: false,
      shell: "/bin/bash",
      requirePty: true,
    });
  });

  it("loads port forwarding settings from persisted config and env overrides", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        portForwarding: {
          enabled: true,
          allowNonLoopbackTargets: false,
        },
        providers: [{ kind: "codex", bin: "codex" }],
      }),
    );

    const persisted = await loadConfig({ configPath, env: {} });
    assert.deepEqual(persisted.portForwarding, {
      enabled: true,
      allowNonLoopbackTargets: false,
    });

    const overridden = await loadConfig({
      configPath,
      env: {
        SIDEMESH_PORT_FORWARDING: "0",
        SIDEMESH_PORT_FORWARDING_ALLOW_NON_LOOPBACK: "1",
      },
    });
    assert.deepEqual(overridden.portForwarding, {
      enabled: false,
      allowNonLoopbackTargets: true,
    });
  });

  it("loads browser preview settings from persisted config and env overrides", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        browserPreview: {
          enabled: true,
          chromePath: "/opt/chrome",
          maxPreviews: 3,
          idleTtlMs: 120000,
          frameIntervalMs: 1500,
          quality: 70,
        },
        providers: [{ kind: "codex", bin: "codex" }],
      }),
    );

    const persisted = await loadConfig({ configPath, env: {} });
    assert.deepEqual(persisted.browserPreview, {
      enabled: true,
      chromePath: "/opt/chrome",
      maxPreviews: 3,
      idleTtlMs: 120000,
      frameIntervalMs: 1500,
      quality: 70,
    });

    const overridden = await loadConfig({
      configPath,
      env: {
        SIDEMESH_BROWSER_PREVIEW: "0",
        SIDEMESH_BROWSER_PREVIEW_CHROME_PATH: "/usr/bin/chromium",
        SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS: "2",
        SIDEMESH_BROWSER_PREVIEW_IDLE_TTL_MS: "30000",
        SIDEMESH_BROWSER_PREVIEW_FRAME_INTERVAL_MS: "250",
        SIDEMESH_BROWSER_PREVIEW_QUALITY: "95",
      },
    });
    assert.deepEqual(overridden.browserPreview, {
      enabled: false,
      chromePath: "/usr/bin/chromium",
      maxPreviews: 2,
      idleTtlMs: 30000,
      frameIntervalMs: 250,
      quality: 95,
    });
  });

  it("lets env overrides win over persisted provider config", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        defaultProviderKind: "copilot",
        providers: [
          {
            kind: "copilot",
            bin: "/opt/copilot-old",
            stateDir: "/tmp/old-state",
            allowAll: false,
            configuredModel: "gpt-4o",
          },
        ],
      }),
    );

    const config = await loadConfig({
      configPath,
      env: {
        SIDEMESH_ENABLE_COPILOT: "1",
        SIDEMESH_COPILOT_BIN: "/usr/local/bin/copilot",
        SIDEMESH_COPILOT_ALLOW_ALL: "1",
        SIDEMESH_COPILOT_MODEL: "auto",
      },
    });

    assert.equal(config.provider.kind, "copilot");
    if (config.provider.kind !== "copilot") {
      throw new Error("expected copilot provider");
    }
    assert.equal(config.provider.bin, "/usr/local/bin/copilot");
    assert.equal(config.provider.allowAll, true);
    assert.equal(config.provider.configuredModel, "auto");
    assert.equal(config.provider.stateDir, "/tmp/old-state");
  });

  it("ignores persisted Copilot config unless the experimental flag is enabled", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        defaultProviderKind: "copilot",
        providers: [
          {
            kind: "copilot",
            bin: "copilot",
            stateDir: null,
            allowAll: false,
            configuredModel: null,
          },
        ],
      }),
    );

    const config = await loadConfig({ configPath, env: {} });

    assert.equal(config.defaultProviderKind, "codex");
    assert.equal(config.provider.kind, "codex");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["codex"],
    );
  });

  it("rejects explicit Copilot selection unless the experimental flag is enabled", async () => {
    await assert.rejects(
      () =>
        loadConfig({
          configPath,
          env: {
            SIDEMESH_PROVIDER: "copilot",
          },
        }),
      /Set SIDEMESH_ENABLE_COPILOT=1/,
    );
  });

  it("persists a generated token when requested", async () => {
    const config = await loadConfig({
      configPath,
      env: {
        SIDEMESH_PROVIDER: "codex",
      },
      persistGeneratedToken: true,
    });

    assert.equal(config.tokenSource, "file");
    assert.equal(config.configExists, true);

    const raw = JSON.parse(await readFile(configPath, "utf8")) as {
      token?: string;
    };
    assert.equal(raw.token, config.token);
  });

  it("rotates the persisted token in place", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "before-token",
        defaultProviderKind: "codex",
        providers: [{ kind: "codex", bin: "codex" }],
      }),
    );

    const config = await rotatePersistedToken({ configPath, env: {} });
    assert.notEqual(config.token, "before-token");

    const raw = JSON.parse(await readFile(configPath, "utf8")) as {
      token?: string;
    };
    assert.equal(raw.token, config.token);
  });
});
