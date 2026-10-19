import { describe, it } from 'vitest';
import { BAG_SLOTS } from '../gatheringRules';
import {
  VAULT_SLOTS, addGrants, depositMany, depositStack, moveToSlot, sortBag, sortVault, useItems, withdrawStack, type VaultInfo, type VaultItemInfo, type VaultRow,
} from '../vaultRules';
import { checkParity, recorder } from './parity';

/**
 * Vault, Reliquary sort and item use against client/rules/inventory/vault_rules.gd. Replayed by the Godot suite rules_gathering
 * (vault_parity.json). Every case carries the item table it ran against. Regenerate:
 * UPDATE_VAULT_PARITY=1 npx vitest run server/rules/gameplay/__tests__/vaultRules.parity.test.ts
 */
const TABLE: Record<string, VaultItemInfo> = {
  ore: { maxStack: 250, itemType: 'material', rarity: 'common', name: 'Ore' },
  plank: { maxStack: 250, itemType: 'material', rarity: 'uncommon', name: 'Plank' },
  flask: { maxStack: 20, itemType: 'consumable', rarity: 'common', name: 'Flask' },
  tonic: { maxStack: 20, itemType: 'consumable', rarity: 'rare', name: 'Tonic' },
  staff: { maxStack: 1, itemType: 'weapon', rarity: 'common', name: 'Staff' },
  blade: { maxStack: 1, itemType: 'weapon', rarity: 'epic', name: 'Blade' },
  buckler: { maxStack: 1, itemType: 'offhand', rarity: 'uncommon', name: 'Buckler' },
  helm: { maxStack: 1, itemType: 'armor_head', rarity: 'rare', name: 'Helm' },
  ring: { maxStack: 1, itemType: 'ring', rarity: 'rare', name: 'Ring' },
  rune_a: { maxStack: 250, itemType: 'rune', rarity: 'epic', name: 'Rune A' },
  relic_x: { maxStack: 1, itemType: 'trinket', rarity: 'relic', name: 'Relic' },
  gem: { maxStack: 50, itemType: 'gem', rarity: 'legendary' },
};
const info: VaultInfo = (id) => TABLE[id] ?? { maxStack: 1, itemType: 'material', rarity: 'common' };
const IDS = Object.keys(TABLE);

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

describe('vault parity', () => {
  it('vault_parity.json is current', () => {
    const r = recorder();
    const rnd = rng(1015);
    const int = (n: number) => Math.floor(rnd() * n);
    const pick = <T,>(l: readonly T[]): T => l[int(l.length)];
    let inst = 1;
    const rows = (size: number, fill: number, withFixed: boolean): VaultRow[] => {
      const slots = Array.from({ length: size }, (_, i) => i).filter(() => rnd() < fill);
      return slots.map((slot) => {
        const itemId = pick(IDS);
        const m = info(itemId);
        const row: VaultRow = { slot, itemId, qty: m.maxStack > 1 ? 1 + int(m.maxStack) : 1 };
        if (m.maxStack === 1 && rnd() < 0.6) { row.inst = inst++; row.power = int(4) * 1000 + int(99); row.ilvl = 1 + int(99); }
        if (withFixed && m.maxStack === 1 && rnd() < 0.15) row.fixed = true;
        return row;
      });
    };
    for (let i = 0; i < 42; i++) {
      const bag = rows(BAG_SLOTS, [0.1, 0.4, 0.8, 0.97][i % 4], true);
      const vault = rows(VAULT_SLOTS, [0.05, 0.3, 0.7, 0.98][(i >> 1) % 4], false);
      const slotIn = (list: VaultRow[]) => (list.length && rnd() < 0.85 ? pick(list).slot : int(130) - 3);
      const qty = pick([undefined, undefined, 1, 5, 30, 400, 0, -2]);
      switch (i % 7) {
        case 0: { const s = slotIn(bag); r.add('depositStack', [bag, vault, s, qty ?? null, TABLE], () => depositStack(bag, vault, s, qty, info)); break; }
        case 1: { const s = slotIn(vault); r.add('withdrawStack', [bag, vault, s, qty ?? null, TABLE], () => withdrawStack(bag, vault, s, qty, info)); break; }
        case 2: {
          const side = pick(['bag', 'vault'] as const), to = pick(['bag', 'vault'] as const);
          const from = slotIn(side === 'bag' ? bag : vault);
          const ts = rnd() < 0.5 ? slotIn(to === 'bag' ? bag : vault) : int(to === 'bag' ? BAG_SLOTS + 2 : VAULT_SLOTS + 2);
          r.add('moveToSlot', [bag, vault, side, from, to, ts, qty ?? null, TABLE], () => moveToSlot(bag, vault, side, from, to, ts, qty, info));
          break;
        }
        case 3: {
          const kind = pick(['materials', 'all'] as const);
          const except = bag.filter(() => rnd() < 0.2).map((x) => x.slot);
          r.add('depositMany', [bag, vault, kind, except, TABLE], () => depositMany(bag, vault, kind, except, info));
          break;
        }
        case 4: r.add('sortVault', [vault, TABLE], () => sortVault(vault, info)); break;
        case 5: {
          const locked = bag.filter(() => rnd() < 0.2).map((x) => x.slot);
          r.add('sortBag', [bag, locked, TABLE], () => sortBag(bag, info, locked));
          break;
        }
        default: {
          const grants = Array.from({ length: 1 + int(3) }, () => ({ itemId: pick(IDS), qty: 1 + int(pick([3, 40, 300])) }));
          r.add('addGrants', [bag, grants, TABLE], () => addGrants(bag, grants, info));
          const uses = Array.from({ length: 1 + int(4) }, () => ({ itemId: pick(['flask', 'tonic', 'ore', 'staff', 'nope']), slot: rnd() < 0.5 ? pick(bag.length ? bag : [{ slot: 0 }]).slot : undefined, qty: int(40) - 3 }));
          r.add('useItems', [bag, uses, TABLE], () => useItems(bag, uses, info));
        }
      }
    }
    checkParity('rules_gathering', 'vault', 'VAULT', r.cases);
  });
});
