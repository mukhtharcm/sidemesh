import type { AgentSessionActivityDraft } from "./agent-provider.js";
import { materializeAgentActivityDraft } from "./agent-provider.js";
import { appendCommandActivityOutput, applyCommandTerminalInteraction, mergeActivity } from "./activity.js";
import type { ActiveTurnState, LiveThreadStatus, SessionActivity, SessionRuntimeSummary } from "./types.js";

export interface SessionRuntimeCacheEntry {
  threadUpdatedAt: number;
  runtime: SessionRuntimeSummary | null;
  promise?: Promise<SessionRuntimeSummary | null>;
}

interface SessionState {
  activeTurn: ActiveTurnState | null;
  unverifiedTurn: boolean;
  status: LiveThreadStatus | null;
  statusUpdatedAt: number;
  recoveredStatus: LiveThreadStatus | null;
  activities: Map<string, SessionActivity>;
  runtime: SessionRuntimeCacheEntry | null;
  nextSeq: number;
  revision: number;
  assistantText: string;
  assistantReasoning: string;
}

/** Owns the current session overlay. Provider history remains the durable transcript. */
export class SessionStateStore {
  private readonly sessions = new Map<string, SessionState>();

  public get(id: string): SessionState {
    let state = this.sessions.get(id);
    if (!state) {
      state = {
        activeTurn: null, unverifiedTurn: false, status: null, statusUpdatedAt: 0,
        recoveredStatus: null, activities: new Map(), runtime: null,
        nextSeq: 0, revision: 0, assistantText: "", assistantReasoning: "",
      };
      this.sessions.set(id, state);
    }
    return state;
  }

  public keys(): IterableIterator<string> { return this.sessions.keys(); }
  public values(): IterableIterator<SessionState> { return this.sessions.values(); }
  public get size(): number { return this.sessions.size; }

  public clearDraft(id: string): void {
    const state = this.get(id);
    state.assistantText = "";
    state.assistantReasoning = "";
  }

  public updateActivity(id: string, draft: AgentSessionActivityDraft, allocSeq: () => number): SessionActivity {
    const activities = this.get(id).activities;
    const previous = activities.get(draft.id);
    let activity = materializeAgentActivityDraft(draft, {
      createdAt: previous?.createdAt ?? Date.now(), seq: previous?.seq ?? allocSeq(),
    });
    if (previous?.type === "file_change" && activity.type === "file_change" && activity.status === "in_progress") {
      activity = { ...activity, status: previous.status };
    }
    const merged = mergeActivity(previous, activity);
    activities.set(merged.id, merged);
    return merged;
  }

  public appendOutput(id: string, activityId: string, delta: string): SessionActivity | null {
    const activities = this.get(id).activities;
    const activity = activities.get(activityId);
    if (!activity || (activity.type !== "command" && activity.type !== "tool")) return null;
    const updated = appendCommandActivityOutput(activity, delta);
    if (updated) activities.set(activityId, updated);
    return updated;
  }

  public terminalInput(id: string, activityId: string, stdin: string): SessionActivity | null {
    const activities = this.get(id).activities;
    const activity = activities.get(activityId);
    if (activity?.type !== "command") return null;
    const updated = applyCommandTerminalInteraction(activity, stdin);
    if (updated) activities.set(activityId, updated);
    return updated;
  }
}
