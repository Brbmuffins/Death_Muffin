import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Progression } from '../progression';
import { Inventory, addToSlots } from '../loot';
import { necroApi, saveInventory, saveProgress } from '../../net/api';
import { blankState } from '../../../server/rules/gameplay/necroRules';
import type { Character } from '../../net/types';

vi.mock('../../net/api', () => ({ saveProgress: vi.fn(), saveInventory: vi.fn(), necroApi: { purchase: vi.fn(), get: vi.fn(), save: vi.fn() } }));

const character = (): Character => ({ id: 7, class_index: 2, class_name: 'Shadowblade', level: 2,
  experience: 5, gold: 20, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 });

describe('save before changing class', () => {
  beforeEach(() => {
    // These tests fail saves on purpose; keep the expected retry warnings out of the test output.
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.mocked(saveProgress).mockReset().mockResolvedValue({ success: true });
    vi.mocked(saveInventory).mockReset().mockResolvedValue([]);
  });
  afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });

  it('waits for an outstanding progress save and saves later gains before returning', async () => {
    const progress = new Progression(character());
    try {
      let finish!: () => void;
      vi.mocked(saveProgress).mockImplementationOnce(() => new Promise(resolve => { finish = () => resolve({ success: true }); }));
      progress.addGold(10);
      const first = progress.flush();
      progress.addGold(5);
      let done = false;
      const changing = progress.saveBeforeClassChange().then(() => { done = true; });
      await Promise.resolve();
      expect(done).toBe(false);
      finish();await first;await changing;
      expect(saveProgress).toHaveBeenLastCalledWith(expect.objectContaining({ characterId: 7, gold: 35, level: 2 }), false);
      expect(progress.state).toBe('saved');
    } finally { progress.dispose(); }
  });

  it('waits for an upgrade purchase before saving gold and changing class', async () => {
    const c = character();c.gold = 1000;
    const progress = new Progression(c);progress.mode = 'server';
    try {
      let finish!: () => void;
      vi.mocked(necroApi.purchase).mockImplementationOnce(() => new Promise(resolve => { finish = () => resolve({ progress: { ...blankState(), damageTier: 1 } }); }));
      const cost = progress.damageCost()!;
      expect(progress.buyDamage()).toBe(true);
      await Promise.resolve();await Promise.resolve();
      expect(necroApi.purchase).toHaveBeenCalled();
      let done = false;
      const changing = progress.saveBeforeClassChange().then(() => { done = true; });
      await Promise.resolve();expect(done).toBe(false);
      finish();await changing;
      expect(progress.local.damageTier).toBe(1);
      expect(saveProgress).toHaveBeenLastCalledWith(expect.objectContaining({ characterId: 7, gold: 1000 - cost }), false);
    } finally { progress.dispose(); }
  });

  it('blocks a class change when saving progress fails and retains the unsaved gold', async () => {
    const progress = new Progression(character());
    try {
      progress.addGold(12);
      vi.mocked(saveProgress).mockRejectedValue(new Error('Unavailable'));
      await expect(progress.saveBeforeClassChange()).rejects.toThrow('Could not save your progress');
      expect(progress.character.gold).toBe(32);
      expect(progress.character.class_index).toBe(2);
      expect(progress.state).toBe('retrying');
      vi.mocked(saveProgress).mockResolvedValue({ success: true });
      await progress.saveBeforeClassChange();
      expect(progress.state).toBe('saved');
    } finally { progress.dispose(); }
  });

  it('blocks a class change when item saving fails and retries the same inventory', async () => {
    const inventory = new Inventory(7);
    try {
      inventory.add({ item_id: 'flask_hp_minor', quantity: 3 });
      vi.mocked(saveInventory).mockRejectedValue(new Error('Unavailable'));
      await expect(inventory.saveBeforeClassChange()).rejects.toThrow('Could not save your items');
      expect(inventory.count('flask_hp_minor')).toBe(3);
      const items = inventory.all;
      vi.mocked(saveInventory).mockResolvedValue(items);
      await inventory.saveBeforeClassChange();
      expect(inventory.state).toBe('saved');
      expect(inventory.count('flask_hp_minor')).toBe(3);
    } finally { inventory.dispose(); }
  });

  it('keeps loot and flask use that arrive before an equip or craft inventory reply', async () => {
    const inventory = new Inventory(7);
    try {
      inventory.add({ item_id: 'flask_hp_minor', quantity: 2 });
      inventory.replace([]); // Stale server reply from a request already in progress.
      expect(inventory.count('flask_hp_minor')).toBe(2);
      await inventory.flush();
      expect(saveInventory).toHaveBeenLastCalledWith(7, expect.arrayContaining([
        expect.objectContaining({ item_id: 'flask_hp_minor', quantity: 2 }),
      ]), 48);
    } finally { inventory.dispose(); }

    const usingFlask = new Inventory(7);
    try {
      const reply = addToSlots([], { item_id: 'flask_hp_minor', quantity: 1 })!;
      usingFlask.replace(reply);
      usingFlask.consume('flask_hp_minor');
      usingFlask.replace(reply);
      expect(usingFlask.count('flask_hp_minor')).toBe(0);
      usingFlask.replace([]); // Already reflected by the server; keep its updated bag.
      expect(usingFlask.count('flask_hp_minor')).toBe(0);
    } finally { usingFlask.dispose(); }
  });

  it('does not replay an in-flight save already present in an equip reply', async () => {
    const savedPickup = addToSlots([], { item_id: 'flask_hp_minor', quantity: 1 })!;
    const inventory = new Inventory(7);
    try {
      let complete!: () => void;
      vi.mocked(saveInventory).mockImplementationOnce(() => new Promise(resolve => { complete = () => resolve(savedPickup); }));
      inventory.add({ item_id: 'flask_hp_minor', quantity: 1 });
      const saving = inventory.flush();
      inventory.replace(savedPickup); // Server applied save, but response is still in flight.
      expect(inventory.count('flask_hp_minor')).toBe(1);
      complete();
      await saving;
      expect(inventory.count('flask_hp_minor')).toBe(1);
    } finally { inventory.dispose(); }

    const savedUse = addToSlots([], { item_id: 'flask_hp_minor', quantity: 1 })!;
    const usingFlask = new Inventory(7);
    try {
      usingFlask.replace(addToSlots([], { item_id: 'flask_hp_minor', quantity: 2 })!);
      let complete!: () => void;
      vi.mocked(saveInventory).mockImplementationOnce(() => new Promise(resolve => { complete = () => resolve(savedUse); }));
      usingFlask.consume('flask_hp_minor');
      const saving = usingFlask.flush();
      usingFlask.replace(savedUse);
      expect(usingFlask.count('flask_hp_minor')).toBe(1);
      complete();
      await saving;
      expect(usingFlask.count('flask_hp_minor')).toBe(1);
    } finally { usingFlask.dispose(); }
  });

  it('a craft never overlaps a bag save, so spent ingredients cannot be written back', async () => {
    const inventory = new Inventory(7);
    try {
      let release!: () => void;
      const order: string[] = [];
      vi.mocked(saveInventory).mockImplementation(() => new Promise((resolve) => {
        order.push('save-start');
        release = () => {
          order.push('save-end');
          resolve([]);
        };
      }));
      inventory.add({ item_id: 'log_oak', quantity: 3 });
      const saving = inventory.flush(); // a save is now in flight
      const crafted = inventory.exclusive(async () => {
        order.push('craft');
        inventory.add({ item_id: 'log_oak', quantity: 1 }); // a pickup during the craft
        inventory.replace([]); // the server's post-craft bag
      });
      await new Promise((r) => setTimeout(r, 20));
      expect(order).toEqual(['save-start']); // the craft waits for the save to land
      release();
      await saving;
      await crafted;
      expect(order.slice(0, 3)).toEqual(['save-start', 'save-end', 'craft']);
      // The mid-craft pickup replays on top of the fresh bag; the spent logs don't come back.
      expect(inventory.count('log_oak')).toBe(1);
    } finally { inventory.dispose(); }
  });
});

