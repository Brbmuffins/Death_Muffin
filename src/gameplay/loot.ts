import { AREAS, type AreaId } from '../content/areas';
import { ELITE, ENEMIES, type EnemyId } from '../content/enemies';
import { ITEMS } from '../content/items';
import { waveModifiers } from '../content/upgrades';
import { saveInventory } from '../net/api';
import type { InventorySlot } from '../net/types';
import { pickWeighted, randInt } from './rng';
import { DIFFICULTIES, type Difficulty } from '../content/difficulty';

export const BAG_COLS = 6;
export const BAG_ROWS = 4;
export const BAG_SIZE = BAG_COLS * BAG_ROWS; // matches Unity's 4×6 bag

export interface LootDrop {
  item_id: string;
  quantity: number;
}

export interface KillReward {
  gold: number;
  shards: number;
  items: LootDrop[];
  xp: number;
}

/**
 * Per-player reward roll for a kill (personal loot: every party member near the
 * kill rolls their own — no contention, PvE-only assumption). Item ids are
 * restricted to ids the live server knows (content/items.ts).
 */
export function rollKill(def: EnemyId, area: AreaId, level: number, elite: boolean, waveTier: number, rand = Math.random, difficulty: Difficulty = 'medium', itemChanceMult = 1): KillReward {
  const d = ENEMIES[def];
  const a = AREAS[area];
  const mods = waveModifiers(waveTier);
  const diff = DIFFICULTIES[difficulty].rewardMult;
  const levelMult = 1 + 0.15 * (level - 1);
  const gold = Math.round(randInt(rand, d.gold[0], d.gold[1]) * levelMult * mods.rewardMult * diff * (elite ? ELITE.goldMult : 1));
  const shards = elite ? (rand() < 0.25 ? 2 : 1) : 0;
  const items: LootDrop[] = [];
  const chance = Math.min(1, a.itemChance * mods.itemChanceMult * itemChanceMult * (elite ? 6 : 1));
  if (a.loot.length && rand() < chance) items.push(rollItem(area, rand));
  const xp = Math.round(d.xp * (1 + 0.25 * (level - 1)) * diff * (elite ? ELITE.xpMult : 1));
  return { gold, shards, items, xp };
}

export function rollItem(area: AreaId, rand = Math.random): LootDrop {
  const pick = pickWeighted(AREAS[area].loot, rand())!;
  const meta = ITEMS[pick.item];
  return { item_id: pick.item, quantity: meta?.type === 'material' ? 1 + (rand() < 0.35 ? 1 : 0) : 1 };
}

/**
 * A boss's spoils. The Prelate's are unchanged (Sanctum loot, 3 shards back); an area boss rolls its own area's
 * loot and scales gold/XP by its shard cost (2/3/4 of the Prelate's 5) and returns fewer shards.
 */
export function rollBoss(waveTier: number, rand = Math.random, difficulty: Difficulty = 'medium', area: AreaId = 'sanctum', costShards = 5): KillReward {
  const mods = waveModifiers(waveTier);
  const diff = DIFFICULTIES[difficulty].rewardMult;
  const k = costShards / 5;
  const items = [rollItem(area, rand), rollItem(area, rand), rollItem(area, rand)];
  return { gold: Math.round(320 * k * mods.rewardMult * diff), shards: costShards >= 5 ? 3 : Math.max(1, costShards - 1), items, xp: Math.round(900 * k * diff) };
}

/** A boss's first kill per character: a guaranteed rare-or-better item from ids the server knows. */
export function rollFirstKillItem(area: AreaId, rand = Math.random): LootDrop {
  for (let i = 0; i < 30; i++) {
    const d = rollItem(area, rand);
    const r = ITEMS[d.item_id]?.rarity;
    if (r === 'rare' || r === 'epic') return d;
  }
  // Some early areas have no rare entry in their weighted table. Keep the historical rare helm
  // fallback there; never grant a late-area set piece from the global catalog on a first kill.
  const rares = AREAS[area].loot.map((entry) => entry.item).filter((id) => {
    const m = ITEMS[id];
    return m && m.type !== 'material' && (m.rarity === 'rare' || m.rarity === 'epic');
  });
  return { item_id: rares[Math.floor(rand() * rares.length)] ?? 'helm_gold', quantity: 1 };
}

/**
 * Adds a drop to a slot array: stacks onto an existing slot of the same item
 * (materials), otherwise takes the first free slot_index. Returns null when
 * the bag is full.
 */
