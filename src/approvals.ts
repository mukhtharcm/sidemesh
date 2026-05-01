import type {
  PendingAction,
  PendingActionApprovalScope,
  PendingActionDecisionId,
  PendingActionDecisionKind,
  PendingActionDecisionRequest,
  PendingActionElicitationFieldValue,
  SessionMessage,
} from "./types.js";

export interface NormalizedPendingActionDecision {
  decision: PendingActionDecisionKind;
  scope: PendingActionApprovalScope;
  legacyDecision: PendingActionDecisionId;
}

export type PendingActionDecisionInput =
  | PendingActionDecisionRequest
  | NormalizedPendingActionDecision
  | PendingActionDecisionId
  | null
  | undefined;

export interface PendingActionUserInputResponse {
  answer: string;
  wasFreeform: boolean;
}

export interface PendingActionElicitationResponse {
  action: "accept" | "decline" | "cancel";
  content?: Record<string, PendingActionElicitationFieldValue>;
}

export type PendingActionResponseInput =
  | PendingActionDecisionInput
  | PendingActionUserInputResponse
  | PendingActionElicitationResponse;

const LEGACY_DECISIONS = new Set<PendingActionDecisionId>([
  "accept",
  "acceptForSession",
  "acceptForLocation",
  "decline",
  "cancel",
]);

export function parsePendingActionDecision(
  value: unknown,
): NormalizedPendingActionDecision | null {
  if (typeof value === "string") {
    return decisionFromLegacy(value);
  }
  if (!value || typeof value !== "object") {
    return null;
  }

  const typed = value as Record<string, unknown>;
  const decision = typed.decision;
  if (!isDecisionKind(decision)) {
    return null;
  }

  if (typed.scope !== undefined && !isApprovalScope(typed.scope)) {
    return null;
  }
  const requestedScope = isApprovalScope(typed.scope) ? typed.scope : "once";
  const scope = decision === "approve" ? requestedScope : "once";
  const legacyDecision = legacyDecisionFor(decision, scope);
  return { decision, scope, legacyDecision };
}

export function parsePendingActionResponseBody(
  value: unknown,
  action?: Pick<PendingAction, "kind"> | null,
): PendingActionResponseInput | null {
  if (action?.kind === "user_input") {
    return parsePendingActionUserInputResponse(value);
  }
  if (action?.kind === "elicitation") {
    return parsePendingActionElicitationResponse(value);
  }
  if (!value || typeof value !== "object") {
    return null;
  }

  const typed = value as Record<string, unknown>;
  if (typed.approvalDecision !== undefined && typed.approvalDecision !== null) {
    return parsePendingActionDecision(typed.approvalDecision);
  }
  if (isDecisionKind(typed.decision)) {
    return parsePendingActionDecision(typed);
  }
  return parsePendingActionDecision(typed.decision);
}

export function parsePendingActionUserInputResponse(
  value: unknown,
): PendingActionUserInputResponse | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const typed = value as Record<string, unknown>;
  const answer = typed.answer;
  if (typeof answer !== "string") {
    return null;
  }
  return {
    answer,
    wasFreeform: typed.wasFreeform !== false,
  };
}

export function parsePendingActionElicitationResponse(
  value: unknown,
): PendingActionElicitationResponse | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const typed = value as Record<string, unknown>;
  const action = typed.action;
  if (action !== "accept" && action !== "decline" && action !== "cancel") {
    return null;
  }
  const content = normalizeElicitationContent(typed.content);
  if (typed.content !== undefined && content == null) {
    return null;
  }
  return {
    action,
    ...(content == null ? {} : { content }),
  };
}

export function normalizePendingActionDecision(
  value: PendingActionDecisionInput,
): NormalizedPendingActionDecision | null {
  return parsePendingActionDecision(value);
}

export function legacyDecisionFor(
  decision: PendingActionDecisionKind,
  scope: PendingActionApprovalScope,
): PendingActionDecisionId {
  if (decision === "decline") {
    return "decline";
  }
  if (decision === "cancel") {
    return "cancel";
  }
  if (scope === "location") {
    return "acceptForLocation";
  }
  if (scope === "session") {
    return "acceptForSession";
  }
  return "accept";
}

export function toPublicPendingAction(action: PendingAction): PendingAction {
  return {
    id: action.id,
    sessionId: action.sessionId,
    kind: action.kind,
    title: action.title,
    detail: action.detail,
    requestedAt: action.requestedAt,
    canApprove: action.canApprove,
    canApproveForSession: action.canApproveForSession,
    canDecline: action.canDecline,
    ...(action.sessionTitle === undefined
      ? {}
      : { sessionTitle: action.sessionTitle }),
    ...(action.cwd === undefined ? {} : { cwd: action.cwd }),
    ...(action.approval === undefined ? {} : { approval: action.approval }),
    ...(action.userInput === undefined ? {} : { userInput: action.userInput }),
    ...(action.elicitation === undefined
      ? {}
      : { elicitation: action.elicitation }),
  };
}

export function buildPendingActionResponseMessage(
  action: Pick<PendingAction, "kind" | "title" | "userInput" | "elicitation">,
  response: PendingActionResponseInput,
  options: {
    id: string;
    createdAt: number;
    seq: number;
  },
): SessionMessage | null {
  if (action.kind === "user_input") {
    if (
      !response ||
      typeof response !== "object" ||
      !("answer" in response) ||
      typeof response.answer !== "string"
    ) {
      return null;
    }
    const text = response.answer.trim();
    if (!text) {
      return null;
    }
    return {
      id: options.id,
      role: "user",
      text,
      attachments: [],
      createdAt: options.createdAt,
      seq: options.seq,
    };
  }

  if (action.kind !== "elicitation") {
    return null;
  }
  if (
    !response ||
    typeof response !== "object" ||
    !("action" in response) ||
    (response.action !== "accept" &&
      response.action !== "decline" &&
      response.action !== "cancel")
  ) {
    return null;
  }
  if (response.action !== "accept") {
    return null;
  }

  const text = buildElicitationResponseText(action, response.content);
  if (!text) {
    return null;
  }
  return {
    id: options.id,
    role: "user",
    text,
    attachments: [],
    createdAt: options.createdAt,
    seq: options.seq,
  };
}

