#!/usr/bin/env node

import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import nodePath from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = nodePath.resolve(
  nodePath.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const localTypeScript = nodePath.join(
  repoRoot,
  "node_modules",
  "typescript",
  "bin",
  "tsc",
);

if (!existsSync(localTypeScript)) {
  console.error("Installing Sidemesh directly from a GitHub repo via npm is no longer supported.");
  console.error("");
  console.error("Install the published package instead:");
  console.error("  npm install -g sidemesh");
  console.error("");
  console.error(
    "If you are developing from a local clone, run `npm install` at the repo root so the TypeScript build toolchain is available before packaging.",
  );
  process.exit(1);
}

const npmCommand = process.platform === "win32" ? "npm.cmd" : "npm";
const result = spawnSync(npmCommand, ["run", "build"], {
  cwd: repoRoot,
  stdio: "inherit",
  env: process.env,
});

if (result.error) {
  throw result.error;
}
process.exit(result.status ?? 1);
