import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";

import {
  daemonStatePath,
  inspectDaemon,
  removeDaemonState,
  writeDaemonState,
} from "./daemon-lifecycle.js";

describe("daemon lifecycle state", () => {
  it("writes, inspects, and removes managed daemon state", async () => {
    const stateDir = await mkdtemp(join(tmpdir(), "sidemesh-daemon-test-"));
    const config = { stateDir, port: 9 };

    await writeDaemonState(config, {
      pid: process.pid,
      port: config.port,
      label: "test-host",
      configPath: join(stateDir, "config.json"),
      stateDir,
      startedAt: 123,
      command: ["node", "dist/cli.js", "daemon"],
    });

    const inspected = await inspectDaemon(config);
    assert.equal(inspected.statePath, daemonStatePath(config));
    assert.equal(inspected.state?.pid, process.pid);
    assert.equal(inspected.pidAlive, true);
    assert.equal(inspected.healthReachable, false);

    await removeDaemonState(config, process.pid + 1);
    assert.equal((await inspectDaemon(config)).state?.pid, process.pid);

    await removeDaemonState(config, process.pid);
    assert.equal((await inspectDaemon(config)).state, null);
  });
});
