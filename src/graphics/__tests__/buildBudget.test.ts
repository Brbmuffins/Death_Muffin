import { describe, expect, it } from 'vitest';
import { FrameBudget } from '../buildBudget';

function harness(budgetMs: number, costMs: number) {
  let clock = 0;
  const frames: (() => void)[] = [];
  const b = new FrameBudget(budgetMs, { now: () => clock, schedule: (fn) => (frames.push(fn), true) });
  const job = (log: number[], id: number) => () => {
    clock += costMs;
    log.push(id);
    return id;
  };
  const step = () => frames.shift()?.();
  return { b, job, step, frames };
}

describe('FrameBudget', () => {
  it('finishes only about the budget per frame and carries the rest over, in order', async () => {
    const { b, job, step, frames } = harness(4, 1);
    const log: number[] = [];
    const ps = Array.from({ length: 10 }, (_, i) => b.run(job(log, i)));
    expect(log).toEqual([]);
    step();
    expect(log).toEqual([0, 1, 2, 3]);
    expect(frames.length).toBe(1);
    step();
    step();
    expect(log).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(await Promise.all(ps)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(frames.length).toBe(0);
  });

  it('always completes at least one job per frame, even when one exceeds the budget', () => {
    const { b, job, step } = harness(4, 10);
    const log: number[] = [];
    for (let i = 0; i < 3; i++) b.run(job(log, i));
    step();
    expect(log).toEqual([0]);
    step();
    step();
    expect(log).toEqual([0, 1, 2]);
  });

  it('a throwing job rejects its own promise and does not stall the queue', async () => {
    const { b, step } = harness(4, 1);
    const bad = b.run(() => {
      throw new Error('boom');
    });
    const good = b.run(() => 7);
    step();
    await expect(bad).rejects.toThrow('boom');
    await expect(good).resolves.toBe(7);
  });

  it('runs at once when there is no frame source', async () => {
    const b = new FrameBudget(4, { now: () => 0, schedule: () => false });
    await expect(b.run(() => 'now')).resolves.toBe('now');
    expect(b.pending).toBe(0);
  });
});
