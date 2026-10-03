import assert from "node:assert/strict";
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import {
  resolvePreferredShell,
  shellCaptureArgs,
  shellLoginArgs,
} from "./host-environment.js";

describe("host environment helpers", () => {
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

  it("ignores login-style shell shims when resolving a real shell", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-shell-test-"));
    const loginPath = nodePath.join(dir, "login");
    const shellPath = nodePath.join(dir, "bash");
    await writeFile(loginPath, "#!/bin/sh\nexit 0\n");
    await writeFile(shellPath, "#!/bin/sh\nexit 0\n");
    await chmod(loginPath, 0o755);
    await chmod(shellPath, 0o755);

    const resolved = resolvePreferredShell({
      SHELL: loginPath,
      PATH: dir,
    });
    assert.notEqual(resolved, loginPath);
    assert.equal(nodePath.basename(resolved ?? ""), "bash");
  });

  it("uses login and capture flags only for known shells", () => {
    assert.deepEqual(shellLoginArgs("/bin/bash"), ["-l"]);
    assert.deepEqual(shellLoginArgs("/system/bin/sh"), []);
    assert.deepEqual(shellCaptureArgs("/bin/bash"), ["-l", "-i", "-c"]);
    assert.deepEqual(shellCaptureArgs("/system/bin/sh"), ["-i", "-c"]);
    assert.equal(shellCaptureArgs("/usr/bin/python"), null);
  });
});
