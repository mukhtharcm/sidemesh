import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { normalizePromptTextValue } from "./setup.js";

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

  it("preserves non-blank input", () => {
    assert.equal(
      normalizePromptTextValue("/tmp/custom-state", {
        defaultValue: "/Users/example/.sidemesh",
      }),
      "/tmp/custom-state",
    );
  });
});
