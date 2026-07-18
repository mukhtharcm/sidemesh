import { realpath, stat } from "node:fs/promises";
import path from "node:path";

import type { SessionSummary } from "./types.js";

/**
 * Resolve a requested path to its canonical form and verify it lives under
 * one of the known workspace roots.
 *
 * - Requires absolute paths.
 * - Uses realpath so symlink tricks can't escape the workspace.
 * - For writes / creates, the path itself may not exist yet; pass
 *   `allowMissing: true` and we'll canonicalize the nearest existing
 *   ancestor instead.
 */
export async function resolveWorkspacePath(
  input: string,
  workspaceRoots: string[],
  options: { allowMissing?: boolean } = {},
): Promise<string> {
  if (!input || typeof input !== "string") {
    throw new WorkspaceAccessError("path is required");
  }
  if (!path.isAbsolute(input)) {
    throw new WorkspaceAccessError("path must be absolute");
  }

  const canonicalRoots = await canonicalizeRoots(workspaceRoots);
  if (canonicalRoots.length === 0) {
    throw new WorkspaceAccessError("no workspace roots available");
  }

  let canonical: string;
  try {
    canonical = await realpath(input);
  } catch (error) {
    if (!options.allowMissing) {
      throw new WorkspaceAccessError(
        `cannot resolve path: ${stringifyError(error)}`,
      );
    }
    // Walk up to the nearest existing ancestor and canonicalize that, then
    // append the missing tail. This lets us allow writes of new files inside
    // a trusted directory without allowing writes outside it.
    canonical = await canonicalizeWithMissingTail(input);
  }

  if (!isUnderAny(canonical, canonicalRoots)) {
    throw new WorkspaceAccessError("path is outside any workspace");
  }
  return canonical;
}

export class WorkspaceAccessError extends Error {
  public readonly status: number;
  public constructor(message: string, status = 403) {
    super(message);
    this.name = "WorkspaceAccessError";
    this.status = status;
  }
}

async function canonicalizeRoots(roots: string[]): Promise<string[]> {
  const resolved = await Promise.all(
    roots
      .filter(
        (root): root is string => typeof root === "string" && root.length > 0,
      )
      .map(async (root) => {
        try {
          const real = await realpath(root);
          const info = await stat(real);
          return info.isDirectory() ? real : null;
        } catch {
          return null;
        }
      }),
  );
  return [...new Set(resolved.filter((root): root is string => !!root))];
}

async function canonicalizeWithMissingTail(target: string): Promise<string> {
  let current = target;
  const segments: string[] = [];
  while (current.length > 1) {
    try {
      const real = await realpath(current);
      return segments.length === 0
        ? real
        : path.join(real, ...segments.reverse());
    } catch {
      segments.push(path.basename(current));
      const parent = path.dirname(current);
      if (parent === current) break;
      current = parent;
    }
  }
  throw new WorkspaceAccessError(`cannot resolve any ancestor of ${target}`);
}

function isUnderAny(target: string, roots: string[]): boolean {
  for (const root of roots) {
    if (target === root) return true;
    const withSep = root.endsWith(path.sep) ? root : root + path.sep;
    if (target.startsWith(withSep)) return true;
  }
  return false;
}

function stringifyError(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

/**
 * Collect explicitly configured roots plus the distinct cwds of known sessions.
 * No ambient directory is trusted implicitly: a fresh daemon without configured
 * roots or sessions exposes no host filesystem paths.
 */
export async function collectWorkspaceRoots(
  listSessions: () => Promise<SessionSummary[]>,
  configuredRoots: string[] = [],
): Promise<string[]> {
  try {
    const sessions = await listSessions();
    const roots = new Set<string>(configuredRoots);
    for (const session of sessions) {
      if (session.cwd) roots.add(session.cwd);
    }
    return [...roots];
  } catch {
    return [...new Set(configuredRoots)];
  }
}
