import { execFile } from "node:child_process";
import { promisify } from "node:util";

import type {
  GitInfoSummary,
  SessionGitDiff,
  SessionGitFileStatus,
  SessionGitStatus,
} from "./types.js";

const execFileAsync = promisify(execFile);
const GIT_TIMEOUT_MS = 5_000;
const STATUS_MAX_BUFFER = 768 * 1024;
export const GIT_DIFF_MAX_CHARS = 240_000;
const DIFF_MAX_BUFFER = 2 * 1024 * 1024;
const MAX_STATUS_FILES = 200;

type GitDiffKind = SessionGitDiff["kind"];

interface GitRunOptions {
  allowExitCodes?: number[];
  maxBuffer?: number;
}

type ExecFileError = Error & {
  code?: string | number;
  stdout?: string | Buffer;
  stderr?: string | Buffer;
};

interface ParsedStatus {
  branch: string | null;
  upstream: string | null;
  ahead: number;
  behind: number;
  staged: number;
  unstaged: number;
  untracked: number;
  files: SessionGitFileStatus[];
  filesTruncated: boolean;
}

export function sanitizeGitUrl(value: string | null | undefined): string | null {
  const trimmed = (value ?? "").trim();
  if (!trimmed) {
    return null;
  }

  if (/^https?:\/\//i.test(trimmed)) {
    try {
      const url = new URL(trimmed);
      url.username = "";
      url.password = "";
      return url.toString();
    } catch {
      return trimmed.replace(/\/\/[^/@]+@/, "//");
    }
  }

  return trimmed.replace(/\/\/[^/@]+@/, "//");
}

export async function readGitStatus(
  cwd: string,
  persisted: GitInfoSummary | null,
): Promise<SessionGitStatus> {
  const refreshedAt = Date.now();
  const fallback = (): SessionGitStatus => ({
    isRepo: false,
    cwd,
    repoRoot: null,
    branch: persisted?.branch ?? null,
    sha: persisted?.sha ?? null,
    shortSha: shortSha(persisted?.sha ?? null),
    upstream: null,
    ahead: 0,
    behind: 0,
    dirty: false,
    staged: 0,
    unstaged: 0,
    untracked: 0,
    changed: 0,
    originUrl: sanitizeGitUrl(persisted?.originUrl),
    files: [],
    filesTruncated: false,
    refreshedAt,
    error: null,
  });

  let repoRoot: string;
  try {
    repoRoot = (await runGit(cwd, ["rev-parse", "--show-toplevel"])).stdout.trim();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("not a git repository")) {
      return fallback();
    }
    return { ...fallback(), error: message };
  }

  const [statusResult, branchResult, shaResult, originResult] = await Promise.allSettled([
    runGit(cwd, ["status", "--porcelain=v1", "--branch", "--untracked-files=all"], {
      maxBuffer: STATUS_MAX_BUFFER,
    }),
    runGit(cwd, ["branch", "--show-current"]),
    runGit(cwd, ["rev-parse", "HEAD"]),
    runGit(cwd, ["remote", "get-url", "origin"]),
  ]);

  const parsed = parsePorcelainStatus(
    statusResult.status === "fulfilled" ? statusResult.value.stdout : "",
  );
  const sha =
    shaResult.status === "fulfilled"
      ? emptyToNull(shaResult.value.stdout.trim())
      : persisted?.sha ?? null;
  const branch =
    branchResult.status === "fulfilled"
      ? emptyToNull(branchResult.value.stdout.trim()) ?? parsed.branch ?? persisted?.branch ?? null
      : parsed.branch ?? persisted?.branch ?? null;
  const originUrl =
    originResult.status === "fulfilled"
      ? sanitizeGitUrl(originResult.value.stdout)
      : sanitizeGitUrl(persisted?.originUrl);
  const changed = parsed.staged + parsed.unstaged + parsed.untracked;

  return {
    isRepo: true,
    cwd,
    repoRoot,
    branch,
    sha,
    shortSha: shortSha(sha),
    upstream: parsed.upstream,
    ahead: parsed.ahead,
    behind: parsed.behind,
    dirty: changed > 0,
    staged: parsed.staged,
    unstaged: parsed.unstaged,
    untracked: parsed.untracked,
    changed,
    originUrl,
    files: parsed.files,
    filesTruncated: parsed.filesTruncated,
    refreshedAt,
    error: statusResult.status === "rejected" ? statusError(statusResult.reason) : null,
  };
}

export async function readGitDiff(cwd: string, kind: Exclude<GitDiffKind, "remote">): Promise<SessionGitDiff> {
  const args = gitDiffArgs(kind);
  const result = await runGit(cwd, args, {
    allowExitCodes: [0, 1],
    maxBuffer: DIFF_MAX_BUFFER,
  });
  return buildGitDiff(kind, result.stdout, null);
}

