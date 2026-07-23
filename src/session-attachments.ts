import type { SessionMessageAttachment } from "./types.js";

const MAX_ATTACHMENT_COUNT = 12;
const MAX_TRAVERSAL_DEPTH = 8;
const MAX_TRAVERSAL_VALUES = 10_000;
const MAX_INLINE_IMAGE_URL_CHARS = 14 * 1024 * 1024;
const MAX_TOTAL_INLINE_IMAGE_URL_CHARS = 20 * 1024 * 1024;

export function extractSessionAttachments(
  value: unknown,
): SessionMessageAttachment[] {
  const attachments: SessionMessageAttachment[] = [];
  const seenValues = new Set<unknown>();
  const seenAttachments = new Set<string>();
  let inlineImageUrlChars = 0;

  const append = (attachment: SessionMessageAttachment): void => {
    if (attachments.length >= MAX_ATTACHMENT_COUNT) {
      return;
    }
    const key = attachmentKey(attachment);
    if (seenAttachments.has(key)) {
      return;
    }
    const inlineChars = attachment.url?.startsWith("data:image/")
      ? attachment.url.length
      : 0;
    if (
      inlineChars > 0 &&
      inlineImageUrlChars + inlineChars > MAX_TOTAL_INLINE_IMAGE_URL_CHARS
    ) {
      return;
    }
    seenAttachments.add(key);
    inlineImageUrlChars += inlineChars;
    attachments.push(attachment);
  };

  const visit = (candidate: unknown, depth: number): void => {
    if (
      candidate == null ||
      depth > MAX_TRAVERSAL_DEPTH ||
      seenValues.size >= MAX_TRAVERSAL_VALUES ||
      attachments.length >= MAX_ATTACHMENT_COUNT
    ) {
      return;
    }
    if (typeof candidate !== "object") {
      return;
    }
    if (seenValues.has(candidate)) {
      return;
    }
    seenValues.add(candidate);

    if (Array.isArray(candidate)) {
      for (const entry of candidate) {
        visit(entry, depth + 1);
      }
      return;
    }

    const record = candidate as Record<string, unknown>;
    const direct = attachmentFromRecord(record);
    if (direct) {
      append(direct);
      return;
    }

    const acpImage = asRecord(record.Image);
    if (acpImage) {
      const attachment = attachmentFromSource(
        stringProperty(acpImage, "source"),
      );
      if (attachment) {
        append(attachment);
      }
    }

    for (const nested of Object.values(record)) {
      visit(nested, depth + 1);
    }
  };

  visit(value, 0);
  return attachments;
}

export function mergeSessionAttachments(
  ...groups: ReadonlyArray<ReadonlyArray<SessionMessageAttachment>>
): SessionMessageAttachment[] {
  const merged: SessionMessageAttachment[] = [];
  const seen = new Set<string>();
  let inlineImageUrlChars = 0;
  for (const group of groups) {
    for (const attachment of group) {
      if (merged.length >= MAX_ATTACHMENT_COUNT) {
        return merged;
      }
      const key = attachmentKey(attachment);
      if (seen.has(key)) {
        continue;
      }
      const inlineChars = attachment.url?.startsWith("data:image/")
        ? attachment.url.length
        : 0;
      if (
        inlineChars > 0 &&
        inlineImageUrlChars + inlineChars > MAX_TOTAL_INLINE_IMAGE_URL_CHARS
      ) {
        continue;
      }
      seen.add(key);
      inlineImageUrlChars += inlineChars;
      merged.push(attachment);
    }
  }
  return merged;
}

export function stripSessionAttachments(
  value: unknown,
  promotedAttachments = extractSessionAttachments(value),
): unknown {
  return stripValue(
    value,
    0,
    new Set<unknown>(),
    new Set(promotedAttachments.map(attachmentKey)),
    { visited: 0 },
  );
}

function stripValue(
  value: unknown,
  depth: number,
  seen: Set<unknown>,
  promoted: Set<string>,
  traversal: { visited: number },
): unknown {
  if (value == null || typeof value !== "object") {
    return value;
  }
  if (
    depth > MAX_TRAVERSAL_DEPTH ||
    traversal.visited >= MAX_TRAVERSAL_VALUES
  ) {
    return value;
  }
  if (seen.has(value)) {
    return null;
  }
  traversal.visited += 1;
  seen.add(value);
  if (Array.isArray(value)) {
    return value
      .map((entry) =>
        stripValue(entry, depth + 1, seen, promoted, traversal),
      )
      .filter((entry) => entry !== undefined);
  }

  const record = value as Record<string, unknown>;
  const direct = attachmentFromRecord(record);
  if (direct && promoted.has(attachmentKey(direct))) {
    return undefined;
  }
  const stripped: Record<string, unknown> = {};
  for (const [key, nested] of Object.entries(record)) {
    const acpImage = key === "Image" ? asRecord(nested) : null;
    const acpAttachment = acpImage
      ? attachmentFromSource(stringProperty(acpImage, "source"))
      : null;
    if (acpAttachment && promoted.has(attachmentKey(acpAttachment))) {
      continue;
    }
    const next = stripValue(nested, depth + 1, seen, promoted, traversal);
    if (next !== undefined) {
      stripped[key] = next;
    }
  }
  return stripped;
}

function attachmentKey(attachment: SessionMessageAttachment): string {
  return `${attachment.type}\n${attachment.url ?? ""}\n${attachment.path ?? ""}`;
}

function attachmentFromRecord(
  record: Record<string, unknown>,
): SessionMessageAttachment | null {
  const normalizedType = normalizeType(record.type);
  const url =
    stringProperty(record, "url") ??
    stringProperty(record, "imageUrl") ??
    stringProperty(record, "image_url");
  const path =
    stringProperty(record, "path") ??
    stringProperty(record, "localPath") ??
    stringProperty(record, "local_path");

  if (
    normalizedType === "inputimage" ||
    normalizedType === "outputimage" ||
    normalizedType === "imageurl"
  ) {
    return attachmentFromSource(url);
  }

  if (normalizedType === "localimage" && path) {
    return { type: "localImage", path };
  }

  if (normalizedType === "image") {
    if (url) {
      return attachmentFromSource(url);
    }
    if (path) {
      return { type: "localImage", path };
    }
    const data = stringProperty(record, "data");
    const mimeType =
      stringProperty(record, "mimeType") ??
      stringProperty(record, "mime_type") ??
      stringProperty(record, "mime");
    if (data && mimeType?.startsWith("image/")) {
      return attachmentFromSource(`data:${mimeType};base64,${data}`);
    }
  }

  return null;
}

function attachmentFromSource(
  source: string | null,
): SessionMessageAttachment | null {
  if (!source) {
    return null;
  }
  if (source.startsWith("data:image/")) {
    if (
      source.length > MAX_INLINE_IMAGE_URL_CHARS ||
      !source.includes(";base64,")
    ) {
      return null;
    }
    return { type: "image", url: source };
  }
  if (source.startsWith("http://") || source.startsWith("https://")) {
    return { type: "image", url: source };
  }
  if (
    source.startsWith("/") ||
    source.startsWith("./") ||
    source.startsWith("../")
  ) {
    return { type: "localImage", path: source };
  }
  return null;
}

function normalizeType(value: unknown): string {
  return typeof value === "string"
    ? value.replaceAll(/[^a-zA-Z]/g, "").toLowerCase()
    : "";
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function stringProperty(
  record: Record<string, unknown>,
  key: string,
): string | null {
  const value = record[key];
  return typeof value === "string" && value.length > 0 ? value : null;
}
