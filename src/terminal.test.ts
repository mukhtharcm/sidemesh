import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { platform } from "node:os";
import { describe, it } from "node:test";
import type { WebSocket } from "ws";

import {
  TerminalError,
  TerminalRegistry,
  terminalEnabledFromEnv,
} from "./terminal.js";

describe("terminal configuration", () => {
  it("keeps terminal access opt-in", () => {
    assert.equal(terminalEnabledFromEnv({}), false);
    assert.equal(terminalEnabledFromEnv({ SIDEMESH_TERMINAL: "0" }), false);
    assert.equal(terminalEnabledFromEnv({ SIDEMESH_TERMINAL: "1" }), true);
    assert.equal(
      terminalEnabledFromEnv({ SIDEMESH_ENABLE_TERMINAL: "true" }),
      true,
    );
  });

  it("rejects terminal creation when disabled", async () => {
    const registry = new TerminalRegistry({
      enabled: false,
      resolveCwd: async (cwd) => cwd,
    });

    await assert.rejects(
      registry.create({ cwd: "/tmp" }),
      (error) =>
        error instanceof TerminalError &&
        error.status === 403 &&
        error.message === "terminal access is disabled",
    );
  });

  it("runs terminal sign-in with literal arguments, a filtered environment, and no retained output", async () => {
    const registry = new TerminalRegistry({ enabled: true, resolveCwd: async (cwd) => cwd });
    const socket = new FakeSocket();
    let terminalId = "";
    try {
      const done = registry.runAuthentication({
        cwd: process.cwd(), sessionId: "auth-session", executable: process.execPath,
        args: ["-e", "console.log('AUTH_READY'); process.stdin.once('data', () => process.exit(process.stdout.isTTY && !process.env.SIDEMESH_TOKEN && process.env.AUTH_TEST === 'private-value' && process.argv[1] === '$(do-not-run)' ? 0 : 2))", "$(do-not-run)"],
        env: { AUTH_TEST: "private-value", SIDEMESH_TOKEN: "must-be-removed" },
        signal: new AbortController().signal,
        onReady: (id) => {
          terminalId = id;
          registry.attach(socket as unknown as WebSocket, id, -1);
          const publicInfo = JSON.stringify(registry.get(id));
          assert.equal(publicInfo.includes("private-value"), false);
          assert.equal(publicInfo.includes("do-not-run"), false);
          assert.equal(registry.get(id)?.purpose, "authentication");
        },
      });
      await waitForFrame(socket, (frame) => frame.type === "output" && String(frame.data).includes("AUTH_READY"));
      socket.emit("message", Buffer.from(JSON.stringify({ type: "input", data: "finish\n" })));
      await done;
      assert.equal(registry.get(terminalId), null);
      assert.equal(socket.readyState, 3);
      assert.deepEqual(registry.list(), []);
    } finally { registry.dispose(); }
  });

  it("cancels sign-in even when the program ignores termination", async () => {
    const registry = new TerminalRegistry({ enabled: true, resolveCwd: async (cwd) => cwd });
    const socket = new FakeSocket();
    const cancelled = new AbortController();
    try {
      const done = registry.runAuthentication({
        cwd: process.cwd(), sessionId: "auth-session", executable: process.execPath,
        args: ["-e", "process.on('SIGTERM', () => {}); process.on('SIGHUP', () => {}); console.log('AUTH_READY'); setInterval(() => {}, 1000)"],
        signal: cancelled.signal, onReady: (id) => registry.attach(socket as unknown as WebSocket, id, -1),
      });
      const rejected = assert.rejects(done, (error: Error) => error.name === "AbortError");
      await waitForFrame(socket, (frame) => frame.type === "output" && String(frame.data).includes("AUTH_READY"));
      cancelled.abort();
      await rejected;
      assert.deepEqual(registry.list(), []);
    } finally { registry.dispose(); }
  });

  it("applies terminal access and workspace checks to sign-in", async () => {
    for (const enabled of [false, true]) {
      const registry = new TerminalRegistry({ enabled, resolveCwd: async () => { throw new Error("outside workspace"); } });
      try {
        await assert.rejects(registry.runAuthentication({
          cwd: "/unknown", sessionId: "auth-session", executable: process.execPath, args: [],
          signal: new AbortController().signal, onReady: () => assert.fail("must not spawn"),
        }), enabled ? /outside workspace/ : /terminal access is disabled/);
        assert.deepEqual(registry.list(), []);
      } finally { registry.dispose(); }
    }
  });

  it("notifies attached viewers when a session terminal is replaced", async () => {
    const registry = new TerminalRegistry({
      enabled: true,
      resolveCwd: async () => process.cwd(),
      shell: platform() === "win32" ? "cmd.exe" : "/bin/sh",
    });
    const socket = new FakeSocket();

    try {
      const first = await registry.create({
        cwd: process.cwd(),
        sessionId: "terminal-test-session",
      });
      registry.attach(socket as unknown as WebSocket, first.id, -1);

      const hello = await waitForFrame(socket, (frame) => {
        return frame.type === "hello";
      });
      assert.equal(asRecord(hello.terminal)?.id, first.id);

      registry.kill(first.id);
      await waitForFrame(socket, (frame) => frame.type === "exit");

      const normalDuplicate = await registry.create({
        cwd: process.cwd(),
        sessionId: "terminal-test-session",
      });
      assert.equal(
        socket.sent.some((frame) => {
          return (
            frame.type === "replace" &&
            asRecord(frame.replacement)?.id === normalDuplicate.id
          );
        }),
        false,
      );

      const second = await registry.create({
        cwd: process.cwd(),
        sessionId: "terminal-test-session",
        replaceExisting: true,
      });
      const replace = await waitForFrame(socket, (frame) => {
        const replacement = asRecord(frame.replacement);
        return frame.type === "replace" && replacement?.id === second.id;
      });

      assert.equal(replace.terminalId, first.id);
      assert.equal(asRecord(replace.replacement)?.sessionId, first.sessionId);
    } finally {
      socket.close();
      registry.dispose();
    }
  });
});

class FakeSocket extends EventEmitter {
  public readonly OPEN = 1;
  public readyState = 1;
  public bufferedAmount = 0;
  public readonly sent: Record<string, unknown>[] = [];

  public send(payload: string): void {
    const frame = asRecord(JSON.parse(payload));
    if (!frame) return;
    this.sent.push(frame);
    this.emit("sent", frame);
  }

  public close(): void {
    this.readyState = 3;
    this.emit("close");
  }
}

async function waitForFrame(
  socket: FakeSocket,
  predicate: (frame: Record<string, unknown>) => boolean,
): Promise<Record<string, unknown>> {
  for (const frame of socket.sent) {
    if (predicate(frame)) return frame;
  }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("timed out waiting for terminal frame"));
    }, 3000);
    const onSent = (frame: Record<string, unknown>) => {
      if (!predicate(frame)) return;
      cleanup();
      resolve(frame);
    };
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off("sent", onSent);
    };
    socket.on("sent", onSent);
  });
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}
