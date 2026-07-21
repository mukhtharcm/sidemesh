import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { buildCodexInitializeParams } from "./codex-client.js";

describe("Codex app-server initialization", () => {
  it("identifies the installed Sidemesh client on the stable protocol surface", () => {
    const params = buildCodexInitializeParams("1.2.3");

    assert.deepEqual(params, {
      clientInfo: {
        name: "sidemesh_node",
        title: "Sidemesh Node",
        version: "1.2.3",
      },
      capabilities: {
        mcpServerOpenaiFormElicitation: true,
      },
    });
    assert.equal("experimentalApi" in params.capabilities, false);
  });
});
