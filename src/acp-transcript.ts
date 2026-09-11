import { randomUUID } from "node:crypto";
import type { ContentBlock, SessionUpdate } from "@agentclientprotocol/sdk";
import { materializeAgentActivityDraft, type AgentProviderLiveEvent } from "./agent-provider.js";
import { semanticFromTool } from "./acp-history.js";
import { extractSessionAttachments, mergeSessionAttachments } from "./session-attachments.js";
import type { StoredSessionItem } from "./session-store.js";
import type { SessionMessage, SessionMessageContentBlock, ToolActivity } from "./types.js";

/** One reducer for live notifications and staged history replay. The caller owns storage. */
export class AcpTranscript {
  private currentMessageId: string | null = null;
  private submittedUserId: string | null = null;
  private turnId: string | undefined;

  constructor(private readonly sessionId: string, private nextSeq: number,
    private readonly read: (id: string) => StoredSessionItem | null,
    private readonly write: (item: StoredSessionItem) => void,
    private readonly emit?: (event: AgentProviderLiveEvent) => void) {}

  beginTurn(turnId: string, message: Omit<SessionMessage, "seq">): void {
    this.finish();
    this.turnId = turnId;
    this.submittedUserId = message.id;
    this.write({ kind: "message", authority: "recovery", nativeId: null, value: { ...message, seq: this.nextSeq++ } });
  }

  update(update: SessionUpdate): void {
    switch (update.sessionUpdate) {
      case "user_message_chunk":
      case "agent_message_chunk":
      case "agent_thought_chunk": {
        const role = update.sessionUpdate === "user_message_chunk" ? "user" : "assistant";
        if (role === "user" && this.submittedUserId) {
          // The first user notification in this prompt is the agent's echo.
          // Bind its native ID to the submitted input; do not add the text twice.
          const submitted = this.read(this.submittedUserId);
          if (submitted && update.messageId) this.write({ ...submitted, nativeId: update.messageId });
          return;
        }
        this.submittedUserId = null;
        const current = this.currentMessageId ? this.read(this.currentMessageId) : null;
        const id = update.messageId ? `acp-message-${update.messageId}`
          : current?.kind === "message" && current.value.role === role ? current.value.id : `acp-message-${randomUUID()}`;
        if (id !== this.currentMessageId) this.finish("commentary");
        this.currentMessageId = id;
        const previous = this.read(id);
        const message: SessionMessage = previous?.kind === "message" ? previous.value : {
          id, role, text: "", content: [], attachments: [], createdAt: Date.now(), seq: this.nextSeq++,
        };
        const text = contentText(update.content);
        const thinking = update.sessionUpdate === "agent_thought_chunk";
        const content = appendBlock(message.content, thinking ? { type: "thinking", thinking: text }
          : { type: "text", text });
        const value = { ...message, text: thinking ? message.text : message.text + text,
          content, attachments: mergeSessionAttachments(message.attachments, extractSessionAttachments(update.content),
            update.content.type === "audio" ? [{ type: "file", url: `data:${update.content.mimeType};base64,${update.content.data}` }] : []) };
        this.write({ kind: "message", value, nativeId: update.messageId ?? previous?.nativeId ?? null, authority: "recovery" });
        if (role === "assistant" && text) this.emit?.(thinking ? {
          type: "reasoning_delta", sessionId: this.sessionId, turnId: this.turnId, itemId: id, reasoningId: id, delta: text, summary: false,
        } : { type: "assistant_delta", sessionId: this.sessionId, turnId: this.turnId, itemId: id, delta: text });
        return;
      }
      case "tool_call":
      case "tool_call_update": {
        this.submittedUserId = null;
        this.finish("commentary");
        const id = `acp-tool-${update.toolCallId}`;
        const saved = this.read(id);
        const previous = saved?.kind === "activity" && saved.value.type === "tool" ? saved.value : null;
        const title = update.title ?? previous?.title ?? update.name ?? "Tool";
        const args = update.rawInput ?? previous?.args ?? null;
        const result = update.rawOutput ?? update.content ?? previous?.result ?? null;
        const status = update.status === "completed" ? "completed" : update.status === "failed" ? "failed"
          : update.status ? "in_progress" : previous?.status ?? "in_progress";
        const value = materializeAgentActivityDraft({
          id, type: "tool", turnId: previous?.turnId ?? this.turnId ?? null, status,
          toolName: update.name ?? previous?.toolName ?? title, title, args,
          output: typeof result === "string" ? result : update.content?.flatMap((entry) =>
            entry.type === "content" && entry.content.type === "text" ? [entry.content.text] : []).join("\n") || previous?.output || null,
          result, isError: status === "failed", semantic: update.kind ? semanticFromTool(title, args, update.kind) : previous?.semantic ?? null,
          attachments: mergeSessionAttachments(previous?.attachments ?? [], extractSessionAttachments(result)),
        }, { seq: previous?.seq ?? this.nextSeq++, createdAt: previous?.createdAt ?? Date.now() }) as ToolActivity;
        this.write({ kind: "activity", value, nativeId: update.toolCallId, authority: "recovery" });
        this.emit?.({ type: "activity_updated", sessionId: this.sessionId, turnId: this.turnId, activity: value });
        return;
      }
      case "compaction_update": {
        this.finish("commentary");
        const id = `acp-compaction-${update.compactionId}`;
        const previous = this.read(id);
        const value = { id, type: "context_compaction" as const, turnId: this.turnId ?? null,
          status: update.status === "completed" ? "completed" as const : update.status === "failed" ? "failed" as const : "in_progress" as const,
          seq: previous?.value.seq ?? this.nextSeq++, createdAt: previous?.value.createdAt ?? Date.now() };
        this.write({ kind: "activity", value, nativeId: update.compactionId, authority: "recovery" });
        this.emit?.({ type: "activity_updated", sessionId: this.sessionId, turnId: this.turnId, activity: value });
        return;
      }
      case "compaction_summary_chunk":
        this.update({ sessionUpdate: "agent_thought_chunk", messageId: `compaction-${update.compactionId}`, content: update.content });
        return;
    }
  }

  finish(phase: SessionMessage["phase"] = "final_answer"): void {
    const current = this.currentMessageId ? this.read(this.currentMessageId) : null;
    this.currentMessageId = null;
    if (current?.kind !== "message" || current.value.role !== "assistant") return;
    const value = { ...current.value, phase };
    this.write({ ...current, value });
    this.emit?.({ type: "assistant_message_completed", sessionId: this.sessionId, turnId: this.turnId, message: value });
  }
}

function appendBlock(blocks: SessionMessageContentBlock[], block: SessionMessageContentBlock): SessionMessageContentBlock[] {
  if ((block.type === "text" ? block.text : block.thinking) === "") return blocks;
  const last = blocks.at(-1);
  if (last?.type === "text" && block.type === "text") return [...blocks.slice(0, -1), { ...last, text: last.text + block.text }];
  if (last?.type === "thinking" && block.type === "thinking") return [...blocks.slice(0, -1), { ...last, thinking: last.thinking + block.thinking }];
  return [...blocks, block];
}

function contentText(content: ContentBlock): string {
  switch (content.type) {
    case "text": return content.text;
    case "resource": return "text" in content.resource ? content.resource.text : `[Resource: ${content.resource.uri}]`;
    case "resource_link": return `${content.name} (${content.uri})`;
    case "audio": return `[Audio: ${content.mimeType}]`;
    case "image": return "";
  }
}
