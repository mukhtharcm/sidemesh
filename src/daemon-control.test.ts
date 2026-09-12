import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { it } from "node:test";

import { confirmDanger, daemonInvocation } from "./daemon-control.js";

it("launches the CLI entry point and preserves the explicit config path", async () => {
  const configPath = "/tmp/sidemesh config/config.json";
  const invocation = daemonInvocation(configPath);
  assert.deepEqual(invocation.args.slice(-3), ["daemon", "--config", configPath]);
  const commandIndex = invocation.args.indexOf("daemon");
  const { stdout } = await promisify(execFile)(invocation.command, [
    ...invocation.args.slice(0, commandIndex), "--help",
  ]);
  assert.match(stdout, /Usage: sidemesh/);
  assert.match(stdout, /daemon/);
});

it("requires explicit confirmation in a non-interactive shell", async () => {
  await confirmDanger("Stop the daemon.", true);
  if (!process.stdin.isTTY) {
    await assert.rejects(confirmDanger("Stop the daemon.", false), /Pass --yes/);
  }
});
