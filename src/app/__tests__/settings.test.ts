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
    const { settings, updateSettings } = await import('../settings');

    expect(settings.difficulty).toBe('medium');
    expect(settings.autoCombat).toBe(false);

    updateSettings({ difficulty: 'easy' });
    expect(settings.autoCombat).toBe(true);
    updateSettings({ difficulty: 'hard' });
    expect(settings.autoCombat).toBe(false);
    updateSettings({ autoCombat: true });
    expect(settings.autoCombat).toBe(false);
    expect(JSON.parse(saved.get('dm_settings_v1')!).autoCombat).toBe(false);
  });

  it('normalizes old saved settings while preserving an Easy opt-out', async () => {
    let saved = JSON.stringify({ difficulty: 'hard', autoCombat: true });
    vi.stubGlobal('window', { matchMedia: () => ({ matches: false }) });
    vi.stubGlobal('localStorage', { getItem: () => saved, setItem: () => {} });

    expect((await import('../settings')).settings.autoCombat).toBe(false);
    vi.resetModules();
    saved = JSON.stringify({ difficulty: 'easy', autoCombat: false });
    expect((await import('../settings')).settings.autoCombat).toBe(false);
    vi.resetModules();
    saved = JSON.stringify({ difficulty: 'easy' });
    expect((await import('../settings')).settings.autoCombat).toBe(true);
  });
});
