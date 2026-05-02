import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";

import ignore from "ignore";

export interface FsSearchResult {
  path: string;
  name: string;
  isDirectory: boolean;
  score: number;
}

interface CacheEntry {
  entries: string[];
  expiresAt: number;
}

const CACHE_TTL_MS = 30_000;
const MAX_RESULTS = 50;
const MAX_SCANNED = 100_000;

const searchCache = new Map<string, CacheEntry>();

export async function searchFiles(
  query: string,
  roots: string[],
  options: { limit?: number } = {},
): Promise<FsSearchResult[]> {
  const limit = options.limit ?? MAX_RESULTS;
  const allEntries: Array<{ path: string; name: string; isDirectory: boolean }> = [];

  for (const root of roots) {
    const entries = await walkWithCache(root);
    for (const entry of entries) {
      const relative = entry;
      const name = path.basename(entry);
      const isDirectory = entry.endsWith("/");
      const displayPath = isDirectory ? relative + "/" : relative;
      allEntries.push({ path: displayPath, name, isDirectory });
    }
  }

  const scored = allEntries
    .map((entry) => ({
      ...entry,
      score: fuzzyScore(query, entry.path),
    }))
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);

  return scored;
}

async function walkWithCache(root: string): Promise<string[]> {
  const now = Date.now();
  const cached = searchCache.get(root);
  if (cached && cached.expiresAt > now) {
    return cached.entries;
  }

  const entries = await walkDirectory(root);
  searchCache.set(root, { entries, expiresAt: now + CACHE_TTL_MS });
  return entries;
}

async function walkDirectory(root: string): Promise<string[]> {
  const results: string[] = [];
  const stack: Array<{ dir: string; ig: ignore.Ignore }> = [];

  const rootIg = await loadGitignore(root);
  stack.push({ dir: root, ig: rootIg });

  while (stack.length > 0 && results.length < MAX_SCANNED) {
    const { dir, ig } = stack.pop()!;

    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const relative = path.relative(root, path.join(dir, entry.name));
      if (ig.ignores(relative)) continue;

      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name === ".git") continue;
        const subIg = await loadGitignore(path.join(dir, entry.name), ig);
        stack.push({ dir: path.join(dir, entry.name), ig: subIg });
      } else if (entry.isFile()) {
        results.push(relative);
      }
    }
  }

  return results;
}

async function loadGitignore(
  dir: string,
  parent?: ignore.Ignore,
): Promise<ignore.Ignore> {
  const ig = ignore({ allowRelativePaths: true });
  if (parent) {
    ig.add(parent);
  }

  try {
    const content = await readFile(path.join(dir, ".gitignore"), "utf8");
    ig.add(content);
  } catch {
    // .gitignore may not exist
  }

  return ig;
}

export function fuzzyScore(query: string, target: string): number {
  const q = query.toLowerCase();
  const t = target.toLowerCase();
  const ql = q.length;
  const tl = t.length;

  if (ql === 0) return 1;
  if (tl === 0) return 0;

  let qi = 0;
  let ti = 0;
  let score = 0;
  let consecutive = 0;
  let lastMatch = -1;

  while (qi < ql && ti < tl) {
    if (q[qi] === t[ti]) {
      score += 10;
      if (lastMatch === ti - 1) {
        consecutive++;
        score += consecutive * 5;
      } else {
        consecutive = 0;
      }
      if (ti === 0 || t[ti - 1] === "/" || t[ti - 1] === "\\" || t[ti - 1] === "_" || t[ti - 1] === "-") {
        score += 15;
      }
      lastMatch = ti;
      qi++;
    }
    ti++;
  }

  if (qi < ql) return 0;

  score -= (tl - ql) * 2;

  return Math.max(0, score);
}
