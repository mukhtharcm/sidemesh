import { open, readFile, readdir, stat } from "node:fs/promises";
import nodePath from "node:path";
import type { AgentSessionEvent, SessionEntry, Skill as PiSkill } from "@earendil-works/pi-coding-agent";
import { materializeAgentActivityDraft, type AgentSessionActivityDraft, type AgentSessionInputItem } from "./agent-provider.js";
import { imageFromDataUrl, readLocalImage } from "./input-image.js";
import { extractSessionAttachments } from "./session-attachments.js";
import type { SessionMessage, SessionActivity, SessionRuntimeSummary, SessionMessageAttachment, SessionMessageContentBlock, SessionMessageContentBlockText, SessionActivityChange, ToolActivitySemantic, SkillSummary } from "./types.js";
import { textToBlocks } from "./types.js";

export type PiThinkingLevel = "off" | "minimal" | "low" | "medium" | "high" | "xhigh";

export interface PiImageInput {
  type: "image";
  data: string;
  mimeType: string;
}

export interface PiModelLike {
  id: string;
  name: string;
  provider: string;
  reasoning: boolean;
  input: string[];
  contextWindow?: number;
}

export interface PiSessionSummary {
  id: string;
  path: string;
  cwd: string;
  name: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
}

export interface PiPreparedInput {
  text: string;
  preview: string;
  attachments: SessionMessageAttachment[];
  images: PiImageInput[];
  warnings: string[];
}

export function runtimeFromAssistantMessage(
  existing: SessionRuntimeSummary | null,
  message: Record<string, unknown>,
  turnId: string | null,
): SessionRuntimeSummary {
  const provider = stringValue(message.provider);
  const model = stringValue(message.model);
  const usage = asRecord(message.usage);
  const next: SessionRuntimeSummary = {
    ...(existing ?? {}),
    updatedAt: numberValue(message.timestamp) ?? Date.now(),
    ...(provider && model
      ? {
          model: formatPiModelRef(provider, model),
          modelProvider: provider,
        }
      : {}),
  };
  next.telemetry = {
    ...(existing?.telemetry ?? {}),
    lastUsage: {
      model:
        provider && model ? formatPiModelRef(provider, model) : undefined,
      inputTokens: numberValue(usage?.input),
      outputTokens: numberValue(usage?.output),
      cacheReadTokens: numberValue(usage?.cacheRead),
      cacheWriteTokens: numberValue(usage?.cacheWrite),
      cost: numberValue(asRecord(usage?.cost)?.total),
      updatedAt: numberValue(message.timestamp) ?? Date.now(),
    },
  };
  return runtimeWithTurnId(next, turnId) ?? next;
}

export function runtimeWithTurnId(
  runtime: SessionRuntimeSummary | null,
  turnId: string | null,
): SessionRuntimeSummary | null {
  if (!runtime) {
    return null;
  }
  if (!turnId) {
    const { turnId: _turnId, ...rest } = runtime;
    return rest;
  }
  return {
    ...runtime,
    turnId,
  };
}

