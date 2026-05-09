import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { describe, it, beforeEach, afterEach } from "node:test";

import { clearFsSearchCache, searchFiles, fuzzyScore } from "./fs-search.js";

describe("fuzzyScore", () => {
  it("returns 1 for empty query", () => {
    assert.strictEqual(fuzzyScore("", "foo/bar.ts"), 1);
  });

  it("returns 0 for empty target", () => {
    assert.strictEqual(fuzzyScore("foo", ""), 0);
  });

  it("returns 0 when query chars are not all present", () => {
    assert.strictEqual(fuzzyScore("xyz", "foo/bar.ts"), 0);
  });

  it("scores exact match highly", () => {
    const exact = fuzzyScore("bar", "bar");
    const partial = fuzzyScore("bar", "foobar");
    assert.ok(exact > partial);
  });

  it("rewards word-boundary matches", () => {
    const boundary = fuzzyScore("bar", "foo/bar.ts");
    const middle = fuzzyScore("bar", "foobarts");
    assert.ok(boundary > middle);
  });

  it("rewards consecutive matches", () => {
    const consecutive = fuzzyScore("abc", "abc");
    const scattered = fuzzyScore("abc", "aXbXc");
    assert.ok(consecutive > scattered);
  });

  it("penalizes longer targets", () => {
    const short = fuzzyScore("bar", "bar");
    const long = fuzzyScore("bar", "very/long/path/to/bar");
    assert.ok(short > long);
  });

  it("is case-insensitive", () => {
    assert.strictEqual(fuzzyScore("BAR", "bar.ts"), fuzzyScore("bar", "bar.ts"));
  });
});

describe("searchFiles", () => {
  let tmpDir: string;

  beforeEach(async () => {
    tmpDir = await mkdtemp(path.join(tmpdir(), "fs-search-test-"));
  });

  afterEach(async () => {
    clearFsSearchCache();
    await rm(tmpDir, { recursive: true, force: true });
  });

  it("finds files by exact name", async () => {
    await writeFile(path.join(tmpDir, "server.ts"), "");
    const results = await searchFiles("server", [tmpDir]);
    assert.ok(results.some((r) => r.path === "server.ts"));
  });

  it("finds files by partial match", async () => {
    await writeFile(path.join(tmpDir, "user-service.ts"), "");
    const results = await searchFiles("usr", [tmpDir]);
    assert.ok(results.some((r) => r.path === "user-service.ts"));
  });

  it("finds files in nested directories", async () => {
    const nested = path.join(tmpDir, "src", "components");
    await mkdir(nested, { recursive: true });
    await writeFile(path.join(nested, "button.tsx"), "");
    const results = await searchFiles("button", [tmpDir]);
    assert.ok(results.some((r) => r.path === path.join("src", "components", "button.tsx")));
  });

  it("skips node_modules", async () => {
    const nm = path.join(tmpDir, "node_modules", "foo");
    await mkdir(nm, { recursive: true });
    await writeFile(path.join(nm, "index.js"), "");
    const results = await searchFiles("index", [tmpDir]);
    assert.ok(!results.some((r) => r.path.includes("node_modules")));
  });

  it("skips .git directory", async () => {
    const gitDir = path.join(tmpDir, ".git");
    await mkdir(gitDir, { recursive: true });
    await writeFile(path.join(gitDir, "config"), "");
    const results = await searchFiles("config", [tmpDir]);
    assert.ok(!results.some((r) => r.path.includes(".git")));
  });

  it("respects .gitignore", async () => {
    await writeFile(path.join(tmpDir, ".gitignore"), "*.log\n");
    await writeFile(path.join(tmpDir, "app.log"), "");
    await writeFile(path.join(tmpDir, "app.ts"), "");
    const results = await searchFiles("app", [tmpDir]);
    assert.ok(results.some((r) => r.path === "app.ts"));
    assert.ok(!results.some((r) => r.path === "app.log"));
  });

  it("respects nested .gitignore files", async () => {
    const subDir = path.join(tmpDir, "src");
    await mkdir(subDir, { recursive: true });
    await writeFile(path.join(tmpDir, ".gitignore"), "*.log\n");
    await writeFile(path.join(subDir, ".gitignore"), "*.tmp\n");
    await writeFile(path.join(subDir, "main.ts"), "");
    await writeFile(path.join(subDir, "debug.log"), "");
    await writeFile(path.join(subDir, "cache.tmp"), "");
    const results = await searchFiles("main", [tmpDir]);
    assert.ok(results.some((r) => r.path === path.join("src", "main.ts")));
    assert.ok(!results.some((r) => r.path.includes("debug.log")));
    assert.ok(!results.some((r) => r.path.includes("cache.tmp")));
  });

  it("returns empty array when no matches", async () => {
    await writeFile(path.join(tmpDir, "foo.ts"), "");
    const results = await searchFiles("xyz", [tmpDir]);
    assert.deepStrictEqual(results, []);
  });

  it("returns empty array when query is empty", async () => {
    await writeFile(path.join(tmpDir, "a.ts"), "");
    await writeFile(path.join(tmpDir, "b.ts"), "");
    const results = await searchFiles("", [tmpDir]);
    assert.deepStrictEqual(results, []);
  });

  it("limits results", async () => {
    for (let i = 0; i < 10; i++) {
      await writeFile(path.join(tmpDir, `file${i}.ts`), "");
    }
    const results = await searchFiles("file", [tmpDir], { limit: 5 });
    assert.strictEqual(results.length, 5);
  });

  it("sorts by score descending", async () => {
    await writeFile(path.join(tmpDir, "server.ts"), "");
    await writeFile(path.join(tmpDir, "my-server.ts"), "");
    const results = await searchFiles("server", [tmpDir]);
    assert.ok(results.length >= 2);
    assert.ok(results[0].score >= results[1].score);
  });

  it("caches results and respects TTL", async () => {
    await writeFile(path.join(tmpDir, "cached.ts"), "");
    const first = await searchFiles("cached", [tmpDir]);
    assert.strictEqual(first.length, 1);

    // Cached call should return same result without reading disk again
    const second = await searchFiles("cached", [tmpDir]);
    assert.strictEqual(second.length, 1);
  });

  it("includes matching directories in results", async () => {
    const nested = path.join(tmpDir, "src", "components");
    await mkdir(nested, { recursive: true });
    const results = await searchFiles("comp", [tmpDir]);
    assert.ok(results.some((r) => r.path === path.join("src", "components") + "/"));
    assert.ok(results.some((r) => r.isDirectory));
  });

  it("clears cached entries when the cache is invalidated", async () => {
    await writeFile(path.join(tmpDir, "cached.ts"), "");
    const first = await searchFiles("second", [tmpDir]);
    assert.deepStrictEqual(first, []);

    await writeFile(path.join(tmpDir, "second.ts"), "");
    const cached = await searchFiles("second", [tmpDir]);
    assert.deepStrictEqual(cached, []);

    clearFsSearchCache();
    const refreshed = await searchFiles("second", [tmpDir]);
    assert.ok(refreshed.some((r) => r.path === "second.ts"));
  });

  it("returns empty array for empty roots", async () => {
    const results = await searchFiles("foo", []);
    assert.deepStrictEqual(results, []);
  });
});
