import { describe, expect, it } from 'vitest';
import { AREAS, type AreaId } from '../../../server/rules/content/areas';
import { ENEMIES, type EnemyId } from '../../../server/rules/content/enemies';
import { ITEMS } from '../../../server/rules/content/items';
import { isProfessionMaterial, rollBoss, rollItem, rollKill, rollSurgeItem, settleCombatDrop } from '../loot';
import { rollChest } from '../depthsRewards';

/** A small deterministic generator, so two runs see the same rolls. */
const seeded = (seed: number) => () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
const huntingGrounds = (Object.keys(AREAS) as AreaId[]).filter((a) => AREAS[a].loot.length);
const enemyOf = (area: AreaId): EnemyId => AREAS[area].enemies[0]?.id ?? (Object.keys(ENEMIES)[0] as EnemyId);

describe('the dead drop no profession materials (owner, 2026-10-04)', () => {
  it('kills, elites and bosses never drop ore, bars, logs, bones, seeds or herbs', () => {
    for (const area of huntingGrounds) {
      const r = seeded(7);
      for (let i = 0; i < 3000; i++) {
        for (const d of rollKill(enemyOf(area), area, AREAS[area].level, i % 5 === 0, 0, r).items) expect(isProfessionMaterial(d.item_id), `${area}: ${d.item_id}`).toBe(false);
      }
      for (let i = 0; i < 200; i++) for (const d of rollBoss(0, r, 'medium', area).items) expect(isProfessionMaterial(d.item_id) && !d.item_id.startsWith('gem_'), `${area} boss: ${d.item_id}`).toBe(false);
      for (let i = 0; i < 200; i++) expect(isProfessionMaterial(rollSurgeItem(area, r).item_id), `${area} surge`).toBe(false);
    }
  });

  it('gear drops exactly as often as before: same rolls, same gear, materials paid as gold', () => {
    for (const area of huntingGrounds) {
      // "Before" = the raw area roll; "after" = the settled one. Settling consumes no randomness, so the two streams line up.
      const a = seeded(11), b = seeded(11);
      let gearBefore = 0, gearAfter = 0, goldDelta = 0;
      for (let i = 0; i < 2000; i++) {
        const raw = rollItem(area, a);
        const settled = settleCombatDrop(rollItem(area, b));
        if (!isProfessionMaterial(raw.item_id)) gearBefore++;
        if (settled.drop) gearAfter++;
        goldDelta += settled.gold;
        if (isProfessionMaterial(raw.item_id)) expect(settled.gold).toBe(Math.max(1, Math.round(ITEMS[raw.item_id].sell * raw.quantity)));
      }
      expect(gearAfter, area).toBe(gearBefore);
      expect(goldDelta, area).toBeGreaterThanOrEqual(0);
    }
  });

  it('Depths chests keep their guaranteed gear and may still hold gems', () => {
    const r = seeded(3);
    for (let i = 0; i < 100; i++) {
      const c = rollChest(10, 30, r);
      expect(c.drops.length).toBeGreaterThan(0);
      for (const d of c.drops) expect(isProfessionMaterial(d.item_id) && !d.item_id.startsWith('gem_')).toBe(false);
    }
  });
});