export function addToSlots(slots: InventorySlot[], drop: LootDrop): InventorySlot[] | null {
  const meta = ITEMS[drop.item_id];
  const cap = meta?.stack ?? Infinity;
  const stack = slots.find((s) => s.item_id === drop.item_id && (s.item_type === 'material' || meta?.type === 'material') && s.quantity < cap);
  if (stack) {
    const add = Math.min(drop.quantity, cap - stack.quantity);
    const next = slots.map((s) => (s === stack ? { ...s, quantity: s.quantity + add } : s));
    return add >= drop.quantity ? next : addToSlots(next, { ...drop, quantity: drop.quantity - add });
  }
  const used = new Set(slots.map((s) => s.slot_index));
  let free = -1;
  for (let i = 0; i < BAG_SIZE; i++) {
    if (!used.has(i)) {
      free = i;
      break;
    }
  }
  if (free === -1) return null;
  if (drop.quantity > cap) {
    const placed = addToSlots(slots, { ...drop, quantity: cap });
    return placed && addToSlots(placed, { ...drop, quantity: drop.quantity - cap });
  }
  return [
    ...slots,
    {
      // Joined item fields come back from the server on save; local placeholders until then.
      id: 0,
      slot_index: free,
      quantity: Math.min(drop.quantity, cap),
      equipped: 0,
      item_id: drop.item_id,
      name: meta?.name ?? drop.item_id,
      rarity: meta?.rarity ?? 'common',
      item_type: meta?.type ?? 'material',
      stat_bonus: meta?.offlineStats ?? null,
      icon_id: null,
      sell_value: meta?.sell ?? 0,
      crafted: 0,
    },
  ];
}

/** Payload shape for POST /api/inventory/save. */
/**
 * The save endpoint owns the bag only (slot_index 0..BAG_SIZE-1). Equipped gear lives in reserved
 * slots (100+) that /api/inventory/equip manages, so it is never sent back: one equipped item used to
 * make every save fail with "each slot_index must be between 0 and 23".
 */
export function toSavePayload(slots: InventorySlot[]) {
  return slots.filter((s) => s.slot_index >= 0 && s.slot_index < BAG_SIZE).map((s) => ({
    slot_index: s.slot_index,
    item_id: s.item_id,
    quantity: s.quantity,
    equipped: s.equipped,
  }));
}

export type InventorySaveState = 'saved' | 'saving' | 'retrying';
type InventoryMutation = ({ kind: 'add'; drop: LootDrop } | { kind: 'consume'; itemId: string }) & { countAfter: number };

function itemCount(slots: InventorySlot[], itemId: string) {
  return slots.filter((s) => s.item_id === itemId).reduce((n, s) => n + s.quantity, 0);
}

function applyInventoryMutation(slots: InventorySlot[], mutation: InventoryMutation): InventorySlot[] | null {
  if (mutation.kind === 'add') return addToSlots(slots, mutation.drop);
  const slot = slots.find((s) => s.item_id === mutation.itemId && s.quantity > 0);
  // The server may already have removed it (for example as a crafting cost).
  if (!slot) return slots;
  return slots.map((s) => (s === slot ? { ...s, quantity: s.quantity - 1 } : s)).filter((s) => s.quantity > 0);
}

/** An in-flight save may already be reflected in another server reply. */
function reconcileInFlightMutation(slots: InventorySlot[], mutation: InventoryMutation): InventorySlot[] | null {
  const itemId = mutation.kind === 'add' ? mutation.drop.item_id : mutation.itemId;
  const count = itemCount(slots, itemId);
  if (mutation.kind === 'add') {
    const missing = Math.min(mutation.drop.quantity, Math.max(0, mutation.countAfter - count));
    return missing ? addToSlots(slots, { ...mutation.drop, quantity: missing }) : slots;
  }
  return count > mutation.countAfter ? applyInventoryMutation(slots, mutation) : slots;
}

/**
 * Owns the bag. Pickups merge immediately (optimistic) and flush to the server
 * in debounced batches — a horde of drops is one POST, not twenty. Failed
 * saves keep the local state and retry with backoff.
 */
export class Inventory {
  private slots: InventorySlot[] = [];
  private dirty = false;
  private timer = 0;
  private inFlight = false;
  private retryDelay = 3000;
  /** Local changes that a server response may not yet include. */
  private pendingMutations: InventoryMutation[] = [];
  private inFlightMutations: InventoryMutation[] = [];
  state: InventorySaveState = 'saved';
  private listeners = new Set<(slots: InventorySlot[]) => void>();

  constructor(private characterId: number) {}

  get all() {
    return this.slots;
  }

