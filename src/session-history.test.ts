import assert from "node:assert/strict";
import { it } from "node:test";
import { confirmedSessionInputIds, reconcileSessionHistory } from "./session-history.js";
import type { StoredSessionItem } from "./session-store.js";

const input = (id: string, extra: Partial<StoredSessionItem> = {}): StoredSessionItem => ({
  kind: "message", nativeId: null, authority: "recovery",
  value: { id, role: "user", text: "repeat", content: [{ type: "text", text: "repeat" }], attachments: [], createdAt: 10, seq: 0 },
  ...extra,
} as StoredSessionItem);

it("confirms input only with an explicit native ID or observed native timestamp", () => {
  const native = input("native", { nativeId: "native", authority: "cache" });
  const pending = input("client", { clientInputId: "client" });
  for (const matchTimestamps of [false, true]) {
    const unbound = reconcileSessionHistory([pending], [native], matchTimestamps);
    assert.equal(unbound.length, 2);
    assert.deepEqual(confirmedSessionInputIds(unbound), []);
  }
  for (const bound of [{ ...pending, nativeId: "native" }, { ...pending, nativeInputTimestamp: 10 }]) {
    const merged = reconcileSessionHistory([bound], [native], true);
    assert.equal(merged.length, 1);
    assert.equal(merged[0]?.value.id, "client");
    assert.deepEqual(confirmedSessionInputIds(merged), ["client"]);
    assert.deepEqual(confirmedSessionInputIds(reconcileSessionHistory([bound], [{ ...native, authority: "recovery" }], true)), []);
  }
  // An old native message whose display ID equals a client ID is not a binding.
  assert.deepEqual(confirmedSessionInputIds([input("client", { nativeId: "native", authority: "cache" })]), []);
});
