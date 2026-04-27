import { EventEmitter } from "node:events";
import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  hasProviderMethod,
  requireProviderMethod,
  type AgentProvider,
  type AgentProviderCapabilities,
} from "./agent-provider.js";

const EMPTY_CAPABILITIES: AgentProviderCapabilities = {
  sessions: {
    create: false,
    resume: false,
    rename: false,
    archive: false,
    interrupt: false,
    history: false,
    eventReplay: false,
    recentFallback: false,
  },
  input: {
    text: false,
    imageUrl: false,
    localImage: false,
    skills: false,
  },
  approvals: {
    command: false,
    fileChange: false,
    permissions: false,
    approveForSession: false,
  },
  configuration: {
    models: false,
    profiles: false,
    skills: false,
    skillManagement: false,
  },
  runtimeControls: {
    model: false,
    reasoningEffort: false,
    fastMode: false,
    approvalPolicy: false,
    sandboxMode: false,
    networkAccess: false,
    webSearch: false,
  },
  workspace: {
    filesystem: false,
    gitStatus: false,
    gitDiff: false,
    remoteGitDiff: false,
  },
};

function makeProvider(methods: Partial<AgentProvider> = {}): AgentProvider {
  return Object.assign(new EventEmitter(), {
    kind: "test",
    displayName: "Test Provider",
    capabilities: EMPTY_CAPABILITIES,
    start: async () => {},
    getVersion: async () => "test-1.0.0",
  }, methods) as AgentProvider;
}

describe("provider method guards", () => {
  it("detects implemented optional methods", async () => {
    const provider = makeProvider({
      listModels: async () => [],
    });

    assert.equal(hasProviderMethod(provider, "listModels"), true);
    assert.equal(hasProviderMethod(provider, "listSkills"), false);

    const listModels = requireProviderMethod(provider, "listModels", "model listing");
    assert.deepEqual(await listModels.call(provider, {
      cwd: null,
      profile: null,
      provider: null,
    }), []);
  });

  it("throws a provider-specific message for missing optional methods", () => {
    const provider = makeProvider();

    assert.throws(
      () => requireProviderMethod(provider, "listModels", "model listing"),
      /Test Provider does not implement model listing/,
    );
  });
});
