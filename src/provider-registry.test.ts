import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { CodexAgentProvider } from "./codex-provider.js";
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
    assert.deepEqual(supportedAgentProviderKinds(), ["codex"]);
    assert.equal(isAgentProviderKind("codex"), true);
    assert.equal(isAgentProviderKind("copilot"), false);
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
});
