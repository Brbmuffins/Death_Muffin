import { describe, expect, it } from 'vitest';
import { CHAIN, KillChain } from '../../../server/rules/gameplay/killChain';
import { MILESTONES, newlyReached } from '../milestones';
import { AREAS } from '../../../server/rules/content/areas';

describe('Kill Chain', () => {
  it('chains kills inside the window and reports tier-ups once', () => {
    const c = new KillChain();
    const ups: string[] = [];
    for (let i = 0; i < 30; i++) {
      const up = c.hit(i * 1000);
      if (up) ups.push(up.name);
    }
    expect(c.count).toBe(30);
    expect(ups).toEqual(['Stirring', 'Rampage', 'Slaughter']);
    expect(c.best).toBe(30);
  });

  it('breaks after the window and pays the bonus of the tier it had reached', () => {
    const c = new KillChain();
    for (let i = 0; i < 12; i++) c.hit(i * 500);
    expect(c.tier?.name).toBe('Rampage');
    expect(c.mult).toBeCloseTo(1.1);
    expect(c.tick(5500 + CHAIN.windowMs - 1)).toBe(0);
    expect(c.tick(5500 + CHAIN.windowMs + 1)).toBe(12);
    expect(c.count).toBe(0);
    expect(c.mult).toBe(1);
    expect(c.best).toBe(12);
  });

  it('a kill after the window starts a fresh chain rather than extending the old one', () => {
    const c = new KillChain();
    for (let i = 0; i < 6; i++) c.hit(i * 100);
    c.hit(600 + CHAIN.windowMs + 500);
    expect(c.count).toBe(1);
  });

  it('bonuses climb with tier and stay modest', () => {
    const b = CHAIN.tiers.map((t) => t.bonus);
    expect([...b].sort((x, y) => x - y)).toEqual(b);
    expect(Math.max(...b)).toBeLessThanOrEqual(0.25);
    expect(KillChain.tierFor(4)).toBeNull();
  });
});

describe('Milestones', () => {
  it('ids are unique, every combat area has area lines, and gold rises with the line', () => {
    expect(new Set(MILESTONES.map((m) => m.id)).size).toBe(MILESTONES.length);
    for (const [id, a] of Object.entries(AREAS)) {
      if (!a.safe) expect(MILESTONES.some((m) => m.id.startsWith(`area.${id}.`)), id).toBe(true);
    }
    const kills = MILESTONES.filter((m) => m.id.startsWith('kills.')).map((m) => m.gold);
    expect([...kills].sort((x, y) => x - y)).toEqual(kills);
  });

  it('pays each milestone once', () => {
    const c = { totalKills: 520, areaKills: { graves: 130 }, bestChain: 12 };
    const first = newlyReached(c, new Set());
    expect(first.map((m) => m.id).sort()).toEqual(['area.graves.100', 'chain.10', 'kills.100', 'kills.500']);
    const claimed = new Set(first.map((m) => m.id));
    expect(newlyReached(c, claimed)).toEqual([]);
    expect(newlyReached({ ...c, totalKills: 1000 }, claimed).map((m) => m.id)).toEqual(['kills.1000']);
  });
});
