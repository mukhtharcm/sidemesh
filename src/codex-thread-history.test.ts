import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { it } from "node:test";
import type { Thread, ThreadItem } from "./codex-protocol.js";
import { CodexAgentProvider } from "./codex-provider.js";
import { codexThreadHistory } from "./codex-thread-history.js";
import { loadRolloutLog } from "./codex-history.js";

function threadWith(items: ThreadItem[]): Thread {
  return {
    id: "native-thread", sessionId: "native-thread", extra: null, historyMode: "legacy",
    forkedFromId: null, parentThreadId: null, preview: "Repeat", ephemeral: false,
    modelProvider: "fixture", createdAt: 10, updatedAt: 20, recencyAt: null,
    status: { type: "idle" }, path: null, cwd: "/tmp", cliVersion: "0.144.6",
    source: "cli", threadSource: null, agentNickname: null, agentRole: null,
    gitInfo: null, name: null,
    turns: [{ id: "native-turn", status: "completed", itemsView: "full", error: null,
      startedAt: 10, completedAt: 20, durationMs: 10000, items }],
  };
}

it("normalizes official Codex items with native IDs, reasoning, images, plans, and errors", () => {
  const user = (id: string, clientId: string | null): ThreadItem => ({
    type: "userMessage", id, clientId, content: [
      { type: "text", text: "Repeat", text_elements: [] },
      { type: "image", url: "https://example.com/image.png" },
    ],
  });
  const thread = threadWith([
    user("native-user-1", "client-user-1"),
    { type: "reasoning", id: "reason-1", summary: ["Check"], content: ["Details"] },
    { type: "agentMessage", id: "answer-1", text: "First", phase: "commentary", memoryCitation: null },
    { type: "commandExecution", id: "command-1", command: "pwd", cwd: "/tmp", processId: null,
      source: "agent", status: "completed", commandActions: [], aggregatedOutput: "/tmp", exitCode: 0, durationMs: 5 },
    { type: "dynamicToolCall", id: "tool-1", namespace: null, tool: "screenshot", arguments: {},
      status: "completed", contentItems: [{ type: "inputImage", imageUrl: "data:image/png;base64,YQ==" }], success: true, durationMs: 5 },
    { type: "contextCompaction", id: "compact-1" },
    { type: "plan", id: "plan-1", text: "Plan text" },
    user("native-user-2", null),
    { type: "agentMessage", id: "answer-2", text: "Second", phase: "final_answer", memoryCitation: null },
    { type: "reasoning", id: "reason-2", summary: ["Unfinished"], content: [] },
  ]);
  thread.turns[0]!.status = "failed";
  thread.turns[0]!.error = { message: "Native failure", codexErrorInfo: null, additionalDetails: null };
  const log = codexThreadHistory(thread);
  assert.deepEqual(log.messages.map((item) => item.id), ["client-user-1", "answer-1", "plan-1", "native-user-2", "answer-2", "reason-2", "native-turn:error"]);
  assert.deepEqual(log.confirmedInputIds, ["client-user-1"]);
  assert.equal(log.messages.filter((item) => item.text === "Repeat").length, 2);
  assert.deepEqual(log.messages[1]?.content.map((item) => item.type), ["thinking", "thinking", "text"]);
  assert.equal(log.messages[4]?.content.length, 1);
  assert.equal(log.messages[0]?.attachments.length, 1);
  assert.equal(log.activities[0]?.status, "completed");
  const image = log.activities[1];
  assert.equal(image?.type, "tool");
  if (image?.type === "tool") {
    assert.equal(image.attachments?.length, 1);
    assert.equal(JSON.stringify(image.result).includes("YQ=="), false);
  }
  assert.equal(log.activities[2]?.status, "completed");
  const bounded = codexThreadHistory(thread, { messageLimit: 2, activityLimit: 1 });
  assert.deepEqual(bounded.messages, log.messages.slice(-2));
  assert.deepEqual(bounded.activities, log.activities.slice(-1));
  assert.equal(bounded.nextSeq, log.nextSeq);
  assert.equal(bounded.totalMessages, log.messages.length);
  thread.turns[0]!.itemsView = "summary";
  assert.throws(() => codexThreadHistory(thread), /incomplete history/);
});

