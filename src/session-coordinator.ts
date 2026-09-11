import { randomUUID } from "node:crypto";
import { isDeepStrictEqual } from "node:util";

import { materializeAgentActivityDraft, type AgentPendingAction, type AgentProviderLiveEvent,
  type AgentSessionLogOptions, type AgentSessionSnapshot } from "./agent-provider.js";
import { appendCommandActivityOutput, applyCommandTerminalInteraction, mergeActivity, mergeSessionActivities } from "./activity.js";
import { toPublicPendingAction } from "./approvals.js";
import { SessionInputCoordinator } from "./session-input-coordinator.js";
import { SessionStore, type SessionRecoveryItem } from "./session-store.js";
import type { ActiveTurnState, LatestPlanUpdate, LiveEvent, LiveThreadStatus, SessionActivity, SessionMessage, SessionRuntimeSummary } from "./types.js";

export interface SessionRuntimeCacheEntry {
  threadUpdatedAt: number;
  runtime: SessionRuntimeSummary | null;
  promise?: Promise<SessionRuntimeSummary | null>;
}

interface SessionState {
  activeTurn: ActiveTurnState | null;
  busy: boolean;
  status: LiveThreadStatus | null;
  executionRevision: number;
  activities: Map<string, SessionActivity>;
  messages: Map<string, SessionRecoveryItem & { kind: "message" }>;
  runtime: SessionRuntimeCacheEntry | null;
  nextSeq: number;
  revision: number;
  draftId: string | null;
}

type InputCallbacks = ConstructorParameters<typeof SessionInputCoordinator>[1];

/** One published session view and one durable input path. Adapters own native execution. */
export class SessionCoordinator {
  private readonly sessions = new Map<string, SessionState>();
  private readonly reads = new Map<string, Promise<unknown>>();
  readonly pendingActions = new Map<string, AgentPendingAction>();
  readonly inputs: SessionInputCoordinator;

  constructor(private readonly store: SessionStore, private readonly callbacks: {
    readSnapshot(id: string, options?: AgentSessionLogOptions): Promise<AgentSessionSnapshot>;
    publish(event: LiveEvent): void;
    input: Omit<InputCallbacks, "runState" | "queueChanged" | "warning">;
  }) {
    this.inputs = new SessionInputCoordinator(store, {
      ...callbacks.input,
      runState: async (id) => {
        const snapshot = await this.snapshot(id, { messageLimit: 1, activityLimit: 1 });
        return { turnId: snapshot.activeTurnId, busy: snapshot.busy || snapshot.status === "unknown" };
      },
      queueChanged: (id, queued) => {
        if (callbacks.input.canSteer(id)) return;
        this.publish({ type: "queue_updated", sessionId: id, steeringCount: 0, followUpCount: queued.length,
          steeringPreview: [], followUpPreview: queued.map((item) => item.payload?.input.flatMap((input) => input.type === "text" ? [input.text] : []).join("\n") ?? "") });
      },
      warning: (id, error) => this.publish({ type: "provider_warning", sessionId: id, level: "warning",
        code: "queued_input_failed", message: error instanceof Error ? error.message : String(error) }),
    });
  }

  get(id: string): SessionState {
    let state = this.sessions.get(id);
    if (!state) {
      state = { activeTurn: null, busy: false, status: null, executionRevision: 0,
        activities: new Map(), messages: new Map(), runtime: null, nextSeq: 0, revision: 0, draftId: null };
      for (const item of this.store.readRecovery(id)) {
        if (item.kind === "activity") state.activities.set(item.value.id, item.value);
        // A recovered draft is display content. Only a new native event can make it live again.
        else state.messages.set(item.value.id, item);
        state.nextSeq = Math.max(state.nextSeq, item.value.seq + 1);
      }
      state.nextSeq = Math.max(state.nextSeq, (this.store.getPlan(id)?.seq ?? -1) + 1);
      this.sessions.set(id, state);
    }
    return state;
  }

  keys(): IterableIterator<string> { return this.sessions.keys(); }
  values(): IterableIterator<SessionState> { return this.sessions.values(); }
  get size(): number { return this.sessions.size; }
  allocSeq(id: string): number { return this.get(id).nextSeq++; }

