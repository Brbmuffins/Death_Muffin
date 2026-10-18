import { describe, it } from 'vitest';
import { BOSSES } from '../../content/bosses';
import { PLOTS, SEEDS } from '../../content/gardening';
import { AFFIXES, affixAcceptRange } from '../affixRules';
import { bonusFor, candidatesFor, dayKey, generateBoard, nextResetMs, orderInfo, streakOf } from '../contractRules';
import {
  BAG_SLOTS, MATERIAL_STACK, NODES, NODE_IDS, SKILLS, actionMs, addSkillXp, bestToolPerKind, beltSlotOf, beltSlotKind, blankLedger, checkBudget, isBeltSlot, placeItems, rollBatch, rollGather,
  successChance, toolItemId, toolKindOf, toolTierFor, totalXpFor, xpPerHour, xpToNextCurve, xpToNextLive, type SkillId,
} from '../gatheringRules';
import { EMPOWERABLE, canEmpower, empowerGold, empoweredLevel, reforgeCost, reforgeProblem, reforgeValue } from '../goldSinkRules';
import { PLOTS as _plots, growMs, plantBlocker, plotDef, remainingText, rollHarvest, stateOf } from '../gardeningRules';
import { assignBlocker, claimRng, estimate, hashSeed, laborActions, laborSlots, postsFor, rollLabor, totalGatherLevel } from '../laborRules';
import { dropStream } from '../lootRules';
import {
  isSalvageGear, isSalvageRune, isSalvageable, mergeGrants, salvageItemIds, salvagePreview, salvageYield, yieldsPlanks, instanceYieldBonus,
} from '../salvageRules';
import { checkParity, recorder } from './parity';

/**
 * The gathering family: gatheringRules, salvageRules, goldSinkRules, laborRules, gardeningRules and contractRules, against
 * client/rules/gathering/*.gd. Replayed by the Godot suite rules-gathering (<name>_parity.json). Seeded rolls use the loot drop stream
 * (DmDropStream) on both sides. Regenerate: UPDATE_<NAME>_PARITY=1 npx vitest run server/rules/gameplay/__tests__/gatheringRules.parity.test.ts
 * with NAME one of GATHER, SALVAGE, GOLD_SINK, LABOR, GARDEN, CONTRACTS.
 */
type Words = [number, number, number, number];
let counter = 1;
const seed = (): Words => [(counter++ * 2654435761) >>> 0, (counter++ * 40503) >>> 0, (counter++ * 69069) >>> 0, (counter++ * 1103515245) >>> 0];
const levels = [1, 2, 5, 9, 10, 15, 24, 30, 45, 60, 80, 98, 99];

