/**
 * Per-frame build budget. A fast wave resolves dozens of Creature construction chains in the same microtask batch
 * (clone, material variants, mixer + clip actions: ~1 ms each); run together they land as one long frame. Callers hand
 * their sync chunk to `run`; at most `budgetMs` of chunks complete per animation frame (always at least one, so
 * progress is guaranteed) and the rest continue next frame. Gameplay never waits on these: visuals only.
 */
export interface BudgetEnv {
  now: () => number;
  /** Schedules `fn` for the next frame. Return false to say "no frame source": jobs then run at once. */
  schedule: (fn: () => void) => boolean;
}
/** QA A/B switch: set `globalThis.__cwNoBudget = true` before load (DM_QA_NOBUDGET=1 in the tools/qa probes) to build bodies immediately, as before the budget. */

const defaultEnv: BudgetEnv = {
  now: () => (typeof performance !== 'undefined' ? performance.now() : Date.now()),
  schedule: (fn) => {
    if ((globalThis as { __cwNoBudget?: boolean }).__cwNoBudget || typeof requestAnimationFrame !== 'function' || (typeof document !== 'undefined' && document.hidden)) return false;
    requestAnimationFrame(fn);
    return true;
  },
};

export class FrameBudget {
  private queue: { job: () => void }[] = [];
  private scheduled = false;
  /** Jobs finished / frames used (QA and tests). */
  stats = { done: 0, frames: 0, maxFrameMs: 0 };

  constructor(
    public budgetMs = 4,
    private env: BudgetEnv = defaultEnv,
  ) {}

  get pending() {
    return this.queue.length;
  }

  run<T>(fn: () => T): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const job = () => {
        try {
          resolve(fn());
        } catch (err) {
          reject(err);
        }
      };
      // Nothing waiting and a frame to spare is not worth a hop only when we are idle: queue anyway so ordering holds.
      this.queue.push({ job });
      this.pump();
    });
  }

  private pump() {
    if (this.scheduled || !this.queue.length) return;
    this.scheduled = true;
    if (this.env.schedule(() => this.frame())) return;
    // No frame source (hidden tab, tests): drain now.
    this.scheduled = false;
    for (const q of this.queue.splice(0)) q.job(), this.stats.done++;
  }

  private frame() {
    this.scheduled = false;
    const t0 = this.env.now();
    let n = 0;
    while (this.queue.length) {
      this.queue.shift()!.job();
      n++;
      this.stats.done++;
      if (this.env.now() - t0 >= this.budgetMs) break;
    }
    this.stats.frames++;
    this.stats.maxFrameMs = Math.max(this.stats.maxFrameMs, this.env.now() - t0);
    void n;
    this.pump();
  }
}

export const buildBudget = new FrameBudget();
