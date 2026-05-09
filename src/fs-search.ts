import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";

import ignore from "ignore";

export interface FsSearchResult {
  path: string;
  name: string;
  isDirectory: boolean;
  score: number;
}

interface SearchEntry {
  path: string;
  name: string;
  isDirectory: boolean;
}

interface CacheEntry {
  entries: SearchEntry[];
  expiresAt: number;
}

const CACHE_TTL_MS = 30_000;
const MAX_RESULTS = 50;
const MAX_SCANNED = 100_000;

const searchCache = new Map<string, CacheEntry>();

export function clearFsSearchCache(): void {
  searchCache.clear();
}

export async function searchFiles(
  query: string,
  roots: string[],
  options: { limit?: number } = {},
): Promise<FsSearchResult[]> {
  const normalizedQuery = query.trim();
  if (normalizedQuery.length === 0) {
    return [];
  }

  const limit = options.limit ?? MAX_RESULTS;
  const allEntries: SearchEntry[] = [];

  for (const root of roots) {
    const entries = await walkWithCache(root);
    allEntries.push(...entries);
  }

  const scored = allEntries
    .map((entry) => ({
      path: entry.isDirectory ? `${entry.path}/` : entry.path,
      name: entry.name,
      isDirectory: entry.isDirectory,
      score: fuzzyScore(normalizedQuery, entry.path),
    }))
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);

  return scored;
}

async function walkWithCache(root: string): Promise<SearchEntry[]> {
  const now = Date.now();
  const cached = searchCache.get(root);
  if (cached && cached.expiresAt > now) {
    return cached.entries;
  }

  const entries = await walkDirectory(root);
  searchCache.set(root, { entries, expiresAt: now + CACHE_TTL_MS });
  return entries;
}

async function walkDirectory(root: string): Promise<SearchEntry[]> {
  const results: SearchEntry[] = [];
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
        results.push({
          path: relative,
          name: entry.name,
          isDirectory: true,
        });
        const subIg = await loadGitignore(path.join(dir, entry.name), ig);
        stack.push({ dir: path.join(dir, entry.name), ig: subIg });
      } else if (entry.isFile()) {
        results.push({
          path: relative,
          name: entry.name,
          isDirectory: false,
        });
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
