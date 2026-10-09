import { describe, expect, it } from 'vitest';
import { Nav } from '../nav';
import { WorldSim } from '../sim/WorldSim';
import { WorldMirror, makeSnapshot } from '../sim/snapshot';
import { mulberry32 } from '../rng';
import { rollBoss, rollKill } from '../loot';
import { DIFFICULTIES, DIFFICULTY_ORDER, isDifficulty, type Difficulty } from '../../../server/rules/content/difficulty';

function sim(difficulty: Difficulty) {
  const s = new WorldSim(new Nav(), mulberry32(3));
  s.difficulty = difficulty;
  s.setPlayer({ id: 'p1', x: 0, z: -16, alive: true, area: 'graves' });
  return s;
}

describe('difficulty', () => {
  it('orders easy < medium < hard on every axis', () => {
    const [e, m, h] = DIFFICULTY_ORDER.map((d) => DIFFICULTIES[d]);
    for (const k of ['enemyHpMult', 'enemyDamageMult', 'rewardMult'] as const) {
      expect(e[k]).toBeLessThan(m[k]);
      expect(m[k]).toBeLessThan(h[k]);
    }
    expect(m.enemyHpMult).toBe(1);
    expect(m.enemyDamageMult).toBe(1);
    expect(m.rewardMult).toBe(1);
    expect(isDifficulty('hard')).toBe(true);
    expect(isDifficulty('nightmare')).toBe(false);
  });

  it('scales spawned enemy health and damage', () => {
    const base = sim('medium').spawnEnemy('robber', 'graves', 0, -20, false);
    for (const d of ['easy', 'hard'] as const) {
      const e = sim(d).spawnEnemy('robber', 'graves', 0, -20, false);
      expect(e.maxHp).toBeCloseTo(base.maxHp * DIFFICULTIES[d].enemyHpMult);
      expect(e.damage).toBeCloseTo(base.damage * DIFFICULTIES[d].enemyDamageMult);
    }
  });

  it('scales the Prelate', () => {
    const hp = (d: Difficulty) => {
      const s = sim(d);
      s.setPlayer({ id: 'p1', x: 0, z: -110, alive: true, area: 'sanctum' });
      s.apply({ t: 'summonBoss', by: 'p1' });
      return s.bossState.maxHp;
    };
    expect(hp('hard') / hp('medium')).toBeCloseTo(DIFFICULTIES.hard.enemyHpMult);
    expect(hp('easy') / hp('medium')).toBeCloseTo(DIFFICULTIES.easy.enemyHpMult);
  });

  it('scales gold and experience, not shards', () => {
    const avg = (d: Difficulty) => {
      const rand = mulberry32(9);
      let gold = 0;
      let xp = 0;
      for (let i = 0; i < 300; i++) {
        const r = rollKill('robber', 'graves', 1, false, 0, rand, d);
        gold += r.gold;
        xp += r.xp;
      }
      return { gold, xp };
    };
    expect(avg('hard').gold).toBeGreaterThan(avg('medium').gold);
    expect(avg('easy').xp).toBeLessThan(avg('medium').xp);
    expect(rollBoss(0, mulberry32(1), 'hard').shards).toBe(rollBoss(0, mulberry32(1), 'easy').shards);
    expect(rollBoss(0, mulberry32(1), 'hard').gold).toBeGreaterThan(rollBoss(0, mulberry32(1), 'medium').gold);
  });

  it("rides in snapshots so guests use the host's difficulty", () => {
    const host = sim('hard');
    const mirror = new WorldMirror();
    mirror.applySnapshot(makeSnapshot(host, true));
    expect(mirror.difficulty).toBe('hard');
    // Older hosts don't send it: guests fall back to medium.
    const old = { ...makeSnapshot(host, true), difficulty: undefined };
    mirror.applySnapshot(old);
    expect(mirror.difficulty).toBe('medium');
  });
});
