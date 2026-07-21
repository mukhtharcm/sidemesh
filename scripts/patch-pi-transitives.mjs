import { access, cp, mkdir, readFile, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const packageRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const piNodeModules = path.join(
  packageRoot,
  "node_modules",
  "@earendil-works",
  "pi-coding-agent",
  "node_modules",
);
const piManifest = JSON.parse(
  await readFile(path.join(piNodeModules, "..", "package.json"), "utf8"),
);
if (piManifest.version !== "0.80.3") {
  throw new Error(
    `Pi transitive remediation requires pi-coding-agent@0.80.3, found ${piManifest.version ?? "unknown"}`,
  );
}

// Pi ships an npm-shrinkwrap that currently pins these vulnerable versions,
// so root-level npm overrides cannot replace them. Keep the replacements as
// exact root dependencies and copy only those audited packages after install.
const replacements = [
  { name: "brace-expansion", version: "5.0.7" },
  { name: "protobufjs", version: "7.6.5" },
];

for (const replacement of replacements) {
  const source = path.join(packageRoot, "node_modules", replacement.name);
  const target = path.join(piNodeModules, replacement.name);
  await access(source);
  await mkdir(piNodeModules, { recursive: true });
  await rm(target, { recursive: true, force: true });
  await cp(source, target, { recursive: true });

  const manifest = JSON.parse(
    await readFile(path.join(target, "package.json"), "utf8"),
  );
  if (manifest.version !== replacement.version) {
    throw new Error(
      `Expected ${replacement.name}@${replacement.version}, found ${manifest.version ?? "unknown"}`,
    );
  }
}
