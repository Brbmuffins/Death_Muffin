import { existsSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { ABILITIES, PRIMARIES, DEFAULT_LOADOUT, GRIMOIRE, HOTBAR, SIGNATURE_LEVEL, unlockLevel, type AbilityId } from '../../content/abilities';
import { CODEX_RITES, RITE_ORDER } from '../../content/codex';
import { CAST_FLOW } from '../../content/combatFlow';
import { assignRite, legacyLoadoutKey, loadLoadout, loadRites, loadSeen, loadoutStorageKey, sanitizeLoadout, sanitizePrimary, saveLoadout, saveRites, unseenRites } from '../loadout';
import type { StorageLike } from '../codexJournal';
import { kitFor } from '../../content/kits';

const memory = (): StorageLike & { data: Map<string, string> } => {
  const data = new Map<string, string>();
  return { data, getItem: (k) => data.get(k) ?? null, setItem: (k, v) => void data.set(k, v) };
};

describe('Grimoire loadout', () => {
  it('keeps the Knight hotbar complete at level 1 without learning future rites', () => {
    const kit = kitFor('knight');
    const keys = sanitizeLoadout(null, 1, kit);
    expect(keys).toEqual(kit.defaultLoadout);
    expect(keys.map(unlockLevel)).toEqual([1, 1, 3, 5]);
    const seen = loadSeen(memory(), 8, { primary: kit.defaultPrimary, keys }, kit);
    expect(unseenRites(seen, 3, kit)).toContain('bulwark');
  });
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
    // The unlock ladder (spell-variety brief §4): a choice at level 2, then 3, 4, 5, 6, 7, 8, 12.
    const gated = GRIMOIRE.filter((id) => unlockLevel(id) > 1).map(unlockLevel).sort((a, b) => a - b);
    expect(gated).toEqual([2, 3, 4, 4, 5, 6, 7, 8, 12]);
    expect(PRIMARIES.map(unlockLevel)).toEqual([1, 2, 6]);
    for (const id of [...GRIMOIRE, ...PRIMARIES]) expect(existsSync(`public/${ABILITIES[id].icon}`), ABILITIES[id].icon).toBe(true);
    expect(unlockLevel('dirge')).toBe(SIGNATURE_LEVEL);
  });
});

describe('loadout v2 (primary + keys)', () => {
  const mem = () => {
    const data = new Map<string, string>();
    return { data, getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => void data.set(k, v), removeItem: (k: string) => void data.delete(k) };
  };

  it('migrates a v1 array (keys only) and defaults the primary to Bone Needle', () => {
    const store = mem();
    store.data.set(legacyLoadoutKey(3), JSON.stringify(['grave_step', 'exhume', 'miasma', 'black_litany']));
    expect(loadRites(store, 3, 5)).toEqual({ primary: 'bone_needle', keys: ['grave_step', 'exhume', 'miasma', 'black_litany'] });
  });

  it('round-trips primary + keys, and v2 wins over a stale v1', () => {
    const store = mem();
    store.data.set(legacyLoadoutKey(4), JSON.stringify(['wailing_skull', 'exhume', 'miasma', 'black_litany']));
    saveRites(store, 4, { primary: 'bone_needle', keys: ['marrow_spear', 'grave_step', 'miasma', 'black_litany'] });
    expect(loadRites(store, 4, 5).keys).toEqual(['marrow_spear', 'grave_step', 'miasma', 'black_litany']);
    // Saving keys alone keeps the stored primary.
    saveLoadout(store, 4, ['exhume', 'marrow_spear', 'miasma', 'black_litany']);
    expect(JSON.parse(store.data.get(loadoutStorageKey(4))!).primary).toBe('bone_needle');
  });

  it('sanitises the primary: unknown, non-primary or locked falls back to Bone Needle', () => {
    expect(sanitizePrimary('bone_needle', 1)).toBe('bone_needle');
    expect(sanitizePrimary('marrow_spear', 99)).toBe('bone_needle');
    expect(sanitizePrimary(42, 99)).toBe('bone_needle');
    expect(sanitizePrimary(null, 99)).toBe('bone_needle');
  });

  it('marks level-1 rites and the current bar as seen; later rites start unseen', () => {
    const store = mem();
    const seen = loadSeen(store, 5, { primary: 'bone_needle', keys: ['marrow_spear', 'exhume', 'miasma', 'black_litany'] });
    expect(unseenRites(seen, 1)).toEqual([]);
    expect(unseenRites(seen, 3)).toContain('wailing_skull');
    seen.add('wailing_skull');
    expect(unseenRites(seen, 3)).not.toContain('wailing_skull');
  });
});