  /** Stamp after the state mutation and durable write, before any socket receives it. */
  publish(event: LiveEvent): LiveEvent {
    const state = this.get(event.sessionId);
    const stamped = { ...event, seq: event.seq ?? this.allocSeq(event.sessionId), revision: ++state.revision };
    this.callbacks.publish(stamped);
    return stamped;
  }

  private execution(id: string, busy: boolean, turnId: string | null, status: LiveThreadStatus): void {
    const state = this.get(id);
    state.busy = busy;
    state.activeTurn = turnId ? { turnId, startedAt: state.activeTurn?.turnId === turnId ? state.activeTurn.startedAt : Date.now() } : null;
    state.status = status;
    state.executionRevision = state.revision + 1;
  }

  private saveMessage(id: string, item: SessionRecoveryItem & { kind: "message" }): void {
    this.store.putRecovery(id, item);
    this.get(id).messages.set(item.value.id, item);
  }

  private saveActivity(id: string, activity: SessionActivity): void {
    this.store.putRecovery(id, { kind: "activity", nativeId: activity.id, authority: "recovery", value: activity });
    this.get(id).activities.set(activity.id, activity);
  }

  private finishDraft(id: string): void {
    const state = this.get(id);
    state.draftId = null;
  }

  private appendDraft(event: Extract<AgentProviderLiveEvent, { type: "assistant_delta" | "reasoning_delta" }>): void {
    const state = this.get(event.sessionId);
    const current = state.draftId ? state.messages.get(state.draftId) : undefined;
    const id = event.type === "reasoning_delta" ? state.draftId ?? `draft:${randomUUID()}`
      : event.itemId ?? state.draftId ?? `draft:${randomUUID()}`;
    const movingReasoning = event.type === "assistant_delta" && current?.value.text === "" && current.value.id !== id;
    const previous = state.messages.get(id) ?? (movingReasoning ? current : undefined);
    if (state.draftId && state.draftId !== id) this.finishDraft(event.sessionId);
    const message: SessionMessage = previous ? { ...previous.value, id } : { id, role: "assistant", text: "", content: [], attachments: [], createdAt: Date.now(), seq: this.allocSeq(event.sessionId) };
    const value = event.type === "assistant_delta"
      ? { ...message, text: message.text + event.delta, content: [...message.content.filter((part) => part.type !== "text"), { type: "text" as const, text: message.text + event.delta }] }
      : { ...message, content: appendReasoning(message.content, event) };
    this.saveMessage(event.sessionId, { kind: "message", nativeId: event.type === "assistant_delta" ? event.itemId ?? null : null,
      authority: "recovery", value, draft: true, turnId: event.turnId });
    if (movingReasoning && current) {
      state.messages.delete(current.value.id);
      this.store.deleteRecovery(event.sessionId, "message", current.value.id);
    }
    state.draftId = id;
  }

