import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  extractSessionAttachments,
  mergeSessionAttachments,
  stripSessionAttachments,
} from "./session-attachments.js";

describe("extractSessionAttachments", () => {
  it("normalizes OpenAI snake-case and camel-case image content", () => {
    assert.deepEqual(
      extractSessionAttachments([
        {
          type: "input_image",
          image_url: "data:image/png;base64,AAAA",
        },
        {
          type: "inputImage",
          imageUrl: "https://example.com/result.png",
        },
      ]),
      [
        { type: "image", url: "data:image/png;base64,AAAA" },
        { type: "image", url: "https://example.com/result.png" },
      ],
    );
  });

  it("normalizes MCP and ACP image result blocks", () => {
    assert.deepEqual(
      extractSessionAttachments({
        content: [
          { type: "image", mimeType: "image/webp", data: "BBBB" },
          { Image: { source: "/repo/result.png" } },
        ],
      }),
      [
        { type: "image", url: "data:image/webp;base64,BBBB" },
        { type: "localImage", path: "/repo/result.png" },
      ],
    );
  });

  it("keeps provider-neutral bare, file URL, and Windows local images", () => {
    assert.deepEqual(
      extractSessionAttachments([
        { type: "image", path: "artifacts/result.png" },
        { type: "localImage", path: "file:///repo/result.png" },
        { type: "localImage", path: "C:\\repo\\result.png" },
      ]),
      [
        { type: "localImage", path: "artifacts/result.png" },
        { type: "localImage", path: "file:///repo/result.png" },
        { type: "localImage", path: "C:\\repo\\result.png" },
      ],
    );
  });

  it("deduplicates nested representations and ignores unrelated strings", () => {
    const image = {
      type: "inputImage",
      imageUrl: "data:image/jpeg;base64,CCCC",
    };
    assert.deepEqual(
      extractSessionAttachments({
        contentItems: [image],
        mirrored: { content: [image] },
        output: "/tmp/not-an-explicit-image.png",
      }),
      [{ type: "image", url: "data:image/jpeg;base64,CCCC" }],
    );
  });

  it("rejects malformed inline image values", () => {
    assert.deepEqual(
      extractSessionAttachments({
        type: "input_image",
        image_url: "data:image/png,not-base64",
      }),
      [],
    );
  });

  it("strips promoted image blocks without dropping text results", () => {
    assert.deepEqual(
      stripSessionAttachments({
        contentItems: [
          { type: "inputText", text: "Screenshot captured" },
          {
            type: "inputImage",
            imageUrl: "data:image/png;base64,AAAA",
          },
        ],
      }),
      {
        contentItems: [{ type: "inputText", text: "Screenshot captured" }],
      },
    );
  });

  it("preserves malformed ACP wrappers that were not promoted", () => {
    assert.deepEqual(
      stripSessionAttachments({
        Image: { source: "not-an-image-source", metadata: "keep me" },
      }),
      {
        Image: { source: "not-an-image-source", metadata: "keep me" },
      },
    );
  });

  it("preserves image blocks beyond the promoted attachment cap", () => {
    const value = Array.from({ length: 13 }, (_, index) => ({
      type: "input_image",
      image_url: `https://example.com/image-${index}.png`,
    }));
    const attachments = extractSessionAttachments(value);

    assert.equal(attachments.length, 12);
    assert.deepEqual(stripSessionAttachments(value, attachments), [
      {
        type: "input_image",
        image_url: "https://example.com/image-12.png",
      },
    ]);
  });

  it("merges explicit and extracted attachments without duplicates", () => {
    assert.deepEqual(
      mergeSessionAttachments(
        [{ type: "image", url: "https://example.com/explicit.png" }],
        [
          { type: "image", url: "https://example.com/explicit.png" },
          { type: "localImage", path: "/repo/extracted.png" },
        ],
      ),
      [
        { type: "image", url: "https://example.com/explicit.png" },
        { type: "localImage", path: "/repo/extracted.png" },
      ],
    );
  });
});