it("uses isolated native Codex thread/read before and after resume without a model prompt", {
  skip: !process.env.SIDEMESH_TEST_CODEX_BIN, timeout: 60000,
}, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), "sidemesh-codex-native-"));
  const env = { CODEX_HOME: directory, OPENAI_API_KEY: "", CODEX_API_KEY: "" };
  const provider = new CodexAgentProvider(process.env.SIDEMESH_TEST_CODEX_BIN!, env);
  const id = randomUUID();
  const timestamp = "2026-09-10T12:00:00.000Z";
  const rollout = path.join(directory, "sessions", "2026", "09", "10", `rollout-2026-09-10T12-00-00-${id}.jsonl`);
  let ordinal = 0;
  const row = (type: string, payload: unknown) => JSON.stringify({ timestamp, ordinal: ordinal++, type, payload });
  const completed = (item: unknown) => row("event_msg", { type: "item_completed", thread_id: id, turn_id: "native-turn", item });
  try {
    const legacy = (await provider.getVersion()).includes("0.144.");
    await mkdir(path.dirname(rollout), { recursive: true });
    await writeFile(path.join(directory, "config.toml"), 'model = "fixture"\nmodel_provider = "fixture"\n[model_providers.fixture]\nname = "Fixture"\nbase_url = "http://127.0.0.1:1/v1"\nwire_api = "responses"\n');
    await writeFile(rollout, [
      row("session_meta", { id, session_id: id, timestamp, cwd: directory, originator: "sidemesh-test",
        cli_version: "0.144.6", source: "cli", model_provider: "fixture", history_mode: legacy ? "legacy" : "paginated" }),
      row("event_msg", { type: "task_started", turn_id: "native-turn", model_context_window: 1000 }),
      legacy
        ? row("event_msg", { type: "user_message", message: "Saved fixture", client_id: "client-user", local_images: [] })
        : completed({ type: "UserMessage", id: "native-user", client_id: "client-user",
          content: [{ type: "text", text: "Saved fixture", text_elements: [] }] }),
      ...(legacy ? [
        row("response_item", { type: "function_call", name: "exec_command", call_id: "command-1", arguments: JSON.stringify({ cmd: "pwd", workdir: directory }) }),
        row("response_item", { type: "function_call_output", call_id: "command-1", output: "Process exited with code 0\nOutput:\nfixture output\n" }),
      ] : []),
      legacy
        ? row("event_msg", { type: "agent_message", message: "Saved reply" })
        : completed({ type: "AgentMessage", id: "native-answer", phase: "final_answer", content: [{ type: "Text", text: "Saved reply" }] }),
      row("event_msg", { type: "task_complete", turn_id: "native-turn", last_agent_message: "Saved reply" }),
    ].join("\n") + "\n");
    await provider.start();
    // Build the native projection from the seeded canonical JSONL. No native
    // database tables are written by this test or by the adapter.
    if (!legacy) await provider.resumeSessionThread(id, { persistExtendedHistory: true });
    const snapshot = await provider.readSessionSnapshot(id);
    assert.equal(snapshot.thread.id, id);
    assert.equal(snapshot.activeTurnId, null);
    assert.deepEqual(snapshot.messages.map((message) => message.text), ["Saved fixture", "Saved reply"]);
    assert.deepEqual(snapshot.confirmedInputIds, ["client-user"]);
    if (legacy) {
      assert.equal(snapshot.activities[0]?.type, "command");
      assert.equal(snapshot.activities[0]?.status, "completed");
      assert.equal(snapshot.activities[0]?.seq, 1);
      assert.equal(snapshot.messages[1]?.seq, 2);
    }
    const old = await loadRolloutLog(id, rollout, directory);
    assert.deepEqual(snapshot.messages.map((message) => message.text), old.messages.map((message) => message.text));
    await provider.resumeSessionThread(id, { persistExtendedHistory: true });
    const resumed = await provider.readSessionSnapshot(id);
    assert.deepEqual(resumed.messages.map((message) => message.id), snapshot.messages.map((message) => message.id));
    await provider.close();
    await provider.start();
    const restarted = await provider.readSessionSnapshot(id);
    assert.deepEqual(restarted.messages.map((message) => message.text), snapshot.messages.map((message) => message.text));
  } finally {
    await provider.close();
    await rm(directory, { recursive: true, force: true });
  }
});
