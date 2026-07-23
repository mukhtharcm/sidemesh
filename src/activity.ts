import path from "node:path";

import type {
  CommandActivity,
  ContextCompactionActivity,
  FileChangeActivity,
  ImageGenerationActivity,
  SessionActivity,
  SessionCommandActionSummary,
  SessionActivityChange,
  ToolActivity,
  ToolActivitySemantic,
  ToolActivitySemanticAction,
  ToolActivitySemanticCategory,
  ToolActivitySemanticTarget,
  ThreadItemRecord,
  ThreadRecord,
  TurnDiffActivity,
  WebSearchActivity,
} from "./types.js";
import {
  extractSessionAttachments,
  mergeSessionAttachments,
  stripSessionAttachments,
} from "./session-attachments.js";

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
    let seq = 0;
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
          seq: seq++,
        });
        if (activity) {
          activities.push(activity);
        }
      }
    }
    return {
      activities: activities.sort((left, right) => left.seq - right.seq),
      totalCount: activities.length,
    };
  }

  let totalCount = 0;
  const activities: SessionActivity[] = [];
  let seq = 0;

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
        seq: seq++,
      });
      if (activity) {
        activities.push(activity);
      }
    }
  }

  activities.sort((left, right) => left.seq - right.seq);
  return { activities, totalCount };
}

export function buildActivityFromThreadItem(
  item: ThreadItemRecord,
  context: {
    turnId: string | null;
    createdAt: number;
    seq: number;
    lifecycleStatus?: SessionActivity["status"];
  },
): SessionActivity | null {
  if (item.type === "commandExecution") {
    const source = normalizeCommandSource(item.source);
    const status = context.lifecycleStatus ?? normalizeStatus(item.status);
    return {
      id: item.id,
      type: "command",
      turnId: context.turnId,
      createdAt: context.createdAt,
      seq: context.seq,
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
      seq: context.seq,
      status: context.lifecycleStatus ?? normalizeStatus(item.status),
      changes: buildFileChangeChanges(item.changes),
    };
  }

  if (
    item.type === "toolExecution" ||
    item.type === "mcpToolCall" ||
    item.type === "dynamicToolCall" ||
    item.type === "collabAgentToolCall"
  ) {
    const tool = buildToolActivityFields(item);
    const attachments = extractSessionAttachments(tool.result);
    return {
      id: item.id,
      type: "tool",
      turnId: context.turnId,
      createdAt: context.createdAt,
      seq: context.seq,
      status: context.lifecycleStatus ?? normalizeStatus(item.status),
      toolName: tool.toolName,
      title: tool.title,
      args: tool.args,
      output: tool.output,
      result:
        attachments.length > 0
          ? stripSessionAttachments(tool.result) ?? null
          : tool.result,
      attachments,
      isError: tool.isError,
      semantic: normalizeToolSemantic(item),
    };
  }

  if (item.type === "webSearch") {
    return buildWebSearchActivity(item, context);
  }

  if (item.type === "imageGeneration") {
    return {
      id: item.id,
      type: "image_generation",
      turnId: context.turnId,
      createdAt: context.createdAt,
      seq: context.seq,
      status: context.lifecycleStatus ?? normalizeStatus(item.status),
      revisedPrompt: asString(item.revisedPrompt),
      savedPath: asString(item.savedPath),
    };
  }

  if (item.type === "contextCompaction") {
    return buildContextCompactionActivity(item, context);
  }

  return null;
}

