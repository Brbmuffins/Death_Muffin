/**
 * Per-viewer client settings (graphics preset, motion, feedback). Stored in
 * localStorage as a convenience only — every read/write is guarded because
 * storage can be unavailable (private windows, blocked site data).
 */
export type Quality = 'high' | 'low';

export interface Settings {
  quality: Quality;
  reducedMotion: boolean;
  damageNumbers: boolean;
  volume: number; // 0..1
}

const KEY = 'cw_settings_v1';

function defaults(): Settings {
  let reduced = false;
  try {
    reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch {
    /* no matchMedia */
  }
  return { quality: 'high', reducedMotion: reduced, damageNumbers: true, volume: 0.6 };
}

function load(): Settings {
  const base = defaults();
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) return { ...base, ...JSON.parse(raw) };
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
