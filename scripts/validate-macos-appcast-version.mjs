#!/usr/bin/env node
import { readFile } from "node:fs/promises";

const defaultAppcastUrl =
  "https://github.com/mukhtharcm/sidemesh/releases/download/macos-appcast-prod/appcast-prod.xml";

const currentVersion = required("VERSION");
const currentBuildNumber = required("BUILD_NUMBER");
const appcastUrl = process.env.APPCAST_URL?.trim() || defaultAppcastUrl;
const appcastPath = process.env.EXISTING_APPCAST_PATH?.trim();

function required(name) {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

function parseVersion(value, label) {
  const parts = value.split(".");
  if (parts.length < 1 || parts.length > 3) {
    throw new Error(`${label} must use one to three numeric segments, got ${JSON.stringify(value)}.`);
  }
  if (parts.some((part) => !/^(0|[1-9]\d*)$/.test(part))) {
    throw new Error(`${label} must use numeric segments without leading zeroes, got ${JSON.stringify(value)}.`);
  }
  return parts.map(Number).concat([0, 0, 0]).slice(0, 3);
}

function parseBuildNumber(value, label) {
  if (!/^[1-9]\d*$/.test(value)) {
    throw new Error(`${label} must be a positive integer without leading zeroes, got ${JSON.stringify(value)}.`);
  }
  return Number(value);
}

function compareVersions(left, right) {
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return left[index] < right[index] ? -1 : 1;
    }
  }
  return 0;
}

async function loadExistingAppcast() {
  if (appcastPath) {
    return readFile(appcastPath, "utf8");
  }

  const response = await fetch(appcastUrl);
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw new Error(`Failed to fetch existing appcast: ${response.status} ${response.statusText}`);
  }
  return response.text();
}

function parseExistingAppcast(appcast) {
  const version = appcast.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/)?.[1]?.trim();
  const buildNumber = appcast.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)?.[1]?.trim();
  if (!version || !buildNumber) {
    throw new Error("Existing appcast is missing sparkle:shortVersionString or sparkle:version.");
  }
  return { version, buildNumber };
}

async function main() {
  const current = {
    version: parseVersion(currentVersion, "VERSION"),
    buildNumber: parseBuildNumber(currentBuildNumber, "BUILD_NUMBER"),
  };
  const existingAppcast = await loadExistingAppcast();
  if (!existingAppcast) {
    console.log(`No existing appcast found at ${appcastUrl}; allowing ${currentVersion} (${currentBuildNumber}).`);
    return;
  }

  const existingRaw = parseExistingAppcast(existingAppcast);
  const existing = {
    version: parseVersion(existingRaw.version, "existing appcast version"),
    buildNumber: parseBuildNumber(existingRaw.buildNumber, "existing appcast build number"),
  };
  const versionOrder = compareVersions(current.version, existing.version);

  if (versionOrder < 0) {
    throw new Error(
      `Refusing to publish macOS appcast ${currentVersion} (${currentBuildNumber}); ` +
        `existing appcast is ${existingRaw.version} (${existingRaw.buildNumber}).`,
    );
  }
  if (versionOrder === 0 && current.buildNumber <= existing.buildNumber) {
    throw new Error(
      `Refusing to publish macOS appcast ${currentVersion} (${currentBuildNumber}); ` +
        `existing build for this version is ${existingRaw.buildNumber}.`,
    );
  }

  console.log(
    `Validated macOS appcast ${currentVersion} (${currentBuildNumber}) against ` +
      `existing ${existingRaw.version} (${existingRaw.buildNumber}).`,
  );
}

try {
  await main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
