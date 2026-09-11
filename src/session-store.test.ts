import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { it } from "node:test";

import { SessionStore } from "./session-store.js";

const payload = {
  input: [{ type: "text" as const, text: "Keep this request", text_elements: [] }],
  overrides: {
    model: null, mode: null, reasoningEffort: null, fastMode: null,
    approvalPolicy: null, sandboxMode: null, networkAccess: null,
    webSearch: null, profile: null,
  },
};
const receipt = { mode: "turn" as const, turnId: "turn-1", messageId: "input-1" };

it("retains input and acceptance across restarts without resending uncertain work", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-session-store-"));
  let store = await SessionStore.open(dir);
  try {
    for (const key of ["session:unsent", "session:unknown", "session:accepted"]) {
      store.prepareInput({ key, sessionId: "session", signatureHash: key, payload });
    }
    store.dispatchInput("session:unknown");
    store.dispatchInput("session:accepted");
    store.acceptInput("session:accepted", receipt);
    store.close();
    store = await SessionStore.open(dir);
    assert.equal(store.getInput("session:unsent")?.state, "prepared");
    assert.equal(store.getInput("session:unknown")?.state, "uncertain");
    assert.deepEqual(store.getInput("session:unknown")?.payload, payload);
    assert.deepEqual(store.getInput("session:accepted")?.receipt, receipt);
    assert.throws(() => store.dispatchInput("session:unknown"), /not ready/);
    assert.throws(() => store.prepareInput({
      key: "session:accepted", sessionId: "session", signatureHash: "other", payload,
    }), /UNIQUE/);
    store.clearInterruptedInputs(new Map([["session", "turn-1"]]));
    assert.equal(store.getInput("session:accepted")?.state, "uncertain");
    assert.deepEqual(store.getInput("session:accepted")?.payload, payload);
    assert.equal(store.getInput("session:unknown")?.state, "uncertain");
    if (process.platform !== "win32") {
      for (const name of ["sessions-v1.db", "sessions-v1.db-wal", "sessions-v1.db-shm"]) {
        assert.equal((await stat(join(dir, name))).mode & 0o777, 0o600);
      }
    }
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

it("imports legacy receipts and plans once and preserves the original files", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-session-import-"));
  const inputFile = join(dir, "session-input-dedupe-v1.json");
  const planFile = join(dir, "session-runtime-signals-v1.json");
  const source = JSON.stringify({ version: 1, entries: [{
    key: "copilot:session:input-1", signatureHash: "signature", receipt,
    createdAt: Date.now(), updatedAt: Date.now(),
  }] });
  const plan = {
    type: "plan_updated" as const, sessionId: "copilot:session", seq: 4,
    plan: [{ step: "Keep the saved plan", status: "in_progress" as const }],
  };
  await writeFile(inputFile, source);
  await writeFile(planFile, JSON.stringify({ sessions: [{
    sessionId: plan.sessionId, updatedAt: Date.now(), latestPlanUpdate: plan,
  }] }));
  let store = await SessionStore.open(dir);
  try {
    assert.equal(store.getInput("copilot:session:input-1")?.sessionId, "copilot:session");
    assert.deepEqual(store.getPlan(plan.sessionId), plan);
    store.clearInterruptedInputs(new Map([[plan.sessionId, receipt.turnId]]));
    store.setPlan(plan.sessionId, null);
    store.close();
    store = await SessionStore.open(dir);
    assert.equal(store.getInput("copilot:session:input-1")?.state, "uncertain");
    assert.equal(store.getPlan(plan.sessionId), null);
    assert.equal(await readFile(inputFile, "utf8"), source);
    assert.ok(await readFile(planFile, "utf8"));
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

it("never expires unconfirmed, cancelled, or queued payloads with old dedupe receipts", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-input-retention-"));
  let store = await SessionStore.open(dir);
  try {
    for (let index = 0; index < 505; index++) {
      const key = `session:input-${index}`;
      store.prepareInput({ key, sessionId: "session", signatureHash: key, payload });
      store.dispatchInput(key);
      store.acceptInput(key, receipt);
    }
    store.prepareInput({ key: "session:cancelled", sessionId: "session", signatureHash: "cancelled", payload });
    store.cancelQueuedInputs("session");
    store.prepareInput({ key: "session:queued", sessionId: "session", signatureHash: "queued", payload });
    store.queueInput("session:queued", "queued", payload);
    const db = new DatabaseSync(join(dir, "sessions-v1.db"));
    db.exec("UPDATE inputs SET updated_at = 1");
    db.close();
    store.close();
    store = await SessionStore.open(dir);
    assert.equal(store.inputCount(), 507);
    assert.equal(store.getInput("session:input-0")?.state, "uncertain");
    assert.deepEqual(store.getInput("session:input-0")?.payload, payload);
    assert.equal(store.getInput("session:cancelled")?.state, "cancelled");
    assert.equal(store.getInput("session:queued")?.state, "queued");
  } finally { store.close(); await rm(dir, { recursive: true, force: true }); }
});

it("does not mark an invalid legacy import complete", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-session-import-"));
  try {
    const file = join(dir, "session-input-dedupe-v1.json");
    await writeFile(file, '{"version":1,"entries":[{}]}');
    await assert.rejects(SessionStore.open(dir));
    await writeFile(file, JSON.stringify({ version: 1, entries: [{
      key: "session:input", signatureHash: "signature", receipt,
      createdAt: Date.now(), updatedAt: Date.now(),
    }] }));
    const store = await SessionStore.open(dir);
    assert.deepEqual(store.getInput("session:input")?.receipt, receipt);
    store.close();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

it("keeps native confirmation across a late acknowledgement, a lost reply, and restart", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sidemesh-input-proof-"));
  let store = await SessionStore.open(dir);
  try {
    for (const id of ["before:reply", "lost:reply", "unsent"]) {
      store.prepareInput({ key: `session:${id}`, sessionId: "session", signatureHash: id, payload });
      if (id !== "unsent") store.dispatchInput(`session:${id}`);
    }
    store.confirmInputs("session", ["before:reply", "lost:reply", "unsent"]);
    store.acceptInput("session:before:reply", { ...receipt, messageId: "before:reply" });
    store.failInput("session:lost:reply");
    store.close();
    store = await SessionStore.open(dir);
    for (const id of ["before:reply", "lost:reply"]) {
      const record = store.getInput(`session:${id}`)!;
      assert.equal(record.state, "confirmed");
      assert.equal(record.payload, null);
      assert.equal(record.receipt?.messageId, id);
    }
    assert.equal(store.getInput("session:unsent")?.state, "prepared");
  } finally { store.close(); await rm(dir, { recursive: true, force: true }); }
});
