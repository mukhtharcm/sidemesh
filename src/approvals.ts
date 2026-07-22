import type {
  PendingAction,
  PendingActionApprovalScope,
  PendingActionDecisionId,
  PendingActionDecisionKind,
  PendingActionDecisionRequest,
  PendingActionProviderOptionRequest,
  PendingActionElicitationFieldValue,
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
  | PendingActionProviderOptionRequest
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
  const providerOption = parsePendingActionProviderOptionResponse(typed);
  if (providerOption) {
    return providerOption;
  }
  if (typed.approvalDecision !== undefined && typed.approvalDecision !== null) {
    return parsePendingActionDecision(typed.approvalDecision);
  }
  if (isDecisionKind(typed.decision)) {
    return parsePendingActionDecision(typed);
  }
  return parsePendingActionDecision(typed.decision);
}

export function parsePendingActionProviderOptionResponse(
  value: unknown,
): PendingActionProviderOptionRequest | null {
  if (!value || typeof value !== "object") {
    return null;
  }
  const optionId = (value as Record<string, unknown>).providerOptionId;
  if (typeof optionId !== "string" || !optionId.trim()) {
    return null;
  }
  return { providerOptionId: optionId.trim() };
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
