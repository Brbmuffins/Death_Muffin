import { REAGENT_BREW_LIST, REAGENT_ITEMS } from './reagents';

/**
 * The Alchemist's Wing, pure data and helpers (no DOM, no three.js): the Reagent Shelf's contents, the "found" record, and the
 * Great Cauldron's brew of the day. The shelf and the day's pick are read by ui/ReagentShelfPanel.ts and ui/ForgePanel.ts.
 */

/** Garden herbs and the Kiln's bone meal, the older half of the shelf (the reagents proper come from REAGENT_ITEMS). */
export const SHELF_HERBS = ['herb_mourning_moss', 'herb_nightshade', 'herb_corpse_lily', 'herb_wolfsbane', 'herb_bloodroot', 'herb_moonpetal', 'bone_meal'];

export interface ShelfGroup { title: string; blurb: string; ids: string[] }

export const SHELF_GROUPS: ShelfGroup[] = [
  { title: 'Garden herbs', blurb: 'Grown in the Acre (Grave Gardening); bone meal comes from the Bone Kiln.', ids: SHELF_HERBS },
  { title: 'Dead-drops', blurb: 'Shed by the dead: dust, ectoplasm, bile and ash.', ids: ['reagent_grave_dust', 'reagent_wraith_ectoplasm', 'reagent_plague_bile', 'reagent_cinder_ash'] },
  { title: 'Foraged', blurb: 'Rot-cap grows in the Cloister, Ash-bloom in the Pyre.', ids: ['herb_rot_cap', 'herb_ash_bloom'] },
  { title: 'Boss ichors', blurb: 'Every area boss always leaves one.', ids: Object.keys(REAGENT_ITEMS).filter((id) => id.startsWith('ichor_')) },
];
export const SHELF_IDS: string[] = SHELF_GROUPS.flatMap((g) => g.ids);

const foundKey = (characterId: number) => `dm_wing_found_${characterId}`;
const bonusKey = (characterId: number) => `dm_wing_botd_${characterId}`;

type Store = Pick<Storage, 'getItem' | 'setItem'>;

/** Shelf items this character has ever held (browser-local, like the Codex's per-device memory). */
export function loadFound(store: Store | null, characterId: number): Set<string> {
  try {
    const raw = store?.getItem(foundKey(characterId));
    const list = raw ? (JSON.parse(raw) as unknown) : [];
    return new Set(Array.isArray(list) ? list.filter((x): x is string => typeof x === 'string' && SHELF_IDS.includes(x)) : []);
  } catch {
    return new Set();
  }
}

/** Adds every shelf item currently in the bag to the found set; returns the (possibly new) set and whether it grew. */
export function recordFound(store: Store | null, characterId: number, held: Iterable<string>): { found: Set<string>; grew: boolean } {
  const found = loadFound(store, characterId);
  const before = found.size;
  for (const id of held) if (SHELF_IDS.includes(id)) found.add(id);
  const grew = found.size > before;
  if (grew) {
    try { store?.setItem(foundKey(characterId), JSON.stringify([...found])); } catch { /* storage may be blocked */ }
  }
  return { found, grew };
}

/** UTC calendar day, so the pick is the same for everyone on the same day. */
export const dayKey = (now = Date.now()) => new Date(now).toISOString().slice(0, 10);

/** The Cauldron's brew of the day: a deterministic pick from the reagent brews (recipe id + brew item id). */
export function brewOfTheDay(day = dayKey()): { recipeId: string; brewId: string } {
  let h = 2166136261;
  for (let i = 0; i < day.length; i++) h = Math.imul(h ^ day.charCodeAt(i), 16777619) >>> 0;
  // Only the first eight (up to Alchemy 62): the epic elixirs need boss ichor, too rare for a daily pick.
  const pool = REAGENT_BREW_LIST.slice(0, 8);
  const [brewId, b] = pool[h % pool.length];
  return { recipeId: b.recipe.id, brewId };
}

/** True while today's bonus (one extra of the brew, the first time you brew it at the Wing each day) is unclaimed. */
export function bonusAvailable(store: Store | null, characterId: number, day = dayKey()): boolean {
  try { return store?.getItem(bonusKey(characterId)) !== day; } catch { return true; }
}
export function claimBonus(store: Store | null, characterId: number, day = dayKey()) {
  try { store?.setItem(bonusKey(characterId), day); } catch { /* ignore */ }
}
