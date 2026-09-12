import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { it } from "node:test";

import type { AgentSessionSnapshot, AgentSubmitInputRequest } from "./agent-provider.js";
import { SessionCoordinator } from "./session-coordinator.js";
import { SessionStore } from "./session-store.js";
import type { LiveEvent, SessionMessage } from "./types.js";

const overrides = { model: null, mode: null, reasoningEffort: null, fastMode: null, approvalPolicy: null,
  sandboxMode: null, networkAccess: null, webSearch: null, profile: null };
const input = (id: string) => ({ key: `session:${id}`, sessionId: "session", signatureHash: id,
  payload: { input: [{ type: "text" as const, text: id, text_elements: [] }], overrides } });
function native(): AgentSessionSnapshot {
  return { thread: { id: "session", name: "Test", preview: "", cwd: "/tmp", createdAt: 1, updatedAt: 1,
    source: "fake", path: null, status: { type: "idle" } }, busy: false, activeTurnId: null,
    messages: [], activities: [], totalMessages: 0, totalActivities: 0, runtime: null, nextSeq: 0 };
}
function message(id: string, text: string): SessionMessage {
  return { id, text, role: "assistant", content: [{ type: "text", text }], attachments: [], createdAt: 10, seq: 0 };
}
function coordinator(store: SessionStore, readSnapshot: () => Promise<AgentSessionSnapshot>, events: LiveEvent[] = [],
  dispatch: (request: AgentSubmitInputRequest) => Promise<{ mode: "turn"; turnId: string | null }> = async () => ({ mode: "turn", turnId: null })) {
  return new SessionCoordinator(store, { readSnapshot, publish: (event) => events.push(event),
    input: { canSteer: () => false, prepare: async (_id, payload) => payload, dispatch, submitted: async () => {} } });
}

