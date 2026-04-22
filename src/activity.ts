import path from "node:path";

import type {
  CommandActivity,
  FileChangeActivity,
  SessionActivity,
  SessionCommandActionSummary,
  SessionActivityChange,
  ThreadItemRecord,
  ThreadRecord,
  TurnDiffActivity,
} from "./types.js";

const MAX_COMMAND_OUTPUT_CHARS = 12_000;
const MAX_DIFF_CHARS = 8_000;
const MAX_TERMINAL_INPUT_CHARS = 2_000;

export interface ExtractedSessionActivities {
  activities: SessionActivity[];
  totalCount: number;
}

export function extractSessionActivities(
  thread: ThreadRecord,
  limit: number | null = null,
): ExtractedSessionActivities {
  const turns = Array.isArray(thread.turns) ? thread.turns : [];
  const boundedLimit = limit && limit > 0 ? limit : null;

  if (!boundedLimit) {
    const activities: SessionActivity[] = [];
    for (const turn of turns) {
      const items = Array.isArray(turn.items) ? turn.items : [];
      const baseCreatedAt = pickTurnTimestamp(
        turn.startedAt,
        turn.completedAt,
        thread.updatedAt,
      );
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
    return {
      activities: activities.sort((left, right) => left.createdAt - right.createdAt),
      totalCount: activities.length,
    };
  }

  let totalCount = 0;
  const activities: SessionActivity[] = [];

  for (let turnIndex = turns.length - 1; turnIndex >= 0; turnIndex -= 1) {
    const turn = turns[turnIndex];
    const items = Array.isArray(turn.items) ? turn.items : [];
    const baseCreatedAt = pickTurnTimestamp(
      turn.startedAt,
      turn.completedAt,
      thread.updatedAt,
    );
    for (let itemIndex = items.length - 1; itemIndex >= 0; itemIndex -= 1) {
      const item = items[itemIndex];
      if (!isActivityThreadItem(item)) {
        continue;
      }
      totalCount += 1;
      if (activities.length >= boundedLimit) {
        continue;
      }
      const activity = buildActivityFromThreadItem(item, {
        turnId: turn.id,
        createdAt: baseCreatedAt + itemIndex,
      });
      if (activity) {
        activities.push(activity);
      }
    }
  }

  activities.sort((left, right) => left.createdAt - right.createdAt);
  return { activities, totalCount };
}

export function buildActivityFromThreadItem(
  item: ThreadItemRecord,
  context: { turnId: string | null; createdAt: number },
): SessionActivity | null {
  if (item.type === "commandExecution") {
    const source = normalizeCommandSource(item.source);
    const status = normalizeStatus(item.status);
    return {
      id: item.id,
      type: "command",
      turnId: context.turnId,
      createdAt: context.createdAt,
      status,
      command: asString(item.command) || "",
      cwd: asString(item.cwd) || "",
      output: truncateNullableText(asString(item.aggregatedOutput), MAX_COMMAND_OUTPUT_CHARS),
      exitCode: asNumber(item.exitCode),
      durationMs: asNumber(item.durationMs),
      source,
      processId: asString(item.processId),
      commandActions: summarizeCommandActions(item.commandActions),
      terminalStatus:
        status === "in_progress" && isInteractiveCommandSource(source) ? "waiting" : null,
      terminalInput: null,
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
      source: incoming.source ?? existingCommand.source,
      processId: incoming.processId ?? existingCommand.processId,
      commandActions:
        incoming.commandActions.length > 0
          ? incoming.commandActions
          : existingCommand.commandActions,
      terminalStatus:
        incoming.status === "in_progress"
          ? incoming.terminalStatus ?? existingCommand.terminalStatus
          : incoming.terminalStatus,
      terminalInput: incoming.terminalInput ?? existingCommand.terminalInput,
    };
  }

  if (incoming.type === "turn_diff") {
    const existingTurnDiff = existing as TurnDiffActivity;
    return {
      ...incoming,
      createdAt: existing.createdAt,
      diff: incoming.diff ?? existingTurnDiff.diff,
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

export function applyCommandTerminalInteraction(
  activity: CommandActivity | undefined,
  stdin: string,
): CommandActivity | null {
  if (!activity || !stdin) {
    return null;
  }

  return {
    ...activity,
    terminalStatus: "input",
    terminalInput: truncateNullableText(
      `${activity.terminalInput || ""}${stdin}`,
      MAX_TERMINAL_INPUT_CHARS,
    ),
  };
}

export function buildTurnDiffActivity(
  turnId: string | null,
  diff: string,
  createdAt: number,
): TurnDiffActivity | null {
  const normalized = truncateNullableText(diff, MAX_DIFF_CHARS);
  if (!turnId || !normalized) {
    return null;
  }

  return {
    id: `turn-diff:${turnId}`,
    type: "turn_diff",
    turnId,
    createdAt,
    status: "in_progress",
    diff: normalized,
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

function isActivityThreadItem(item: ThreadItemRecord): boolean {
  return item.type === "commandExecution" || item.type === "fileChange";
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

function normalizeCommandSource(value: unknown): string | null {
  switch (value) {
    case "agent":
    case "userShell":
    case "unifiedExecStartup":
    case "unifiedExecInteraction":
      return value;
    default:
      return asString(value);
  }
}

function isInteractiveCommandSource(source: string | null): boolean {
  return (
    source === "userShell" ||
    source === "unifiedExecStartup" ||
    source === "unifiedExecInteraction"
  );
}

function summarizeCommandActions(raw: unknown): SessionCommandActionSummary[] {
  if (!Array.isArray(raw)) {
    return [];
  }

  const summaries: SessionCommandActionSummary[] = [];
  const seen = new Set<string>();

  for (const entry of raw) {
    if (!entry || typeof entry !== "object") {
      continue;
    }

    const typed = entry as Record<string, unknown>;
    const summary = summarizeCommandAction(typed);
    if (!summary) {
      continue;
    }

    const key = `${summary.kind}:${summary.label}`;
    if (seen.has(key)) {
      continue;
    }

    seen.add(key);
    summaries.push(summary);

    if (summaries.length >= 4) {
      break;
    }
  }

  return summaries;
}

function summarizeCommandAction(
  action: Record<string, unknown>,
): SessionCommandActionSummary | null {
  switch (action.type) {
    case "read": {
      const targetPath = asString(action.path) || asString(action.name);
      if (!targetPath) {
        return { kind: "read", label: "Read file" };
      }
      return { kind: "read", label: `Read ${path.basename(targetPath)}` };
    }
    case "listFiles": {
      const targetPath = asString(action.path);
      if (!targetPath) {
        return { kind: "list_files", label: "List files" };
      }
      return { kind: "list_files", label: `List ${path.basename(targetPath) || targetPath}` };
    }
    case "search": {
      const query = asString(action.query);
      if (query) {
        return { kind: "search", label: `Search "${truncateLabel(query, 28)}"` };
      }
      const targetPath = asString(action.path);
      if (!targetPath) {
        return { kind: "search", label: "Search files" };
      }
      return { kind: "search", label: `Search ${path.basename(targetPath) || targetPath}` };
    }
    case "unknown": {
      const command = asString(action.command);
      if (!command) {
        return { kind: "unknown", label: "Run command" };
      }
      return { kind: "unknown", label: truncateLabel(command, 34) };
    }
    default:
      return null;
  }
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

function truncateLabel(value: string, maxChars: number): string {
  if (value.length <= maxChars) {
    return value;
  }
  return `${value.slice(0, maxChars - 3)}...`;
}
