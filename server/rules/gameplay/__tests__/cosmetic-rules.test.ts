import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { CAPES, CHARM_ITEMS, PETS, PET_CHANCE, petChance, petForSkill } from '../../content/cosmetics';
import { ITEMS } from '../../content/items';
import { ALL_SKILLS, LEVEL_CAP, NODES } from '../gatheringRules';
import { capeProgress, isCape, isPet, totalLevel, unlockedCapes } from '../cosmeticRules';

const all = (n: number) => Object.fromEntries(ALL_SKILLS.map((s) => [s, n]));

describe('capes', () => {
  it('has unique ids, and one mastery cape per skill', () => {
    expect(new Set(CAPES.map((c) => c.id)).size).toBe(CAPES.length);
    for (const s of ALL_SKILLS) expect(CAPES.some((c) => c.skill === s), s).toBe(true);
  });

  it('unlocks a mastery cape only at the level cap in that skill', () => {
    const mastery = CAPES.filter((c) => c.skill);
    expect(mastery.length).toBeGreaterThan(0);
    for (const c of mastery) {
      expect(unlockedCapes({ [c.skill!]: LEVEL_CAP - 1 }), c.id).not.toContain(c.id);
      const got = unlockedCapes({ [c.skill!]: LEVEL_CAP });
      expect(got, c.id).toContain(c.id);
      expect(got.filter((id) => mastery.some((m) => m.id === id)), c.id).toEqual([c.id]); // no other skill's cape comes with it
    }
  });

  it('unlocks the mantles by total level, the highest only once every skill can reach it', () => {
    const n = ALL_SKILLS.length;
    expect(totalLevel({})).toBe(n);
    expect(unlockedCapes({})).toEqual([]);
    const mantles = CAPES.filter((c) => c.total !== undefined).sort((a, b) => a.total! - b.total!);
    expect(mantles.length).toBeGreaterThan(0);
    for (const m of mantles) {
      const level = Math.ceil(m.total! / n); // the lowest level in every skill that reaches the total
      expect(unlockedCapes(all(level)), m.id).toContain(m.id);
      if (level > 1) expect(unlockedCapes(all(level - 1)), m.id).not.toContain(m.id);
    }
    expect(mantles[mantles.length - 1].total).toBeLessThanOrEqual(n * LEVEL_CAP); // the top mantle can be earned
    expect(totalLevel(all(LEVEL_CAP))).toBe(n * LEVEL_CAP);
    expect(unlockedCapes(all(LEVEL_CAP))).toHaveLength(CAPES.length);
  });

  it('reports progress toward a locked cape', () => {
    const c = CAPES.find((x) => x.skill)!;
    const have = Math.floor(LEVEL_CAP / 2);
    expect(capeProgress(c, { [c.skill!]: have })).toEqual({ unlocked: false, have, need: LEVEL_CAP });
    const m = CAPES.find((x) => x.total !== undefined)!;
    const n = ALL_SKILLS.length;
    const level = Math.max(1, Math.floor((m.total! - 1) / n)); // the highest all-skills level still short of the total
    expect(capeProgress(m, all(level))).toMatchObject({ unlocked: n * level >= m.total!, have: n * level, need: m.total });
    expect(capeProgress(m, all(Math.ceil(m.total! / n)))).toMatchObject({ unlocked: true, need: m.total });
  });
});

describe('pets', () => {
  it('every pet has a charm item in the catalogue, and skills own at most one pet', () => {
    for (const p of PETS) {
      expect(CHARM_ITEMS[p.charm], p.id).toBeTruthy();
      expect(ITEMS[p.charm], p.charm).toBeTruthy();
    }
    expect(new Set(PETS.map((p) => p.skill)).size).toBe(PETS.length);
    for (const p of PETS) expect(petForSkill(p.skill), p.id).toBe(p);
  });

  it('charms can be found: every gathering node offers its skill\'s charm at a rare, level-scaled chance', () => {
    for (const n of Object.values(NODES)) {
      const pet = petForSkill(n.skill);
      if (!pet) continue;
      const extra = n.extras.find((e) => e.item === pet.charm);
      expect(extra, `${n.id} has no ${pet.charm}`).toBeTruthy();
      expect(extra!.chance).toBeCloseTo(petChance(n.level), 8);
      expect(extra!.chance).toBeGreaterThan(0);
      expect(extra!.chance).toBeLessThan(1);
    }
    expect(petChance(90)).toBeGreaterThan(PET_CHANCE); // deeper nodes find charms more often
  });

  it('sanitises what other players broadcast', () => {
    expect(isCape(CAPES[0].id)).toBe(true);
    expect(isCape('sword_iron')).toBe(false);
    expect(isCape(PETS[0].id)).toBe(false);
    expect(isPet(PETS[0].id)).toBe(true);
    expect(isPet(CAPES[0].id)).toBe(false);
    expect(isPet(42)).toBe(false);
  });
});

describe('server migration', () => {
  it('010-cosmetics.sql is generated from the content (run node tools/build-cosmetics-sql.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-cosmetics-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });
});
