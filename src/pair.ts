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
            addresses: addresses.map((address) => address.url),
          }),
  };
}

export function buildPairUrl(options: {
  label: string;
  baseUrl: string;
  token: string;
  addresses?: string[];
}): string {
  const params = new URLSearchParams({
    v: "2",
    label: options.label,
    baseUrl: options.baseUrl,
    token: options.token,
  });
  for (const address of options.addresses ?? []) {
    if (address !== options.baseUrl) {
      params.append("address", address);
    }
  }
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
      if (address.internal) {
        continue;
      }
      const isV4 = address.family === "IPv4";
      const isV6 = address.family === "IPv6";
      if (!isV4 && !isV6) {
        continue;
      }
      if (isV6 && isUnpairableV6(address.address)) {
        continue;
      }
      const kind =
        (isV4 && isTailscaleV4(address.address)) ||
        (isV6 && isTailscaleV6(address.address))
          ? "tailscale"
          : "lan";
      const host = isV6 ? `[${address.address}]` : address.address;
      add({
        label: kind === "tailscale" ? `${name} (tailnet)` : name,
        url: `http://${host}:${port}`,
        kind,
      });
    }
  }

  return [...results.values()];
}

export function isTailscaleV6(address: string): boolean {
  return address.toLowerCase().startsWith("fd7a:115c:a1e0:");
}

function isUnpairableV6(address: string): boolean {
  const normalized = address.toLowerCase().split("%")[0] ?? "";
  return (
    normalized === "::" ||
    normalized === "::1" ||
    normalized.startsWith("fe8") ||
    normalized.startsWith("fe9") ||
    normalized.startsWith("fea") ||
    normalized.startsWith("feb")
  );
}

function isTailscaleV4(address: string): boolean {
  const octets = address.split(".").map((part) => Number.parseInt(part, 10));
  if (octets.length !== 4 || octets.some((octet) => !Number.isFinite(octet))) {
    return false;
  }
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}
