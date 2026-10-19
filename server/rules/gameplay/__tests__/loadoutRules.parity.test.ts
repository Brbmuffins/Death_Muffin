import { describe, it } from 'vitest';
import { RUNE_IDS, RUNE_RITES } from '../../content/runes';
import { CAPES } from '../../content/cosmetics';
import { ALL_SKILLS } from '../gatheringRules';
import { capeProgress, capeUnlocked, totalLevel, unlockedCapes } from '../cosmeticRules';
import { applyLoadout, cleanName, normalizePreset, type ItemInfo, type Row } from '../loadoutRules';
import { runeFits } from '../runeRules';
import { checkParity, recorder } from './parity';

/**
 * Loadout presets (client/net/offline/dm_offline_loadout.gd) and cosmetic unlocks (dm_offline_cosmetics.gd): the offline backend's ports of
 * the rules the server enforces. Replayed by rules_combat (loadout_parity.json) and rules_gathering (cosmetics_parity.json).
 * Regenerate: UPDATE_LOADOUT_PARITY=1 / UPDATE_COSMETICS_PARITY=1 npx vitest run server/rules/gameplay/__tests__/loadoutRules.parity.test.ts
 */
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

describe('loadout and cosmetics parity', () => {
  it('cosmetics_parity.json is current', () => {
    const r = recorder();
    const rnd = rng(31);
    const sets = [{}, { mining: 99 }, Object.fromEntries(ALL_SKILLS.map((s) => [s, 99])), Object.fromEntries(ALL_SKILLS.map((s) => [s, 14])), Object.fromEntries(ALL_SKILLS.map((s) => [s, 43])),
      ...Array.from({ length: 12 }, () => Object.fromEntries(ALL_SKILLS.map((s) => [s, Math.floor(rnd() * 130) - 5]))), { woodcutting: 99, alchemy: 98 }];
    for (const lv of sets) {
      r.add('totalLevel', [lv], () => totalLevel(lv));
      r.add('unlockedCapes', [lv], () => unlockedCapes(lv));
      for (const c of CAPES) {
        r.add('capeProgress', [c.id, lv], () => capeProgress(c, lv));
        r.add('capeUnlocked', [c.id, lv], () => capeUnlocked(c.id, lv));
      }
      r.add('capeUnlocked', ['cape_nope', lv], () => capeUnlocked('cape_nope', lv));
    }
    checkParity('rules_gathering', 'cosmetics', 'COSMETICS', r.cases);
  });

  it('loadout_parity.json is current', () => {
    const r = recorder();
    const rnd = rng(606);
    const int = (n: number) => Math.floor(rnd() * n);
    const pick = <T,>(l: readonly T[]): T => l[int(l.length)];
    for (const n of ['  Hello   World ', 'a<b>c', 'x'.repeat(40), 'tab\there\u0007bell', '   ', '', 'ok ', 'twenty four chars long!!x ', 5, null, undefined, 'Ünï cødé']) r.add('cleanName', [n ?? null], () => cleanName(n));
    const keys = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany'];
    const goodRunes = Object.fromEntries(RUNE_RITES.map((rite) => [rite, RUNE_IDS.find((id) => runeFits(id, rite))]));
    const gear = (n: number) => ({ itemId: pick(['sword_iron', 'bone_staff', 'buckler_1']), instanceId: n });
    const presets: unknown[] = [
      null, 5, 'x', [], {}, { name: '' }, { name: 'A' }, { name: 'A', rites: {} }, { name: 'A', rites: { primary: 'x', keys: ['a', 'b'] } },
      { name: 'A', rites: { primary: 'x', keys: ['a', 'a', 'b', 'c', 'd'] } }, { name: 'A', rites: { primary: 'Bad Id', keys } },
      { name: 'Good', rites: { primary: 'bone_needle', keys }, runes: goodRunes, weapon: { itemId: 'sword_iron', instanceId: 7 }, offhand: null },
      { name: 'Good', rites: { primary: 'bone_needle', keys } }, { name: 'Good', rites: { primary: 'bone_needle', keys }, runes: null },
      { name: 'Good', rites: { primary: 'bone_needle', keys }, runes: [] }, { name: 'Good', rites: { primary: 'bone_needle', keys }, runes: { nope: RUNE_IDS[0] } },
      { name: 'Good', rites: { primary: 'bone_needle', keys }, runes: { bone_needle: 'sword' } }, { name: 'Good', rites: { primary: 'bone_needle', keys }, runes: { exhume: null } },
      { name: 'Good', rites: { primary: 'bone_needle', keys }, weapon: 'x' }, { name: 'Good', rites: { primary: 'bone_needle', keys }, weapon: { itemId: 'Bad' } },
      { name: 'Good', rites: { primary: 'bone_needle', keys }, weapon: { itemId: 'ok_id', instanceId: 0 } }, { name: 'Good', rites: { primary: 'bone_needle', keys }, weapon: { itemId: 'ok_id', instanceId: 1.5 } },
      { name: 'Good', rites: { primary: 'bone_needle', keys }, offhand: { itemId: 'ok_id', instanceId: 12 } }, { name: ' Spaced   out ', rites: { primary: 'p', keys: ['a', 'b', 'c', 'd', 'e'] }, weapon: undefined },
    ];
    for (const p of presets) r.add('normalizePreset', [p], () => normalizePreset(p));

    const TABLE: Record<string, ItemInfo> = {
      sword_iron: { maxStack: 1, equipSlot: 'main_hand', twoHanded: false }, great_axe: { maxStack: 1, equipSlot: 'main_hand', twoHanded: true },
      bone_staff: { maxStack: 1, equipSlot: 'main_hand', twoHanded: true }, buckler_1: { maxStack: 1, equipSlot: 'off_hand', twoHanded: false },
      helm: { maxStack: 1, equipSlot: 'head', twoHanded: false }, ore: { maxStack: 250, equipSlot: null, twoHanded: false },
    };
    const info = (id: string): ItemInfo => TABLE[id] ?? { maxStack: 1, equipSlot: null, twoHanded: false };
    const gearIds = ['sword_iron', 'great_axe', 'bone_staff', 'buckler_1', 'helm', 'ore'];
    for (let i = 0; i < 36; i++) {
      const rows: Row[] = [];
      const fill = [0.1, 0.5, 0.9, 1][i % 4];
      for (let s = 0; s < 48; s++) if (rnd() < fill) rows.push({ slot_index: s, item_id: pick(gearIds), quantity: 1, equipped: 0, instance_id: rnd() < 0.5 ? 1 + int(4) : null, id: 1000 + s });
      if (rnd() < 0.7) rows.push({ slot_index: 105, item_id: pick(['sword_iron', 'great_axe', 'bone_staff']), quantity: 1, equipped: 1, equipped_slot: 'main_hand', instance_id: rnd() < 0.5 ? 1 + int(4) : null, id: 2001 });
      if (rnd() < 0.5) rows.push({ slot_index: 106, item_id: 'buckler_1', quantity: 1, equipped: 1, equipped_slot: 'off_hand', instance_id: rnd() < 0.5 ? 1 + int(4) : null, id: 2002 });
      const learned = RUNE_IDS.filter(() => rnd() < 0.6);
      RUNE_RITES.forEach((rite, k) => {
        const id = RUNE_IDS.find((x) => runeFits(x, rite));
        if (id && rnd() < 0.5) rows.push({ slot_index: 130 + k, item_id: id, quantity: 1, equipped: 1, equipped_slot: `rune_${rite}`, instance_id: null, id: 3000 + k });
      });
      rows.sort((a, b) => a.slot_index - b.slot_index);
      const mk = (): { itemId: string; instanceId: number | null } | null => (rnd() < 0.25 ? null : { itemId: pick(gearIds), instanceId: rnd() < 0.5 ? 1 + int(4) : null });
      const runes: Record<string, string> = {};
      for (const rite of RUNE_RITES) {
        const roll = rnd();
        if (roll < 0.5) runes[rite] = RUNE_IDS.find((x) => runeFits(x, rite))!;
        else if (roll < 0.6) runes[rite] = pick(RUNE_IDS);
      }
      const preset = { weapon: mk(), offhand: mk(), runes };
      r.add('applyLoadout', [rows, TABLE, preset, learned], () => applyLoadout(rows, info, preset as never, new Set(learned)));
    }
    void gearIds;
    checkParity('rules_combat', 'loadout', 'LOADOUT', r.cases);
  });
});
