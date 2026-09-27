import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import {
  GATHER_SKILLS,
  LEVEL_CAP,
  NODES,
  NODE_IDS,
  addSkillXp,
  checkBudget,
  blankLedger,
  grantableItems,
  nodesForSkill,
  placeItems,
  rollBatch,
  totalXpFor,
  xpPerHour,
  xpToNextCurve,
  xpToNextLive,
} from '../gatheringRules';
import { ITEMS } from '../../content/items';
import { addToSlots } from '../loot';
import { mulberry32 } from '../rng';

describe('gathering rules', () => {
  it('every item a node can grant is a known item id', () => {
    for (const id of grantableItems()) expect(ITEMS[id], id).toBeDefined();
  });

  it('gathered materials stack to 250 on the client like the server', () => {
    for (const n of NODE_IDS) expect(ITEMS[NODES[n].item].stack, NODES[n].item).toBe(250);
  });

  it('each gathering skill has a level-1 node and levels climb', () => {
    for (const s of GATHER_SKILLS) {
      const list = nodesForSkill(s);
      expect(list[0].level, s).toBe(1);
      for (let i = 1; i < list.length; i++) expect(list[i].level).toBeGreaterThanOrEqual(list[i - 1].level);
    }
  });

  it('XP/h stays inside the §9 targets (tier 1 ≈ 4–5k, top tier ≈ 40k)', () => {
    for (const s of GATHER_SKILLS) {
      const [first] = nodesForSkill(s);
      expect(xpPerHour(first, 1), `${s} tier 1 at 1`).toBeGreaterThan(3000);
      expect(xpPerHour(first, 15), `${s} tier 1 at 15`).toBeLessThan(8000);
    }
    const top = [NODES.bone_elder, NODES.geode_moon, NODES.pool_coelacanth];
    for (const n of top) {
      expect(xpPerHour(n, 95), n.id).toBeGreaterThan(25000);
      expect(xpPerHour(n, 99), n.id).toBeLessThan(50000);
    }
  });

  it('the live curve is the default and the recommended curve matches the roadmap table', () => {
    expect(totalXpFor(99, xpToNextLive)).toBe(242550);
    expect(totalXpFor(10, xpToNextCurve)).toBe(2250);
    const t99 = totalXpFor(99, xpToNextCurve);
    expect(t99).toBeGreaterThan(1_450_000);
    expect(t99).toBeLessThan(1_600_000);
  });

  it('addSkillXp rolls levels and stops at the cap', () => {
    expect(addSkillXp({ level: 1, xp: 40 }, 20)).toEqual({ level: 2, xp: 10, leveled: 1 });
    const capped = addSkillXp({ level: 98, xp: 0 }, 1e9);
    expect(capped.level).toBe(LEVEL_CAP);
    expect(capped.xp).toBe(0);
  });

  it('below the node level a batch earns nothing', () => {
    const r = rollBatch(NODES.churchyard_yew, { level: 10, xp: 0 }, 20, mulberry32(1));
    expect(r.successes).toBe(0);
    expect(r.items).toEqual([]);
  });

  it('a long batch lands near the expected success rate', () => {
    const def = NODES.coffin_oak;
    const r = rollBatch(def, { level: 1, xp: 0 }, 2000, mulberry32(3));
    expect(r.successes / 2000).toBeGreaterThan(0.55);
    expect(r.successes / 2000).toBeLessThan(0.8); // levels rise during the batch
  });

  it('the budget clamps claims to elapsed time', () => {
    const def = NODES.coffin_oak;
    const first = checkBudget(def, blankLedger(), 100, 10_000);
    expect(first.ok && first.accepted).toBe(15);
    if (!first.ok) return;
    const soon = checkBudget(def, first.ledger, 100, 10_000 + 4800);
    expect(soon.ok && soon.accepted).toBe(2 + 3);
    expect(checkBudget(def, blankLedger(), 0, 1).ok).toBe(false);
  });

  it('placeItems tops up stacks, then free slots, then rejects', () => {
    const bag = [{ slot: 0, itemId: 'log_oak', qty: 248 }];
    const p = placeItems(bag, [{ itemId: 'log_oak', qty: 5 }], () => 250);
    expect(p.updates).toEqual([{ slot: 0, qty: 250 }]);
    expect(p.inserts).toEqual([{ slot: 1, itemId: 'log_oak', qty: 3 }]);
    const full = Array.from({ length: 24 }, (_, i) => ({ slot: i, itemId: 'staff_oak', qty: 1 }));
    expect(placeItems(full, [{ itemId: 'log_oak', qty: 2 }], () => 250).rejected).toEqual([{ itemId: 'log_oak', qty: 2 }]);
  });

  it('the client bag honours the same stack cap', () => {
    let slots = addToSlots([], { item_id: 'log_oak', quantity: 249 })!;
    slots = addToSlots(slots, { item_id: 'log_oak', quantity: 3 })!;
    expect(slots.map((s) => s.quantity)).toEqual([250, 2]);
  });

  it('server/death-muffin/backend/gathering/gathering-rules.cjs is generated from the current rules', async () => {
    const { bundleGatheringRules, GATHER_OUT } = await import('../../../tools/build-server-rules.mjs');
    const lf = (s: string) => s.replace(/\r\n/g, '\n');
    expect(lf(readFileSync(GATHER_OUT, 'utf8')), 'run `npm run build:server-rules`').toBe(lf(await bundleGatheringRules()));
  });
});
