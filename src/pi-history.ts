import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { normalizeStoredSessionActivity } from "./activity.js";
import { SessionStore, type StoredSessionItem } from "./session-store.js";
import { type PiSessionSummary } from "./pi-mapping.js";
import type { SessionActivity, SessionMessage, SessionRuntimeSummary } from "./types.js";

// This public SDK path is used only for native file discovery and cold history.
// Running sessions use RPC; importing another provider does not load the Pi SDK.
export const piSdk = () => import("@earendil-works/pi-coding-agent");

export async function listPiHistory(agentDir: string): Promise<PiSessionSummary[]> {
  const root = join(agentDir, "sessions");
  const directories = await readdir(root, { withFileTypes: true }).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return [];
    throw error;
  });
  const { SessionManager } = await piSdk();
  const summaries: PiSessionSummary[] = [];
  for (const directory of [root, ...directories.filter((entry) => entry.isDirectory()).map((entry) => join(root, entry.name))]) {
    for (const session of await SessionManager.listAll(directory)) {
      summaries.push({ id: session.id, path: session.path, cwd: session.cwd, name: session.name ?? null,
        preview: session.firstMessage || "Pi session", createdAt: session.created.getTime(), updatedAt: session.modified.getTime() });
    }
  }
  return summaries;
}

export async function readPiHistory(path: string | null, expectedId: string | null): Promise<{ entries: SessionEntry[]; leafId: string | null; name: string | null } | null> {
  if (!path) return null;
  let text: string;
  try { text = await readFile(path, "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return null; throw error; }
  // SessionManager.open repairs incomplete files and can rewrite migrations.
  // The host only reads native history; the Pi process owns all native writes.
  const { parseSessionEntries, migrateSessionEntries } = await piSdk();
  const file = parseSessionEntries(text);
  const header = file[0];
  if (!header || header.type !== "session" || !header.id || (expectedId && header.id !== expectedId)) {
    throw new Error("Pi history has an invalid or changed session identity");
  }
  migrateSessionEntries(file);
  const entries = file.filter((entry): entry is SessionEntry => entry.type !== "session");
  return { entries, leafId: entries.at(-1)?.id ?? null,
    name: entries.filter((entry) => entry.type === "session_info").at(-1)?.name ?? null };
}

const messageSchema = z.object({
  id: z.string().min(1), role: z.enum(["user", "assistant", "system"]), text: z.string(),
  content: z.array(z.union([z.object({ type: z.literal("text"), text: z.string() }),
    z.object({ type: z.literal("thinking"), thinking: z.string() })])).optional(),
  attachments: z.array(z.object({ type: z.enum(["image", "localImage", "file"]), url: z.string().optional(), path: z.string().optional() })).default([]),
  createdAt: z.number(), seq: z.number().int().nonnegative(), phase: z.enum(["commentary", "final_answer"]).optional(),
});
const activitySchema = z.object({
  id: z.string().min(1), type: z.enum(["command", "tool", "file_change", "turn_diff", "web_search", "image_generation", "context_compaction"]),
  seq: z.number().int().nonnegative(), createdAt: z.number(), turnId: z.string().nullable(), status: z.string(),
}).passthrough();
const legacySchema = z.object({
  archivedSessionIds: z.array(z.string()).default([]),
  sessions: z.array(z.object({
    thread: z.object({ id: z.string().min(1), cwd: z.string(), path: z.string().nullable(),
      name: z.string().nullable(), preview: z.string(), createdAt: z.number(), updatedAt: z.number() }),
    messages: z.array(messageSchema).default([]), activities: z.array(activitySchema).default([]),
    archived: z.boolean().optional(), runtime: z.record(z.string(), z.unknown()).nullable().optional(),
    draftAssistantMessage: z.object({ id: z.string(), text: z.string(), createdAt: z.number(),
      content: messageSchema.shape.content, phase: messageSchema.shape.phase }).nullable().optional(),
    preservedSidecarMessages: z.array(z.object({ message: messageSchema,
      previousUserMessage: messageSchema.nullable().optional() }).passthrough()).default([]),
    preservedSidecarUserMessages: z.array(z.object({ message: messageSchema }).passthrough()).default([]),
  })).default([]),
});

export async function importPiHistory(store: SessionStore, providerId: string, directory: string): Promise<void> {
  const migration = `pi-json-v1:${providerId}`;
  if (store.hasMigration(migration)) return;
  let raw: unknown;
  try { raw = JSON.parse(await readFile(join(directory, "sessions.json"), "utf8")); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; raw = {}; }
  const legacy = legacySchema.parse(raw);
  const sessions = legacy.sessions.map((saved) => {
    const items = new Map<string, StoredSessionItem>();
    const addMessage = (message: z.infer<typeof messageSchema>) => {
      const value: SessionMessage = { ...message, content: message.content ?? [{ type: "text", text: message.text }],
        ...(message.role === "assistant" ? { phase: message.phase ?? "final_answer" } : {}) };
      items.set(value.id, { kind: "message", value, nativeId: value.id, authority: "recovery" });
    };
    for (const message of saved.messages) addMessage(message);
    for (const record of saved.preservedSidecarMessages) {
      if (record.previousUserMessage && !items.has(record.previousUserMessage.id)) addMessage(record.previousUserMessage);
      if (!items.has(record.message.id)) addMessage(record.message);
    }
    for (const record of saved.preservedSidecarUserMessages) if (!items.has(record.message.id)) addMessage(record.message);
    for (const activity of saved.activities) items.set(activity.id, { kind: "activity", nativeId: activity.id,
      authority: "recovery", value: normalizeStoredSessionActivity(activity as SessionActivity) });
    const draft = saved.draftAssistantMessage;
    if (draft && (draft.text || draft.content?.length) && !items.has(draft.id)) addMessage({ ...draft,
      role: "assistant", attachments: [], seq: Math.max(-1, ...[...items.values()].map((item) => item.value.seq)) + 1 });
    return { session: { id: saved.thread.id, nativeId: saved.thread.id, cwd: saved.thread.cwd, name: saved.thread.name,
      preview: saved.thread.preview, createdAt: milliseconds(saved.thread.createdAt), updatedAt: milliseconds(saved.thread.updatedAt),
      archived: saved.archived === true || legacy.archivedSessionIds.includes(saved.thread.id),
      metadata: { nativePath: saved.thread.path, runtime: saved.runtime as SessionRuntimeSummary | null | undefined } },
      items: [...items.values()].sort((a, b) => a.value.seq - b.value.seq) };
  });
  // Legacy archives can contain IDs whose transcripts were never materialized.
  for (const id of legacy.archivedSessionIds) {
    if (sessions.some((saved) => saved.session.id === id)) continue;
    sessions.push({ session: { id, nativeId: id, cwd: "", name: null, preview: "Pi session", createdAt: 0, updatedAt: 0,
      archived: true, metadata: { nativePath: null, runtime: null } }, items: [] });
  }
  store.importProviderSessions(migration, providerId, sessions);
}

function milliseconds(value: number): number { return value < 1_000_000_000_000 ? value * 1000 : value; }
