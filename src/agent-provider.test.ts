import { EventEmitter } from "node:events";
import { describe, it } from "node:test";
import assert from "node:assert/strict";

import {
  hasProviderMethod,
  requireProviderMethod,
  type AgentProvider,
  type AgentProviderCapabilities,
} from "./agent-provider.js";
import { mergeRecentUnindexedThreads } from "./server.js";
import type { ThreadRecord } from "./types.js";

const EMPTY_CAPABILITIES: AgentProviderCapabilities = {
  sessions: {
    create: false,
    resume: false,
    rename: false,
    archive: false,
    compact: false,
    interrupt: false,
    history: false,
    eventReplay: false,
    recentFallback: false,
    searchSessions: false,
  },
  input: {
    text: false,
    imageUrl: false,
    localImage: false,
    skills: false,
    fileMentions: false,
  },
  interaction: {
    userInput: false,
    elicitation: false,
  },
  approvals: {
    command: false,
    tool: false,
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
    mode: false,
    reasoningEffort: false,
    fastMode: false,
    approvalPolicy: false,
    sandboxMode: false,
    networkAccess: false,
    webSearch: false,
  },
  workspace: {
    filesystem: false,
    remoteGitDiff: false,
  },
  lifecycle: {
    restart: false,
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

describe("recent fallback session merge", () => {
  it("lets newer unindexed rollout sessions displace full indexed results", async () => {
    const indexed = [
      thread("indexed-1", 100),
      thread("indexed-2", 90),
    ];
    const provider = makeProvider({
      capabilities: {
        ...EMPTY_CAPABILITIES,
        sessions: {
          ...EMPTY_CAPABILITIES.sessions,
          recentFallback: true,
    searchSessions: true,
        },
      },
      listRecentUnindexedSessionThreads: async () => [
        thread("fallback-new", 120),
        thread("fallback-old", 80),
      ],
    });

    const merged = await mergeRecentUnindexedThreads(provider, indexed, 2);

    assert.deepEqual(
      merged.map((item) => item.id),
      ["fallback-new", "indexed-1"],
    );
  });
});

function thread(id: string, updatedAt: number): ThreadRecord {
  return {
    id,
    name: null,
    preview: id,
    createdAt: updatedAt,
    updatedAt,
    cwd: "/workspace",
    source: "cli",
    path: `/tmp/${id}.jsonl`,
    status: { type: "idle" },
    gitInfo: null,
  };
}
