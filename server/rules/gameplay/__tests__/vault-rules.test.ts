import { describe, expect, it } from 'vitest';
import { BAG_SLOTS } from '../gatheringRules';
import { VAULT_SLOTS, addGrants, depositMany, depositStack, moveToSlot, sortBag, sortVault, useItems, withdrawStack, type VaultInfo, type VaultRow } from '../vaultRules';

const TABLE: Record<string, { maxStack: number; itemType: string; rarity: string }> = {
  ore: { maxStack: 250, itemType: 'material', rarity: 'common' },
  flask: { maxStack: 20, itemType: 'consumable', rarity: 'common' },
  staff: { maxStack: 1, itemType: 'weapon', rarity: 'common' },
  ring: { maxStack: 1, itemType: 'ring', rarity: 'rare' },
};
const info: VaultInfo = (id) => TABLE[id] ?? { maxStack: 1, itemType: 'material', rarity: 'common' };
const row = (slot: number, itemId: string, qty = 1, fixed = false): VaultRow => ({ slot, itemId, qty, ...(fixed ? { fixed } : {}) });

describe('vault rules', () => {
  it('sizes: a 48-slot bag and a 120-slot vault', () => {
    expect(BAG_SLOTS).toBe(48);
    expect(VAULT_SLOTS).toBe(120);
  });

  it('deposits stack first, never mutate their inputs, and move partial quantities', () => {
    const bag = [row(2, 'ore', 100)];
    const vault = [row(0, 'ore', 200)];
    const r = depositStack(bag, vault, 2, undefined, info);
    expect(r.ok && r.vault).toEqual([row(0, 'ore', 250), row(1, 'ore', 50)]);
    expect(bag).toEqual([row(2, 'ore', 100)]);
    const part = depositStack(bag, vault, 2, 30, info);
    expect(part.ok && part.bag).toEqual([row(2, 'ore', 70)]);
    expect(part.ok && part.moved).toBe(30);
  });

  it('refuses what does not fit, equipped rows and empty slots', () => {
    const full = Array.from({ length: VAULT_SLOTS }, (_, i) => row(i, 'staff'));
    expect(depositStack([row(0, 'ring')], full, 0, undefined, info)).toMatchObject({ ok: false });
    expect(depositStack([row(0, 'ring', 1, true)], [], 0, undefined, info)).toMatchObject({ ok: false, error: expect.stringMatching(/Equipped/) });
    expect(depositStack([], [], 5, undefined, info)).toMatchObject({ ok: false });
    const fullBag = Array.from({ length: BAG_SLOTS }, (_, i) => row(i, 'staff'));
    expect(withdrawStack(fullBag, [row(0, 'ring')], 0, undefined, info)).toMatchObject({ ok: false, error: expect.stringMatching(/Reliquary/) });
  });

  it('withdraw lands in the first free bag slot', () => {
    const r = withdrawStack([row(0, 'staff'), row(2, 'ore', 5)], [row(7, 'ore', 4)], 7, undefined, info);
    expect(r.ok && r.bag).toEqual([row(0, 'staff'), row(2, 'ore', 9)]);
    expect(r.ok && r.vault).toEqual([]);
  });

  it('bulk deposit honours kind and exceptSlots and is all or nothing', () => {
    const bag = [row(0, 'staff'), row(1, 'ore', 5), row(2, 'flask', 3), row(3, 'ore', 4), row(4, 'ring', 1, true)];
    const mats = depositMany(bag, [], 'materials', [3], info);
    expect(mats.ok && mats.bag.map((r) => r.slot)).toEqual([0, 2, 3, 4]);   // potions stay in the bag (2026-10-14: Deposit materials moves materials and runes only)
    const all = depositMany(bag, [], 'all', [], info);
    expect(all.ok && all.bag).toEqual([row(4, 'ring', 1, true)]);
    const nearlyFull = Array.from({ length: VAULT_SLOTS - 1 }, (_, i) => row(i, 'ring'));
    expect(depositMany([row(0, 'staff'), row(1, 'staff')], nearlyFull, 'all', [], info)).toMatchObject({ ok: false });
    expect(depositMany([row(0, 'staff')], [], 'materials', [], info)).toMatchObject({ ok: false });
  });

  it('sort merges stacks and orders by type, then best rarity, then id', () => {
    const sorted = sortVault([row(9, 'ore', 200), row(50, 'ore', 100), row(3, 'ring'), row(80, 'staff'), row(81, 'flask', 2)], info);
    expect(sorted.map((r) => [r.slot, r.itemId, r.qty])).toEqual([[0, 'staff', 1], [1, 'ring', 1], [2, 'flask', 2], [3, 'ore', 250], [4, 'ore', 50]]);
  });

  it('addGrants stacks then fills free slots, or returns null without a change', () => {
    const bag = [row(0, 'ore', 249)];
    expect(addGrants(bag, [{ itemId: 'ore', qty: 3 }], info)).toEqual([row(0, 'ore', 250), row(1, 'ore', 2)]);
    const full = Array.from({ length: BAG_SLOTS }, (_, i) => row(i, 'staff'));
    expect(addGrants(full, [{ itemId: 'ore', qty: 1 }], info)).toBeNull();
  });

  it('moveToSlot: a chosen empty slot, part of a stack, merging, swapping in a side and across, equipped gear stays', () => {
    const bag = [row(0, 'ore', 100), row(1, 'staff'), row(2, 'ring', 1, true), row(5, 'flask', 18)];
    const vault = [row(0, 'ore', 240), row(3, 'flask', 5), row(7, 'staff')];
    // within the bag: to an empty slot, and inputs untouched
    const a = moveToSlot(bag, vault, 'bag', 1, 'bag', 9, undefined, info);
    expect(a.ok && a.bag.map((r) => [r.slot, r.itemId])).toEqual([[0, 'ore'], [2, 'ring'], [5, 'flask'], [9, 'staff']]);
    expect(bag[1].slot).toBe(1);
    // part of a stack to an empty slot
    const b = moveToSlot(bag, vault, 'bag', 0, 'bag', 10, 30, info);
    expect(b.ok && b.bag.filter((r) => r.itemId === 'ore')).toEqual([row(0, 'ore', 70), row(10, 'ore', 30)]);
    // merging into the same item, capped; what does not fit stays
    const c = moveToSlot(bag, vault, 'bag', 0, 'vault', 0, undefined, info);
    expect(c.ok && c.moved).toBe(10);
    expect(c.ok && c.bag.find((r) => r.slot === 0)).toEqual(row(0, 'ore', 90));
    expect(c.ok && c.vault.find((r) => r.slot === 0)).toEqual(row(0, 'ore', 250));
    // a full stack refuses
    const full = moveToSlot(bag, [row(0, 'ore', 250)], 'bag', 0, 'vault', 0, undefined, info);
    expect(full.ok).toBe(false);
    // swap within a side, and across sides (the vault staff comes into the bag's flask slot)
    const d = moveToSlot(bag, vault, 'bag', 1, 'bag', 5, undefined, info);
    expect(d.ok && d.bag.map((r) => [r.slot, r.itemId])).toEqual([[0, 'ore'], [1, 'flask'], [2, 'ring'], [5, 'staff']]);
    const e = moveToSlot(bag, vault, 'bag', 5, 'vault', 7, undefined, info);
    expect(e.ok && e.bag.find((r) => r.slot === 5)).toEqual(row(5, 'staff'));
    expect(e.ok && e.vault.find((r) => r.slot === 7)).toEqual(row(7, 'flask', 18));
    // part of a stack onto a different item refuses; equipped gear neither moves nor gets swapped
    expect(moveToSlot(bag, vault, 'bag', 0, 'bag', 1, 5, info).ok).toBe(false);
    expect(moveToSlot(bag, vault, 'bag', 2, 'bag', 20, undefined, info).ok).toBe(false);
    expect(moveToSlot(bag, vault, 'bag', 1, 'bag', 2, undefined, info).ok).toBe(false);
    // bounds
    expect(moveToSlot(bag, vault, 'bag', 1, 'bag', BAG_SLOTS, undefined, info).ok).toBe(false);
    expect(moveToSlot(bag, vault, 'bag', 1, 'vault', VAULT_SLOTS - 1, undefined, info).ok).toBe(true);
  });
});

