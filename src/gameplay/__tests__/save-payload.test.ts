import { describe, expect, it } from 'vitest';
import { BAG_SIZE, toSavePayload } from '../loot';
import type { InventorySlot } from '../../net/types';

const slot = (slot_index: number, item_id: string, equipped = 0) =>
  ({ id: slot_index, slot_index, item_id, quantity: 1, equipped }) as InventorySlot;

describe('toSavePayload', () => {
  it('sends only bag slots; equipped gear (reserved slots 100+) is left to /equip', () => {
    const payload = toSavePayload([slot(0, 'ore_tin'), slot(BAG_SIZE - 1, 'log_oak'), slot(105, 'staff_oak', 1), slot(100, 'helm_copper', 1)]);
    expect(payload.map((p) => p.slot_index)).toEqual([0, BAG_SIZE - 1]);
    expect(payload.every((p) => p.slot_index >= 0 && p.slot_index < 24)).toBe(true);
  });
});