export function parsePiSessionHistory(
  entries: SessionEntry[],
  leafId: string | null,
  summary: PiSessionSummary,
): {
  messages: SessionMessage[];
  activities: SessionActivity[];
  sourceEntryIds: Map<string, string>;
  runtime: SessionRuntimeSummary | null;
  nextSeq: number;
  threadName: string | null;
  preview: string;
} {
  const branch = piBranch(entries, leafId);
  const messages: SessionMessage[] = [];
  const activities = new Map<string, SessionActivity>();
  const toolCalls = new Map<string, { toolName: string; args: unknown }>();
  const sourceEntryIds = new Map<string, string>();
  let runtime: SessionRuntimeSummary | null = null;
  let seq = 0;
  let threadName = summary.name;
  let preview = summary.preview;

  for (const entry of branch) {
    const messageTime = entry.type === "message" ? (entry.message as unknown as { timestamp?: unknown }).timestamp : undefined;
    const createdAt = typeof messageTime === "number" && Number.isFinite(messageTime)
      ? messageTime : entryTimestampMillis(entry.timestamp);
    if (entry.type === "session_info") {
      threadName = entry.name?.trim() || null;
      continue;
    }
    if (entry.type === "thinking_level_change") {
      runtime = {
        ...(runtime ?? {}),
        reasoningEffort: entry.thinkingLevel,
        updatedAt: createdAt,
      };
      continue;
    }
    if (entry.type === "model_change") {
      runtime = {
        ...(runtime ?? {}),
        model: formatPiModelRef(entry.provider, entry.modelId),
        modelProvider: entry.provider,
        updatedAt: createdAt,
      };
      continue;
    }
    if (entry.type === "compaction") {
      activities.set(entry.id, {
        id: entry.id,
        type: "context_compaction",
        turnId: null,
        createdAt,
        seq: seq++,
        status: "completed",
        summary: entry.summary,
      });
      runtime = {
        ...(runtime ?? {}),
        telemetry: {
          ...(runtime?.telemetry ?? {}),
          compaction: {
            ...(runtime?.telemetry?.compaction ?? {}),
            status: "completed",
            preCompactionTokens: entry.tokensBefore,
            completedAt: createdAt,
            updatedAt: createdAt,
          },
        },
        updatedAt: createdAt,
      };
      continue;
    }
    if (entry.type === "branch_summary") {
      const text = entry.summary.trim();
      if (text) {
        messages.push({
          id: entry.id,
          role: "system",
          text,
          content: [{ type: "text", text }],
          attachments: [],
          createdAt,
          seq: seq++,
        });
        preview = text;
      }
      continue;
    }
    if (entry.type === "custom_message") {
      if (entry.display) {
        const text = extractPiContentText(entry.content);
        const blocks = extractPiContentBlocks(entry.content);
        if (text) {
          messages.push({
            id: entry.id,
            role: "system",
            text,
            content: blocks.length > 0 ? blocks : [{ type: "text", text }],
            attachments: [],
            createdAt,
            seq: seq++,
          });
          preview = text;
        }
      }
      continue;
    }
    if (entry.type !== "message") {
      continue;
    }
    const message = entry.message as unknown as Record<string, unknown>;
    const role = stringValue(message.role);
    if (!role) {
      continue;
    }
    if (role === "user") {
      toolCalls.clear();
      const text = extractPiMessageText(message);
      const blocks = extractPiMessageContentBlocks(message);
      messages.push({
        id: entry.id,
        role: "user",
        text,
        content: blocks.length > 0 ? blocks : [{ type: "text", text }],
        attachments: extractSessionAttachments(message.content),
        createdAt,
        seq: seq++,
      });
      if (text) {
        preview = text;
      }
      continue;
    }
    if (role === "assistant") {
      for (const toolCall of extractPiToolCalls(message.content)) {
        toolCalls.set(toolCall.id, {
          toolName: toolCall.name,
          args: toolCall.arguments,
        });
      }
      const text = extractPiMessageText(message);
      const blocks = extractPiMessageContentBlocks(message);
      const errorMessage = stringValue(message.errorMessage);
      const attachments = extractSessionAttachments(message.content);
      if (text || errorMessage || blocks.length > 0 || attachments.length) {
        const derivedBlocks = blocks.length > 0
          ? blocks
          : [{ type: "text" as const, text: text || errorMessage || "" }];
        messages.push({
          id: entry.id,
          role: "assistant",
          text: text || errorMessage || "",
          content: derivedBlocks,
          attachments: extractSessionAttachments(message.content),
          createdAt,
          seq: seq++,
          phase: detectPiAssistantPhase(message) ?? "final_answer",
        });
        preview = text || errorMessage || preview;
      }
      runtime = runtimeFromAssistantMessage(runtime, message, null);
      continue;
    }
    if (role === "toolResult") {
      const toolCallId = stringValue(message.toolCallId);
      const resolved = toolCallId ? toolCalls.get(toolCallId) : null;
      if (toolCallId) {
        toolCalls.delete(toolCallId);
      }
      const toolName = stringValue(message.toolName) || resolved?.toolName || "tool";
      const args = resolved?.args ?? null;
      const activity = persistedPiToolResultActivity(
        toolName,
        toolCallId ?? entry.id,
        args,
        message,
        createdAt,
        seq++,
        summary.cwd,
      );
      activities.set(activity.id, activity);
      sourceEntryIds.set(activity.id, entry.id);
      const fileChange = fileChangeFromPiTool(
        toolName,
        args,
        message.details,
        activity,
      );
      if (fileChange) {
        sourceEntryIds.set(fileChange.id, entry.id);
        activities.set(
          fileChange.id,
          materializeAgentActivityDraft(fileChange, {
            createdAt,
            seq: seq++,
          }),
        );
      }
      continue;
    }
    if (role === "bashExecution") {
      activities.set(
        entry.id,
        bashExecutionToActivity(message, {
          turnId: null,
          createdAt,
          seq: seq++,
        }),
      );
      continue;
    }
    if (role === "custom" || role === "branchSummary" || role === "compactionSummary") {
      const text = customPiMessageText(message);
      if (text) {
        messages.push({
          id: entry.id,
          role: "system",
          text,
          content: textToBlocks(text),
          attachments: extractSessionAttachments(message.content),
          createdAt,
          seq: seq++,
        });
        preview = text;
      }
    }
  }

  return {
    messages,
    activities: [...activities.values()].sort((left, right) => left.seq - right.seq),
    sourceEntryIds,
    runtime,
    nextSeq: seq,
    threadName,
    preview,
  };
}

