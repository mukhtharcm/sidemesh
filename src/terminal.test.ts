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
