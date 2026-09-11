import { readFile } from "node:fs/promises";
import nodePath from "node:path";

export interface InputImage { type: "image"; data: string; mimeType: string; }

export function imageFromDataUrl(url: string): InputImage | null {
  const match = url.match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/]+={0,2})$/);
  if (!match || Buffer.from(match[2], "base64").toString("base64") !== match[2]) return null;
  return { type: "image", mimeType: match[1], data: match[2] };
}

export async function readLocalImage(path: string): Promise<InputImage> {
  const absolutePath = nodePath.resolve(path);
  const mimeType = imageMimeTypeFromPath(absolutePath);
  if (!mimeType) {
    throw new Error(`Unsupported image type for "${path}".`);
  }
  const buffer = await readFile(absolutePath);
  return {
    type: "image",
    data: buffer.toString("base64"),
    mimeType,
  };
}

function imageMimeTypeFromPath(path: string): string | null {
  switch (nodePath.extname(path).toLowerCase()) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    case ".svg":
      return "image/svg+xml";
    default:
      return null;
  }
}
