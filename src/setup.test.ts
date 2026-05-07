import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  normalizePromptTextValue,
  shouldPromptForCodexCommand,
  shouldPromptForUpdateChannel,
} from "./setup.js";

describe("normalizePromptTextValue", () => {
  it("falls back to the provided default when the submitted value is blank", () => {
    assert.equal(
      normalizePromptTextValue("   ", {
        defaultValue: "/Users/example/.sidemesh",
      }),
      "/Users/example/.sidemesh",
    );
  });

  it("keeps an intentionally blank value when fallback is disabled", () => {
    assert.equal(
      normalizePromptTextValue("", {
        defaultValue: "auto",
        fallbackToDefaultOnEmpty: false,
      }),
      "",
    );
  });

  it("produces a validator-safe non-blank value for required defaults", () => {
    const value = normalizePromptTextValue("   ", {
      defaultValue: "/Users/example/.sidemesh",
    });
    assert.equal(value.trim() ? undefined : "State directory cannot be empty.", undefined);
  });

  it("preserves non-blank input", () => {
    assert.equal(
      normalizePromptTextValue("/tmp/custom-state", {
        defaultValue: "/Users/example/.sidemesh",
      }),
      "/tmp/custom-state",
    );
  });
});

describe("shouldPromptForCodexCommand", () => {
  it("skips the prompt on first setup when the default codex binary is fine", () => {
    assert.equal(
      shouldPromptForCodexCommand(null, { advanced: false }),
      false,
    );
  });

  it("skips the prompt when the persisted command is still the default", () => {
    assert.equal(
      shouldPromptForCodexCommand("codex", { advanced: false }),
      false,
    );
  });

  it("keeps the prompt for custom command overrides", () => {
    assert.equal(
      shouldPromptForCodexCommand("/opt/bin/codex-preview", {
        advanced: false,
      }),
      true,
    );
  });

  it("keeps the prompt in advanced setup", () => {
    assert.equal(
      shouldPromptForCodexCommand(null, { advanced: true }),
      true,
    );
  });
});

describe("shouldPromptForUpdateChannel", () => {
  it("skips the prompt on first setup unless advanced mode is enabled", () => {
    assert.equal(
      shouldPromptForUpdateChannel(null, { advanced: false }),
      false,
    );
  });

  it("shows the prompt when editing an existing config", () => {
    assert.equal(
      shouldPromptForUpdateChannel(
        {
          version: 1,
          updateChannel: "stable",
          providers: [{ kind: "codex", bin: "codex" }],
        },
        { advanced: false },
      ),
      true,
    );
  });

  it("shows the prompt in advanced setup even on first run", () => {
    assert.equal(
      shouldPromptForUpdateChannel(null, { advanced: true }),
      true,
    );
  });
});
