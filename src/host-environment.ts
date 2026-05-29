import { accessSync, constants as fsConstants } from "node:fs";
import { userInfo } from "node:os";
import nodePath from "node:path";

export type HostEnvironment = Record<string, string | undefined>;

export function isTermuxEnvironment(
  env: HostEnvironment = process.env,
): boolean {
  const prefix = env.PREFIX?.trim();
  return (
    Boolean(env.TERMUX_VERSION?.trim()) ||
    Boolean(env.TERMUX_APP_PID?.trim()) ||
    Boolean(prefix?.startsWith("/data/data/com.termux/files/usr"))
  );
}

export function supportsSystemdServiceManagement(
  env: HostEnvironment = process.env,
): boolean {
  return (
    process.platform === "linux" &&
    !isTermuxEnvironment(env) &&
    resolveExecutableSync("systemctl", env) !== null
  );
}

export function resolvePreferredShell(
  env: HostEnvironment = process.env,
): string | null {
  const candidates = dedupe([
    env.SHELL?.trim(),
    readUserShell(),
    ...(process.platform === "win32"
      ? ["powershell.exe", "cmd.exe"]
      : [
          ...(isTermuxEnvironment(env)
            ? [
                "/data/data/com.termux/files/usr/bin/bash",
                "/data/data/com.termux/files/usr/bin/sh",
              ]
            : []),
          "/bin/bash",
          "/usr/bin/bash",
          "/bin/zsh",
          "/usr/bin/zsh",
          "/bin/fish",
          "/usr/bin/fish",
          "/bin/sh",
          "/usr/bin/sh",
          "/system/bin/sh",
          "bash",
          "zsh",
          "fish",
          "sh",
          "ksh",
          "dash",
          "ash",
        ]),
  ]);
  for (const candidate of candidates) {
    const resolved = resolveExecutableSync(candidate, env);
    if (resolved) {
      return resolved;
    }
  }
  return null;
}

export function resolveDefaultShell(
  env: HostEnvironment = process.env,
): string {
  return (
    resolvePreferredShell(env) ??
    (process.platform === "win32" ? "powershell.exe" : "sh")
  );
}

export function resolveExecutableSync(
  command: string | null | undefined,
  env: HostEnvironment = process.env,
): string | null {
  const trimmed = command?.trim();
  if (!trimmed) {
    return null;
  }

  if (isPathLike(trimmed)) {
    const absolute = nodePath.resolve(trimmed);
    return isExecutable(absolute) ? absolute : null;
  }

  const pathValue =
    env.PATH ??
    env.Path ??
    (env === process.env ? process.env.PATH ?? "" : "");
  for (const dir of pathValue.split(nodePath.delimiter)) {
    if (!dir) {
      continue;
    }
    const candidate = nodePath.join(dir, trimmed);
    if (isExecutable(candidate)) {
      return candidate;
    }
    if (process.platform === "win32") {
      for (const extension of [".exe", ".cmd", ".bat"]) {
        if (isExecutable(candidate + extension)) {
          return candidate + extension;
        }
      }
    }
  }
  return null;
}

export function shellLoginArgs(shellPath: string): string[] {
  const name = nodePath.basename(shellPath).toLowerCase();
  if (["bash", "zsh", "fish", "ksh"].includes(name)) {
    return ["-l"];
  }
  return [];
}

export function shellCaptureArgs(shellPath: string): string[] | null {
  const name = nodePath.basename(shellPath).toLowerCase();
  switch (name) {
    case "zsh":
    case "bash":
    case "ksh":
    case "fish":
      return ["-l", "-i", "-c"];
    case "sh":
    case "dash":
    case "ash":
      return ["-i", "-c"];
    default:
      return null;
  }
}

export function shellNeedsInteractiveFlag(shellPath: string): boolean {
  const name = nodePath.basename(shellPath).toLowerCase();
  return ["bash", "zsh", "fish", "ksh", "sh", "dash", "ash"].includes(name);
}

function dedupe(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    const trimmed = value?.trim();
    if (!trimmed || seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    result.push(trimmed);
  }
  return result;
}

function readUserShell(): string | null {
  try {
    const shell = userInfo().shell?.trim();
    return shell || null;
  } catch {
    return null;
  }
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function isPathLike(value: string): boolean {
  return value.includes("/") || value.includes("\\");
}
