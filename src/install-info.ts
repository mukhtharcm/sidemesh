import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { constants as fsConstants, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import nodePath from "node:path";
import { promisify } from "node:util";

import type { NodeConfig, UpdateChannel } from "./types.js";

const execFileAsync = promisify(execFile);

export type InstallType = "git" | "npm-global" | "npm-local" | "unknown";

export interface InstallInfo {
  packageVersion: string;
  latestVersion: string | null;
  currentCommitSha: string | null;
  latestCommitSha: string | null;
  updateChannel: UpdateChannel;
  updateAvailable: boolean;
  packageRoot: string;
  installType: InstallType;
  updateSupported: boolean;
  updateCommand: string | null;
  restoreCommand: string | null;
  isManagedService: boolean;
  serviceName: string | null;
}

export interface DetectInstallInfoOptions {
  packageRoot?: string;
  config?: Pick<NodeConfig, "updateChannel"> | null;
}

interface LatestVersionInfo {
  latestVersion: string | null;
  latestCommitSha: string | null;
}

export async function detectInstallInfo(
  packageRootOverride?: string,
): Promise<InstallInfo>;
export async function detectInstallInfo(
  options?: DetectInstallInfoOptions,
): Promise<InstallInfo>;
export async function detectInstallInfo(
  packageRootOrOptions: string | DetectInstallInfoOptions = {},
): Promise<InstallInfo> {
  const options =
    typeof packageRootOrOptions === "string"
      ? { packageRoot: packageRootOrOptions }
      : packageRootOrOptions;
  const packageRoot = options.packageRoot ?? resolvePackageRoot();
  const updateChannel = options.config?.updateChannel ?? "stable";
  const packageVersion = await readPackageVersion(packageRoot);
  const installType = await detectInstallType(packageRoot);
  const isManagedService = await isSystemdServiceActive().catch(() => false);
  const serviceName = isManagedService ? "sidemesh" : null;
  const currentCommitSha =
    installType === "git" ? await readCurrentCommitSha(packageRoot) : null;

  let updateSupported = false;
  let updateCommand: string | null = null;

  switch (installType) {
    case "git": {
      updateSupported = true;
      const npmCommand = shellQuote(resolveNpmExecutable());
      updateCommand =
        updateChannel === "bleeding-edge"
          ? `(git checkout main || git checkout -b main --track origin/main) && git pull origin main && ${npmCommand} install && ${npmCommand} run build`
          : `git pull && ${npmCommand} install && ${npmCommand} run build`;
      break;
    }
    case "npm-global": {
      updateSupported = true;
      updateCommand = `${shellQuote(resolveNpmExecutable())} update -g sidemesh`;
      break;
    }
    case "npm-local": {
      updateSupported = false;
      break;
    }
    case "unknown": {
      updateSupported = false;
      break;
    }
  }

  const { latestVersion, latestCommitSha } = updateSupported
    ? await checkLatestVersion(packageRoot, installType, updateChannel)
    : { latestVersion: null, latestCommitSha: null };
  const updateAvailable = isUpdateAvailable({
    packageVersion,
    latestVersion,
    currentCommitSha,
    latestCommitSha,
    installType,
    updateChannel,
  });

  return {
    packageVersion,
    latestVersion,
    currentCommitSha,
    latestCommitSha,
    updateChannel,
    updateAvailable,
    packageRoot,
    installType,
    updateSupported,
    updateCommand,
    restoreCommand:
      installType === "git" && currentCommitSha
        ? `git checkout ${currentCommitSha}`
        : null,
    isManagedService,
    serviceName,
  };
}

export function resolvePackageRoot(): string {
  return nodePath.resolve(
    nodePath.dirname(fileURLToPath(import.meta.url)),
    "..",
  );
}

async function readPackageVersion(packageRoot: string): Promise<string> {
  try {
    const content = await readFile(
      nodePath.join(packageRoot, "package.json"),
      "utf8",
    );
    const pkg = JSON.parse(content) as { version?: unknown };
    return typeof pkg.version === "string" ? pkg.version : "unknown";
  } catch {
    return "unknown";
  }
}

async function readCurrentCommitSha(packageRoot: string): Promise<string | null> {
  try {
    const { stdout } = await execFileAsync(
      "git",
      ["rev-parse", "HEAD"],
      { cwd: packageRoot, encoding: "utf8", timeout: 10_000 },
    );
    const sha = stdout.trim();
    return sha || null;
  } catch {
    return null;
  }
}

async function checkLatestVersion(
  packageRoot: string,
  installType: InstallType,
  updateChannel: UpdateChannel,
): Promise<LatestVersionInfo> {
  switch (installType) {
    case "git": {
      if (updateChannel === "bleeding-edge") {
        try {
          const { stdout } = await execFileAsync(
            "git",
            ["ls-remote", "origin", "main"],
            { cwd: packageRoot, encoding: "utf8", timeout: 10_000 },
          );
          const match = /^([0-9a-f]{40})\s+refs\/heads\/main$/m.exec(stdout);
          return {
            latestVersion: null,
            latestCommitSha: match?.[1] ?? null,
          };
        } catch {
          return { latestVersion: null, latestCommitSha: null };
        }
      }
      try {
        const { stdout } = await execFileAsync(
          "git",
          ["ls-remote", "--tags", "origin"],
          { cwd: packageRoot, encoding: "utf8", timeout: 10_000 },
        );
        const tags = [...new Set(
          stdout
            .split("\n")
            .map((line) => {
              const match = /refs\/tags\/(.+?)\s*$/.exec(line);
              return match?.[1]?.replace(/\^{}$/, "") ?? null;
            })
            .filter((tag): tag is string => tag !== null && tag.startsWith("v")),
        )];
        if (tags.length === 0) {
          return { latestVersion: null, latestCommitSha: null };
        }
        tags.sort(compareSemverDesc);
        return {
          latestVersion: tags[0],
          latestCommitSha: null,
        };
      } catch {
        return { latestVersion: null, latestCommitSha: null };
      }
    }
    case "npm-global": {
      try {
        const { stdout } = await execFileAsync(
          resolveNpmExecutable(),
          ["view", "sidemesh", "version"],
          {
            encoding: "utf8",
            timeout: 10_000,
          },
        );
        return {
          latestVersion: stdout.trim() || null,
          latestCommitSha: null,
        };
      } catch {
        return { latestVersion: null, latestCommitSha: null };
      }
    }
    default:
      return { latestVersion: null, latestCommitSha: null };
  }
}

function isUpdateAvailable(options: {
  packageVersion: string;
  latestVersion: string | null;
  currentCommitSha: string | null;
  latestCommitSha: string | null;
  installType: InstallType;
  updateChannel: UpdateChannel;
}): boolean {
  if (options.installType === "git" && options.updateChannel === "bleeding-edge") {
    return (
      options.currentCommitSha !== null &&
      options.latestCommitSha !== null &&
      options.currentCommitSha !== options.latestCommitSha
    );
  }
  return (
    options.latestVersion !== null &&
    normalizeVersionLabel(options.latestVersion) !== options.packageVersion
  );
}

function normalizeVersionLabel(value: string): string {
  return value.replace(/^v/, "");
}

function compareSemverDesc(left: string, right: string): number {
  const lClean = normalizeVersionLabel(left).split("+")[0];
  const rClean = normalizeVersionLabel(right).split("+")[0];
  const [lCore, lPre = ""] = lClean.split("-");
  const [rCore, rPre = ""] = rClean.split("-");
  const lParts = lCore.split(".").map(Number);
  const rParts = rCore.split(".").map(Number);

  for (let i = 0; i < Math.max(lParts.length, rParts.length); i += 1) {
    const l = lParts[i] ?? 0;
    const r = rParts[i] ?? 0;
    if (Number.isNaN(l) || Number.isNaN(r)) {
      return right.localeCompare(left);
    }
    if (l !== r) {
      return r - l;
    }
  }

  if (lPre === "" && rPre !== "") return -1;
  if (rPre === "" && lPre !== "") return 1;
  if (lPre !== rPre) return rPre.localeCompare(lPre);
  return 0;
}

async function detectInstallType(packageRoot: string): Promise<InstallType> {
  try {
    await access(
      nodePath.join(packageRoot, ".git"),
      fsConstants.R_OK,
    );
    return "git";
  } catch {}

  try {
    const { stdout } = await execFileAsync(resolveNpmExecutable(), ["root", "-g"], {
      encoding: "utf8",
    });
    const globalRoot = stdout.trim();
    if (
      globalRoot &&
      (packageRoot === globalRoot ||
        packageRoot.startsWith(globalRoot + nodePath.sep))
    ) {
      return "npm-global";
    }
  } catch {}

  if (packageRoot.includes(`${nodePath.sep}node_modules${nodePath.sep}`)) {
    return "npm-local";
  }

  return "unknown";
}

async function isSystemdServiceActive(): Promise<boolean> {
  try {
    await execFileAsync("systemctl", [
      "is-active",
      "--quiet",
      "sidemesh.service",
    ]);
    return true;
  } catch {
    return false;
  }
}

function resolveNpmExecutable(): string {
  const npmBin = nodePath.join(
    nodePath.dirname(process.execPath),
    process.platform === "win32" ? "npm.cmd" : "npm",
  );
  return existsSync(npmBin) ? npmBin : "npm";
}

function shellQuote(value: string): string {
  if (/^[A-Za-z0-9_./:-]+$/.test(value)) {
    return value;
  }
  return `'${value.replaceAll("'", `'\\''`)}'`;
}
