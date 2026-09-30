import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { ALCHEMY_BUFFS, ALCHEMY_HEALING, ALCHEMY_ITEMS, ALCHEMY_RECIPES } from '../../content/alchemy';
import { REAGENT_RECIPES } from '../../content/reagents';
import { SEEDS } from '../../content/gardening';
import { BUFF_FLASKS, HEALING_FLASKS, ITEMS } from '../../content/items';
import { SKILLS, ALL_SKILLS } from '../gatheringRules';

const herbs = new Set(SEEDS.filter((s) => s.kind === 'herb').map((s) => s.harvest));

describe('alchemy content', () => {
  it('is a real skill with a name and a place in the Skills grid', () => {
    expect(SKILLS.alchemy.name).toBe('Alchemy');
    expect(ALL_SKILLS).toContain('alchemy');
  });

  it('every recipe brews from known items into a known result, at rising levels', () => {
    let last = 0;
    for (const [id, name, prof, level, result, qty, ings] of ALCHEMY_RECIPES) {
      expect(prof, id).toBe('alchemy');
      expect(name).toBeTruthy();
      expect(ITEMS[result], `${id} result ${result}`).toBeTruthy();
      expect(qty).toBeGreaterThanOrEqual(1);
      expect(ings.length).toBeGreaterThan(0);
      for (const [item, n] of ings) {
        expect(ITEMS[item], `${id} ingredient ${item}`).toBeTruthy();
        expect(n).toBeGreaterThan(0);
      }
      expect(level).toBeGreaterThanOrEqual(last);
      last = level;
    }
  });

  it('the herb potions actually consume herbs, and the top herbs are worth brewing', () => {
    const used = new Set([...ALCHEMY_RECIPES, ...REAGENT_RECIPES].flatMap((r) => r[6].map(([item]) => item)));
    for (const herb of herbs) expect(used.has(herb), `${herb} is never used`).toBe(true);
  });

  it('new potions work when drunk: each has an effect, and a heal never exceeds a full bar', () => {
    for (const id of Object.keys(ALCHEMY_ITEMS)) expect(id in HEALING_FLASKS || id in BUFF_FLASKS, `${id} does nothing`).toBe(true);
    for (const [id, frac] of Object.entries(ALCHEMY_HEALING)) {
      expect(HEALING_FLASKS[id]).toBe(frac);
      expect(frac).toBeGreaterThan(HEALING_FLASKS.flask_hp_major);
      expect(frac).toBeLessThanOrEqual(1);
    }
    for (const id of Object.keys(ALCHEMY_BUFFS)) expect(BUFF_FLASKS[id].seconds).toBeGreaterThan(0);
  });

  it('every recipe result that is a flask is drinkable', () => {
    for (const r of ALCHEMY_RECIPES) expect(r[4] in HEALING_FLASKS || r[4] in BUFF_FLASKS, r[4]).toBe(true);
  });
});

describe('server migration', () => {
  it('009-alchemy.sql is generated from the content (run node tools/build-alchemy-sql.mjs if this fails)', () => {
    expect(() => execFileSync('node', ['tools/build-alchemy-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });
});
