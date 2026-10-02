/**
 * Co-op reconnection policy: when to retry and how long to wait. No DOM, no sockets — the scene supplies `attempt`,
 * so the schedule, the error classification and the stop rules are unit-testable on their own.
 */

/** After a dropped link: 1 s, 2 s, 4 s, 8 s, then every 15 s, for as long as the scene is mounted. */
export function rejoinDelayMs(attempt: number): number {
  return Math.min(15000, 1000 * 2 ** Math.max(0, attempt));
}

/** First connect found the service down: stay quiet and look again every 10 s, 20 s, then every 30 s. */
export function firstConnectDelayMs(attempt: number): number {
  return Math.min(30000, 10000 * (Math.max(0, attempt) + 1));
}

export type ReconnectMode = 'first' | 'rejoin';

/**
 * Is this failure worth retrying? The service being down or unreachable always is. Rejoining after a drop also retries
 * "already in this world" (the server may not have reaped our old socket yet). Not configured, auth failures and
 * join rejections written for the player (e.g. "That world is full") are final.
 */
export function isRetryableError(err: unknown, mode: ReconnectMode): boolean {
  const msg = err instanceof Error ? err.message : String(err ?? '');
  if (/not configured|not authenticated/i.test(msg)) return false;
  if (/unreachable|timeout|timed out|xhr poll error|websocket error|transport|network|ECONNREFUSED|failed to fetch/i.test(msg)) return true;
  if (mode === 'rejoin' && /already in (this|a) world/i.test(msg)) return true;
  return false;
}

export interface ReconnectorOptions {
  mode: ReconnectMode;
  /** One try; reject on failure. Success ends the retry loop. */
  attempt(): Promise<void>;
  /** A non-retryable failure ended the loop. */
  onGiveUp?(err: Error): void;
  /** A retryable failure; `delayMs` is the wait before the next try. */
  onRetry?(n: number, delayMs: number, err: Error | null): void;
  /** Injectable for tests. */
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (id: unknown) => void;
}

/** Runs `attempt` with backoff until it works, fails for good, or `stop()` is called. */
export class Reconnector {
  private n = 0;
  private timer: unknown = null;
  private inFlight = false;
  private stopped = false;
  private finished = false;

  constructor(private readonly o: ReconnectorOptions) {}

  get active() {
    return !this.stopped && !this.finished;
  }

  /** Schedule the first try after the mode's initial delay. */
  start() {
    if (this.active && this.timer === null && !this.inFlight) this.schedule(null);
  }

  /** Try right now (network came back, tab visible again). The backoff counter keeps going if it fails. */
  kick() {
    if (!this.active || this.inFlight) return;
    this.clear();
    void this.run();
  }

  stop() {
    this.stopped = true;
    this.clear();
  }

  private delay() {
    return this.o.mode === 'rejoin' ? rejoinDelayMs(this.n) : firstConnectDelayMs(this.n);
  }

  private schedule(err: Error | null) {
    const ms = this.delay();
    this.o.onRetry?.(this.n, ms, err);
    this.n++;
    this.timer = (this.o.setTimer ?? setTimeout)(() => {
      this.timer = null;
      void this.run();
    }, ms);
  }

  private clear() {
    if (this.timer !== null) (this.o.clearTimer ?? ((id) => clearTimeout(id as ReturnType<typeof setTimeout>)))(this.timer);
    this.timer = null;
  }

  private async run() {
    if (!this.active || this.inFlight) return;
    this.inFlight = true;
    try {
      await this.o.attempt();
      this.finished = true;
    } catch (e) {
      if (this.stopped) return;
      const err = e instanceof Error ? e : new Error(String(e));
      if (isRetryableError(err, this.o.mode)) this.schedule(err);
      else {
        this.finished = true;
        this.o.onGiveUp?.(err);
      }
    } finally {
      this.inFlight = false;
    }
  }
}
