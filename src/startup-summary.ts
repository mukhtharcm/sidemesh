import type { NodeConfig } from "./types.js";
import { buildPairInfo } from "./pair.js";

export function startupSummaryLines(options: {
  config: NodeConfig;
  providerDisplayName: string;
  providerKinds: string[];
}): string[] {
  const pairInfo = buildPairInfo(options.config);
  const preferredAddress =
    pairInfo.addresses.find((entry) => entry.kind === "tailscale") ??
    pairInfo.addresses.find((entry) => entry.kind === "lan") ??
    pairInfo.addresses[0];
  return [
    `[sidemesh] ${options.config.label} listening on port ${options.config.port}`,
    `[sidemesh] config: ${options.config.configPath}${
      options.config.configExists ? "" : " (not yet persisted)"
    }`,
    `[sidemesh] providers: ${options.providerDisplayName} (${options.providerKinds.join(", ")})`,
    `[sidemesh] terminal: ${options.config.terminal.enabled ? "enabled" : "disabled"}`,
    `[sidemesh] token (${options.config.tokenSource}): ${pairInfo.tokenFingerprint}`,
    preferredAddress
      ? `[sidemesh] pair with: ${preferredAddress.url} (run \`sidemesh pair\` for the full token)`
      : "[sidemesh] run `sidemesh pair` to view pairing details",
  ];
}
