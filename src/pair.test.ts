import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildPairInfo } from "./pair.js";
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
      configPath: "/tmp/sidemesh/config.json",
      configExists: true,
    };

    const info = buildPairInfo(config);
    assert.equal(info.label, "mbp");
    assert.equal(info.token, config.token);
    assert.equal(info.tokenFingerprint, "abcdef…3456");
    assert.ok(
      info.addresses.some((entry) => entry.url === "http://127.0.0.1:8787"),
    );
  });
});
