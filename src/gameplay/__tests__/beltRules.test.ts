import { describe, expect, it } from 'vitest';
import { BELT_KEY, BELT_SLOT_IDS, beltState, emptyHint, emptyPressText, healPick } from '../beltRules';
import { HEALING_FLASKS } from '../../../server/rules/content/items';
import { HEAL_ORDER } from '../beltRules';

describe('belt rules', () => {
  it('has three slots: Q heal, Z elixir, X tonic', () => {
    expect(BELT_SLOT_IDS).toEqual(['heal', 'elixir', 'tonic']);
    expect(BELT_KEY).toEqual({ heal: 'q', elixir: 'z', tonic: 'x' });
  });
  it('heal order covers every healing flask, best first', () => {
    expect([...HEAL_ORDER].sort()).toEqual(Object.keys(HEALING_FLASKS).sort());
    const fr = HEAL_ORDER.map((id) => HEALING_FLASKS[id]);
    expect(fr).toEqual([...fr].sort((a, b) => b - a));
  });
  it('picks the best carried flask, or null', () => {
    expect(healPick(() => 0)).toBeNull();
    expect(healPick((id) => (id === 'flask_hp_minor' ? 2 : 0))).toBe('flask_hp_minor');
    expect(healPick(() => 1)).toBe('flask_hp_grand');
  });
  it('states', () => {
    expect(beltState({ hasItem: false })).toBe('empty');
    expect(beltState({ hasItem: true })).toBe('ready');
    expect(beltState({ hasItem: true, cooling: true })).toBe('cooling');
    expect(beltState({ hasItem: false, active: true })).toBe('active');
  });
  it('empty hints say how to fill the slot', () => {
    expect(emptyHint('tonic')).toMatch(/Click it.*Alchemist's Wing.*Press X/);
    expect(emptyHint('heal')).toMatch(/Moss Tonic.*Press Q/);
    expect(emptyPressText('elixir')).toBe('Empty elixir slot');
    expect(emptyPressText('heal').length).toBeLessThan(24);
  });
});
