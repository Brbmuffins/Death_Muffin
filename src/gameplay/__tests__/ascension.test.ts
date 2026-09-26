import { beforeAll, describe, expect, it, vi } from 'vitest';
import { ASCENSION, BOONS, BOON_ORDER, ashesForRun, ascensionLevels, boonEffects, roman } from '../../content/ascension';
import { AREAS } from '../../content/areas';
import { Nav } from '../nav';
import { mulberry32 } from '../rng';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';

vi.mock('../../net/api', () => ({ saveProgress: vi.fn(async () => undefined) }));

beforeAll(() => {
  // Progression schedules saves on window timers; node has none.
  (globalThis as unknown as { window: unknown }).window = { setTimeout: () => 0, clearTimeout: () => undefined };
});

async function fresh(id = 1) {
  const { Progression } = await import('../progression');
  return new Progression({ id, class_index: 1, class_name: '', level: 18, experience: 0, gold: 5000, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });
}

describe('Ascension rules', () => {
  it('pays nothing until the Prelate falls this run, then more for a bigger run and a higher rank', () => {
    expect(ashesForRun({ prelateKills: 0, peakWaveTier: 8, kills: 5000 }, 0)).toBe(0);
    const small = ashesForRun({ prelateKills: 1, peakWaveTier: 0, kills: 100 }, 0);
    const big = ashesForRun({ prelateKills: 3, peakWaveTier: 8, kills: 3000 }, 0);
    expect(small).toBeGreaterThan(0);
    expect(big).toBeGreaterThan(small);
    expect(ashesForRun({ prelateKills: 1, peakWaveTier: 0, kills: 100 }, 4)).toBeGreaterThan(small);
  });

  it('boons are sane: costs per rank, effects bounded', () => {
    for (const id of BOON_ORDER) {
      expect(BOONS[id].cost.length).toBe(BOONS[id].maxRank);
      for (let i = 1; i < BOONS[id].cost.length; i++) expect(BOONS[id].cost[i]).toBeGreaterThan(BOONS[id].cost[i - 1]);
    }
    const maxed = boonEffects(Object.fromEntries(BOON_ORDER.map((id) => [id, 99])));
    expect(maxed.damageCostMult).toBeGreaterThan(0.5);
    expect(maxed.unlockKillsMult).toBeGreaterThan(0.5);
    expect(maxed.extraThralls).toBe(1);
    expect(roman(4)).toBe('IV');
    expect(roman(19)).toBe('XIX');
  });

  it('ascending burns the run but keeps level, gold and boons', async () => {
    const p = await fresh(2);
    const c = p.character;
    p.local.damageTier = 9;
    p.local.waveTierOwned = 5;
    p.local.waveTierActive = 4;
    p.local.shards = 7;
    p.local.areaKills = { graves: 400, ossuary: 500 };
    p.local.unlocked = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum'];
    p.local.totalKills = 900;
    expect(p.canAscend()).toBe(false);
    expect(p.ascend()).toBe(0);
    p.recordPrelateKill();
    const earned = p.ashesOnAscend();
    expect(earned).toBeGreaterThan(0);
    expect(p.ascend()).toBe(earned);
    expect(p.local.ascension).toBe(1);
    expect(p.local.ashes).toBe(earned);
    expect(p.local.damageTier).toBe(0);
    expect(p.local.waveTierOwned).toBe(0);
    expect(p.local.shards).toBe(0);
    expect(p.local.unlocked).toEqual(['chapterhouse', 'graves']);
    expect(p.local.areaKills).toEqual({});
    expect(p.local.run.prelateKills).toBe(0);
    // Server-owned and lifetime values survive.
    expect(c.level).toBe(18);
    expect(c.gold).toBe(5000);
    expect(p.local.bossKills).toBe(1);
    expect(p.local.totalKills).toBe(900);
  });

  it('boons cost Ashes, respect rank gates, and shape the next run', async () => {
    const p = await fresh(3);
    p.local.ashes = 100;
    expect(p.boonProblem('legion_pact')).toMatch(/Ascension/);
    expect(p.buyBoon('first_rites')).toBe(true);
    expect(p.local.damageTier).toBe(2); // applies to the run in progress too
    expect(p.buyBoon('shard_keeper')).toBe(true);
    expect(p.buyBoon('bone_tithe')).toBe(true);
    const full = Math.round(40 * Math.pow(1.5, p.local.damageTier));
    expect(p.damageCost()).toBe(Math.round(full * 0.9));
    expect(p.unlockKills(300)).toBe(300);
    p.recordPrelateKill();
    p.ascend();
    expect(p.local.damageTier).toBe(2);
    expect(p.local.shards).toBe(2);
    p.local.ashes = 0;
    expect(p.buyBoon('vigil')).toBe(false);
    expect(p.boonProblem('vigil')).toMatch(/Needs/);
  });

  it('records the run: kills and the peak Wave Speed it was fought at', async () => {
    const p = await fresh(4);
    p.recordKill('graves', 3);
    p.recordKill('graves', 1);
    expect(p.local.run.kills).toBe(2);
    expect(p.local.run.peakWaveTier).toBe(3);
  });
});

describe('Ascension in the world', () => {
  it('ages every enemy and the Prelate, and rides snapshots to guests', () => {
    const base = new WorldSim(new Nav(), mulberry32(1));
    const old = new WorldSim(new Nav(), mulberry32(1));
    old.ascension = 2;
    const a = base.spawnEnemy('robber', 'graves', 0, -20, false, false);
    const b = old.spawnEnemy('robber', 'graves', 0, -20, false, false);
    expect(b.level - a.level).toBe(ascensionLevels(2));
    expect(b.maxHp).toBeGreaterThan(a.maxHp);
    expect(b.damage).toBeGreaterThan(a.damage);
    old.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum' });
    old.apply({ t: 'summonBoss', by: 'p1' });
    expect(old.bossState.level).toBe(AREAS.sanctum.level + 2 * ASCENSION.levelsPerRank);
    const m = new WorldMirror();
    m.applySnapshot(makeSnapshot(old, true));
    expect(m.ascension).toBe(2);
  });
});
