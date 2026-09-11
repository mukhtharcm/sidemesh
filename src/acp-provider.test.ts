import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { agent, methods, PROTOCOL_VERSION, RequestError,
  type ContentBlock, type SessionUpdate, type SessionConfigOption, type ClientApp, type SessionInfo } from "@agentclientprotocol/sdk";
import { AcpAgentProvider } from "./acp-provider.js";
import { AgentProviderRequestError, type AgentPendingAction, type AgentProviderLiveEvent } from "./agent-provider.js";
import { SessionStore } from "./session-store.js";

const overrides = { model: null, mode: null, reasoningEffort: null, fastMode: null, approvalPolicy: null,
  sandboxMode: null, networkAccess: null, webSearch: null, profile: null };
const textInput = (text: string) => [{ type: "text" as const, text, text_elements: [] }];
const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";

function harness() {
  let counter = 0;
  const history = new Map<string, SessionUpdate[]>();
  const sessions: SessionInfo[] = [];
  const controls: SessionConfigOption[] = [
    { id: "model", type: "select", name: "Model", category: "model", currentValue: "first",
      options: [{ value: "first", name: "First" }, { value: "second", name: "Second" }, { value: "broken", name: "Unavailable" }] },
    { id: "auto", type: "boolean", name: "Automatic", currentValue: false },
  ];
  const result = { history, sessions, connects: 0, prompts: [] as string[], promptBlocks: [] as ContentBlock[][], images: false, loadFails: false, loadCalls: 0,
    onPrompt: null as (() => void) | null, deleteSupported: true, deleteFails: false, deleted: [] as string[],
    requireAuth: false, authenticated: "", loadSupported: true, closed: 0, configurationRequests: [] as unknown[],
    connect: async (app: ClientApp, cwd: string) => {
      result.connects++;
      const held = new Map<string, () => void>();
      const server = agent()
        .onRequest(methods.agent.initialize, () => ({ protocolVersion: PROTOCOL_VERSION,
          agentInfo: { name: "wire-fixture", version: "1" },
          agentCapabilities: { loadSession: result.loadSupported, promptCapabilities: { image: result.images }, sessionCapabilities: {
            list: {}, resume: {}, close: {}, ...(result.deleteSupported ? { delete: {} } : {}),
          } },
          authMethods: [{ id: "first", name: "First account" }, { id: "second", name: "Second account" }],
        }))
        .onRequest(methods.agent.authenticate, ({ params }) => { result.authenticated = params.methodId; return {}; })
        .onRequest(methods.agent.session.new, () => {
          if (result.requireAuth && !result.authenticated) throw RequestError.authRequired();
          const sessionId = `native-${++counter}`;
          history.set(sessionId, []);
          sessions.push({ sessionId, cwd, title: "Fixture session" });
          return { sessionId, configOptions: controls, modes: {
            currentModeId: "code", availableModes: [{ id: "code", name: "Code" }, { id: "plan", name: "Plan" }],
          } };
        })
        .onRequest(methods.agent.session.load, async ({ params, client }) => {
          result.loadCalls++;
          for (const [index, update] of (history.get(params.sessionId) ?? []).entries()) {
            await client.notify(methods.client.session.update, { sessionId: params.sessionId, update });
            if (result.loadFails && index === 0) throw RequestError.internalError(undefined, "Replay interrupted");
          }
          return { configOptions: controls };
        })
        .onRequest(methods.agent.session.resume, ({ params }) => ({ sessionId: params.sessionId, configOptions: controls }))
        .onRequest(methods.agent.session.list, ({ params }) => ({
          sessions: params.cursor ? sessions.slice(1) : sessions.slice(0, 1),
          nextCursor: !params.cursor && sessions.length > 1 ? "page-2" : undefined,
        }))
        .onRequest(methods.agent.session.setConfigOption, ({ params }) => {
          result.configurationRequests.push(params);
          if (params.value === "broken") throw RequestError.invalidParams(undefined, "Model unavailable");
          const option = controls.find((option) => option.id === params.configId)!;
          if (option.type === "boolean") { assert.equal("type" in params && params.type, "boolean"); option.currentValue = Boolean(params.value); }
          else option.currentValue = String(params.value);
          return { configOptions: controls };
        })
        .onRequest(methods.agent.session.setMode, () => ({}))
        .onRequest(methods.agent.session.close, () => { result.closed++; return {}; })
        .onRequest(methods.agent.session.delete, ({ params }) => {
          if (result.deleteFails) throw RequestError.internalError(undefined, "Deletion failed");
          result.deleted.push(params.sessionId);
          history.delete(params.sessionId);
          const index = sessions.findIndex((session) => session.sessionId === params.sessionId);
          if (index >= 0) sessions.splice(index, 1);
          return {};
        })
        .onNotification(methods.agent.session.cancel, ({ params }) => held.get(params.sessionId)?.())
        .onRequest(methods.agent.session.prompt, async ({ params, client, signal }) => {
          const text = params.prompt.flatMap((block) => block.type === "text" ? [block.text] : []).join("");
          result.prompts.push(text);
          result.promptBlocks.push(params.prompt);
          result.onPrompt?.();
          const index = result.prompts.length;
          const send = async (update: SessionUpdate) => {
            history.get(params.sessionId)!.push(update);
            await client.notify(methods.client.session.update, { sessionId: params.sessionId, update });
          };
          for (const content of params.prompt) await send({ sessionUpdate: "user_message_chunk", messageId: `user-${index}`, content });
          if (text === "hold") {
            await new Promise<void>((resolve) => {
              held.set(params.sessionId, resolve);
              signal.addEventListener("abort", () => resolve(), { once: true });
            });
            held.delete(params.sessionId);
            return { stopReason: "cancelled" };
          }
          await send({ sessionUpdate: "tool_call", toolCallId: `tool-${index}`, title: "Read file", kind: "read", rawInput: { path: "README.md" }, status: "in_progress" });
          await send({ sessionUpdate: "tool_call_update", toolCallId: `tool-${index}`, status: "completed", content: [
            { type: "content", content: { type: "image", data: png, mimeType: "image/png" } },
          ] });
          await send({ sessionUpdate: "agent_thought_chunk", messageId: `answer-${index}`, content: { type: "text", text: "Check the result." } });
          await send({ sessionUpdate: "agent_message_chunk", messageId: `answer-${index}`, content: { type: "text", text: `Reply to ${text}` } });
          await send({ sessionUpdate: "agent_message_chunk", messageId: `answer-${index}`, content: { type: "image", data: png, mimeType: "image/png" } });
          await send({ sessionUpdate: "plan", entries: [{ content: "Read the file", priority: "medium", status: "completed" }] });
          await send({ sessionUpdate: "available_commands_update", availableCommands: [{ name: "help", description: "Show help", input: { hint: "topic" } }] });
          return { stopReason: "end_turn" };
        });
      const connection = app.connect(server);
      return { connection, close: async () => { connection.close(); } };
    },
  };
  return result;
}

