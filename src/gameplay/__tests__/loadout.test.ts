import { describe, expect, it } from 'vitest';
import { ABILITIES, DEFAULT_LOADOUT, GRIMOIRE, HOTBAR, SIGNATURE_LEVEL, unlockLevel, type AbilityId } from '../../content/abilities';
import { CODEX_RITES, RITE_ORDER } from '../../content/codex';
import { CAST_FLOW } from '../../content/combatFlow';
import { assignRite, loadLoadout, loadoutStorageKey, sanitizeLoadout, saveLoadout } from '../loadout';
import type { StorageLike } from '../codexJournal';

const memory = (): StorageLike & { data: Map<string, string> } => {
  const data = new Map<string, string>();
  return { data, getItem: (k) => data.get(k) ?? null, setItem: (k, v) => void data.set(k, v) };
};

describe('Grimoire loadout', () => {
  it('starts on the classic four and keeps the default bar', () => {
    expect(DEFAULT_LOADOUT).toEqual(HOTBAR.slice(0, 4));
    expect(sanitizeLoadout(null, 1)).toEqual(DEFAULT_LOADOUT);
  });

  it('only lets unlocked, distinct Grimoire rites onto keys 1–4', () => {
    // Too low for the skull, a duplicate, a signature and junk all fall back to the default for that key.
    expect(sanitizeLoadout(['wailing_skull', 'miasma', 'miasma', 'dirge'], 1)).toEqual(['marrow_spear', 'miasma', 'exhume', 'black_litany']);
    expect(sanitizeLoadout(['wailing_skull', 'grave_step', 'grave_frost', 'bone_mantle'], 12)).toEqual(['wailing_skull', 'grave_step', 'grave_frost', 'bone_mantle']);
    // Level 7: the mantle (12) isn't learned yet.
    expect(sanitizeLoadout(['wailing_skull', 'grave_step', 'grave_frost', 'bone_mantle'], 7)).toEqual(['wailing_skull', 'grave_step', 'grave_frost', 'black_litany']);
    expect(sanitizeLoadout('nonsense', 20)).toEqual(DEFAULT_LOADOUT);
  });

  it('swaps a rite that already sits on another key', () => {
    const start: AbilityId[] = ['marrow_spear', 'exhume', 'miasma', 'black_litany'];
    expect(assignRite(start, 0, 'miasma')).toEqual(['miasma', 'exhume', 'marrow_spear', 'black_litany']);
    expect(assignRite(start, 3, 'grave_frost')).toEqual(['marrow_spear', 'exhume', 'miasma', 'grave_frost']);
    expect(assignRite(start, 1, 'exhume')).toEqual(start);
  });

  it('remembers the choice per character and survives broken storage', () => {
    const store = memory();
    saveLoadout(store, 7, ['grave_step', 'exhume', 'miasma', 'black_litany']);
    expect(loadLoadout(store, 7, 5)).toEqual(['grave_step', 'exhume', 'miasma', 'black_litany']);
    expect(loadLoadout(store, 8, 5)).toEqual(DEFAULT_LOADOUT);
    store.data.set(loadoutStorageKey(9), '{not json');
    expect(loadLoadout(store, 9, 5)).toEqual(DEFAULT_LOADOUT);
    const throwing: StorageLike = { getItem: () => { throw new Error('denied'); }, setItem: () => { throw new Error('denied'); } };
    expect(loadLoadout(throwing, 1, 20)).toEqual(DEFAULT_LOADOUT);
    expect(() => saveLoadout(throwing, 1, DEFAULT_LOADOUT)).not.toThrow();
  });

  it('every Grimoire rite has help, timing and a level before the signature rites', () => {
    for (const id of GRIMOIRE) {
      expect(CODEX_RITES[id].tip.length).toBeGreaterThan(40);
      expect(RITE_ORDER).toContain(id);
      expect(CAST_FLOW[id].lockMs).toBeLessThanOrEqual(160);
      expect(ABILITIES[id].icon).toMatch(/^art\/abilities\//);
    }
    const gated = GRIMOIRE.filter((id) => unlockLevel(id) > 1).map(unlockLevel);
    expect(gated).toEqual([3, 5, 7, 12]);
    expect(unlockLevel('dirge')).toBe(SIGNATURE_LEVEL);
  });
});
