import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, writeFile, mkdir } from "node:fs/promises";
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
    assert.ok(info.updateCommand?.includes("git pull"));
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

  it("tracks bleeding-edge git installs against origin/main", async () => {
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

    const info = await detectInstallInfo({
      packageRoot: repo,
      config: { updateChannel: "bleeding-edge" },
    });

    assert.equal(info.installType, "git");
    assert.equal(info.updateChannel, "bleeding-edge");
    assert.match(info.currentCommitSha ?? "", /^[0-9a-f]{40}$/);
    assert.equal(info.latestCommitSha, info.currentCommitSha);
    assert.equal(info.updateAvailable, false);
    assert.match(info.updateCommand ?? "", /git pull origin main/);
  });

  it("falls back to unknown when package.json is missing", async () => {
    const dir = await mkdtemp(nodePath.join(tmpdir(), "sidemesh-install-test-"));
    const info = await detectInstallInfo(dir);
    assert.equal(info.installType, "unknown");
    assert.equal(info.packageVersion, "unknown");
    assert.equal(info.updateSupported, false);
  });
});
