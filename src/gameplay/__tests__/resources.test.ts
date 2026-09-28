import { describe, expect, it } from 'vitest';
import type { DerivedStats } from '../characterStats';
import { Nav } from '../nav';
import { Player } from '../Player';
import { resourceRulesFor } from '../resources';

const stats = (over: Partial<DerivedStats> = {}): DerivedStats => ({
  level: 12,
  maxHp: 100,
  spellPower: 20,
  maxEssence: 150,
  essenceRegen: 5,
  moveSpeed: 5.4,
  thrallHp: 45,
  thrallDamage: 8,
  damageBonusPct: 0,
  ...over,
});

describe('resource abstraction — necromancer regression', () => {
  // These four pin the pre-framework numbers. If the generalisation ever
  // changes them, the four necromantic disciplines have silently changed.
  it('starts at 60% of max essence, exactly as before', () => {
    const p = new Player(stats(), new Nav());
    expect(p.resource.kind).toBe('essence');
    expect(p.resource.max).toBe(150);
    expect(p.essence).toBe(90);
  });

  it('revives at 50% of max essence', () => {
    const p = new Player(stats(), new Nav());
    p.alive = false;
    p.essence = 0;
    p.revive();
    expect(p.essence).toBe(75);
  });

  it('regenerates stats.essenceRegen per second and clamps at max', () => {
    const p = new Player(stats(), new Nav());
    p.essence = 0;
    p.update(1, 10_000, null);
    expect(p.essence).toBeCloseTo(5, 6);
    p.essence = 149;
    p.update(1, 10_000, null);
    expect(p.essence).toBe(150);
  });

  it('clamps the value into the new ceiling on setStats', () => {
    const p = new Player(stats(), new Nav());
    p.essence = 150;
    p.setStats(stats({ maxEssence: 80 }));
    expect(p.resource.max).toBe(80);
    expect(p.essence).toBe(80);
  });

  it('keeps `essence` and `resource.value` as one value', () => {
    const p = new Player(stats(), new Nav());
    p.essence = 42;
    expect(p.resource.value).toBe(42);
    p.resource.value = 7;
    expect(p.essence).toBe(7);
  });
});

describe('resource abstraction — Rage (Hollow Knight)', () => {
  it('starts empty out of 100 and revives empty', () => {
    const p = new Player(stats(), new Nav(), 'knight');
    expect(p.resource.kind).toBe('rage');
    expect(p.resource.max).toBe(100);
    expect(p.resource.value).toBe(0);
    p.resource.value = 60;
    p.revive();
    expect(p.resource.value).toBe(0);
  });

  it('does not passively regenerate, and only decays once out of combat', () => {
    const p = new Player(stats(), new Nav(), 'knight');
    p.resource.value = 50;
    // Still in combat (hit 1s ago): Rage holds.
    p.lastHurtAt = 9_000;
    p.update(1, 10_000, null);
    expect(p.resource.value).toBe(50);
    // 5s since the last hit: -4/s.
    p.lastHurtAt = 5_000;
    p.update(1, 10_000, null);
    expect(p.resource.value).toBeCloseTo(46, 6);
  });

  it('never leaves 0..max however hard it is pushed', () => {
    const p = new Player(stats(), new Nav(), 'knight');
    p.addResource(500);
    expect(p.resource.value).toBe(100);
    p.addResource(-500);
    expect(p.resource.value).toBe(0);
    // Decay cannot drive it negative either.
    p.lastHurtAt = -1e9;
    p.update(10, 10_000, null);
    expect(p.resource.value).toBe(0);
  });

  it('ignores maxEssence — its ceiling is its own', () => {
    const p = new Player(stats({ maxEssence: 999 }), new Nav(), 'knight');
    expect(p.resource.max).toBe(100);
  });
});

describe('resource rules registry', () => {
  it('gives every family a usable resource so no orb is ever dead', () => {
    for (const family of ['necromancer', 'knight', 'warden', 'monk', 'witch', 'veil'] as const) {
      const rules = resourceRulesFor(family);
      expect(rules.label.length).toBeGreaterThan(0);
      expect(rules.max(stats())).toBeGreaterThan(0);
    }
  });
});
