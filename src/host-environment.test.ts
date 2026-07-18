import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { describe, it } from "node:test";

import {
  isTermuxEnvironment,
  isTermuxRuntimePlatform,
  resolveTermuxPrefix,
  resolvePreferredShell,
  shellCaptureArgs,
  shellLoginArgs,
  supportsSystemdServiceManagement,
  supportsTermuxServiceManagement,
} from "./host-environment.js";

describe("host environment helpers", () => {
  it("detects termux from its environment markers", () => {
    const defaultPrefix = "/data/data/com.termux/files/usr";
    assert.equal(
      isTermuxEnvironment({
        PREFIX: defaultPrefix,
      }),
      true,
    );
    assert.equal(
      isTermuxEnvironment({
        TERMUX_VERSION: "0.118.1",
      }),
      true,
    );
    assert.equal(
      isTermuxEnvironment({
        PATH: `/usr/bin:${defaultPrefix}/bin:/bin`,
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

  it("allows Termux service management on Android and Linux runtimes only", () => {
    assert.equal(isTermuxRuntimePlatform("android"), true);
    assert.equal(isTermuxRuntimePlatform("linux"), true);
    assert.equal(isTermuxRuntimePlatform("darwin"), false);
  });

  it("detects termux-services when the expected commands and svlogger exist", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-termux-test-"));
    const prefix = nodePath.join(dir, "prefix");
    const binDir = nodePath.join(prefix, "bin");
    const svloggerPath = nodePath.join(
      prefix,
      "share",
      "termux-services",
      "svlogger",
    );
    await mkdir(binDir, { recursive: true });
    await mkdir(nodePath.dirname(svloggerPath), { recursive: true });
    await chmod(
      await ensureExecutable(nodePath.join(binDir, "sv")),
      0o755,
    );
    await chmod(
      await ensureExecutable(nodePath.join(binDir, "service-daemon")),
      0o755,
    );
    await writeFile(svloggerPath, "#!/bin/sh\nexit 0\n");

    assert.equal(
      supportsTermuxServiceManagement({
        PREFIX: prefix,
        TERMUX_VERSION: "0.118.1",
        PATH: "/usr/bin",
      }, "linux"),
      true,
    );
    assert.equal(resolveTermuxPrefix({ PREFIX: prefix }), prefix);
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

async function ensureExecutable(path: string): Promise<string> {
  await writeFile(path, "#!/bin/sh\nexit 0\n");
  return path;
}