function buildToolActivityFields(item: ThreadItemRecord): {
  toolName: string;
  title: string | null;
  args: unknown;
  output: string | null;
  result: unknown;
  isError: boolean | null;
} {
  if (item.type === "mcpToolCall") {
    const server = asString(item.server);
    const tool = asString(item.tool) || "tool";
    const status = normalizeStatus(item.status);
    return {
      toolName: server ? `${server}.${tool}` : tool,
      title: server ? `${tool} via ${server}` : tool,
      args: item.arguments ?? null,
      output: null,
      result: item.result ?? item.error ?? null,
      isError: item.error != null ? true : status === "completed" ? false : null,
    };
  }

  if (item.type === "dynamicToolCall") {
    const namespace = asString(item.namespace);
    const tool = asString(item.tool) || "tool";
    return {
      toolName: namespace ? `${namespace}.${tool}` : tool,
      title: tool,
      args: item.arguments ?? null,
      output: null,
      result: item.contentItems ?? null,
      isError: typeof item.success === "boolean" ? !item.success : null,
    };
  }

  if (item.type === "collabAgentToolCall") {
    const tool = asString(item.tool) || "agent collaboration";
    const status = normalizeStatus(item.status);
    return {
      toolName: `collab.${tool}`,
      title: tool,
      args: {
        prompt: item.prompt ?? null,
        receiverThreadIds: item.receiverThreadIds ?? [],
        model: item.model ?? null,
        reasoningEffort: item.reasoningEffort ?? null,
      },
      output: null,
      result: item.agentsStates ?? null,
      isError: status === "failed" ? true : status === "completed" ? false : null,
    };
  }

  return {
    toolName: asString(item.toolName) || asString(item.name) || "tool",
    title: asString(item.title),
    args: item.args ?? item.arguments ?? null,
    output: truncateNullableText(asString(item.output), MAX_COMMAND_OUTPUT_CHARS),
    result: item.result ?? null,
    isError: typeof item.isError === "boolean" ? item.isError : null,
  };
}

export function mergeActivity(
  existing: SessionActivity | undefined,
  incoming: SessionActivity,
): SessionActivity {
  if (incoming.type === "tool") {
    incoming = withToolAttachments(incoming);
  }
  if (!existing || existing.type !== incoming.type) {
    return incoming;
  }

  if (incoming.type === "command") {
    const existingCommand = existing as CommandActivity;
    return {
      ...incoming,
      createdAt: existing.createdAt,
      seq: existing.seq,
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
      seq: existing.seq,
      diff: incoming.diff ?? existingTurnDiff.diff,
    };
  }

  if (incoming.type === "tool") {
    const existingTool = existing as ToolActivity;
    return {
      ...incoming,
      createdAt: existing.createdAt,
      seq: existing.seq,
      title: incoming.title ?? existingTool.title,
      args: incoming.args ?? existingTool.args,
      output: incoming.output ?? existingTool.output,
      result: incoming.result ?? existingTool.result,
      attachments:
        incoming.attachments && incoming.attachments.length > 0
          ? incoming.attachments
          : existingTool.attachments ?? [],
      isError: incoming.isError ?? existingTool.isError,
      semantic: mergeToolSemantic(existingTool.semantic, incoming.semantic),
    };
  }

  if (incoming.type === "web_search") {
    const existingSearch = existing as WebSearchActivity;
    return {
      ...incoming,
      createdAt: existing.createdAt,
      seq: existing.seq,
      query: incoming.query ?? existingSearch.query,
      queries:
        incoming.queries.length > 0 ? incoming.queries : existingSearch.queries,
      targetUrl: incoming.targetUrl ?? existingSearch.targetUrl,
      pattern: incoming.pattern ?? existingSearch.pattern,
    };
  }

  if (incoming.type === "image_generation") {
    const existingImage = existing as ImageGenerationActivity;
    return {
      ...incoming,
      createdAt: existing.createdAt,
      seq: existing.seq,
      revisedPrompt: incoming.revisedPrompt ?? existingImage.revisedPrompt,
      savedPath: incoming.savedPath ?? existingImage.savedPath,
    };
  }

  if (incoming.type === "context_compaction") {
    return {
      ...incoming,
      createdAt: existing.createdAt,
      seq: existing.seq,
    };
  }

  const existingFileChange = existing as FileChangeActivity;
  return {
    ...incoming,
    createdAt: existing.createdAt,
    seq: existing.seq,
    changes:
      incoming.changes.length > 0
        ? incoming.changes
        : existingFileChange.changes,
  };
}

function withToolAttachments(activity: ToolActivity): ToolActivity {
  const attachments = mergeSessionAttachments(
    activity.attachments ?? [],
    extractSessionAttachments(activity.result),
  );
  return attachments.length > 0 || activity.attachments
    ? {
        ...activity,
        result:
          attachments.length > 0
            ? stripSessionAttachments(activity.result, attachments) ?? null
            : activity.result,
        attachments,
      }
    : activity;
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
  return [...merged.values()].sort((left, right) => left.seq - right.seq);
}

export function normalizeStoredSessionActivity(
  activity: SessionActivity,
): SessionActivity {
  if (activity.type !== "tool") {
    return activity;
  }
  return {
    ...activity,
    semantic: normalizeToolSemantic(activity),
  };
}

