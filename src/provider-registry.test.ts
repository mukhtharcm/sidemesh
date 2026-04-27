import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { CodexAgentProvider } from "./codex-provider.js";
import { CopilotAgentProvider } from "./copilot-provider.js";
import { FakeAgentProvider } from "./fake-provider.js";
import {
  DEFAULT_AGENT_PROVIDER_KIND,
  createAgentProviderFromConfig,
  isAgentProviderKind,
  listAgentProviderDefinitionSummaries,
  loadAgentProviderConfig,
  summarizeAgentProviderConfig,
  supportedAgentProviderKinds,
} from "./provider-registry.js";

describe("provider registry", () => {
  it("reports Codex as the default supported provider", () => {
    assert.equal(DEFAULT_AGENT_PROVIDER_KIND, "codex");
    assert.deepEqual(supportedAgentProviderKinds(), ["codex", "fake", "copilot"]);
    assert.equal(isAgentProviderKind("codex"), true);
    assert.equal(isAgentProviderKind("fake"), true);
    assert.equal(isAgentProviderKind("copilot"), true);
  });

  it("exposes provider metadata without leaking factory functions", () => {
    assert.deepEqual(listAgentProviderDefinitionSummaries(), [
      {
        kind: "codex",
        displayName: "Codex",
        defaultCommand: "codex",
        commandEnvironmentVariables: [
          "SIDEMESH_CODEX_BIN",
          "SIDEMESH_PROVIDER_COMMAND",
        ],
      },
      {
        kind: "fake",
        displayName: "Fake Test Provider",
        defaultCommand: "builtin",
        commandEnvironmentVariables: [
          "SIDEMESH_FAKE_LATENCY_MS",
          "SIDEMESH_FAKE_SEED",
          "SIDEMESH_FAKE_WORKSPACE_ROOT",
          "SIDEMESH_FAKE_CAPABILITY_PROFILE",
        ],
      },
      {
        kind: "copilot",
        displayName: "GitHub Copilot",
        defaultCommand: "copilot",
        commandEnvironmentVariables: [
          "SIDEMESH_COPILOT_BIN",
          "SIDEMESH_PROVIDER_COMMAND",
          "SIDEMESH_COPILOT_STATE_DIR",
          "SIDEMESH_COPILOT_ALLOW_ALL",
        ],
      },
    ]);
  });

  it("loads Codex command overrides in provider-specific priority order", () => {
    assert.deepEqual(loadAgentProviderConfig("codex", {}), {
      kind: "codex",
      bin: "codex",
    });
    assert.deepEqual(
      loadAgentProviderConfig("codex", {
        SIDEMESH_PROVIDER_COMMAND: "custom-agent",
      }),
      {
        kind: "codex",
        bin: "custom-agent",
      },
    );
    assert.deepEqual(
      loadAgentProviderConfig("codex", {
        SIDEMESH_CODEX_BIN: "codex-beta",
        SIDEMESH_PROVIDER_COMMAND: "custom-agent",
      }),
      {
        kind: "codex",
        bin: "codex-beta",
      },
    );
  });

  it("summarizes and constructs the Codex provider", () => {
    const config = { kind: "codex" as const, bin: "codex-beta" };

    assert.deepEqual(summarizeAgentProviderConfig(config), {
      kind: "codex",
      command: "codex-beta",
    });

    const provider = createAgentProviderFromConfig(config);
    assert.ok(provider instanceof CodexAgentProvider);
    assert.equal(provider.kind, "codex");
    assert.equal(provider.displayName, "Codex");
  });

  it("loads and constructs the fake test provider", () => {
    const config = loadAgentProviderConfig("fake", {
      SIDEMESH_FAKE_LATENCY_MS: "0",
      SIDEMESH_FAKE_SEED: "0",
      SIDEMESH_FAKE_WORKSPACE_ROOT: "/tmp/sidemesh-fake",
      SIDEMESH_FAKE_CAPABILITY_PROFILE: "chat-only",
    });

    assert.deepEqual(config, {
      kind: "fake",
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: "/tmp/sidemesh-fake",
      capabilityProfile: "chat-only",
    });
    assert.deepEqual(summarizeAgentProviderConfig(config), {
      kind: "fake",
      command: "builtin",
    });

    const provider = createAgentProviderFromConfig(config);
    assert.ok(provider instanceof FakeAgentProvider);
    assert.equal(provider.kind, "fake");
    assert.equal(provider.displayName, "Fake Test Provider");
    assert.equal(provider.capabilities.input.text, true);
    assert.equal(provider.capabilities.input.imageUrl, false);
  });

  it("rejects unknown fake capability profiles", () => {
    assert.throws(
      () =>
        loadAgentProviderConfig("fake", {
          SIDEMESH_FAKE_CAPABILITY_PROFILE: "not-real",
        }),
      /Unsupported SIDEMESH_FAKE_CAPABILITY_PROFILE/,
    );
  });

  it("loads and constructs the Copilot provider", () => {
    const config = loadAgentProviderConfig("copilot", {
      SIDEMESH_COPILOT_BIN: "copilot-beta",
      SIDEMESH_PROVIDER_COMMAND: "ignored",
      SIDEMESH_COPILOT_STATE_DIR: "/tmp/sidemesh-copilot",
      SIDEMESH_COPILOT_ALLOW_ALL: "true",
    });

    assert.deepEqual(config, {
      kind: "copilot",
      bin: "copilot-beta",
      stateDir: "/tmp/sidemesh-copilot",
      allowAll: true,
    });
    assert.deepEqual(summarizeAgentProviderConfig(config), {
      kind: "copilot",
      command: "copilot-beta",
    });

    const provider = createAgentProviderFromConfig(config);
    assert.ok(provider instanceof CopilotAgentProvider);
    assert.equal(provider.kind, "copilot");
    assert.equal(provider.displayName, "GitHub Copilot");
    assert.equal(provider.capabilities.input.text, true);
    assert.equal(provider.capabilities.input.localImage, false);
  });
});