export function persistedPiToolResultActivity(
  toolName: string,
  toolCallId: string,
  args: unknown,
  message: Record<string, unknown>,
  createdAt: number,
  seq: number,
  cwd = "",
): SessionActivity {
  const output = extractPiContentText(message.content);
  const isError = booleanValue(message.isError) ?? false;
  if (toolName === "bash") {
    return {
      id: activityIdForToolCall(toolName, toolCallId),
      type: "command",
      turnId: null,
      createdAt,
      seq,
      status: isError ? "failed" : "completed",
      command: stringValue(asRecord(args)?.command) || "",
      cwd,
      output,
      exitCode: parseExitCode(output),
      durationMs: null,
      source: "tool",
      processId: null,
      commandActions: [],
      terminalStatus: null,
      terminalInput: null,
    };
  }
  return {
    id: activityIdForToolCall(toolName, toolCallId),
    type: "tool",
    turnId: null,
    createdAt,
    seq,
    status: isError ? "failed" : "completed",
    toolName,
    title: toolName,
    args,
    output,
    result: message.details ?? { content: message.content ?? null },
    attachments: extractSessionAttachments(message.content),
    isError,
    semantic: inferPiToolSemantic(toolName, args, message.details),
  };
}

export function toolExecutionStartDraft(
  event: Extract<AgentSessionEvent, { type: "tool_execution_start" }>,
  cwd: string,
  turnId: string | null,
): AgentSessionActivityDraft {
  if (event.toolName === "bash") {
    return {
      id: activityIdForToolCall(event.toolName, event.toolCallId),
      type: "command",
      turnId,
      status: "in_progress",
      command: stringValue(asRecord(event.args)?.command) || "",
      cwd,
      output: null,
      exitCode: null,
      durationMs: null,
      source: "tool",
      processId: null,
      commandActions: [],
      terminalStatus: null,
      terminalInput: null,
    };
  }
  return {
    id: activityIdForToolCall(event.toolName, event.toolCallId),
    type: "tool",
    turnId,
    status: "in_progress",
    toolName: event.toolName,
    title: event.toolName,
    args: event.args ?? null,
    output: null,
    result: null,
    isError: null,
    semantic: inferPiToolSemantic(event.toolName, event.args, null),
  };
}

