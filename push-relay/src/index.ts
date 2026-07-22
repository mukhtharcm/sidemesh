interface Env {
  DB: D1Database;
  PUSH_QUEUE: Queue<PushQueueMessage>;
  REGISTRATION_RATE_LIMITER: RateLimit;
  PUBLISH_RATE_LIMITER: RateLimit;
  ALLOWED_BUNDLE_IDS: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_PRIVATE_KEY: string;
}

interface InstallationRequest {
  deviceToken: string;
  bundleId: string;
  environment: "development" | "production";
}

interface PushEvent {
  eventId: string;
  kind:
    | "approval_required"
    | "input_required"
    | "turn_completed"
    | "turn_failed";
  hostId: string;
  sessionId: string;
  actionId?: string;
  turnId?: string;
  createdAt: number;
  expiresAt: number;
}

interface PushQueueMessage {
  eventId: string;
  installationId: string;
}

interface InstallationRow {
  id: string;
  device_token: string;
  bundle_id: string;
  environment: "development" | "production";
  status: "active" | "invalid" | "revoked";
}

interface NotificationEventRow {
  payload_json: string;
  status: "pending" | "sending" | "sent" | "failed";
  expires_at: number;
}

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};
const MAX_BODY_BYTES = 16 * 1024;
const MAX_EVENT_TTL_MS = 24 * 60 * 60 * 1000;
const SEND_LEASE_MS = 60_000;

let cachedApnsToken: { value: string; expiresAt: number } | null = null;

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      console.error("Push relay request failed", error);
      return json({ error: "internal_error" }, 500);
    }
  },

  async queue(batch, env): Promise<void> {
    for (const message of batch.messages) {
      try {
        const outcome = await deliverQueuedPush(message.body, env);
        if (outcome === "retry") {
          const delaySeconds = Math.min(30 * 2 ** Math.min(message.attempts, 8), 3_600);
          message.retry({ delaySeconds });
        } else {
          message.ack();
        }
      } catch (error) {
        console.error("APNs queue delivery failed", error);
        const delaySeconds = Math.min(30 * 2 ** Math.min(message.attempts, 8), 3_600);
        message.retry({ delaySeconds });
      }
    }
  },
} satisfies ExportedHandler<Env, PushQueueMessage>;

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/healthz") {
    return json({ ok: true });
  }
  if (request.method === "POST" && url.pathname === "/v1/installations") {
    return createInstallation(request, env);
  }
  const installationMatch = /^\/v1\/installations\/([A-Za-z0-9_-]+)$/.exec(
    url.pathname,
  );
  if (installationMatch && request.method === "PUT") {
    return updateInstallation(request, env, installationMatch[1]!);
  }
  if (installationMatch && request.method === "DELETE") {
    return revokeInstallation(request, env, installationMatch[1]!);
  }
  if (request.method === "POST" && url.pathname === "/v1/notifications") {
    return acceptNotification(request, env);
  }
  return json({ error: "not_found" }, 404);
}

