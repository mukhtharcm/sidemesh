import { randomBytes, randomUUID } from "node:crypto";
import {
  chmod,
  mkdir,
  readFile,
  rename,
  writeFile,
} from "node:fs/promises";
import nodePath from "node:path";

const STATE_VERSION = 1;
const STATE_FILE = "push-notifications-v1.json";
const DELIVERY_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_RETRY_DELAY_MS = 15 * 60 * 1000;

export type PushNotificationKind =
  | "approval_required"
  | "input_required"
  | "turn_completed"
  | "turn_failed";

export interface PushNotificationEvent {
  eventId: string;
  kind: PushNotificationKind;
  hostId: string;
  sessionId: string;
  actionId?: string;
  turnId?: string;
  createdAt: number;
  expiresAt: number;
}

export interface PushSubscriptionInput {
  installationId: string;
  hostId: string;
  relayUrl: string;
  publishToken: string;
}

export interface PushSubscriptionSummary {
  installationId: string;
  hostId: string;
  relayUrl: string;
  createdAt: number;
  updatedAt: number;
}

interface StoredPushSubscription extends PushSubscriptionSummary {
  publishToken: string;
}

interface PendingDelivery {
  id: string;
  subscriptionId: string;
  event: PushNotificationEvent;
  attempts: number;
  nextAttemptAt: number;
}

interface PushNotificationState {
  version: typeof STATE_VERSION;
  subscriptions: StoredPushSubscription[];
  deliveries: PendingDelivery[];
}

interface PushNotificationDispatcherOptions {
  fetch?: typeof fetch;
  now?: () => number;
  random?: () => number;
}

export class PushNotificationDispatcher {
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly random: () => number;
  private state: PushNotificationState;
  private saveChain = Promise.resolve();
  private pumpPromise: Promise<void> | null = null;
  private timer: NodeJS.Timeout | null = null;
  private closed = false;

  private constructor(
    private readonly statePath: string,
    state: PushNotificationState,
    options: PushNotificationDispatcherOptions,
  ) {
    this.state = state;
    this.fetchImpl = options.fetch ?? fetch;
    this.now = options.now ?? Date.now;
    this.random = options.random ?? Math.random;
  }

  public static async open(
    stateDir: string,
    options: PushNotificationDispatcherOptions = {},
  ): Promise<PushNotificationDispatcher> {
    await mkdir(stateDir, { recursive: true, mode: 0o700 });
    const statePath = nodePath.join(stateDir, STATE_FILE);
    const state = await loadState(statePath);
    const dispatcher = new PushNotificationDispatcher(statePath, state, options);
    dispatcher.schedulePump(0);
    return dispatcher;
  }

  public listSubscriptions(): PushSubscriptionSummary[] {
    return this.state.subscriptions.map(({ publishToken: _secret, ...entry }) => ({
      ...entry,
    }));
  }

  public async upsertSubscription(
    input: PushSubscriptionInput,
  ): Promise<PushSubscriptionSummary> {
    const normalized = normalizeSubscriptionInput(input);
    const now = this.now();
    const existingIndex = this.state.subscriptions.findIndex(
      (entry) => entry.installationId === normalized.installationId,
    );
    const createdAt =
      existingIndex >= 0
        ? this.state.subscriptions[existingIndex]!.createdAt
        : now;
    const stored: StoredPushSubscription = {
      ...normalized,
      createdAt,
      updatedAt: now,
    };
    if (existingIndex >= 0) {
      this.state.subscriptions.splice(existingIndex, 1, stored);
    } else {
      this.state.subscriptions.push(stored);
    }
    await this.save();
    return withoutSecret(stored);
  }

  public async removeSubscription(installationId: string): Promise<boolean> {
    const previousLength = this.state.subscriptions.length;
    this.state.subscriptions = this.state.subscriptions.filter(
      (entry) => entry.installationId !== installationId,
    );
    this.state.deliveries = this.state.deliveries.filter(
      (entry) => entry.subscriptionId !== installationId,
    );
    if (this.state.subscriptions.length === previousLength) {
      return false;
    }
    await this.save();
    return true;
  }

  public async enqueue(
    event: Omit<PushNotificationEvent, "eventId" | "hostId" | "createdAt" | "expiresAt"> &
      Partial<Pick<PushNotificationEvent, "eventId" | "createdAt" | "expiresAt">>,
  ): Promise<string> {
    if (this.closed) return event.eventId ?? randomUUID();
    const now = this.now();
    const baseEvent = {
      ...event,
      eventId: event.eventId ?? randomUUID(),
      createdAt: event.createdAt ?? now,
      expiresAt: event.expiresAt ?? now + DELIVERY_TTL_MS,
    };
    for (const subscription of this.state.subscriptions) {
      const materialized: PushNotificationEvent = {
        ...baseEvent,
        hostId: subscription.hostId,
      };
      const id = `${subscription.installationId}:${materialized.eventId}`;
      if (this.state.deliveries.some((entry) => entry.id === id)) {
        continue;
      }
      this.state.deliveries.push({
        id,
        subscriptionId: subscription.installationId,
        event: materialized,
        attempts: 0,
        nextAttemptAt: now,
      });
    }
    await this.save();
    this.schedulePump(0);
    return baseEvent.eventId;
  }

  public async flushDue(): Promise<void> {
    if (this.pumpPromise) {
      await this.pumpPromise;
      return;
    }
    this.pumpPromise = this.runPump().finally(() => {
      this.pumpPromise = null;
    });
    await this.pumpPromise;
  }

