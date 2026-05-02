import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  CODEX_PROVIDER_CAPABILITIES,
  CodexAgentProvider,
} from "./codex-provider.js";
import {
  COPILOT_PROVIDER_CAPABILITIES,
  CopilotAgentProvider,
} from "./copilot-provider.js";
import {
  FAKE_PROVIDER_CAPABILITIES,
  FakeAgentProvider,
} from "./fake-provider.js";
import {
  PI_PROVIDER_CAPABILITIES,
  PiAgentProvider,
} from "./pi-provider.js";
import {
  DEFAULT_AGENT_PROVIDER_KIND,
  createAgentProviderFromConfig,
  isAgentProviderKind,
  listAgentProviderDefinitionSummaries,
  listSetupAgentProviderDefinitionSummaries,
  loadAgentProviderConfig,
  summarizeAgentProviderConfig,
  supportedAgentProviderKinds,
} from "./provider-registry.js";

describe("provider registry", () => {
  it("reports Codex as the default supported provider", () => {
    assert.equal(DEFAULT_AGENT_PROVIDER_KIND, "codex");
    assert.deepEqual(supportedAgentProviderKinds(), [
      "codex",
      "pi",
      "fake",
      "copilot",
    ]);
    assert.equal(isAgentProviderKind("codex"), true);
    assert.equal(isAgentProviderKind("pi"), true);
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
        supportedApprovalPolicies: [
          "untrusted",
          "on-failure",
          "on-request",
          "never",
        ],
        capabilities: CODEX_PROVIDER_CAPABILITIES,
        setupAudience: "public",
      },
      {
        kind: "pi",
        displayName: "Pi",
        defaultCommand: "sdk",
        commandEnvironmentVariables: [
          "SIDEMESH_PI_AGENT_DIR",
          "SIDEMESH_PI_STATE_DIR",
          "PI_CODING_AGENT_DIR",
        ],
        supportedApprovalPolicies: [],
        capabilities: PI_PROVIDER_CAPABILITIES,
        setupAudience: "public",
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
        supportedApprovalPolicies: [
          "untrusted",
          "on-failure",
          "on-request",
          "never",
        ],
        capabilities: FAKE_PROVIDER_CAPABILITIES,
        setupAudience: "dev",
      },
      {
        kind: "copilot",
        displayName: "GitHub Copilot",
        defaultCommand: "copilot",
        commandEnvironmentVariables: [
          "SIDEMESH_ENABLE_COPILOT",
          "SIDEMESH_COPILOT_BIN",
          "SIDEMESH_PROVIDER_COMMAND",
          "SIDEMESH_COPILOT_STATE_DIR",
          "SIDEMESH_COPILOT_ALLOW_ALL",
          "SIDEMESH_COPILOT_MODEL",
          "COPILOT_MODEL",
          "COPILOT_PROVIDER_MODEL_ID",
          "COPILOT_PROVIDER_WIRE_MODEL",
        ],
        supportedApprovalPolicies: ["on-request", "never"],
        capabilities: COPILOT_PROVIDER_CAPABILITIES,
        setupAudience: "dev",
      },
    ]);
  });

  it("hides dev-only providers from the normal setup wizard", () => {
    assert.deepEqual(
      listSetupAgentProviderDefinitionSummaries().map((summary) => summary.kind),
      ["codex", "pi"],
    );
    assert.deepEqual(
      listSetupAgentProviderDefinitionSummaries({
        includeKinds: ["fake"],
      }).map((summary) => summary.kind),
      ["codex", "pi", "fake"],
    );
    assert.deepEqual(
      listSetupAgentProviderDefinitionSummaries({
        includeDev: true,
      }).map((summary) => summary.kind),
      ["codex", "pi", "fake", "copilot"],
    );
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

  it("loads and constructs the Pi provider", () => {
    const config = loadAgentProviderConfig("pi", {
      SIDEMESH_PI_AGENT_DIR: "/tmp/pi-agent",
      SIDEMESH_PI_STATE_DIR: "/tmp/sidemesh-pi",
    });

    assert.deepEqual(config, {
      kind: "pi",
      agentDir: "/tmp/pi-agent",
      stateDir: "/tmp/sidemesh-pi",
    });
    assert.deepEqual(summarizeAgentProviderConfig(config), {
      kind: "pi",
      command: "sdk",
    });

    const provider = createAgentProviderFromConfig(config);
    assert.ok(provider instanceof PiAgentProvider);
    assert.equal(provider.kind, "pi");
    assert.equal(provider.displayName, "Pi");
    assert.equal(provider.capabilities.input.text, true);
    assert.equal(provider.capabilities.input.imageUrl, false);
    assert.equal(provider.capabilities.input.localImage, true);
    assert.equal(provider.capabilities.input.skills, true);
    assert.equal(provider.capabilities.configuration.models, true);
    assert.equal(provider.capabilities.configuration.skills, true);
    assert.equal(provider.capabilities.configuration.prompts, true);
    assert.equal(provider.capabilities.configuration.skillManagement, false);
    assert.equal(provider.capabilities.runtimeControls.model, true);
    assert.equal(provider.capabilities.runtimeControls.reasoningEffort, true);
    assert.equal(provider.capabilities.interaction.userInput, false);
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
      SIDEMESH_COPILOT_MODEL: "claude-sonnet-4.6",
    });

    assert.deepEqual(config, {
      kind: "copilot",
      bin: "copilot-beta",
      stateDir: "/tmp/sidemesh-copilot",
      allowAll: true,
      configuredModel: "claude-sonnet-4.6",
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
    assert.equal(provider.capabilities.input.imageUrl, true);
    assert.equal(provider.capabilities.input.localImage, true);
    assert.equal(provider.capabilities.input.skills, true);
    assert.equal(provider.capabilities.interaction.userInput, true);
    assert.equal(provider.capabilities.interaction.elicitation, true);
    assert.equal(provider.capabilities.configuration.models, true);
    assert.equal(provider.capabilities.configuration.skills, true);
    assert.equal(provider.capabilities.configuration.prompts, false);
    assert.equal(provider.capabilities.configuration.skillManagement, true);
    assert.equal(provider.capabilities.runtimeControls.model, true);
    assert.equal(provider.capabilities.runtimeControls.mode, true);
  });

  it("still exposes Copilot model controls without an explicit configured model", () => {
    const config = loadAgentProviderConfig("copilot", {});

    assert.deepEqual(config, {
      kind: "copilot",
      bin: "copilot",
      stateDir: null,
      allowAll: false,
      configuredModel: null,
    });

    const provider = createAgentProviderFromConfig(config);
    assert.equal(provider.capabilities.configuration.models, true);
    assert.equal(provider.capabilities.runtimeControls.model, true);
    assert.equal(provider.capabilities.runtimeControls.mode, true);
  });
});
