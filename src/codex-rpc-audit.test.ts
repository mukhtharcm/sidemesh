import test from "node:test";
import assert from "node:assert/strict";

import { extractTokenUsage } from "./codex-rpc-audit.js";

test("extractTokenUsage reads camelCase token usage", () => {
  assert.deepEqual(
    extractTokenUsage({
      tokenUsage: {
        total: {
          inputTokens: 10,
          cachedInputTokens: 4,
          outputTokens: 3,
          reasoningOutputTokens: 1,
          totalTokens: 13,
        },
      },
    }),
    {
      inputTokens: 10,
      cachedInputTokens: 4,
      outputTokens: 3,
      reasoningOutputTokens: 1,
      totalTokens: 13,
    },
  );
});

test("extractTokenUsage prefers last turn usage when present", () => {
  assert.deepEqual(
    extractTokenUsage({
      tokenUsage: {
        total: {
          inputTokens: 1000,
          cachedInputTokens: 800,
          outputTokens: 200,
          reasoningOutputTokens: 50,
          totalTokens: 1200,
        },
        last: {
          inputTokens: 20,
          cachedInputTokens: 10,
          outputTokens: 5,
          reasoningOutputTokens: 1,
          totalTokens: 25,
        },
      },
    }),
    {
      inputTokens: 20,
      cachedInputTokens: 10,
      outputTokens: 5,
      reasoningOutputTokens: 1,
      totalTokens: 25,
    },
  );
});

test("extractTokenUsage reads snake_case rollout token usage", () => {
  assert.deepEqual(
    extractTokenUsage({
      info: {
        total_token_usage: {
          input_tokens: 100,
          cached_input_tokens: 80,
          output_tokens: 20,
          reasoning_output_tokens: 5,
          total_tokens: 120,
        },
      },
    }),
    {
      inputTokens: 100,
      cachedInputTokens: 80,
      outputTokens: 20,
      reasoningOutputTokens: 5,
      totalTokens: 120,
    },
  );
});

test("extractTokenUsage ignores non-usage payloads", () => {
  assert.equal(extractTokenUsage({ method: "thread/list" }), undefined);
});
