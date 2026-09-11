import { AgentProviderRequestError, type AgentSubmitInputRequest, type AgentSubmitInputResult } from "./agent-provider.js";
import { SessionStore, type SessionInputRecord, type SessionInputReceipt } from "./session-store.js";

export class SessionInputError extends AgentProviderRequestError {
  constructor(readonly code: string, message: string, status = 409) { super(message, status, true); }
}

type InputRequest = Omit<SessionInputRecord, "state" | "receipt">;

/** One host-owned dispatch path. SQLite owns the queue and all delivery receipts. */
export class SessionInputCoordinator {
  private readonly locks = new Map<string, Promise<unknown>>();
  private readonly stopping = new Set<string>();
  private closed = false;

  constructor(private readonly store: SessionStore, private readonly callbacks: {
    canSteer(sessionId: string): boolean;
    runState(sessionId: string): Promise<{ turnId: string | null; busy: boolean }>;
    prepare(sessionId: string, payload: NonNullable<SessionInputRecord["payload"]>): Promise<NonNullable<SessionInputRecord["payload"]>>;
    dispatch(request: AgentSubmitInputRequest): Promise<AgentSubmitInputResult>;
    submitted(request: AgentSubmitInputRequest, receipt: SessionInputReceipt): Promise<void>;
    queueChanged(sessionId: string, queued: SessionInputRecord[]): void;
    warning(sessionId: string, error: unknown): void;
  }) {}

  submit(request: InputRequest): Promise<SessionInputReceipt & { replayed: boolean }> {
    this.assertOpen(request.sessionId);
    return this.exclusive(request.sessionId, async () => {
      this.assertOpen(request.sessionId);
      const existing = this.store.getInput(request.key);
      if (existing) {
        if (existing.signatureHash !== request.signatureHash) {
          throw new SessionInputError("input_id_conflict", "clientMessageId was already used with different input");
        }
        if (existing.state === "uncertain" || existing.state === "dispatching") {
          throw new SessionInputError("input_delivery_uncertain", "The agent may have received this input. Check the session before sending it again.");
        }
        if (existing.state === "cancelled") {
          throw new SessionInputError("input_cancelled", "This input was cancelled. Send it with a new message ID to start it again.");
        }
        if (existing.receipt) return { ...existing.receipt, replayed: true };
      } else {
        this.store.prepareInput(request);
      }
      const state = await this.callbacks.runState(request.sessionId);
      this.assertOpen(request.sessionId);
      if ((!this.callbacks.canSteer(request.sessionId) && state.busy) || this.store.queuedInputs(request.sessionId).length) {
        if (!request.payload) throw new Error("Input payload is missing");
        const payload = await this.callbacks.prepare(request.sessionId, request.payload);
        this.assertOpen(request.sessionId);
        const receipt = this.store.queueInput(request.key, this.messageId(request), payload);
        this.queueChanged(request.sessionId);
        this.wake(request.sessionId);
        return { ...receipt, replayed: false };
      }
      return { ...await this.dispatch(this.store.getInput(request.key)!, state.turnId), replayed: false };
    });
  }

  wake(sessionId: string): void {
    if (this.closed || this.stopping.has(sessionId)) return;
    void this.exclusive(sessionId, async () => {
      while (!this.closed && !this.stopping.has(sessionId)) {
        const next = this.store.queuedInputs(sessionId)[0];
        if (!next) return;
        const state = await this.callbacks.runState(sessionId);
        if (this.closed || this.stopping.has(sessionId) || state.busy) return;
        // Stop/archive may have cancelled this row while the native read waited.
        if (this.store.getInput(next.key)?.state !== "queued") continue;
        await this.dispatch(next, state.turnId);
      }
    }).catch((error: unknown) => {
      if (!this.closed) this.callbacks.warning(sessionId, error);
    });
  }

  recover(): void {
    for (const sessionId of this.store.queuedSessionIds()) this.wake(sessionId);
  }

  async stop(sessionId: string, operation: () => Promise<void>): Promise<void> {
    this.stopping.add(sessionId);
    this.store.cancelQueuedInputs(sessionId);
    this.queueChanged(sessionId);
    try { await this.exclusive(sessionId, operation); }
    finally { this.stopping.delete(sessionId); }
  }

  close(): void { this.closed = true; }
  async drain(): Promise<void> { await Promise.allSettled([...this.locks.values()]); }

  private async dispatch(record: SessionInputRecord, turnId: string | null): Promise<SessionInputReceipt> {
    if (!record.payload) throw new Error("Saved input payload is missing");
    const payload = await this.callbacks.prepare(record.sessionId, record.payload);
    this.assertOpen(record.sessionId);
    const request = { ...payload, sessionId: record.sessionId, activeTurnId: turnId, clientMessageId: this.messageId(record) };
    this.store.dispatchInput(record.key, payload);
    try {
      const result = await this.callbacks.dispatch(request);
      const receipt = { ...result, messageId: request.clientMessageId };
      this.store.acceptInput(record.key, receipt);
      this.queueChanged(record.sessionId);
      await this.callbacks.submitted(request, receipt);
      return receipt;
    } catch (error) {
      this.store.failInput(record.key, error instanceof AgentProviderRequestError && error.inputNotDispatched);
      this.queueChanged(record.sessionId);
      throw error;
    }
  }

  private messageId(record: InputRequest): string { return record.key.slice(record.sessionId.length + 1); }
  private queueChanged(sessionId: string): void { this.callbacks.queueChanged(sessionId, this.store.queuedInputs(sessionId)); }
  private assertOpen(sessionId: string): void {
    if (this.closed || this.stopping.has(sessionId)) throw new SessionInputError("session_stopping", "The session is stopping. Try again after it stops.", 503);
  }

  private exclusive<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.locks.get(sessionId) ?? Promise.resolve();
    const current = previous.catch(() => {}).then(operation);
    this.locks.set(sessionId, current);
    void current.finally(() => {
      if (this.locks.get(sessionId) === current) this.locks.delete(sessionId);
    }).catch(() => {});
    return current;
  }
}