function completion(provider: AcpAgentProvider): Promise<Extract<AgentProviderLiveEvent, { type: "turn_completed" }>> {
  return new Promise((resolve) => {
    const listener = (event: AgentProviderLiveEvent) => {
      if (event.type !== "turn_completed") return;
      provider.off("liveEvent", listener);
      resolve(event);
    };
    provider.on("liveEvent", listener);
  });
}

describe("AcpAgentProvider", () => {
  let directory: string;
  let store: SessionStore;
  let wire: ReturnType<typeof harness>;
  let provider: AcpAgentProvider;
  let events: AgentProviderLiveEvent[];
  const createProvider = (id = "acpx") => new AcpAgentProvider({ agent: "fixture", command: "fixture-new-command", providerId: id,
    stateDir: join(directory, "legacy"), cwd: directory }, { sessionStore: store, connect: wire.connect });
  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), "sidemesh-acp-provider-"));
    store = await SessionStore.open(directory);
    wire = harness();
    provider = createProvider();
    events = [];
    provider.on("liveEvent", (event) => events.push(event));
    await provider.start();
  });
  afterEach(async () => { await provider.close(); store.close(); await rm(directory, { recursive: true, force: true }); });

  it("keeps archive separate from native deletion and deletes without loading history", async () => {
    const done = completion(provider);
    const created = await provider.createSession({ cwd: directory, input: textInput("saved"), overrides });
    await done;
    assert.equal(provider.capabilities.sessions.delete, true);
    const nativeId = store.getProviderSession("acpx", created.thread.id)!.nativeId;
    await provider.archiveSession(created.thread.id);
    assert.deepEqual(wire.deleted, []);
    await provider.close();
    provider = createProvider();
    await provider.start();
    assert.equal(provider.capabilities.sessions.delete, true);
    wire.loadFails = true;
    const loads = wire.loadCalls;
    await provider.deleteSession(created.thread.id);
    assert.equal(wire.loadCalls, loads);
    assert.deepEqual(wire.deleted, [nativeId]);
    assert.equal(store.getProviderSession("acpx", created.thread.id), null);
    assert.deepEqual(store.readSessionItems("acpx", created.thread.id), []);
    assert.deepEqual(await provider.listLoadedSessionIds(), []);
    await assert.rejects(provider.readSessionThread(created.thread.id, false), /not found/);
  });

  it("keeps history when deletion is unsupported or fails", async () => {
    wire.deleteSupported = false;
    const created = await provider.createSession({ cwd: directory, input: [], overrides });
    await assert.rejects(provider.deleteSession(created.thread.id), /does not support/);
    assert.ok(store.getProviderSession("acpx", created.thread.id));
    wire.deleteSupported = true;
    wire.deleteFails = true;
    await assert.rejects(provider.deleteSession(created.thread.id), /Deletion failed/);
    assert.ok(store.getProviderSession("acpx", created.thread.id));
    assert.deepEqual(wire.deleted, []);
    assert.deepEqual(await provider.listLoadedSessionIds(), []);
    store.saveProviderSession("acpx", { id: "local-only", nativeId: null, cwd: directory, name: null,
      preview: "Failed before creation", createdAt: 1, updatedAt: 1, archived: false, metadata: {} });
    const connects = wire.connects;
    await provider.deleteSession("local-only");
    assert.equal(wire.connects, connects);
    assert.equal(store.getProviderSession("acpx", "local-only"), null);
  });

  it("negotiates image input and sends ACP image and resource blocks", async () => {
    assert.equal(provider.capabilities.input.imageUrl, false);
    wire.images = true;
    const local = join(directory, "image.png");
    await writeFile(local, Buffer.from(png, "base64"));
    const done = completion(provider);
    const created = await provider.createSession({ cwd: directory, input: [
      { type: "image", url: `data:image/png;base64,${png}` },
      { type: "localImage", path: local }, { type: "file", path: join(directory, "a #b.txt") },
    ], overrides });
    await done;
    assert.equal(provider.capabilities.input.imageUrl, true);
    assert.equal(provider.capabilities.input.localImage, true);
    assert.deepEqual(wire.promptBlocks[0]!.slice(0, 2), [0, 1].map(() => ({ type: "image", data: png, mimeType: "image/png" })));
    assert.equal(wire.promptBlocks[0]![2]!.type, "resource_link");
    assert.match(JSON.stringify(wire.promptBlocks[0]![2]), /a%20%23b.txt/);
    const log = await provider.readSessionLog(created.thread);
    assert.ok(log.messages.find((message) => message.role === "user")?.attachments.some((item) => item.url === `data:image/png;base64,${png}`));
    await provider.close();
    provider = createProvider();
    await provider.start();
    assert.equal(provider.capabilities.input.imageUrl, true);
    assert.equal(await provider.getVersion(), "wire-fixture 1 (ACP 1)");
    const changed = new AcpAgentProvider({ agent: "fixture", command: "different-agent-command", cwd: directory }, { sessionStore: store, connect: wire.connect });
    await changed.start();
    assert.equal(changed.capabilities.input.imageUrl, false);
    assert.equal(await changed.getVersion(), "ACP 1");
    await changed.close();
  });

  it("rejects unsupported and invalid images before sending a prompt", async () => {
    const created = await provider.createSession({ cwd: directory, input: [], overrides });
    await assert.rejects(provider.submitInput({ sessionId: created.thread.id, input: [{ type: "image", url: `data:image/png;base64,${png}` }], overrides, activeTurnId: null }), /does not support image/);
    wire.images = true;
    const imageSession = await provider.createSession({ cwd: directory, input: [], overrides });
    for (const url of ["https://example.com/image.png", "data:image/png;base64,abc"]) {
      await assert.rejects(provider.submitInput({ sessionId: imageSession.thread.id, input: [{ type: "image", url }], overrides, activeTurnId: null }), /local images or image data URLs/);
    }
    assert.equal(wire.prompts.length, 0);
  });

  it("uses SDK sessions, preserves partial tool updates and images, and commits complete replay", async () => {
    const done = completion(provider);
    const created = await provider.createSession({ cwd: directory, input: textInput("hello"), overrides });
    assert.equal((await done).status, "completed");
    assert.ok(events.some((event) => event.type === "assistant_delta"));
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.length, 2);
    assert.equal(log.activities.length, 1);
    assert.equal(log.messages[1]!.text, "Reply to hello");
    assert.equal(log.messages[1]!.content[0]!.type, "thinking");
    assert.equal(log.messages[1]!.attachments.length, 1);
    const tool = log.activities[0]!;
    assert.equal(tool.type, "tool");
    if (tool.type === "tool") {
      assert.equal(tool.title, "Read file");
      assert.deepEqual(tool.args, { path: "README.md" });
      assert.equal(tool.attachments?.length, 1);
      assert.equal(JSON.stringify(tool.result).includes(png), false);
      assert.equal(tool.output?.includes(png) ?? false, false);
    }
    assert.equal(log.runtime?.commands?.[0]?.name, "help");
    assert.equal(log.latestPlanUpdate?.plan[0]?.status, "completed");
    assert.equal(log.latestPlanUpdate?.plan[0]?.priority, "medium");
    assert.ok(store.readSessionItems("acpx", created.thread.id).every((item) => item.authority === "cache"));
    assert.equal((await provider.getVersion()), "wire-fixture 1 (ACP 1)");
    const replay = await provider.readSessionLog(created.thread);
    assert.deepEqual(replay.messages, log.messages);
  });

  it("does not replace saved history when a replay fails and keeps repeated prompts distinct", async () => {
    let done = completion(provider);
    const created = await provider.createSession({ cwd: directory, input: textInput("repeat"), overrides });
    await done;
    done = completion(provider);
    await provider.submitInput({ sessionId: created.thread.id, input: textInput("repeat"), activeTurnId: null, overrides, clientMessageId: "client-repeat-2" });
    await done;
    assert.ok(events.some((event) => event.type === "input_confirmed" && event.clientInputId === "client-repeat-2"));
    const snapshot = await provider.readSessionSnapshot(created.thread.id);
    assert.equal(snapshot.busy, false);
    assert.equal(snapshot.activeTurnId, null);
    const saved = store.readSessionItems("acpx", created.thread.id);
    wire.loadFails = true;
    await assert.rejects(provider.readSessionLog(created.thread), /Replay interrupted/);
    assert.deepEqual(store.readSessionItems("acpx", created.thread.id), saved);
    wire.loadFails = false;
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.filter((message) => message.role === "user").length, 2);
    assert.ok(log.messages.some((message) => message.id === "client-repeat-2"));
    assert.equal(log.messages.length, 4);
  });

  it("keeps local output omitted by a native replay", async () => {
    const done = completion(provider);
    const created = await provider.createSession({ cwd: directory, input: textInput("keep output"), overrides });
    await done;
    const nativeId = store.getProviderSession("acpx", created.thread.id)!.nativeId!;
    wire.history.set(nativeId, wire.history.get(nativeId)!.slice(0, 1));
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)!.text, "Reply to keep output");
    assert.equal(log.activities.length, 1);
    assert.ok(events.some((event) => event.type === "provider_warning" && event.code === "acp_history_unconfirmed"));
  });

  it("applies exact configuration values and stops before prompt dispatch when a control fails", async () => {
    const created = await provider.createSession({ cwd: directory, input: [], overrides: { ...overrides, model: "second" } });
    assert.equal(created.runtime?.model, "second");
    await provider.setSessionConfiguration(created.thread.id, "auto", true);
    assert.deepEqual(wire.configurationRequests.at(-1), { sessionId: "native-1", configId: "auto", type: "boolean", value: true });
    assert.equal((await provider.setSessionConfiguration(created.thread.id, "acp:mode", "plan"))?.mode, "plan");
    await assert.rejects(provider.submitInput({ sessionId: created.thread.id, input: textInput("must not run"), activeTurnId: null,
      overrides: { ...overrides, model: "broken" } }), (error: unknown) => error instanceof AgentProviderRequestError && error.inputNotDispatched);
    assert.equal(wire.prompts.length, 0);
  });

  it("cancels active work and rejects new dispatch during close without archiving history", async () => {
    const done = completion(provider);
    const accepted = new Promise<void>((resolve) => { wire.onPrompt = resolve; });
    const created = await provider.createSession({ cwd: directory, input: textInput("hold"), overrides });
    await accepted;
    await provider.close();
    assert.equal((await done).status, "interrupted");
    await assert.rejects(provider.submitInput({ sessionId: created.thread.id, input: textInput("later"), activeTurnId: null, overrides }));
    assert.equal(wire.prompts.length, 1);
    assert.equal(store.getProviderSession("acpx", created.thread.id)!.archived, false);
    provider = createProvider();
    await provider.start();
    assert.equal((await provider.listSessionThreads({ limit: 10, archived: false }))[0]!.id, created.thread.id);
    assert.equal(wire.connects, 1);
  });

  it("selects an explicit authentication method through the app", async () => {
    wire.requireAuth = true;
    const pending = new Promise<AgentPendingAction>((resolve) => provider.on("liveEvent", (event) => {
      if (event.type === "action_opened") resolve(event.action);
    }));
    const created = provider.createSession({ cwd: directory, input: [], overrides });
    const action = await pending;
    assert.equal(provider.respondToPendingAction(action, { answer: "invented", wasFreeform: false }), false);
    assert.equal(provider.respondToPendingAction(action, { answer: "Second account (second)", wasFreeform: false }), true);
    await created;
    assert.equal(wire.authenticated, "second");
  });

  it("discovers native sessions through pagination and keeps resume distinct from replay", async () => {
    wire.loadSupported = false;
    const done = completion(provider);
    const created = await provider.createSession({ cwd: directory, input: textInput("saved"), overrides });
    await done;
    wire.sessions.push({ sessionId: "external", cwd: directory, title: "External session" });
    wire.history.set("external", []);
    assert.equal((await provider.listSessionThreads({ limit: 10, archived: false })).length, 2);
    await provider.close();
    provider = createProvider();
    await provider.start();
    await provider.resumeSessionThread(created.thread.id);
    const log = await provider.readSessionLog(created.thread);
    assert.equal(log.messages.at(-1)!.text, "Reply to saved");
    assert.equal(wire.loadCalls, 0);
  });
});

