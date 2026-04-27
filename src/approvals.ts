import type {
  PendingAction,
  PendingActionApprovalScope,
  PendingActionDecisionId,
  PendingActionDecisionKind,
  PendingActionDecisionRequest,
} from "./types.js";

export type PendingActionDecisionInput =
  | PendingActionDecisionRequest
  | PendingActionDecisionId
  | null
  | undefined;

const LEGACY_DECISIONS = new Set<PendingActionDecisionId>([
  "accept",
  "acceptForSession",
  "acceptForLocation",
  "decline",
  "cancel",
]);

export function parsePendingActionDecision(
  value: unknown,
): PendingActionDecisionRequest | null {
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
  const scope = isApprovalScope(typed.scope) ? typed.scope : "once";
  const legacyDecision = legacyDecisionFor(decision, scope);
  return { decision, scope, legacyDecision };
}

export function parsePendingActionResponseBody(
  value: unknown,
): PendingActionDecisionRequest | null {
  if (!value || typeof value !== "object") {
    return null;
  }

  const typed = value as Record<string, unknown>;
  if ("approvalDecision" in typed) {
    return parsePendingActionDecision(typed.approvalDecision);
  }
  if (isDecisionKind(typed.decision)) {
    return parsePendingActionDecision(typed);
  }
  return parsePendingActionDecision(typed.decision);
}

export function normalizePendingActionDecision(
  value: PendingActionDecisionInput,
): PendingActionDecisionRequest | null {
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
  };
}

function decisionFromLegacy(value: string): PendingActionDecisionRequest | null {
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
