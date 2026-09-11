import assert from "node:assert/strict";
import { it } from "node:test";
import { parseContentInput, contentInputAttachment } from "./input-content.js";

it("validates inline content without fetching URIs or reading host paths", () => {
  const text = { type: "resource", uri: "file:///unread-private-file", text: "" };
  assert.deepEqual(parseContentInput(text), text);
  assert.equal(contentInputAttachment(parseContentInput(text)).url, "data:text/plain;base64,");
  assert.deepEqual(parseContentInput({ type: "resourceLink", uri: "urn:example:record", name: "Record" }),
    { type: "resourceLink", uri: "urn:example:record", name: "Record" });
  for (const value of [
    { type: "audio", mimeType: "text/plain", data: "YQ==" },
    { type: "audio", mimeType: "audio/wav", data: "YQ" },
    { type: "audio", mimeType: "audio/wav", data: Buffer.alloc(5 * 1024 * 1024 + 1).toString("base64") },
    { ...text, blob: "YQ==" }, { ...text, blob: 3 }, { ...text, text: null },
    { ...text, uri: "relative/path" }, { ...text, uri: "javascript:alert(1)" },
    { ...text, uri: "https://example.com/\nsecret" },
    { type: "resourceLink", uri: "https://example.com", name: "" },
  ]) assert.throws(() => parseContentInput(value), { status: 400 });
});
