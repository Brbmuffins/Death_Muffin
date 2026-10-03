import { describe, expect, it } from 'vitest';
import { getAtlas } from '../atlas';
import { BUFF_FLASKS, HEALING_FLASKS, ITEMS } from '../../content/items';
import { COMPOST_ITEM, SEEDS } from '../../content/gardening';
import { MEALS } from '../../content/processing';
import { PETS } from '../../content/cosmetics';
import { candidatesFor, generateBoard, RELIC_ORDERS, RELIC_PREMIUM } from '../contractRules';
import { SKILLS } from '../gatheringRules';

/**
 * Docs/polish/loot.md item 14: nothing the player can pick up or make may be sell-only. Every material that drops (or is crafted)
 * must be eaten by a recipe, asked for by the Sexton, planted, drunk, eaten, adopted or carried on the belt. The allowlist of
 * sell-only items is the owner's decision (3 Oct 2026): it must stay empty.
 */
const SELL_ONLY_ALLOWLIST: string[] = [];

const MAXED = Object.fromEntries(Object.keys(SKILLS).map((s) => [s, 99]));

/** Every item id with a consumer, and the first consumer found (for the failure message). */
function consumers(): Map<string, string> {
  const a = getAtlas();
  const out = new Map<string, string>();
  const put = (id: string, how: string) => out.has(id) || out.set(id, how);
  for (const [id, list] of a.usedIn) if (list.length) put(id, `recipe ${list[0].id}`);
  for (const c of candidatesFor(MAXED)) put(c.itemId, `contract (${c.skill} ${c.level})`);
  for (const s of SEEDS) put(s.id, `plot (${s.kind})`);
  put(COMPOST_ITEM, 'plot compost');
  for (const id of [...Object.keys(BUFF_FLASKS), ...Object.keys(HEALING_FLASKS), ...Object.keys(MEALS)]) put(id, 'drink or eat');
  for (const p of PETS) put(p.charm, 'adopt a pet');
  for (const id of Object.keys(ITEMS)) if (id.startsWith('tool_')) put(id, 'tool belt');
  return out;
}

describe('trade goods have uses', () => {
  it('no dropped or crafted material is sell-only', () => {
    const a = getAtlas();
    const used = consumers();
    const dead: string[] = [];
    for (const [id, meta] of Object.entries(ITEMS)) {
      if (meta.type !== 'material') continue;
      const obtainable = (a.sources.get(id)?.length ?? 0) > 0 || (a.madeBy.get(id)?.length ?? 0) > 0;
      if (obtainable && !used.has(id) && !SELL_ONLY_ALLOWLIST.includes(id)) dead.push(id);
    }
    expect(dead, `sell-only items: ${dead.join(', ')}`).toEqual([]);
    expect(SELL_ONLY_ALLOWLIST).toEqual([]);
  });

  it('every seed and sapling has a plot kind to grow in', () => {
    for (const s of SEEDS) expect(['herb', 'tree'], s.id).toContain(s.kind);
    for (const id of Object.keys(ITEMS)) if (/^(seed|sapling)_/.test(id)) expect(SEEDS.some((s) => s.id === id), `${id} has no plot`).toBe(true);
  });

  it('the Sexton asks for the gems, the fragment and the seal, at the level that finds them', () => {
    for (const r of RELIC_ORDERS) {
      expect(ITEMS[r.itemId], r.itemId).toBeTruthy();
      expect(candidatesFor({ [r.skill]: r.level - 1 }).some((c) => c.itemId === r.itemId)).toBe(false);
      expect(candidatesFor({ [r.skill]: r.level }).some((c) => c.itemId === r.itemId)).toBe(true);
    }
    expect(candidatesFor(MAXED).some((c) => c.itemId === 'ingot_tin')).toBe(true);
    expect(candidatesFor(MAXED).some((c) => c.itemId === 'ingot_bronze')).toBe(true);
    const seen = new Set<string>();
    for (let c = 1; c <= 400; c++) for (const o of generateBoard(c, '2026-10-03', MAXED)) seen.add(o.itemId);
    for (const r of RELIC_ORDERS) expect(seen.has(r.itemId), `${r.itemId} never ordered`).toBe(true);
  });

  it('relic orders only ever stand in for the hard order, and the first two stay ordinary', () => {
    const relic = new Set(RELIC_ORDERS.map((r) => r.itemId));
    let hard = 0;
    for (let c = 1; c <= 300; c++) {
      const board = generateBoard(c, '2026-10-03', MAXED);
      expect(relic.has(board[0].itemId) || relic.has(board[1].itemId)).toBe(false);
      if (relic.has(board[2].itemId)) hard++;
    }
    expect(hard / 300).toBeGreaterThan(0.1);
    expect(hard / 300).toBeLessThan(0.3);
  });

  it('there is no gold loop: orders pay at most 2x sell, relics are never paid back, and nothing is bought', () => {
    const relic = new Set(RELIC_ORDERS.map((r) => r.itemId));
    expect(RELIC_PREMIUM).toBeLessThanOrEqual(2);
    for (let c = 1; c <= 300; c++) {
      for (const o of generateBoard(c, '2026-10-03', MAXED)) {
        const sell = ITEMS[o.itemId].sell;
        if (relic.has(o.itemId)) {
          // A relic order pays about 2x what the vendor would (plus the slot's flat fee) and hands back only a Grave Garnet.
          expect(o.rewardGold).toBeLessThanOrEqual(Math.round(o.qty * sell * RELIC_PREMIUM) + 60);
          expect(o.rewardItem?.itemId).toBe('gem_grave_garnet');
          expect(o.rewardItem?.qty).toBe(1);
          expect(o.qty * sell).toBeGreaterThanOrEqual((o.rewardItem?.qty ?? 0) * ITEMS.gem_grave_garnet.sell);
        }
      }
    }
  });
});
