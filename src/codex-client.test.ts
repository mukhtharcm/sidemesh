import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import { buildCodexInitializeParams, CodexBridge } from "./codex-client.js";

describe("Codex app-server initialization", () => {
  it("removes host authentication from the child and handles failed or closed processes", { timeout: 10000 }, async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "sidemesh-codex-bridge-"));
    const binary = path.join(directory, "fixture.mjs");
    const bridge = new CodexBridge(binary, { SIDEMESH_TOKEN: "test-host-token" });
    try {
      await writeFile(binary, `#!${process.execPath}\n` +
        `import {createInterface} from 'node:readline';\n` +
        `createInterface({input:process.stdin}).on('line', line => {\n` +
        ` const request=JSON.parse(line); if(request.id === undefined) return;\n` +
        ` process.stdout.write(JSON.stringify({id:request.id,result:{hasHostToken:!!process.env.SIDEMESH_TOKEN}})+'\\n');\n` +
        `});\n`, { mode: 0o700 });
      await bridge.start();
      assert.deepEqual(await bridge.request("inspect", {}), { hasHostToken: false });
      await bridge.close();
      await assert.rejects(bridge.request("inspect", {}), /not running/);
      const missing = new CodexBridge(path.join(directory, "missing"));
      await assert.rejects(missing.start(), /ENOENT/);
      await missing.close();
    } finally {
      await bridge.close();
      await rm(directory, { recursive: true, force: true });
    }
  });

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