export function fileChangeFromPiTool(
  toolName: string,
  args: unknown,
  details: unknown,
  parent: SessionActivity,
): AgentSessionActivityDraft | null {
  if (toolName !== "edit") {
    return null;
  }
  const typedArgs = asRecord(args);
  const typedDetails = asRecord(details);
  const path = stringValue(typedArgs?.path);
  const diff = stringValue(typedDetails?.diff);
  if (!path || !diff) {
    return null;
  }
  const changes: SessionActivityChange[] = [
    {
      path,
      kind: "update",
      diff,
    },
  ];
  return {
    id: `${parent.id}:file-change`,
    type: "file_change",
    turnId: parent.turnId,
    status: parent.status,
    changes,
  };
}

function inferPiToolSemantic(
  toolName: string,
  args: unknown,
  _result: unknown,
): ToolActivitySemantic {
  const typedArgs = asRecord(args);
  const path = stringValue(typedArgs?.path);
  const query = stringValue(typedArgs?.query) ?? stringValue(typedArgs?.pattern);
  switch (toolName) {
    case "read":
      return {
        category: "filesystem",
        action: "read",
        targets: path
          ? [{ type: "file", path, access: "read", role: "target" }]
          : [],
      };
    case "grep":
      return {
        category: "filesystem",
        action: "search",
        targets: [
          ...(query ? [{ type: "query", value: query } as const] : []),
          ...(path
            ? [{ type: "file", path, role: "target" } as const]
            : []),
        ],
      };
    case "find":
    case "ls":
      return {
        category: "filesystem",
        action: "list",
        targets: path
          ? [{ type: "file", path, role: "target" }]
          : [],
      };
    case "edit":
    case "write":
      return {
        category: "filesystem",
        action: "write",
        targets: path
          ? [{ type: "file", path, access: "write", role: "target" }]
          : [],
      };
    case "bash":
      return {
        category: "command",
        action: "invoke",
        targets: stringValue(typedArgs?.command)
          ? [{ type: "command", command: stringValue(typedArgs?.command)! }]
          : [],
      };
    default:
      return {
        category: "unknown",
        action: "invoke",
        targets: [],
      };
  }
}

function bashExecutionToActivity(
  message: Record<string, unknown>,
  context: { turnId: string | null; createdAt: number; seq: number },
): SessionActivity {
  const command = stringValue(message.command) || "";
  const output = stringValue(message.output) ?? null;
  const cancelled = booleanValue(message.cancelled) ?? false;
  const exitCode = numberValue(message.exitCode) ?? null;
  return {
    id: `pi-bash:${context.createdAt}:${context.seq}`,
    type: "command",
    turnId: context.turnId,
    createdAt: context.createdAt,
    seq: context.seq,
    status:
      cancelled || (typeof exitCode === "number" && exitCode !== 0)
        ? "failed"
        : "completed",
    command,
    cwd: "",
    output,
    exitCode,
    durationMs: null,
    source: "shell",
    processId: null,
    commandActions: [],
    terminalStatus: null,
    terminalInput: null,
  };
}

function entryTimestampMillis(value: string | undefined): number {
  const parsed = value ? Date.parse(value) : NaN;
  return Number.isFinite(parsed) ? parsed : Date.now();
}

