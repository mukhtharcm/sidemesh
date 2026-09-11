import { basename } from "node:path";
import { pathToFileURL } from "node:url";
import type { ContentBlock, PromptCapabilities } from "@agentclientprotocol/sdk";
import type { AgentSessionInputItem } from "./agent-provider.js";
import type { SessionMessageAttachment } from "./types.js";
import { imageFromDataUrl, readLocalImage } from "./input-image.js";

export function acpInputPreview(input: AgentSessionInputItem[]): string {
  return input.map((item) => item.type === "text" ? item.text : item.type === "file"
    ? `${item.isDirectory ? "Directory" : "File"}: ${item.path}`
    : item.type === "image" || item.type === "localImage" ? "[Image]" : "").join("\n\n");
}

export async function prepareAcpInput(input: AgentSessionInputItem[], capabilities: PromptCapabilities = {}) {
  const prompt: ContentBlock[] = [];
  const attachments: SessionMessageAttachment[] = [];
  for (const item of input) {
    switch (item.type) {
      case "text":
        if (item.text.trim()) prompt.push({ type: "text", text: item.text });
        break;
      case "file":
        prompt.push({ type: "resource_link", uri: pathToFileURL(item.path).href, name: basename(item.path) });
        attachments.push({ type: "file", path: item.path });
        break;
      case "image":
      case "localImage": {
        if (!capabilities.image) throw new Error("This ACP agent does not support image input");
        const image = item.type === "localImage" ? await readLocalImage(item.path) : imageFromDataUrl(item.url);
        if (!image) throw new Error("ACP accepts local images or image data URLs");
        prompt.push(image);
        attachments.push({ type: "image", url: `data:${image.mimeType};base64,${image.data}` });
        break;
      }
      default:
        throw new Error(`ACP ${item.type} input is not supported`);
    }
  }
  if (!prompt.length) throw new Error("Input is required");
  return { prompt, attachments, text: acpInputPreview(input) };
}
