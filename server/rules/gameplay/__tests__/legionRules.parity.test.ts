import { describe, it } from 'vitest';
import { RUNE_IDS, RUNE_RITES } from '../../content/runes';
import { AFFIXES, affixAcceptRange } from '../affixRules';
import { KIT_ARMOR_TYPES, KIT_WEAPON_TYPES, isKitSlot, kitIdForType, kitSlotId, legionBonus, pieceBonus, reinforceBonus, statPoints, type KitPiece } from '../legionRules';
import { RUNE_BASE, isRuneSlot, ownedRunes, runeEquippedSlot, runeFits, runeSlotIndex, runeSlotRite, socketsOf, socketsSignature } from '../runeRules';
import { checkParity, recorder } from './parity';

/**
 * The Legion kit bonus (godot/rules/combat/dm_legion.gd) and the rune socket rows (godot/rules/combat/dm_runes.gd).
 * Replayed by the Godot suite rules-combat (legion_parity.json, runes_parity.json).
 * Regenerate: UPDATE_LEGION_PARITY=1 / UPDATE_RUNES_PARITY=1 npx vitest run server/rules/gameplay/__tests__/legionRules.parity.test.ts
 */
describe('legion and rune parity', () => {
  it('legion_parity.json is current', () => {
    const r = recorder();
    const affixAt = (i: number, L: number, hi: boolean) => ({ id: AFFIXES[i % AFFIXES.length].id, v: affixAcceptRange(AFFIXES[i % AFFIXES.length].id, L)![hi ? 1 : 0] });
    const types = ['weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_legs', 'armor_feet', 'armor_hands', 'ring', 'trinket', 'rune', '', null, undefined];
    for (const t of types) r.add('kitIdForType', [t ?? null], () => kitIdForType(t));
    for (const s of [-1, 0, 119, 120, 121, 122, 123, 130, 120.5]) r.add('kitSlotId', [s], () => kitSlotId(s));
    void isKitSlot; void KIT_ARMOR_TYPES; void KIT_WEAPON_TYPES;

    const pieces: KitPiece[] = [];
    for (const itemType of ['weapon', 'offhand', 'armor_head', 'armor_chest', 'armor_hands', 'ring']) {
      for (const statBonus of [null, {}, { stat_str: 4 }, { stat_str: 3, stat_agi: 5, stat_int: 2, stat_vit: 1 }, { stat_int: 36 }, { stat_vit: 60, stat_str: 60 }, { stat_str: -5, stat_agi: 7 }]) {
        pieces.push({ itemType, statBonus });
      }
      for (let i = 0; i < AFFIXES.length; i++) {
        pieces.push({ itemType, statBonus: { stat_str: 6, stat_vit: 4 }, affixes: [affixAt(i, 40, true)] });
        pieces.push({ itemType, affixes: [affixAt(i, 99, false), affixAt(i + 1, 12, true), affixAt(i + 5, 70, true)] });
      }
    }
    for (const p of pieces) {
      r.add('statPoints', [p], () => statPoints(p));
      for (const kit of ['weapon', 'armor'] as const) r.add('pieceBonus', [kit, p], () => pieceBonus(kit, p));
    }
    r.add('pieceBonus', ['weapon', null], () => pieceBonus('weapon', null));
    for (const t of [-3, 0, 1, 2, 3.7, 4, 5, 6, 7, 8, 12, 99, NaN]) r.add('reinforceBonus', [Number.isNaN(t) ? null : t], () => reinforceBonus(t));
    const w = pieces.filter((p) => p.itemType === 'weapon' && p.affixes);
    const a = pieces.filter((p) => p.itemType === 'armor_chest' && p.affixes);
    for (let i = 0; i < Math.min(w.length, a.length); i++) {
      const tier = [0, 1, 3, 5, 8][i % 5];
      r.add('legionBonus', [{ weapon: w[i], armor: a[i] }, tier], () => legionBonus({ weapon: w[i], armor: a[i] }, tier));
    }
    r.add('legionBonus', [{ weapon: null, armor: null }, 0], () => legionBonus({ weapon: null, armor: null }, 0));
    r.add('legionBonus', [{ weapon: w[0], armor: null }, 2], () => legionBonus({ weapon: w[0], armor: null }, 2));
    r.add('legionBonus', [{ weapon: a[0], armor: w[0] }, 2], () => legionBonus({ weapon: a[0], armor: w[0] }, 2));
    checkParity('rules-combat', 'legion', 'LEGION', r.cases);
  });

  it('runes_parity.json is current', () => {
    const r = recorder();
    for (const s of [-1, 0, 129, 130, 131, 130 + RUNE_RITES.length - 1, 130 + RUNE_RITES.length, 130.5]) {
      r.add('isRuneSlot', [s], () => isRuneSlot(s));
      r.add('runeSlotRite', [s], () => runeSlotRite(s));
    }
    for (const rite of RUNE_RITES) {
      r.add('runeSlotIndex', [rite], () => runeSlotIndex(rite));
      r.add('runeEquippedSlot', [rite], () => runeEquippedSlot(rite));
      for (const id of [...RUNE_IDS, 'rune_none', 'sword']) r.add('runeFits', [id, rite], () => runeFits(id, rite));
    }
    r.add('runeFits', [RUNE_IDS[0], 'nope'], () => runeFits(RUNE_IDS[0], 'nope'));
    const rows = [
      ...RUNE_RITES.map((rite, i) => ({ slot_index: RUNE_BASE + i, item_id: RUNE_IDS.find((id) => runeFits(id, rite)) ?? 'x', quantity: 1 })),
      { slot_index: RUNE_BASE, item_id: 'sword', quantity: 1 }, { slot_index: RUNE_BASE + 1, item_id: RUNE_IDS[0], quantity: 0 }, { slot_index: 3, item_id: RUNE_IDS[0], quantity: 4 },
      { slot_index: 4, item_id: RUNE_IDS[0], quantity: 2 }, { slot_index: 5, item_id: RUNE_IDS[1], quantity: 3, equipped: 1 }, { slot_index: 99, item_id: RUNE_IDS[1], quantity: 1 },
      { slot_index: 100, item_id: RUNE_IDS[1], quantity: 9 }, { slot_index: 6, item_id: 'sword', quantity: 1 },
    ];
    for (const n of [0, 1, 3, rows.length]) {
      const sub = rows.slice(0, n);
      r.add('socketsOf', [sub], () => socketsOf(sub));
      r.add('socketsSignature', [sub], () => socketsSignature(socketsOf(sub)));
    }
    r.add('socketsOf', [rows], () => socketsOf(rows));
    r.add('ownedRunes', [rows], () => ownedRunes(rows));
    r.add('ownedRunes', [[]], () => ownedRunes([]));
    checkParity('rules-combat', 'runes', 'RUNES', r.cases);
  });
});
