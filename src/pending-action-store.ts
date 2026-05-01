import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import { toPublicPendingAction } from "./approvals.js";
import type { AgentPendingAction } from "./agent-provider.js";
import type { PendingAction } from "./types.js";

export const RECOVERED_PENDING_ACTION_KIND = "sidemesh/recovered-pending-action";

export interface PendingActionStoreOptions {
  ttlMs: number;
  limit: number;
}

interface StoredPendingAction {
  action: PendingAction;
  savedAt: number;
}

interface StoreFile {
  version: 1;
  actions: StoredPendingAction[];
}

export class PendingActionStore {
  private readonly actionsById = new Map<string, StoredPendingAction>();
  private writeQueue: Promise<void> = Promise.resolve();

  private constructor(
    private readonly filePath: string,
    private readonly options: PendingActionStoreOptions,
  ) {}

  static async open(
    filePath: string,
    options: PendingActionStoreOptions,
  ): Promise<PendingActionStore> {
    const store = new PendingActionStore(filePath, options);
    await store.load();
    await store.flush();
    return store;
  }

  recoveredActions(): AgentPendingAction[] {
    this.prune(Date.now());
    return [...this.actionsById.values()]
      .sort((left, right) => right.action.requestedAt - left.action.requestedAt)
      .map(({ action }) => toRecoveredAction(action));
  }

  async put(action: AgentPendingAction): Promise<void> {
    if (!shouldPersistPendingAction(action)) {
      return;
    }
    const write = this.writeQueue.then(async () => {
      const publicAction = toPublicPendingAction(action);
      this.actionsById.set(action.id, {
        savedAt: Date.now(),
        action: {
          ...publicAction,
          state: "pending",
          recoverable: true,
        },
      });
      this.prune(Date.now());
      await this.flush();
    });
    this.writeQueue = write.catch(() => undefined);
    await write;
  }

  async delete(actionId: string): Promise<void> {
    const write = this.writeQueue.then(async () => {
      if (!this.actionsById.delete(actionId)) {
        return;
      }
      await this.flush();
    });
    this.writeQueue = write.catch(() => undefined);
    await write;
  }

  async deleteForSession(sessionId: string): Promise<void> {
    const write = this.writeQueue.then(async () => {
      let changed = false;
      for (const [actionId, entry] of this.actionsById) {
        if (entry.action.sessionId === sessionId) {
          this.actionsById.delete(actionId);
          changed = true;
        }
      }
      if (changed) {
        await this.flush();
      }
    });
    this.writeQueue = write.catch(() => undefined);
    await write;
  }

  async drain(): Promise<void> {
    await this.writeQueue;
  }

  private async load(): Promise<void> {
    let raw: string;
    try {
      raw = await readFile(this.filePath, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        return;
      }
      throw error;
    }

    const parsed = JSON.parse(raw) as Partial<StoreFile>;
    if (parsed.version !== 1 || !Array.isArray(parsed.actions)) {
      throw new Error("Invalid pending action store format");
    }
    for (const rawEntry of parsed.actions) {
      const entry = normalizeStoredPendingAction(rawEntry);
      if (entry) {
        this.actionsById.set(entry.action.id, entry);
      }
    }
    this.prune(Date.now());
  }

  private prune(now: number): void {
    for (const [actionId, entry] of this.actionsById) {
      if (now - entry.savedAt > this.options.ttlMs) {
        this.actionsById.delete(actionId);
      }
    }
    if (this.actionsById.size <= this.options.limit) {
      return;
    }
    const stale = [...this.actionsById.entries()]
      .sort((left, right) => left[1].savedAt - right[1].savedAt)
      .slice(0, this.actionsById.size - this.options.limit);
    for (const [actionId] of stale) {
      this.actionsById.delete(actionId);
    }
  }

