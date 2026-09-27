import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Progression } from '../progression';
import { Inventory } from '../loot';
import { necroApi, saveInventory, saveProgress } from '../../net/api';
import { blankState } from '../necroRules';
import type { Character } from '../../net/types';

vi.mock('../../net/api', () => ({ saveProgress: vi.fn(), saveInventory: vi.fn(), necroApi: { purchase: vi.fn(), get: vi.fn(), save: vi.fn() } }));

const character = (): Character => ({ id: 7, class_index: 2, class_name: 'Shadowblade', level: 2,
  experience: 5, gold: 20, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 10 });

describe('save before changing class', () => {
  beforeEach(() => {
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.mocked(saveProgress).mockReset().mockResolvedValue({ success: true });
    vi.mocked(saveInventory).mockReset().mockResolvedValue([]);
  });
  afterEach(() => { vi.unstubAllGlobals(); });

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
});