  handle(event: AgentProviderLiveEvent): void {
    if (event.type === "input_confirmed") { this.store.confirmInputs(event.sessionId, [event.clientInputId]); return; }
    if (event.type === "skills_changed" || (event.type === "provider_warning" && !event.sessionId)) return;
    if (event.type === "action_opened") {
      this.pendingActions.set(event.action.id, event.action);
      const state = this.get(event.action.sessionId);
      this.execution(event.action.sessionId, true, state.activeTurn?.turnId ?? null, "waiting_for_approval");
      this.publish({ type: event.type, sessionId: event.action.sessionId, action: toPublicPendingAction(event.action) });
      return;
    }
    const id = event.sessionId!;
    const state = this.get(id);
    switch (event.type) {
      case "turn_started":
        this.finishDraft(id);
        this.execution(id, true, event.turnId, "running");
        break;
      case "assistant_delta":
      case "reasoning_delta":
        this.appendDraft(event);
        break;
      case "assistant_message_completed": {
        const candidate = state.draftId ? state.messages.get(state.draftId) : undefined;
        const draft = candidate && (!event.turnId || !candidate.turnId || event.turnId === candidate.turnId) ? candidate : undefined;
        const seq = draft?.value.seq ?? this.allocSeq(id);
        const message: SessionMessage = { id: event.message.id, role: "assistant", text: event.message.text,
          content: event.message.content?.length ? event.message.content : [...(draft?.value.content.filter((part) => part.type === "thinking") ?? []), { type: "text", text: event.message.text }],
          attachments: event.message.attachments ?? [],
          createdAt: draft?.value.createdAt ?? Date.now(), seq, phase: event.message.phase };
        this.saveMessage(id, { kind: "message", value: message, nativeId: message.id, authority: "recovery", turnId: event.turnId });
        if (draft) {
          if (draft.value.id !== message.id) {
            state.messages.delete(draft.value.id);
            this.store.deleteRecovery(id, "message", draft.value.id);
          }
          state.draftId = null;
        }
        this.publish({ type: event.type, sessionId: id, turnId: event.turnId, seq, messageItem: message });
        return;
      }
      case "activity_updated": {
        const previous = state.activities.get(event.activity.id);
        let activity = materializeAgentActivityDraft(event.activity, { createdAt: previous?.createdAt ?? Date.now(), seq: previous?.seq ?? this.allocSeq(id) });
        if (previous?.type === "file_change" && activity.type === "file_change" && activity.status === "in_progress") activity = { ...activity, status: previous.status };
        activity = mergeActivity(previous, activity);
        this.saveActivity(id, activity);
        this.publish({ type: "activity_updated", sessionId: id, turnId: event.turnId, activity });
        return;
      }
      case "activity_output_delta":
      case "activity_terminal_input": {
        const previous = state.activities.get(event.activityId);
        if (!previous || (previous.type !== "command" && previous.type !== "tool")) return;
        const activity = event.type === "activity_output_delta" ? appendCommandActivityOutput(previous, event.delta)
          : previous.type === "command" ? applyCommandTerminalInteraction(previous, event.stdin) : null;
        if (activity) {
          this.saveActivity(id, activity);
          this.publish({ type: "activity_updated", sessionId: id, turnId: event.turnId, activity });
        }
        return;
      }
      case "runtime_updated": {
        const previous = state.runtime?.runtime;
        const runtime = event.runtime ? { ...previous, ...event.runtime, telemetry: { ...previous?.telemetry, ...event.runtime.telemetry } } : previous ?? null;
        state.runtime = { threadUpdatedAt: Date.now() / 1000, runtime };
        this.publish({ ...event, runtime: runtime ?? undefined });
        return;
      }
      case "thread_status_changed":
        this.execution(id, runningStatus(event.status), runningStatus(event.status) ? state.activeTurn?.turnId ?? null : null, event.status);
        break;
      case "plan_updated": {
        const seq = this.allocSeq(id);
        this.store.setPlan(id, { ...event, seq });
        this.publish({ ...event, seq });
        return;
      }
      case "turn_completed":
        // A delayed completion for an older turn must not stop a newer native turn.
        if (!state.activeTurn || state.activeTurn.turnId === event.turnId) {
          this.finishDraft(id);
          this.execution(id, false, null, /error|fail/i.test(event.status) ? "errored" : "idle");
          this.clearActions(id);
        }
        this.publish(event);
        this.inputs.wake(id);
        return;
      case "action_resolved":
        if (!this.pendingActions.delete(event.actionId)) return;
        this.execution(id, state.busy, state.activeTurn?.turnId ?? null, this.actionFor(id) ? "waiting_for_approval" : state.busy ? "running" : "idle");
        break;
    }
    this.publish({ ...event, sessionId: id });
  }

  clearActions(id: string): void {
    for (const action of this.pendingActions.values()) {
      if (action.sessionId !== id) continue;
      this.pendingActions.delete(action.id);
      this.publish({ type: "action_resolved", sessionId: id, actionId: action.id });
    }
  }

  invalidate(id: string): void {
    const state = this.get(id);
    this.finishDraft(id);
    this.clearActions(id);
    state.runtime = null;
    this.execution(id, false, null, "unknown");
    this.publish({ type: "history_invalidated", sessionId: id });
  }