export function buildGitDiff(kind: GitDiffKind, diff: string, baseSha: string | null): SessionGitDiff {
  const capped = capText(diff, GIT_DIFF_MAX_CHARS);
  return {
    kind,
    diff: capped.text,
    baseSha,
    truncated: capped.truncated,
    maxChars: GIT_DIFF_MAX_CHARS,
  };
}

function gitDiffArgs(kind: Exclude<GitDiffKind, "remote">): string[] {
  if (kind === "staged") {
    return ["diff", "--cached", "--no-ext-diff", "--no-textconv"];
  }
  return ["diff", "--no-ext-diff", "--no-textconv"];
}

async function runGit(
  cwd: string,
  args: string[],
  options: GitRunOptions = {},
): Promise<{ stdout: string; stderr: string }> {
  try {
    const { stdout, stderr } = await execFileAsync("git", args, {
      cwd,
      timeout: GIT_TIMEOUT_MS,
      maxBuffer: options.maxBuffer ?? STATUS_MAX_BUFFER,
      env: {
        ...process.env,
        GIT_OPTIONAL_LOCKS: "0",
        LC_ALL: "C",
      },
      windowsHide: true,
    });
    return { stdout: bufferToString(stdout), stderr: bufferToString(stderr) };
  } catch (error) {
    const err = error as ExecFileError;
    const code = typeof err.code === "number" ? err.code : null;
    if (code !== null && options.allowExitCodes?.includes(code)) {
      return {
        stdout: bufferToString(err.stdout),
        stderr: bufferToString(err.stderr),
      };
    }
    const stderr = bufferToString(err.stderr).trim();
    throw new Error(stderr || err.message || `git ${args.join(" ")} failed`);
  }
}

function parsePorcelainStatus(stdout: string): ParsedStatus {
  const parsed: ParsedStatus = {
    branch: null,
    upstream: null,
    ahead: 0,
    behind: 0,
    staged: 0,
    unstaged: 0,
    untracked: 0,
    files: [],
    filesTruncated: false,
  };

  for (const line of stdout.split(/\r?\n/)) {
    if (!line) {
      continue;
    }
    if (line.startsWith("## ")) {
      applyBranchLine(parsed, line.slice(3));
      continue;
    }

    const status = line.slice(0, 2);
    const pathPart = line.length > 3 ? line.slice(3) : "";
    if (status === "??") {
      parsed.untracked += 1;
    } else {
      if (status[0] && status[0] !== " ") {
        parsed.staged += 1;
      }
      if (status[1] && status[1] !== " ") {
        parsed.unstaged += 1;
      }
    }

    if (parsed.files.length < MAX_STATUS_FILES) {
      parsed.files.push({
        ...parseStatusPath(pathPart),
        indexStatus: status[0] || " ",
        worktreeStatus: status[1] || " ",
      });
    } else {
      parsed.filesTruncated = true;
    }
  }

  return parsed;
}

function applyBranchLine(parsed: ParsedStatus, line: string): void {
  const bracket = line.match(/\[(?<state>[^\]]+)\]\s*$/);
  const branchPart = bracket ? line.slice(0, bracket.index).trim() : line.trim();
  const state = bracket?.groups?.state ?? "";
  const ahead = state.match(/ahead (?<count>\d+)/);
  const behind = state.match(/behind (?<count>\d+)/);
  parsed.ahead = ahead?.groups?.count ? Number(ahead.groups.count) : 0;
  parsed.behind = behind?.groups?.count ? Number(behind.groups.count) : 0;

  if (branchPart.startsWith("No commits yet on ")) {
    parsed.branch = branchPart.slice("No commits yet on ".length).trim() || null;
    return;
  }
  if (branchPart === "HEAD (no branch)") {
    parsed.branch = null;
    return;
  }

  const [branch, upstream] = branchPart.split("...");
  parsed.branch = emptyToNull(branch);
  parsed.upstream = emptyToNull(upstream);
}

function parseStatusPath(value: string): { path: string; originalPath: string | null } {
  const renameParts = value.split(" -> ");
  if (renameParts.length >= 2) {
    return {
      originalPath: cleanGitPath(renameParts[0]),
      path: cleanGitPath(renameParts.slice(1).join(" -> ")),
    };
  }
  return { path: cleanGitPath(value), originalPath: null };
}

function cleanGitPath(value: string): string {
  const trimmed = value.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function capText(text: string, maxChars: number): { text: string; truncated: boolean } {
  if (text.length <= maxChars) {
    return { text, truncated: false };
  }
  return {
    text: `${text.slice(0, maxChars)}\n\n... diff truncated after ${maxChars} characters ...\n`,
    truncated: true,
  };
}

function statusError(reason: unknown): string {
  return reason instanceof Error ? reason.message : String(reason);
}

function shortSha(value: string | null): string | null {
  return value ? value.slice(0, 12) : null;
}

function emptyToNull(value: string | null | undefined): string | null {
  const trimmed = (value ?? "").trim();
  return trimmed ? trimmed : null;
}

function bufferToString(value: string | Buffer | undefined): string {
  if (Buffer.isBuffer(value)) {
    return value.toString("utf8");
  }
  return value ?? "";
}
