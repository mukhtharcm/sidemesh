import { buildActivityFromThreadItem, mergeActivity } from "./activity.js";
import type { AgentSessionLogOptions } from "./agent-provider.js";
import type { Thread, ThreadItem } from "./codex-protocol.js";
import { extractSessionAttachments } from "./session-attachments.js";
import type {
  SessionActivity, SessionLogSnapshot, SessionMessage, SessionMessageContentBlock,
} from "./types.js";

export function codexThreadHistory(
  thread: Thread,
  options: AgentSessionLogOptions = {},
): SessionLogSnapshot & { confirmedInputIds: string[] } {
  const messages: SessionMessage[] = [];
  const activities: SessionActivity[] = [];
  const confirmedInputIds: string[] = [];
  let seq = 0;
  for (const turn of thread.turns) {
    if (turn.itemsView && turn.itemsView !== "full") {
      throw new Error(`Codex returned incomplete history for turn ${turn.id}`);
    }
    const createdAt = (turn.startedAt ?? turn.completedAt ?? thread.createdAt) * 1000;
    let reasoning: SessionMessageContentBlock[] = [];
    let reasoningId: string | null = null;
    const message = (id: string, role: SessionMessage["role"], text: string,
      content: SessionMessageContentBlock[] = text ? [{ type: "text", text }] : [],
    ): SessionMessage => ({ id, role, text, content, attachments: [], createdAt, seq: seq++ });

    for (const item of turn.items) {
      if (item.type === "userMessage") {
        const text = item.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n");
        const entry = message(item.clientId ?? item.id, "user", text);
        entry.attachments = extractSessionAttachments(item.content);
        messages.push(entry);
        if (item.clientId) confirmedInputIds.push(item.clientId);
      } else if (item.type === "reasoning") {
        reasoningId ??= item.id;
        reasoning.push(...codexReasoningBlocks(item));
      } else if (item.type === "agentMessage" || item.type === "plan") {
        const content = [...reasoning];
        if (item.text) content.push({ type: "text", text: item.text });
        const entry = message(item.id, "assistant", item.text, content);
        entry.phase = item.type === "agentMessage" ? item.phase ?? undefined : "commentary";
        messages.push(entry);
        reasoning = [];
        reasoningId = null;
      } else if (item.type === "enteredReviewMode" || item.type === "exitedReviewMode") {
        messages.push(message(item.id, "system", item.review));
      } else {
        // Items with no status are complete in a completed native turn. During
        // execution their lifecycle comes from the live item notifications.
        const lifecycleStatus = "status" in item ? undefined
          : turn.status === "inProgress" ? "in_progress" : "completed";
        const context = { turnId: turn.id, createdAt, seq, lifecycleStatus } as const;
        let activity = buildActivityFromThreadItem(item, context);
        if (item.type === "imageView" || item.type === "sleep" || item.type === "subAgentActivity") {
          activity = {
            ...context, id: item.id, type: "tool", status: lifecycleStatus ?? "completed",
            toolName: item.type, title: item.type === "subAgentActivity" ? `Agent ${item.kind}` : null,
            args: item, output: null, result: null, isError: null, semantic: null,
            attachments: item.type === "imageView" ? [{ type: "localImage", path: item.path }] : [],
          };
        }
        if (activity) {
          activities.push(activity);
          seq += 1;
        }
      }
    }
    if (reasoning.length && reasoningId) {
      messages.push(message(reasoningId, "assistant", "", reasoning));
    }
    if (turn.error?.message) {
      messages.push(message(`${turn.id}:error`, "system", turn.error.message));
    }
  }
  return {
    messages: options.messageLimit && options.messageLimit > 0 ? messages.slice(-options.messageLimit) : messages,
    activities: options.activityLimit && options.activityLimit > 0 ? activities.slice(-options.activityLimit) : activities,
    runtime: { modelProvider: thread.modelProvider },
    totalMessages: messages.length, totalActivities: activities.length, nextSeq: seq,
    confirmedInputIds,
  };
}

export function codexReasoningBlocks(
  item: Extract<ThreadItem, { type: "reasoning" }>,
): SessionMessageContentBlock[] {
  return [
    ...item.summary.map((thinking) => ({ type: "thinking" as const, thinking, reasoningId: item.id, summary: true })),
    ...item.content.map((thinking) => ({ type: "thinking" as const, thinking, reasoningId: item.id, summary: false })),
  ];
}

export function supplementCodexLegacyHistory(
  native: SessionLogSnapshot,
  legacy: SessionLogSnapshot,
): SessionLogSnapshot {
  const visible = native.messages.filter((message) => message.role !== "system");
  const oldVisible = legacy.messages.filter((message) => message.role !== "system");
  // These are two views of the same native rollout. Use file positions only
  // after the entire visible sequence agrees. This does not deduplicate text
  // or import user/assistant messages; repeated prompts keep their native IDs.
  const sameSequence = visible.length === oldVisible.length && visible.every((message, index) => {
    const old = oldVisible[index]!;
    return message.role === old.role && message.text === old.text &&
      JSON.stringify(message.attachments) === JSON.stringify(old.attachments);
  });
  const positions = new Map(sameSequence ? visible.map((message, index) => [message.id, oldVisible[index]!]) : []);
  const messages = native.messages.map((message) => {
    const position = positions.get(message.id);
    return position ? { ...message, createdAt: position.createdAt, seq: position.seq } : { ...message };
  });
  for (const message of legacy.messages) {
    if (message.role === "system" && !messages.some((native) => native.id === message.id)) messages.push({ ...message });
  }
  const activities = new Map<string, SessionActivity>(legacy.activities
    .filter((activity) => activity.type === "command" || activity.type === "tool")
    .map((activity) => [activity.id, activity]));
  for (const activity of native.activities) {
    const previous = activities.get(activity.id);
    const merged = mergeActivity(previous, activity);
    activities.set(activity.id, sameSequence && previous ? merged : { ...merged, seq: activity.seq, createdAt: activity.createdAt });
  }
  const entries = [...messages, ...activities.values()];
  entries.sort(sameSequence ? (a, b) => a.seq - b.seq : (a, b) => a.createdAt - b.createdAt || a.seq - b.seq);
  entries.forEach((entry, seq) => { entry.seq = seq; });
  return {
    ...native, messages: messages.sort((a, b) => a.seq - b.seq), activities: [...activities.values()].sort((a, b) => a.seq - b.seq),
    totalMessages: messages.length, totalActivities: activities.size, nextSeq: entries.length,
  };
}
