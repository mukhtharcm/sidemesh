import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  TerminalError,
  TerminalRegistry,
  terminalEnabledFromEnv,
} from "./terminal.js";

describe("terminal configuration", () => {
  it("keeps terminal access opt-in", () => {
    assert.equal(terminalEnabledFromEnv({}), false);
    assert.equal(terminalEnabledFromEnv({ SIDEMESH_TERMINAL: "0" }), false);
    assert.equal(terminalEnabledFromEnv({ SIDEMESH_TERMINAL: "1" }), true);
    assert.equal(
      terminalEnabledFromEnv({ SIDEMESH_ENABLE_TERMINAL: "true" }),
      true,
    );
  });

  it("rejects terminal creation when disabled", async () => {
    const registry = new TerminalRegistry({
      enabled: false,
      resolveCwd: async (cwd) => cwd,
    });

    await assert.rejects(
      registry.create({ cwd: "/tmp" }),
      (error) =>
        error instanceof TerminalError &&
        error.status === 403 &&
        error.message === "terminal access is disabled",
    );
  });
});
