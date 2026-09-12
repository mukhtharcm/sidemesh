import { Buffer } from "node:buffer";

export interface ProviderOwnership {
  rawProviderId: string;
  kinds: Record<string, string>;
  aliases: Record<string, string>;
}

export interface SessionReference {
  providerId: string;
  rawId: string;
  sessionId: string;
}

/** Provider ownership survives command, default, and configured-provider changes. */
export function extendProviderOwnership(
  previous: ProviderOwnership | null,
  providers: Array<{ id: string; kind: string }>,
  defaultProviderId: string,
): ProviderOwnership {
  if (!providers.some((entry) => entry.id === defaultProviderId)) throw new Error("Default provider is not configured");
  if (new Set(providers.map((entry) => entry.id)).size !== providers.length) throw new Error("Provider instance IDs must be unique");
  const ownership: ProviderOwnership = previous ? structuredClone(previous)
    : { rawProviderId: defaultProviderId, kinds: {}, aliases: {} };
  for (const { id, kind } of providers) {
    if (Object.hasOwn(ownership.kinds, id) && ownership.kinds[id] !== kind) {
      throw new Error(`Provider instance "${id}" belongs to ${ownership.kinds[id]}; use a new instance ID for ${kind}`);
    }
    if (Object.hasOwn(ownership.aliases, id) && ownership.aliases[id] !== id) {
      throw new Error(`Provider ID "${id}" is a saved alias of "${ownership.aliases[id]}"; use a different instance ID`);
    }
    Object.defineProperty(ownership.kinds, id, { value: kind, enumerable: true, configurable: true, writable: true });
    Object.defineProperty(ownership.aliases, id, { value: id, enumerable: true, configurable: true, writable: true });
  }
  for (const { kind } of providers) {
    const matches = Object.entries(ownership.kinds).filter(([, candidate]) => candidate === kind);
    if (!Object.hasOwn(ownership.aliases, kind) && matches.length === 1) ownership.aliases[kind] = matches[0]![0];
  }
  return ownership;
}

export function wrapProviderScopedId(providerId: string, rawId: string): string {
  return `${providerId}:${Buffer.from(rawId, "utf8").toString("base64url")}`;
}

export function unwrapProviderScopedId(value: string): { kind: string; rawId: string } | null {
  const separator = value.indexOf(":");
  if (separator <= 0) return null;
  const kind = value.slice(0, separator);
  const encoded = value.slice(separator + 1);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) return null;
  const rawId = Buffer.from(encoded, "base64url").toString("utf8");
  return rawId && Buffer.from(rawId, "utf8").toString("base64url") === encoded ? { kind, rawId } : null;
}

export function resolveSessionReference(value: string, ownership: ProviderOwnership): SessionReference | null {
  if (!value) return null;
  const scoped = unwrapProviderScopedId(value);
  // Unknown prefixes cannot silently become raw IDs on the current default.
  const providerId = scoped ? Object.hasOwn(ownership.aliases, scoped.kind) ? ownership.aliases[scoped.kind]! : null : ownership.rawProviderId;
  if (!providerId || !Object.hasOwn(ownership.kinds, providerId)) return null;
  const rawId = scoped?.rawId ?? value;
  return { providerId, rawId, sessionId: wrapProviderScopedId(providerId, rawId) };
}
