import { createHash } from "node:crypto";
import nodePath from "node:path";

import type {
  SessionActivity,
  SessionMessage,
  SessionMessageAttachment,
  SessionResource,
} from "./types.js";

const BARE_URL_PATTERN = /(https?:\/\/[^\s<>]+|www\.[^\s<>]+)/gi;
const LOCAL_MARKDOWN_LINK_PATTERN = /\]\((<)?((?:\/|\.\.?\/)[^)]+)(>)?\)/g;
const IMAGE_EXTENSIONS = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".bmp",
  ".tif",
  ".tiff",
  ".svg",
  ".avif",
  ".heic",
  ".heif",
]);

export function buildSessionResources(
  messages: SessionMessage[],
  activities: SessionActivity[],
): SessionResource[] {
  const resources: SessionResource[] = [];
  const seen = new Set<string>();

  for (const message of messages) {
    appendMessageResources(resources, seen, message);
  }
  for (const activity of activities) {
    appendActivityResources(resources, seen, activity);
  }

  resources.sort((left, right) => {
    if (right.createdAt !== left.createdAt) {
      return right.createdAt - left.createdAt;
    }
    return right.id.localeCompare(left.id);
  });
  return resources;
}

function appendMessageResources(
  resources: SessionResource[],
  seen: Set<string>,
  message: SessionMessage,
): void {
  for (const [index, attachment] of message.attachments.entries()) {
    const next = buildAttachmentResource(message, attachment, index);
    if (next) {
      pushResource(resources, seen, next);
    }
  }

  for (const href of extractUrls(message.text)) {
    pushResource(resources, seen, {
      id: resourceId("message_link", message.id, href),
      kind: "link",
      source: "message_link",
      createdAt: message.createdAt,
      title: formatUrlLabel(href),
      subtitle: messageRoleLabel(message.role),
      url: href,
      path: null,
      messageId: message.id,
      activityId: null,
    });
  }

  for (const filePath of extractLocalMarkdownLinkTargets(message.text)) {
    pushResource(resources, seen, {
      id: resourceId("message_file", message.id, filePath),
      kind: "file",
      source: "message_file",
      createdAt: message.createdAt,
      title: basenameOrPath(filePath),
      subtitle: messageRoleLabel(message.role),
      url: null,
      path: filePath,
      messageId: message.id,
      activityId: null,
    });
  }
}

function buildAttachmentResource(
  message: SessionMessage,
  attachment: SessionMessageAttachment,
  index: number,
): SessionResource | null {
  if (attachment.type === "image" && attachment.url) {
    return {
      id: resourceId("message_attachment", message.id, attachment.url, index),
      kind: "image",
      source: "message_attachment",
      createdAt: message.createdAt,
      title: imageTitle(null, attachment.url),
      subtitle: messageRoleLabel(message.role),
      url: attachment.url,
      path: null,
      messageId: message.id,
      activityId: null,
    };
  }

  if (attachment.type === "localImage" && attachment.path) {
    return {
      id: resourceId("message_attachment", message.id, attachment.path, index),
      kind: "image",
      source: "message_attachment",
      createdAt: message.createdAt,
      title: imageTitle(attachment.path, null),
      subtitle: messageRoleLabel(message.role),
      url: null,
      path: attachment.path,
      messageId: message.id,
      activityId: null,
    };
  }

  return null;
}

function appendActivityResources(
  resources: SessionResource[],
  seen: Set<string>,
  activity: SessionActivity,
): void {
  if (activity.type === "web_search") {
    const href = normalizeUrl(activity.targetUrl);
    if (!href) {
      return;
    }
    pushResource(resources, seen, {
      id: resourceId("web_search", activity.id, href),
      kind: "link",
      source: "web_search",
      createdAt: activity.createdAt,
      title: formatUrlLabel(href),
      subtitle: summarizeWebSearch(activity),
      url: href,
      path: null,
      messageId: null,
      activityId: activity.id,
    });
    return;
  }

  if (activity.type === "image_generation") {
    const savedPath = normalizeLocalPath(activity.savedPath);
    if (!savedPath) {
      return;
    }
    pushResource(resources, seen, {
      id: resourceId("image_generation", activity.id, savedPath),
      kind: isImagePath(savedPath) ? "image" : "file",
      source: "image_generation",
      createdAt: activity.createdAt,
      title: basenameOrPath(savedPath),
      subtitle: summarizeImageGeneration(activity),
      url: null,
      path: savedPath,
      messageId: null,
      activityId: activity.id,
    });
  }
}

