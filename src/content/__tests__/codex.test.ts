import { describe, expect, it } from 'vitest';
import { ABILITIES, SPELL_FX, type AbilityId } from '../abilities';
import { AREAS, AREA_ORDER, type AreaId } from '../../../server/rules/content/areas';
import { DISCIPLINES, type DisciplineId } from '../../../server/rules/content/disciplines';
import { ENEMIES, type EnemyId } from '../../../server/rules/content/enemies';
import {
  BEHAVIOUR_LABEL,
  CODEX_AREAS,
  CODEX_DEAD,
  CODEX_DISCIPLINES,
  CODEX_RITES,
  COVENANT_LORE,
  DEAD_ORDER,
  RITE_ORDER,
  areaUnlockText,
  hexColour,
  riteSwatch,
} from '../codex';
import { CodexJournal, codexStorageKey, type StorageLike } from '../../gameplay/codexJournal';

/** In-memory Web Storage stand-in (vitest runs in node, no localStorage). */
class MemoryStorage implements StorageLike {
  data = new Map<string, string>();
  getItem(key: string) {
    return this.data.get(key) ?? null;
  }
  setItem(key: string, value: string) {
    this.data.set(key, value);
  }
}

/** Storage that throws on every access (private mode / blocked site data). */
const brokenStorage: StorageLike = {
  getItem() {
    throw new Error('SecurityError');
  },
  setItem() {
    throw new Error('QuotaExceededError');
  },
};

const filled = (s: string | undefined) => typeof s === 'string' && s.trim().length > 0;

describe('codex coverage', () => {
  it('every ability has a rite entry with a tip and a real SPELL_FX colour identity', () => {
    expect([...RITE_ORDER].sort()).toEqual(Object.keys(ABILITIES).sort());
    for (const id of Object.keys(ABILITIES) as AbilityId[]) {
      const r = CODEX_RITES[id];
      expect(r, id).toBeDefined();
      expect(filled(r.tip), `${id} tip`).toBe(true);
      expect(filled(r.colour), `${id} colour`).toBe(true);
      expect(SPELL_FX[r.fx], `${id} fx`).toBeDefined();
      const chips = riteSwatch(id);
      expect(chips.length).toBeGreaterThan(0);
      for (const c of chips) expect(c).toMatch(/^#[0-9a-f]{6}$/);
    }
  });

  it('every discipline has a codex entry', () => {
    for (const id of Object.keys(DISCIPLINES) as DisciplineId[]) expect(filled(CODEX_DISCIPLINES[id]?.tip), id).toBe(true);
  });

  it('every enemy (Risen included) and the Prelate has a complete entry in The Dead', () => {
    for (const id of Object.keys(ENEMIES) as EnemyId[]) {
      expect(DEAD_ORDER, id).toContain(id);
      expect(CODEX_DEAD[id].name).toBe(ENEMIES[id].name);
    }
    expect(DEAD_ORDER).toContain('risen');
    expect(DEAD_ORDER).toContain('prelate');
    expect(new Set(DEAD_ORDER).size).toBe(DEAD_ORDER.length);
    for (const id of DEAD_ORDER) {
      const e = CODEX_DEAD[id];
      for (const field of ['name', 'behaviour', 'corpse', 'counter'] as const) expect(filled(e[field]), `${id}.${field}`).toBe(true);
      expect(BEHAVIOUR_LABEL[e.role], `${id} role`).toBeDefined();
    }
  });

  it('every area has a Diocese entry with dangers and an unlock line that matches the area table', () => {
    expect([...AREA_ORDER].sort()).toEqual(Object.keys(AREAS).sort());
    for (const id of Object.keys(AREAS) as AreaId[]) {
      expect(filled(CODEX_AREAS[id]?.dangers), id).toBe(true);
      expect(filled(areaUnlockText(id)), `${id} unlock`).toBe(true);
      const u = AREAS[id].unlock;
      if (u) expect(areaUnlockText(id)).toContain(String(u.kills));
    }
  });

  it('carries 3–4 paragraphs of Covenant lore', () => {
    expect(COVENANT_LORE.paragraphs.length).toBeGreaterThanOrEqual(3);
    expect(COVENANT_LORE.paragraphs.length).toBeLessThanOrEqual(4);
    for (const p of COVENANT_LORE.paragraphs) expect(filled(p)).toBe(true);
  });

  it('formats three.js hex colours', () => {
    expect(hexColour(0x0a0b0c)).toBe('#0a0b0c');
    expect(hexColour(0x9b5cff)).toBe('#9b5cff');
  });
});

describe('codex discovery persistence', () => {
  it('starts sealed and records each discovery once', () => {
    const j = new CodexJournal(7, new MemoryStorage());
    expect(j.has('dead', 'deacon')).toBe(false);
    expect(j.has('area', 'graves')).toBe(false);
    expect(j.discover('dead', 'deacon')).toBe(true);
    expect(j.discover('dead', 'deacon')).toBe(false);
    expect(j.discover('area', 'graves')).toBe(true);
    expect(j.has('dead', 'deacon')).toBe(true);
    expect(j.count('dead')).toBe(1);
    expect(j.count('area')).toBe(1);
  });

  it('persists per character under dm_codex_v1_<characterId>', () => {
    const storage = new MemoryStorage();
    const a = new CodexJournal(11, storage);
    a.discover('dead', 'prelate');
    a.discover('dead', 'risen');
    a.discover('area', 'sanctum');
    expect(storage.data.has(codexStorageKey(11))).toBe(true);
    expect(codexStorageKey(11)).toBe('dm_codex_v1_11');

    const reloaded = new CodexJournal(11, storage);
    expect(reloaded.has('dead', 'prelate')).toBe(true);
    expect(reloaded.has('dead', 'risen')).toBe(true);
    expect(reloaded.has('area', 'sanctum')).toBe(true);
    expect(reloaded.has('dead', 'robber')).toBe(false);

    // Another character on the same browser starts sealed.
    const other = new CodexJournal(12, storage);
    expect(other.count('dead')).toBe(0);
    expect(other.count('area')).toBe(0);
  });

  it('notifies listeners only on new discoveries', () => {
    const j = new CodexJournal(3, new MemoryStorage());
    let calls = 0;
    const off = j.onChange(() => calls++);
    j.discover('dead', 'hound');
    j.discover('dead', 'hound');
    expect(calls).toBe(1);
    off();
    j.discover('dead', 'sac');
    expect(calls).toBe(1);
  });

  it('ignores corrupt or unknown stored data', () => {
    const storage = new MemoryStorage();
    storage.setItem(codexStorageKey(5), '{not json');
    expect(new CodexJournal(5, storage).count('dead')).toBe(0);
    storage.setItem(codexStorageKey(5), JSON.stringify({ dead: ['robber', 'dragon', 42], area: 'graves' }));
    const j = new CodexJournal(5, storage);
    expect(j.has('dead', 'robber')).toBe(true);
    expect(j.count('dead')).toBe(1);
    expect(j.count('area')).toBe(0);
  });

  it('keeps working in-session when storage is unavailable', () => {
    for (const storage of [brokenStorage, null]) {
      const j = new CodexJournal(9, storage);
      expect(j.count('dead')).toBe(0);
      expect(j.discover('dead', 'penitent')).toBe(true);
      expect(j.has('dead', 'penitent')).toBe(true);
    }
  });
});
