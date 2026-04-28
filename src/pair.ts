import { hostname, networkInterfaces } from "node:os";

import type { NodeConfig } from "./types.js";
import { tokenFingerprint } from "./config-store.js";

export interface PairAddress {
  label: string;
  url: string;
  kind: "loopback" | "hostname" | "lan" | "tailscale";
}

export interface PairInfo {
  label: string;
  port: number;
  token: string;
  tokenFingerprint: string;
  configPath: string;
  addresses: PairAddress[];
}

export function buildPairInfo(config: NodeConfig): PairInfo {
  return {
    label: config.label,
    port: config.port,
    token: config.token,
    tokenFingerprint: tokenFingerprint(config.token),
    configPath: config.configPath,
    addresses: listPairAddresses(config.port),
  };
}

export function listPairAddresses(port: number): PairAddress[] {
  const results = new Map<string, PairAddress>();
  const add = (entry: PairAddress) => {
    if (!results.has(entry.url)) {
      results.set(entry.url, entry);
    }
  };

  add({ label: "localhost", url: `http://127.0.0.1:${port}`, kind: "loopback" });
  add({ label: "localhost", url: `http://localhost:${port}`, kind: "loopback" });

  const machineName = hostname().trim();
  if (machineName) {
    add({
      label: machineName,
      url: `http://${machineName}:${port}`,
      kind: "hostname",
    });
  }

  const interfaces = networkInterfaces();
  for (const [name, addresses] of Object.entries(interfaces)) {
    for (const address of addresses ?? []) {
      if (address.internal || address.family !== "IPv4") {
        continue;
      }
      const kind = isTailscaleV4(address.address) ? "tailscale" : "lan";
      add({
        label: kind === "tailscale" ? `${name} (tailnet)` : name,
        url: `http://${address.address}:${port}`,
        kind,
      });
    }
  }

  return [...results.values()];
}

function isTailscaleV4(address: string): boolean {
  const octets = address.split(".").map((part) => Number.parseInt(part, 10));
  if (octets.length !== 4 || octets.some((octet) => !Number.isFinite(octet))) {
    return false;
  }
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}
