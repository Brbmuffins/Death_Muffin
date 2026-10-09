import { describe, expect, it } from 'vitest';
import { BAG_SLOTS } from '../gatheringRules';
import { VAULT_SLOTS, addGrants, depositMany, depositStack, sortVault, withdrawStack, type VaultInfo, type VaultRow } from '../vaultRules';

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
    expect(mats.ok && mats.bag.map((r) => r.slot)).toEqual([0, 3, 4]);
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
});