function pushResource(
  resources: SessionResource[],
  seen: Set<string>,
  resource: SessionResource,
): void {
  const key = [
    resource.source,
    resource.messageId ?? "",
    resource.activityId ?? "",
    resource.kind,
    resource.url ?? "",
    resource.path ?? "",
  ].join("\n");
  if (seen.has(key)) {
    return;
  }
  seen.add(key);
  resources.push(resource);
}

function resourceId(...parts: Array<string | number>): string {
  const digest = createHash("sha1");
  for (const part of parts) {
    digest.update(String(part));
    digest.update("\n");
  }
  return digest.digest("hex");
}

function extractUrls(text: string): string[] {
  if (!text.trim()) {
    return [];
  }

  const urls = new Set<string>();
  for (const match of text.matchAll(BARE_URL_PATTERN)) {
    const raw = match[0];
    const normalized = normalizeUrl(raw);
    if (!normalized) {
      continue;
    }
    urls.add(normalized);
  }
  return [...urls];
}

function normalizeUrl(raw: string | null | undefined): string | null {
  if (!raw) {
    return null;
  }
  const trimmed = raw.trim().replace(/[),.!?;:\]]+$/g, "");
  if (!trimmed) {
    return null;
  }
  if (/^https?:\/\//i.test(trimmed)) {
    return trimmed;
  }
  if (/^www\./i.test(trimmed)) {
    return `https://${trimmed}`;
  }
  return null;
}

function extractLocalMarkdownLinkTargets(text: string): string[] {
  if (!text.includes("](")) {
    return [];
  }

  const paths = new Set<string>();
  for (const match of text.matchAll(LOCAL_MARKDOWN_LINK_PATTERN)) {
    const normalized = normalizeLocalPath(match[2]);
    if (!normalized) {
      continue;
    }
    paths.add(normalized);
  }
  return [...paths];
}

function normalizeLocalPath(raw: string | null | undefined): string | null {
  if (!raw) {
    return null;
  }
  let value = raw.trim();
  if (value.startsWith("<") && value.endsWith(">")) {
    value = value.slice(1, -1).trim();
  }
  if (!value.startsWith("/") && !value.startsWith("./") && !value.startsWith("../")) {
    return null;
  }
  const withLineSuffixRemoved = value.replace(/:\d+(?::\d+)?$/, "");
  return withLineSuffixRemoved.trim() || null;
}

function formatUrlLabel(raw: string): string {
  try {
    const parsed = new URL(raw);
    const host = parsed.host || raw;
    const path = parsed.pathname === "/" ? "" : parsed.pathname;
    return `${host}${path}`.slice(0, 120);
  } catch {
    return raw.slice(0, 120);
  }
}

function basenameOrPath(filePath: string): string {
  const base = nodePath.basename(filePath);
  return base || filePath;
}

function imageTitle(filePath: string | null, url: string | null): string {
  if (filePath) {
    return basenameOrPath(filePath);
  }
  if (url?.startsWith("data:image/")) {
    return "Pasted image";
  }
  if (url) {
    return formatUrlLabel(url);
  }
  return "Image";
}

function summarizeWebSearch(activity: Extract<SessionActivity, { type: "web_search" }>): string {
  const pattern = (activity.pattern ?? "").trim();
  if (pattern) {
    return `Find "${pattern}"`;
  }
  const query = (activity.query ?? "").trim();
  if (query) {
    return query;
  }
  if (activity.queries.length > 0) {
    return activity.queries[0]!;
  }
  return "Opened via web search";
}

function summarizeImageGeneration(
  activity: Extract<SessionActivity, { type: "image_generation" }>,
): string {
  const prompt = (activity.revisedPrompt ?? "").trim();
  if (!prompt) {
    return "Generated image";
  }
  return prompt.length <= 90 ? prompt : `${prompt.slice(0, 87)}...`;
}

function isImagePath(filePath: string): boolean {
  const ext = nodePath.extname(filePath).toLowerCase();
  return IMAGE_EXTENSIONS.has(ext);
}

function messageRoleLabel(role: SessionMessage["role"]): string {
  switch (role) {
    case "user":
      return "You";
    case "assistant":
      return "Assistant";
    default:
      return "System";
  }
}