  private async flush(): Promise<void> {
    await mkdir(dirname(this.filePath), { recursive: true, mode: 0o700 });
    const tmpPath = `${this.filePath}.${process.pid}.${Date.now()}.tmp`;
    const file: StoreFile = {
      version: 1,
      actions: [...this.actionsById.values()].sort(
        (left, right) => left.savedAt - right.savedAt,
      ),
    };
    await writeFile(tmpPath, JSON.stringify(file), {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(tmpPath, this.filePath);
  }
}

export function isRecoveredPendingAction(action: AgentPendingAction): boolean {
  return action.providerRequestKind === RECOVERED_PENDING_ACTION_KIND;
}

function shouldPersistPendingAction(action: PendingAction): boolean {
  if (action.kind === "user_input") {
    return action.recoverable !== false;
  }
  if (action.kind === "elicitation") {
    return action.recoverable === true;
  }
  return false;
}

function toRecoveredAction(action: PendingAction): AgentPendingAction {
  return {
    ...action,
    state: "recovered",
    recoverable: true,
    providerRequestId: action.id,
    providerRequestKind: RECOVERED_PENDING_ACTION_KIND,
    providerPayload: {
      recovered: true,
      originalRequestedAt: action.requestedAt,
    },
  };
}

function normalizeStoredPendingAction(value: unknown): StoredPendingAction | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const typed = value as Record<string, unknown>;
  const action = normalizePendingAction(typed.action);
  const savedAt = typeof typed.savedAt === "number" ? typed.savedAt : null;
  if (!action || savedAt == null || !Number.isFinite(savedAt)) {
    return null;
  }
  if (!shouldPersistPendingAction(action)) {
    return null;
  }
  return {
    savedAt,
    action: {
      ...action,
      state: "pending",
      recoverable: true,
    },
  };
}

function normalizePendingAction(value: unknown): PendingAction | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const typed = value as Record<string, unknown>;
  const id = stringValue(typed.id);
  const sessionId = stringValue(typed.sessionId);
  const kind = stringValue(typed.kind);
  const title = stringValue(typed.title);
  const detail = stringValue(typed.detail);
  const requestedAt =
    typeof typed.requestedAt === "number" && Number.isFinite(typed.requestedAt)
      ? typed.requestedAt
      : null;
  if (
    !id ||
    !sessionId ||
    !isPersistedPendingActionKind(kind) ||
    requestedAt == null
  ) {
    return null;
  }
  const action: PendingAction = {
    id,
    sessionId,
    kind,
    title: title ?? fallbackTitle(kind),
    detail: detail ?? "",
    requestedAt,
    canApprove: typed.canApprove === true,
    canApproveForSession: typed.canApproveForSession === true,
    canDecline: typed.canDecline === true,
    ...(typeof typed.recoverable === "boolean"
      ? { recoverable: typed.recoverable }
      : {}),
    ...(stringValue(typed.sessionTitle)
      ? { sessionTitle: stringValue(typed.sessionTitle)! }
      : {}),
    ...(stringValue(typed.cwd) ? { cwd: stringValue(typed.cwd)! } : {}),
    ...(stringValue(typed.relatedActivityId)
      ? { relatedActivityId: stringValue(typed.relatedActivityId)! }
      : {}),
  };
  if (kind === "user_input") {
    const userInput = normalizeUserInput(typed.userInput);
    if (!userInput) {
      return null;
    }
    action.userInput = userInput;
  } else if (kind === "elicitation") {
    const elicitation = normalizeElicitation(typed.elicitation);
    if (!elicitation) {
      return null;
    }
    action.elicitation = elicitation;
  }
  return action;
}

function normalizeUserInput(value: unknown): PendingAction["userInput"] | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const typed = value as Record<string, unknown>;
  return {
    question: stringValue(typed.question) ?? "Agent question",
    choices: stringArray(typed.choices),
    allowFreeform: typed.allowFreeform !== false,
  };
}

function normalizeElicitation(
  value: unknown,
): PendingAction["elicitation"] | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const typed = value as Record<string, unknown>;
  const mode = stringValue(typed.mode) === "url" ? "url" : "form";
  return {
    mode,
    message: stringValue(typed.message) ?? "Structured input requested",
    ...(stringValue(typed.source) ? { source: stringValue(typed.source)! } : {}),
    ...(stringValue(typed.url) ? { url: stringValue(typed.url)! } : {}),
    fields: normalizeElicitationFields(typed.fields),
  };
}

