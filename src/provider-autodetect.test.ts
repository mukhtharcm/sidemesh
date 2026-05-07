import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { inferInstalledProviderConfigs } from "./provider-autodetect.js";

describe("inferInstalledProviderConfigs", () => {
  let tempDir = "";

  beforeEach(async () => {
    tempDir = await mkdtemp(
      nodePath.join(tmpdir(), "sidemesh-provider-autodetect-test-"),
    );
  });

  afterEach(async () => {
    if (tempDir) {
      await rm(tempDir, { recursive: true, force: true });
    }
  });

  it("prefers Codex as the default when Codex and Pi are both ready", async () => {
    const homeDir = nodePath.join(tempDir, "home");
    const binDir = nodePath.join(tempDir, "bin");
    const stateDir = nodePath.join(tempDir, "state");
    const piAgentDir = nodePath.join(tempDir, "pi-agent");
    await mkdir(homeDir, { recursive: true });
    await mkdir(binDir, { recursive: true });
    await mkdir(piAgentDir, { recursive: true });
    await writeCodexFixture(homeDir, binDir);

    const result = await inferInstalledProviderConfigs({
      env: {
        HOME: homeDir,
        PATH: binDir,
        SIDEMESH_PI_AGENT_DIR: piAgentDir,
      },
      stateDir,
    });

    assert.equal(result.defaultProviderKind, "codex");
    assert.deepEqual(
      result.providers.map((provider) => provider.kind),
      ["codex", "pi"],
    );
    assert.equal(readinessFor(result, "codex"), "ready");
    assert.equal(readinessFor(result, "pi"), "ready");
  });

  it("treats Codex as detected but not ready when auth is missing", async () => {
    const homeDir = nodePath.join(tempDir, "home");
    const binDir = nodePath.join(tempDir, "bin");
    const stateDir = nodePath.join(tempDir, "state");
    const piAgentDir = nodePath.join(tempDir, "pi-agent");
    await mkdir(homeDir, { recursive: true });
    await mkdir(binDir, { recursive: true });
    await mkdir(piAgentDir, { recursive: true });
    await writeCommand(nodePath.join(binDir, "codex"), "#!/bin/sh\necho codex 1.2.3\n");

    const result = await inferInstalledProviderConfigs({
      env: {
        HOME: homeDir,
        PATH: binDir,
        SIDEMESH_PI_AGENT_DIR: piAgentDir,
      },
      stateDir,
    });

    assert.equal(result.defaultProviderKind, "pi");
    assert.deepEqual(
      result.providers.map((provider) => provider.kind),
      ["pi"],
    );
    assert.equal(readinessFor(result, "codex"), "detected");
    assert.equal(readinessFor(result, "pi"), "ready");
  });

  it("returns no inferred providers when nothing supported is ready", async () => {
    const homeDir = nodePath.join(tempDir, "home");
    await mkdir(homeDir, { recursive: true });

    const result = await inferInstalledProviderConfigs({
      env: {
        HOME: homeDir,
        PATH: "",
      },
      stateDir: nodePath.join(tempDir, "state"),
    });

    assert.equal(result.defaultProviderKind, null);
    assert.deepEqual(result.providers, []);
  });
});

async function writeCodexFixture(homeDir: string, binDir: string): Promise<void> {
  await writeCommand(nodePath.join(binDir, "codex"), "#!/bin/sh\necho codex 1.2.3\n");
  const authDir = nodePath.join(homeDir, ".codex");
  await mkdir(authDir, { recursive: true });
  await writeFile(
    nodePath.join(authDir, "auth.json"),
    JSON.stringify({
      auth_mode: "chatgpt",
      tokens: {
        access_token: "access-token",
        refresh_token: "refresh-token",
        email: "dev@example.com",
      },
    }),
  );
}

async function writeCommand(path: string, content: string): Promise<void> {
  await writeFile(path, content, "utf8");
  await chmod(path, 0o755);
}

function readinessFor(
  result: Awaited<ReturnType<typeof inferInstalledProviderConfigs>>,
  kind: string,
): string | null {
  return result.candidates.find((candidate) => candidate.kind === kind)?.readiness ?? null;
}
