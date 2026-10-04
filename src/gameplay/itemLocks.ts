import type { InventorySlot } from '../net/types';
import { browserStorage, type StorageLike } from './codexJournal';
import { isSalvageGear } from './salvageRules';
import { affixIsNecro } from './affixRules';

/**
 * Reliquary locks: a locked bag item is skipped by every bulk action (Sell all junk, Deposit materials and Deposit all, Salvage all).
 * Browser-local and per character (a convenience, not progress), stored through browserStorage() so the offline edition namespaces
 * it, and guarded so the lock list simply starts empty when storage is unavailable.
 *
 * A lock is the pair slot + item id: if the item in that slot changes (sold, moved, salvaged), the lock quietly lapses instead of
 * landing on whatever fills the slot next.
 */
export const locksStorageKey = (characterId: number) => `dm_locks_v1_${characterId}`;

export class ItemLocks {
  private locked = new Map<number, string>();
  private listeners = new Set<() => void>();
  private key: string;

  constructor(characterId: number, private storage: StorageLike | null = browserStorage()) {
    this.key = locksStorageKey(characterId);
    try {
      const raw = this.storage?.getItem(this.key);
      const list = raw ? (JSON.parse(raw) as unknown) : [];
      if (Array.isArray(list)) for (const e of list) if (Array.isArray(e) && Number.isInteger(e[0]) && typeof e[1] === 'string') this.locked.set(e[0], e[1]);
    } catch {
      /* start empty */
    }
  }

  isLocked(slot: Pick<InventorySlot, 'slot_index' | 'item_id'>): boolean {
    return this.locked.get(slot.slot_index) === slot.item_id;
  }

  /** Slot indexes of the locked items, for the server's `exceptSlots`. */
  slotsOf(slots: InventorySlot[]): number[] {
    return slots.filter((s) => this.isLocked(s)).map((s) => s.slot_index);
  }

  toggle(slot: Pick<InventorySlot, 'slot_index' | 'item_id'>): boolean {
    const now = !this.isLocked(slot);
    if (now) this.locked.set(slot.slot_index, slot.item_id);
    else this.locked.delete(slot.slot_index);
    this.save();
    return now;
  }

  /** Follow items that changed slot (old index -> new index). */
  remap(moves: Map<number, number>) {
    const next = new Map<number, string>();
    for (const [index, id] of this.locked) {
      const to = moves.get(index);
      if (to !== undefined) next.set(to, id);
    }
    this.locked = next;
    this.save();
  }

  /** Drop locks whose slot no longer holds that item (call on every bag change). */
  prune(slots: InventorySlot[]) {
    let changed = false;
    for (const [index, id] of [...this.locked]) {
      if (!slots.some((s) => s.slot_index === index && s.item_id === id)) {
        this.locked.delete(index);
        changed = true;
      }
    }
    if (changed) this.save();
  }

  onChange(fn: () => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private save() {
    try {
      this.storage?.setItem(this.key, JSON.stringify([...this.locked]));
    } catch {
      /* storage unavailable: locks last for this session only */
    }
    this.listeners.forEach((fn) => fn());
  }
}

const SELL_JUNK_RARITIES = ['common', 'uncommon'];

/** A rolled piece with a necromancer affix is never bulk-sold or bulk-salvaged: that is the roll people are hunting. */
const hasNecroAffix = (s: InventorySlot) => !!s.inst && s.inst.affixes.some(affixIsNecro);

/** The bag slots "Sell all junk" would sell: unlocked, unequipped common and uncommon gear that has a sell value (and no necromancer affix). `keep` spares what is worth wearing (see keepsForYou). */
export function junkSlots(slots: InventorySlot[], locks: Pick<ItemLocks, 'isLocked'>, keep?: (s: InventorySlot) => boolean): InventorySlot[] {
  return slots.filter((s) => !s.equipped && s.slot_index >= 0 && s.slot_index < 100 && isSalvageGear(s.item_type) && SELL_JUNK_RARITIES.includes(s.rarity) && s.sell_value > 0 && !locks.isLocked(s) && !hasNecroAffix(s) && !keep?.(s));
}

/** Gear the Bone Grinder's "Salvage all below rare" takes: unlocked, unequipped common and uncommon gear. */
export function salvageBelowRare(slots: InventorySlot[], locks: Pick<ItemLocks, 'isLocked'>, keep?: (s: InventorySlot) => boolean): InventorySlot[] {
  return slots.filter((s) => !s.equipped && s.slot_index >= 0 && s.slot_index < 100 && isSalvageGear(s.item_type) && SELL_JUNK_RARITIES.includes(s.rarity) && !locks.isLocked(s) && !hasNecroAffix(s) && !keep?.(s));
}
