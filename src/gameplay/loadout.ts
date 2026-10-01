import { unlockLevel, type AbilityId } from '../content/abilities';
import { kitFor, type Kit } from '../content/kits';
import type { StorageLike } from './codexJournal';

/**
 * Every reader takes the active `kit` and defaults to the necromancer's, so
 * pre-framework call sites (and their tests) keep their exact behaviour.
 */
const NECRO = kitFor('necromancer');

/**
 * The Grimoire loadout: the left-click primary plus five rites on keys 1–5
 * (right-click also casts slot 5). A per-character preference, so it lives in browser
 * storage beside the Codex journal and never touches the server.
 *
 * v2 storage is `{ primary, keys }` under dm_loadout_v2_<id>; a v1 array
 * (dm_loadout_v1_<id>, keys only) is migrated on first read.
 */
export const LOADOUT_SLOTS = 5;
export const loadoutStorageKey = (characterId: number) => `dm_loadout_v2_${characterId}`;
export const legacyLoadoutKey = (characterId: number) => `dm_loadout_v1_${characterId}`;
export const seenStorageKey = (characterId: number) => `dm_rites_seen_v1_${characterId}`;

export interface Rites {
  primary: AbilityId;
  keys: AbilityId[];
}

/**
 * All rites that can be equipped in the five sockets. The signature stays on R.
 */
export function assignableRites(kit: Kit = NECRO): AbilityId[] {
  return [...new Set([...kit.grimoire, kit.rmb])];
}

/**
 * Five distinct Grimoire rites. Invalid slots fall back to the default rite
 * for that socket, then another free unlocked rite.
 * Families with fewer than five level-1 rites keep future defaults visible in
 * locked hotbar slots, so a new character never starts with a hole.
 */
export function sanitizeLoadout(raw: unknown, level: number, kit: Kit = NECRO): AbilityId[] {
  const available = assignableRites(kit);
  const defaults = [...kit.defaultLoadout, kit.rmb];
  const usable = (id: unknown): id is AbilityId => typeof id === 'string' && available.includes(id as AbilityId) && unlockLevel(id as AbilityId) <= level;
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
    // Keep an as-yet-locked default visible in its original socket. A newly
    // unlocked rite may replace it, but never moves the right-click default.
    const fallback = (defaults[i] && !picked.includes(defaults[i]) ? defaults[i] : undefined)
      ?? available.find((g) => usable(g) && !picked.includes(g))
      ?? available.find((g) => !picked.includes(g))!;
    picked[i] = fallback;
    return fallback;
  });
}

/** A valid primary for this level (falls back to Bone Needle). */
export function sanitizePrimary(raw: unknown, level: number, kit: Kit = NECRO): AbilityId {
  return typeof raw === 'string' && kit.primaries.includes(raw as AbilityId) && unlockLevel(raw as AbilityId) <= level ? (raw as AbilityId) : kit.defaultPrimary;
}

function readJson(storage: StorageLike | null, key: string): unknown {
  try {
    const text = storage?.getItem(key);
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}

export function loadRites(storage: StorageLike | null, characterId: number, level: number, kit: Kit = NECRO): Rites {
  const v2 = readJson(storage, loadoutStorageKey(characterId)) as { primary?: unknown; keys?: unknown } | null;
  if (v2 && typeof v2 === 'object' && !Array.isArray(v2)) return { primary: sanitizePrimary(v2.primary, level, kit), keys: sanitizeLoadout(v2.keys, level, kit) };
  // v1: an array of keys only.
  const v1 = readJson(storage, legacyLoadoutKey(characterId));
  return { primary: kit.defaultPrimary, keys: sanitizeLoadout(v1, level, kit) };
}

export function saveRites(storage: StorageLike | null, characterId: number, rites: Rites) {
  try {
    storage?.setItem(loadoutStorageKey(characterId), JSON.stringify({ primary: rites.primary, keys: rites.keys }));
  } catch {
    // Private mode / full storage: the choice still holds for this session.
  }
}

/** Five equipped rite slots. */
export function loadLoadout(storage: StorageLike | null, characterId: number, level: number, kit: Kit = NECRO): AbilityId[] {
  return loadRites(storage, characterId, level, kit).keys;
}

/** Save the five rite slots, keeping whatever primary is stored. */
export function saveLoadout(storage: StorageLike | null, characterId: number, loadout: AbilityId[], kit: Kit = NECRO) {
  const stored = readJson(storage, loadoutStorageKey(characterId)) as { primary?: unknown } | null;
  const primary = typeof stored?.primary === 'string' && kit.primaries.includes(stored.primary as AbilityId) ? (stored.primary as AbilityId) : kit.defaultPrimary;
  saveRites(storage, characterId, { primary, keys: loadout });
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

/**
 * Rites the player has seen in the Grimoire (or placed). A learned rite not in this set wears a
 * NEW tag, and the hotbar's Grimoire button a pip. Starts with the level-1 kit and the current bar.
 */
export function loadSeen(storage: StorageLike | null, characterId: number, rites: Rites, kit: Kit = NECRO): Set<AbilityId> {
  const raw = readJson(storage, seenStorageKey(characterId));
  const seen = new Set<AbilityId>(Array.isArray(raw) ? (raw.filter((x) => typeof x === 'string') as AbilityId[]) : []);
  for (const id of [...assignableRites(kit), ...kit.primaries]) if (unlockLevel(id) <= 1) seen.add(id);
  seen.add(rites.primary);
  for (const id of rites.keys) if (unlockLevel(id) <= 1) seen.add(id);
  return seen;
}

export function saveSeen(storage: StorageLike | null, characterId: number, seen: Set<AbilityId>) {
  try {
    storage?.setItem(seenStorageKey(characterId), JSON.stringify([...seen]));
  } catch {
    /* session-only */
  }
}

/** Learned (at this level) but never seen. */
export function unseenRites(seen: Set<AbilityId>, level: number, kit: Kit = NECRO): AbilityId[] {
  return [...kit.primaries, ...assignableRites(kit)].filter((id) => unlockLevel(id) <= level && !seen.has(id));
}
