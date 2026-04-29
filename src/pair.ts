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
  preferredAddress: PairAddress | null;
  pairUrl: string | null;
}

export function buildPairInfo(config: NodeConfig): PairInfo {
  const addresses = listPairAddresses(config.port);
  const preferredAddress = selectPreferredPairAddress(addresses);
  return {
    label: config.label,
    port: config.port,
    token: config.token,
    tokenFingerprint: tokenFingerprint(config.token),
    configPath: config.configPath,
    addresses,
    preferredAddress,
    pairUrl:
      preferredAddress == null
        ? null
        : buildPairUrl({
            label: config.label,
            baseUrl: preferredAddress.url,
            token: config.token,
          }),
  };
}

export function buildPairUrl(options: {
  label: string;
  baseUrl: string;
  token: string;
}): string {
  const params = new URLSearchParams({
    v: "1",
    label: options.label,
    baseUrl: options.baseUrl,
    token: options.token,
  });
  return `sidemesh://pair?${params.toString()}`;
}

export function selectPreferredPairAddress(
  addresses: PairAddress[],
): PairAddress | null {
  for (const kind of ["tailscale", "lan", "hostname", "loopback"] as const) {
    const match = addresses.find((entry) => entry.kind === kind);
    if (match != null) return match;
  }
  return null;
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
