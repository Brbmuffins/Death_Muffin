/**
 * Per-viewer client settings (graphics preset, motion, feedback). Stored in
 * localStorage as a convenience only — every read/write is guarded because
 * storage can be unavailable (private windows, blocked site data).
 */
import { isDifficulty, type Difficulty } from '../content/difficulty';

export type Quality = 'high' | 'low';

export interface Settings {
  quality: Quality;
  reducedMotion: boolean;
  damageNumbers: boolean;
  volume: number; // 0..1
  /** First-time onboarding tips (ui/Onboarding). */
  tips: boolean;
  /** Session difficulty; in co-op the world keeper's setting applies. */
  difficulty: Difficulty;
  /** Fight nearby enemies and manage basic rites while standing. */
  autoCombat: boolean;
}

const KEY = 'dm_settings_v1';

function defaults(): Settings {
  let reduced = false;
  try {
    reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch {
    /* no matchMedia */
  }
  return { quality: 'high', reducedMotion: reduced, damageNumbers: true, volume: 0.6, tips: true, difficulty: 'medium', autoCombat: true };
}

function load(): Settings {
  const base = defaults();
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const s = { ...base, ...JSON.parse(raw) } as Settings;
      if (!isDifficulty(s.difficulty)) s.difficulty = base.difficulty;
      return s;
    }
  } catch {
    /* storage unavailable */
  }
  return base;
}

export const settings: Settings = load();

const listeners = new Set<(s: Settings) => void>();

export function updateSettings(patch: Partial<Settings>) {
  Object.assign(settings, patch);
  try {
    localStorage.setItem(KEY, JSON.stringify(settings));
  } catch {
    /* storage unavailable */
  }
  listeners.forEach((fn) => fn(settings));
}

export function onSettingsChange(fn: (s: Settings) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
