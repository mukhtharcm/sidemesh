import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { setTimeout as delay } from "node:timers/promises";

import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { SessionStore } from "./session-store.js";
import { PiRpc } from "./pi-rpc.js";
import { piBranch, preparePiInput } from "./pi-mapping.js";

import { PiAgentProvider } from "./pi-provider.js";
import type { AgentCreateSessionRequest, AgentProviderLiveEvent } from "./agent-provider.js";

describe("PiAgentProvider", () => {
  let tempDir = "";
  let agentDir = "";
  let stateDir = "";
  const providers: PiAgentProvider[] = [];

  beforeEach(async () => {
    tempDir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-pi-provider-"));
    agentDir = nodePath.join(tempDir, "pi-agent");
    stateDir = nodePath.join(tempDir, "pi-state");
    await mkdir(agentDir, { recursive: true });
  });

  afterEach(async () => {
    await Promise.all(providers.splice(0).map((provider) => provider.close()));
    if (tempDir) {
      await rm(tempDir, {
        recursive: true,
        force: true,
        maxRetries: 5,
        retryDelay: 50,
      });
    }
  });

  it("lists and parses persisted Pi session history", async () => {
    const cwd = nodePath.join(tempDir, "repo");
    const sessionDir = piSessionDirForCwd(cwd, agentDir);
    await mkdir(sessionDir, { recursive: true });
    const sessionPath = nodePath.join(sessionDir, "2026-05-01_session-1.jsonl");
    await writeFile(
      sessionPath,
      [
        JSON.stringify({
          type: "session",
          version: 3,
          id: "session-1",
          timestamp: "2026-05-01T10:00:00.000Z",
          cwd,
        }),
        JSON.stringify({
          type: "message",
          id: "m1",
          parentId: null,
          timestamp: "2026-05-01T10:00:01.000Z",
          message: {
            role: "user",
            content: [{ type: "text", text: "Inspect README" }],
            timestamp: 1_777_770_001_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m2",
          parentId: "m1",
          timestamp: "2026-05-01T10:00:02.000Z",
          message: {
            role: "assistant",
            content: [
              { type: "text", text: "Checking the file." },
              {
                type: "toolCall",
                id: "call-read",
                name: "read",
                arguments: { path: "README.md" },
              },
            ],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: {
              input: 10,
              output: 20,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 30,
              cost: {
                input: 0.001,
                output: 0.002,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0.003,
              },
            },
            stopReason: "toolUse",
            timestamp: 1_777_770_002_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m3",
          parentId: "m2",
          timestamp: "2026-05-01T10:00:03.000Z",
          message: {
            role: "toolResult",
            toolCallId: "call-read",
            toolName: "read",
            content: [{ type: "text", text: "# README" }],
            isError: false,
            timestamp: 1_777_770_003_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m4",
          parentId: "m3",
          timestamp: "2026-05-01T10:00:04.000Z",
          message: {
            role: "assistant",
            content: [
              { type: "text", text: "Updating the intro." },
              {
                type: "toolCall",
                id: "call-edit",
                name: "edit",
                arguments: { path: "README.md" },
              },
            ],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: {
              input: 11,
              output: 21,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 32,
              cost: {
                input: 0.001,
                output: 0.002,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0.003,
              },
            },
            stopReason: "toolUse",
            timestamp: 1_777_770_004_000,
          },
        }),
        JSON.stringify({
          type: "message",
          id: "m5",
          parentId: "m4",
          timestamp: "2026-05-01T10:00:05.000Z",
          message: {
            role: "toolResult",
            toolCallId: "call-edit",
            toolName: "edit",
            content: [{ type: "text", text: "README updated" }],
            details: {
              diff: "@@ -1 +1 @@\n-Old\n+New",
              firstChangedLine: 1,
            },
            isError: false,
            timestamp: 1_777_770_005_000,
          },
        }),
        JSON.stringify({
          type: "compaction",
          id: "c1",
          parentId: "m5",
          timestamp: "2026-05-01T10:00:06.000Z",
          summary: "Compacted earlier context.",
          firstKeptEntryId: "m3",
          tokensBefore: 1200,
        }),
        JSON.stringify({
          type: "session_info",
          id: "s1",
          parentId: "c1",
          timestamp: "2026-05-01T10:00:07.000Z",
          name: "Pi README session",
        }),
        JSON.stringify({
          type: "message",
          id: "m6",
          parentId: "s1",
          timestamp: "2026-05-01T10:00:08.000Z",
          message: {
            role: "assistant",
            content: [{ type: "text", text: "Done." }],
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            usage: {
              input: 12,
              output: 22,
              cacheRead: 0,
              cacheWrite: 0,
              totalTokens: 34,
              cost: {
                input: 0.001,
                output: 0.002,
                cacheRead: 0,
                cacheWrite: 0,
                total: 0.003,
              },
            },
            stopReason: "stop",
            timestamp: 1_777_770_008_000,
          },
        }),
      ].join("\n") + "\n",
    );

    const provider = new PiAgentProvider({ agentDir, stateDir });
    providers.push(provider);
    await provider.start();

    const threads = await provider.listSessionThreads({
      limit: 10,
      archived: false,
    });
    assert.equal(threads.length, 1);
    assert.equal(threads[0]?.id, "session-1");
    assert.equal(threads[0]?.name, "Pi README session");
    assert.equal(threads[0]?.source, "pi");
    assert.equal(threads[0]?.path, sessionPath);

    const log = await provider.readSessionLog(threads[0]!);
    assert.deepEqual(
      log.messages.map((message) => message.role),
      ["user", "assistant", "assistant", "assistant"],
    );
    assert.equal(log.messages[0]?.text, "Inspect README");
    assert.equal(log.messages[3]?.text, "Done.");
    assert.equal(log.runtime?.model, "anthropic/claude-sonnet-4-5");
    assert.equal(log.runtime?.modelProvider, "anthropic");
    assert.equal(log.runtime?.telemetry?.lastUsage?.outputTokens, 22);

    const activityTypes = log.activities.map((activity) => activity.type).sort();
    assert.deepEqual(activityTypes, [
      "context_compaction",
      "file_change",
      "tool",
      "tool",
    ]);

    const readActivity = log.activities.find(
      (activity) => activity.type === "tool" && activity.toolName === "read",
    ) as Extract<(typeof log.activities)[number], { type: "tool" }> | undefined;
    assert.equal(readActivity?.semantic?.category, "filesystem");
    assert.equal(readActivity?.semantic?.action, "read");

    const fileChange = log.activities.find(
      (activity) => activity.type === "file_change",
    );
    assert.ok(fileChange);

    if (readActivity?.semantic?.targets[0]?.type === "file") {
      readActivity.semantic.targets[0].path = "mutated.md";
    }
    if (fileChange?.type === "file_change") {
      fileChange.changes[0]!.diff = "mutated diff";
    }

    const reloadedLog = await provider.readSessionLog(threads[0]!);
    const reloadedReadActivity = reloadedLog.activities.find(
      (activity) => activity.type === "tool" && activity.toolName === "read",
    ) as Extract<(typeof reloadedLog.activities)[number], { type: "tool" }> | undefined;
    const reloadedFileChange = reloadedLog.activities.find(
      (activity) => activity.type === "file_change",
    );
    if (reloadedReadActivity?.semantic?.targets[0]?.type === "file") {
      assert.equal(reloadedReadActivity.semantic.targets[0].path, "README.md");
    } else {
      throw new Error("expected file semantic target");
    }
    assert.equal(
      reloadedFileChange?.type === "file_change"
        ? reloadedFileChange.changes[0]?.diff
        : null,
      "@@ -1 +1 @@\n-Old\n+New",
    );
  });

  async function fixture(providerId = "pi", sessionStore?: SessionStore) {
    const rpcEntry = nodePath.join(tempDir, "rpc.mjs");
    await writeFile(rpcEntry, RPC_FIXTURE);
    const provider = new PiAgentProvider({ agentDir, stateDir, rpcEntry, providerId, sessionStore });
    providers.push(provider);
    await provider.start();
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => events.push(event));
    const created = await provider.createSession({ cwd: tempDir, input: [], overrides });
    const send = (text: string, clientMessageId = `client-${Date.now()}`) => provider.submitInput({
      sessionId: created.thread.id, input: [{ type: "text", text, text_elements: [] }], overrides,
      activeTurnId: null, clientMessageId,
    });
    return { provider, created, events, send };
  }

  it("uses native RPC events, waits through retry, and confirms persisted messages without duplicates", async () => {
    const { provider, created, events, send } = await fixture();
    assert.equal(created.runtime?.commands?.[0]?.name, "fixture");
    const receipt = await send("hello", "client-hello");
    assert.equal(receipt.mode, "turn");
    await until(() => events.some((event) => event.type === "auto_retry_updated"));
    assert.equal(events.filter((event) => event.type === "turn_completed").length, 0);
    await until(() => events.some((event) => event.type === "turn_completed"));
    assert.equal((await provider.readSessionThread(created.thread.id, true)).status?.type, "idle");
    const log = await provider.readSessionSnapshot(created.thread.id);
    assert.equal(log.busy, false);
    assert.equal(log.activeTurnId, null);
    assert.deepEqual(log.confirmedInputIds, ["client-hello"]);
    assert.deepEqual(log.messages.map((message) => message.text), ["hello", "Done."]);
    assert.equal(log.messages[0]?.id, "client-hello");
    assert.deepEqual(log.messages[1]?.content, [{ type: "thinking", thinking: "Think first." }, { type: "text", text: "Done." }]);
    assert.ok(events.some((event) => event.type === "reasoning_delta"));
    assert.equal(events.filter((event) => event.type === "turn_completed").length, 1);
    const tool = log.activities.find((activity) => activity.type === "tool");
    assert.equal(tool?.status, "completed");
    assert.equal(tool?.attachments?.[0]?.url, "data:image/png;base64,aGk=");
    assert.ok(!JSON.stringify(tool?.result).includes("aGk="));
    const pid = Number(await readFile(nodePath.join(agentDir, "pid"), "utf8"));
    await provider.close();
    assert.throws(() => process.kill(pid, 0), /ESRCH/);
    const reopened = new PiAgentProvider({ agentDir, stateDir });
    providers.push(reopened);
    const cold = await reopened.readSessionLog(created.thread);
    assert.deepEqual(cold.messages, log.messages);
    assert.equal(await readFile(nodePath.join(agentDir, "token-present"), "utf8"), "false");
  });

  it("keeps live output that is absent from the native file after restart", async () => {
    const { provider, created, events, send } = await fixture();
    await send("undurable", "client-undurable");
    await until(() => events.some((event) => event.type === "turn_completed"));
    const warm = await provider.readSessionSnapshot(created.thread.id);
    assert.deepEqual(warm.confirmedInputIds, []);
    assert.equal(warm.messages.at(-1)?.text, "Done.");
    await provider.close();
    const reopened = new PiAgentProvider({ agentDir, stateDir });
    providers.push(reopened);
    const cold = await reopened.readSessionLog(created.thread);
    assert.deepEqual(cold.messages, warm.messages);
  });

  it("does not bind an input when a native event has different image content", async () => {
    const { provider, created, events } = await fixture();
    await provider.submitInput({ sessionId: created.thread.id, activeTurnId: null, clientMessageId: "image-input", overrides,
      input: [{ type: "text", text: "changed-image", text_elements: [] }, { type: "image", url: "data:image/png;base64,aGk=" }] });
    await until(() => events.some((event) => event.type === "turn_completed"));
    // This fixture emits text-only user history even when the prompt has an image.
    const snapshot = await provider.readSessionSnapshot(created.thread.id);
    assert.deepEqual(snapshot.confirmedInputIds, []);
    assert.equal(snapshot.messages.find((message) => message.id === "image-input")?.attachments.length, 1);
    assert.equal(snapshot.messages.filter((message) => message.role === "user").length, 2);
  });

  it("routes extension choices and cancellation and rejects unsupported input before prompt", async () => {
    const { provider, created, events, send } = await fixture();
    await assert.rejects(provider.submitInput({ sessionId: created.thread.id, activeTurnId: null,
      input: [{ type: "text", text: "must not send", text_elements: [] }], overrides: { ...overrides, model: "bad/model" } }), /not find|not available|Unknown|No Pi model/);
    await assert.rejects(provider.submitInput({ sessionId: created.thread.id, activeTurnId: null,
      input: [{ type: "image", url: "https://example.test/image.png" }], overrides }), /local images/);
    await provider.setSessionConfiguration(created.thread.id, "pi:auto-compaction", false);
    assert.equal((await provider.readSessionRuntime(created.thread))?.configurationOptions?.find((option) => option.id === "pi:auto-compaction")?.value, false);
    await send("question");
    await until(() => events.some((event) => event.type === "action_opened"));
    const opened = events.find((event) => event.type === "action_opened");
    assert.ok(opened?.type === "action_opened");
    assert.equal(provider.respondToPendingAction(opened.action, { answer: "unknown", wasFreeform: false }), false);
    assert.equal(provider.respondToPendingAction(opened.action, { decision: "cancel", scope: "once" }), true);
    await until(() => events.some((event) => event.type === "turn_completed"));
    const replies = await readFile(nodePath.join(agentDir, "requests"), "utf8");
    assert.ok(replies.includes('"cancelled":true'));
    assert.ok(!replies.includes("must not send"));
    assert.ok(events.some((event) => event.type === "action_resolved"));
  });

  it("aborts native work when no local turn ID is available", async () => {
    const { provider, created } = await fixture();
    await writeFile(nodePath.join(agentDir, "external-work"), "busy");
    const before = await provider.readSessionSnapshot(created.thread.id);
    assert.equal(before.busy, true);
    assert.equal(before.activeTurnId, null);
    assert.deepEqual(await provider.interruptTurn(created.thread.id, null), { interrupted: true });
    assert.equal((await provider.readSessionSnapshot(created.thread.id)).busy, false);
  });

  it("keeps one native turn for steering and aborts it before closing the process", async () => {
    const { provider, created, events, send } = await fixture();
    const first = await send("hold", "first");
    const second = await send("later", "second");
    assert.equal(second.mode, "steer");
    assert.equal(second.turnId, first.turnId);
    const snapshot = await provider.readSessionSnapshot(created.thread.id);
    assert.equal(snapshot.busy, true);
    assert.equal(snapshot.activeTurnId, first.turnId);
    assert.deepEqual(snapshot.confirmedInputIds, []);
    assert.equal(events.filter((event) => event.type === "turn_started").length, 1);
    await provider.interruptTurn(created.thread.id, first.turnId!);
    assert.ok(events.some((event) => event.type === "turn_completed" && event.status === "interrupted"));
    const log = await provider.readSessionLog(created.thread);
    assert.ok(log.messages.some((message) => message.id === "second" && message.text === "later"));
    assert.equal((await provider.readSessionThread(created.thread.id, false)).status?.type, "idle");
  });

  it("keeps the native compaction summary without duplicating its live activity", async () => {
    const { provider, created } = await fixture();
    await provider.compactSession(created.thread.id);
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.activities.length, 1);
    assert.ok(log.activities[0]?.type === "context_compaction");
    assert.equal(log.activities[0].summary, "Keep this context");
    assert.equal(log.runtime?.telemetry?.compaction?.preCompactionTokens, 1000);
  });

  it("keeps instance identity when two RPC processes use the same native session ID", async () => {
    const db = await SessionStore.open(nodePath.join(tempDir, "shared"));
    try {
      const a = await fixture("pi-a", db);
      const b = await fixture("pi-b", db);
      await a.send("hold", "a-user");
      await b.send("hold", "b-user");
      assert.notEqual(a.created.thread.id, b.created.thread.id);
      assert.equal(db.getProviderSession("pi-a", a.created.thread.id)?.nativeId, "native-session");
      assert.equal(db.getProviderSession("pi-b", b.created.thread.id)?.nativeId, "native-session");
      assert.equal(db.getSessionItem("pi-b", b.created.thread.id, "a-user"), null);
      await Promise.all([a.provider.close(), b.provider.close()]);
    } finally { db.close(); }
  });

  it("imports legacy recovery and archive records once and preserves the source file", async () => {
    await mkdir(stateDir, { recursive: true });
    const path = nodePath.join(stateDir, "sessions.json");
    const message = { id: "unconfirmed", role: "user", text: "Keep my input", attachments: [], createdAt: 1000, seq: 0 };
    const saved = { archivedSessionIds: ["archive-only"], sessions: [{
      thread: { id: "legacy", cwd: tempDir, path: null, name: "Old session", preview: "Old", createdAt: 1, updatedAt: 2 },
      messages: [], activities: [], preservedSidecarUserMessages: [{ message }],
      preservedSidecarMessages: [{ message: { ...message, role: "assistant", id: "answer", text: "Keep the answer", seq: 1 }, previousUserMessage: message }],
    }] };
    const source = JSON.stringify(saved);
    await writeFile(path, source);
    const provider = new PiAgentProvider({ agentDir, stateDir });
    providers.push(provider);
    const threads = await provider.listSessionThreads({ limit: 10, archived: false });
    assert.equal(threads[0]?.name, "Old session");
    const log = await provider.readSessionLog(threads[0]!);
    assert.deepEqual(log.messages.map((item) => item.text), ["Keep my input", "Keep the answer"]);
    assert.equal((await provider.listSessionThreads({ limit: 10, archived: true }))[0]?.id, "archive-only");
    assert.equal(await readFile(path, "utf8"), source);
    await provider.close();
    await writeFile(path, "invalid JSON");
    const reopened = new PiAgentProvider({ agentDir, stateDir });
    providers.push(reopened);
    assert.equal((await reopened.readSessionLog(threads[0]!)).messages.length, 2);
  });

  it("fails a malformed legacy import without marking the migration complete", async () => {
    await mkdir(stateDir, { recursive: true });
    await writeFile(nodePath.join(stateDir, "sessions.json"), '{"sessions":[{}]}');
    const provider = new PiAgentProvider({ agentDir, stateDir });
    providers.push(provider);
    await assert.rejects(provider.start());
    await provider.close();
    const db = await SessionStore.open(stateDir);
    try { assert.equal(db.hasMigration("pi-json-v1:pi"), false); }
    finally { db.close(); }
  });

  it("uses only the selected native branch and rejects broken parent chains", () => {
    const entry = (id: string, parentId: string | null) => ({ id, parentId, type: "message", timestamp: new Date().toISOString(),
      message: { role: "user", content: [{ type: "text", text: id }], timestamp: Date.now() } }) as SessionEntry;
    const entries = [entry("root", null), entry("old", "root"), entry("new", "root")];
    assert.deepEqual(piBranch(entries, "new").map((item) => item.id), ["root", "new"]);
    assert.throws(() => piBranch([entry("loop", "loop")], "loop"), /cycl/i);
    assert.throws(() => piBranch(entries, "missing"), /missing/i);
  });

  it("starts the installed official Pi RPC entry without a model request", async () => {
    const rpc = new PiRpc({ cwd: tempDir, agentDir, temporary: true });
    try {
      const state = await rpc.request({ type: "get_state" });
      assert.equal(state.isStreaming, false);
      const history = await rpc.request({ type: "get_entries" });
      assert.ok(Array.isArray(history.entries));
      const commands = await rpc.request({ type: "get_commands" });
      assert.ok(Array.isArray(commands.commands));
    } finally { await rpc.close(); }
  });

  it("handles a real Pi extension command and its input request without a model turn", async () => {
    await mkdir(nodePath.join(agentDir, "extensions"), { recursive: true });
    await writeFile(nodePath.join(agentDir, "extensions", "fixture.ts"), `
      export default function (pi) {
        pi.registerCommand("fixture", { description: "Local extension check", handler: async (_args, ctx) => {
          const choice = await ctx.ui.select("Choose a test value", ["First", "Second"]);
          pi.sendMessage({ customType: "fixture", content: "Selected: " + choice, display: true });
        } });
      }
    `);
    const provider = new PiAgentProvider({ agentDir, stateDir });
    providers.push(provider);
    const events: AgentProviderLiveEvent[] = [];
    provider.on("liveEvent", (event) => {
      events.push(event);
      if (event.type === "action_opened") assert.equal(provider.respondToPendingAction(event.action, { answer: "Second", wasFreeform: false }), true);
    });
    const created = await provider.createSession({ cwd: tempDir, input: [], overrides });
    assert.ok(created.runtime?.commands?.some((command) => command.name === "fixture"));
    await provider.submitInput({ sessionId: created.thread.id, activeTurnId: null, overrides,
      input: [{ type: "text", text: "/fixture", text_elements: [] }], clientMessageId: "real-command" });
    assert.ok(events.some((event) => event.type === "turn_completed"));
    assert.ok((await provider.readSessionLog(created.thread)).messages.some((message) => message.text === "Selected: Second"));
    assert.equal((await provider.readSessionThread(created.thread.id, false)).status?.type, "idle");
  });

  it("keeps local image bytes and file or skill context and rejects invalid data URLs", async () => {
    const path = nodePath.join(tempDir, "image.png");
    await writeFile(path, "image");
    const file = nodePath.join(tempDir, "README.md");
    await writeFile(file, "# File context");
    const skill = nodePath.join(tempDir, "SKILL.md");
    await writeFile(skill, "---\nname: fixture\n---\nUse this instruction");
    const prepared = await preparePiInput([{ type: "localImage", path }, { type: "file", path: file }, { type: "skill", name: "fixture", path: skill }]);
    assert.equal(prepared.images[0]?.data, Buffer.from("image").toString("base64"));
    assert.equal(prepared.attachments[0]?.url, "data:image/png;base64,aW1hZ2U=");
    assert.ok(prepared.text.includes("# File context"));
    assert.ok(prepared.text.includes("Use this instruction"));
    for (const url of ["data:text/plain;base64,aGk=", "data:image/png;base64,%%%%", "data:image/png;base64,a"]) {
      await assert.rejects(preparePiInput([{ type: "image", url }]), /local images/);
    }
  });
});

const overrides: AgentCreateSessionRequest["overrides"] = {
  model: null, mode: null, reasoningEffort: null, fastMode: null, approvalPolicy: null,
  sandboxMode: null, networkAccess: null, webSearch: null, profile: null,
};
function piSessionDirForCwd(cwd: string, agentDir: string): string {
  return nodePath.join(agentDir, "sessions", `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`);
}
async function until(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (!predicate()) { assert.ok(Date.now() < deadline, "Expected Pi event before timeout"); await delay(10); }
}

const RPC_FIXTURE = String.raw`
import { createInterface } from 'node:readline';
import { mkdirSync, writeFileSync, appendFileSync, readFileSync, existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
const dir = process.env.PI_CODING_AGENT_DIR;
mkdirSync(dir, {recursive:true});
writeFileSync(join(dir,'pid'), String(process.pid));
writeFileSync(join(dir,'token-present'), String('SIDEMESH_TOKEN' in process.env));
const sessionFile = process.argv.includes('--session') ? process.argv[process.argv.indexOf('--session')+1] : join(dir,'native.jsonl');
let entries = existsSync(sessionFile) ? readFileSync(sessionFile,'utf8').trim().split('\n').slice(1).map(JSON.parse) : [];
let leafId = entries.at(-1)?.id ?? null;
let isStreaming = false, autoCompactionEnabled = true, active, queued = [], thinkingLevel = 'medium';
const model = { id:'model', provider:'fixture', name:'Fixture model', reasoning:true, input:['text','image'], contextWindow:10000 };
const emit = (event) => process.stdout.write(JSON.stringify(event)+'\n');
const reply = (request,data) => emit({ type:'response', id:request.id, command:request.type, success:true, ...(data === undefined ? {} : {data}) });
const append = (message) => { const entry={type:'message', id:'entry-'+(entries.length+1), parentId:leafId, timestamp:new Date(message.timestamp).toISOString(), message}; entries.push(entry); leafId=entry.id; emit({type:'message_end', message}); };
const persist = () => writeFileSync(sessionFile, [JSON.stringify({type:'session',version:3,id:'native-session',cwd:process.cwd(),timestamp:new Date().toISOString()}), ...entries.map(JSON.stringify)].join('\n')+'\n');
const settle = () => { isStreaming=false; active=undefined; emit({type:'agent_settled'}); };
const finish = (text) => {
  if (!isStreaming) return;
  const result={content:[{type:'text',text:'image result'},{type:'image',mimeType:'image/png',data:'aGk='}],isError:false};
  emit({type:'tool_execution_start',toolCallId:'read-1',toolName:'read',args:{path:'README.md'}});
  emit({type:'tool_execution_update',toolCallId:'read-1',toolName:'read',args:{path:'README.md'},partialResult:{content:[{type:'text',text:'partial'}]}});
  emit({type:'tool_execution_end',toolCallId:'read-1',toolName:'read',result,isError:false});
  append({role:'toolResult',toolName:'read',toolCallId:'read-1',...result,timestamp:Date.now()});
  const message={role:'assistant', content:[{type:'thinking',thinking:'Think first.'},{type:'text',text:'Done.'}],provider:'fixture',model:'model',stopReason:'stop',timestamp:Date.now()};
  emit({type:'message_start',message:{...message,content:[]}});
  emit({type:'message_update',assistantMessageEvent:{type:'thinking_delta',contentIndex:0,delta:'Think first.'}});
  emit({type:'message_update',assistantMessageEvent:{type:'text_delta',contentIndex:1,delta:'Done.'}});
  append(message);
  if(text !== 'undurable') persist();
  emit({type:'agent_end',messages:[]});
  emit({type:'auto_retry_start',attempt:1,maxAttempts:2,delayMs:100,errorMessage:'retry test'});
  setTimeout(() => { emit({type:'auto_retry_end',attempt:1,success:true}); settle(); },100);
};
createInterface({input:process.stdin}).on('line',(line) => {
  const request=JSON.parse(line); appendFileSync(join(dir,'requests'),line+'\n');
  switch(request.type) {
    case 'get_state': reply(request,{sessionId:'native-session',sessionFile,sessionName:'Native session',isStreaming:isStreaming||existsSync(join(dir,'external-work')),isCompacting:false,thinkingLevel,pendingMessageCount:queued.length,messageCount:entries.length,autoCompactionEnabled,model}); break;
    case 'get_available_models': reply(request,{models:[model]}); break;
    case 'get_commands': reply(request,{commands:[{name:'fixture',description:'Local test command',source:'extension'}]}); break;
    case 'get_available_thinking_levels': reply(request,{levels:['off','medium','high']}); break;
    case 'get_entries': reply(request,{entries,leafId}); break;
    case 'set_auto_compaction': autoCompactionEnabled=request.enabled; reply(request); break;
    case 'set_thinking_level': thinkingLevel=request.level; reply(request); break;
    case 'set_model': reply(request,model); break;
    case 'set_session_name': reply(request); break;
    case 'compact': {
      emit({type:'compaction_start',reason:'manual'});
      const result={summary:'Keep this context',firstKeptEntryId:leafId??'none',tokensBefore:1000};
      const entry={type:'compaction',id:'compact-'+(entries.length+1),parentId:leafId,timestamp:new Date().toISOString(),...result};
      entries.push(entry); leafId=entry.id; persist();
      emit({type:'compaction_end',reason:'manual',result,aborted:false,willRetry:false}); reply(request,result); break;
    }
    case 'prompt':
      isStreaming=true; active=request.message; emit({type:'agent_start'});
      append({role:'user',content:[{type:'text',text:request.message},...(request.message==='changed-image'?[]:request.images??[])],timestamp:Date.now()});
      reply(request);
      if(request.message==='question') emit({type:'extension_ui_request',id:'pick',method:'select',title:'Choose one',options:['First','Second']});
      else if(request.message!=='hold') setTimeout(()=>finish(request.message),30);
      break;
    case 'steer': queued.push(request.message); emit({type:'queue_update',steering:queued,followUp:[]}); reply(request); break;
    case 'clear_queue': queued=[]; reply(request,{steering:[],followUp:[]}); break;
    case 'abort': if(existsSync(join(dir,'external-work'))) unlinkSync(join(dir,'external-work')); settle(); reply(request); break;
    case 'extension_ui_response': settle(); break;
    default: emit({type:'response',id:request.id,command:request.type,success:false,error:'unsupported fixture command'});
  }
});
`;
