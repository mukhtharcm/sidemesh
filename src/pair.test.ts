import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildPairInfo,
  buildPairUrl,
  selectPreferredPairAddress,
} from "./pair.js";
import type { NodeConfig } from "./types.js";

describe("pairing helpers", () => {
  it("builds pairing info with a redacted token fingerprint and base URLs", () => {
    const config: NodeConfig = {
      label: "mbp",
      port: 8787,
      token: "abcdefghijklmnopqrstuvwxyz123456",
      tokenSource: "file",
      provider: { kind: "codex", bin: "codex" },
      providers: [{ kind: "codex", bin: "codex" }],
      defaultProviderKind: "codex",
      stateDir: "/tmp/sidemesh",
      terminal: { enabled: false, shell: null, requirePty: false },
      portForwarding: { enabled: false, allowNonLoopbackTargets: false },
      configPath: "/tmp/sidemesh/config.json",
      configExists: true,
    };

    const info = buildPairInfo(config);
    assert.equal(info.label, "mbp");
    assert.equal(info.token, config.token);
    assert.equal(info.tokenFingerprint, "abcdef…3456");
    assert.ok(info.preferredAddress);
    assert.ok(info.pairUrl?.startsWith("sidemesh://pair?"));
    assert.ok(
      info.addresses.some((entry) => entry.url === "http://127.0.0.1:8787"),
    );
  });

  it("builds sidemesh pairing URLs with label, base URL, and token", () => {
    const pairUrl = buildPairUrl({
      label: "MacBook",
      baseUrl: "http://100.80.10.1:8899",
      token: "secret-token",
    });

    const parsed = new URL(pairUrl);
    assert.equal(parsed.protocol, "sidemesh:");
    assert.equal(parsed.hostname, "pair");
    assert.equal(parsed.searchParams.get("v"), "1");
    assert.equal(parsed.searchParams.get("label"), "MacBook");
    assert.equal(
      parsed.searchParams.get("baseUrl"),
      "http://100.80.10.1:8899",
    );
    assert.equal(parsed.searchParams.get("token"), "secret-token");
  });

  it("prefers Tailscale addresses for QR pairing", () => {
    const selected = selectPreferredPairAddress([
      { label: "lo", url: "http://127.0.0.1:8899", kind: "loopback" },
      { label: "en0", url: "http://192.168.1.2:8899", kind: "lan" },
      {
        label: "tailscale0",
        url: "http://100.80.1.2:8899",
        kind: "tailscale",
      },
    ]);

    assert.equal(selected?.kind, "tailscale");
  });
});
