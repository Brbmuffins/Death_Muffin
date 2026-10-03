import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { Progression } from '../progression';
import { necroApi, saveProgress } from '../../net/api';
import type { Character } from '../../net/types';

vi.mock('../../net/api', () => ({ saveProgress: vi.fn(), saveInventory: vi.fn(), necroApi: { purchase: vi.fn(), get: vi.fn(), save: vi.fn() } }));

const character = (): Character => ({ id: 9, class_index: 2, class_name: 'Shadowblade', level: 1, experience: 0, gold: 0, stat_str: 5, stat_agi: 5, stat_int: 5, stat_vit: 5 });

describe('core bug hunt: progression saves', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.stubGlobal('window', { setTimeout, clearTimeout });
    vi.mocked(saveProgress).mockReset().mockResolvedValue({ success: true });
    vi.mocked(necroApi.save).mockReset();
  });
  afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

  it('a level-up that lands while a save is in flight is saved right after it, not 45 s later', async () => {
    const progress = new Progression(character());
    try {
      let finish!: () => void;
      vi.mocked(saveProgress).mockImplementationOnce(() => new Promise((resolve) => { finish = () => resolve({ success: true }); }));
      progress.addGold(5);
      const first = progress.flush();
      expect(progress.addXp(500)).toBeGreaterThan(0); // level-up: urgent, but the first save is still out
      finish();
      await first;
      await vi.advanceTimersByTimeAsync(1000);
      expect(saveProgress).toHaveBeenCalledTimes(2);
      expect(vi.mocked(saveProgress).mock.calls[1][0]).toMatchObject({ level: 3 });
    } finally { progress.dispose(); }
  });
});