describe('bag rules (DECISIONS B25)', () => {
  it('sort merges stacks, orders by type, rarity and item level, packs around fixed rows and reports every move', () => {
    const bag: VaultRow[] = [row(0, 'ore', 200), row(1, 'flask', 3), { slot: 2, itemId: 'staff', qty: 1, inst: 9, ilvl: 10 }, row(3, 'ring', 1, true),
      row(5, 'ore', 100), { slot: 7, itemId: 'staff', qty: 1, inst: 4, ilvl: 30 }, row(8, 'flask', 2)];
    const r = sortBag(bag, info);
    expect(r.bag).toEqual([
      { slot: 0, itemId: 'staff', qty: 1, inst: 4, ilvl: 30 }, { slot: 1, itemId: 'staff', qty: 1, inst: 9, ilvl: 10 }, row(2, 'flask', 5),
      row(3, 'ring', 1, true), row(4, 'ore', 250), row(5, 'ore', 50)]);
    expect(r.moves).toEqual({ 7: 0, 2: 1, 1: 2, 8: 2, 0: 4, 5: 5 });
    expect(bag[0]).toEqual(row(0, 'ore', 200));
  });

  it('a locked stack moves but never merges', () => {
    const r = sortBag([row(0, 'ore', 5), row(4, 'ore', 7)], info, [4]);
    expect(r.bag.map((x) => x.qty).sort()).toEqual([5, 7]);
  });

  it('use takes consumables only, from the named slot first, and skips what the bag lacks', () => {
    const bag = [row(0, 'flask', 2), row(6, 'flask', 4), row(1, 'ore', 9)];
    const r = useItems(bag, [{ itemId: 'flask', slot: 6, qty: 5 }, { itemId: 'ore', qty: 3 }, { itemId: 'flask', qty: 9 }], info);
    expect(r.bag).toEqual([row(1, 'ore', 9)]);
    expect(r.used).toEqual([{ itemId: 'flask', qty: 6 }]);
    expect(useItems(bag, [{ itemId: 'flask', slot: 6, qty: 1 }], info).bag).toEqual([row(0, 'flask', 2), row(1, 'ore', 9), row(6, 'flask', 3)]);
  });
});

