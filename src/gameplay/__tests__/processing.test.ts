import { describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { ALCHEMY_RECIPES } from '../../content/alchemy';
import { REAGENT_RECIPES } from '../../content/reagents';
import { ITEMS } from '../../content/items';
import { MEALS, PROCESSING_ITEMS, PROCESSING_RECIPES } from '../../content/processing';
import { NODES, TOOL_KIND, toolItemId, toolTierFor, rollBatch, type SkillId } from '../gatheringRules';

describe('Professions G6: processing', () => {
  it('every recipe uses and makes items the client knows, with icons on disk', () => {
    for (const [id, , prof, level, result, qty, ings] of PROCESSING_RECIPES) {
      expect(ITEMS[result], `${id} result`).toBeDefined();
      for (const [item, n] of ings) expect(ITEMS[item], `${id} needs ${item}`).toBeDefined(), expect(n).toBeGreaterThan(0);
      expect(['mining', 'fishing', 'woodcutting', 'gravedigging']).toContain(prof);
      expect(level).toBeGreaterThanOrEqual(1);
      expect(qty).toBeGreaterThanOrEqual(1);
    }
    for (const id of Object.keys(PROCESSING_ITEMS)) expect(existsSync(`public/art/items/${id}.png`), id).toBe(true);
    expect(new Set(PROCESSING_RECIPES.map((r) => r[0])).size).toBe(PROCESSING_RECIPES.length);
  });

  it('no gathered material is a dead end any more', () => {
    const used = new Set([...PROCESSING_RECIPES, ...ALCHEMY_RECIPES, ...REAGENT_RECIPES].flatMap((r) => r[6].map(([i]) => i)));
    // Oak, river fish and every ore already had recipes before G6.
    for (const n of Object.values(NODES)) if (!['log_oak', 'fish_river'].includes(n.item) && !n.item.startsWith('ore_')) expect(used.has(n.item), n.item).toBe(true);
    for (const m of Object.keys(MEALS)) expect(PROCESSING_ITEMS[m].kind).toBe('consumable');
  });

  it('the best tool carried sets the tier, and tools raise the odds', () => {
    expect(toolTierFor('woodcutting', ['tool_hatchet_iron', 'tool_hatchet_steel', 'tool_pickaxe_moon'])).toBe(4);
    expect(toolTierFor('mining', ['tool_hatchet_moon'])).toBe(0);
    expect(toolTierFor('gardening' as SkillId, ['tool_spade_moon'])).toBe(0);
    for (const skill of Object.keys(TOOL_KIND) as SkillId[]) for (let t = 1; t <= 6; t++) expect(ITEMS[toolItemId(skill, t)]).toBeDefined();
    const def = NODES.seam_copper;
    let seed = 1;
    const rng = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
    const bare = rollBatch(def, { level: 1, xp: 0 }, 400, rng, 0).successes;
    seed = 1;
    const tooled = rollBatch(def, { level: 1, xp: 0 }, 400, rng, 6).successes;
    expect(tooled).toBeGreaterThan(bare);
  });

  it('the server migration is generated from this module and up to date', () => {
    expect(() => execFileSync('node', ['tools/build-processing-sql.mjs', '--check'], { stdio: 'pipe' })).not.toThrow();
  });
});
