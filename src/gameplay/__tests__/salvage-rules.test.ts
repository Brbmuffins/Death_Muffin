import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { ITEMS } from '../../content/items';
import { SALVAGE_GEAR_TYPES, SALVAGE_RARITIES, isSalvageGear, mergeGrants, salvageItemIds, salvagePreview, salvageYield, yieldsPlanks } from '../salvageRules';

/** A deterministic generator (mulberry32). */
function seeded(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const gear = (id: string, rarity: string, item_type = 'weapon') => ({ id, item_type, rarity });
const qty = (items: { item_id: string; quantity: number }[], id: string) => items.find((g) => g.item_id === id)?.quantity ?? 0;

describe('salvage yields', () => {
  it('every id it can return is a known item', () => {
    for (const id of salvageItemIds()) expect(ITEMS[id], id).toBeTruthy();
  });

  it('is deterministic for a seeded generator', () => {
    const a = salvageYield(gear('staff_moon', 'epic'), 40, seeded(7));
    const b = salvageYield(gear('staff_moon', 'epic'), 40, seeded(7));
    expect(a).toEqual(b);
  });

  it('gives planks for staffs, wands and grimoires, and ingots for everything else', () => {
    for (const id of ['staff_oak', 'wand_iron', 'grimoire_hell', 'tome_cleric']) expect(yieldsPlanks({ id }), id).toBe(true);
    for (const id of ['helm_copper', 'ring_copper', 'sword_iron', 'skull_focus_bone', 'chest_iron']) expect(yieldsPlanks({ id }), id).toBe(false);
    const staff = salvageYield(gear('staff_oak', 'common'), 1, seeded(1)).items.map((g) => g.item_id);
    expect(staff).toContain('plank_oak');
    expect(staff).not.toContain('ingot_copper');
    expect(salvageYield(gear('helm_copper', 'common', 'armor_head'), 1, seeded(1)).items.map((g) => g.item_id)).toContain('ingot_copper');
  });

  it('the material follows the rarity tier', () => {
    const want: Record<string, [string, string]> = {
      common: ['ingot_copper', 'plank_oak'],
      uncommon: ['ingot_iron', 'plank_willow'],
      epic: ['ingot_gold', 'plank_blackthorn'],
      legendary: ['ingot_hell', 'plank_bone_elder'],
      relic: ['ingot_moon', 'plank_bone_elder'],
    };
    for (const [rarity, [ingot, plank]] of Object.entries(want)) {
      expect(salvageYield(gear('helm_x', rarity, 'armor_head'), 1, seeded(3)).items.map((g) => g.item_id), rarity).toContain(ingot);
      expect(salvageYield(gear('staff_x', rarity), 1, seeded(3)).items.map((g) => g.item_id), rarity).toContain(plank);
    }
    const rareIngots = new Set<string>();
    const rarePlanks = new Set<string>();
    const rand = seeded(11);
    for (let i = 0; i < 80; i++) {
      for (const g of salvageYield(gear('helm_x', 'rare', 'armor_head'), 1, rand).items) if (g.item_id.startsWith('ingot_')) rareIngots.add(g.item_id);
      for (const g of salvageYield(gear('staff_x', 'rare'), 1, rand).items) if (g.item_id.startsWith('plank_')) rarePlanks.add(g.item_id);
    }
    expect([...rareIngots].sort()).toEqual(['ingot_silver', 'ingot_steel']);
    expect([...rarePlanks].sort()).toEqual(['plank_ghostwood', 'plank_yew']);
  });

  it('quantity rises with rarity: 1 for common, 2-3 at the top', () => {
    const rand = seeded(5);
    const maxOf = (rarity: string) => Math.max(...Array.from({ length: 60 }, () => qty(salvageYield(gear('helm_x', rarity, 'armor_head'), 1, rand).items, rarity === 'common' ? 'ingot_copper' : rarity === 'relic' ? 'ingot_moon' : 'ingot_hell')));
    expect(maxOf('common')).toBeLessThanOrEqual(2); // 1, plus a rare level bonus
    expect(maxOf('legendary')).toBeGreaterThanOrEqual(2);
    expect(maxOf('relic')).toBeGreaterThanOrEqual(3);
  });

  it('always gives 1-2 grave dust; ectoplasm from uncommon, bile or ash from epic, never earlier', () => {
    const rand = seeded(9);
    const seen = (rarity: string) => {
      const ids = new Set<string>();
      for (let i = 0; i < 300; i++) {
        const out = salvageYield(gear('helm_x', rarity, 'armor_head'), 1, rand);
        expect(qty(out.items, 'reagent_grave_dust')).toBeGreaterThanOrEqual(1);
        expect(qty(out.items, 'reagent_grave_dust')).toBeLessThanOrEqual(2);
        for (const g of out.items) ids.add(g.item_id);
      }
      return ids;
    };
    expect(seen('common').has('reagent_wraith_ectoplasm')).toBe(false);
    expect(seen('uncommon').has('reagent_wraith_ectoplasm')).toBe(true);
    for (const r of ['common', 'uncommon', 'rare']) {
      const ids = seen(r);
      expect(ids.has('reagent_plague_bile') || ids.has('reagent_cinder_ash'), r).toBe(false);
    }
    const epic = seen('epic');
    expect(epic.has('reagent_plague_bile')).toBe(true);
    expect(epic.has('reagent_cinder_ash')).toBe(true);
    expect(seen('common').has('bone_meal')).toBe(true);
  });

  it('Salvaging level adds +0.5% per level to one extra material', () => {
    const extra = (level: number) => {
      const rand = seeded(21);
      let n = 0;
      for (let i = 0; i < 4000; i++) if (qty(salvageYield(gear('helm_x', 'common', 'armor_head'), level, rand).items, 'ingot_copper') > 1) n++;
      return n / 4000;
    };
    expect(extra(1)).toBeLessThan(0.03);
    expect(extra(99)).toBeGreaterThan(0.44);
    expect(extra(99)).toBeLessThan(0.55);
    // rand just under the threshold gives the bonus, just over does not
    const seq = (values: number[]) => { let i = 0; return () => values[i++ % values.length]; };
    expect(qty(salvageYield(gear('helm_x', 'common', 'armor_head'), 10, seq([0, 0, 0.049, 0.9, 0.9, 0.9, 0.9, 0.9])).items, 'ingot_copper')).toBe(2);
    expect(qty(salvageYield(gear('helm_x', 'common', 'armor_head'), 10, seq([0, 0, 0.051, 0.9, 0.9, 0.9, 0.9, 0.9])).items, 'ingot_copper')).toBe(1);
  });

  it('XP scales with rarity and does not depend on level', () => {
    const xp = SALVAGE_RARITIES.map((r) => salvageYield(gear('helm_x', r, 'armor_head'), 1, seeded(1)).xp);
    expect(xp).toEqual([...xp].sort((a, b) => a - b));
    expect(new Set(xp).size).toBe(SALVAGE_RARITIES.length);
    expect(salvageYield(gear('helm_x', 'epic', 'armor_head'), 77, seeded(1)).xp).toBe(xp[3]);
  });

  it('previews list materials, the dust and the conditional reagents', () => {
    const p = salvagePreview(gear('staff_moon', 'epic'));
    expect(p.materials).toEqual(['plank_blackthorn']);
    expect(p.reagents.map((r) => r.id)).toEqual(expect.arrayContaining(['reagent_grave_dust', 'reagent_wraith_ectoplasm', 'reagent_plague_bile', 'reagent_cinder_ash']));
    expect(salvagePreview(gear('helm_x', 'common', 'armor_head')).reagents.map((r) => r.id)).not.toContain('reagent_wraith_ectoplasm');
  });

  it('knows which item types are gear, and merges grants', () => {
    for (const t of SALVAGE_GEAR_TYPES) expect(isSalvageGear(t)).toBe(true);
    expect(isSalvageGear('material')).toBe(false);
    expect(isSalvageGear('consumable')).toBe(false);
    expect(mergeGrants([[{ item_id: 'a', quantity: 1 }], [{ item_id: 'a', quantity: 2 }, { item_id: 'b', quantity: 1 }]])).toEqual([{ item_id: 'a', quantity: 3 }, { item_id: 'b', quantity: 1 }]);
  });

  it('the server bundles are fresh', async () => {
    const { bundleRulesFor } = await import('../../../tools/build-server-rules.mjs');
    const lf = (s: string) => s.replace(/\r\n/g, '\n');
    for (const key of ['salvage', 'vault']) {
      const { out, text } = await bundleRulesFor(key);
      expect(lf(readFileSync(out, 'utf8')), `run npm run build:server-rules (${key})`).toBe(lf(text));
    }
  });
});