function normalizeElicitationFields(
  value: unknown,
): NonNullable<PendingAction["elicitation"]>["fields"] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .filter(
      (field): field is Record<string, unknown> =>
        Boolean(field) && typeof field === "object" && !Array.isArray(field),
    )
    .map(normalizeElicitationField)
    .filter(
      (
        field,
      ): field is NonNullable<PendingAction["elicitation"]>["fields"][number] =>
        field != null,
    );
}

function normalizeElicitationField(
  field: Record<string, unknown>,
): NonNullable<PendingAction["elicitation"]>["fields"][number] | null {
  const key = stringValue(field.key);
  if (!key) {
    return null;
  }
  const title = stringValue(field.title) ?? key;
  const base = {
    key,
    title,
    ...(stringValue(field.description)
      ? { description: stringValue(field.description)! }
      : {}),
    required: field.required === true,
  };
  switch (normalizeElicitationFieldType(field.type)) {
    case "boolean":
      return {
        ...base,
        type: "boolean",
        ...(typeof field.defaultValue === "boolean"
          ? { defaultValue: field.defaultValue }
          : {}),
      };
    case "number":
      return {
        ...base,
        type: "number",
        ...(numericValue(field.defaultValue) == null
          ? {}
          : { defaultValue: numericValue(field.defaultValue)! }),
        ...(numericValue(field.minimum) == null
          ? {}
          : { minimum: numericValue(field.minimum)! }),
        ...(numericValue(field.maximum) == null
          ? {}
          : { maximum: numericValue(field.maximum)! }),
        ...(field.integer === true ? { integer: true } : {}),
      };
    case "string[]": {
      const options = normalizeElicitationOptions(field.options);
      return {
        ...base,
        type: "string[]",
        defaultValue: stringArray(field.defaultValue),
        ...(numberValue(field.minItems) == null
          ? {}
          : { minItems: numberValue(field.minItems)! }),
        ...(numberValue(field.maxItems) == null
          ? {}
          : { maxItems: numberValue(field.maxItems)! }),
        options,
      };
    }
    case "string":
    default:
      return {
        ...base,
        type: "string",
        ...(stringValue(field.defaultValue)
          ? { defaultValue: stringValue(field.defaultValue)! }
          : {}),
        ...(numberValue(field.minLength) == null
          ? {}
          : { minLength: numberValue(field.minLength)! }),
        ...(numberValue(field.maxLength) == null
          ? {}
          : { maxLength: numberValue(field.maxLength)! }),
        ...(normalizeElicitationFormat(field.format)
          ? { format: normalizeElicitationFormat(field.format)! }
          : {}),
        ...(normalizeElicitationOptions(field.options).length === 0
          ? {}
          : { options: normalizeElicitationOptions(field.options) }),
      };
  }
}

function normalizeElicitationOptions(
  value: unknown,
): Array<{ value: string; label: string }> {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .filter(
      (option): option is Record<string, unknown> =>
        Boolean(option) && typeof option === "object" && !Array.isArray(option),
    )
    .map((option) => {
      const optionValue = stringValue(option.value) ?? "";
      return {
        value: optionValue,
        label: stringValue(option.label) ?? optionValue,
      };
    })
    .filter((option) => option.value.length > 0);
}

function normalizeElicitationFieldType(value: unknown): "string" | "string[]" | "boolean" | "number" {
  if (
    value === "string" ||
    value === "string[]" ||
    value === "boolean" ||
    value === "number"
  ) {
    return value;
  }
  return "string";
}

function normalizeElicitationFormat(
  value: unknown,
): "email" | "uri" | "date" | "date-time" | null {
  if (
    value === "email" ||
    value === "uri" ||
    value === "date" ||
    value === "date-time"
  ) {
    return value;
  }
  return null;
}

function isPersistedPendingActionKind(
  value: string | null,
): value is "user_input" | "elicitation" {
  return value === "user_input" || value === "elicitation";
}

function fallbackTitle(kind: "user_input" | "elicitation"): string {
  return kind === "user_input" ? "Agent question" : "Structured input requested";
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0
    ? value.trim()
    : null;
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .filter((item): item is string => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

function numericValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
