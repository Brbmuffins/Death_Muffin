import { describe, it } from 'vitest';
import {
  AFFIXES, AFFIX_GEAR_TYPES, DROP_SOURCES, addInstanceTotals, affixAcceptRange, affixEffect, affixIsNecro, affixKind, affixQuality, affixRange, affixText, affixWord,
  affixedName, clampDropLevel, effectiveRarity, emptyAffixTotals, instancePower, instanceProblem, instanceSellValue, itemLevelFor, rollAffixCount, rollInstance,
  type AffixRoll, type DropSource, type ItemInstanceData,
} from '../affixRules';
import { dropStream } from '../lootRules';
import { checkParity, recorder } from './parity';

/**
 * The affix rules the client shows and the server validates: client/rules/loot/affix_rules.gd. Replayed by the Godot suite rules_loot
 * (affix_parity.json). Regenerate: UPDATE_AFFIX_PARITY=1 npx vitest run server/rules/gameplay/__tests__/affixRules.parity.test.ts
 */
describe('affix rules parity', () => {
  it('affix_parity.json is current', () => {
    const r = recorder();
    const ilvls = [-5, 0, 1, 2, 7, 15, 33, 50, 74, 98, 99, 100, 250];
    for (const a of AFFIXES) {
      for (const L of ilvls) {
        r.add('affixRange', [a.id, L], () => affixRange(a.id, L));
        r.add('affixAcceptRange', [a.id, L], () => affixAcceptRange(a.id, L));
      }
      for (const v of [0, 1, 2, 5, 9, 13, 24, 60, 120]) {
        const roll: AffixRoll = { id: a.id, v };
        r.add('affixEffect', [roll], () => affixEffect(roll));
        r.add('affixText', [roll], () => affixText(roll));
        for (const L of [1, 20, 60, 99]) r.add('affixQuality', [roll, L], () => affixQuality(roll, L));
      }
      r.add('affixMeta', [a.id], () => ({ necro: affixIsNecro({ id: a.id, v: 1 }), kind: affixKind({ id: a.id, v: 1 }), word: affixWord({ id: a.id, v: 1 }) }));
    }
    r.add('affixMeta', ['no_such_affix'], () => ({ necro: affixIsNecro({ id: 'no_such_affix', v: 1 }), kind: affixKind({ id: 'no_such_affix', v: 1 }), word: affixWord({ id: 'no_such_affix', v: 1 }) }));
    r.add('affixRange', ['no_such_affix', 10], () => affixRange('no_such_affix', 10));
    r.add('affixText', [{ id: 'no_such_affix', v: 3 }], () => affixText({ id: 'no_such_affix', v: 3 }));

    for (const src of DROP_SOURCES) {
      for (const lv of [-3, 0, 1, 10, 50, 95, 99, 120]) r.add('itemLevelFor', [lv, src], () => itemLevelFor(lv, src));
    }
    for (const [lv, ch] of [[1, 1], [0, 5], [20, 5], [14, 4], [15, 5], [99, 200], [200, 200], [-4, 30], [60, 0]]) r.add('clampDropLevel', [lv, ch], () => clampDropLevel(lv, ch));

    const rarities = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic'];
    for (const rar of rarities) for (const n of [-1, 0, 1, 2, 3, 4, 9]) r.add('effectiveRarity', [rar, n], () => effectiveRarity(rar, n));

    // seeded rolls: the affix count, then a whole instance, from the same stream
    let s = 1;
    const seed = (): [number, number, number, number] => [s++ * 2654435761 >>> 0, s++ * 40503 >>> 0, s++ * 69069 >>> 0, s++ * 1103515245 >>> 0];
    for (const rar of rarities) {
      for (const src of DROP_SOURCES) {
        for (let k = 0; k < 6; k++) {
          const w = seed();
          r.add('rollAffixCount', [rar, src, w], () => rollAffixCount(rar, src as DropSource, dropStream(w)));
        }
        for (let k = 0; k < 6; k++) {
          const w = seed();
          const lv = [1, 8, 30, 60, 99, 140][k];
          r.add('rollInstance', [rar, lv, src, w], () => rollInstance({ rarity: rar }, lv, src as DropSource, dropStream(w)));
        }
      }
    }

    // instances: legal, edge and forged
    const a0 = AFFIXES[0];
    const range = (id: string, L: number) => affixAcceptRange(id, L)!;
    const mk = (ilvl: number, list: [string, number][]): ItemInstanceData => ({ ilvl, affixes: list.map(([id, v]) => ({ id, v })) });
    const groupMates = AFFIXES.filter((a) => a.group === a0.group);
    const insts: unknown[] = [
      mk(10, []), mk(1, [[a0.id, range(a0.id, 1)[0]]]), mk(50, [[a0.id, range(a0.id, 50)[1]]]), mk(50, [[a0.id, range(a0.id, 50)[1] + 1]]), mk(50, [[a0.id, range(a0.id, 50)[0] - 1]]),
      mk(99, AFFIXES.slice(0, 3).map((a) => [a.id, range(a.id, 99)[0]] as [string, number])), mk(99, AFFIXES.slice(0, 4).map((a) => [a.id, range(a.id, 99)[0]] as [string, number])),
      mk(0, []), mk(100, []), { ilvl: 5.5, affixes: [] }, { ilvl: 5 }, { ilvl: 5, affixes: [{ id: 'nope', v: 1 }] }, { ilvl: 5, affixes: [{ id: a0.id, v: 1.5 }] },
      null, 'x', 7, { ilvl: '5', affixes: [] },
    ];
    if (groupMates.length > 1) insts.push(mk(60, groupMates.slice(0, 2).map((a) => [a.id, range(a.id, 60)[0]] as [string, number])));
    for (const t of [...AFFIX_GEAR_TYPES, 'rune', 'potion', 'material', '']) for (const inst of insts) r.add('instanceProblem', [inst, t], () => instanceProblem(inst, t));

    const roll6 = AFFIXES.slice(0, 6).map((a) => ({ id: a.id, v: range(a.id, 40)[1] }));
    for (const n of [0, 1, 2, 3, 4]) {
      const list = roll6.slice(0, n);
      r.add('affixedName', ['Iron Helm', list], () => affixedName('Iron Helm', list));
      r.add('affixedName', ['', list], () => affixedName('', list));
      for (const base of [0, 1, 7, 33, 100, 4999]) for (const ilvl of [1, 15, 60, 99]) {
        const inst = { ilvl, affixes: list };
        r.add('instanceSellValue', [base, inst], () => instanceSellValue(base, inst));
        r.add('instancePower', [inst], () => instancePower(inst));
      }
      r.add('addInstanceTotals', [list], () => addInstanceTotals(emptyAffixTotals(), list));
    }
    r.add('instanceSellValue', [50, null], () => instanceSellValue(50, null));
    r.add('instancePower', [null], () => instancePower(null));
    checkParity('rules_loot', 'affix', 'AFFIX', r.cases);
  });
});