  snapshot(id: string, options: AgentSessionLogOptions = {}) {
    const previous = this.reads.get(id);
    const reading = previous ? previous.catch(() => {}).then(() => this.readSnapshot(id, options)) : this.readSnapshot(id, options);
    this.reads.set(id, reading);
    void reading.finally(() => { if (this.reads.get(id) === reading) this.reads.delete(id); }).catch(() => {});
    return reading;
  }

  private async readSnapshot(id: string, options: AgentSessionLogOptions) {
    const state = this.get(id);
    const startRevision = state.revision;
    const runtimeBeforeRead = state.runtime;
    const native = await this.callbacks.readSnapshot(id);
    // No await after this point: every covered event must be represented in this view.
    const previousStatus = state.status;
    if (state.executionRevision <= startRevision) {
      if (!native.busy) this.clearActions(id);
      state.busy = native.busy;
      state.activeTurn = native.activeTurnId ? { turnId: native.activeTurnId, startedAt: state.activeTurn?.startedAt ?? Date.now() } : null;
      const status = normalizedStatus(native.thread.status.phase ?? native.thread.status.type);
      state.status = native.busy ? (this.actionFor(id) ? "waiting_for_approval" : runningStatus(status) ? status : "running") : runningStatus(status) ? "idle" : status;
    }
    if (state.status !== previousStatus) this.publish({ type: "thread_status_changed", sessionId: id, status: state.status ?? "unknown" });
    if (state.runtime === runtimeBeforeRead) state.runtime = { threadUpdatedAt: native.thread.updatedAt, runtime: native.runtime };
    this.store.confirmInputs(id, native.confirmedInputIds ?? []);
    // Reconcile the complete native view before applying client limits. Rebase
    // events received before the first snapshot after the native transcript.
    const positions = new Map<string, number>([
      ...native.messages.map((item): [string, number] => [`message:${item.id}`, item.seq]),
      ...native.activities.map((item): [string, number] => [`activity:${item.id}`, item.seq]),
    ]);
    const recovery: SessionRecoveryItem[] = [...state.messages.values(),
      ...[...state.activities.values()].map((value): SessionRecoveryItem => ({ kind: "activity", nativeId: value.id, authority: "recovery", value }))];
    let cursor = native.nextSeq;
    for (const item of recovery.sort((left, right) => left.value.seq - right.value.seq)) {
      const nativeSeq = positions.get(`${item.kind}:${item.value.id}`);
      const seq = nativeSeq ?? Math.max(cursor, item.value.seq);
      if (nativeSeq == null) cursor = seq + 1;
      if (seq !== item.value.seq) {
        if (item.kind === "message") this.saveMessage(id, { ...item, value: { ...item.value, seq } });
        else this.saveActivity(id, { ...item.value, seq });
      }
    }
    state.nextSeq = Math.max(state.nextSeq, cursor);
    const messages = [...native.messages];
    for (const item of state.messages.values()) {
      const index = messages.findIndex((message) => message.id === item.value.id);
      const saved = index >= 0 ? messages[index]! : null;
      if (saved && (messageCovered(saved, item.value, item.draft === true))) {
        state.messages.delete(item.value.id);
        this.store.deleteRecovery(id, "message", item.value.id);
        if (state.draftId === item.value.id) state.draftId = null;
        continue;
      }
      if (item.draft && state.busy && state.draftId === item.value.id) continue;
      if (index >= 0) messages[index] = item.value;
      else messages.push(item.value);
    }
    for (const activity of native.activities) {
      const live = state.activities.get(activity.id);
      if (!live) continue;
      if (activityCovered(activity, live)) {
        state.activities.delete(activity.id);
        this.store.deleteRecovery(id, "activity", activity.id);
      } else if (activity.status !== "in_progress" && live.status === "in_progress") {
        this.saveActivity(id, { ...live, status: activity.status });
      }
    }
    const activities = mergeSessionActivities(native.activities, [...state.activities.values()]);
    const plan = latestPlan(native.latestPlanUpdate, this.store.getPlan(id));
    state.nextSeq = Math.max(state.nextSeq, native.nextSeq, (plan?.seq ?? -1) + 1);
    const draft = state.busy && state.draftId ? state.messages.get(state.draftId)?.value : null;
    const messageLimit = options.messageLimit ?? messages.length;
    const activityLimit = options.activityLimit ?? activities.length;
    return { ...native, messages: messages.slice(-messageLimit), activities: activities.slice(-activityLimit),
      totalMessages: native.totalMessages + Math.max(0, messages.length - native.messages.length),
      totalActivities: Math.max(native.totalActivities, activities.length),
      runtime: state.runtime?.runtime ?? native.runtime, latestPlanUpdate: plan,
      busy: state.busy, activeTurnId: state.activeTurn?.turnId ?? null, status: state.status ?? "unknown",
      revision: state.revision, nextSeq: state.nextSeq,
      liveAssistantText: draft?.text ?? "", liveAssistantReasoning: draft ? reasoningText(draft) : "" };
  }

