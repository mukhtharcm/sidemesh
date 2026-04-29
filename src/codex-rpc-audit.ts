interface CodexRpcAuditRecord {
  ts: number;
  direction: "request" | "response" | "notification";
  method: string;
  status?: "ok" | "error";
  durationMs?: number;
  tokenUsage?: CodexTokenUsageSummary;
  error?: string;
}

interface CodexRpcMethodStats {
  count: number;
  lastAt: number;
  errors?: number;
  totalDurationMs?: number;
}

export interface CodexTokenUsageSummary {
  inputTokens?: number;
  cachedInputTokens?: number;
  outputTokens?: number;
  reasoningOutputTokens?: number;
  totalTokens?: number;
}

export interface CodexRpcAuditSnapshot {
  enabled: boolean;
  startedAt: number;
  requests: Record<string, CodexRpcMethodStats>;
  notifications: Record<string, CodexRpcMethodStats>;
  tokenUsageEvents: CodexRpcAuditRecord[];
  recent: CodexRpcAuditRecord[];
}

const MAX_RECENT = 200;
const MAX_TOKEN_USAGE_EVENTS = 80;

class CodexRpcAudit {
  public readonly enabled =
    process.env.SIDEMESH_CODEX_RPC_AUDIT?.trim() === "1";

  private readonly startedAt = Date.now();
  private readonly requests = new Map<string, CodexRpcMethodStats>();
  private readonly notifications = new Map<string, CodexRpcMethodStats>();
  private readonly recent: CodexRpcAuditRecord[] = [];
  private readonly tokenUsageEvents: CodexRpcAuditRecord[] = [];

  public recordRequest(method: string): void {
    if (!this.enabled) {
      return;
    }
    const record: CodexRpcAuditRecord = {
      ts: Date.now(),
      direction: "request",
      method,
    };
    increment(this.requests, method, record.ts);
    this.pushRecent(record);
    this.log(record);
  }

  public recordResponse(
    method: string,
    startedAt: number,
    status: "ok" | "error",
    error?: string,
  ): void {
    if (!this.enabled) {
      return;
    }
    const now = Date.now();
    const durationMs = Math.max(0, now - startedAt);
    const stats = increment(this.requests, method, now);
    stats.totalDurationMs = (stats.totalDurationMs ?? 0) + durationMs;
    if (status === "error") {
      stats.errors = (stats.errors ?? 0) + 1;
    }
    const record: CodexRpcAuditRecord = {
      ts: now,
      direction: "response",
      method,
      status,
      durationMs,
      error: sanitizeError(error),
    };
    this.pushRecent(record);
    this.log(record);
  }

  public recordNotification(method: string, params: unknown): void {
    if (!this.enabled) {
      return;
    }
    const now = Date.now();
    increment(this.notifications, method, now);
    const tokenUsage = extractTokenUsage(params);
    const record: CodexRpcAuditRecord = {
      ts: now,
      direction: "notification",
      method,
      tokenUsage,
    };
    this.pushRecent(record);
    if (tokenUsage) {
      this.tokenUsageEvents.push(record);
      trimFront(this.tokenUsageEvents, MAX_TOKEN_USAGE_EVENTS);
    }
    this.log(record);
  }

  public snapshot(): CodexRpcAuditSnapshot {
    return {
      enabled: this.enabled,
      startedAt: this.startedAt,
      requests: Object.fromEntries(this.requests),
      notifications: Object.fromEntries(this.notifications),
      tokenUsageEvents: [...this.tokenUsageEvents],
      recent: [...this.recent],
    };
  }

  private pushRecent(record: CodexRpcAuditRecord): void {
    this.recent.push(record);
    trimFront(this.recent, MAX_RECENT);
  }

  private log(record: CodexRpcAuditRecord): void {
    const parts = [
      "[sidemesh:codex-rpc]",
      record.direction,
      record.method,
    ];
    if (record.status) {
      parts.push(record.status);
    }
    if (record.durationMs !== undefined) {
      parts.push(`${record.durationMs}ms`);
    }
    if (record.error) {
      parts.push(`error=${record.error}`);
    }
    if (record.tokenUsage) {
      parts.push(`usage=${JSON.stringify(record.tokenUsage)}`);
    }
    console.error(parts.join(" "));
  }
}

export const codexRpcAudit = new CodexRpcAudit();

export function getCodexRpcAuditSnapshot(): CodexRpcAuditSnapshot {
  return codexRpcAudit.snapshot();
}

export function extractTokenUsage(value: unknown): CodexTokenUsageSummary | undefined {
  const visited = new Set<unknown>();
  return extractTokenUsageInner(value, visited);
}

function extractTokenUsageInner(
  value: unknown,
  visited: Set<unknown>,
): CodexTokenUsageSummary | undefined {
  if (!value || typeof value !== "object") {
    return undefined;
  }
  if (visited.has(value)) {
    return undefined;
  }
  visited.add(value);

  const record = value as Record<string, unknown>;
  const direct = normalizeTokenUsage(record);
  if (direct) {
    return direct;
  }

  const candidates = [
    record.tokenUsage,
    record.token_usage,
    record.totalTokenUsage,
    record.total_token_usage,
    record.lastTokenUsage,
    record.last_token_usage,
    record.usage,
    record.info,
    record.turn,
  ];
  for (const candidate of candidates) {
    const found = extractTokenUsageInner(candidate, visited);
    if (found) {
      return found;
    }
  }

  return undefined;
}

function normalizeTokenUsage(
  record: Record<string, unknown>,
): CodexTokenUsageSummary | undefined {
  const summary: CodexTokenUsageSummary = {
    inputTokens: numberField(record, "inputTokens", "input_tokens"),
    cachedInputTokens: numberField(
      record,
      "cachedInputTokens",
      "cached_input_tokens",
    ),
    outputTokens: numberField(record, "outputTokens", "output_tokens"),
    reasoningOutputTokens: numberField(
      record,
      "reasoningOutputTokens",
      "reasoning_output_tokens",
    ),
    totalTokens: numberField(record, "totalTokens", "total_tokens"),
  };

  return Object.values(summary).some((value) => value !== undefined)
    ? summary
    : undefined;
}

function numberField(
  record: Record<string, unknown>,
  camelKey: string,
  snakeKey: string,
): number | undefined {
  const value = record[camelKey] ?? record[snakeKey];
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function increment(
  map: Map<string, CodexRpcMethodStats>,
  method: string,
  now: number,
): CodexRpcMethodStats {
  const current = map.get(method) ?? { count: 0, lastAt: now };
  current.count += 1;
  current.lastAt = now;
  map.set(method, current);
  return current;
}

function trimFront<T>(items: T[], limit: number): void {
  while (items.length > limit) {
    items.shift();
  }
}

function sanitizeError(error: string | undefined): string | undefined {
  if (!error) {
    return undefined;
  }
  return error.length > 180 ? `${error.slice(0, 177)}...` : error;
}
