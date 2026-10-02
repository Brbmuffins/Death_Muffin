import { afterEach, describe, expect, it, vi } from 'vitest';

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetModules();
});

describe('difficulty and auto combat', () => {
  it('starts manual on Medium and changes auto combat with difficulty', async () => {
    const saved = new Map<string, string>();
    vi.stubGlobal('window', { matchMedia: () => ({ matches: false }) });
    vi.stubGlobal('localStorage', {
      getItem: (key: string) => saved.get(key) ?? null,
      setItem: (key: string, value: string) => saved.set(key, value),
    });
    const { settings, updateSettings, setActiveCharacter, canUseAutoCombat } = await import('../settings');

    expect(settings.difficulty).toBe('medium');
    expect(settings.autoCombat).toBe(false);
    setActiveCharacter(42, false);
    expect(canUseAutoCombat()).toBe(false);

    updateSettings({ difficulty: 'easy' });
    expect(settings.autoCombat).toBe(false);
    updateSettings({ autoCombat: true });
    expect(settings.autoCombat).toBe(false);
    expect(settings.difficulty).toBe('easy');
    setActiveCharacter(43, false);
    expect(settings.difficulty).toBe('medium');
    expect(settings.autoCombat).toBe(false);
    setActiveCharacter(42, true);
    expect(settings.difficulty).toBe('easy');
    expect(settings.autoCombat).toBe(false);
    updateSettings({ difficulty: 'medium' });
    updateSettings({ difficulty: 'easy' });
    expect(settings.autoCombat).toBe(true);
    updateSettings({ difficulty: 'hard' });
    expect(settings.autoCombat).toBe(false);
    updateSettings({ autoCombat: true });
    expect(settings.autoCombat).toBe(false);
    expect(JSON.parse(saved.get('dm_settings_v1')!).autoCombat).toBe(false);
    expect(JSON.parse(saved.get('dm_play_settings_v1_42')!).difficulty).toBe('hard');
  });

  it('ignores old shared Easy settings and refuses saved Auto for ordinary accounts', async () => {
    const saved = new Map<string, string>([
      ['dm_settings_v1', JSON.stringify({ difficulty: 'easy', autoCombat: true, autoGather: false })],
      ['dm_play_settings_v1_7', JSON.stringify({ difficulty: 'easy', autoCombat: true })],
    ]);
    vi.stubGlobal('window', { matchMedia: () => ({ matches: false }) });
    vi.stubGlobal('localStorage', {
      getItem: (key: string) => saved.get(key) ?? null,
      setItem: (key: string, value: string) => saved.set(key, value),
    });
    const { settings, setActiveCharacter, updateSettings } = await import('../settings');
    expect(settings.difficulty).toBe('medium');
    expect(settings.autoGather).toBe(false);
    setActiveCharacter(7, false);
    expect(settings.difficulty).toBe('easy');
    expect(settings.autoCombat).toBe(false);
    updateSettings({ autoCombat: true });
    expect(settings.autoCombat).toBe(false);
    setActiveCharacter(7, true);
    expect(settings.autoCombat).toBe(false);
    updateSettings({ autoCombat: true });
    expect(settings.autoCombat).toBe(true);
    setActiveCharacter(8, false);
    expect(settings.difficulty).toBe('medium');
    expect(settings.autoCombat).toBe(false);
  });
});

describe('battery defaults', () => {
  async function load(touch: boolean, stored?: object) {
    const saved = new Map<string, string>();
    if (stored) saved.set('dm_settings_v1', JSON.stringify(stored));
    vi.stubGlobal('window', {
      matchMedia: (q: string) => ({ matches: q.includes('pointer: coarse') ? touch : q.includes('hover: hover') ? !touch : false }),
    });
    vi.stubGlobal('localStorage', {
      getItem: (key: string) => saved.get(key) ?? null,
      setItem: (key: string, value: string) => saved.set(key, value),
    });
    return import('../settings');
  }
  it('desktop defaults to high / 60', async () => {
    const { settings } = await load(false);
    expect([settings.quality, settings.fps, settings.graphicsChosen]).toEqual(['high', 60, false]);
  });
  it('phone defaults to low / 30', async () => {
    const { settings } = await load(true);
    expect([settings.quality, settings.fps]).toEqual(['low', 30]);
  });
  it('phone with old stored high and no flag is optimised', async () => {
    const { settings } = await load(true, { quality: 'high' });
    expect([settings.quality, settings.fps]).toEqual(['low', 30]);
  });
  it('phone with graphicsChosen keeps its choice', async () => {
    const { settings } = await load(true, { quality: 'high', fps: 60, graphicsChosen: true });
    expect([settings.quality, settings.fps]).toEqual(['high', 60]);
  });
  it('desktop keeps stored values and invalid fps falls back', async () => {
    const { settings } = await load(false, { quality: 'low', fps: 45 });
    expect([settings.quality, settings.fps]).toEqual(['low', 60]);
  });
  it('changing graphics or fps sets graphicsChosen', async () => {
    const { settings, updateSettings } = await load(true);
    updateSettings({ volume: 0.5 });
    expect(settings.graphicsChosen).toBe(false);
    updateSettings({ fps: 60 });
    expect(settings.graphicsChosen).toBe(true);
  });
});
