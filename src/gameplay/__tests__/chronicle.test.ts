import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const api = vi.hoisted(() => ({
  getChronicle: vi.fn(),
  addChronicle: vi.fn(),
  ascendChronicle: vi.fn(),
}));
vi.mock('../../net/api', () => api);

import { Chronicle } from '../chronicle';

const saved = () => ({ life: { kills: 100 }, run: { kills: 10 }, runNo: 3, runStartedAt: null, runs: [] });

describe('Chronicle', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    api.getChronicle.mockResolvedValue(saved());
    api.addChronicle.mockResolvedValue({});
    api.ascendChronicle.mockResolvedValue({ archived: true });
  });
  afterEach(() => {
    vi.useRealTimers();
    vi.clearAllMocks();
  });

  it('shows the saved record plus unflushed counters, and maxima keep the best', async () => {
    const c = new Chronicle(1);
    await c.load();
    c.add('kills', 5);
    c.add('gold.earned', 40);
    c.max('peak.level', 7);
    c.max('peak.level', 4);
    const v = c.view();
    expect(v.life.kills).toBe(105);
    expect(v.run.kills).toBe(15);
    expect(v.life['gold.earned']).toBe(40);
    expect(v.life['peak.level']).toBe(7);
    c.dispose();
  });

  it('flushes deltas once, without double counting them in the view', async () => {
    const c = new Chronicle(1);
    await c.load();
    c.add('kills', 5);
    await c.flush();
    expect(api.addChronicle).toHaveBeenCalledWith(1, { kills: 5 }, {});
    expect(c.view().life.kills).toBe(105);
    await c.flush();
    expect(api.addChronicle).toHaveBeenCalledTimes(1);
    c.dispose();
  });

  it('keeps counters for the next try when a flush fails', async () => {
    const c = new Chronicle(1);
    await c.load();
    api.addChronicle.mockRejectedValueOnce(new Error('offline'));
    c.add('deaths', 2);
    await c.flush();
    expect(c.view().life.deaths).toBe(2);
    await c.flush();
    expect(api.addChronicle).toHaveBeenLastCalledWith(1, { deaths: 2 }, {});
    c.dispose();
  });

  it('counts whole seconds of play and AFK time, carrying fractions', () => {
    const c = new Chronicle(1);
    c.time(0.6, false);
    c.time(0.6, true);
    expect(c.view().life.playSeconds).toBe(1);
    expect(c.view().life.afkSeconds ?? 0).toBe(0);
    c.time(0.5, true);
    c.time(0.5, true);
    expect(c.view().life.afkSeconds).toBe(1);
    c.dispose();
  });

  it('ascend banks pending counters first, then archives and reloads the record', async () => {
    const c = new Chronicle(1);
    await c.load();
    c.add('kills', 3);
    await c.ascend(2);
    expect(api.addChronicle).toHaveBeenCalledWith(1, { kills: 3 }, {});
    expect(api.ascendChronicle).toHaveBeenCalledWith(1, 2);
    expect(api.addChronicle.mock.invocationCallOrder[0]).toBeLessThan(api.ascendChronicle.mock.invocationCallOrder[0]);
    expect(api.getChronicle).toHaveBeenCalledTimes(2);
    c.dispose();
  });
});
