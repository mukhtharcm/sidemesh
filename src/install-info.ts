import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { fileURLToPath } from "node:url";
import nodePath from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type InstallType = "git" | "npm-global" | "npm-local" | "unknown";

export interface InstallInfo {
  packageVersion: string;
  latestVersion: string | null;
  updateAvailable: boolean;
  packageRoot: string;
  installType: InstallType;
  updateSupported: boolean;
  updateCommand: string | null;
  isManagedService: boolean;
  serviceName: string | null;
}

export async function detectInstallInfo(
  packageRootOverride?: string,
): Promise<InstallInfo> {
  const packageRoot = packageRootOverride ?? resolvePackageRoot();
  const packageVersion = await readPackageVersion(packageRoot);
  const installType = await detectInstallType(packageRoot);
  const isManagedService = await isSystemdServiceActive().catch(() => false);
  const serviceName = isManagedService ? "sidemesh" : null;

  let updateSupported = false;
  let updateCommand: string | null = null;

  switch (installType) {
    case "git": {
      updateSupported = true;
      updateCommand = "git pull && npm install && npm run build";
      break;
    }
    case "npm-global": {
      updateSupported = true;
      updateCommand = "npm update -g sidemesh";
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

  const latestVersion = updateSupported
    ? await checkLatestVersion(packageRoot, installType)
    : null;
  const updateAvailable =
    latestVersion !== null && latestVersion !== packageVersion;

  return {
    packageVersion,
    latestVersion,
    updateAvailable,
    packageRoot,
    installType,
    updateSupported,
    updateCommand,
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

async function checkLatestVersion(
  packageRoot: string,
  installType: InstallType,
): Promise<string | null> {
  switch (installType) {
    case "git": {
      try {
        const { stdout } = await execFileAsync(
          "git",
          ["ls-remote", "--tags", "origin"],
          { cwd: packageRoot, encoding: "utf8", timeout: 10_000 },
        );
        const tags = stdout
          .split("\n")
          .map((line) => {
            const match = /refs\/tags\/(.+?)\s*$/.exec(line);
            return match?.[1]?.replace(/\^{}$/, "") ?? null;
          })
          .filter((t): t is string => t !== null && t.startsWith("v"));
        if (tags.length === 0) return null;
        tags.sort(compareSemverDesc);
        return tags[0];
      } catch {
        return null;
      }
    }
    case "npm-global": {
      try {
        const { stdout } = await execFileAsync("npm", ["view", "sidemesh", "version"], {
          encoding: "utf8",
          timeout: 10_000,
        });
        return stdout.trim() || null;
      } catch {
        return null;
      }
    }
    default:
      return null;
  }
}

function compareSemverDesc(left: string, right: string): number {
  // Parse semver: major.minor.patch[-prerelease][+build]
  const lClean = left.replace(/^v/, "").split("+")[0];
  const rClean = right.replace(/^v/, "").split("+")[0];
  const [lCore, lPre = ""] = lClean.split("-");
  const [rCore, rPre = ""] = rClean.split("-");
  const lParts = lCore.split(".").map(Number);
  const rParts = rCore.split(".").map(Number);

  for (let i = 0; i < Math.max(lParts.length, rParts.length); i++) {
    const l = lParts[i] ?? 0;
    const r = rParts[i] ?? 0;
    if (Number.isNaN(l) || Number.isNaN(r)) {
      return right.localeCompare(left);
    }
    if (l !== r) return r - l;
  }

  // No pre-release > has pre-release (e.g. 1.0.0 > 1.0.0-beta)
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
    const { stdout } = await execFileAsync("npm", ["root", "-g"], {
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
