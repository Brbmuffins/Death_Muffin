import { describe, expect, it } from 'vitest';
import { ALCHEMY_BUFFS } from '../../content/alchemy';
import { BREWS, LIFESTEAL_HIT_CAP, LIFESTEAL_TARGET_CAP, applyBrew, brewSummary, brewValue, brewWard, emptyBrews, lifestealHeal, type BrewDef } from '../../content/brews';
import { BUFF_FLASKS, ITEMS } from '../../content/items';
import { rollKill } from '../loot';

describe('brew engine', () => {
  it('keeps the existing flask ids and values', () => {
    expect(BUFF_FLASKS.flask_speed).toMatchObject({ kind: 'speed', value: 0.2, seconds: 30 });
    expect(BUFF_FLASKS.flask_damage).toMatchObject({ kind: 'damage', value: 0.15, seconds: 45 });
    expect(BUFF_FLASKS.flask_void_resist).toMatchObject({ kind: 'ward', value: 0.25, seconds: 90 });
    expect(BUFF_FLASKS.elixir_moonlight).toMatchObject(ALCHEMY_BUFFS.elixir_moonlight);
    for (const id of Object.keys(BREWS)) expect(ITEMS[id], id).toBeDefined();
  });

  it('sums active effects and expires them', () => {
    const b = emptyBrews();
    const t = 1000;
    applyBrew(b, 'flask_damage', t);
    applyBrew(b, 'flask_speed', t);
    expect(brewValue(b, 'damage', t + 10)).toBe(0.15);
    expect(brewValue(b, 'speed', t + 10)).toBe(0.2);
    expect(brewValue(b, 'damage', t + 45_000)).toBe(0);
    expect(brewValue(b, 'speed', t + 29_999)).toBe(0.2);
    expect(brewValue(b, 'speed', t + 30_000)).toBe(0);
  });

  it('a new elixir replaces the elixir; a tonic is independent', () => {
    const b = emptyBrews();
    applyBrew(b, 'flask_damage', 0);
    applyBrew(b, 'flask_speed', 0);
    const r = applyBrew(b, 'elixir_moonlight', 1000);
    expect(r.replaced).toBe('flask_damage');
    expect(b.elixir!.id).toBe('elixir_moonlight');
    expect(brewValue(b, 'damage', 1001)).toBe(0.25);
    expect(b.tonic!.id).toBe('flask_speed');
    expect(brewValue(b, 'speed', 1001)).toBe(0.2);
  });

  it('the same brew extends, capped at twice its duration', () => {
    const b = emptyBrews();
    applyBrew(b, 'flask_speed', 0);
    const r = applyBrew(b, 'flask_speed', 1000);
    expect(r.extended).toBe(true);
    expect(b.tonic!.until).toBe(60_000);
    applyBrew(b, 'flask_speed', 2000);
    expect(b.tonic!.until).toBe(62_000); // capped at now + 2 x 30s
    applyBrew(b, 'flask_speed', 3000);
    expect(b.tonic!.until).toBe(63_000);
  });

  it('an expired elixir is not reported as replaced', () => {
    const b = emptyBrews();
    applyBrew(b, 'flask_damage', 0);
    expect(applyBrew(b, 'elixir_moonlight', 100_000).replaced).toBeNull();
  });

  it('Moonlight Elixir is +25% spell damage', () => {
    const b = emptyBrews();
    applyBrew(b, 'elixir_moonlight', 0);
    expect(1 + brewValue(b, 'damage', 1)).toBeCloseTo(1.25);
  });

  it('resists apply by damage source', () => {
    const fake: Record<string, BrewDef> = {
      t_fire: { slot: 'elixir', effects: [{ kind: 'resist_fire', value: 0.4 }, { kind: 'ward', value: 0.1 }], seconds: 10, label: 'T', color: 0, glyph: 'x' },
      t_rot: { slot: 'elixir', effects: [{ kind: 'resist_rot', value: 0.3 }], seconds: 10, label: 'T', color: 0, glyph: 'x' },
    };
    Object.assign(BREWS, fake);
    try {
      const b = emptyBrews();
      applyBrew(b, 't_fire', 0);
      expect(brewWard(b, 'ember', 1)).toBeCloseTo(0.5);
      expect(brewWard(b, 'burn', 1)).toBeCloseTo(0.5);
      expect(brewWard(b, 'toxic', 1)).toBeCloseTo(0.1);
      expect(brewWard(b, 'melee', 1)).toBeCloseTo(0.1);
      applyBrew(b, 't_rot', 0);
      expect(brewWard(b, 'toxic', 1)).toBeCloseTo(0.3);
      expect(brewWard(b, 'dust', 1)).toBeCloseTo(0.3);
      expect(brewWard(b, 'ember', 1)).toBe(0);
    } finally {
      delete BREWS.t_fire;
      delete BREWS.t_rot;
    }
  });

  it('warding elixir still wards every source', () => {
    const b = emptyBrews();
    applyBrew(b, 'flask_void_resist', 0);
    expect(brewWard(b, 'boss', 1)).toBe(0.25);
  });

  it('fortune multiplies the item drop chance', () => {
    const rolls = (mult: number) => {
      let n = 0;
      // Reagent/rune streams pinned to "no drop": only the area item roll is counted, so the ratio is exact.
      for (let i = 0; i < 4000; i++) if (rollKill('risen', 'graves', 1, false, 0, () => (i + 0.5) / 4000, 'medium', mult, () => 0.999, () => 0.999).items.length) n++;
      return n;
    };
    const base = rolls(1);
    expect(base).toBeGreaterThan(0);
    expect(rolls(1.5)).toBeGreaterThan(base * 1.4);
    expect(rolls(1.5)).toBeLessThan(base * 1.6);
  });

  it('lifesteal is a share of damage, with a per-hit and per-target cap', () => {
    expect(lifestealHeal(100, 1, 0.05, 1000)).toBeCloseTo(5);
    expect(lifestealHeal(100, 50, 0.05, 1000)).toBeCloseTo(100 * LIFESTEAL_TARGET_CAP * 0.05);
    expect(lifestealHeal(1e6, 1, 0.05, 1000)).toBeCloseTo(1000 * LIFESTEAL_HIT_CAP);
    expect(lifestealHeal(0, 1, 0.05, 1000)).toBe(0);
    expect(lifestealHeal(100, 1, 0, 1000)).toBe(0);
  });

  it('every brew describes itself', () => {
    for (const id of Object.keys(BREWS)) expect(brewSummary(id)).toMatch(/·/);
  });
});
