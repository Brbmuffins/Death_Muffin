import { BREW_KEYS, type BrewSlot } from '../content/brews';

/**
 * The HUD belt (2026-10-02): three always-visible slots by the left edge, so a player can see where the healing potion
 * and the two brews live even before they own any. Pure rules, no DOM: WorldScene feeds it, HUD draws it.
 */
export type BeltSlotId = 'heal' | BrewSlot;
export const BELT_SLOT_IDS: BeltSlotId[] = ['heal', 'elixir', 'tonic'];
export const BELT_KEY: Record<BeltSlotId, string> = { heal: 'q', ...BREW_KEYS };

/** Healing flasks, best first: the order Q (and Auto) drinks them. */
export const HEAL_ORDER = ['flask_hp_grand', 'flask_hp_major', 'flask_hp_minor'];
/** Seconds between healing sips (WorldScene.flaskCdUntil). */
export const HEAL_COOLDOWN_S = 1.5;

/** The flask Q drinks now: the first of HEAL_ORDER the bag holds, or null. */
export function healPick(count: (id: string) => number): string | null {
  return HEAL_ORDER.find((id) => count(id) > 0) ?? null;
}

/** One line for an empty slot: how to fill it. */
export function emptyHint(id: BeltSlotId): string {
  if (id === 'heal') {
    return `Healing: no potions yet. Brew Moss Tonic from Mourning Moss in the Alchemist's Wing (east door of the Chapterhouse), or loot them from the dead. Press Q to drink one.`;
  }
  const kind = id === 'elixir' ? 'elixir' : 'tonic';
  return `Empty ${kind} slot. Click it to pick ${id === 'elixir' ? 'an' : 'a'} ${kind} from your bag, or drag one here from the Reliquary. Brew them in the Alchemist's Wing. Press ${BREW_KEY_LABEL[id]} to drink it.`;
}
const BREW_KEY_LABEL: Record<BrewSlot, string> = { elixir: 'Z', tonic: 'X' };

/** The short floating line when a player presses an empty slot (the toast carries emptyHint). */
export function emptyPressText(id: BeltSlotId): string {
  return id === 'heal' ? 'No healing potions' : `Empty ${id} slot`;
}

export type BeltState = 'empty' | 'ready' | 'active' | 'cooling';
export function beltState(o: { hasItem: boolean; active?: boolean; cooling?: boolean }): BeltState {
  if (o.active) return 'active';
  if (o.cooling && o.hasItem) return 'cooling';
  return o.hasItem ? 'ready' : 'empty';
}