export function buildPendingActionQuestionMessage(
  action: Pick<
    PendingAction,
    "kind" | "title" | "detail" | "userInput" | "elicitation"
  >,
  options: {
    id: string;
    createdAt: number;
    seq: number;
  },
): SessionMessage | null {
  if (action.kind === "user_input") {
    const question =
      action.userInput?.question?.trim() ||
      action.detail.trim() ||
      action.title.trim() ||
      "Agent question";
    const choices = (action.userInput?.choices ?? [])
      .map((choice) => choice.trim())
      .filter((choice) => choice.length > 0);
    const lines = [`**Model asked:** ${question}`];
    if (choices.length > 0) {
      lines.push("", "**Options:**", ...choices.map((choice) => `- ${choice}`));
    }
    if (action.userInput?.allowFreeform === true && choices.length > 0) {
      lines.push("", "You can also type a custom answer.");
    }
    return {
      id: options.id,
      role: "assistant",
      text: lines.join("\n"),
      attachments: [],
      createdAt: options.createdAt,
      seq: options.seq,
      phase: "question",
    };
  }

  if (action.kind !== "elicitation") {
    return null;
  }

  const message =
    action.elicitation?.message?.trim() ||
    action.detail.trim() ||
    action.title.trim() ||
    "Input requested";
  const lines = [`**Model requested input:** ${message}`];
  if (action.elicitation?.mode === "url" && action.elicitation.url) {
    lines.push("", action.elicitation.url);
  }
  const fields = action.elicitation?.fields ?? [];
  if (fields.length > 0) {
    lines.push(
      "",
      "**Fields:**",
      ...fields.map((field) =>
        field.required ? `- ${field.title} (required)` : `- ${field.title}`,
      ),
    );
  }
  return {
    id: options.id,
    role: "assistant",
    text: lines.join("\n"),
    attachments: [],
    createdAt: options.createdAt,
    seq: options.seq,
    phase: "question",
  };
}

function decisionFromLegacy(value: string): NormalizedPendingActionDecision | null {
  if (!isLegacyDecision(value)) {
    return null;
  }
  switch (value) {
    case "accept":
      return { decision: "approve", scope: "once", legacyDecision: value };
    case "acceptForSession":
      return { decision: "approve", scope: "session", legacyDecision: value };
    case "acceptForLocation":
      return { decision: "approve", scope: "location", legacyDecision: value };
    case "decline":
      return { decision: "decline", scope: "once", legacyDecision: value };
    case "cancel":
      return { decision: "cancel", scope: "once", legacyDecision: value };
  }
}

function isLegacyDecision(value: unknown): value is PendingActionDecisionId {
  return typeof value === "string" && LEGACY_DECISIONS.has(value as PendingActionDecisionId);
}

function isDecisionKind(value: unknown): value is PendingActionDecisionKind {
  return value === "approve" || value === "decline" || value === "cancel";
}

function isApprovalScope(value: unknown): value is PendingActionApprovalScope {
  return value === "once" || value === "session" || value === "location";
}

function normalizeElicitationContent(
  value: unknown,
): Record<string, PendingActionElicitationFieldValue> | null {
  if (value === undefined) {
    return null;
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const result: Record<string, PendingActionElicitationFieldValue> = {};
  for (const [key, fieldValue] of Object.entries(value)) {
    if (!isElicitationFieldValue(fieldValue)) {
      return null;
    }
    result[key] = fieldValue;
  }
  return result;
}

function buildElicitationResponseText(
  action: Pick<PendingAction, "title" | "elicitation">,
  content: Record<string, PendingActionElicitationFieldValue> | undefined,
): string | null {
  if (action.elicitation?.mode === "url") {
    return "Continued browser sign-in";
  }
  if (!content || Object.keys(content).length === 0) {
    return action.title.trim() || "Submitted form";
  }

  const labels = new Map(
    (action.elicitation?.fields ?? []).map((field) => [field.key, field.title]),
  );
  const seen = new Set<string>();
  const lines: string[] = [];

  for (const field of action.elicitation?.fields ?? []) {
    if (!(field.key in content)) {
      continue;
    }
    seen.add(field.key);
    lines.push(`${field.title}: ${formatElicitationFieldValue(content[field.key]!)}`);
  }

  for (const [key, value] of Object.entries(content)) {
    if (seen.has(key)) {
      continue;
    }
    lines.push(
      `${labels.get(key) || humanizeFieldKey(key)}: ${formatElicitationFieldValue(value)}`,
    );
  }

  const text = lines.join("\n");
  return text.trim() || null;
}

function formatElicitationFieldValue(
  value: PendingActionElicitationFieldValue,
): string {
  if (Array.isArray(value)) {
    return value.join(", ");
  }
  if (typeof value === "boolean") {
    return value ? "Yes" : "No";
  }
  return String(value);
}

function humanizeFieldKey(value: string): string {
  return value
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/[_-]+/g, " ")
    .trim()
    .replace(/\s+/g, " ")
    .replace(/^./, (match) => match.toUpperCase());
}

function isElicitationFieldValue(
  value: unknown,
): value is PendingActionElicitationFieldValue {
  if (
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return true;
  }
  if (!Array.isArray(value)) {
    return false;
  }
  return value.every((item) => typeof item === "string");
}
