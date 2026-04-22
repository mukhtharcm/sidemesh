import type {
  CommandActivity,
  FileChangeActivity,
  SessionActivity,
  SessionActivityChange,
  ThreadItemRecord,
  ThreadRecord,
} from "./types.js";

const MAX_COMMAND_OUTPUT_CHARS = 12_000;
const MAX_DIFF_CHARS = 8_000;

export function extractSessionActivities(thread: ThreadRecord): SessionActivity[] {
  const turns = Array.isArray(thread.turns) ? thread.turns : [];
  const activities: SessionActivity[] = [];

  for (const turn of turns) {
    const items = Array.isArray(turn.items) ? turn.items : [];
    const baseCreatedAt = pickTurnTimestamp(turn.startedAt, turn.completedAt, thread.updatedAt);
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index];
      const activity = buildActivityFromThreadItem(item, {
        turnId: turn.id,
        createdAt: baseCreatedAt + index,
      });
      if (activity) {
        activities.push(activity);
      }
    }
  }

  return activities.sort((left, right) => left.createdAt - right.createdAt);
}

export function buildActivityFromThreadItem(
  item: ThreadItemRecord,
  context: { turnId: string | null; createdAt: number },
): SessionActivity | null {
  if (item.type === "commandExecution") {
    return {
      id: item.id,
      type: "command",
      turnId: context.turnId,
      createdAt: context.createdAt,
      status: normalizeStatus(item.status),
      command: asString(item.command) || "",
      cwd: asString(item.cwd) || "",
      output: truncateNullableText(asString(item.aggregatedOutput), MAX_COMMAND_OUTPUT_CHARS),
      exitCode: asNumber(item.exitCode),
      durationMs: asNumber(item.durationMs),
    };
  }

  if (item.type === "fileChange") {
    return {
      id: item.id,
      type: "file_change",
      turnId: context.turnId,
      createdAt: context.createdAt,
      status: normalizeStatus(item.status),
      changes: buildFileChangeChanges(item.changes),
    };
  }

  return null;
}

export function mergeActivity(
  existing: SessionActivity | undefined,
  incoming: SessionActivity,
): SessionActivity {
  if (!existing || existing.type !== incoming.type) {
    return incoming;
  }

  if (incoming.type === "command") {
    const existingCommand = existing as CommandActivity;
    return {
      ...incoming,
      createdAt: existing.createdAt,
      output: incoming.output ?? existingCommand.output,
      exitCode: incoming.exitCode ?? existingCommand.exitCode,
      durationMs: incoming.durationMs ?? existingCommand.durationMs,
    };
  }

  const existingFileChange = existing as FileChangeActivity;
  return {
    ...incoming,
    createdAt: existing.createdAt,
    changes:
      incoming.changes.length > 0
        ? incoming.changes
        : existingFileChange.changes,
  };
}

export function mergeSessionActivities(
  historical: SessionActivity[],
  live: Iterable<SessionActivity>,
): SessionActivity[] {
  const merged = new Map<string, SessionActivity>();
  for (const activity of historical) {
    merged.set(activity.id, activity);
  }
  for (const activity of live) {
    merged.set(activity.id, mergeActivity(merged.get(activity.id), activity));
  }
  return [...merged.values()].sort((left, right) => left.createdAt - right.createdAt);
}

export function appendCommandActivityOutput(
  activity: CommandActivity | undefined,
  delta: string,
): CommandActivity | null {
  if (!activity || !delta) {
    return null;
  }

  return {
    ...activity,
    output: truncateNullableText(`${activity.output || ""}${delta}`, MAX_COMMAND_OUTPUT_CHARS),
  };
}

export function buildFileChangeChanges(raw: unknown): SessionActivityChange[] {
  if (!Array.isArray(raw)) {
    return [];
  }

  const changes: SessionActivityChange[] = [];

  for (const entry of raw) {
    if (!entry || typeof entry !== "object") {
      continue;
    }

    const typed = entry as Record<string, unknown>;
    const path = asString(typed.path);
    const diff = truncateNullableText(asString(typed.diff), MAX_DIFF_CHARS);
    const kindRecord =
      typed.kind && typeof typed.kind === "object"
        ? (typed.kind as Record<string, unknown>)
        : null;
    const kind = normalizeChangeKind(kindRecord?.type);

    if (!path || !kind || !diff) {
      continue;
    }

    const change: SessionActivityChange = {
      path,
      kind,
      diff,
    };
    const movePath = asString(kindRecord?.move_path);
    if (movePath) {
      change.movePath = movePath;
    }
    changes.push(change);
  }

  return changes;
}

function pickTurnTimestamp(
  startedAtSeconds: number | null,
  completedAtSeconds: number | null,
  threadUpdatedAtSeconds: number,
): number {
  const candidate = startedAtSeconds ?? completedAtSeconds ?? threadUpdatedAtSeconds;
  return candidate * 1000;
}

function normalizeStatus(value: unknown): SessionActivity["status"] {
  switch (value) {
    case "completed":
      return "completed";
    case "failed":
      return "failed";
    case "declined":
      return "declined";
    default:
      return "in_progress";
  }
}

function normalizeChangeKind(value: unknown): SessionActivityChange["kind"] | null {
  if (value === "add" || value === "delete" || value === "update") {
    return value;
  }
  return null;
}

function asString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function asNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function truncateNullableText(value: string | null, maxChars: number): string | null {
  if (!value) {
    return null;
  }

  if (value.length <= maxChars) {
    return value;
  }

  const head = value.slice(0, Math.floor(maxChars * 0.65));
  const tail = value.slice(-Math.floor(maxChars * 0.25));
  return `${head}\n\n... output truncated ...\n\n${tail}`;
}
