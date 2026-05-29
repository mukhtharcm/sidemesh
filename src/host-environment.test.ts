import assert from "node:assert/strict";
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import {
  isTermuxEnvironment,
  resolvePreferredShell,
  shellCaptureArgs,
  shellLoginArgs,
  supportsSystemdServiceManagement,
} from "./host-environment.js";

describe("host environment helpers", () => {
  it("detects termux from its environment markers", () => {
    assert.equal(
      isTermuxEnvironment({
        PREFIX: "/data/data/com.termux/files/usr",
      }),
      true,
    );
    assert.equal(
      isTermuxEnvironment({
        TERMUX_VERSION: "0.118.1",
      }),
      true,
    );
    assert.equal(isTermuxEnvironment({ PREFIX: "/usr" }), false);
  });

  it("never treats termux as a systemd host", () => {
    assert.equal(
      supportsSystemdServiceManagement({
        PREFIX: "/data/data/com.termux/files/usr",
        PATH: process.env.PATH,
      }),
      false,
    );
  });

  it("resolves shell commands from PATH when SHELL is not absolute", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-shell-test-"));
    const shellPath = nodePath.join(dir, "bash");
    await writeFile(shellPath, "#!/bin/sh\nexit 0\n");
    await chmod(shellPath, 0o755);

    assert.equal(
      resolvePreferredShell({
        SHELL: "bash",
        PATH: dir,
      }),
      shellPath,
    );
  });

  it("uses login and capture flags only for known shells", () => {
    assert.deepEqual(shellLoginArgs("/bin/bash"), ["-l"]);
    assert.deepEqual(shellLoginArgs("/system/bin/sh"), []);
    assert.deepEqual(shellCaptureArgs("/bin/bash"), ["-l", "-i", "-c"]);
    assert.deepEqual(shellCaptureArgs("/system/bin/sh"), ["-i", "-c"]);
    assert.equal(shellCaptureArgs("/usr/bin/python"), null);
  });
});
