/**
 * Per-viewer client settings (graphics preset, motion, feedback). Stored in
 * localStorage as a convenience only — every read/write is guarded because
 * storage can be unavailable (private windows, blocked site data).
 */
import { isFpsCap, type FpsCap } from './framePacing';
import { DEFAULT_LOOT_RULES, readLootRules, type LootRules } from '../gameplay/lootFilter';
import { isDifficulty, type Difficulty } from '../content/difficulty';

export type Quality = 'high' | 'low';

export interface Settings {
  quality: Quality;
  /** Frame-rate cap: 0 = Max (the display's refresh rate, desktop default), 60, or 30 (battery saver, phone default). */
  fps: FpsCap;
  /** True once the player has changed Graphics or Frame rate themselves; until then phones get battery-saver defaults. */
  graphicsChosen: boolean;
  /** Let the game lower the render resolution when the GPU can't hold the frame rate (ResolutionGovernor). */
  autoResolution: boolean;
  reducedMotion: boolean;
  damageNumbers: boolean;
  /** Draw heroes without their helms (yours and other players'): the hood or hair shows instead. */
  hideHelm: boolean;
  volume: number; // 0..1 (master)
  /** Mixer sliders, 0..1, applied under the master volume. */
  combatVolume: number;
  ambienceVolume: number;
  interfaceVolume: number;
  /** First-time onboarding tips (ui/Onboarding). */
  tips: boolean;
  /** The compact "Next" suggestion under the minimap (gameplay/guidance.ts), and its minimap ping. Both default on. */
  guidance: boolean;
  guidancePing: boolean;
  /** Session difficulty; in co-op the world keeper's setting applies. */
  difficulty: Difficulty;
  /** Fight nearby enemies and manage basic rites while standing. */
  autoCombat: boolean;
  /** When a gathering node depletes, walk on to the nearest one of the same kind. */
  autoGather: boolean;
  /** Per gear rarity: on the ground, auto-loot or sell for gold (gameplay/lootFilter.ts). Default: everything on the ground. */
  lootRules: LootRules;
}

const OFFLINE_PREFIX = import.meta.env.VITE_OFFLINE_BUILD === '1' ? 'dm_offline_' : '';
const KEY = `${OFFLINE_PREFIX}dm_settings_v1`;
const characterKey = (id: number) => `${OFFLINE_PREFIX}dm_play_settings_v1_${id}`;
let activeCharacter: number | null = null;
let autoCombatAllowed = false;

/** Phones and tablets: coarse primary pointer and no hover. */
export function isTouchFirst(): boolean {
  try {
    return window.matchMedia('(pointer: coarse)').matches && !window.matchMedia('(hover: hover)').matches;
  } catch {
    return false;
  }
}

function defaults(): Settings {
  let reduced = false;
  try {
    reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  } catch {
    /* no matchMedia */
  }
  const touchFirst = isTouchFirst();
  return { quality: touchFirst ? 'low' : 'high', fps: touchFirst ? 30 : 0, graphicsChosen: false, autoResolution: true, reducedMotion: reduced, damageNumbers: true, hideHelm: false, volume: 0.6, combatVolume: 1, ambienceVolume: 1, interfaceVolume: 1, tips: true, guidance: true, guidancePing: true, difficulty: 'medium', autoCombat: false, autoGather: true, lootRules: { ...DEFAULT_LOOT_RULES } };
}

function load(): Settings {
  const base = defaults();
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const stored = JSON.parse(raw) as Partial<Settings>;
      const s = { ...base, ...stored } as Settings;
      for (const k of ['volume', 'combatVolume', 'ambienceVolume', 'interfaceVolume'] as const) {
        if (typeof s[k] !== 'number' || !Number.isFinite(s[k])) s[k] = base[k];
        s[k] = Math.min(1, Math.max(0, s[k]));
      }
      if (!isFpsCap(s.fps)) s.fps = base.fps;
      s.graphicsChosen = s.graphicsChosen === true;
      s.autoResolution = s.autoResolution !== false;
      // Saved 'high' on a phone is usually just the old default, not a choice: auto-optimise until the player picks.
      if (!s.graphicsChosen && isTouchFirst()) {
        s.quality = 'low';
        s.fps = 30;
      }
      // Desktop players who never picked a rate get Max: the old 60 default was a cap that throttled 120/144 Hz screens.
      if (!s.graphicsChosen && !isTouchFirst()) s.fps = 0;
      if (!isDifficulty(s.difficulty)) s.difficulty = base.difficulty;
      // The first release had a single Loot filter (tiers below it became gold): carried over into the per-tier rules.
      s.lootRules = readLootRules(s.lootRules, (stored as { lootFilter?: unknown }).lootFilter);
      delete (s as { lootFilter?: unknown }).lootFilter;
      // Old browser-wide play settings cannot be attributed to an account.
      // Each character starts on Medium until its own preference is loaded.
      s.difficulty = base.difficulty;
      s.autoCombat = false;
      return s;
    }
  } catch {
    /* storage unavailable */
  }
  return base;
}

export const settings: Settings = load();

const listeners = new Set<(s: Settings) => void>();

export function canUseAutoCombat(): boolean {
  return autoCombatAllowed;
}

/**
 * Auto combat is owner-only for now. Player-facing text that explains it is wrapped in `{auto}...{/auto}` and dropped for everyone
 * else, so no one is told about a key (G) or an Easy-mode feature they do not have.
 */
export function gateAuto(text: string): string {
  return text.replace(/\{auto\}([\s\S]*?)\{\/auto\}/g, (_m, inner: string) => (autoCombatAllowed ? inner : ''));
}

/** Called after the authenticated character response, before the world mounts. */
export function setActiveCharacter(id: number | null, allowed = false) {
  activeCharacter = id;
  autoCombatAllowed = allowed === true;
  let difficulty: Difficulty = 'medium';
  let autoCombat = false;
  if (id !== null) {
    try {
      const raw = localStorage.getItem(characterKey(id));
      if (raw) {
        const saved = JSON.parse(raw) as { difficulty?: unknown; autoCombat?: unknown };
        if (isDifficulty(saved.difficulty)) difficulty = saved.difficulty;
        autoCombat = saved.autoCombat === true;
      }
    } catch {
      /* storage unavailable or corrupt */
    }
  }
  settings.difficulty = difficulty;
  settings.autoCombat = autoCombatAllowed && difficulty === 'easy' && autoCombat;
  listeners.forEach((fn) => fn(settings));
}

export function updateSettings(patch: Partial<Settings>) {
  if (patch.difficulty !== undefined && patch.autoCombat === undefined) {
    patch = { ...patch, autoCombat: autoCombatAllowed && patch.difficulty === 'easy' };
  }
  if (!autoCombatAllowed || (patch.difficulty ?? settings.difficulty) !== 'easy') {
    patch = { ...patch, autoCombat: false };
  }
  if (patch.quality !== undefined || patch.fps !== undefined) patch = { ...patch, graphicsChosen: true };
  Object.assign(settings, patch);
  try {
    localStorage.setItem(KEY, JSON.stringify(settings));
    if (activeCharacter !== null) localStorage.setItem(characterKey(activeCharacter), JSON.stringify({ difficulty: settings.difficulty, autoCombat: settings.autoCombat }));
  } catch {
    /* storage unavailable */
  }
  listeners.forEach((fn) => fn(settings));
}

export function onSettingsChange(fn: (s: Settings) => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