  actionFor(id: string): AgentPendingAction | null {
    return [...this.pendingActions.values()].find((action) => action.sessionId === id) ?? null;
  }
}

function sameContent(left: SessionMessage | SessionActivity, right: SessionMessage | SessionActivity): boolean {
  const { seq: _seq, createdAt: _time, ...a } = left;
  const { seq: _otherSeq, createdAt: _otherTime, ...b } = right;
  if ("type" in left && "type" in right && left.type === "tool" && right.type === "tool") return isDeepStrictEqual({ ...a, turnId: null, attachments: left.attachments ?? [] }, { ...b, turnId: null, attachments: right.attachments ?? [] });
  if ("turnId" in a && "turnId" in b) return isDeepStrictEqual({ ...a, turnId: null }, { ...b, turnId: null });
  return isDeepStrictEqual(a, b);
}

function activityCovered(saved: SessionActivity, local: SessionActivity): boolean {
  if (sameContent(saved, local)) return true;
  if (saved.type !== local.type || saved.status === "in_progress") return false;
  if ((saved.type === "command" && local.type === "command") || (saved.type === "tool" && local.type === "tool")) {
    if (!(saved.output ?? "").startsWith(local.output ?? "")) return false;
    if (local.type === "tool" && saved.type === "tool") {
      if ((local.attachments ?? []).some((attachment) => !saved.attachments?.some((other) => isDeepStrictEqual(other, attachment)))) return false;
      if (local.result != null && !isDeepStrictEqual(local.result, saved.result)) return false;
    }
    return sameContent(mergeActivity(local, saved), saved);
  }
  return false;
}

function reasoningText(message: SessionMessage): string {
  return message.content.flatMap((part) => part.type === "thinking" ? [part.thinking] : []).join("");
}

function appendReasoning(content: SessionMessage["content"], event: Extract<AgentProviderLiveEvent, { type: "reasoning_delta" }>): SessionMessage["content"] {
  const index = content.findIndex((part) => part.type === "thinking" && part.reasoningId === event.reasoningId && part.summary === event.summary);
  return index < 0 ? [...content, { type: "thinking", thinking: event.delta, reasoningId: event.reasoningId, summary: event.summary }]
    : content.map((part, i) => i === index && part.type === "thinking" ? { ...part, thinking: part.thinking + event.delta } : part);
}

function messageCovered(saved: SessionMessage, local: SessionMessage, partial: boolean): boolean {
  return saved.role === local.role && (partial ? saved.text.startsWith(local.text) : saved.text === local.text)
    && reasoningText(saved).startsWith(reasoningText(local))
    && local.attachments.every((attachment) => saved.attachments.some((other) => isDeepStrictEqual(other, attachment)))
    && (!local.phase || saved.phase === local.phase);
}

function latestPlan(...plans: Array<LatestPlanUpdate | null | undefined>): LatestPlanUpdate | null {
  return plans.filter((plan): plan is LatestPlanUpdate => !!plan).sort((a, b) => (b.seq ?? -1) - (a.seq ?? -1))[0] ?? null;
}

function runningStatus(status: LiveThreadStatus): boolean {
  return status === "running" || status === "waiting_for_input" || status === "waiting_for_approval";
}

function normalizedStatus(value: string): LiveThreadStatus {
  if (value === "active") return "running";
  if (value === "notLoaded") return "closed";
  if (value === "systemError") return "errored";
  return ["idle", "running", "waiting_for_input", "waiting_for_approval", "errored", "closed"].includes(value) ? value as LiveThreadStatus : "unknown";
}
