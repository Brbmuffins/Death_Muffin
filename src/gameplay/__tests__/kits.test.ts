import { describe, expect, it } from 'vitest';
import {
  DEFAULT_LOADOUT,
  DEFAULT_PRIMARY,
  GRIMOIRE,
  HOTBAR,
  PRIMARIES,
  SIGNATURE_BY_DISCIPLINE,
} from '../../content/abilities';
import { DISCIPLINES, PLAYABLE_DISCIPLINES, type ClassFamily } from '../../content/disciplines';
import { kitFor, signatureFor } from '../../content/kits';
import { sanitizeLoadout, sanitizePrimary } from '../loadout';

const FAMILIES: ClassFamily[] = ['necromancer', 'knight', 'warden', 'monk', 'witch', 'veil'];

describe('kits — necromancer regression', () => {
  // The necromancer kit must stay exactly the pre-framework constants, or the
  // four necromantic disciplines have silently changed what they play.
  it('is built from the shipped necromancer constants', () => {
    const kit = kitFor('necromancer');
    expect(kit.hotbar).toEqual(HOTBAR);
    expect(kit.grimoire).toEqual(GRIMOIRE);
    expect(kit.defaultLoadout).toEqual(DEFAULT_LOADOUT);
    expect(kit.primaries).toEqual(PRIMARIES);
    expect(kit.defaultPrimary).toBe(DEFAULT_PRIMARY);
    expect(kit.rmb).toBe('corpse_explosion');
  });

  it('keeps every necromantic discipline signature', () => {
    for (const d of ['ossuary', 'gravecaller', 'mourner', 'rotweaver'] as const) {
      expect(signatureFor('necromancer', d)).toBe(SIGNATURE_BY_DISCIPLINE[d]);
    }
  });

  it('defaults loadout and primary readers to the necromancer kit', () => {
    // No kit argument = the pre-framework behaviour.
    expect(sanitizeLoadout(null, 1)).toEqual(sanitizeLoadout(null, 1, kitFor('necromancer')));
    expect(sanitizePrimary(null, 1)).toBe(DEFAULT_PRIMARY);
  });
});

describe('kits — framework invariants', () => {
  it('gives every family a kit, so no discipline_index can load a class with no rites', () => {
    for (const family of FAMILIES) {
      const kit = kitFor(family);
      expect(kit.grimoire.length).toBeGreaterThanOrEqual(4);
      expect(kit.primaries).toContain(kit.defaultPrimary);
      expect(kit.defaultLoadout).toHaveLength(4);
    }
  });

  it('only exposes disciplines whose family has a real kit and a signature', () => {
    for (const d of PLAYABLE_DISCIPLINES) {
      expect(signatureFor(d.family, d.id)).toBeDefined();
    }
  });

  it('every discipline declares a family in the union', () => {
    for (const d of Object.values(DISCIPLINES)) {
      expect(FAMILIES).toContain(d.family);
    }
  });
});
