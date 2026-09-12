import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

// Generate only the official types used by the adapter, in one module.
const binary = process.argv[2] ?? "codex";
const version = execFileSync(binary, ["--version"], { encoding: "utf8" }).trim();
const directory = await mkdtemp(path.join(tmpdir(), "sidemesh-codex-types-"));
try {
  execFileSync(binary, ["app-server", "generate-ts", "--experimental", "--out", directory]);
  const modules = new Map();
  async function collect(file) {
    if (modules.has(file)) return;
    const source = await readFile(file, "utf8");
    modules.set(file, source);
    for (const match of source.matchAll(/^import type .* from "([^"]+)";$/gm)) {
      await collect(path.resolve(path.dirname(file), `${match[1]}.ts`));
    }
  }
  for (const root of ["ThreadReadResponse", "TurnStartParams", "TurnSteerParams"]) {
    await collect(path.join(directory, "v2", `${root}.ts`));
  }
  const output = [...modules].map(([file, source]) =>
    `// ${path.relative(directory, file)}\n` + source
      .replace(/^\/\/ GENERATED CODE!.*\n/gm, "")
      .replace(/^\/\/ This file was generated.*\n/gm, "")
      .replace(/^import type .*\n/gm, "").trim(),
  ).join("\n\n");
  await writeFile(new URL("../src/codex-protocol.ts", import.meta.url),
    `// Generated from ${version}; do not edit.\n` +
    `// Run: node scripts/generate-codex-protocol.mjs <codex-binary>\n` +
    `// Upstream: https://github.com/openai/codex (Apache-2.0).\n\n${output}\n`);
} finally {
  await rm(directory, { recursive: true, force: true });
}
