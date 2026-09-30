import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { CAPES, CHARM_ITEMS, PETS, PET_CHANCE, petChance, petForSkill } from '../../content/cosmetics';
import { ITEMS } from '../../content/items';
import { ALL_SKILLS, NODES } from '../gatheringRules';
import { capeProgress, isCape, isPet, totalLevel, unlockedCapes } from '../cosmeticRules';

const all = (n: number) => Object.fromEntries(ALL_SKILLS.map((s) => [s, n]));

describe('capes', () => {
  it('has unique ids, and one mastery cape per skill', () => {
    expect(new Set(CAPES.map((c) => c.id)).size).toBe(CAPES.length);
    for (const s of ALL_SKILLS) expect(CAPES.some((c) => c.skill === s), s).toBe(true);
  });

  it('unlocks a mastery cape only at 99 in that skill', () => {
    expect(unlockedCapes({ woodcutting: 98 })).not.toContain('cape_woodcutting');
    expect(unlockedCapes({ woodcutting: 99 })).toContain('cape_woodcutting');
    expect(unlockedCapes({ woodcutting: 99 })).not.toContain('cape_mining');
  });

  it('unlocks the mantles by total level, up to the Sexton\'s Mantle at all 99', () => {
    expect(totalLevel({})).toBe(ALL_SKILLS.length);
    expect(unlockedCapes({})).toEqual([]);
    expect(unlockedCapes(all(17))).toContain('cape_apprentice');
    expect(unlockedCapes(all(50))).toContain('cape_journeyman');
    expect(unlockedCapes(all(50))).not.toContain('cape_sexton');
    expect(totalLevel(all(99))).toBe(594);
    expect(unlockedCapes(all(99))).toContain('cape_sexton');
    expect(unlockedCapes(all(99))).toHaveLength(CAPES.length);
  });

  it('reports progress toward a locked cape', () => {
    const c = CAPES.find((x) => x.id === 'cape_fishing')!;
    expect(capeProgress(c, { fishing: 74 })).toEqual({ unlocked: false, have: 74, need: 99 });
    const m = CAPES.find((x) => x.id === 'cape_journeyman')!;
    expect(capeProgress(m, all(40))).toMatchObject({ unlocked: false, have: 240, need: 300 });
  });
});

describe('pets', () => {
  it('every pet has a charm item in the catalogue, and skills own at most one pet', () => {
    for (const p of PETS) {
      expect(CHARM_ITEMS[p.charm], p.id).toBeTruthy();
      expect(ITEMS[p.charm], p.charm).toBeTruthy();
    }
    expect(new Set(PETS.map((p) => p.skill)).size).toBe(PETS.length);
    expect(petForSkill('woodcutting')?.id).toBe('pet_tithe_bat');
  });

  it('charms can be found: every gathering node offers its skill\'s charm at a rare, level-scaled chance', () => {
    for (const n of Object.values(NODES)) {
      const pet = petForSkill(n.skill);
      if (!pet) continue;
      const extra = n.extras.find((e) => e.item === pet.charm);
      expect(extra, `${n.id} has no ${pet.charm}`).toBeTruthy();
      expect(extra!.chance).toBeCloseTo(petChance(n.level), 8);
      expect(extra!.chance).toBeLessThan(1 / 1000);
    }
    expect(petChance(90)).toBeGreaterThan(PET_CHANCE);
  });

  it('sanitises what other players broadcast', () => {
    expect(isCape('cape_mining')).toBe(true);
    expect(isCape('sword_iron')).toBe(false);
    expect(isPet('pet_grave_rat')).toBe(true);
    expect(isPet(42)).toBe(false);
  });
});

describe('server migration', () => {
  it('010-cosmetics.sql is generated from the content (run node tools/build-cosmetics-sql.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-cosmetics-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });
});
