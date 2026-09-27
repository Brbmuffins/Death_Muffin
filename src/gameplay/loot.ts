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
export function rollKill(def: EnemyId, area: AreaId, level: number, elite: boolean, waveTier: number, rand = Math.random, difficulty: Difficulty = 'medium'): KillReward {
  const d = ENEMIES[def];
  const a = AREAS[area];
  const mods = waveModifiers(waveTier);
  const diff = DIFFICULTIES[difficulty].rewardMult;
  const levelMult = 1 + 0.15 * (level - 1);
  const gold = Math.round(randInt(rand, d.gold[0], d.gold[1]) * levelMult * mods.rewardMult * diff * (elite ? ELITE.goldMult : 1));
  const shards = elite ? (rand() < 0.25 ? 2 : 1) : 0;
  const items: LootDrop[] = [];
  const chance = Math.min(1, a.itemChance * mods.itemChanceMult * (elite ? 6 : 1));
  if (a.loot.length && rand() < chance) items.push(rollItem(area, rand));
  const xp = Math.round(d.xp * (1 + 0.25 * (level - 1)) * diff * (elite ? ELITE.xpMult : 1));
  return { gold, shards, items, xp };
}

export function rollItem(area: AreaId, rand = Math.random): LootDrop {
  const pick = pickWeighted(AREAS[area].loot, rand())!;
  const meta = ITEMS[pick.item];
  return { item_id: pick.item, quantity: meta?.type === 'material' ? 1 + (rand() < 0.35 ? 1 : 0) : 1 };
}

export function rollBoss(waveTier: number, rand = Math.random, difficulty: Difficulty = 'medium'): KillReward {
  const mods = waveModifiers(waveTier);
  const diff = DIFFICULTIES[difficulty].rewardMult;
  const items = [rollItem('sanctum', rand), rollItem('sanctum', rand), rollItem('sanctum', rand)];
  return { gold: Math.round(320 * mods.rewardMult * diff), shards: 3, items, xp: Math.round(900 * diff) };
}

/**
 * Adds a drop to a slot array: stacks onto an existing slot of the same item
 * (materials), otherwise takes the first free slot_index. Returns null when
 * the bag is full.
 */
export function addToSlots(slots: InventorySlot[], drop: LootDrop): InventorySlot[] | null {
  const meta = ITEMS[drop.item_id];
  const stack = slots.find((s) => s.item_id === drop.item_id && (s.item_type === 'material' || meta?.type === 'material'));
  if (stack) return slots.map((s) => (s === stack ? { ...s, quantity: s.quantity + drop.quantity } : s));
  const used = new Set(slots.map((s) => s.slot_index));
  let free = -1;
  for (let i = 0; i < BAG_SIZE; i++) {
    if (!used.has(i)) {
      free = i;
      break;
    }
  }
  if (free === -1) return null;
  return [
    ...slots,
    {
      // Joined item fields come back from the server on save; local placeholders until then.
      id: 0,
      slot_index: free,
      quantity: drop.quantity,
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
export function toSavePayload(slots: InventorySlot[]) {
  return slots.map((s) => ({
    slot_index: s.slot_index,
    item_id: s.item_id,
    quantity: s.quantity,
    equipped: s.equipped,
  }));
}

export type InventorySaveState = 'saved' | 'saving' | 'retrying';

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
      // Keep unsaved pickups: re-apply the local delta on top later via flush.
      this.slots = slots;
      this.scheduleFlush(300);
    } else this.slots = slots;
    this.emit();
  }

  add(drop: LootDrop): boolean {
    const next = addToSlots(this.slots, drop);
    if (!next) return false;
    this.slots = next;
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
    this.dirty = true;
    this.emit();
    this.scheduleFlush(1500);
    return true;
  }

  private scheduleFlush(ms: number) {
    window.clearTimeout(this.timer);
    this.timer = window.setTimeout(() => void this.flush(), ms);
  }

  async flush(): Promise<void> {
    if (!this.dirty || this.inFlight) return;
    this.inFlight = true;
    this.dirty = false;
    this.state = 'saving';
    const sent = this.slots;
    try {
      const saved = await saveInventory(this.characterId, toSavePayload(sent));
      // Only adopt the server rows if nothing changed while the request flew.
      if (this.slots === sent) this.slots = saved;
      else this.dirty = true;
      this.retryDelay = 3000;
      this.state = 'saved';
    } catch (err) {
      console.warn('[inventory] save failed, will retry', err);
      this.dirty = true;
      this.state = 'retrying';
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