export async function preparePiInput(
  input: AgentSessionInputItem[],
): Promise<PiPreparedInput> {
  const promptParts: string[] = [];
  const images: PiImageInput[] = [];
  const attachments: SessionMessageAttachment[] = [];
  const warnings: string[] = [];

  for (const item of input) {
    switch (item.type) {
      case "text":
        if (item.text.trim()) {
          promptParts.push(item.text.trim());
        }
        break;
      case "skill":
        promptParts.push(await inlinePiSkill(item.name, item.path));
        break;
      case "localImage": {
        const image = await readLocalImage(item.path);
        images.push(image);
        attachments.push({ type: "image", url: `data:${image.mimeType};base64,${image.data}` });
        break;
      }
      case "image": {
        const image = imageFromDataUrl(item.url);
        if (!image) throw new Error("Pi accepts local images or image data URLs");
        images.push(image);
        attachments.push({ type: "image", url: item.url });
        break;
      }
      case "file": {
        const fileContent = await inlinePiFile(item.path, item.isDirectory ?? false);
        if (fileContent) {
          promptParts.push(fileContent);
        }
        break;
      }
    }
  }

  const preview = previewFromInput(input);
  let text = promptParts.join("\n\n").trim();
  if (!text && images.length === 1) {
    text = "Please inspect the attached image.";
  } else if (!text && images.length > 1) {
    text = `Please inspect the ${images.length} attached images.`;

  }

  return {
    text,
    preview,
    attachments,
    images,
    warnings,
  };
}

async function inlinePiSkill(name: string, filePath: string): Promise<string> {
  const content = await readFile(filePath, "utf8");
  const body = stripFrontmatter(content).trim();
  const baseDir = nodePath.dirname(filePath);
  return `<skill name="${name}" location="${filePath}">\nReferences are relative to ${baseDir}.\n\n${body}\n</skill>`;
}

const FILE_CONTENT_CAP_BYTES = 100_000;

const DIRECTORY_LISTING_MAX_ENTRIES = 100;

async function inlinePiFile(filePath: string, isDirectory: boolean): Promise<string | null> {
  try {
    if (isDirectory) {
      const entries = await readdir(filePath, { withFileTypes: true });
      const lines = entries
        .slice(0, DIRECTORY_LISTING_MAX_ENTRIES)
        .map((e) => (e.isDirectory() ? `${e.name}/` : e.name));
      const truncated = entries.length > DIRECTORY_LISTING_MAX_ENTRIES;
      const suffix = truncated ? String.raw`
... (${entries.length - DIRECTORY_LISTING_MAX_ENTRIES} more entries)` : "";
      return `--- Directory: ${filePath} ---
${lines.join("\n")}${suffix}`;
    }

    const stats = await stat(filePath);
    const isBinaryFile = await checkBinaryFile(filePath);
    if (isBinaryFile) {
      return `--- File: ${filePath} ---
[binary file]`;
    }

    const handle = await open(filePath, "r");
    try {
      const buffer = Buffer.allocUnsafe(Math.min(stats.size, FILE_CONTENT_CAP_BYTES + 1));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      const text = buffer.subarray(0, bytesRead).toString("utf8");
      const truncated = stats.size > FILE_CONTENT_CAP_BYTES;
      const suffix = truncated ? String.raw`
... (truncated, ${stats.size} bytes total)` : "";
      return `--- File: ${filePath} ---
\`\`\`
${text}${suffix}
\`\`\``;
    } finally {
      await handle.close();
    }
  } catch {
    return `--- File: ${filePath} ---
[unable to read file]`;
  }
}

async function checkBinaryFile(filePath: string): Promise<boolean> {
  const handle = await open(filePath, "r");
  try {
    const buffer = Buffer.allocUnsafe(8192);
    const { bytesRead } = await handle.read(buffer, 0, 8192, 0);
    const sample = buffer.subarray(0, bytesRead);
    if (sample.length === 0) return false;
    for (let i = 0; i < sample.length; i++) {
      if (sample[i] === 0) return true;
    }
    return false;
  } finally {
    await handle.close();
  }
}

function previewFromInput(input: AgentSessionInputItem[]): string {
  const text = input
    .map((item) => {
      switch (item.type) {
        case "text":
          return item.text.trim();
        case "skill":
          return `/skill:${item.name.trim()}`;
        default:
          return "";
      }
    })
    .filter(Boolean)
    .join("\n")
    .trim();
  if (!text) {
    return input.some((item) => item.type === "localImage") ? "Image prompt" : "Pi session";
  }
  return summarizePreview(text);
}

