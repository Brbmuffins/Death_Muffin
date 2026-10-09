import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Progression } from '../progression';
import { ApiError, necroApi, reportKills, saveProgress } from '../../net/api';
import { blankState } from '../../../server/rules/gameplay/necroRules';
import type { Character } from '../../net/types';

vi.mock('../../net/api', async (orig) => {
  const real = await orig<typeof import('../../net/api')>();
  return { ...real, saveProgress: vi.fn(), reportKills: vi.fn(), saveInventory: vi.fn(), necroApi: { purchase: vi.fn(), get: vi.fn(), save: vi.fn() } };
});

const character = (): Character => ({ id: 7, class_index: 2, class_name: 'Shadowblade', level: 2, experience: 5, gold: 20, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 });
const kill = (over = {}) => ({ area: 'graves', def: 'robber', level: 1, elite: false, tier: 0, diff: 'medium', rank: 0, xpMult: 1, goldMult: 1, shardMult: 1, ...over });

/** Server authority step 2: kills ride along with the progress save and are never lost or double counted. */
describe('kill reports in Progression', () => {
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.mocked(saveProgress).mockReset().mockResolvedValue({ success: true });
    vi.mocked(reportKills).mockReset().mockResolvedValue({ mode: 'audit' });
  });
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

  it('the progress save carries the sealed batches, and they are forgotten once the server has them', async () => {
    const p = new Progression(character());
    try {
      p.reportKill(kill());
      p.reportKill(kill());
      p.addGold(3);
      await p.flush();
      const sent = vi.mocked(saveProgress).mock.calls[0][0];
      expect(sent.killReports).toHaveLength(1);
      expect(sent.killReports![0].groups[0].n).toBe(2);
      expect(p.reporter.hasPending).toBe(false);
    } finally { p.dispose(); }
  });

  it('a failed save keeps its batch and the retry repeats it with the same sequence number (no double count)', async () => {
    const p = new Progression(character());
    try {
      p.reportKill(kill());
      p.addGold(3);
      vi.mocked(saveProgress).mockRejectedValueOnce(new Error('offline'));
      await p.flush();
      expect(p.reporter.hasPending).toBe(true);
      p.reportKill(kill({ def: 'hound' }));
      await p.flush();
      const [first, second] = vi.mocked(saveProgress).mock.calls.map((c) => c[0].killReports!);
      expect(first).toHaveLength(1);
      expect(second).toHaveLength(2);
      expect(second[0].seq).toBe(first[0].seq);
      expect(second[1].seq).toBeGreaterThan(second[0].seq);
      expect(p.reporter.hasPending).toBe(false);
    } finally { p.dispose(); }
  });

  it('a save with no kills sends no report field at all', async () => {
    const p = new Progression(character());
    try {
      p.addGold(3);
      await p.flush();
      expect(vi.mocked(saveProgress).mock.calls[0][0]).not.toHaveProperty('killReports');
    } finally { p.dispose(); }
  });

  it('a floor clear is posted at once on its own; an older server (404) makes the browser stop holding batches', async () => {
    const p = new Progression(character());
    try {
      p.reportFloor({ depth: 1, level: 20, clear: true, chest: false, mult: 1 });
      await Promise.resolve(); await Promise.resolve();
      expect(reportKills).toHaveBeenCalledTimes(1);
      await vi.waitFor(() => expect(p.reporter.hasPending).toBe(false));
      vi.mocked(reportKills).mockRejectedValueOnce(new ApiError('not found', 404));
      p.reportKill(kill());
      await p.flushReports();
      expect(p.reporter.hasPending).toBe(false);
      vi.mocked(reportKills).mockRejectedValueOnce(new ApiError('boom', 500));
      p.reportKill(kill());
      await p.flushReports();
      expect(p.reporter.hasPending).toBe(true);
    } finally { p.dispose(); }
  });

  it('a necromancer save never claims kills the server has not been told about', async () => {
    const order: string[] = [];
    vi.mocked(saveProgress).mockImplementation(async (payload) => { order.push(payload.killReports ? 'save+report' : 'save'); return { success: true }; });
    vi.mocked(reportKills).mockImplementation(async () => { order.push('report'); return { mode: 'enforce' }; });
    vi.mocked(necroApi.save).mockImplementation(async () => { order.push('necro'); return { progress: blankState() }; });
    const p = new Progression(character());
    p.mode = 'server';
    try {
      // Through the progress save: the batch rides with it, ahead of the necromancer claim.
      p.reportKill(kill());
      p.recordKill('graves');
      await p.flush();
      expect(order).toEqual(['save+report', 'necro']);
      // Through a necromancer save on its own (a summon): the batch is posted first.
      order.length = 0;
      p.reportKill(kill());
      p.recordKill('graves');
      await (p as unknown as { flushNecro(k?: boolean): Promise<void> }).flushNecro();
      expect(order).toEqual(['report', 'necro']);
    } finally { p.dispose(); }
  });
});
