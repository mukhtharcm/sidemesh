/** Coalesces snapshot writes while acknowledging only durably saved requests. */
export class StateWriter {
  private generation = 0;
  private attempted = 0;
  private flushed = 0;
  private loop: Promise<void> | null = null;
  private readonly waiters = new Set<{
    generation: number;
    resolve(): void;
    reject(error: unknown): void;
  }>();

  public constructor(private readonly save: () => Promise<void>) {}

  public request(): Promise<void> {
    const generation = ++this.generation;
    const promise = new Promise<void>((resolve, reject) => {
      this.waiters.add({ generation, resolve, reject });
    });
    this.startLoop();
    return promise;
  }

  private startLoop(): void {
    if (this.loop) return;
    this.loop = Promise.resolve().then(() => this.run());
    void this.loop.then(() => {
      this.loop = null;
      if (this.attempted < this.generation) this.startLoop();
    });
  }

  public async flush(): Promise<void> {
    while (this.loop) await this.loop;
    // Retry a failed final write once during shutdown.
    if (this.flushed < this.generation) await this.request();
    while (this.loop) await this.loop;
  }

  private async run(): Promise<void> {
    while (this.attempted < this.generation) {
      const failedGeneration = this.attempted + 1;
      const target = this.generation;
      try {
        await this.save();
        this.flushed = target;
        this.attempted = target;
        this.settle(target);
      } catch (error) {
        // A request arriving during a failed write still gets its own attempt.
        this.attempted = failedGeneration;
        this.settle(failedGeneration, error);
      }
    }
  }

  private settle(generation: number, error?: unknown): void {
    for (const waiter of this.waiters) {
      if (waiter.generation > generation) continue;
      this.waiters.delete(waiter);
      if (error !== undefined) waiter.reject(error);
      else waiter.resolve();
    }
  }
}
