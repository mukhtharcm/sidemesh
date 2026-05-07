#!/usr/bin/env node

import { spawnSync } from "node:child_process";

const MIN_VERSION = [22, 5, 0];
const MIN_VERSION_TEXT = MIN_VERSION.join(".");

function parseVersion(raw) {
  return raw
    .replace(/^v/, "")
    .split("-", 1)[0]
    .split(".")
    .map((part) => Number.parseInt(part, 10));
}

function compareVersion(left, right) {
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const leftPart = left[index] ?? 0;
    const rightPart = right[index] ?? 0;
    if (leftPart > rightPart) return 1;
    if (leftPart < rightPart) return -1;
  }
  return 0;
}

const currentVersion = parseVersion(process.version);
const npmNodeExecPath = process.env.npm_node_execpath;
let installNodeVersion = currentVersion;

if (npmNodeExecPath) {
  const result = spawnSync(npmNodeExecPath, ["-p", "process.version"], {
    encoding: "utf8",
  });
  if (result.status === 0 && result.stdout) {
    installNodeVersion = parseVersion(result.stdout.trim());
  }
}

if (compareVersion(installNodeVersion, MIN_VERSION) >= 0) {
  process.exit(0);
}

console.error(`Sidemesh requires Node.js >= ${MIN_VERSION_TEXT}.`);
console.error(
  `Current runtime: v${installNodeVersion.join(".")}${npmNodeExecPath ? ` (${npmNodeExecPath})` : ""}`,
);
console.error("");
console.error(
  "Sidemesh uses newer Node runtime features, including node:sqlite, so Node 20 installs are not supported.",
);
console.error(
  "Upgrade Node, then rerun the install. For the smoothest global npm installs, use a user-managed Node setup such as Homebrew, nvm, or Volta.",
);
process.exit(1);
