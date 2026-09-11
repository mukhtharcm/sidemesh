import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { it } from "node:test";

import { AgentProviderRequestError, type AgentSubmitInputRequest } from "./agent-provider.js";
import { SessionInputCoordinator } from "./session-input-coordinator.js";
import { SessionStore } from "./session-store.js";

const payload = { input: [{ type: "text" as const, text: "Keep this request", text_elements: [] }], overrides: {
  model: null, mode: null, reasoningEffort: null, fastMode: null, approvalPolicy: null,
  sandboxMode: null, networkAccess: null, webSearch: null, profile: null,
} };
const request = (id: string) => ({ key: `session:${id}`, sessionId: "session", signatureHash: id, payload });

async function fixture() {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-queue-"));
  const state = {
    store: await SessionStore.open(dir), busy: true, canSteer: false, fail: null as Error | null,
    calls: [] as AgentSubmitInputRequest[], warnings: [] as unknown[],
    beforeState: null as Promise<void> | null, beforeSend: null as Promise<void> | null,
  };
  const coordinator = () => new SessionInputCoordinator(state.store, {
    canSteer: () => state.canSteer,
    runState: async () => { await state.beforeState; return { turnId: state.busy ? "turn-1" : null, busy: state.busy }; },
    prepare: async (_id, value) => { await state.beforeSend; return value; },
    dispatch: async (value) => {
      state.calls.push(value);
      if (state.fail) throw state.fail;
      state.busy = true;
      return { mode: value.activeTurnId ? "steer" : "turn", turnId: "turn-1" };
    },
    submitted: async () => {}, queueChanged: () => {}, warning: (_id, error) => { state.warnings.push(error); },
  });
  return { state, coordinator, dir, cleanup: async () => { state.store.close(); await rm(dir, { recursive: true, force: true }); } };
}

it("saves queued input before acknowledgement and recovers it once after restart", async () => {
  const f = await fixture();
  let queue = f.coordinator();
  try {
    const first = await queue.submit(request("one"));
    assert.deepEqual(first, { mode: "queued", turnId: null, messageId: "one", replayed: false });
    assert.deepEqual(f.state.store.getInput("session:one")?.payload, payload);
    assert.equal((await queue.submit(request("one"))).replayed, true);
    assert.equal(f.state.calls.length, 0);
    queue.close();
    await queue.drain();
    f.state.store.close();
    f.state.store = await SessionStore.open(f.dir);
    f.state.busy = false;
    queue = f.coordinator();
    queue.recover();
    await queue.drain();
    assert.equal(f.state.calls.length, 1);
    assert.equal(f.state.calls[0]?.clientMessageId, "one");
    assert.deepEqual(f.state.calls[0]?.input, payload.input);
    assert.equal(f.state.store.getInput("session:one")?.state, "accepted");
    assert.equal((await queue.submit(request("one"))).replayed, true);
    assert.equal(f.state.calls.length, 1);
  } finally { queue.close(); await queue.drain(); await f.cleanup(); }
});

it("keeps failed queued input and never replays its old receipt after an unknown send", async () => {
  const f = await fixture();
  const queue = f.coordinator();
  try {
    await queue.submit(request("one"));
    await queue.drain();
    f.state.busy = false;
    f.state.fail = new AgentProviderRequestError("Model was rejected before prompt", 400, true);
    queue.wake("session");
    await queue.drain();
    assert.equal(f.state.store.getInput("session:one")?.state, "queued");
    f.state.fail = new Error("Connection lost after prompt");
    queue.wake("session");
    await queue.drain();
    assert.equal(f.state.store.getInput("session:one")?.state, "uncertain");
    assert.equal(f.state.store.getInput("session:one")?.receipt?.mode, "queued");
    await assert.rejects(queue.submit(request("one")), { code: "input_delivery_uncertain" });
    queue.recover();
    await queue.drain();
    assert.equal(f.state.calls.length, 2);
    assert.deepEqual(f.state.store.getInput("session:one")?.payload, payload);
  } finally { queue.close(); await queue.drain(); await f.cleanup(); }
});

it("cancels queued input before stop and prevents dispatch during shutdown", async () => {
  const f = await fixture();
  const queue = f.coordinator();
  try {
    await queue.submit(request("one"));
    await queue.drain();
    f.state.busy = false;
    const gate = deferred();
    f.state.beforeState = gate.promise;
    queue.wake("session");
    const stopped = queue.stop("session", async () => { queue.wake("session"); });
    gate.resolve();
    await stopped;
    assert.equal(f.state.calls.length, 0);
    assert.equal(f.state.store.getInput("session:one")?.state, "cancelled");
    assert.deepEqual(f.state.store.getInput("session:one")?.payload, payload);
    await assert.rejects(queue.submit(request("one")), { code: "input_cancelled" });
    f.state.busy = true;
    await queue.submit(request("two"));
    await queue.drain();
    f.state.busy = false;
    const send = deferred();
    f.state.beforeSend = send.promise;
    queue.wake("session");
    await new Promise<void>((resolve) => setImmediate(resolve));
    queue.close();
    send.resolve();
    await queue.drain();
    assert.equal(f.state.calls.length, 0);
    assert.equal(f.state.store.getInput("session:two")?.state, "queued");
  } finally { queue.close(); await queue.drain(); await f.cleanup(); }
});

it("serializes concurrent starts and retains native steering when the provider supports it", async () => {
  const f = await fixture();
  const queue = f.coordinator();
  try {
    f.state.busy = false;
    const [first, duplicate, second] = await Promise.all([
      queue.submit(request("one")), queue.submit(request("one")), queue.submit(request("two")),
    ]);
    assert.equal(first.mode, "turn");
    assert.equal(duplicate.replayed, true);
    assert.equal(second.mode, "queued");
    assert.equal(f.state.calls.length, 1);
    f.state.busy = false;
    queue.wake("session");
    await queue.drain();
    assert.equal(f.state.calls.length, 2);
    f.state.canSteer = true;
    const third = await queue.submit(request("three"));
    assert.equal(third.mode, "steer");
    assert.equal(f.state.calls[2]?.activeTurnId, "turn-1");
  } finally { queue.close(); await queue.drain(); await f.cleanup(); }
});

function deferred(): { promise: Promise<void>; resolve(): void } {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}
