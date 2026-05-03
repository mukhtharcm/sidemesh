import { Buffer } from "node:buffer";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { after, describe, it } from "node:test";

import { FakeAgentProvider } from "./fake-provider.js";
import type {
  AgentPendingAction,
  AgentProviderLiveEvent,
  AgentSessionInputItem,
  AgentSessionOverrides,
} from "./agent-provider.js";

const EMPTY_OVERRIDES: AgentSessionOverrides = {
    model: null,
    mode: null,
    reasoningEffort: null,
    fastMode: null,
  approvalPolicy: null,
  sandboxMode: null,
  networkAccess: null,
  webSearch: null,
  profile: null,
};

describe("fake test provider", () => {
  const tempRoots: string[] = [];

  after(async () => {
    await Promise.all(tempRoots.map((root) => rm(root, { recursive: true, force: true })));
  });

  it("streams chat, tool activity, approvals, images, and replayable history", async () => {
    const cwd = await tempRoot(tempRoots);
    const provider = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: cwd,
    });
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    await provider.start();

    const input: AgentSessionInputItem[] = [
      {
        type: "text",
        text: "run tools with approval:command approval:tool approval:file approval:permissions image",
        text_elements: [],
      },
      {
        type: "image",
        url: "data:image/png;base64,ZmFrZQ==",
      },
      {
        type: "skill",
        name: "fake code review",
        path: "fake://skills/code-review/SKILL.md",
      },
    ];
    const created = await provider.createSession({
      cwd,
      input,
      overrides: {
        ...EMPTY_OVERRIDES,
        model: "fake-vision",
        reasoningEffort: "high",
        fastMode: true,
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
        networkAccess: true,
        webSearch: "live",
        profile: "balanced",
      },
    });

    assert.ok(created.activeTurnId);
    assert.equal(created.runtime?.model, "fake-vision");
    assert.equal(created.runtime?.serviceTier, "fast");

    for (const kind of ["command", "tool", "file_change", "permissions"] as const) {
      const action = await waitFor(
        () => openedAction(events, kind),
        `approval ${kind}`,
      );
      assert.equal(provider.respondToPendingAction(action, null), false);
      assert.equal(provider.respondToPendingAction(action, "accept"), true);
    }

    const completed = await waitFor(
      () => events.find((event) => event.type === "turn_completed"),
      "turn completion",
    );
    assert.equal(completed.type, "turn_completed");
    assert.equal(completed.status, "completed");

    const thread = await provider.readSessionThread(created.thread.id, true);
    assert.equal(thread.turns?.length, 1);
    assert.equal(thread.turns?.[0]?.status, "completed");

    const log = await provider.readSessionLog(thread);
    assert.equal(log.messages[0]?.role, "user");
    assert.equal(log.messages[0]?.attachments.length, 1);
    assert.ok(log.messages.some((message) => message.text.includes("Fake provider response complete")));
    assert.deepEqual(
      [...new Set(log.activities.map((activity) => activity.type))].sort(),
      ["command", "file_change", "image_generation", "tool", "turn_diff", "web_search"],
    );
    assert.ok(log.nextSeq > 0);

    const paged = await provider.readSessionLog(thread, {
      messageLimit: 1,
      activityLimit: 2,
    });
    assert.equal(paged.messages.length, 1);
    assert.equal(paged.activities.length, 2);
    assert.equal(paged.totalMessages, log.totalMessages);
    assert.equal(paged.totalActivities, log.totalActivities);
  });

  it("supports session lifecycle operations without Codex", async () => {
    const cwd = await tempRoot(tempRoots);
    const provider = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: cwd,
    });
    await provider.start();

    const created = await provider.createSession({
      cwd,
      input: [],
      overrides: EMPTY_OVERRIDES,
    });
    assert.equal(created.activeTurnId, null);
    assert.deepEqual(await provider.listLoadedSessionIds(), [created.thread.id]);

    await provider.setSessionName(created.thread.id, "Renamed fake session");
    assert.equal(
      (await provider.readSessionThread(created.thread.id, false)).name,
      "Renamed fake session",
    );

    const compacted = await provider.compactSession(created.thread.id);
    assert.deepEqual(compacted, {
      compacted: true,
      tokensRemoved: 0,
      messagesRemoved: 0,
    });
    const runtime = await provider.readSessionRuntime(created.thread);
    assert.equal(runtime?.telemetry?.compaction?.status, "completed");

    await provider.archiveSession(created.thread.id);
    assert.deepEqual(await provider.listSessionThreads({ limit: 10, archived: false }), []);
    assert.equal(
      (await provider.listSessionThreads({ limit: 10, archived: true })).length,
      1,
    );
    assert.deepEqual(await provider.listLoadedSessionIds(), []);

    await provider.unarchiveSession(created.thread.id);
    await provider.resumeSessionThread(created.thread.id, {
      persistExtendedHistory: true,
    });
    assert.deepEqual(await provider.listLoadedSessionIds(), [created.thread.id]);
  });

  it("supports configuration APIs and skill change events", async () => {
    const cwd = await tempRoot(tempRoots);
    const provider = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: cwd,
    });
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    await provider.start();

    const models = await provider.listModels({
      cwd,
      profile: null,
      provider: null,
    });
    const balanced = models.find((model) => model.model === "fake-balanced");
    const auto = models.find((model) => model.model === "fake-auto");
    assert.equal(balanced?.reasoningEffortControl, "client");
    assert.equal(balanced?.sortOrder, 0);
    assert.equal(auto?.reasoningEffortControl, "provider");
    assert.equal(auto?.sortOrder, 1);
    assert.equal(models.some((model) => model.inputModalities.includes("image")), true);

    const profiles = await provider.listProfiles({ cwd });
    assert.equal(profiles.defaultProfile, "balanced");
    assert.equal(profiles.profiles.some((profile) => profile.name === "locked-down"), true);

    let skills = await provider.listSkills({ cwd, forceReload: false });
    assert.equal(skills.skills.some((skill) => skill.scope === "repo"), true);
    assert.equal(
      skills.skills.find((skill) => skill.name === "fake code review")?.enabled,
      true,
    );

    await provider.writeSkillConfig({
      name: "fake code review",
      path: null,
      enabled: false,
    });
    await waitFor(
      () => events.find((event) => event.type === "skills_changed"),
      "skills_changed event",
    );
    skills = await provider.listSkills({ cwd, forceReload: true });
    assert.equal(
      skills.skills.find((skill) => skill.name === "fake code review")?.enabled,
      false,
    );
  });

  it("supports filesystem APIs and watch notifications", async () => {
    const cwd = await tempRoot(tempRoots);
    const provider = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: cwd,
    });
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    await provider.start();

    const watch = await provider.fsWatch(cwd);
    const filePath = nodePath.join(cwd, "notes", "fake.md");
    await provider.fsCreateDirectory(nodePath.dirname(filePath), true);
    await provider.fsWriteFile(
      filePath,
      Buffer.from("# Fake\n").toString("base64"),
    );

    const changed = await waitFor(
      () =>
        events.find(
          (event) => event.type === "fs_changed" && event.watchId === watch.watchId,
        ),
      "fs_changed event",
    );
    assert.equal(changed.type, "fs_changed");
    assert.deepEqual(changed.changedPaths, [nodePath.dirname(filePath)]);

    const listing = await provider.fsReadDirectory(nodePath.join(cwd, "notes"));
    assert.deepEqual(listing.entries.map((entry) => entry.fileName), ["fake.md"]);

    const metadata = await provider.fsGetMetadata(filePath);
    assert.equal(metadata.isFile, true);

    const file = await provider.fsReadFile(filePath);
    assert.equal(Buffer.from(file.dataBase64, "base64").toString("utf8"), "# Fake\n");

    const copyPath = nodePath.join(cwd, "notes", "copy.md");
    await provider.fsCopy({
      sourcePath: filePath,
      destinationPath: copyPath,
      recursive: false,
    });
    assert.equal((await provider.fsGetMetadata(copyPath)).isFile, true);

    await provider.fsRemove(copyPath, { recursive: false, force: false });
    await assert.rejects(() => provider.fsGetMetadata(copyPath));

    await provider.fsUnwatch(watch.watchId);
  });

  it("can simulate a chat-only provider without attachments, tools, approvals, or configuration", async () => {
    const cwd = await tempRoot(tempRoots);
    const provider = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: cwd,
      capabilityProfile: "chat-only",
    });
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    await provider.start();

    assert.equal(provider.capabilities.input.text, true);
    assert.equal(provider.capabilities.input.imageUrl, false);
    assert.equal(provider.capabilities.input.localImage, false);
    assert.equal(provider.capabilities.input.skills, false);
    assert.equal(provider.capabilities.configuration.models, false);
    assert.equal(provider.capabilities.runtimeControls.model, false);
    assert.equal(provider.capabilities.approvals.command, false);

    const created = await provider.createSession({
      cwd,
      input: [
        {
          type: "text",
          text: "tools approval:command approval:tool approval:file approval:permissions image",
          text_elements: [],
        },
      ],
      overrides: EMPTY_OVERRIDES,
    });

    await waitFor(
      () =>
        events.find(
          (event) =>
            event.type === "turn_completed" &&
            event.sessionId === created.thread.id,
        ),
      "chat-only turn completion",
    );
    assert.equal(
      events.some((event) => event.type === "action_opened"),
      false,
    );

    const log = await provider.readSessionLog(
      await provider.readSessionThread(created.thread.id, true),
    );
    assert.equal(log.activities.length, 0);
    assert.ok(
      log.messages.some((message) =>
        message.text.includes("Fake command approval skipped"),
      ),
    );
  });

  it("can simulate providers without filesystem or model controls", async () => {
    const cwd = await tempRoot(tempRoots);
    const noFiles = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: cwd,
      capabilityProfile: "no-files",
    });
    const noFilesEvents: AgentProviderLiveEvent[] = [];
    noFiles.on("liveEvent", (event) => noFilesEvents.push(event));
    await noFiles.start();

    assert.equal(noFiles.capabilities.workspace.remoteGitDiff, false);
    assert.equal(noFiles.capabilities.configuration.models, true);

    const noFilesSession = await noFiles.createSession({
      cwd,
      input: [{ type: "text", text: "tools", text_elements: [] }],
      overrides: EMPTY_OVERRIDES,
    });
    await waitFor(
      () =>
        noFilesEvents.find(
          (event) =>
            event.type === "turn_completed" &&
            event.sessionId === noFilesSession.thread.id,
        ),
      "no-files turn completion",
    );
    const noFilesLog = await noFiles.readSessionLog(
      await noFiles.readSessionThread(noFilesSession.thread.id, true),
    );
    assert.deepEqual(
      [...new Set(noFilesLog.activities.map((activity) => activity.type))].sort(),
      ["command", "tool", "web_search"],
    );

    const noModelControls = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      workspaceRoot: cwd,
      capabilityProfile: "no-model-controls",
    });
    assert.equal(noModelControls.capabilities.configuration.models, false);
    assert.equal(noModelControls.capabilities.configuration.profiles, false);
    assert.equal(noModelControls.capabilities.runtimeControls.model, false);
    assert.equal(noModelControls.capabilities.runtimeControls.fastMode, false);
    assert.equal(noModelControls.capabilities.approvals.command, true);
    assert.equal(noModelControls.capabilities.workspace.remoteGitDiff, true);
  });

  it("can simulate providers without approvals and minimal session controls", async () => {
    const noApprovals = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      capabilityProfile: "no-approvals",
    });
    assert.equal(noApprovals.capabilities.approvals.command, false);
    assert.equal(noApprovals.capabilities.approvals.tool, false);
    assert.equal(noApprovals.capabilities.approvals.fileChange, false);
    assert.equal(noApprovals.capabilities.approvals.permissions, false);
    assert.equal(noApprovals.capabilities.runtimeControls.approvalPolicy, false);
    assert.equal(noApprovals.capabilities.configuration.models, true);
    assert.equal(noApprovals.capabilities.workspace.remoteGitDiff, true);

    const minimal = new FakeAgentProvider({
      latencyMs: 0,
      seedSessions: false,
      capabilityProfile: "minimal",
    });
    assert.equal(minimal.capabilities.sessions.create, true);
    assert.equal(minimal.capabilities.sessions.history, true);
    assert.equal(minimal.capabilities.sessions.resume, false);
    assert.equal(minimal.capabilities.sessions.rename, false);
    assert.equal(minimal.capabilities.sessions.archive, false);
    assert.equal(minimal.capabilities.sessions.compact, false);
    assert.equal(minimal.capabilities.sessions.interrupt, false);
    assert.equal(minimal.capabilities.sessions.eventReplay, false);
    assert.equal(minimal.capabilities.input.text, true);
    assert.equal(minimal.capabilities.input.imageUrl, false);
    assert.equal(minimal.capabilities.configuration.models, false);
    assert.equal(minimal.capabilities.workspace.remoteGitDiff, false);
  });

  it("can fail and interrupt turns deterministically", async () => {
    const cwd = await tempRoot(tempRoots);
    const provider = new FakeAgentProvider({
      latencyMs: 20,
      seedSessions: false,
      workspaceRoot: cwd,
    });
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    await provider.start();

    const failing = await provider.createSession({
      cwd,
      input: [
        {
          type: "text",
          text: "please fail",
          text_elements: [],
        },
      ],
      overrides: EMPTY_OVERRIDES,
    });
    await waitFor(
      () =>
        events.find(
          (event) =>
            event.type === "turn_completed" &&
            event.sessionId === failing.thread.id,
        ),
      "failed turn",
    );
    const failedTurn = (await provider.readSessionThread(failing.thread.id, true)).turns?.[0];
    assert.equal(failedTurn?.status, "failed");

    const interruptible = await provider.createSession({
      cwd,
      input: [
        {
          type: "text",
          text: "slow response",
          text_elements: [],
        },
      ],
      overrides: EMPTY_OVERRIDES,
    });
    assert.ok(interruptible.activeTurnId);
    await provider.interruptTurn(interruptible.thread.id, interruptible.activeTurnId);
    const interruptedTurn = (await provider.readSessionThread(
      interruptible.thread.id,
      true,
    )).turns?.[0];
    assert.equal(interruptedTurn?.status, "interrupted");

    const approvalBlocked = await provider.createSession({
      cwd,
      input: [
        {
          type: "text",
          text: "approval:command",
          text_elements: [],
        },
      ],
      overrides: EMPTY_OVERRIDES,
    });
    assert.ok(approvalBlocked.activeTurnId);
    await waitFor(
      () => openedAction(events, "command"),
      "interruptible approval",
    );
    await provider.interruptTurn(
      approvalBlocked.thread.id,
      approvalBlocked.activeTurnId,
    );
    const approvalTurn = (await provider.readSessionThread(
      approvalBlocked.thread.id,
      true,
    )).turns?.[0];
    assert.equal(approvalTurn?.status, "interrupted");
  });
});

function openedAction(
  events: AgentProviderLiveEvent[],
  kind: AgentPendingAction["kind"],
): AgentPendingAction | null {
  const event = events.find(
    (candidate) =>
      candidate.type === "action_opened" && candidate.action.kind === kind,
  );
  return event?.type === "action_opened" ? event.action : null;
}

async function tempRoot(roots: string[]): Promise<string> {
  const root = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-fake-provider-"));
  roots.push(root);
  return root;
}

async function waitFor<T>(
  getValue: () => T | null | undefined,
  label: string,
): Promise<NonNullable<T>> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const value = getValue();
    if (value !== null && value !== undefined) {
      return value;
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`Timed out waiting for ${label}`);
}