async function createInstallation(request: Request, env: Env): Promise<Response> {
  const registrationLimit = await env.REGISTRATION_RATE_LIMITER.limit({
    key: "global",
  });
  if (!registrationLimit.success) return json({ error: "rate_limited" }, 429);
  const input = parseInstallation(await readJson(request), env);
  if (!input) return json({ error: "invalid_installation" }, 400);
  const installationId = randomToken(18);
  const publishToken = randomToken(32);
  const managementToken = randomToken(32);
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO installations
      (id, device_token, bundle_id, environment, publish_token_hash,
       management_token_hash, status, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)`,
  )
    .bind(
      installationId,
      input.deviceToken,
      input.bundleId,
      input.environment,
      await hashToken(publishToken),
      await hashToken(managementToken),
      now,
      now,
    )
    .run();
  return json(
    { installationId, publishToken, managementToken },
    201,
  );
}

async function updateInstallation(
  request: Request,
  env: Env,
  installationId: string,
): Promise<Response> {
  const managementToken = bearerToken(request);
  if (!managementToken) return json({ error: "unauthorized" }, 401);
  const input = parseInstallation(await readJson(request), env);
  if (!input) return json({ error: "invalid_installation" }, 400);
  const result = await env.DB.prepare(
    `UPDATE installations
     SET device_token = ?, bundle_id = ?, environment = ?, status = 'active', updated_at = ?
     WHERE id = ? AND management_token_hash = ?`,
  )
    .bind(
      input.deviceToken,
      input.bundleId,
      input.environment,
      Date.now(),
      installationId,
      await hashToken(managementToken),
    )
    .run();
  if ((result.meta.changes ?? 0) === 0) {
    return json({ error: "unauthorized" }, 401);
  }
  return json({ ok: true });
}

async function revokeInstallation(
  request: Request,
  env: Env,
  installationId: string,
): Promise<Response> {
  const managementToken = bearerToken(request);
  if (!managementToken) return json({ error: "unauthorized" }, 401);
  const result = await env.DB.prepare(
    `UPDATE installations SET status = 'revoked', updated_at = ?
     WHERE id = ? AND management_token_hash = ?`,
  )
    .bind(Date.now(), installationId, await hashToken(managementToken))
    .run();
  if ((result.meta.changes ?? 0) === 0) {
    return json({ error: "unauthorized" }, 401);
  }
  return json({ ok: true });
}

async function acceptNotification(request: Request, env: Env): Promise<Response> {
  const publishToken = bearerToken(request);
  if (!publishToken) return json({ error: "unauthorized" }, 401);
  const publishLimit = await env.PUBLISH_RATE_LIMITER.limit({
    key: await hashToken(publishToken),
  });
  if (!publishLimit.success) return json({ error: "rate_limited" }, 429);
  const installation = await env.DB.prepare(
    `SELECT id, device_token, bundle_id, environment, status
     FROM installations WHERE publish_token_hash = ?`,
  )
    .bind(await hashToken(publishToken))
    .first<InstallationRow>();
  if (!installation || installation.status !== "active") {
    return json({ error: "invalid_subscription" }, 410);
  }
  const event = parsePushEvent(await readJson(request));
  if (!event) return json({ error: "invalid_event" }, 400);
  const idempotencyKey = request.headers.get("idempotency-key");
  if (idempotencyKey && idempotencyKey !== event.eventId) {
    return json({ error: "idempotency_mismatch" }, 400);
  }
  await env.DB.prepare(
    `INSERT OR IGNORE INTO notification_events
      (event_id, installation_id, payload_json, status, created_at, expires_at)
     VALUES (?, ?, ?, 'pending', ?, ?)`,
  )
    .bind(
      event.eventId,
      installation.id,
      JSON.stringify(event),
      event.createdAt,
      event.expiresAt,
    )
    .run();
  const stored = await env.DB.prepare(
    `SELECT status FROM notification_events
     WHERE event_id = ? AND installation_id = ?`,
  )
    .bind(event.eventId, installation.id)
    .first<{ status: string }>();
  if (stored?.status !== "sent" && stored?.status !== "failed") {
    await env.PUSH_QUEUE.send(
      { eventId: event.eventId, installationId: installation.id },
      { contentType: "json" },
    );
  }
  return json({ accepted: true, duplicate: stored?.status === "sent" }, 202);
}

async function deliverQueuedPush(
  message: PushQueueMessage,
  env: Env,
): Promise<"done" | "retry"> {
  const now = Date.now();
  const claimed = await env.DB.prepare(
    `UPDATE notification_events
     SET status = 'sending', lease_until = ?, attempts = attempts + 1
     WHERE event_id = ? AND installation_id = ?
       AND status IN ('pending', 'sending')
       AND (lease_until IS NULL OR lease_until < ?)`,
  )
    .bind(
      now + SEND_LEASE_MS,
      message.eventId,
      message.installationId,
      now,
    )
    .run();
  if ((claimed.meta.changes ?? 0) === 0) return "done";

  const [event, installation] = await Promise.all([
    env.DB.prepare(
      `SELECT payload_json, status, expires_at FROM notification_events
       WHERE event_id = ? AND installation_id = ?`,
    )
      .bind(message.eventId, message.installationId)
      .first<NotificationEventRow>(),
    env.DB.prepare(
      `SELECT id, device_token, bundle_id, environment, status
       FROM installations WHERE id = ?`,
    )
      .bind(message.installationId)
      .first<InstallationRow>(),
  ]);
  if (!event || !installation || installation.status !== "active") {
    await markEvent(env, message, "failed", "invalid installation");
    return "done";
  }
  if (event.expires_at <= now) {
    await markEvent(env, message, "failed", "expired");
    return "done";
  }

  const payload = JSON.parse(event.payload_json) as PushEvent;
  const result = await sendToApns(payload, installation, env);
  if (result.kind === "success") {
    await env.DB.prepare(
      `UPDATE notification_events
       SET status = 'sent', sent_at = ?, lease_until = NULL, last_error = NULL
       WHERE event_id = ? AND installation_id = ?`,
    )
      .bind(now, message.eventId, message.installationId)
      .run();
    return "done";
  }
  if (result.kind === "invalid_token") {
    await env.DB.batch([
      env.DB.prepare(
        `UPDATE installations SET status = 'invalid', updated_at = ? WHERE id = ?`,
      ).bind(now, installation.id),
      env.DB.prepare(
        `UPDATE notification_events
         SET status = 'failed', lease_until = NULL, last_error = ?
         WHERE event_id = ? AND installation_id = ?`,
      ).bind(result.reason, message.eventId, message.installationId),
    ]);
    return "done";
  }
  if (result.kind === "permanent") {
    await markEvent(env, message, "failed", result.reason);
    return "done";
  }
  await markEvent(env, message, "pending", result.reason);
  return "retry";
}

async function markEvent(
  env: Env,
  message: PushQueueMessage,
  status: "pending" | "failed",
  reason: string,
): Promise<void> {
  await env.DB.prepare(
    `UPDATE notification_events SET status = ?, lease_until = NULL, last_error = ?
     WHERE event_id = ? AND installation_id = ?`,
  )
    .bind(status, reason.slice(0, 300), message.eventId, message.installationId)
    .run();
}

async function sendToApns(
  event: PushEvent,
  installation: InstallationRow,
  env: Env,
): Promise<
  | { kind: "success" }
  | { kind: "retry" | "permanent" | "invalid_token"; reason: string }
> {
  const host =
    installation.environment === "development"
      ? "https://api.sandbox.push.apple.com"
      : "https://api.push.apple.com";
  const response = await fetch(
    `${host}/3/device/${installation.device_token}`,
    {
      method: "POST",
      headers: {
        authorization: `bearer ${await apnsProviderToken(env)}`,
        "apns-topic": installation.bundle_id,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(event.expiresAt / 1_000)),
        "apns-collapse-id": event.eventId.slice(0, 64),
        "content-type": "application/json",
      },
      body: JSON.stringify(apnsPayload(event)),
    },
  );
  if (response.ok) return { kind: "success" };
  const parsed = (await response.json().catch(() => null)) as
    | { reason?: string }
    | null;
  const reason = parsed?.reason || `APNs HTTP ${response.status}`;
  if (
    response.status === 410 ||
    reason === "BadDeviceToken" ||
    reason === "DeviceTokenNotForTopic" ||
    reason === "Unregistered"
  ) {
    return { kind: "invalid_token", reason };
  }
  if (response.status === 429 || response.status >= 500) {
    return { kind: "retry", reason };
  }
  return { kind: "permanent", reason };
}

function apnsPayload(event: PushEvent): Record<string, unknown> {
  const copy = (() => {
    switch (event.kind) {
      case "approval_required":
        return {
          title: "Approval needed",
          body: "An agent needs your approval.",
          interruptionLevel: "time-sensitive",
        };
      case "input_required":
        return {
          title: "Agent needs your answer",
          body: "An agent is waiting for your input.",
          interruptionLevel: "time-sensitive",
        };
      case "turn_failed":
        return {
          title: "Agent stopped with an error",
          body: "Agent work needs your attention.",
          interruptionLevel: "active",
        };
      case "turn_completed":
        return {
          title: "Agent finished",
          body: "Agent work completed.",
          interruptionLevel: "active",
        };
    }
  })();
  return {
    aps: {
      alert: { title: copy.title, body: copy.body },
      sound: "default",
      "thread-id": `sidemesh-${event.sessionId}`.slice(0, 64),
      "interruption-level": copy.interruptionLevel,
    },
    sidemesh: {
      eventId: event.eventId,
      type: event.kind,
      hostId: event.hostId,
      sessionId: event.sessionId,
      ...(event.actionId ? { actionId: event.actionId } : {}),
      ...(event.turnId ? { turnId: event.turnId } : {}),
    },
  };
}

async function apnsProviderToken(env: Env): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1_000);
  if (cachedApnsToken && cachedApnsToken.expiresAt > nowSeconds + 60) {
    return cachedApnsToken.value;
  }
  const header = base64UrlJson({ alg: "ES256", kid: env.APNS_KEY_ID });
  const claims = base64UrlJson({ iss: env.APNS_TEAM_ID, iat: nowSeconds });
  const signingInput = `${header}.${claims}`;
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToBytes(env.APNS_PRIVATE_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    new TextEncoder().encode(signingInput),
  );
  const value = `${signingInput}.${base64UrlBytes(new Uint8Array(signature))}`;
  cachedApnsToken = { value, expiresAt: nowSeconds + 50 * 60 };
  return value;
}

function parseInstallation(value: unknown, env: Env): InstallationRequest | null {
  if (!value || typeof value !== "object") return null;
  const typed = value as Record<string, unknown>;
  const deviceToken = stringValue(typed.deviceToken);
  const bundleId = stringValue(typed.bundleId);
  const environment = stringValue(typed.environment);
  if (
    !deviceToken ||
    !/^[a-fA-F0-9]{32,200}$/.test(deviceToken) ||
    !bundleId ||
    !allowedBundleIds(env).has(bundleId) ||
    (environment !== "development" && environment !== "production")
  ) {
    return null;
  }
  return { deviceToken: deviceToken.toLowerCase(), bundleId, environment };
}

function parsePushEvent(value: unknown): PushEvent | null {
  if (!value || typeof value !== "object") return null;
  const typed = value as Record<string, unknown>;
  const kind = stringValue(typed.kind);
  const eventId = stringValue(typed.eventId);
  const hostId = stringValue(typed.hostId);
  const sessionId = stringValue(typed.sessionId);
  const createdAt = numberValue(typed.createdAt);
  const expiresAt = numberValue(typed.expiresAt);
  const now = Date.now();
  if (
    !eventId ||
    !/^[A-Za-z0-9._:-]{1,128}$/.test(eventId) ||
    !isPushKind(kind) ||
    !bounded(hostId, 200) ||
    !bounded(sessionId, 500) ||
    createdAt === null ||
    expiresAt === null ||
    expiresAt <= now ||
    expiresAt > now + MAX_EVENT_TTL_MS
  ) {
    return null;
  }
  const actionId = stringValue(typed.actionId);
  const turnId = stringValue(typed.turnId);
  return {
    eventId,
    kind,
    hostId,
    sessionId,
    ...(actionId && actionId.length <= 500 ? { actionId } : {}),
    ...(turnId && turnId.length <= 500 ? { turnId } : {}),
    createdAt,
    expiresAt,
  };
}

async function readJson(request: Request): Promise<unknown> {
  const length = Number(request.headers.get("content-length") || "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) return null;
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function bearerToken(request: Request): string | null {
  const auth = request.headers.get("authorization") || "";
  return auth.startsWith("Bearer ") ? auth.slice(7).trim() || null : null;
}

function allowedBundleIds(env: Env): Set<string> {
  return new Set(env.ALLOWED_BUNDLE_IDS.split(",").map((item) => item.trim()));
}

async function hashToken(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return base64UrlBytes(new Uint8Array(digest));
}

function randomToken(bytes: number): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64UrlBytes(value);
}

function base64UrlJson(value: unknown): string {
  return base64UrlBytes(new TextEncoder().encode(JSON.stringify(value)));
}

function base64UrlBytes(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToBytes(value: string): ArrayBuffer {
  const normalized = value.replace(/\\n/g, "\n");
  const body = normalized
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0)).buffer;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), { status, headers: JSON_HEADERS });
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function bounded(value: string | null, maximum: number): value is string {
  return value !== null && value.length > 0 && value.length <= maximum;
}

function isPushKind(value: string | null): value is PushEvent["kind"] {
  return (
    value === "approval_required" ||
    value === "input_required" ||
    value === "turn_completed" ||
    value === "turn_failed"
  );
}

export const testing = {
  apnsPayload,
  parsePushEvent,
  parseInstallation,
};