  onChange(fn: (slots: InventorySlot[]) => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit() {
    this.listeners.forEach((fn) => fn(this.slots));
  }

  /** Server responses (load, equip, craft) are the source of truth. */
  replace(slots: InventorySlot[]) {
    if (this.dirty || this.inFlight) {
      // Equip and craft replies can arrive after a pickup or flask use. Replay
      // those local changes before the next save instead of dropping them.
      let merged = slots;
      for (const mutation of this.inFlightMutations) {
        const next = reconcileInFlightMutation(merged, mutation);
        if (!next) {
          this.scheduleFlush(300);
          return;
        }
        merged = next;
      }
      for (const mutation of this.pendingMutations) {
        const next = applyInventoryMutation(merged, mutation);
        if (!next) {
          // The server bag may have filled while the request flew. Keep the
          // local bag so a pickup is never silently discarded.
          this.scheduleFlush(300);
          return;
        }
        merged = next;
      }
      this.slots = merged;
      this.dirty = true;
      this.scheduleFlush(300);
    } else this.slots = slots;
    this.emit();
  }

  add(drop: LootDrop): boolean {
    const next = addToSlots(this.slots, drop);
    if (!next) return false;
    this.slots = next;
    this.pendingMutations.push({ kind: 'add', drop: { ...drop }, countAfter: itemCount(next, drop.item_id) });
    this.dirty = true;
    this.emit();
    this.scheduleFlush(1500);
    return true;
  }

  count(itemId: string) {
    return this.slots.filter((s) => s.item_id === itemId).reduce((n, s) => n + s.quantity, 0);
  }

  consume(itemId: string): boolean {
    const slot = this.slots.find((s) => s.item_id === itemId && s.quantity > 0);
    if (!slot) return false;
    this.slots = this.slots
      .map((s) => (s === slot ? { ...s, quantity: s.quantity - 1 } : s))
      .filter((s) => s.quantity > 0);
    this.pendingMutations.push({ kind: 'consume', itemId, countAfter: this.count(itemId) });
    this.dirty = true;
    this.emit();
    this.scheduleFlush(1500);
    return true;
  }

  private scheduleFlush(ms: number) {
    window.clearTimeout(this.timer);
    this.timer = window.setTimeout(() => void this.flush(), ms);
  }

  /** Saves held while a server-side bag change (craft, equip) runs; see exclusive(). */
  private held = 0;

  /**
   * Run a server-side bag change with no save in flight. Saves overwrite the whole bag, so a save racing a craft
   * or equip could write spent ingredients back (duplicating them). This waits for any in-flight save, pushes
   * pending pickups, then holds saves until `fn` (which should re-read the bag and call replace()) is done.
   * Pickups made meanwhile replay on top of the fresh bag.
   */
  async exclusive<T>(fn: () => Promise<T>): Promise<T> {
    const settle = async () => {
      const deadline = performance.now() + 15000;
      while (this.inFlight) {
        if (performance.now() > deadline) throw new Error('Your items are still saving. Please try again.');
        await new Promise<void>((resolve) => window.setTimeout(resolve, 50));
      }
    };
    await settle();
    await this.flush();
    await settle();
    this.held++;
    try {
      return await fn();
    } finally {
      this.held--;
      if (this.dirty && !this.held) this.scheduleFlush(300);
    }
  }

  async flush(): Promise<void> {
    if (!this.dirty || this.inFlight || this.held) return;
    this.inFlight = true;
    this.dirty = false;
    this.state = 'saving';
    const sent = this.slots;
    const sentMutations = this.pendingMutations;
    this.pendingMutations = [];
    this.inFlightMutations = sentMutations;
    try {
      const saved = await saveInventory(this.characterId, toSavePayload(sent));
      // Only adopt the server rows if nothing changed while the request flew.
      if (this.slots === sent) this.slots = saved;
      else this.dirty = true;
      this.retryDelay = 3000;
      this.state = 'saved';
      this.inFlightMutations = [];
    } catch (err) {
      console.warn('[inventory] save failed, will retry', err);
      this.dirty = true;
      this.state = 'retrying';
      this.pendingMutations = [...sentMutations, ...this.pendingMutations];
      this.inFlightMutations = [];
      this.retryDelay = Math.min(60000, this.retryDelay * 2);
    } finally {
      this.inFlight = false;
      this.emit();
      if (this.dirty) this.scheduleFlush(this.state === 'retrying' ? this.retryDelay : 800);
    }
  }

  async saveBeforeClassChange() {
    const deadline = performance.now() + 15000;
    while (this.inFlight) {
      if (performance.now() > deadline) throw new Error('Your items are still saving. Please try again.');
      await new Promise<void>((resolve) => window.setTimeout(resolve, 50));
    }
    await this.flush();
    if (this.dirty || this.state === 'retrying') throw new Error('Could not save your items. Please try again before changing class.');
  }

  dispose() {
    window.clearTimeout(this.timer);
    void this.flush();
    this.listeners.clear();
  }
}
