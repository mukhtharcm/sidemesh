import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
      ["fake", "copilot"],
    );
    assert.equal(config.token, "file-token");
    assert.equal(config.tokenSource, "file");
    assert.deepEqual(config.terminal, {
      enabled: false,
      shell: null,
      requirePty: false,
    });
    assert.deepEqual(config.browserPreview, {
      enabled: false,
      chromePath: null,
      maxPreviews: 8,
      idleTtlMs: 60 * 60 * 1000,
      frameIntervalMs: 900,
      quality: 55,
    });
    assert.equal(config.updateChannel, "stable");
  });

  it("loads update channel from persisted config and env overrides", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        updateChannel: "bleeding-edge",
        providers: [{ kind: "codex", bin: "codex" }],
      }),
    );

    const persisted = await loadConfig({ configPath, env: {} });
    assert.equal(persisted.updateChannel, "bleeding-edge");

    const overridden = await loadConfig({
      configPath,
      env: {
        SIDEMESH_UPDATE_CHANNEL: "stable",
      },
    });
    assert.equal(overridden.updateChannel, "stable");
  });

  it("loads mobile client version hints from persisted config and env overrides", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        recommendedMobileClientVersion: "1.2.0+2",
        minimumMobileClientVersion: "v1.0.0",
        providers: [{ kind: "codex", bin: "codex" }],
      }),
    );

    const persisted = await loadConfig({ configPath, env: {} });
    assert.equal(persisted.recommendedMobileClientVersion, "1.2.0+2");
    assert.equal(persisted.minimumMobileClientVersion, "v1.0.0");

    const overridden = await loadConfig({
      configPath,
      env: {
        SIDEMESH_RECOMMENDED_MOBILE_CLIENT_VERSION: "v1.3.0",
        SIDEMESH_MINIMUM_MOBILE_CLIENT_VERSION: "1.1.0+4",
      },
    });
    assert.equal(overridden.recommendedMobileClientVersion, "v1.3.0");
    assert.equal(overridden.minimumMobileClientVersion, "1.1.0+4");
  });

  it("rejects invalid mobile client version hints", async () => {
    await assert.rejects(
      () =>
        loadConfig({
          configPath,
          env: {
            SIDEMESH_MINIMUM_MOBILE_CLIENT_VERSION: "latest",
          },
        }),
      /SIDEMESH_MINIMUM_MOBILE_CLIENT_VERSION must be a mobile client version/,
    );

    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        recommendedMobileClientVersion: "latest",
        providers: [{ kind: "codex", bin: "codex" }],
      }),
    );

    await assert.rejects(
      () => loadConfig({ configPath, env: {} }),
      /recommendedMobileClientVersion.*must be a mobile client version/s,
    );
  });

  it("loads Pi provider config from env and persisted values", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        defaultProviderKind: "pi",
        providers: [
          {
            kind: "pi",
            agentDir: "/tmp/pi-agent-old",
            stateDir: "/tmp/pi-state-old",
          },
        ],
      }),
    );

    const config = await loadConfig({
      configPath,
      env: {
        SIDEMESH_PROVIDER: "pi",
        SIDEMESH_PI_AGENT_DIR: "/tmp/pi-agent",
      },
    });

    assert.equal(config.defaultProviderKind, "pi");
    assert.equal(config.provider.kind, "pi");
    if (config.provider.kind !== "pi") {
      throw new Error("expected pi provider");
    }
    assert.equal(config.provider.agentDir, "/tmp/pi-agent");
    assert.equal(config.provider.stateDir, "/tmp/pi-state-old");
  });

  it("loads OpenCode provider config from env and persisted values", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        defaultProviderKind: "opencode",
        providers: [
          {
            kind: "opencode",
            bin: "opencode-old",
            stateDir: "/tmp/opencode-state-old",
          },
        ],
      }),
    );

    const config = await loadConfig({
      configPath,
      env: {
        SIDEMESH_PROVIDER: "opencode",
        SIDEMESH_OPENCODE_BIN: "opencode-beta",
      },
    });

    assert.equal(config.defaultProviderKind, "opencode");
    assert.equal(config.provider.kind, "opencode");
    if (config.provider.kind !== "opencode") {
      throw new Error("expected opencode provider");
    }
    assert.equal(config.provider.bin, "opencode-beta");
    assert.equal(config.provider.stateDir, "/tmp/opencode-state-old");
  });

  it("loads acpx provider config from env and persisted values", async () => {
    await writeFile(
      configPath,
      JSON.stringify({
        version: 1,
        token: "file-token",
        defaultProviderKind: "acpx",
        providers: [
          {
            kind: "acpx",
            agent: "gemini",
            command: null,
            stateDir: "/tmp/acpx-state-old",
            permissionMode: "approve-reads",
          },
        ],
      }),
    );

    const config = await loadConfig({
      configPath,
      env: {
        SIDEMESH_PROVIDER: "acpx",
        SIDEMESH_ACPX_AGENT: "claude",
        SIDEMESH_ACPX_COMMAND: "claude-agent-acp",
        SIDEMESH_ACPX_PERMISSION_MODE: "deny-all",
      },
    });

    assert.equal(config.defaultProviderKind, "acpx");
    assert.equal(config.provider.kind, "acpx");
    if (config.provider.kind !== "acpx") {
      throw new Error("expected acpx provider");
    }
    assert.equal(config.provider.agent, "claude");
    assert.equal(config.provider.command, "claude-agent-acp");
    assert.equal(config.provider.stateDir, "/tmp/acpx-state-old");
    assert.equal(config.provider.permissionMode, "deny-all");
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

  it("loads browser settings from persisted config and env overrides", async () => {
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

  it("loads persisted Copilot config without an experimental flag", async () => {
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

    assert.equal(config.defaultProviderKind, "copilot");
    assert.equal(config.provider.kind, "copilot");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["copilot"],
    );
  });

  it("accepts explicit Copilot selection without an experimental flag", async () => {
    const config = await loadConfig({
      configPath,
      env: {
        SIDEMESH_PROVIDER: "copilot",
      },
    });

    assert.equal(config.defaultProviderKind, "copilot");
    assert.equal(config.provider.kind, "copilot");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["copilot"],
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

  it("auto-detects a ready Pi provider on first run", async () => {
    const homeDir = nodePath.join(tempDir, "home");
    const piAgentDir = nodePath.join(tempDir, "pi-agent");
    await mkdir(homeDir, { recursive: true });
    await mkdir(piAgentDir, { recursive: true });

    const config = await loadConfig({
      configPath,
      env: {
        HOME: homeDir,
        PATH: "",
        SIDEMESH_PI_AGENT_DIR: piAgentDir,
      },
    });

    assert.equal(config.defaultProviderKind, "pi");
    assert.equal(config.provider.kind, "pi");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["pi"],
    );
  });

  it("persists inferred ready providers when generating a first-run config", async () => {
    const homeDir = nodePath.join(tempDir, "home");
    const binDir = nodePath.join(tempDir, "bin");
    const piAgentDir = nodePath.join(tempDir, "pi-agent");
    await mkdir(homeDir, { recursive: true });
    await mkdir(binDir, { recursive: true });
    await mkdir(piAgentDir, { recursive: true });
    await writeCommand(nodePath.join(binDir, "codex"), "#!/bin/sh\necho codex 1.2.3\n");
    await mkdir(nodePath.join(homeDir, ".codex"), { recursive: true });
    await writeFile(
      nodePath.join(homeDir, ".codex", "auth.json"),
      JSON.stringify({
        auth_mode: "chatgpt",
        tokens: {
          access_token: "access-token",
          refresh_token: "refresh-token",
        },
      }),
    );

    const config = await loadConfig({
      configPath,
      env: {
        HOME: homeDir,
        PATH: binDir,
        SIDEMESH_PI_AGENT_DIR: piAgentDir,
      },
      persistGeneratedToken: true,
    });

    assert.equal(config.defaultProviderKind, "codex");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["codex", "pi"],
    );

    const raw = JSON.parse(await readFile(configPath, "utf8")) as {
      defaultProviderKind?: string;
      providers?: Array<{ kind?: string }>;
    };
    assert.equal(raw.defaultProviderKind, "codex");
    assert.deepEqual(
      raw.providers?.map((provider) => provider.kind),
      ["codex", "pi"],
    );
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

async function writeCommand(path: string, content: string): Promise<void> {
  await writeFile(path, content, "utf8");
  await chmod(path, 0o755);
}
