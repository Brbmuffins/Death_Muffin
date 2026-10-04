import { BREW_KEYS } from '../content/brews';
import type { StorageLike } from './codexJournal';
import { MAX_PRESETS } from './loadoutRules';

/**
 * Rebindable actions (2026-10-03): only the loadout hotkeys for now, all UNBOUND until the player picks a key in Settings → Controls.
 * A key the game already uses cannot be bound, so nothing existing is ever stolen. Stored per browser (a key preference, like the quality
 * setting, not part of the character).
 */
export const KEYBIND_STORAGE_KEY = 'dm_keybinds_v1';

export type ActionId = 'loadout_next' | `loadout_${1 | 2 | 3 | 4 | 5 | 6}`;
export const LOADOUT_ACTIONS: ActionId[] = ['loadout_next', ...(Array.from({ length: MAX_PRESETS }, (_, i) => `loadout_${i + 1}`) as ActionId[])];
export const ACTION_LABEL: Record<ActionId, string> = {
  loadout_next: 'Next loadout',
  loadout_1: 'Loadout 1',
  loadout_2: 'Loadout 2',
  loadout_3: 'Loadout 3',
  loadout_4: 'Loadout 4',
  loadout_5: 'Loadout 5',
  loadout_6: 'Loadout 6',
};

export type Binds = Partial<Record<ActionId, string>>;

/** Every key the game already answers to (lowercase `KeyboardEvent.key`), with what it does. Keep in step with WorldScene's key handler. */
export const RESERVED_KEYS: Record<string, string> = {
  '1': 'rite slot 1', '2': 'rite slot 2', '3': 'rite slot 3', '4': 'rite slot 4', '5': 'rite slot 5', '6': 'the signature rite',
  r: 'the signature rite', q: 'the healing flask', t: 'Recall', i: 'the Reliquary', b: 'the Reliquary', j: 'the character sheet', y: 'the Legion',
  c: 'the Workbench', p: 'Skills', o: 'Contracts', u: 'the Garden', h: 'the Laborers', n: 'Capes and Pets', v: 'the Vault', m: 'the Waystones',
  k: 'the Codex', '.': 'the Gear Atlas', l: 'the Grimoire', g: 'auto combat', e: 'talking to someone nearby', escape: 'Settings and closing panels',
  enter: 'chat', w: 'walking', a: 'walking', s: 'walking', d: 'walking', arrowup: 'walking', arrowdown: 'walking', arrowleft: 'walking', arrowright: 'walking',
  ' ': 'the game',
  [BREW_KEYS.elixir]: 'the elixir on your belt', [BREW_KEYS.tonic]: 'the tonic on your belt',
};

/** Keys that are modifiers or give no single character: never bindable. */
const NOT_A_KEY = new Set(['shift', 'control', 'alt', 'meta', 'altgraph', 'capslock', 'tab', 'dead', 'unidentified', 'contextmenu', 'os', 'fn']);

export type Check = { ok: true; key: string } | { ok: false; error: string };

/** Can this key go on `action`? Readable refusal when the game uses it already or another action holds it. */
export function checkBind(binds: Binds, action: ActionId, rawKey: string): Check {
  const key = rawKey.toLowerCase();
  if (NOT_A_KEY.has(key) || key.length === 0 || (key.length > 1 && !/^f([1-9]|1[0-2])$/.test(key) && !/^(arrow|page|home|end|insert|delete|backspace)/.test(key))) return { ok: false, error: 'That key cannot be used. Pick a letter, number or function key.' };
  if (key === 'f5' || key === 'f11' || key === 'f12') return { ok: false, error: `${label(key)} is used by your browser. Pick another key.` };
  if (RESERVED_KEYS[key]) return { ok: false, error: `${label(key)} is already used for ${RESERVED_KEYS[key]}. Pick another key.` };
  const other = LOADOUT_ACTIONS.find((a) => a !== action && binds[a] === key);
  if (other) return { ok: false, error: `${label(key)} is already ${ACTION_LABEL[other]}. Clear that one first.` };
  return { ok: true, key };
}

/** A key as the player reads it: a letter in capitals, "F7", "Page Up". */
export function label(key: string): string {
  if (key.length === 1) return key.toUpperCase();
  if (/^f\d+$/.test(key)) return key.toUpperCase();
  return key.replace(/^arrow/, 'Arrow ').replace(/^page/, 'Page ').replace(/^./, (c) => c.toUpperCase());
}

export function loadBinds(storage: StorageLike | null): Binds {
  try {
    const raw = JSON.parse(storage?.getItem(KEYBIND_STORAGE_KEY) ?? 'null') as Record<string, unknown> | null;
    const out: Binds = {};
    if (!raw || typeof raw !== 'object') return out;
    for (const a of LOADOUT_ACTIONS) {
      const k = raw[a];
      if (typeof k === 'string' && checkBind(out, a, k).ok) out[a] = k.toLowerCase();
    }
    return out;
  } catch {
    return {};
  }
}

export function saveBinds(storage: StorageLike | null, binds: Binds) {
  try {
    storage?.setItem(KEYBIND_STORAGE_KEY, JSON.stringify(binds));
  } catch {
    /* private mode: the binding holds for this session */
  }
}

/** The action a pressed key triggers, or null. */
export function actionForKey(binds: Binds, rawKey: string): ActionId | null {
  const key = rawKey.toLowerCase();
  return LOADOUT_ACTIONS.find((a) => binds[a] === key) ?? null;
}

/** Which saved slot a "next loadout" press should apply: the one after the loadout that is on now (or after the last one used), wrapping. */
export function nextSlot(saved: readonly number[], activeSlot: number | null, lastUsed: number | null): number | null {
  if (!saved.length) return null;
  const from = activeSlot ?? lastUsed;
  if (from === null) return saved[0];
  const after = saved.find((s) => s > from);
  return after ?? saved[0];
}
