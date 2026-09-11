import { readdir, readFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { z } from "zod";
import type { AgentSessionLogOptions } from "./agent-provider.js";
import { materializeAgentActivityDraft } from "./agent-provider.js";
import type { SessionActivity, SessionLogSnapshot, SessionMessage, SessionMessageAttachment,
  SessionMessageContentBlock, SessionRuntimeSummary, ThreadRecord, ToolActivitySemantic,
  ToolActivitySemanticAction, ToolActivitySemanticCategory, ToolActivitySemanticTarget } from "./types.js";
import type { SessionStore, StoredProviderSession, StoredSessionItem } from "./session-store.js";

const TOOL_OUTPUT_MAX_CHARS = 4_000;
const legacyUserContent = z.array(z.union([
  z.object({ Text: z.string() }),
  z.object({ Mention: z.object({ uri: z.string(), content: z.string() }) }),
  z.object({ Image: z.object({ source: z.string() }) }),
  z.object({ Audio: z.object({ source: z.string().optional(), data: z.string().optional(),
    mimeType: z.string().optional(), mime_type: z.string().optional() }) }),
]));
type AcpxUserContent = z.infer<typeof legacyUserContent>;
const legacyRecord = z.object({
  schema: z.literal("acpx.session.v1"), acpxRecordId: z.string().min(1), acpSessionId: z.string().min(1),
  agentCommand: z.string(), cwd: z.string().refine(isAbsolute), name: z.string().optional(), title: z.string().nullable().optional(),
  createdAt: z.string().datetime({ offset: true }), updated_at: z.string().datetime({ offset: true }),
  lastUsedAt: z.string().datetime({ offset: true }), closed: z.boolean().optional(),
  messages: z.array(z.union([
    z.literal("Resume"), z.object({ User: z.object({ id: z.string(), content: legacyUserContent }) }),
    z.object({ Agent: z.object({ content: z.array(z.union([
      z.object({ Text: z.string() }), z.object({ Thinking: z.object({ text: z.string(), signature: z.string().nullable().optional() }) }),
      z.object({ RedactedThinking: z.string() }), z.object({ ToolUse: z.object({
        id: z.string(), name: z.string(), raw_input: z.string(), input: z.unknown(), is_input_complete: z.boolean(),
      }) }),
    ])), tool_results: z.record(z.string(), z.object({ tool_use_id: z.string(), tool_name: z.string(),
      is_error: z.boolean(), content: z.unknown(), output: z.unknown().optional() })) }) }),
  ])),
  cumulative_token_usage: z.object({ input_tokens: z.number().optional(), output_tokens: z.number().optional(),
    cache_creation_input_tokens: z.number().optional(), cache_read_input_tokens: z.number().optional() }).default({}),
  acpx: z.object({ current_model_id: z.string().optional(), current_mode_id: z.string().optional(),
    config_options: z.array(z.unknown()).optional(), available_commands: z.array(z.unknown()).optional() }).optional(),
});
type AcpSessionRecord = z.infer<typeof legacyRecord>;

/** Import old display records without executing a command or changing the source files. */
export async function importAcpxHistory(store: SessionStore, providerId: string, stateDir: string): Promise<void> {
  const migration = `acpx-json-v1:${providerId}`;
  if (store.hasMigration(migration)) return;
  const directory = join(stateDir, "sessions");
  let names: string[];
  try { names = await readdir(directory); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; names = []; }
  const sessions: Array<{ session: StoredProviderSession; items: StoredSessionItem[] }> = [];
  for (const name of names.filter((name) => name.endsWith(".json")).sort()) {
    const record = legacyRecord.parse(JSON.parse(await readFile(join(directory, name), "utf8")));
    if (decodeURIComponent(name.slice(0, -5)) !== record.acpxRecordId) throw new Error(`ACP record ID does not match its file: ${name}`);
    const thread = mapAcpxRecordToThread(record);
    const log = mapAcpxRecordToSessionLog(record);
    sessions.push({ session: {
      id: record.acpxRecordId, nativeId: record.acpSessionId, cwd: record.cwd, name: thread.name ?? null,
      preview: thread.preview, createdAt: millisFromIso(record.createdAt), updatedAt: recordUpdatedMillis(record),
      archived: record.closed ?? false, metadata: { runtime: log.runtime },
    }, items: [
      ...log.messages.map((value): StoredSessionItem => ({ kind: "message", value, nativeId: null, authority: "primary" })),
      ...log.activities.map((value): StoredSessionItem => ({ kind: "activity",
        value: materializeAgentActivityDraft(value, value), nativeId: value.id, authority: "primary" })),
    ] });
  }
  store.importProviderSessions(migration, providerId, sessions);
}

export function mapAcpxRecordToThread(
  record: AcpSessionRecord,
  options: { includeTurns?: boolean; activeTurnId?: string | null } = {},
): ThreadRecord {
  const activeTurnId = options.activeTurnId ?? null;
  const preview = recordPreview(record);
  return {
    id: record.acpxRecordId,
    name: record.name ?? record.title ?? null,
    preview,
    createdAt: secondsFromIso(record.createdAt),
    updatedAt: secondsFromIso(recordUpdatedIso(record)),
    cwd: record.cwd,
    source: "acpx",
    path: null,
    status: record.closed
      ? { type: "closed", phase: "closed" }
      : activeTurnId
        ? { type: "running", phase: "running", activeFlags: ["inProgress"] }
        : { type: "idle", phase: "idle" },
    turns: options.includeTurns
      ? activeTurnId
        ? [{ id: activeTurnId, status: "inProgress", startedAt: null, completedAt: null }]
        : []
      : undefined,
  };
}

export function mapAcpxRecordToSessionLog(
  record: AcpSessionRecord,
  options: AgentSessionLogOptions = {},
): SessionLogSnapshot {
  const messages: SessionMessage[] = [];
  const activities: SessionActivity[] = [];
  let seq = 0;
  for (const [messageIndex, message] of record.messages.entries()) {
    if (typeof message === "string") {
      continue;
    }
    if ("User" in message) {
      messages.push({
        id: message.User.id || `acpx-user-${messageIndex}`,
        role: "user",
        text: userContentText(message.User.content),
        content: userContentBlocks(message.User.content),
        attachments: userContentAttachments(message.User.content),
        createdAt: millisFromIso(record.createdAt) + seq,
        seq: seq++,
      });
      continue;
    }
    if ("Agent" in message) {
      const contentBlocks: SessionMessageContentBlock[] = [];
      const textParts: string[] = [];
      for (const [contentIndex, content] of message.Agent.content.entries()) {
        if ("Text" in content) {
          textParts.push(content.Text);
          contentBlocks.push({ type: "text", text: content.Text });
        } else if ("Thinking" in content) {
          contentBlocks.push({
            type: "thinking",
            thinking: content.Thinking.text,
            reasoningId: content.Thinking.signature ?? undefined,
          });
        } else if ("RedactedThinking" in content) {
          contentBlocks.push({
            type: "thinking",
            thinking: content.RedactedThinking,
            summary: true,
          });
        } else if ("ToolUse" in content) {
          const activity = toolActivityFromRecordContent({
            record,
            messageIndex,
            contentIndex,
            toolUse: content.ToolUse,
            result: message.Agent.tool_results[content.ToolUse.id],
            seq: seq++,
          });
          activities.push(activity);
        }
      }
      if (contentBlocks.length > 0) {
        const text = textParts.join("\n").trim();
        messages.push({
          id: `acpx-agent-${messageIndex}`,
          role: "assistant",
          text,
          content: contentBlocks,
          attachments: [],
          createdAt: millisFromIso(record.createdAt) + seq,
          seq: seq++,
          phase: text ? "final_answer" : "commentary",
        });
      }
    }
  }
  const limitedMessages = limitTail(messages, options.messageLimit ?? null);
  const limitedActivities = limitTail(activities, options.activityLimit ?? null);
  return {
    messages: limitedMessages,
    activities: limitedActivities,
    runtime: runtimeSummaryFromRecord(record),
    totalMessages: messages.length,
    totalActivities: activities.length,
    nextSeq: seq,
  };
}

function toolActivityFromRecordContent(input: {
  record: AcpSessionRecord;
  messageIndex: number;
  contentIndex: number;
  toolUse: {
    id: string;
    name: string;
    raw_input: string;
    input: unknown;
    is_input_complete: boolean;
  };
  result?: {
    tool_use_id: string;
    tool_name: string;
    is_error: boolean;
    content: unknown;
    output?: unknown;
  };
  seq: number;
}): SessionActivity {
  const output = toolResultText(input.result?.content) ?? stringifyShort(input.result?.output);
  return {
    id: input.toolUse.id || `acpx-tool-${input.messageIndex}-${input.contentIndex}`,
    type: "tool",
    turnId: null,
    createdAt: millisFromIso(input.record.createdAt) + input.seq,
    seq: input.seq,
    status: input.result ? (input.result.is_error ? "failed" : "completed") : "in_progress",
    toolName: input.toolUse.name,
    title: input.toolUse.name,
    args: input.toolUse.input ?? safeJsonParse(input.toolUse.raw_input) ?? input.toolUse.raw_input,
    output: output ?? null,
    result: input.result?.output ?? input.result?.content ?? null,
    isError: input.result?.is_error ?? null,
    semantic: semanticFromTool(input.toolUse.name, input.toolUse.input),
  };
}

function runtimeSummaryFromRecord(record: AcpSessionRecord): SessionRuntimeSummary | null {
  const usage = record.cumulative_token_usage;
  const hasUsage = [
    usage.input_tokens,
    usage.output_tokens,
    usage.cache_creation_input_tokens,
    usage.cache_read_input_tokens,
  ].some((value) => typeof value === "number");
  return {
    model: record.acpx?.current_model_id,
    mode: record.acpx?.current_mode_id,
    telemetry: hasUsage
      ? {
          lastUsage: {
            inputTokens: usage.input_tokens,
            outputTokens: usage.output_tokens,
            cacheWriteTokens: usage.cache_creation_input_tokens,
            cacheReadTokens: usage.cache_read_input_tokens,
            updatedAt: recordUpdatedMillis(record),
          },
        }
      : undefined,
    updatedAt: recordUpdatedMillis(record),
  };
}

export function semanticFromTool(
  name: string,
  input: unknown,
  kind?: string,
): ToolActivitySemantic {
  const category = semanticCategory(kind, name);
  const action = semanticAction(kind, name);
  const targets = semanticTargets(input, kind);
  return { category, action, targets };
}

function semanticCategory(
  kind: string | undefined,
  name: string,
): ToolActivitySemanticCategory {
  const normalized = `${kind ?? ""} ${name}`.toLowerCase();
  if (kind === "execute" || /bash|shell|command|terminal/.test(normalized)) return "command";
  if (kind === "fetch" || /http|url|web|fetch/.test(normalized)) return "network";
  if (kind === "read" || kind === "edit" || kind === "delete" || kind === "move" || kind === "search") return "filesystem";
  if (/memory/.test(normalized)) return "memory";
  if (/task|todo/.test(normalized)) return "task";
  return "unknown";
}

function semanticAction(
  kind: string | undefined,
  name: string,
): ToolActivitySemanticAction {
  const normalized = `${kind ?? ""} ${name}`.toLowerCase();
  if (kind === "read" || /read|cat|open/.test(normalized)) return "read";
  if (kind === "edit" || /write|edit|patch/.test(normalized)) return "write";
  if (kind === "search" || /search|grep|find/.test(normalized)) return "search";
  if (kind === "fetch" || /fetch|http/.test(normalized)) return "fetch";
  if (kind === "execute" || /run|bash|shell|command/.test(normalized)) return "invoke";
  return "unknown";
}

function semanticTargets(
  input: unknown,
  kind?: string,
): ToolActivitySemanticTarget[] {
  const targets: ToolActivitySemanticTarget[] = [];
  const command = commandFromRawInput(input);
  if (kind === "execute" && command) {
    targets.push({ type: "command", command });
  }
  const path = stringProperty(input, ["path", "file", "filePath", "filepath", "target"]);
  if (path) {
    targets.push({
      type: "file",
      path,
      access: kind === "edit" || kind === "delete" || kind === "move" ? "write" : "read",
    });
  }
  const url = stringProperty(input, ["url", "uri"]);
  if (url) {
    targets.push({ type: "url", url });
  }
  const query = stringProperty(input, ["query", "pattern", "search"]);
  if (query) {
    targets.push({ type: "query", value: query });
  }
  if (targets.length === 0) {
    targets.push({ type: "unknown", label: stringifyShort(input) ?? "tool" });
  }
  return targets;
}

function commandFromRawInput(rawInput: unknown): string | undefined {
  if (typeof rawInput === "string" && rawInput.trim()) {
    return rawInput.trim();
  }
  if (!isRecord(rawInput)) {
    return undefined;
  }
  const command = stringProperty(rawInput, ["command", "cmd", "program"]);
  if (!command) {
    return undefined;
  }
  const args = rawInput.args;
  if (!Array.isArray(args) || args.length === 0) {
    return command;
  }
  return [command, ...args.map(String)].join(" ");
}

function recordPreview(record: AcpSessionRecord): string {
  return (
    record.title?.trim() ||
    record.name?.trim() ||
    firstUserText(record) ||
    lastAssistantText(record) ||
    `${record.agentCommand} session`
  );
}

function firstUserText(record: AcpSessionRecord): string | null {
  for (const message of record.messages) {
    if (typeof message !== "string" && "User" in message) {
      const text = userContentText(message.User.content).trim();
      if (text) return truncate(text, 160);
    }
  }
  return null;
}

function lastAssistantText(record: AcpSessionRecord): string | null {
  for (const message of [...record.messages].reverse()) {
    if (typeof message !== "string" && "Agent" in message) {
      const parts = message.Agent.content
        .map((content) => "Text" in content ? content.Text : "")
        .filter(Boolean);
      const text = parts.join("\n").trim();
      if (text) return truncate(text, 160);
    }
  }
  return null;
}

function userContentText(content: AcpxUserContent): string {
  return content
    .map((entry) => {
      if ("Text" in entry) return entry.Text;
      if ("Mention" in entry) return `${entry.Mention.uri}\n${entry.Mention.content}`;
      if ("Image" in entry) return `[image: ${entry.Image.source}]`;
      if ("Audio" in entry) {
        const mimeType = entry.Audio.mimeType ?? entry.Audio.mime_type;
        return mimeType ? `[audio: ${mimeType}]` : "[audio]";
      }
      return "";
    })
    .filter(Boolean)
    .join("\n\n");
}

function userContentBlocks(content: AcpxUserContent): SessionMessageContentBlock[] {
  const text = userContentText(content);
  return text ? [{ type: "text", text }] : [];
}

function userContentAttachments(content: AcpxUserContent): SessionMessageAttachment[] {
  return content
    .map((entry): SessionMessageAttachment | null => {
      if (!("Image" in entry)) return null;
      const source = entry.Image.source;
      return source.startsWith("http://") || source.startsWith("https://")
        ? { type: "image", url: source }
        : { type: "localImage", path: source };
    })
    .filter((entry): entry is SessionMessageAttachment => entry != null);
}

function toolResultText(content: unknown): string | null {
  if (!content) {
    return null;
  }
  if (typeof content === "object" && !Array.isArray(content)) {
    const record = content as Record<string, unknown>;
    if (typeof record.Text === "string") {
      return record.Text;
    }
    if (record.Image && typeof record.Image === "object") {
      return `[image: ${stringProperty(record.Image, ["source"]) ?? "image"}]`;
    }
  }
  return stringifyShort(content) ?? null;
}

function recordUpdatedIso(record: AcpSessionRecord): string {
  return record.updated_at || record.lastUsedAt || record.createdAt;
}

function recordUpdatedMillis(record: AcpSessionRecord): number {
  return millisFromIso(recordUpdatedIso(record));
}

function secondsFromIso(value: string): number {
  return Math.floor(millisFromIso(value) / 1000);
}

function millisFromIso(value: string): number {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Date.now();
}

function limitTail<T>(items: T[], limit: number | null): T[] {
  if (limit == null || limit < 0 || items.length <= limit) {
    return items;
  }
  return items.slice(items.length - limit);
}

function stringifyShort(value: unknown): string | undefined {
  if (value == null) {
    return undefined;
  }
  if (typeof value === "string") {
    return truncate(value, TOOL_OUTPUT_MAX_CHARS);
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  try {
    return truncate(JSON.stringify(value), TOOL_OUTPUT_MAX_CHARS);
  } catch {
    return String(value);
  }
}

function truncate(value: string, maxChars: number): string {
  return value.length > maxChars ? `${value.slice(0, maxChars - 1)}…` : value;
}

function stringProperty(value: unknown, keys: string[]): string | undefined {
  if (!isRecord(value)) {
    return undefined;
  }
  for (const key of keys) {
    const entry = value[key];
    if (typeof entry === "string" && entry.trim()) {
      return entry.trim();
    }
  }
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeJsonParse(value: string): unknown {
  try {
    return JSON.parse(value) as unknown;
  } catch {
    return undefined;
  }
}