it("imports old ACPx records once, keeps their IDs after a command change, and preserves source files", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sidemesh-acp-import-"));
  const legacy = join(directory, "legacy");
  await mkdir(join(legacy, "sessions"), { recursive: true });
  const now = new Date().toISOString();
  const source = JSON.stringify({ schema: "acpx.session.v1", acpxRecordId: "legacy-id", acpSessionId: "old-native-id",
    agentCommand: "old-agent-command", cwd: directory, title: "Old session", createdAt: now, updated_at: now, lastUsedAt: now,
    messages: [{ User: { id: "old-user-id", content: [{ Text: "Keep this" }] } },
      { Agent: { content: [{ Text: "Old answer" }], tool_results: {} } }], cumulative_token_usage: {},
  });
  const sourcePath = join(legacy, "sessions", "legacy-id.json");
  await writeFile(sourcePath, source);
  const store = await SessionStore.open(directory);
  let connects = 0;
  const create = () => new AcpAgentProvider({ agent: "custom", command: "changed-command", stateDir: legacy }, {
    sessionStore: store, connect: async () => { connects++; throw new Error("Must not launch for local history"); },
  });
  let provider = create();
  try {
    await provider.start();
    const thread = (await provider.listSessionThreads({ limit: 10, archived: false }))[0]!;
    assert.equal(thread.id, "legacy-id");
    assert.equal((await provider.readSessionLog(thread)).messages.at(-1)!.text, "Old answer");
    await provider.archiveSession(thread.id);
    await provider.close();
    provider = create();
    await provider.start();
    assert.equal((await provider.listSessionThreads({ limit: 10, archived: true })).length, 1);
    assert.equal((await provider.listSessionThreads({ limit: 10, archived: false })).length, 0);
    assert.equal(await readFile(sourcePath, "utf8"), source);
    assert.equal(connects, 0);
  } finally { await provider.close(); store.close(); await rm(directory, { recursive: true, force: true }); }
});

