import { describe, expect, it } from 'vitest';
import { AREA_ORDER } from '../areas';
import { LEGENDARY_BOSS_AREAS, LEGENDARY_BOSS_CHANCE, LEGENDARY_DROP, LEGENDARY_STARTER_AREA, legendaryBossChance } from '../legendarySets';

describe('legendary boss chance (owner, 3 Oct 2026: it climbs as you descend, the starter boss has its own, none elsewhere)', () => {
  it('every rolling boss area answers with its table entry (the base chance when it has none)', () => {
    for (const area of LEGENDARY_BOSS_AREAS) expect(legendaryBossChance(area), area).toBe(LEGENDARY_BOSS_CHANCE[area] ?? LEGENDARY_DROP.bossChance);
  });
  it('deeper bosses never leave less than shallower ones, and every chance is a real chance', () => {
    const chances = AREA_ORDER.filter((id) => LEGENDARY_BOSS_AREAS.includes(id)).map(legendaryBossChance);
    expect(chances.length).toBe(LEGENDARY_BOSS_AREAS.length);
    expect(chances).toEqual([...chances].sort((a, b) => a - b));
    for (const c of chances) {
      expect(c).toBeGreaterThan(0);
      expect(c).toBeLessThanOrEqual(1);
    }
  });
  it('the starter boss answers its own chance, and the areas that roll no legendary boss answer 0', () => {
    expect(legendaryBossChance(LEGENDARY_STARTER_AREA)).toBe(LEGENDARY_DROP.starterBossChance);
    for (const area of AREA_ORDER.filter((id) => id !== LEGENDARY_STARTER_AREA && !LEGENDARY_BOSS_AREAS.includes(id))) expect(legendaryBossChance(area), area).toBe(0);
  });
});