function summarizePreview(text: string): string {
  return text.length > 80 ? `${text.slice(0, 77)}...` : text;
}

function extractPiToolCalls(
  content: unknown,
): Array<{ id: string; name: string; arguments: unknown }> {
  if (!Array.isArray(content)) {
    return [];
  }
  return content.flatMap((block) => {
    const typed = asRecord(block);
    if (!typed || typed.type !== "toolCall") {
      return [];
    }
    const id = stringValue(typed.id);
    const name = stringValue(typed.name);
    if (!id || !name) {
      return [];
    }
    return [{ id, name, arguments: typed.arguments ?? null }];
  });
}

export function extractPiMessageText(
  message: Record<string, unknown> | null | undefined,
): string {
  return extractPiContentText(message?.content);
}

function extractPiContentBlocks(
  content: unknown,
): SessionMessageContentBlock[] {
  if (typeof content === "string") {
    const text = content.trim();
    return text ? [{ type: "text", text }] : [];
  }
  if (!Array.isArray(content)) {
    return [];
  }
  const blocks: SessionMessageContentBlock[] = [];
  for (const block of content) {
    const typed = asRecord(block);
    if (!typed) continue;
    const blockType = stringValue(typed.type);
    if (blockType === "text") {
      const text = stringValue(typed.text);
      if (text) {
        blocks.push({ type: "text", text });
      }
    } else if (blockType === "thinking") {
      const thinking = stringValue(typed.thinking);
      if (thinking) {
        blocks.push({ type: "thinking", thinking });
      }
    }
  }
  return blocks;
}

export function extractPiMessageContentBlocks(
  message: Record<string, unknown> | null | undefined,
): SessionMessageContentBlock[] {
  return extractPiContentBlocks(message?.content);
}

export function extractPiContentText(content: unknown): string {
  const blocks = extractPiContentBlocks(content);
  return blocks
    .filter((b): b is SessionMessageContentBlockText => b.type === "text")
    .map((b) => b.text)
    .join("\n")
    .trim();
}

export function customPiMessageText(
  message: Record<string, unknown> | null | undefined,
): string | null {
  if (!message) {
    return null;
  }
  const role = stringValue(message.role);
  if (role === "branchSummary" || role === "compactionSummary") {
    return stringValue(message.summary) ?? null;
  }
  return extractPiMessageText(message) || null;
}

export function detectPiAssistantPhase(
  message: Record<string, unknown>,
): SessionMessage["phase"] | undefined {
  const content = Array.isArray(message.content) ? message.content : [];
  let detected: SessionMessage["phase"] | undefined;
  for (const block of content) {
    const typed = asRecord(block);
    if (!typed || typed.type !== "text") {
      continue;
    }
    const rawSignature = stringValue(typed.textSignature);
    if (!rawSignature) {
      continue;
    }
    try {
      const parsed = JSON.parse(rawSignature) as { phase?: unknown };
      if (parsed.phase === "commentary" || parsed.phase === "final_answer") {
        detected = parsed.phase;
      }
    } catch {
      // Ignore legacy non-JSON signatures.
    }
  }
  return detected;
}

export function extractPiPartialToolText(partialResult: unknown): string | null {
  if (typeof partialResult === "string") {
    return partialResult;
  }
  const typed = asRecord(partialResult);
  if (!typed) {
    return null;
  }
  const contentText = extractPiContentText(typed.content);
  if (contentText) {
    return contentText;
  }
  return stringValue(typed.text) ?? stringValue(typed.output) ?? null;
}

export function activityIdForToolCall(toolName: string, toolCallId: string): string {
  const prefix = toolName === "bash" ? "pi-command" : "pi-tool";
  return `${prefix}:${toolCallId}`;
}