it("isolates the same native session ID in two instances sharing one database", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sidemesh-acp-instances-"));
  const store = await SessionStore.open(directory);
  const firstWire = harness();
  const secondWire = harness();
  const providers = [firstWire, secondWire].map((wire, index) => new AcpAgentProvider({
    agent: "fixture", providerId: `instance-${index}`, stateDir: directory,
  }, { sessionStore: store, connect: wire.connect }));
  try {
    const results = [];
    for (const [index, provider] of providers.entries()) {
      await provider.start();
      const done = completion(provider);
      results.push(await provider.createSession({ cwd: directory, input: textInput(`instance ${index}`), overrides }));
      await done;
    }
    for (const [index, created] of results.entries()) {
      assert.equal(store.getProviderSession(`instance-${index}`, created.thread.id)!.nativeId, "native-1");
      assert.equal((await providers[index]!.readSessionLog(created.thread)).messages.at(-1)!.text, `Reply to instance ${index}`);
      assert.equal(store.getProviderSession(`instance-${1 - index}`, created.thread.id), null);
    }
  } finally { await Promise.all(providers.map((provider) => provider.close())); store.close(); await rm(directory, { recursive: true, force: true }); }
});

it("leaves a failed ACP import unmarked and rolls back a failed history replacement", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sidemesh-acp-rollback-"));
  await mkdir(join(directory, "sessions"));
  const file = join(directory, "sessions", "invalid.json");
  await writeFile(file, '{"schema":"acpx.session.v1"}');
  const store = await SessionStore.open(directory);
  const provider = new AcpAgentProvider({ agent: "fixture", stateDir: directory }, { sessionStore: store });
  try {
    await assert.rejects(provider.start());
    assert.equal(store.hasMigration("acpx-json-v1:acpx"), false);
    assert.equal(store.listProviderSessions("acpx").length, 0);
    assert.equal(await readFile(file, "utf8"), '{"schema":"acpx.session.v1"}');
    const record = { id: "saved", nativeId: "native", cwd: directory, name: null, preview: "Saved",
      createdAt: 1, updatedAt: 2, archived: false, metadata: {} };
    store.saveProviderSession("acpx", record);
    const item = { kind: "message" as const, nativeId: "message", authority: "primary" as const,
      value: { id: "message", seq: 0, createdAt: 1, role: "user" as const, text: "Keep", content: [], attachments: [] } };
    store.putSessionItem("acpx", record.id, item);
    assert.throws(() => store.replaceProviderHistory("acpx", { ...record, name: "Changed" }, [
      { ...item, value: { ...item.value, seq: Number.NaN } },
    ]));
    assert.equal(store.getProviderSession("acpx", record.id)!.name, null);
    assert.deepEqual(store.readSessionItems("acpx", record.id), [item]);
  } finally { await provider.close(); store.close(); await rm(directory, { recursive: true, force: true }); }
});

