import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, HUNT_ORDER, chaseMult, huntRank, isChaseItem } from '../areas';
import { ITEMS } from '../items';

describe('the descent order (owner, 3 Oct 2026: "the map is out of order, it should descend")', () => {
  it('lists every area once', () => {
    expect([...AREA_ORDER].sort()).toEqual(Object.keys(AREAS).sort());
  });
  it('safe halls come first, then the hunting grounds from the shallowest level to the deepest', () => {
    const halls = AREA_ORDER.filter((id) => AREAS[id].safe);
    expect(AREA_ORDER.slice(0, halls.length)).toEqual(halls);
    const hunts = AREA_ORDER.slice(halls.length);
    for (const id of hunts) expect(AREAS[id].safe, `${id} is a ground`).toBe(false); // no hall hides among the grounds
    const levels = hunts.map((id) => AREAS[id].level);
    expect(levels).toEqual([...levels].sort((a, b) => a - b));
  });
  it('the main line reads Chapterhouse, Graves, Ossuary, Nave, Sanctum, Cloister, Pyre, Fen', () => {
    const main = ['chapterhouse', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'];
    expect(AREA_ORDER.filter((id) => main.includes(id))).toEqual(main);
  });
  it('a ground never comes before the one that unlocks it', () => {
    for (const id of AREA_ORDER) {
      const from = AREAS[id].unlock?.area;
      if (from) expect(AREA_ORDER.indexOf(from), `${id} after ${from}`).toBeLessThan(AREA_ORDER.indexOf(id));
    }
  });
});

describe('drop quality by depth', () => {
  it('build gear is weighted up more the deeper the ground, and only build gear', () => {
    let prev = 0;
    for (const id of HUNT_ORDER) {
      expect(chaseMult(id)).toBeGreaterThan(prev);
      prev = chaseMult(id);
    }
    expect(huntRank('graves')).toBe(0);
    expect(huntRank('fen')).toBe(HUNT_ORDER.length - 1);
    expect(huntRank('chapterhouse')).toBe(-1);
  });
  it('materials, flasks and starter gear are never scaled', () => {
    for (const id of Object.keys(ITEMS)) if (ITEMS[id].type === 'material' || /^(flask|ore|log|ingot|gem|herb|seed)_/.test(id)) expect(isChaseItem(id), id).toBe(false);
  });
});
