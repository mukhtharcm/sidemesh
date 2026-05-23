import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createAgentProviderRuntime } from "./provider-factory.js";
import type { NodeConfig } from "./types.js";

describe("createAgentProviderRuntime", () => {
  it("keeps default provider capabilities separate from other providers", () => {
    const runtime = createAgentProviderRuntime(makeMultiProviderConfig());

    assert.equal(runtime.defaultProviderKind, "copilot");
    assert.equal(runtime.defaultProvider.kind, "copilot");
    assert.equal(runtime.providerForKind(null)?.kind, "copilot");
    assert.equal(runtime.providerForKind(undefined)?.kind, "copilot");
    assert.equal(runtime.providerForKind("fake")?.kind, "fake");
    assert.equal(runtime.providerForKind("unknown"), null);
    // Blank / whitespace-only strings must not silently fall back to default.
    assert.equal(runtime.providerForKind(""), null);
    assert.equal(runtime.providerForKind("   "), null);

    // The facade OR-merges session fan-out capabilities so that a secondary
    // provider's searchable sessions remain accessible via /api/sessions/search.
    // copilot has searchSessions=false but fake has searchSessions=true, so
    // the facade should advertise true.
    assert.equal(runtime.provider.capabilities.sessions.searchSessions, true);
    assert.equal(
      runtime.providerForKind("fake")?.provider.capabilities.sessions.searchSessions,
      true,
    );
    // The default (copilot) provider's own flag is unaffected.
    assert.equal(
      runtime.defaultProvider.provider.capabilities.sessions.searchSessions,
      false,
    );
  });
});

function makeMultiProviderConfig(): NodeConfig {
  return {
    label: "runtime-test",
    port: 0,
    token: "test-token",
    tokenSource: "generated",
    provider: {
      kind: "copilot",
      bin: "copilot",
      stateDir: null,
      allowAll: false,
      configuredModel: null,
    },
    providers: [
      {
        kind: "fake",
        latencyMs: 0,
        seedSessions: false,
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
    defaultProviderKind: "copilot",
    updateChannel: "stable",
    stateDir: "/tmp/sidemesh-runtime-test",
    terminal: { enabled: false, shell: null, requirePty: false },
    browserPreview: {
      enabled: false,
      chromePath: null,
      maxPreviews: 8,
      idleTtlMs: 3_600_000,
      frameIntervalMs: 900,
      quality: 55,
    },
    configPath: "/tmp/sidemesh-runtime-test/config.json",
    configExists: false,
  };
}
