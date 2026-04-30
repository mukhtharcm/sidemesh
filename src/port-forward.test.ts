import assert from "node:assert/strict";
import { createServer } from "node:net";
import { describe, it } from "node:test";

import {
  PortForwardError,
  PortForwardRegistry,
  loopbackTargetCandidates,
} from "./port-forward.js";

describe("port forwarding", () => {
  it("keeps port forwarding opt-in", () => {
    const registry = new PortForwardRegistry({ enabled: false });

    assert.throws(
      () => registry.create({ targetPort: 3000 }),
      (error) =>
        error instanceof PortForwardError &&
        error.status === 403 &&
        error.message === "port forwarding is disabled",
    );
  });

  it("creates loopback-only forwards by default", () => {
    const registry = new PortForwardRegistry({ enabled: true });

    const forward = registry.create({
      targetPort: 3000,
      scheme: "http",
      label: "Vite",
      sessionId: "session-1",
      cwd: "/repo",
    });

    assert.equal(forward.targetHost, "127.0.0.1");
    assert.equal(forward.targetPort, 3000);
    assert.equal(forward.scheme, "http");
    assert.equal(forward.label, "Vite");
    assert.equal(forward.status, "running");
    assert.equal(forward.activeConnections, 0);
    assert.equal(registry.list().length, 1);

    assert.throws(
      () => registry.create({ targetHost: "192.168.1.10", targetPort: 8080 }),
      (error) =>
        error instanceof PortForwardError &&
        error.status === 400 &&
        error.message.includes("localhost"),
    );
  });

  it("allows non-loopback targets when explicitly configured", () => {
    const registry = new PortForwardRegistry({
      enabled: true,
      allowNonLoopbackTargets: true,
    });

    const forward = registry.create({
      targetHost: "192.168.1.10",
      targetPort: 8080,
      scheme: "tcp",
    });

    assert.equal(forward.targetHost, "192.168.1.10");
    assert.equal(forward.scheme, "tcp");
  });

  it("rejects invalid target ports and schemes", () => {
    const registry = new PortForwardRegistry({ enabled: true });

    assert.throws(
      () => registry.create({ targetPort: 0 }),
      /targetPort must be between 1 and 65535/,
    );
    assert.throws(
      () => registry.create({ targetPort: 3000, scheme: "ftp" }),
      /scheme must be http, https, or tcp/,
    );
  });

  it("bridges WebSocket bytes to the target TCP socket", async () => {
    const target = createServer((socket) => {
      socket.on("data", (chunk) => {
        socket.write(Buffer.from(`echo:${chunk.toString("utf8")}`));
      });
    });
    const targetPort = await listenOnRandomPort(target);
    const registry = new PortForwardRegistry({ enabled: true });
    const forward = registry.create({ targetPort });
    const socket = new FakeSocket();

    try {
      registry.attach(socket as never, forward.id);
      await waitForFrame(socket, (frame) => frame.type === "hello");

      socket.emit("message", Buffer.from("hello"));
      const echoed = await waitForBinary(socket);
      assert.equal(echoed.toString("utf8"), "echo:hello");

      const updated = registry.get(forward.id);
      assert.equal(updated?.connections, 1);
      assert.equal(updated?.activeConnections, 1);
      assert.equal(updated?.bytesFromClient, 5);
      assert.equal(updated?.bytesFromTarget, 10);

      const stopped = registry.stop(forward.id);
      assert.equal(stopped.status, "stopped");
      assert.equal(stopped.activeConnections, 0);
      assert.equal(socket.readyState, 3);
    } finally {
      socket.close();
      registry.dispose();
      await closeServer(target);
    }
  });

  it("falls back between loopback families for IPv6-only dev servers", async () => {
    const target = createServer((socket) => {
      socket.on("data", (chunk) => {
        socket.write(Buffer.from(`ipv6:${chunk.toString("utf8")}`));
      });
    });
    const targetPort = await listenOnRandomPort(target, "::1");
    const registry = new PortForwardRegistry({ enabled: true });
    const forward = registry.create({ targetHost: "127.0.0.1", targetPort });
    const socket = new FakeSocket();

    try {
      registry.attach(socket as never, forward.id);
      await waitForFrame(socket, (frame) => frame.type === "hello");

      socket.emit("message", Buffer.from("hello"));
      const echoed = await waitForBinary(socket);
      assert.equal(echoed.toString("utf8"), "ipv6:hello");

      const updated = registry.get(forward.id);
      assert.equal(updated?.connections, 1);
      assert.equal(updated?.activeConnections, 1);
    } finally {
      socket.close();
      registry.dispose();
      await closeServer(target);
    }
  });

  it("only falls back for canonical localhost targets", () => {
    assert.deepEqual(loopbackTargetCandidates("127.0.0.1"), [
      "127.0.0.1",
      "::1",
      "localhost",
    ]);
    assert.deepEqual(loopbackTargetCandidates("::1"), [
      "::1",
      "127.0.0.1",
      "localhost",
    ]);
    assert.deepEqual(loopbackTargetCandidates("localhost"), [
      "localhost",
      "::1",
      "127.0.0.1",
    ]);
    assert.deepEqual(loopbackTargetCandidates("127.0.0.2"), ["127.0.0.2"]);
  });
});

