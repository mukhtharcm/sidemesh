import { describe, it } from "node:test";
import assert from "node:assert/strict";

import { buildCodexInitializeParams } from "./codex-client.js";

describe("Codex app-server initialization", () => {
  it("opts into the permission-profile API while identifying Sidemesh", () => {
    const params = buildCodexInitializeParams("1.2.3");

    assert.deepEqual(params, {
      clientInfo: {
        name: "sidemesh_node",
        title: "Sidemesh Node",
        version: "1.2.3",
      },
      capabilities: {
        experimentalApi: true,
        mcpServerOpenaiFormElicitation: true,
      },
    });
  });
});
