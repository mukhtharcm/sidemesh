import { createHash } from "node:crypto";

import type {
  SessionActivity,
  SessionLogPageInfo,
  SessionLogSnapshot,
  SessionMessage,
} from "./types.js";

type TimelineKind = "message" | "activity";

interface TimelineEntry<T extends SessionMessage | SessionActivity> {
  kind: TimelineKind;
  value: T;
}

interface SessionLogCursorPayload {
  version: 1;
  scopeHash: string;
  kind: TimelineKind;
  idHash: string;
  createdAt: number;
  seq: number;
}

export const SESSION_LOG_CURSOR_MAX_LENGTH = 512;
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
const SHA256_BASE64URL_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export interface SessionLogPaginationOptions {
  limit: number;
  beforeCursor?: string | null;
}

export interface SessionLogPaginationResult {
  messages: SessionMessage[];
  activities: SessionActivity[];
  page: SessionLogPageInfo;
}

export function paginateSessionLogSnapshot(
  cursorScope: string,
  snapshot: SessionLogSnapshot,
  options: SessionLogPaginationOptions,
): SessionLogSnapshot {
  const paged = paginateSessionLogEntries(
    cursorScope,
    snapshot.messages,
    snapshot.activities,
    options,
  );
  return {
    ...snapshot,
    messages: paged.messages,
    activities: paged.activities,
    page: {
      ...paged.page,
      hasMoreBefore:
        paged.page.hasMoreBefore ||
        (!options.beforeCursor &&
          snapshot.totalMessages + snapshot.totalActivities >
            paged.messages.length + paged.activities.length),
    },
  };
}

export class SessionLogCursorError extends Error {
  public readonly code: "INVALID_SESSION_LOG_CURSOR" | "STALE_SESSION_LOG_CURSOR";
  public readonly status: 400 | 410;

  constructor(message: string, status: 400 | 410 = 400) {
    super(message);
    this.name = "SessionLogCursorError";
    this.status = status;
    this.code = status === 410
      ? "STALE_SESSION_LOG_CURSOR"
      : "INVALID_SESSION_LOG_CURSOR";
  }
}

export function paginateSessionLogEntries(
  cursorScope: string,
  messages: readonly SessionMessage[],
  activities: readonly SessionActivity[],
  options: SessionLogPaginationOptions,
): SessionLogPaginationResult {
  const limit = Math.max(1, Math.trunc(options.limit));
  const anchor = options.beforeCursor
    ? decodeSessionLogCursor(options.beforeCursor, cursorScope)
    : null;
  const timeline = buildTimeline(messages, activities);
  let end = timeline.length;

  if (anchor) {
    const anchorIndex = timeline.findIndex(
      (entry) =>
        entry.kind === anchor.kind &&
        entry.value.createdAt === anchor.createdAt &&
        entry.value.seq === anchor.seq &&
        stableCursorHash(entry.value.id) === anchor.idHash,
    );
    if (anchorIndex < 0) {
      throw new SessionLogCursorError(
        "The transcript changed and the history cursor is no longer available.",
        410,
      );
    }
    end = anchorIndex;
  }

  const start = Math.max(0, end - limit);
  const pageEntries = timeline.slice(start, end);
  const pageMessages: SessionMessage[] = [];
  const pageActivities: SessionActivity[] = [];
  for (const entry of pageEntries) {
    if (entry.kind === "message") {
      pageMessages.push(entry.value as SessionMessage);
    } else {
      pageActivities.push(entry.value as SessionActivity);
    }
  }

  const first = pageEntries[0];
  return {
    messages: pageMessages,
    activities: pageActivities,
    page: {
      beforeCursor: first
        ? encodeSessionLogCursor(
            cursorScope,
            first.kind,
            first.value.id,
            first.value.createdAt,
            first.value.seq,
          )
        : null,
      hasMoreBefore: start > 0,
    },
  };
}

export function decodeSessionLogCursor(
  cursor: string,
  expectedScope: string,
): SessionLogCursorPayload {
  if (
    cursor.length === 0 ||
    cursor.length > SESSION_LOG_CURSOR_MAX_LENGTH ||
    !BASE64URL_PATTERN.test(cursor)
  ) {
    throw new SessionLogCursorError("Invalid transcript history cursor.");
  }
  let parsed: unknown;
  try {
    const decoded = Buffer.from(cursor, "base64url");
    if (decoded.toString("base64url") !== cursor) {
      throw new Error("Non-canonical base64url cursor");
    }
    parsed = JSON.parse(decoded.toString("utf8"));
  } catch {
    throw new SessionLogCursorError("Invalid transcript history cursor.");
  }

  if (
    !parsed ||
    typeof parsed !== "object" ||
    (parsed as { version?: unknown }).version !== 1 ||
    typeof (parsed as { scopeHash?: unknown }).scopeHash !== "string" ||
    !SHA256_BASE64URL_PATTERN.test(
      (parsed as { scopeHash: string }).scopeHash,
    ) ||
    (parsed as { scopeHash: string }).scopeHash !==
      stableCursorHash(expectedScope) ||
    ((parsed as { kind?: unknown }).kind !== "message" &&
      (parsed as { kind?: unknown }).kind !== "activity") ||
    typeof (parsed as { idHash?: unknown }).idHash !== "string" ||
    !SHA256_BASE64URL_PATTERN.test((parsed as { idHash: string }).idHash) ||
    typeof (parsed as { createdAt?: unknown }).createdAt !== "number" ||
    !Number.isSafeInteger((parsed as { createdAt: number }).createdAt) ||
    (parsed as { createdAt: number }).createdAt < 0 ||
    typeof (parsed as { seq?: unknown }).seq !== "number" ||
    !Number.isSafeInteger((parsed as { seq: number }).seq) ||
    (parsed as { seq: number }).seq < 0
  ) {
    throw new SessionLogCursorError("Invalid transcript history cursor.");
  }

  return parsed as SessionLogCursorPayload;
}

export function validateSessionLogCursor(
  cursor: string,
  expectedScope: string,
): void {
  decodeSessionLogCursor(cursor, expectedScope);
}

function encodeSessionLogCursor(
  scope: string,
  kind: TimelineKind,
  id: string,
  createdAt: number,
  seq: number,
): string {
  const payload: SessionLogCursorPayload = {
    version: 1,
    scopeHash: stableCursorHash(scope),
    kind,
    idHash: stableCursorHash(id),
    createdAt,
    seq,
  };
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}

function buildTimeline(
  messages: readonly SessionMessage[],
  activities: readonly SessionActivity[],
): Array<TimelineEntry<SessionMessage | SessionActivity>> {
  const timeline: Array<TimelineEntry<SessionMessage | SessionActivity>> = [
    ...messages.map((value) => ({ kind: "message" as const, value })),
    ...activities.map((value) => ({ kind: "activity" as const, value })),
  ];
  timeline.sort(compareTimelineEntries);
  return timeline;
}

function compareTimelineEntries(
  left: TimelineEntry<SessionMessage | SessionActivity>,
  right: TimelineEntry<SessionMessage | SessionActivity>,
): number {
  if (left.value.createdAt !== right.value.createdAt) {
    return left.value.createdAt - right.value.createdAt;
  }
  if (left.value.seq !== right.value.seq) {
    return left.value.seq - right.value.seq;
  }
  if (left.kind !== right.kind) {
    return left.kind === "activity" ? -1 : 1;
  }
  if (left.value.id === right.value.id) {
    return 0;
  }
  return left.value.id < right.value.id ? -1 : 1;
}

function stableCursorHash(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("base64url");
}