class FakeSocket {
  public readonly OPEN = 1;
  public readyState = 1;
  public bufferedAmount = 0;
  public readonly sent: unknown[] = [];
  private readonly listeners = new Map<string, Set<(...args: unknown[]) => void>>();

  public send(payload: unknown): void {
    this.sent.push(payload);
    this.emit("sent", payload);
  }

  public close(): void {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.emit("close");
  }

  public on(event: string, listener: (...args: unknown[]) => void): void {
    const listeners = this.listeners.get(event) ?? new Set();
    listeners.add(listener);
    this.listeners.set(event, listeners);
  }

  public off(event: string, listener: (...args: unknown[]) => void): void {
    this.listeners.get(event)?.delete(listener);
  }

  public emit(event: string, ...args: unknown[]): void {
    for (const listener of this.listeners.get(event) ?? []) {
      listener(...args);
    }
  }
}

async function waitForFrame(
  socket: FakeSocket,
  predicate: (frame: Record<string, unknown>) => boolean,
): Promise<Record<string, unknown>> {
  for (const payload of socket.sent) {
    const frame = decodeJsonFrame(payload);
    if (frame && predicate(frame)) return frame;
  }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("timed out waiting for port forward frame"));
    }, 3000);
    const onSent = (payload: unknown) => {
      const frame = decodeJsonFrame(payload);
      if (!frame || !predicate(frame)) return;
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

async function waitForBinary(socket: FakeSocket): Promise<Buffer> {
  for (const payload of socket.sent) {
    if (Buffer.isBuffer(payload)) return payload;
  }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("timed out waiting for binary frame"));
    }, 3000);
    const onSent = (payload: unknown) => {
      if (!Buffer.isBuffer(payload)) return;
      cleanup();
      resolve(payload);
    };
    const cleanup = () => {
      clearTimeout(timeout);
      socket.off("sent", onSent);
    };
    socket.on("sent", onSent);
  });
}

function decodeJsonFrame(payload: unknown): Record<string, unknown> | null {
  if (typeof payload !== "string") return null;
  const parsed = JSON.parse(payload) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  return parsed as Record<string, unknown>;
}

async function listenOnRandomPort(
  server: ReturnType<typeof createServer>,
  host = "127.0.0.1",
) {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, host, () => {
      server.off("error", reject);
      resolve();
    });
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return address.port;
}

async function closeServer(server: ReturnType<typeof createServer>) {
  await new Promise<void>((resolve, reject) => {
    server.close((error) => {
      if (error) reject(error);
      else resolve();
    });
  });
}
