import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { StateWriter } from "./state-writer.js";

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

describe("StateWriter", () => {
  it("coalesces a burst into one durable snapshot", async () => {
    let saves = 0;
    const writer = new StateWriter(async () => { saves++; });
    await Promise.all(Array.from({ length: 25 }, () => writer.request()));
    await writer.flush();
    assert.equal(saves, 1);
  });

  it("does not acknowledge changes arriving during an earlier write", async () => {
    const entered = deferred();
    const firstDiskWrite = deferred();
    const secondDiskWrite = deferred();
    let saves = 0;
    const writer = new StateWriter(async () => {
      if (++saves === 1) { entered.resolve(); await firstDiskWrite.promise; }
      else await secondDiskWrite.promise;
    });
    const first = writer.request();
    await entered.promise;
    let secondDone = false;
    const second = writer.request().then(() => { secondDone = true; });
    firstDiskWrite.resolve();
    await first;
    assert.equal(secondDone, false);
    secondDiskWrite.resolve();
    await second;
    await writer.flush();
    assert.equal(saves, 2);
  });

  it("allows a later request to succeed after an earlier disk failure", async () => {
    const entered = deferred();
    const disk = deferred();
    let saves = 0;
    const writer = new StateWriter(async () => {
      if (++saves === 1) { entered.resolve(); await disk.promise; throw new Error("disk full"); }
    });
    const first = assert.rejects(writer.request(), /disk full/);
    await entered.promise;
    const second = writer.request();
    disk.resolve();
    await first;
    await second;
    await writer.flush();
    assert.equal(saves, 2);
  });

  it("saves requests scheduled immediately after acknowledgement", async () => {
    let saved = 0;
    let current = 1;
    const writer = new StateWriter(async () => { saved = current; });
    await writer.request().then(async () => { current = 2; await writer.request(); });
    await writer.flush();
    assert.equal(saved, 2);
  });

  it("retries a failed final snapshot during shutdown", async () => {
    let saves = 0;
    const writer = new StateWriter(async () => { if (++saves === 1) throw new Error("busy"); });
    await assert.rejects(writer.request(), /busy/);
    await writer.flush();
    assert.equal(saves, 2);
  });

  it("does not acknowledge a rejected write even when no error object is supplied", async () => {
    const writer = new StateWriter(() => Promise.reject());
    await writer.request().then(
      () => assert.fail("a failed write was acknowledged"),
      (error: unknown) => assert.equal(error, undefined),
    );
  });

  it("reports a persistent shutdown failure instead of silently dropping data", async () => {
    const writer = new StateWriter(async () => { throw new Error("disk full"); });
    await assert.rejects(writer.request(), /disk full/);
    await assert.rejects(writer.flush(), /disk full/);
  });
});
