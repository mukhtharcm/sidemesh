#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { basename, join, resolve } from "node:path";
import { tmpdir } from "node:os";

const rootDir = resolve(fileURLToPath(new URL("..", import.meta.url)));
const env = process.env;

function required(name) {
  const value = env[name]?.trim();
  if (!value) {
    throw new Error(`${name} is required`);
  }
  return value;
}

const version = required("VERSION");
const buildNumber = required("BUILD_NUMBER");
const releaseTag = required("RELEASE_TAG");
const appName = env.APP_NAME?.trim() || "Sidemesh";
const flavor = env.FLAVOR?.trim() || "prod";
const repository = env.GITHUB_REPOSITORY?.trim() || "mukhtharcm/sidemesh";
const distDir = resolve(env.DIST_DIR?.trim() || join(rootDir, "artifacts", "macos", version));
const zipPath = resolve(env.ZIP_PATH?.trim() || join(distDir, `${appName}-${version}-macos.zip`));
const appcastName = env.SPARKLE_APPCAST_NAME?.trim() || `appcast-${flavor}.xml`;
const appcastPath = resolve(env.SPARKLE_APPCAST_PATH?.trim() || join(distDir, appcastName));
const shortVersion = env.SPARKLE_SHORT_VERSION?.trim() || version.split("-")[0];
const minimumSystemVersion = env.SPARKLE_MINIMUM_SYSTEM_VERSION?.trim() || "10.15.0";
const releaseUrl = env.SPARKLE_RELEASE_URL?.trim() ||
  `https://github.com/${repository}/releases/tag/${encodeURIComponent(releaseTag)}`;
const downloadUrl = env.SPARKLE_DOWNLOAD_URL?.trim() ||
  `https://github.com/${repository}/releases/download/${encodeURIComponent(releaseTag)}/${encodeURIComponent(basename(zipPath))}`;
const privateKeyBase64 = required("SPARKLE_PRIVATE_KEY_BASE64");

if (!existsSync(zipPath)) {
  throw new Error(`ZIP not found: ${zipPath}`);
}

const signTool = findSignUpdateTool();
const keyPath = join(tmpdir(), `sidemesh-sparkle-${process.pid}.edkey`);

try {
  writeFileSync(keyPath, Buffer.from(privateKeyBase64, "base64"), { mode: 0o600 });
  const signatureFragment = signArchive(signTool, keyPath, zipPath);
  mkdirSync(distDir, { recursive: true });
  writeFileSync(appcastPath, buildAppcast(signatureFragment));
  console.log(appcastPath);
} finally {
  await rm(keyPath, { force: true });
}

function findSignUpdateTool() {
  const candidates = [
    env.SPARKLE_SIGN_UPDATE,
    join(rootDir, "apps/mobile/macos/Pods/Sparkle/bin/sign_update"),
    join(rootDir, "apps/mobile/macos/Pods/Sparkle/Sparkle/bin/sign_update"),
    "sign_update",
  ].filter(Boolean);

  for (const candidate of candidates) {
    if (candidate === "sign_update") {
      const found = spawnSync("sh", ["-c", "command -v sign_update"], {
        encoding: "utf8",
      });
      if (found.status === 0 && found.stdout.trim()) {
        return found.stdout.trim();
      }
      continue;
    }
    if (existsSync(candidate)) {
      return candidate;
    }
  }

  throw new Error("Sparkle sign_update tool was not found");
}

function signArchive(tool, keyFile, archivePath) {
  const attempts = [
    ["--ed-key-file", keyFile, archivePath],
    ["-f", keyFile, archivePath],
  ];
  const errors = [];

  for (const args of attempts) {
    const result = spawnSync(tool, args, { encoding: "utf8" });
    if (result.status !== 0) {
      errors.push(result.stderr.trim() || result.stdout.trim());
      continue;
    }
    const output = `${result.stdout}\n${result.stderr}`;
    const fragment = extractSignatureFragment(output);
    if (fragment) {
      return fragment;
    }
    errors.push(`missing signature fragment in sign_update output: ${output.trim()}`);
  }

  throw new Error(`sign_update failed: ${errors.filter(Boolean).join(" | ")}`);
}

function extractSignatureFragment(output) {
  const signature = output.match(/sparkle:edSignature="[^"]+"/)?.[0];
  const length = output.match(/\slength="\d+"/)?.[0]?.trim();
  if (!signature || !length) {
    return null;
  }
  return `${signature} ${length}`;
}

function buildAppcast(signatureFragment) {
  const pubDate = new Date().toUTCString();
  const title = `${appName} ${version}`;
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${xmlEscape(appName)} macOS Updates</title>
    <link>${xmlEscape(`https://github.com/${repository}/releases`)}</link>
    <description>${xmlEscape(appName)} macOS app updates</description>
    <language>en</language>
    <item>
      <title>${xmlEscape(title)}</title>
      <sparkle:version>${xmlEscape(buildNumber)}</sparkle:version>
      <sparkle:shortVersionString>${xmlEscape(shortVersion)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${xmlEscape(minimumSystemVersion)}</sparkle:minimumSystemVersion>
      <pubDate>${xmlEscape(pubDate)}</pubDate>
      <link>${xmlEscape(releaseUrl)}</link>
      <sparkle:releaseNotesLink>${xmlEscape(releaseUrl)}</sparkle:releaseNotesLink>
      <enclosure url="${xmlEscape(downloadUrl)}" ${signatureFragment} type="application/zip" />
    </item>
  </channel>
</rss>
`;
}

function xmlEscape(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&apos;");
}