  public async close(): Promise<void> {
    this.closed = true;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    await this.pumpPromise?.catch(() => undefined);
    await this.saveChain.catch(() => undefined);
  }

  private async runPump(): Promise<void> {
    if (this.closed) return;
    const now = this.now();
    let changed = false;
    for (const delivery of [...this.state.deliveries]) {
      if (delivery.event.expiresAt <= now) {
        this.removeDelivery(delivery.id);
        changed = true;
        continue;
      }
      if (delivery.nextAttemptAt > now) continue;
      const subscription = this.state.subscriptions.find(
        (entry) => entry.installationId === delivery.subscriptionId,
      );
      if (!subscription) {
        this.removeDelivery(delivery.id);
        changed = true;
        continue;
      }
      const outcome = await this.deliver(subscription, delivery.event);
      if (outcome === "delivered") {
        this.removeDelivery(delivery.id);
      } else if (outcome === "invalid_subscription") {
        this.state.subscriptions = this.state.subscriptions.filter(
          (entry) => entry.installationId !== subscription.installationId,
        );
        this.state.deliveries = this.state.deliveries.filter(
          (entry) => entry.subscriptionId !== subscription.installationId,
        );
      } else {
        delivery.attempts += 1;
        delivery.nextAttemptAt = now + retryDelayMs(delivery.attempts, this.random);
      }
      changed = true;
    }
    if (changed) await this.save();
    this.scheduleNextDue();
  }

  private async deliver(
    subscription: StoredPushSubscription,
    event: PushNotificationEvent,
  ): Promise<"delivered" | "retry" | "invalid_subscription"> {
    try {
      const response = await this.fetchImpl(
        new URL("/v1/notifications", subscription.relayUrl),
        {
          method: "POST",
          headers: {
            authorization: `Bearer ${subscription.publishToken}`,
            "content-type": "application/json",
            "idempotency-key": event.eventId,
          },
          body: JSON.stringify(event),
          signal: AbortSignal.timeout(8_000),
        },
      );
      if (response.ok) return "delivered";
      if (response.status === 401 || response.status === 404 || response.status === 410) {
        return "invalid_subscription";
      }
      return "retry";
    } catch {
      return "retry";
    }
  }

  private removeDelivery(id: string): void {
    this.state.deliveries = this.state.deliveries.filter(
      (entry) => entry.id !== id,
    );
  }

  private schedulePump(delayMs: number): void {
    if (this.closed || this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.flushDue();
    }, Math.max(0, delayMs));
    this.timer.unref();
  }

  private scheduleNextDue(): void {
    if (this.closed || this.state.deliveries.length === 0) return;
    const next = Math.min(
      ...this.state.deliveries.map((entry) =>
        Math.min(entry.nextAttemptAt, entry.event.expiresAt),
      ),
    );
    this.schedulePump(Math.max(0, next - this.now()));
  }

  private save(): Promise<void> {
    const snapshot = JSON.stringify(this.state, null, 2) + "\n";
    this.saveChain = this.saveChain.then(() => atomicWrite(this.statePath, snapshot));
    return this.saveChain;
  }
}

function normalizeSubscriptionInput(
  input: PushSubscriptionInput,
): PushSubscriptionInput {
  const installationId = input.installationId.trim();
  const hostId = input.hostId.trim();
  const publishToken = input.publishToken.trim();
  if (!/^[A-Za-z0-9_-]{16,160}$/.test(installationId)) {
    throw new Error("invalid installation id");
  }
  if (hostId.length < 1 || hostId.length > 200) {
    throw new Error("invalid host id");
  }
  if (!/^[A-Za-z0-9_-]{32,256}$/.test(publishToken)) {
    throw new Error("invalid publish token");
  }
  let relay: URL;
  try {
    relay = new URL(input.relayUrl);
  } catch {
    throw new Error("invalid relay URL");
  }
  if (relay.protocol !== "https:" || relay.username || relay.password) {
    throw new Error("relay URL must use HTTPS without embedded credentials");
  }
  relay.pathname = relay.pathname.replace(/\/+$/, "");
  relay.search = "";
  relay.hash = "";
  return {
    installationId,
    hostId,
    relayUrl: relay.toString().replace(/\/$/, ""),
    publishToken,
  };
}

function retryDelayMs(attempts: number, random: () => number): number {
  const base = Math.min(2_000 * 2 ** Math.min(attempts - 1, 9), MAX_RETRY_DELAY_MS);
  return Math.round(base * (0.8 + random() * 0.4));
}

function withoutSecret(entry: StoredPushSubscription): PushSubscriptionSummary {
  const { publishToken: _secret, ...summary } = entry;
  return summary;
}

async function loadState(statePath: string): Promise<PushNotificationState> {
  try {
    const parsed = JSON.parse(await readFile(statePath, "utf8")) as Partial<PushNotificationState>;
    if (
      parsed.version === STATE_VERSION &&
      Array.isArray(parsed.subscriptions) &&
      Array.isArray(parsed.deliveries)
    ) {
      return parsed as PushNotificationState;
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      console.error(`Ignored invalid push notification state: ${String(error)}`);
    }
  }
  return { version: STATE_VERSION, subscriptions: [], deliveries: [] };
}

async function atomicWrite(path: string, contents: string): Promise<void> {
  await mkdir(nodePath.dirname(path), { recursive: true, mode: 0o700 });
  const temporaryPath = `${path}.${randomBytes(6).toString("hex")}.tmp`;
  await writeFile(temporaryPath, contents, { encoding: "utf8", mode: 0o600 });
  await rename(temporaryPath, path);
  await chmod(path, 0o600).catch(() => undefined);
}