describe('gathering family parity', () => {
  it('gather_parity.json is current', () => {
    counter = 1;
    const r = recorder();
    for (const l of [0, 1, 2, 19, 20, 21, 50, 98, 99]) {
      r.add('xpToNextLive', [l], () => xpToNextLive(l));
      r.add('xpToNextCurve', [l], () => xpToNextCurve(l));
    }
    for (const l of [1, 2, 10, 50, 99]) {
      r.add('totalXpFor', [l, false], () => totalXpFor(l));
      r.add('totalXpFor', [l, true], () => totalXpFor(l, xpToNextCurve));
    }
    for (const p of [{ level: 1, xp: 0 }, { level: 1, xp: 49 }, { level: 10, xp: 499 }, { level: 98, xp: 4800 }, { level: 99, xp: 5 }, { level: 0, xp: -4 }, { level: 40, xp: 1999 }]) {
      for (const g of [0, 1, 30, 499, 5000, 123456, 99999999, -5]) r.add('addSkillXp', [p, g], () => addSkillXp(p, g));
    }
    for (const id of NODE_IDS) {
      for (const lv of levels) for (const tier of [0, 1, 3, 6]) {
        r.add('successChance', [id, lv, tier], () => successChance(NODES[id], lv, tier));
        r.add('xpPerHour', [id, lv, tier], () => xpPerHour(NODES[id], lv, tier));
      }
      r.add('actionMs', [id], () => actionMs(NODES[id]));
      for (const lv of [1, NODES[id].level, 99]) {
        const words = seed();
        const tier = counter % 4;
        r.add('rollGatherRun', [id, lv, tier, words], () => {
          const rng = dropStream(words);
          return Array.from({ length: 6 }, () => rollGather(NODES[id], lv, rng, tier));
        });
      }
      for (const lv of [1, NODES[id].level, 60]) {
        const words = seed();
        const actions = [1, 7, 40][counter % 3];
        const floor = counter % 2 ? 0 : 20;
        r.add('rollBatch', [id, { level: lv, xp: 3 }, actions, 2, floor, words], () => rollBatch(NODES[id], { level: lv, xp: 3 }, actions, dropStream(words), 2, floor));
      }
      for (const afk of [false, true]) for (const ledger of [blankLedger(), { lastAt: 100000, hourStart: 90000, hourActions: 10 }, { lastAt: 1000, hourStart: 500, hourActions: 1790 }, { lastAt: 5000, hourStart: 0, hourActions: 0 }]) {
        for (const [claimed, now] of [[1, 100001], [40, 130000], [100, 9_000_000], [0, 10], [2.7, 140000]]) {
          r.add('checkBudget', [id, ledger, claimed, now, afk], () => checkBudget(NODES[id], ledger, claimed, now, afk));
        }
      }
    }
    const skills = Object.keys(SKILLS) as SkillId[];
    for (const sk of skills.slice(0, 4)) for (let t = 1; t <= 6; t++) r.add('toolItemId', [sk, t], () => toolItemId(sk, t));
    const held = [[], ['tool_hatchet_copper'], ['tool_hatchet_iron', 'tool_hatchet_moon', 'tool_pickaxe_steel'], ['tool_rod_silver', 'tool_spade_hell', 'x', ''], ['tool_hatchet_bronze']];
    for (const sk of skills) for (const h of held) r.add('toolTierFor', [sk, h], () => toolTierFor(sk, h));
    for (const h of held) r.add('bestToolPerKind', [h], () => bestToolPerKind(h));
    for (const id of ['tool_hatchet_copper', 'tool_rod_moon', 'tool_spade_nope', 'sword', 'tool_pickaxe_hell']) {
      r.add('toolKindOf', [id], () => toolKindOf(id));
      r.add('beltSlotOf', [id], () => beltSlotOf(id));
    }
    for (const s of [-1, 109, 110, 111, 113, 114, 130]) {
      r.add('isBeltSlot', [s], () => isBeltSlot(s));
      r.add('beltSlotKind', [s], () => beltSlotKind(s));
    }
    // placeItems against a fixed stack table (1 = gear)
    const stacks: Record<string, number> = { oak_log: MATERIAL_STACK, ingot_iron: MATERIAL_STACK, potion: 20, sword: 1 };
    const grantSets = [
      [{ itemId: 'oak_log', qty: 10 }], [{ itemId: 'oak_log', qty: 600 }, { itemId: 'sword', qty: 3 }], [{ itemId: 'potion', qty: 45 }, { itemId: 'ingot_iron', qty: 1 }],
      [{ itemId: 'unknown', qty: 5 }], [{ itemId: 'sword', qty: 100 }],
    ];
    const bags = [
      [], [{ slot: 0, itemId: 'oak_log', qty: 240 }, { slot: 1, itemId: 'oak_log', qty: 250 }], Array.from({ length: BAG_SLOTS }, (_, i) => ({ slot: i, itemId: 'sword', qty: 1 })),
      Array.from({ length: BAG_SLOTS - 2 }, (_, i) => ({ slot: i + 1, itemId: 'potion', qty: 20 })), [{ slot: 5, itemId: 'potion', qty: 3 }],
    ];
    for (const bag of bags) for (const g of grantSets) r.add('placeItems', [bag, g, stacks], () => placeItems(bag, g, (id) => stacks[id] ?? 1));
    checkParity('rules-gathering', 'gather', 'GATHER', r.cases);
  });

  it('salvage_parity.json is current', () => {
    counter = 500;
    const r = recorder();
    for (const t of ['weapon', 'offhand', 'armor_chest', 'ring', 'trinket', 'rune', 'potion', 'material', '']) {
      r.add('salvageTypes', [t], () => ({ gear: isSalvageGear(t), rune: isSalvageRune(t), any: isSalvageable(t) }));
    }
    r.add('salvageItemIds', [], () => salvageItemIds().sort());
    const items: Record<string, unknown>[] = [];
    for (const rarity of ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic', 'weird']) {
      for (const [id, item_type] of [['sword_iron', 'weapon'], ['bone_staff', 'weapon'], ['book_of_rot', 'offhand'], ['helm', 'armor_head'], ['rune_x', 'rune'], ['ring_a', 'ring']] as const) {
        items.push({ id, item_type, rarity });
        items.push({ id, item_type, rarity, ilvl: 40, affixes: 2 });
      }
    }
    items.push({ id: 'sword', item_type: 'weapon', rarity: 'rare', ilvl: 99, affixes: 3 }, { id: 'sword', item_type: 'weapon', rarity: 'rare', ilvl: 1, affixes: 0 });
    for (const it of items) {
      const si = it as never;
      r.add('yieldsPlanks', [it], () => yieldsPlanks(si));
      r.add('instanceYieldBonus', [it], () => instanceYieldBonus(si));
      r.add('salvagePreview', [it], () => salvagePreview(si));
      for (const lv of [1, 20, 99, 150, 0]) {
        const words = seed();
        r.add('salvageYield', [it, lv, words], () => salvageYield(si, lv, dropStream(words)));
      }
    }
    const lists = [[{ item_id: 'a', quantity: 1 }, { item_id: 'b', quantity: 2 }], [{ item_id: 'a', quantity: 4 }], []];
    r.add('mergeGrants', [lists], () => mergeGrants(lists));
    r.add('mergeGrants', [[]], () => mergeGrants([]));
    checkParity('rules-gathering', 'salvage', 'SALVAGE', r.cases);
  });

  it('gold_sink_parity.json is current', () => {
    counter = 900;
    const r = recorder();
    for (const rar of ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic', 'odd']) {
      for (const aff of [0, 1, 2, 3]) for (const ilvl of [1, 12.7, 60, 99]) for (const rr of [0, 1, 5, 20, 30, -2, 2.5]) r.add('reforgeCost', [ilvl, rar, aff, rr], () => reforgeCost(ilvl, rar, aff, rr));
    }
    r.add('reforgeCost', [0, 'relic', 3, 0], () => reforgeCost(0, 'relic', 3, 0));
    r.add('reforgeCost', [99999, 'relic', 3, 20], () => reforgeCost(99999, 'relic', 3, 20));
    for (let i = 0; i < AFFIXES.length; i++) {
      const a = AFFIXES[i];
      for (const ilvl of [1, 30, 99]) {
        const [lo, hi] = affixAcceptRange(a.id, ilvl)!;
        for (const v of [lo, Math.floor((lo + hi) / 2), hi, hi + 1]) {
          const inst = { ilvl, affixes: [{ id: a.id, v }] };
          for (const index of [0, 1, -1, 0.5]) r.add('reforgeProblem', [inst, index], () => reforgeProblem(inst, index));
        }
        for (let k = 0; k < 2; k++) {
          const words = seed();
          r.add('reforgeValue', [a.id, ilvl, words], () => reforgeValue(a.id, ilvl, dropStream(words)));
        }
      }
    }
    r.add('reforgeProblem', [{ ilvl: 10, affixes: [{ id: 'nope', v: 1 }] }, 0], () => reforgeProblem({ ilvl: 10, affixes: [{ id: 'nope', v: 1 }] }, 0));
    for (const b of [...EMPOWERABLE, 'prelate', 'nope']) {
      r.add('canEmpower', [b], () => canEmpower(b));
    }
    for (const b of EMPOWERABLE) r.add('empowerGold', [BOSSES[b].shards], () => empowerGold(b));
    for (const l of [1, 2, 10, 33, 99, 250]) r.add('empoweredLevel', [l], () => empoweredLevel(l));
    checkParity('rules-gathering', 'gold_sink', 'GOLD_SINK', r.cases);
  });

  it('labor_parity.json is current', () => {
    counter = 1300;
    const r = recorder();
    const lvSets: Record<string, number>[] = [
      {}, { woodcutting: 1, mining: 1, fishing: 1, gravedigging: 1 }, { woodcutting: 20, mining: 5, fishing: 30, gravedigging: 2, gardening: 50 },
      { woodcutting: 99, mining: 99, fishing: 99, gravedigging: 99 }, { woodcutting: 49, mining: 1, fishing: 1, gravedigging: 1 }, { woodcutting: 10, mining: 15, fishing: 25, gravedigging: 35, alchemy: 50 },
    ];
    for (const t of [-5, 0, 4, 49, 50, 99, 100, 149, 150, 400]) r.add('laborSlots', [t], () => laborSlots(t));
    for (const lv of lvSets) {
      r.add('totalGatherLevel', [lv], () => totalGatherLevel(lv));
      r.add('postsFor', [lv], () => postsFor(lv).map((n) => n.id));
      for (const id of [...NODE_IDS, 'nope']) r.add('assignBlocker', [id, lv], () => assignBlocker(id, lv));
    }
    for (const id of NODE_IDS) {
      for (const ms of [0, 1000, 600_000, 3_600_000, 8 * 3_600_000, 99 * 3_600_000, -5]) {
        r.add('laborActions', [id, ms], () => laborActions(NODES[id], ms));
        for (const lv of [1, 30, 99]) r.add('estimate', [id, lv, ms], () => estimate(NODES[id], lv, ms));
      }
      for (const lv of [1, NODES[id].level, 90]) {
        const parts = [id, lv, 12345 + counter++];
        r.add('rollLabor', [id, { level: lv, xp: 17 }, 5_400_000, hashSeed(...parts), parts], () => rollLabor(NODES[id], { level: lv, xp: 17 }, 5_400_000, claimRng(hashSeed(...parts))));
      }
    }
    for (const parts of [['a'], ['mining', 3, 99], ['x', 'y', 'z', 1700000000000], [0], ['']]) r.add('hashSeed', [parts], () => hashSeed(...parts));
    checkParity('rules-gathering', 'labor', 'LABOR', r.cases);
  });

  it('garden_parity.json is current', () => {
    counter = 1700;
    const r = recorder();
    const now = 1_700_000_000_000;
    const rows = [
      null,
      { plot: 'h0', seedId: null, plantedAt: 0, readyAt: 0, composted: false },
      { plot: 'h0', seedId: SEEDS[0].id, plantedAt: now - 1000, readyAt: now + 5000, composted: false },
      { plot: 'h0', seedId: SEEDS[0].id, plantedAt: now - 9000, readyAt: now - 1, composted: true },
      { plot: 'h0', seedId: SEEDS[0].id, plantedAt: now - 9000, readyAt: now, composted: true },
    ];
    for (const row of rows) r.add('stateOf', [row, now], () => stateOf(row, now));
    for (const s of SEEDS) {
      for (const c of [false, true]) r.add('growMs', [s.id, c], () => growMs(s, c));
      const words = seed();
      r.add('rollHarvest', [s.id, words], () => rollHarvest(s, dropStream(words)));
      for (const p of [...PLOTS.map((x) => x.id), 'nope']) for (const lv of [1, s.level - 1, s.level, 99]) for (let i = 0; i < rows.length; i += 2) {
        r.add('plantBlocker', [p, s.id, lv, rows[i], now], () => plantBlocker(plotDef(p), s.id, lv, rows[i], now));
      }
    }
    r.add('plantBlocker', [PLOTS[0].id, 'nope', 50, null, now], () => plantBlocker(plotDef(PLOTS[0].id), 'nope', 50, null, now));
    for (const ms of [0, 1, 999, 1000, 1001, 59_000, 60_000, 61_000, 3_599_000, 3_600_000, 4_800_000, 90_000_000, -50]) r.add('remainingText', [ms], () => remainingText(ms));
    void _plots;
    checkParity('rules-gathering', 'garden', 'GARDEN', r.cases);
  });

  it('contracts_parity.json is current', () => {
    const r = recorder();
    const skills = Object.keys(SKILLS) as SkillId[];
    const lvSets: Partial<Record<SkillId, number>>[] = [{}, { mining: 3 }, ...[5, 12, 25, 40, 60, 80, 99].map((n) => Object.fromEntries(skills.map((s, i) => [s, Math.min(99, n + i * 3)]))), { mining: 99 }, { alchemy: 99, gardening: 99 }];
    for (const lv of lvSets) {
      r.add('candidatesFor', [lv], () => candidatesFor(lv));
      for (const [cid, day] of [[1, '2026-10-15'], [7, '2026-10-16'], [4242, '2026-01-01'], [90210, '2027-02-28'], [3, '2026-12-31']] as const) {
        r.add('generateBoard', [cid, day, lv], () => generateBoard(cid, day, lv));
      }
    }
    for (const [cid, day] of [[11, '2026-10-15'], [12, '2026-10-15'], [13, '2026-10-17'], [14, '2026-10-18']] as const) {
      const board = generateBoard(cid, day, lvSets[5]);
      r.add('bonusFor', [board], () => bonusFor(board));
    }
    for (const id of ['ingot_tin', 'gem_grave_garnet', 'covenant_seal', 'oak_log', 'plank_oak', 'reagent_grave_dust', 'nope', 'bone_meal']) r.add('orderInfo', [id], () => orderInfo(id));
    for (const ms of [0, 1, 86_399_999, 86_400_000, 1_700_000_000_000, 1_760_000_000_000]) {
      r.add('dayKey', [ms], () => dayKey(ms));
      r.add('nextResetMs', [ms], () => nextResetMs(ms));
    }
    const streaks: [string[], string][] = [[[], '2026-10-15'], [['2026-10-15'], '2026-10-15'], [['2026-10-14', '2026-10-13'], '2026-10-15'], [['2026-10-12', '2026-10-13', '2026-10-14', '2026-10-15'], '2026-10-15'], [['2026-10-10'], '2026-10-15'], [['2026-02-28', '2026-03-01'], '2026-03-01']];
    for (const [d, t] of streaks) r.add('streakOf', [d, t], () => streakOf(d, t));
    checkParity('rules-gathering', 'contracts', 'CONTRACTS', r.cases);
  });
});