export function appendCommandActivityOutput(
  activity: CommandActivity | ToolActivity | undefined,
  delta: string,
): CommandActivity | ToolActivity | null {
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
  seq: number,
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
    seq,
    status: "in_progress",
    diff: normalized,
  };
}

export function buildCommandActivityFromRolloutEvent(
  payload: unknown,
  createdAt: number,
  seq: number,
): CommandActivity | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const typed = payload as Record<string, unknown>;
  const id = asString(typed.call_id) || asString(typed.callId);
  const cwd = asString(typed.cwd) || "";
  if (!id || !cwd) {
    return null;
  }

  const command = normalizeCommandText(typed.command);
  const output = truncateNullableText(
    resolveCommandOutput(typed),
    MAX_COMMAND_OUTPUT_CHARS,
  );
  const source = normalizeCommandSource(typed.source);
  const status = normalizeStatus(typed.status);

  return {
    id,
    type: "command",
    turnId: asString(typed.turn_id) || asString(typed.turnId),
    createdAt,
    seq,
    status,
    command,
    cwd,
    output,
    exitCode: asNumber(typed.exit_code) ?? asNumber(typed.exitCode),
    durationMs: parseDurationMs(typed.duration) ?? asNumber(typed.duration_ms),
    source,
    processId: asString(typed.process_id) || asString(typed.processId),
    commandActions: summarizeCommandActions(typed.parsed_cmd ?? typed.parsedCmd),
    terminalStatus:
      status === "in_progress" && isInteractiveCommandSource(source) ? "waiting" : null,
    terminalInput: truncateNullableText(
      asString(typed.interaction_input) || asString(typed.interactionInput),
      MAX_TERMINAL_INPUT_CHARS,
    ),
  };
}

export function buildCommandActivityFromGuardianAssessment(
  payload: unknown,
  createdAt: number,
  seq: number,
): CommandActivity | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const typed = payload as Record<string, unknown>;
  const status = normalizeGuardianStatus(typed.status);
  if (!status) {
    return null;
  }

  const id = asString(typed.target_item_id) || asString(typed.targetItemId);
  const action =
    typed.action && typeof typed.action === "object"
      ? (typed.action as Record<string, unknown>)
      : null;
  if (!id || !action) {
    return null;
  }

  const cwd = asString(action.cwd) || "";
  if (!cwd) {
    return null;
  }

  const command = normalizeGuardianCommandText(action);
  if (!command) {
    return null;
  }

  return {
    id,
    type: "command",
    turnId: asString(typed.turn_id) || asString(typed.turnId),
    createdAt,
    seq,
    status,
    command,
    cwd,
    output: null,
    exitCode: null,
    durationMs: null,
    source: "agent",
    processId: null,
    commandActions: summarizeGuardianCommandActions(action, command),
    terminalStatus: status === "in_progress" ? "waiting" : null,
    terminalInput: null,
  };
}

export function buildFileChangeActivityFromRolloutEvent(
  payload: unknown,
  createdAt: number,
  seq: number,
): FileChangeActivity | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const typed = payload as Record<string, unknown>;
  const id = asString(typed.call_id) || asString(typed.callId);
  if (!id) {
    return null;
  }

  return {
    id,
    type: "file_change",
    turnId: asString(typed.turn_id) || asString(typed.turnId),
    createdAt,
    seq,
    status: normalizeStatus(typed.status),
    changes: buildFileChangeChangesFromPatchMap(typed.changes),
  };
}

export function buildWebSearchActivityFromRolloutEvent(
  payload: unknown,
  createdAt: number,
  seq: number,
): WebSearchActivity | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const typed = payload as Record<string, unknown>;
  const id = asString(typed.call_id) || asString(typed.callId);
  if (!id) {
    return null;
  }

  const action = normalizeWebSearchAction(typed.action);
  const hasCompletedAction =
    action.queries.length > 0 ||
    action.targetUrl !== null ||
    action.pattern !== null ||
    action.query !== null;

  return {
    id,
    type: "web_search",
    turnId: asString(typed.turn_id) || asString(typed.turnId),
    createdAt,
    seq,
    status:
      typed.status == null
        ? hasCompletedAction
          ? "completed"
          : "in_progress"
        : normalizeStatus(typed.status),
    query: asString(typed.query) || action.query,
    queries: action.queries,
    targetUrl: action.targetUrl,
    pattern: action.pattern,
  };
}

