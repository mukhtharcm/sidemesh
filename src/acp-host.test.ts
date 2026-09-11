import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";
import { agent, methods, type AgentConnection } from "@agentclientprotocol/sdk";
import { AcpHost } from "./acp-host.js";
import type { AgentPendingAction, AgentProviderLiveEvent } from "./agent-provider.js";

const sessionId = "native-session";

describe("ACP host callbacks over the official SDK", () => {
  let root: string;
  let cwd: string;
  let host: AcpHost;
  let connection: AgentConnection;
  let events: AgentProviderLiveEvent[];
  let actionWaiter: ((action: AgentPendingAction) => void) | null;
  const nextAction = () => new Promise<AgentPendingAction>((resolve) => { actionWaiter = resolve; });

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "sidemesh-acp-host-"));
    cwd = join(root, "workspace");
    await mkdir(cwd);
    events = [];
    actionWaiter = null;
    host = new AcpHost("public-session", cwd, "approve-reads", (event) => {
      events.push(event);
      if (event.type === "action_opened") { actionWaiter?.(event.action); actionWaiter = null; }
    });
    host.nativeSessionId = sessionId;
    connection = agent().connect(host.app);
  });
  afterEach(async () => {
    connection.close();
    await host.close();
    await rm(root, { recursive: true, force: true });
  });

  it("preserves an exact option ID and does not widen automatic read approval", async () => {
    const pendingAction = nextAction();
    const permission = connection.client.request(methods.client.session.requestPermission, {
      sessionId, toolCall: { toolCallId: "tool", kind: "edit", title: "Choose write scope" },
      options: [
        { optionId: "broad", name: "All files", kind: "allow_always" },
        { optionId: "narrow", name: "One folder", kind: "allow_always" },
      ],
    });
    const action = await pendingAction;
    assert.equal(host.respond(action.id, "accept"), false);
    assert.equal(host.respond(action.id, "acceptForSession"), false);
    assert.equal(host.respond(action.id, { providerOptionId: "invented" }), false);
    assert.equal(host.respond(action.id, { providerOptionId: "narrow" }), true);
    assert.deepEqual(await permission, { outcome: { outcome: "selected", optionId: "narrow" } });

    const readAction = nextAction();
    const read = connection.client.request(methods.client.session.requestPermission, {
      sessionId, toolCall: { toolCallId: "read", kind: "read", title: "Read" },
      options: [{ optionId: "forever", name: "Always allow", kind: "allow_always" }],
    });
    const opened = await readAction;
    assert.equal(host.respond(opened.id, "accept"), false);
    host.cancelPending();
    assert.deepEqual(await read, { outcome: { outcome: "cancelled" } });
    assert.ok(events.some((event) => event.type === "action_resolved" && event.actionId === opened.id));
  });

  it("uses canonical workspace paths and writes after app approval without a TTY", async () => {
    const outside = join(root, "outside");
    await mkdir(outside);
    await writeFile(join(outside, "private.txt"), "untouched");
    await symlink(outside, join(cwd, "escape"));
    await assert.rejects(connection.client.request(methods.client.fs.readTextFile, {
      sessionId, path: join(cwd, "escape", "private.txt"),
    }), /outside any workspace/);
    await assert.rejects(connection.client.request(methods.client.fs.writeTextFile, {
      sessionId, path: join(cwd, "escape", "private.txt"), content: "bad",
    }), /outside any workspace/);
    assert.equal(events.length, 0);
    const pendingAction = nextAction();
    const write = connection.client.request(methods.client.fs.writeTextFile, {
      sessionId, path: join(cwd, "new.txt"), content: "one\ntwo\nthree",
    });
    const action = await pendingAction;
    assert.equal(host.respond(action.id, "acceptForSession"), false);
    assert.equal(host.respond(action.id, "accept"), true);
    await write;
    assert.equal(await readFile(join(cwd, "new.txt"), "utf8"), "one\ntwo\nthree");
    assert.deepEqual(await connection.client.request(methods.client.fs.readTextFile, {
      sessionId, path: join(cwd, "new.txt"), line: 2, limit: 1,
    }), { content: "two" });
    assert.equal(await readFile(join(outside, "private.txt"), "utf8"), "untouched");
  });

  it("rejects edits and symbolic-link changes made while approval is pending", async () => {
    const target = join(cwd, "file.txt");
    await writeFile(target, "original");
    let pendingAction = nextAction();
    let rejected = assert.rejects(connection.client.request(methods.client.fs.writeTextFile, {
      sessionId, path: target, content: "agent change",
    }), /File changed/);
    let action = await pendingAction;
    await writeFile(target, "user change");
    host.respond(action.id, "accept");
    await rejected;
    assert.equal(await readFile(target, "utf8"), "user change");

    pendingAction = nextAction();
    rejected = assert.rejects(connection.client.request(methods.client.fs.writeTextFile, {
      sessionId, path: target, content: "agent change",
    }), /outside any workspace/);
    action = await pendingAction;
    const outside = join(root, "private.txt");
    await writeFile(outside, "private");
    await rm(target);
    await symlink(outside, target);
    host.respond(action.id, "accept");
    await rejected;
    assert.equal(await readFile(outside, "utf8"), "private");
  });

  it("owns terminal output, exit, release, and token removal", async () => {
    const pendingAction = nextAction();
    const create = connection.client.request(methods.client.terminal.create, {
      sessionId, command: process.execPath, args: ["-e", "process.stdout.write(process.env.SIDEMESH_TOKEN === undefined ? 'removed:ééé' : 'token leaked')"],
      env: [{ name: "SIDEMESH_TOKEN", value: "test-only-secret" }], outputByteLimit: 7,
    });
    const action = await pendingAction;
    host.respond(action.id, "accept");
    const { terminalId } = await create;
    assert.deepEqual(await connection.client.request(methods.client.terminal.waitForExit, { sessionId, terminalId }), { exitCode: 0, signal: null });
    const output = await connection.client.request(methods.client.terminal.output, { sessionId, terminalId });
    assert.equal(output.output, ":ééé");
    assert.equal(output.truncated, true);
    await assert.rejects(connection.client.request(methods.client.terminal.output, { sessionId: "another", terminalId }), /Unknown/);
    await connection.client.request(methods.client.terminal.release, { sessionId, terminalId });
    await assert.rejects(connection.client.request(methods.client.terminal.output, { sessionId, terminalId }), /not found/i);
  });

  it("kills a running terminal and rejects pending work during close", async () => {
    let pendingAction = nextAction();
    const create = connection.client.request(methods.client.terminal.create, {
      sessionId, command: process.execPath, args: ["-e", "setInterval(() => {}, 1000)"],
    });
    host.respond((await pendingAction).id, "accept");
    const { terminalId } = await create;
    const exited = connection.client.request(methods.client.terminal.waitForExit, { sessionId, terminalId });
    await connection.client.request(methods.client.terminal.kill, { sessionId, terminalId });
    assert.equal((await exited).signal, "SIGTERM");
    pendingAction = nextAction();
    const rejected = assert.rejects(connection.client.request(methods.client.fs.writeTextFile, {
      sessionId, path: join(cwd, "must-not-exist"), content: "bad",
    }), /cancel/i);
    await pendingAction;
    await host.close();
    await rejected;
    await assert.rejects(readFile(join(cwd, "must-not-exist")), { code: "ENOENT" });
  });

  it("keeps structured choices and validates the submitted form", async () => {
    const pendingAction = nextAction();
    const response = connection.client.request(methods.client.elicitation.create, {
      sessionId, mode: "form", message: "Choose settings", requestedSchema: {
        type: "object", required: ["scope"], properties: {
          scope: { type: "string", oneOf: [{ const: "one", title: "One folder" }, { const: "all", title: "All folders" }] },
        },
      },
    });
    const action = await pendingAction;
    const field = action.elicitation!.fields[0]!;
    assert.equal(field.type, "string");
    if (field.type === "string") assert.equal(field.options![0]!.label, "One folder");
    assert.equal(host.respond(action.id, { action: "accept", content: {} }), false);
    assert.equal(host.respond(action.id, { action: "accept", content: { scope: "invalid" } }), false);
    assert.equal(host.respond(action.id, { action: "accept", content: { scope: "one" } }), true);
    assert.deepEqual(await response, { action: "accept", content: { scope: "one" } });
  });
});
