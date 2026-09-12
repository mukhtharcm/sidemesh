import { AgentProviderRequestError, type AgentSessionInputItem } from "./agent-provider.js";
import type { SessionMessageAttachment } from "./types.js";

export type ContentInput = Extract<AgentSessionInputItem, { type: "audio" | "resource" | "resourceLink" }>;
const MAX_CONTENT_BYTES = 5 * 1024 * 1024;

/** Inline content is never fetched or resolved as a host filesystem path. */
export function parseContentInput(value: Record<string, unknown>): ContentInput {
  const fail = (message: string): never => { throw new AgentProviderRequestError(message, 400, true); };
  const name = typeof value.name === "string" && value.name.length <= 512 ? value.name : undefined;
  if (value.name !== undefined && name === undefined) fail("Invalid attachment name");
  const mimeType = typeof value.mimeType === "string" && /^[\w.+-]+\/[\w.+-]+$/.test(value.mimeType) ? value.mimeType : undefined;
  if (value.mimeType !== undefined && !mimeType) fail("Invalid attachment MIME type");
  const base64 = (data: unknown): string => {
    if (typeof data !== "string" || !data || data.length > Math.ceil(MAX_CONTENT_BYTES / 3) * 4 ||
        !/^[A-Za-z0-9+/]+={0,2}$/.test(data) || Buffer.from(data, "base64").toString("base64") !== data ||
        Buffer.byteLength(data, "base64") > MAX_CONTENT_BYTES) fail("Attachment must be valid base64 and at most 5 MiB");
    return data as string;
  };
  if (value.type === "audio") {
    if (!mimeType?.startsWith("audio/")) fail("Audio requires an audio MIME type");
    return { type: "audio", data: base64(value.data), mimeType: mimeType!, ...(name ? { name } : {}) };
  }
  const uri = typeof value.uri === "string" ? value.uri : "";
  try {
    if (!uri || uri.length > 4096 || /[\u0000-\u0020\u007f]/.test(uri) ||
        ["javascript:", "vbscript:", "data:"].includes(new URL(uri).protocol)) fail("Invalid resource URI");
  } catch { fail("Invalid resource URI"); }
  if (value.type === "resourceLink") {
    if (!name?.trim()) fail("A resource reference requires a name");
    return { type: "resourceLink", uri, name: name!, ...(mimeType ? { mimeType } : {}) };
  }
  if ((value.text !== undefined && typeof value.text !== "string") ||
      (value.blob !== undefined && typeof value.blob !== "string")) fail("Invalid resource content");
  if (value.type !== "resource" || (typeof value.text === "string") === (typeof value.blob === "string")) {
    fail("A resource requires exactly one text or blob value");
  }
  if (typeof value.text === "string" && Buffer.byteLength(value.text) > MAX_CONTENT_BYTES) fail("Resource exceeds 5 MiB");
  return { type: "resource", uri, ...(name ? { name } : {}), ...(mimeType ? { mimeType } : {}),
    ...(typeof value.text === "string" ? { text: value.text } : { blob: base64(value.blob) }) };
}

export function contentInputAttachment(item: ContentInput): SessionMessageAttachment {
  const url = item.type === "audio" ? `data:${item.mimeType};base64,${item.data}` : item.type === "resourceLink" ? item.uri :
    typeof item.text === "string" ? `data:${item.mimeType ?? "text/plain"};base64,${Buffer.from(item.text).toString("base64")}` :
    `data:${item.mimeType ?? "application/octet-stream"};base64,${item.blob}`;
  return { type: item.type, url, name: item.name ?? (item.type === "audio" ? "Audio" : item.uri), mimeType: item.mimeType };
}