it("passes explicit arguments without shell expansion, uses stdio framing, and stops the owned process", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sidemesh-acp-stdio-"));
  const script = join(directory, "agent with spaces.mjs");
  const closedFile = join(directory, "closed");
  const literalArg = "literal $SIDEMESH_TOKEN; `echo never` $(echo never)";
  await writeFile(script, `
import { agent, methods, ndJsonStream, PROTOCOL_VERSION } from ${JSON.stringify(import.meta.resolve("@agentclientprotocol/sdk"))};
import { Readable, Writable } from "node:stream";
import { writeFile } from "node:fs/promises";
import assert from "node:assert/strict";
assert.equal(process.argv[2], ${JSON.stringify(literalArg)});
assert.equal(process.env.SIDEMESH_TOKEN, undefined);
const app = agent()
  .onRequest(methods.agent.initialize, () => ({ protocolVersion: PROTOCOL_VERSION, agentCapabilities: { sessionCapabilities: { close: {} } } }))
  .onRequest(methods.agent.session.new, () => ({ sessionId: "stdio-native" }))
  .onRequest(methods.agent.session.prompt, ({ params, requestId }) => {
    // Put notification and response in one read to test the SDK dispatch order.
    process.stdout.write([
      { jsonrpc: "2.0", method: methods.client.session.update, params: { sessionId: params.sessionId,
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "stdio result" } } } },
      { jsonrpc: "2.0", id: requestId, result: { stopReason: "end_turn" } },
    ].map((item) => JSON.stringify(item)).join("\\n") + "\\n");
    return new Promise(() => {});
  })
  .onRequest(methods.agent.session.close, async () => {
    await writeFile(${JSON.stringify(closedFile)}, String(process.pid));
    return {};
  });
const connection = app.connect(ndJsonStream(Writable.toWeb(process.stdout), Readable.toWeb(process.stdin)));
await connection.closed;
`);
  const provider = new AcpAgentProvider({ agent: "stdio-fixture", executable: process.execPath, args: [script, literalArg],
    stateDir: directory, cwd: directory });
  try {
    await provider.start();
    const done = completion(provider);
    const created = await provider.createSession({ cwd: directory, input: textInput("test stdio"), overrides });
    await done;
    assert.equal((await provider.readSessionLog(created.thread)).messages.at(-1)!.text, "stdio result");
    await provider.close();
    const pid = Number(await readFile(closedFile, "utf8"));
    assert.ok(pid > 0);
    assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
  } finally { await provider.close(); await rm(directory, { recursive: true, force: true }); }
});

it("reports a missing explicit executable and closes the failed connection", async () => {
  const directory = await mkdtemp(join(tmpdir(), "sidemesh-acp-missing-"));
  const provider = new AcpAgentProvider({ agent: "missing", executable: join(directory, "missing-agent"), stateDir: directory });
  try {
    await assert.rejects(provider.createSession({ cwd: directory, input: [], overrides }), /ENOENT|closed/i);
    assert.deepEqual(await provider.listLoadedSessionIds(), []);
  } finally { await provider.close(); await rm(directory, { recursive: true, force: true }); }
});
