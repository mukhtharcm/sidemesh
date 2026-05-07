import assert from "node:assert/strict";
import { mkdtemp, writeFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import {
  explainLivePairingConflict,
  explainReachableDaemonConflictForUp,
} from "./cli.js";

describe("explainReachableDaemonConflictForUp", () => {
  it("allows reusing a reachable daemon when it is managed by the same config", () => {
    assert.equal(
      explainReachableDaemonConflictForUp(
        {
          configPath: "/tmp/sidemesh/config.json",
          port: 8787,
        },
        {
          statePath: "/tmp/sidemesh/daemon-state-v1.json",
          state: {
            pid: 1234,
            port: 8787,
            label: "test",
            configPath: "/tmp/sidemesh/config.json",
            stateDir: "/tmp/sidemesh",
            startedAt: 1,
            command: ["node", "dist/cli.js", "daemon"],
          },
          pidAlive: true,
          healthReachable: true,
        },
      ),
      null,
    );
  });

  it("refuses to reuse a reachable daemon without managed state", () => {
    assert.match(
      explainReachableDaemonConflictForUp(
        {
          configPath: "/tmp/sidemesh/config.json",
          port: 8787,
        },
        {
          statePath: "/tmp/sidemesh/daemon-state-v1.json",
          state: null,
          pidAlive: false,
          healthReachable: true,
        },
      ) ?? "",
      /no managed state file exists/i,
    );
  });

  it("refuses to reuse a reachable daemon when the state file is stale", () => {
    assert.match(
      explainReachableDaemonConflictForUp(
        {
          configPath: "/tmp/sidemesh/config.json",
          port: 8787,
        },
        {
          statePath: "/tmp/sidemesh/daemon-state-v1.json",
          state: {
            pid: 1234,
            port: 8787,
            label: "test",
            configPath: "/tmp/sidemesh/config.json",
            stateDir: "/tmp/sidemesh",
            startedAt: 1,
            command: ["node", "dist/cli.js", "daemon"],
          },
          pidAlive: false,
          healthReachable: true,
        },
      ) ?? "",
      /state file .* is stale/i,
    );
  });

  it("refuses to reuse a reachable daemon managed by a different config", () => {
    assert.match(
      explainReachableDaemonConflictForUp(
        {
          configPath: "/tmp/sidemesh/config.json",
          port: 8787,
        },
        {
          statePath: "/tmp/sidemesh/daemon-state-v1.json",
          state: {
            pid: 1234,
            port: 8787,
            label: "test",
            configPath: "/tmp/other/config.json",
            stateDir: "/tmp/sidemesh",
            startedAt: 1,
            command: ["node", "dist/cli.js", "daemon"],
          },
          pidAlive: true,
          healthReachable: true,
        },
      ) ?? "",
      /managed by \/tmp\/other\/config\.json, not \/tmp\/sidemesh\/config\.json/i,
    );
  });
});

describe("explainLivePairingConflict", () => {
  it("refuses to pair from config when the config changed after daemon start", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-cli-test-"));
    const configPath = nodePath.join(dir, "config.json");
    await writeFile(configPath, "{\"token\":\"new-token\"}\n", "utf8");

    const message = await explainLivePairingConflict(
      {
        configPath,
        port: 8787,
      },
      {
        statePath: nodePath.join(dir, "daemon-state-v1.json"),
        state: {
          pid: 1234,
          port: 8787,
          label: "test",
          configPath,
          stateDir: dir,
          startedAt: Date.now() - 20_000,
          command: ["node", "dist/cli.js", "daemon"],
        },
        pidAlive: true,
        healthReachable: true,
      },
    );

    assert.match(message ?? "", /modified after the running daemon started/i);
  });

  it("allows pairing when the config file predates daemon start", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-cli-test-"));
    const configPath = nodePath.join(dir, "config.json");
    await writeFile(configPath, "{\"token\":\"same-token\"}\n", "utf8");
    const file = await stat(configPath);

    const message = await explainLivePairingConflict(
      {
        configPath,
        port: 8787,
      },
      {
        statePath: nodePath.join(dir, "daemon-state-v1.json"),
        state: {
          pid: 1234,
          port: 8787,
          label: "test",
          configPath,
          stateDir: dir,
          startedAt: file.mtimeMs + 2_000,
          command: ["node", "dist/cli.js", "daemon"],
        },
        pidAlive: true,
        healthReachable: true,
      },
    );

    assert.equal(message, null);
  });
});
