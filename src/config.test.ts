import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";

import { loadConfig } from "./config.js";

const ORIGINAL_ENV = { ...process.env };

afterEach(() => {
  for (const key of Object.keys(process.env)) {
    if (!(key in ORIGINAL_ENV)) {
      delete process.env[key];
    }
  }
  for (const [key, value] of Object.entries(ORIGINAL_ENV)) {
    process.env[key] = value;
  }
});

describe("loadConfig", () => {
  it("loads multiple providers and keeps the requested default first", () => {
    process.env.SIDEMESH_TOKEN = "test-token";
    process.env.SIDEMESH_PROVIDER = "copilot";
    process.env.SIDEMESH_PROVIDERS = "codex,copilot";

    const config = loadConfig();

    assert.equal(config.defaultProviderKind, "copilot");
    assert.equal(config.provider.kind, "copilot");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["copilot", "codex"],
    );
  });

  it("defaults to the first configured multi-provider entry when no default is set", () => {
    process.env.SIDEMESH_TOKEN = "test-token";
    delete process.env.SIDEMESH_PROVIDER;
    process.env.SIDEMESH_PROVIDERS = "fake,copilot";

    const config = loadConfig();

    assert.equal(config.defaultProviderKind, "fake");
    assert.equal(config.provider.kind, "fake");
    assert.deepEqual(
      config.providers.map((provider) => provider.kind),
      ["fake", "copilot"],
    );
  });
});
