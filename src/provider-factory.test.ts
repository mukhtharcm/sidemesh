import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createAgentProviderRuntime } from "./provider-factory.js";
import { wrapProviderScopedId } from "./multi-provider.js";
import type { ThreadRecord, NodeConfig } from "./types.js";

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

  it("routes identical native session IDs and events to distinct instances", async () => {
    const config = makeMultiProviderConfig();
    const fake = config.providers[0]!;
    config.providers = [{ ...fake, id: "fake" }, { ...fake, id: "reviewer" }];
    config.defaultProviderKind = "fake";
    config.defaultProviderId = "reviewer";
    const runtime = createAgentProviderRuntime(config);
    assert.equal(runtime.providerForKind(null)?.id, "reviewer");
    assert.equal(runtime.providerForKind("fake")?.id, "fake");
    const thread: ThreadRecord = {
      id: "same-native-id", name: null, preview: "", createdAt: 1, updatedAt: 1,
      cwd: "/tmp", source: "fake", path: null, status: { type: "idle", phase: "idle" },
    };
    const observed: string[] = [];
    runtime.provider.on("liveEvent", (event) => {
      if ("sessionId" in event && event.sessionId) observed.push(event.sessionId);
    });
    for (const entry of runtime.providers) {
      const publicId = wrapProviderScopedId(entry.id!, thread.id);
      entry.provider.readSessionThread = async (id) => {
        assert.equal(id, thread.id);
        return thread;
      };
      assert.equal(runtime.providerForSessionId(publicId), entry);
      const loaded = await runtime.provider.readSessionThread!(publicId, false);
      assert.equal(loaded.id, publicId);
      assert.equal(loaded.providerId, entry.id);
      assert.equal(loaded.providerKind, "fake");
      entry.provider.emit("liveEvent", { type: "turn_started", sessionId: thread.id, turnId: "turn" });
    }
    assert.equal(new Set(observed).size, 2);
    assert.equal(runtime.providerForSessionId(wrapProviderScopedId("missing", thread.id)), null);
    // A legacy raw session ID retains the configured default route.
    assert.equal(runtime.providerForSessionId(thread.id), runtime.defaultProvider);
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
    configPath: "/tmp/sidemesh-runtime-test/config.json",
    configExists: false,
  };
}
