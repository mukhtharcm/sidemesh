import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdtemp, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import nodePath from "node:path";
import { promisify } from "node:util";

import { detectInstallInfo, resolvePackageRoot } from "./install-info.js";

const execFileAsync = promisify(execFile);

describe("resolvePackageRoot", () => {
  it("returns the project root", () => {
    const root = resolvePackageRoot();
    assert.ok(root.length > 0);
  });
});

describe("detectInstallInfo", () => {
  it("detects git install", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-install-test-"));
    await mkdir(nodePath.join(dir, ".git"), { recursive: true });
    await writeFile(
      nodePath.join(dir, "package.json"),
      JSON.stringify({ name: "test", version: "1.0.0" }),
    );
    const info = await detectInstallInfo(dir);
    assert.equal(info.installType, "git");
    assert.equal(info.packageVersion, "1.0.0");
    assert.equal(info.updateSupported, true);
    assert.match(info.updateCommand ?? "", /git pull --ff-only/);
    assert.match(info.updateCommand ?? "", /npm ci/);
    assert.doesNotMatch(info.updateCommand ?? "", /npm install/);
    assert.equal(info.updateAvailable, false);
  });

  it("detects npm-local install", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-install-test-"));
    const nested = nodePath.join(dir, "node_modules", "sidemesh");
    await mkdir(nested, { recursive: true });
    await writeFile(
      nodePath.join(nested, "package.json"),
      JSON.stringify({ name: "sidemesh", version: "0.1.0" }),
    );
    const info = await detectInstallInfo(nested);
    assert.equal(info.installType, "npm-local");
    assert.equal(info.packageVersion, "0.1.0");
    assert.equal(info.updateSupported, false);
    assert.equal(info.latestVersion, null);
  });

  it("tracks bleeding-edge git installs against the CI-verified ref", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-install-test-"));
    const origin = nodePath.join(dir, "origin.git");
    const repo = nodePath.join(dir, "repo");

    await execFileAsync("git", ["init", "--bare", origin]);
    await execFileAsync("git", ["clone", origin, repo]);
    await execFileAsync("git", ["checkout", "-b", "main"], { cwd: repo });
    await execFileAsync("git", ["config", "user.email", "test@example.com"], {
      cwd: repo,
    });
    await execFileAsync("git", ["config", "user.name", "Test User"], {
      cwd: repo,
    });
    await writeFile(
      nodePath.join(repo, "package.json"),
      JSON.stringify({ name: "sidemesh", version: "0.1.0" }),
    );
    await writeFile(nodePath.join(repo, "README.md"), "hello\n");
    await execFileAsync("git", ["add", "."], { cwd: repo });
    await execFileAsync("git", ["commit", "-m", "initial"], { cwd: repo });
    await execFileAsync("git", ["push", "-u", "origin", "main"], {
      cwd: repo,
    });
    await execFileAsync(
      "git",
      ["push", "origin", "HEAD:refs/heads/bleeding-edge"],
      { cwd: repo },
    );

    const info = await detectInstallInfo({
      packageRoot: repo,
      config: { updateChannel: "bleeding-edge" },
    });

    assert.equal(info.installType, "git");
    assert.equal(info.updateChannel, "bleeding-edge");
    assert.match(info.currentCommitSha ?? "", /^[0-9a-f]{40}$/);
    assert.equal(info.latestCommitSha, info.currentCommitSha);
    assert.equal(info.updateAvailable, false);
    assert.match(
      info.updateCommand ?? "",
      /git fetch origin refs\/heads\/bleeding-edge/,
    );
    assert.match(info.updateCommand ?? "", /git merge --ff-only FETCH_HEAD/);
    assert.match(info.updateCommand ?? "", /npm ci/);
    assert.doesNotMatch(info.updateCommand ?? "", /npm install/);

    await writeFile(nodePath.join(repo, "README.md"), "unverified main\n");
    await execFileAsync("git", ["add", "README.md"], { cwd: repo });
    await execFileAsync("git", ["commit", "-m", "candidate"], { cwd: repo });
    const { stdout: candidateStdout } = await execFileAsync(
      "git",
      ["rev-parse", "HEAD"],
      { cwd: repo },
    );
    const candidateSha = candidateStdout.trim();
    await execFileAsync("git", ["push", "origin", "main"], { cwd: repo });
    await execFileAsync("git", ["reset", "--hard", "HEAD^"], { cwd: repo });

    const beforeVerification = await detectInstallInfo({
      packageRoot: repo,
      config: { updateChannel: "bleeding-edge" },
    });
    assert.equal(beforeVerification.latestCommitSha, info.currentCommitSha);
    assert.equal(beforeVerification.updateAvailable, false);

    await execFileAsync(
      "git",
      ["push", "origin", `${candidateSha}:refs/heads/bleeding-edge`],
      { cwd: repo },
    );
    const afterVerification = await detectInstallInfo({
      packageRoot: repo,
      config: { updateChannel: "bleeding-edge" },
    });
    assert.equal(afterVerification.latestCommitSha, candidateSha);
    assert.notEqual(
      afterVerification.latestCommitSha,
      afterVerification.currentCommitSha,
    );
    assert.equal(afterVerification.updateAvailable, true);
  });

  it("falls back to unknown when package.json is missing", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-install-test-"));
    const info = await detectInstallInfo(dir);
    assert.equal(info.installType, "unknown");
    assert.equal(info.packageVersion, "unknown");
    assert.equal(info.updateSupported, false);
  });

  it("detects an active Termux runit service as managed", {
    skip: process.platform !== "linux" && process.platform !== "android",
  }, async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-install-test-"));
    const prefix = nodePath.join(dir, "prefix");
    const binDir = nodePath.join(prefix, "bin");
    const serviceDir = nodePath.join(prefix, "var", "service", "sidemesh");
    const originalPrefix = process.env.PREFIX;
    const originalTermuxVersion = process.env.TERMUX_VERSION;
    const originalPath = process.env.PATH;

    await mkdir(binDir, { recursive: true });
    await mkdir(nodePath.join(prefix, "share", "termux-services"), {
      recursive: true,
    });
    await mkdir(nodePath.join(serviceDir, "supervise"), { recursive: true });
    await mkdir(nodePath.join(prefix, "var", "run"), { recursive: true });
    await writeFile(
      nodePath.join(dir, "package.json"),
      JSON.stringify({ name: "sidemesh", version: "0.1.0" }),
    );
    await writeExecutable(
      nodePath.join(binDir, "sv"),
      "#!/bin/sh\necho 'run: sidemesh: (pid 123) 1s'\n",
    );
    await writeExecutable(
      nodePath.join(binDir, "service-daemon"),
      "#!/bin/sh\nexit 0\n",
    );
    await writeFile(
      nodePath.join(prefix, "share", "termux-services", "svlogger"),
      "#!/bin/sh\nexit 0\n",
    );
    await writeFile(nodePath.join(serviceDir, "run"), "#!/bin/sh\nexit 0\n");
    await writeFile(nodePath.join(serviceDir, "supervise", "ok"), "");
    await writeFile(
      nodePath.join(prefix, "var", "run", "service-daemon.pid"),
      String(process.pid),
    );

    try {
      process.env.PREFIX = prefix;
      process.env.TERMUX_VERSION = "0.118.1";
      process.env.PATH = binDir;

      const info = await detectInstallInfo(dir);

      assert.equal(info.isManagedService, true);
      assert.equal(info.serviceName, "sidemesh");
    } finally {
      restoreEnv("PREFIX", originalPrefix);
      restoreEnv("TERMUX_VERSION", originalTermuxVersion);
      restoreEnv("PATH", originalPath);
    }
  });
});

async function writeExecutable(path: string, content: string): Promise<void> {
  await writeFile(path, content);
  await chmod(path, 0o755);
}

function restoreEnv(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
