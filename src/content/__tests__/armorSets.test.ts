import { afterEach, describe, expect, it, vi } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { ARMOR_PARTS, ARMOR_PIECES, ARMOR_SETS, ASCENDED_ARMOR_SETS } from '../../../server/rules/content/armorSets';
import { AREAS } from '../../../server/rules/content/areas';
import { LEGENDARY_SETS } from '../../../server/rules/content/legendarySets';
import { ITEMS } from '../../../server/rules/content/items';
import { gearTier } from '../gear';
import { handleMock } from '../../net/mockBackend';
import { rollFirstKillItem } from '../../gameplay/loot';

describe('discipline armor integration', () => {
  it('offers every slot for every class in a combat drop table and the server migration', () => {
    const sql = {
      1: readFileSync(resolve('server/death-muffin/backend/migrations/011-class-armor.sql'), 'utf8'),
      2: readFileSync(resolve('server/death-muffin/backend/migrations/012-ascended-armor.sql'), 'utf8'),
      3: readFileSync(resolve('server/death-muffin/backend/migrations/025-legendary-sets.sql'), 'utf8'),
    };
    expect(ARMOR_PIECES).toHaveLength((Object.keys(ARMOR_SETS).length + Object.keys(ASCENDED_ARMOR_SETS).length + Object.keys(LEGENDARY_SETS).length) * ARMOR_PARTS.length);
    for (const piece of ARMOR_PIECES) {
      // Legendary pieces are not in any area table: bosses and scaled-area elites roll them (legendarySets.ts).
      expect(AREAS[piece.area].loot.some((drop) => drop.item === piece.id), piece.id).toBe(piece.collection !== 3);
      expect(ITEMS[piece.id]?.type, piece.id).toBe(`armor_${piece.part}`);
      expect(ITEMS[piece.id]?.offlineStats).toEqual(piece.stats);
      expect(gearTier(piece.id).color).toBe(piece.color);
      expect(existsSync(resolve(`public/art/items/${piece.id}.svg`)), piece.id).toBe(true);
      expect(sql[piece.collection]).toContain(`'${piece.id}'`);
      for (const other of [1, 2, 3] as const) if (other !== piece.collection) expect(sql[other]).not.toContain(`'${piece.id}'`);
    }
  });

  it('gives every discipline a stronger second set with distinct late-game drops', () => {
    expect(Object.keys(ASCENDED_ARMOR_SETS).sort()).toEqual(Object.keys(ARMOR_SETS).sort());
    for (const discipline of Object.keys(ARMOR_SETS)) for (const part of ARMOR_PARTS) {
      const first = ARMOR_PIECES.find((p) => p.disciplineId === discipline && p.part === part && p.collection === 1)!;
      const second = ARMOR_PIECES.find((p) => p.disciplineId === discipline && p.part === part && p.collection === 2)!;
      expect(second.setId).not.toBe(first.setId);
      expect(second.area).toMatch(/sanctum|cloister|pyre/);
      expect(Object.values(second.stats)[0]).toBeGreaterThan(Object.values(first.stats)[0]);
      expect(AREAS[second.area].loot.some((drop) => drop.item === second.id)).toBe(true);
    }
  });

  it('equips, swaps and saves armor in offline play without losing worn gear', async () => {
    const records = new Map<string, string>();
    vi.stubGlobal('localStorage', {
      getItem: (key: string) => records.get(key) ?? null,
      setItem: (key: string, value: string) => records.set(key, value),
    });
    records.set('cw_offline_db_v1', JSON.stringify({ nextCharacterId: 2, accounts: {
      armor_test: { username: 'armor_test', character: { id: 1 }, professions: [], slots: [
        { slot_index: 0, item_id: 'set_warden_head', quantity: 1, equipped: 0 },
        { slot_index: 1, item_id: 'set_warden_ascended_head', quantity: 1, equipped: 0 },
      ] },
    } }));
    const token = 'offline:armor_test';
    const post = (path: string, body: object) => handleMock(path, { method: 'POST', body: JSON.stringify(body) }, token);
    const first = await post('/api/inventory/equip', { characterId: 1, slot_index: 0, equipped: 1 });
    expect(first.data.find((s: { item_id: string }) => s.item_id === 'set_warden_head').slot_index).toBe(100);
    await post('/api/inventory/save', { characterId: 1, slots: [{ slot_index: 1, item_id: 'set_warden_ascended_head', quantity: 1, equipped: 0 }] });
    const second = await post('/api/inventory/equip', { characterId: 1, slot_index: 1, equipped: 1 });
    expect(second.data.find((s: { item_id: string }) => s.item_id === 'set_warden_ascended_head').slot_index).toBe(100);
    expect(second.data.find((s: { item_id: string }) => s.item_id === 'set_warden_head').slot_index).toBe(1);
  });

  it('keeps first-kill rewards inside the boss area progression', () => {
    expect(rollFirstKillItem('graves', () => 0).item_id).toBe('helm_gold');
    expect(AREAS.ossuary.loot.some((drop) => drop.item === rollFirstKillItem('ossuary', () => 0.99).item_id)).toBe(true);
  });
});

afterEach(() => vi.unstubAllGlobals());