export function buildImageGenerationActivityFromRolloutEvent(
  payload: unknown,
  createdAt: number,
  seq: number,
): ImageGenerationActivity | null {
  if (!payload || typeof payload !== "object") {
    return null;
  }

  const typed = payload as Record<string, unknown>;
  const id =
    asString(typed.call_id) ||
    asString(typed.callId) ||
    asString(typed.id);
  if (!id) {
    return null;
  }

  return {
    id,
    type: "image_generation",
    turnId: asString(typed.turn_id) || asString(typed.turnId),
    createdAt,
    seq,
    status: normalizeStatus(typed.status),
    revisedPrompt: asString(typed.revised_prompt) || asString(typed.revisedPrompt),
    savedPath: asString(typed.saved_path) || asString(typed.savedPath),
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

export function buildFileChangeChangesFromPatchMap(raw: unknown): SessionActivityChange[] {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return [];
  }

  const typed = raw as Record<string, unknown>;
  const changes: SessionActivityChange[] = [];

  for (const pathValue of Object.keys(typed).sort()) {
    const change =
      typed[pathValue] && typeof typed[pathValue] === "object"
        ? (typed[pathValue] as Record<string, unknown>)
        : null;
    if (!change) {
      continue;
    }

    const kind = normalizeChangeKind(change.type);
    const diff = truncateNullableText(formatPatchMapDiff(change), MAX_DIFF_CHARS);
    if (!kind || !diff) {
      continue;
    }

    const next: SessionActivityChange = {
      path: pathValue,
      kind,
      diff,
    };
    const movePath = asString(change.move_path) || asString(change.movePath);
    if (movePath) {
      next.movePath = movePath;
    }
    changes.push(next);
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
  return (
    item.type === "commandExecution" ||
    item.type === "toolExecution" ||
    item.type === "mcpToolCall" ||
    item.type === "dynamicToolCall" ||
    item.type === "collabAgentToolCall" ||
    item.type === "fileChange" ||
    item.type === "webSearch" ||
    item.type === "imageGeneration" ||
    item.type === "contextCompaction"
  );
}

function buildContextCompactionActivity(
  item: ThreadItemRecord,
  context: {
    turnId: string | null;
    createdAt: number;
    seq: number;
    lifecycleStatus?: SessionActivity["status"];
  },
): ContextCompactionActivity | null {
  const id = asString(item.id);
  if (!id) {
    return null;
  }
  return {
    id,
    type: "context_compaction",
    turnId: context.turnId,
    createdAt: context.createdAt,
    seq: context.seq,
    status: context.lifecycleStatus ?? normalizeStatus(item.status),
  };
}

function buildWebSearchActivity(
  item: ThreadItemRecord,
  context: {
    turnId: string | null;
    createdAt: number;
    seq: number;
    lifecycleStatus?: SessionActivity["status"];
  },
): WebSearchActivity | null {
  const id = asString(item.id);
  if (!id) {
    return null;
  }

  const action = normalizeWebSearchAction(item.action);
  const query = asString(item.query) || action.query;
  const hasCompletedAction =
    action.queries.length > 0 ||
    action.targetUrl !== null ||
    action.pattern !== null ||
    query !== null;

  return {
    id,
    type: "web_search",
    turnId: context.turnId,
    createdAt: context.createdAt,
    seq: context.seq,
    status:
      context.lifecycleStatus ??
      (hasCompletedAction ? "completed" : "in_progress"),
    query,
    queries: action.queries,
    targetUrl: action.targetUrl,
    pattern: action.pattern,
  };
}

function normalizeWebSearchAction(raw: unknown): {
  query: string | null;
  queries: string[];
  targetUrl: string | null;
  pattern: string | null;
} {
  const typed =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : null;
  if (!typed) {
    return {
      query: null,
      queries: [],
      targetUrl: null,
      pattern: null,
    };
  }

  return {
    query: asString(typed.query),
    queries: Array.isArray(typed.queries)
      ? typed.queries
          .map((value) => asString(value))
          .filter((value): value is string => value !== null)
      : [],
    targetUrl: asString(typed.url),
    pattern: asString(typed.pattern),
  };
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

function normalizeToolSemantic(raw: unknown): ToolActivitySemantic | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const typed = raw as Record<string, unknown>;
  const semanticSource =
    typed.semantic && typeof typed.semantic === "object"
      ? (typed.semantic as Record<string, unknown>)
      : typed;
  const category = normalizeToolCategory(
    semanticSource.category ?? typed.toolCategory,
  );
  const action = normalizeToolAction(
    semanticSource.action ?? typed.toolAction,
  );
  if (!category || !action) {
    return null;
  }
  const targets = normalizeToolSemanticTargets(
    semanticSource.targets,
    typed,
  );
  return {
    category,
    action,
    targets,
  };
}

function mergeToolSemantic(
  existing: ToolActivitySemantic | null,
  incoming: ToolActivitySemantic | null,
): ToolActivitySemantic | null {
  if (!existing) {
    return incoming;
  }
  if (!incoming) {
    return existing;
  }
  const category =
    incoming.category === "unknown" ? existing.category : incoming.category;
  const action =
    incoming.category === "unknown" && incoming.action === "invoke"
      ? existing.action
      : incoming.action;
  return {
    category,
    action,
    targets:
      incoming.targets.length > 0 ? incoming.targets : existing.targets,
  };
}

function normalizeToolCategory(
  value: unknown,
): ToolActivitySemanticCategory | null {
  switch (value) {
    case "filesystem":
    case "network":
    case "command":
    case "session":
    case "memory":
    case "task":
    case "unknown":
      return value;
    default:
      return null;
  }
}

function normalizeToolAction(value: unknown): ToolActivitySemanticAction | null {
  switch (value) {
    case "read":
    case "write":
    case "search":
    case "list":
    case "fetch":
    case "mode_change":
    case "invoke":
    case "unknown":
      return value;
    default:
      return null;
  }
}

function normalizeToolSemanticTargets(
  raw: unknown,
  legacy: Record<string, unknown>,
): ToolActivitySemanticTarget[] {
  const normalized = Array.isArray(raw)
    ? raw
        .map((entry) => normalizeToolSemanticTarget(entry))
        .filter((entry): entry is ToolActivitySemanticTarget => entry !== null)
    : [];
  if (normalized.length > 0) {
    return normalized;
  }
  return legacyToolTargets(legacy);
}

function normalizeToolSemanticTarget(
  raw: unknown,
): ToolActivitySemanticTarget | null {
  if (!raw || typeof raw !== "object") {
    return null;
  }
  const typed = raw as Record<string, unknown>;
  switch (typed.type) {
    case "file": {
      const path = asString(typed.path);
      if (!path) return null;
      const access =
        typed.access === "read" || typed.access === "write"
          ? typed.access
          : undefined;
      const role =
        typed.role === "target" || typed.role === "context"
          ? typed.role
          : undefined;
      return { type: "file", path, ...(access ? { access } : {}), ...(role ? { role } : {}) };
    }
    case "url": {
      const url = asString(typed.url);
      if (!url) return null;
      const role =
        typed.role === "target" || typed.role === "context"
          ? typed.role
          : undefined;
      return { type: "url", url, ...(role ? { role } : {}) };
    }
    case "query": {
      const value = asString(typed.value);
      return value ? { type: "query", value } : null;
    }
    case "mode": {
      const value = asString(typed.value);
      return value ? { type: "mode", value } : null;
    }
    case "command": {
      const command = asString(typed.command);
      return command ? { type: "command", command } : null;
    }
    case "unknown": {
      const label = asString(typed.label);
      return label ? { type: "unknown", label } : null;
    }
    default:
      return null;
  }
}

function legacyToolTargets(
  legacy: Record<string, unknown>,
): ToolActivitySemanticTarget[] {
  const targets: ToolActivitySemanticTarget[] = [];
  const category = normalizeToolCategory(legacy.toolCategory);
  const action = normalizeToolAction(legacy.toolAction);
  const toolTarget = asString(legacy.toolTarget);
  for (const entry of asStringArray(legacy.toolTargets)) {
    targets.push({ type: "file", path: entry, role: "target" });
  }
  const toolUrl = asString(legacy.toolUrl);
  if (toolUrl) {
    targets.push({ type: "url", url: toolUrl, role: "target" });
  }
  const toolQuery = asString(legacy.toolQuery);
  if (toolQuery) {
    targets.push({ type: "query", value: toolQuery });
  }
  const toolMode = asString(legacy.toolMode);
  if (toolMode) {
    targets.push({ type: "mode", value: toolMode });
  }
  if (toolTarget) {
    const inferred =
      category === "command"
        ? ({ type: "command", command: toolTarget } as const)
        : category === "session" || action === "mode_change"
          ? ({ type: "mode", value: toolTarget } as const)
          : toolUrl && toolUrl === toolTarget
            ? ({ type: "url", url: toolTarget, role: "target" } as const)
            : category === "network"
              ? ({ type: "url", url: toolTarget, role: "target" } as const)
              : ({ type: "file", path: toolTarget, role: "target" } as const);
    const duplicate = targets.some((target) => {
      if (target.type !== inferred.type) return false;
      switch (target.type) {
        case "file":
          return inferred.type === "file" && target.path === inferred.path;
        case "url":
          return inferred.type === "url" && target.url === inferred.url;
        case "mode":
          return inferred.type === "mode" && target.value === inferred.value;
        case "command":
          return (
            inferred.type === "command" && target.command === inferred.command
          );
        default:
          return false;
      }
    });
    if (!duplicate) {
      targets.unshift(inferred);
    }
  }
  return targets;
}

function normalizeCommandSource(value: unknown): string | null {
  switch (value) {
    case "agent":
    case "userShell":
    case "unifiedExecStartup":
    case "unifiedExecInteraction":
      return value;
    case "user_shell":
      return "userShell";
    case "unified_exec_startup":
      return "unifiedExecStartup";
    case "unified_exec_interaction":
      return "unifiedExecInteraction";
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

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((entry): entry is string => typeof entry === "string");
}

function normalizeCommandText(value: unknown): string {
  if (typeof value === "string") {
    return value;
  }

  const command = asStringArray(value);
  if (command.length === 0) {
    return "";
  }

  return command.map(quoteShellArg).join(" ");
}

function normalizeGuardianCommandText(action: Record<string, unknown>): string | null {
  switch (action.type) {
    case "command":
      return asString(action.command);
    case "execve": {
      const argv = asStringArray(action.argv);
      if (argv.length > 0) {
        return normalizeCommandText(argv);
      }
      const program = asString(action.program);
      return program ? quoteShellArg(program) : null;
    }
    default:
      return null;
  }
}

function summarizeGuardianCommandActions(
  action: Record<string, unknown>,
  command: string,
): SessionCommandActionSummary[] {
  switch (action.type) {
    case "command":
      return [{ kind: "unknown", label: truncateLabel(command, 34) || "Run command" }];
    case "execve": {
      const argv = asStringArray(action.argv);
      const normalized = argv.length > 0 ? normalizeCommandText(argv) : command;
      return [{ kind: "unknown", label: truncateLabel(normalized, 34) || "Run command" }];
    }
    default:
      return [];
  }
}

function normalizeGuardianStatus(value: unknown): SessionActivity["status"] | null {
  switch (value) {
    case "in_progress":
      return "in_progress";
    case "denied":
    case "aborted":
      return "declined";
    case "timed_out":
      return "failed";
    default:
      return null;
  }
}

function resolveCommandOutput(payload: Record<string, unknown>): string | null {
  return (
    asString(payload.aggregated_output) ||
    asString(payload.aggregatedOutput) ||
    mergeStreams(asString(payload.stdout), asString(payload.stderr))
  );
}

function mergeStreams(stdout: string | null, stderr: string | null): string | null {
  const parts = [stdout, stderr].filter((value): value is string => Boolean(value));
  if (parts.length === 0) {
    return null;
  }
  return parts.join(stdout && stderr ? "\n" : "");
}

function parseDurationMs(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }

  if (typeof value === "string" && value.trim()) {
    const numeric = Number.parseFloat(value);
    if (Number.isFinite(numeric)) {
      return Math.round(numeric);
    }
  }

  if (!value || typeof value !== "object") {
    return null;
  }

  const typed = value as Record<string, unknown>;
  const secs = asNumber(typed.secs) ?? 0;
  const nanos = asNumber(typed.nanos) ?? 0;
  return Math.round(secs * 1000 + nanos / 1_000_000);
}

function formatPatchMapDiff(change: Record<string, unknown>): string | null {
  switch (change.type) {
    case "add":
    case "delete":
      return asString(change.content);
    case "update": {
      const diff = asString(change.unified_diff) || asString(change.unifiedDiff);
      const movePath = asString(change.move_path) || asString(change.movePath);
      if (!diff) {
        return null;
      }
      return movePath ? `${diff}\n\nMoved to: ${movePath}` : diff;
    }
    default:
      return null;
  }
}

function quoteShellArg(value: string): string {
  if (!value) {
    return "''";
  }
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(value)) {
    return value;
  }
  return `'${value.replace(/'/g, `'\\''`)}'`;
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
