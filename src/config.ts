import { hostname, homedir } from "node:os";
import { randomBytes } from "node:crypto";
import { join } from "node:path";

import type { NodeConfig } from "./types.js";

export function loadConfig(): NodeConfig {
  const token = process.env.SIDEMESH_TOKEN?.trim();
  return {
    label: process.env.SIDEMESH_LABEL?.trim() || hostname(),
    port: parseInteger(process.env.SIDEMESH_PORT, 8787),
    token: token || randomBytes(24).toString("hex"),
    tokenSource: token ? "env" : "generated",
    codexBin: process.env.SIDEMESH_CODEX_BIN?.trim() || "codex",
    stateDir:
      process.env.SIDEMESH_STATE_DIR?.trim() || join(homedir(), ".sidemesh"),
  };
}

function parseInteger(value: string | undefined, fallback: number): number {
  if (!value) {
    return fallback;
  }
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}
