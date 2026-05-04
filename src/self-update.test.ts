import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";

import { runSelfUpdate } from "./self-update.js";

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
      config: {
        label: "test",
        port: 9999,
        token: "test-token",
        tokenSource: "generated",
        provider: { kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" },
        providers: [{ kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" }],
        defaultProviderKind: "fake",
        stateDir: nodePath.join(dir, "state"),
        terminal: { enabled: false, shell: null, requirePty: false },
        portForwarding: { enabled: false, allowNonLoopbackTargets: false },
        browserPreview: { enabled: false, chromePath: null, maxPreviews: 8, idleTtlMs: 3_600_000, frameIntervalMs: 900, quality: 55 },
        configPath: nodePath.join(dir, "config.json"),
        configExists: false,
      },
      packageDir: nested,
      dryRun: true,
    });

    assert.equal(result.success, true); // dry-run succeeds
    assert.equal(result.oldVersion, "0.1.0");
  });

  it("returns unsupported for unknown install", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-self-update-test-"));
    const result = await runSelfUpdate({
      config: {
        label: "test",
        port: 9999,
        token: "test-token",
        tokenSource: "generated",
        provider: { kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" },
        providers: [{ kind: "fake", latencyMs: 0, seedSessions: false, workspaceRoot: null, capabilityProfile: "full" }],
        defaultProviderKind: "fake",
        stateDir: nodePath.join(dir, "state"),
        terminal: { enabled: false, shell: null, requirePty: false },
        portForwarding: { enabled: false, allowNonLoopbackTargets: false },
        browserPreview: { enabled: false, chromePath: null, maxPreviews: 8, idleTtlMs: 3_600_000, frameIntervalMs: 900, quality: 55 },
        configPath: nodePath.join(dir, "config.json"),
        configExists: false,
      },
      packageDir: dir,
      dryRun: false,
    });

    assert.equal(result.success, false);
    assert.ok(result.error?.includes("not supported"));
  });
});
