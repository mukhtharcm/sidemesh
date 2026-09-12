import { isDeepStrictEqual } from "node:util";
import type { StoredSessionItem } from "./session-store.js";
import type { SessionMessage } from "./types.js";

/** Replace a completed replay, retaining local content that the native history did not confirm. */
export function reconcileSessionHistory(local: StoredSessionItem[], replay: StoredSessionItem[], matchTimestamps = false): StoredSessionItem[] {
  const confirmed = new Set<StoredSessionItem>();
  let prefixMatches = true;
  const result = replay.map((item, index): StoredSessionItem => {
    const sameId = item.nativeId ? local.find((saved) => saved.kind === item.kind && saved.nativeId === item.nativeId) : undefined;
    const sameTime = matchTimestamps ? local.find((saved) => !confirmed.has(saved)
      && (!saved.clientInputId || saved.nativeInputTimestamp === item.value.createdAt)
      && saved.kind === item.kind && saved.value.createdAt === item.value.createdAt && sameContent(saved, item)) : undefined;
    const candidate = sameId ?? sameTime ?? (prefixMatches && !local[index]?.clientInputId ? local[index] : undefined);
    const matches = candidate && sameContent(candidate, item);
    prefixMatches = Boolean(prefixMatches && matches && candidate === local[index]);
    if (matches) {
      confirmed.add(candidate);
      return { ...withItemMetadata(item, { id: candidate.value.id, createdAt: candidate.value.createdAt }), authority: item.authority,
        ...(candidate.clientInputId ? { clientInputId: candidate.clientInputId, nativeInputTimestamp: candidate.nativeInputTimestamp } : {}) };
    }
    return { ...item, authority: item.authority };
  });
  for (const item of local) {
    if (item.authority !== "cache" && !confirmed.has(item)) {
      // Prefer the complete local record when the replay contains an older version of the same native item.
      const index = result.findIndex((candidate) => candidate.kind === item.kind && item.nativeId && candidate.nativeId === item.nativeId);
      if (index >= 0) result[index] = item;
      else result.push(item);
    }
  }
  return result.map((item, seq) => withItemMetadata(item, { seq }));
}

function withItemMetadata(item: StoredSessionItem, metadata: Partial<Pick<SessionMessage, "id" | "seq" | "createdAt">>): StoredSessionItem {
  return item.kind === "message" ? { ...item, value: { ...item.value, ...metadata } }
    : { ...item, value: { ...item.value, ...metadata } };
}

function sameContent(left: StoredSessionItem, right: StoredSessionItem): boolean {
  const { id: _leftId, seq: _leftSeq, createdAt: _leftTime, ...a } = left.value;
  const { id: _rightId, seq: _rightSeq, createdAt: _rightTime, ...b } = right.value;
  if (left.kind === "activity" && right.kind === "activity") {
    // Local turn IDs identify Sidemesh delivery, not native replay items.
    return isDeepStrictEqual({ ...a, turnId: null }, { ...b, turnId: null });
  }
  return left.kind === right.kind && isDeepStrictEqual(a, b);
}

/** Only a bound input in durable native history can release its host recovery payload. */
export function confirmedSessionInputIds(items: StoredSessionItem[]): string[] {
  return items.flatMap((item) => item.kind === "message" && item.value.role === "user"
    && item.clientInputId && item.nativeId && item.authority === "cache" ? [item.clientInputId] : []);
}
