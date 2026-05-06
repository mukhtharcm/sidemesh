#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "..");
const pubspecPath = resolve(process.env.MOBILE_PUBSPEC_PATH ?? resolve(repoRoot, "apps/mobile/pubspec.yaml"));

function usage() {
  console.error("Usage: npm run mobile:version -- <version+build>");
  console.error("Example: npm run mobile:version -- 1.2.0+3");
}

function parseMobileVersion(value, label) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)$/.exec(value);
  if (!match) {
    throw new Error(`${label} must use X.Y.Z+N with a positive integer build number, got ${JSON.stringify(value)}.`);
  }

  return {
    raw: value,
    version: `${match[1]}.${match[2]}.${match[3]}`,
    versionParts: [Number(match[1]), Number(match[2]), Number(match[3])],
    buildNumber: Number(match[4]),
  };
}

function compareVersionParts(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return left[index] < right[index] ? -1 : 1;
    }
  }
  return 0;
}

const nextArg = process.argv[2];
if (!nextArg || process.argv.length > 3) {
  usage();
  process.exit(1);
}

async function main() {
  const pubspec = await readFile(pubspecPath, "utf8");
  const versionLine = pubspec.match(/^version:[^\S\r\n]*(\S+)[^\S\r\n]*$/m);
  if (!versionLine) {
    throw new Error(`Could not find a top-level version line in ${pubspecPath}.`);
  }

  const current = parseMobileVersion(versionLine[1], "Current mobile version");
  const next = parseMobileVersion(nextArg, "Next mobile version");
  const versionOrder = compareVersionParts(next.versionParts, current.versionParts);

  if (versionOrder < 0) {
    throw new Error(`Refusing to downgrade mobile version from ${current.raw} to ${next.raw}.`);
  }

  if (versionOrder === 0 && next.buildNumber <= current.buildNumber) {
    throw new Error(
      `Refusing to reuse or decrease build number for ${next.version}; ` +
        `current is ${current.buildNumber}, requested ${next.buildNumber}.`,
    );
  }

  const updated = pubspec.replace(/^version:[^\S\r\n]*\S+[^\S\r\n]*$/m, `version: ${next.raw}`);
  await writeFile(pubspecPath, updated);
  console.log(`Updated ${pubspecPath}: ${current.raw} -> ${next.raw}`);
}

try {
  await main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