it("captures live changes after a complete native read and never clears a newer turn with an old completion", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-coordinator-"));
  const store = await SessionStore.open(dir);
  const events: LiveEvent[] = [];
  let finishRead!: (value: AgentSessionSnapshot) => void;
  const host = coordinator(store, () => new Promise((resolve) => { finishRead = resolve; }), events);
  try {
    host.handle({ type: "turn_started", sessionId: "session", turnId: "old" });
    const reading = host.snapshot("session");
    host.handle({ type: "assistant_delta", sessionId: "session", turnId: "old", itemId: "old-message", delta: "Saved answer" });
    host.handle({ type: "reasoning_delta", sessionId: "session", turnId: "old", reasoningId: "reason", delta: "Check", summary: true });
    host.handle({ type: "activity_updated", sessionId: "session", turnId: "old", activity: {
      id: "tool", type: "tool", turnId: "old", status: "in_progress", title: "Read", output: "first", toolName: "read", args: null, result: null, isError: null, semantic: null } });
    host.handle({ type: "activity_output_delta", sessionId: "session", activityId: "tool", delta: " last" });
    host.handle({ type: "turn_completed", sessionId: "session", turnId: "old", status: "completed" });
    host.handle({ type: "turn_started", sessionId: "session", turnId: "new" });
    host.handle({ type: "assistant_delta", sessionId: "session", turnId: "new", itemId: "new-message", delta: "New draft" });
    host.handle({ type: "runtime_updated", sessionId: "session", runtime: { model: "new-model" } });
    host.handle({ type: "turn_completed", sessionId: "session", turnId: "old", status: "completed" });
    finishRead(native());
    const snapshot = await reading;
    assert.equal(snapshot.busy, true);
    assert.equal(snapshot.activeTurnId, "new");
    assert.equal(snapshot.messages[0]?.text, "Saved answer");
    assert.equal(snapshot.messages[0]?.content.some((part) => part.type === "thinking" && part.thinking === "Check"), true);
    assert.equal(snapshot.liveAssistantText, "New draft");
    assert.equal(snapshot.runtime?.model, "new-model");
    assert.equal(snapshot.activities[0]?.type === "tool" && snapshot.activities[0].output, "first last");
    assert.equal(snapshot.revision, events.at(-1)?.revision);
    assert.equal(store.readRecovery("session").length, 3);
  } finally { host.inputs.close(); await host.inputs.drain(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

it("keeps completed output through failed reads and restart until native history covers it", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-coordinator-"));
  let store = await SessionStore.open(dir);
  let log = native();
  let fail = false;
  let host = coordinator(store, async () => { if (fail) throw new Error("interrupted read"); return log; });
  try {
    host.handle({ type: "assistant_message_completed", sessionId: "session", message: { id: "answer", text: "Final answer" } });
    host.handle({ type: "turn_started", sessionId: "session", turnId: "next" });
    host.handle({ type: "reasoning_delta", sessionId: "session", turnId: "next", reasoningId: "r", delta: "Durable thought", summary: false });
    host.handle({ type: "assistant_delta", sessionId: "session", turnId: "next", itemId: "draft", delta: "Partial" });
    assert.equal(store.readRecovery("session").length, 2);
    fail = true;
    await assert.rejects(host.snapshot("session"), /interrupted read/);
    host.inputs.close();
    await host.inputs.drain();
    store.close();
    store = await SessionStore.open(dir);
    fail = false;
    host = coordinator(store, async () => log);
    log = { ...native(), messages: [message("answer", "Final")], totalMessages: 1 };
    let snapshot = await host.snapshot("session");
    assert.equal(snapshot.messages[0]?.text, "Final answer");
    assert.equal(snapshot.messages[1]?.text, "Partial");
    assert.equal(snapshot.liveAssistantText, "");
    assert.equal(snapshot.busy, false);
    assert.equal(store.readRecovery("session").length, 2);
    log = { ...native(), messages: [message("answer", "Final answer"), {
      ...message("draft", "Partial completed"), content: [{ type: "thinking", thinking: "Durable thought and more" }, { type: "text", text: "Partial completed" }] }], totalMessages: 2 };
    snapshot = await host.snapshot("session");
    assert.equal(snapshot.messages.length, 2);
    assert.equal(snapshot.messages[1]?.text, "Partial completed");
    assert.deepEqual(store.readRecovery("session"), []);
  } finally { host.inputs.close(); await host.inputs.drain(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

it("keeps transcript order when live events arrive before the first limited snapshot", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-coordinator-"));
  const store = await SessionStore.open(dir);
  const host = coordinator(store, async () => ({ ...native(), messages: [message("old", "Older native answer")], totalMessages: 1, nextSeq: 1 }));
  try {
    host.handle({ type: "activity_updated", sessionId: "session", activity: { id: "tool", type: "tool", turnId: null,
      status: "completed", title: "Read", toolName: "read", output: "output", args: null, result: null, isError: null, semantic: null } });
    host.handle({ type: "assistant_message_completed", sessionId: "session", message: { id: "new", text: "New answer" } });
    const snapshot = await host.snapshot("session", { messageLimit: 1 });
    assert.equal(snapshot.messages[0]?.text, "New answer");
    assert.equal(snapshot.totalMessages, 2);
    assert.ok(snapshot.activities[0]!.seq > 0);
    assert.ok(snapshot.messages[0]!.seq > snapshot.activities[0]!.seq);
    host.handle({ type: "activity_output_delta", sessionId: "session", activityId: "tool", delta: " tail" });
    assert.equal(host.get("session").activities.get("tool")?.seq, snapshot.activities[0]?.seq);
  } finally { host.inputs.close(); await host.inputs.drain(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

it("serializes native reads so an older snapshot cannot remove newly confirmed output", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-coordinator-"));
  const store = await SessionStore.open(dir);
  let release!: (value: AgentSessionSnapshot) => void;
  let reads = 0;
  const host = coordinator(store, () => {
    reads++;
    return reads === 1 ? new Promise((resolve) => { release = resolve; })
      : Promise.resolve({ ...native(), messages: [message("new", "New answer")], totalMessages: 1 });
  });
  try {
    const first = host.snapshot("session");
    const second = host.snapshot("session");
    assert.equal(reads, 1);
    host.handle({ type: "assistant_message_completed", sessionId: "session", message: { id: "new", text: "New answer" } });
    release(native());
    assert.equal((await first).messages[0]?.text, "New answer");
    assert.equal((await second).messages[0]?.text, "New answer");
    assert.equal(reads, 2);
    assert.deepEqual(store.readRecovery("session"), []);
  } finally { host.inputs.close(); await host.inputs.drain(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

it("prefers a complete native tool result over an older live draft", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-coordinator-"));
  const store = await SessionStore.open(dir);
  let log = native();
  const host = coordinator(store, async () => log);
  try {
    host.handle({ type: "activity_updated", sessionId: "session", activity: { id: "tool", type: "tool", turnId: "local-turn",
      status: "in_progress", title: "Read", toolName: "read", output: "partial", args: null, result: null, isError: null, semantic: null } });
    const activity = host.get("session").activities.get("tool")!;
    assert.equal(activity.type, "tool");
    if (activity.type !== "tool") throw new Error("missing tool");
    log = { ...native(), activities: [{ ...activity, turnId: "native-turn", status: "completed", output: "partial and complete", result: { ok: true } }], totalActivities: 1 };
    const snapshot = await host.snapshot("session");
    assert.equal(snapshot.activities[0]?.type === "tool" && snapshot.activities[0].output, "partial and complete");
    assert.equal(snapshot.activities[0]?.status, "completed");
    assert.deepEqual(store.readRecovery("session"), []);
  } finally { host.inputs.close(); await host.inputs.drain(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

it("uses native busy state and input proof without recreating turns after a late reply", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-coordinator-"));
  const store = await SessionStore.open(dir);
  let log = native();
  let sends = 0;
  const host = coordinator(store, async () => log, [], async () => {
    sends++;
    host.handle({ type: "turn_started", sessionId: "session", turnId: "done" });
    host.handle({ type: "turn_completed", sessionId: "session", turnId: "done", status: "completed" });
    return { mode: "turn", turnId: "done" };
  });
  try {
    const receipt = await host.inputs.submit(input("client:one"));
    assert.equal(receipt.turnId, "done");
    assert.equal(host.get("session").busy, false);
    assert.equal(host.get("session").activeTurn, null);
    assert.equal(store.getInput("session:client:one")?.state, "accepted");
    log = { ...native(), busy: true, confirmedInputIds: ["client:one"], thread: { ...native().thread, status: { type: "active" } } };
    const snapshot = await host.snapshot("session");
    assert.equal(snapshot.busy, true);
    assert.equal(snapshot.activeTurnId, null);
    assert.equal(store.getInput("session:client:one")?.state, "confirmed");
    assert.equal(store.getInput("session:client:one")?.payload, null);
    assert.equal((await host.inputs.submit(input("client:two"))).mode, "queued");
    await host.inputs.stop("session", async () => {});
    assert.equal(sends, 1);
    assert.equal(store.getInput("session:client:two")?.state, "cancelled");
    log = native();
    assert.equal((await host.snapshot("session")).busy, false);
  } finally { host.inputs.close(); await host.inputs.drain(); store.close(); await rm(dir, { recursive: true, force: true }); }
});

it("keeps uncertain input after restart and releases it only on native confirmation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-coordinator-"));
  let store = await SessionStore.open(dir);
  let sends = 0;
  let host = coordinator(store, async () => native(), [], async () => { sends++; throw new Error("reply lost"); });
  try {
    await assert.rejects(host.inputs.submit(input("one")), /reply lost/);
    host.inputs.close(); await host.inputs.drain(); store.close();
    store = await SessionStore.open(dir);
    host = coordinator(store, async () => ({ ...native(), confirmedInputIds: ["one"] }));
    await assert.rejects(host.inputs.submit(input("one")), /may have received/);
    await host.snapshot("session");
    assert.equal((await host.inputs.submit(input("one"))).replayed, true);
    assert.equal(store.getInput("session:one")?.state, "confirmed");
    assert.equal(sends, 1);
  } finally { host.inputs.close(); await host.inputs.drain(); store.close(); await rm(dir, { recursive: true, force: true }); }
});
