import { DEFAULT_LOADOUT, GRIMOIRE, unlockLevel, type AbilityId } from '../content/abilities';
import type { StorageLike } from './codexJournal';

/**
 * The Grimoire loadout: which four rites sit on keys 1–4. A per-character
 * preference (not progress), so it lives in browser storage beside the Codex
 * journal and never touches the server.
 */
export const LOADOUT_SLOTS = 4;
export const loadoutStorageKey = (characterId: number) => `dm_loadout_v1_${characterId}`;

/**
 * A valid loadout for this level: four distinct, unlocked Grimoire rites. A
 * missing, corrupt or out-of-level slot falls back to the default rite for that
 * key (or the first free unlocked one), so play never starts with a hole.
 */
export function sanitizeLoadout(raw: unknown, level: number): AbilityId[] {
  const usable = (id: unknown): id is AbilityId => typeof id === 'string' && GRIMOIRE.includes(id as AbilityId) && unlockLevel(id as AbilityId) <= level;
  const picked: (AbilityId | null)[] = Array.from({ length: LOADOUT_SLOTS }, (_, i) => {
    const id = Array.isArray(raw) ? raw[i] : null;
    return usable(id) ? id : null;
  });
  // Duplicates keep their first slot.
  picked.forEach((id, i) => {
    if (id && picked.indexOf(id) !== i) picked[i] = null;
  });
  return picked.map((id, i) => {
    if (id) return id;
    const fallback = [DEFAULT_LOADOUT[i], ...GRIMOIRE].find((g) => usable(g) && !picked.includes(g))!;
    picked[i] = fallback;
    return fallback;
  });
}

export function loadLoadout(storage: StorageLike | null, characterId: number, level: number): AbilityId[] {
  let raw: unknown = null;
  try {
    const text = storage?.getItem(loadoutStorageKey(characterId));
    raw = text ? JSON.parse(text) : null;
  } catch {
    raw = null;
  }
  return sanitizeLoadout(raw, level);
}

export function saveLoadout(storage: StorageLike | null, characterId: number, loadout: AbilityId[]) {
  try {
    storage?.setItem(loadoutStorageKey(characterId), JSON.stringify(loadout));
  } catch {
    // Private mode / full storage: the choice still holds for this session.
  }
}

/** Put `id` on `slot` (0-based). If it already sits elsewhere, the two swap. */
export function assignRite(loadout: AbilityId[], slot: number, id: AbilityId): AbilityId[] {
  const next = [...loadout];
  const from = next.indexOf(id);
  if (from === slot) return next;
  if (from >= 0) next[from] = next[slot];
  next[slot] = id;
  return next;
}