export function formatPiModelRef(provider: string, modelId: string): string {
  return `${provider}/${modelId}`;
}

export function resolvePiModel<T extends PiModelLike>(
  models: T[],
  requested: string,
): T | null {
  const normalized = requested.trim();
  if (!normalized) {
    return null;
  }
  const typedModels = models.filter(isPiModelLike) as T[];
  if (normalized.includes("/")) {
    const [provider, ...rest] = normalized.split("/");
    const modelId = rest.join("/");
    return (
      typedModels.find(
        (model) => model.provider === provider && model.id === modelId,
      ) ?? null
    );
  }
  const exactMatches = typedModels.filter((model) => model.id === normalized);
  if (exactMatches.length === 1) {
    return exactMatches[0]!;
  }
  return null;
}

export function describePiModelLookupFailure(
  models: PiModelLike[],
  requested: string,
): string {
  const normalized = requested.trim();
  if (!normalized) {
    return "Pi model cannot be empty.";
  }
  if (normalized.includes("/")) {
    return `Unknown or unavailable Pi model "${requested}".`;
  }
  const exactMatches = models.filter((model) => model.id === normalized);
  if (exactMatches.length > 1) {
    return `Ambiguous Pi model "${requested}". Use one of: ${exactMatches
      .map((model) => formatPiModelRef(model.provider, model.id))
      .join(", ")}.`;
  }
  return `Unknown or unavailable Pi model "${requested}".`;
}

export function piSkillToSummary(
  skill: PiSkill,
  cwd: string,
  agentDir: string,
): SkillSummary {
  const userSkillRoot = nodePath.join(agentDir, "skills");
  const repoSkillRoot = nodePath.join(cwd, ".pi", "skills");
  const normalizedPath = nodePath.resolve(skill.filePath);
  const scope = normalizedPath.startsWith(nodePath.resolve(repoSkillRoot))
    ? "repo"
    : normalizedPath.startsWith(nodePath.resolve(userSkillRoot))
      ? "user"
      : "system";
  return {
    name: skill.name,
    description: skill.description,
    shortDescription: null,
    interface: null,
    path: normalizedPath,
    scope,
    enabled: true,
  };
}

function isPiModelLike(value: unknown): value is PiModelLike {
  const typed = asRecord(value);
  return (
    !!typed &&
    typeof typed.id === "string" &&
    typeof typed.name === "string" &&
    typeof typed.provider === "string" &&
    typeof typed.reasoning === "boolean" &&
    Array.isArray(typed.input)
  );
}

export function isPiThinkingLevel(value: unknown): value is PiThinkingLevel {
  return (
    value === "off" ||
    value === "minimal" ||
    value === "low" ||
    value === "medium" ||
    value === "high" ||
    value === "xhigh"
  );
}

function parseExitCode(output: string | null): number | null {
  if (!output) {
    return null;
  }
  const match = output.match(/Command exited with code (\d+)/);
  if (!match) {
    return null;
  }
  const parsed = Number.parseInt(match[1]!, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function stripFrontmatter(content: string): string {
  if (!content.startsWith("---\n")) {
    return content;
  }
  const end = content.indexOf("\n---\n", 4);
  if (end === -1) {
    return content;
  }
  return content.slice(end + 5);
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.trunc(value)
    : undefined;
}

function booleanValue(value: unknown): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

function asRecord(
  value: unknown,
): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

export function piBranch(entries: SessionEntry[], leafId: string | null): SessionEntry[] {
  const byId = new Map(entries.map((entry) => [entry.id, entry]));
  const branch: SessionEntry[] = [];
  const seen = new Set<string>();
  let id = leafId;
  while (id) {
    if (seen.has(id)) throw new Error("Pi history contains a cyclic branch");
    seen.add(id);
    const entry = byId.get(id);
    if (!entry) throw new Error("Pi history is missing a branch entry");
    branch.push(entry);
    id = entry.parentId;
  }
  return branch.reverse();
}
