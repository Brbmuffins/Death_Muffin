import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Inventory } from '../loot';
import { saveInventory } from '../../net/api';

vi.mock('../../net/api', () => ({ saveInventory: vi.fn() }));

describe('Inventory.exclusiveAction', () => {
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.mocked(saveInventory).mockReset().mockResolvedValue([]);
  });
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

  it('returns the server reply even when the bag re-read fails afterwards', async () => {
    const inv = new Inventory(1);
    const out = await inv.exclusiveAction(async () => ({ delivered: true }), async () => { throw new Error('offline'); });
    expect(out).toEqual({ reply: { delivered: true }, bagStale: true });
    inv.dispose();
  });

  it('adopts the fresh bag when the re-read works', async () => {
    const inv = new Inventory(1);
    const bag = [{ id: 1, slot_index: 0, quantity: 3, equipped: 0, item_id: 'material_copper_bar', name: 'Copper Bar', rarity: 'common', item_type: 'material', stat_bonus: null, icon_id: null, sell_value: 4, crafted: 0 }];
    const out = await inv.exclusiveAction(async () => 'ok', async () => bag as never);
    expect(out).toEqual({ reply: 'ok', bagStale: false });
    expect(inv.count('material_copper_bar')).toBe(3);
    inv.dispose();
  });

  it('still refuses when the action itself fails', async () => {
    const inv = new Inventory(1);
    await expect(inv.exclusiveAction(async () => { throw new Error('The Sexton refuses.'); }, async () => [])).rejects.toThrow('The Sexton refuses.');
    inv.dispose();
  });
});

describe('replaying a local consume on a fresh server bag', () => {
  beforeEach(() => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.mocked(saveInventory).mockReset().mockResolvedValue([]);
  });
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

  const row = (slot_index: number, equipped: 0 | 1) => ({ id: slot_index, slot_index, quantity: 1, equipped, item_id: 'tool_pickaxe_copper', name: 'Pickaxe', rarity: 'common', item_type: 'tool', stat_bonus: null, icon_id: null, sell_value: 3, crafted: 0 }) as never;

  it('a sale from bag slot 5 never eats the same tool now hanging on the belt (slot 110)', () => {
    const inv = new Inventory(1);
    inv.replace([row(5, 0)]);
    expect(inv.consumeAt(5)).toBe(true);
    // The belt reply arrives: the tool moved from slot 5 to the belt.
    inv.replace([row(110, 1)]);
    expect(inv.all.map((s) => s.slot_index)).toEqual([110]);
    inv.dispose();
  });
});
