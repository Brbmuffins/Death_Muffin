import { AREAS, type AreaId } from '../content/areas';
import { ELITE, ENEMIES, type EnemyId } from '../content/enemies';
import { ITEMS } from '../content/items';
import { waveModifiers } from '../content/upgrades';
import { saveInventory } from '../net/api';
import type { InventorySlot } from '../net/types';
import { BAG_SLOTS } from './gatheringRules';
import { decorateSlot, type DropInstance } from './affixes';
import { pickWeighted, randInt } from './rng';
import { smartTable } from './smartLoot';
import { ARMOR_BY_ID } from '../content/armorSets';
import { DIFFICULTIES, type Difficulty } from '../content/difficulty';
import { AREA_REAGENT_DROPS, ELITE_REAGENT_MULT, ENEMY_REAGENT_DROPS, bossIchor } from '../content/reagents';
import type { BossId } from '../content/bosses';
import { AREA_RUNE_POOL, BOSS_REPEAT_RUNE_CHANCE, BOSS_RUNE_POOL, ELITE_RUNE_CHANCE, SURGE_RUNE_CHANCE, pickRune } from '../content/runes';
import { LEGENDARY_DROP, legendaryBossChance, rollLegendary } from '../content/legendarySets';

/** One source of truth: gatheringRules.BAG_SLOTS (also bundled for the server). 8 columns × 6 rows = 48. */
export const BAG_SIZE = BAG_SLOTS;
export const BAG_COLS = 8;
export const BAG_ROWS = BAG_SIZE / BAG_COLS;

export interface LootDrop {
  item_id: string;
  quantity: number;
  /** The server's roll for a piece of gear (item level and affixes), attached by LootRoller before the drop lands on the ground. */
  instance?: DropInstance;
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
/**
 * Ordinary kills drop less, but what drops is worth more (owner, 2026-10-02: "keep it valuable, it's just a lot"): half the
 * area-table rolls, material stacks doubled so material income holds, and the client rolls that gear at elite quality
 * (WorldScene.onKill). Elites, bosses, runes, reagents and legendaries are unchanged. Gold keeps its total but lands as one
 * pile every `goldEveryKills` kills (and on every elite).
 */
export const KILL_LOOT = { itemChanceMult: 0.5, materialQtyMult: 2, goldEveryKills: 4 } as const;

export function rollKill(def: EnemyId, area: AreaId, level: number, elite: boolean, waveTier: number, rand = Math.random, difficulty: Difficulty = 'medium', itemChanceMult = 1, reagentRand: () => number = Math.random, runeRand: () => number = Math.random, disciplineId?: string, ownedIds?: () => ReadonlySet<string>): KillReward {
  const d = ENEMIES[def];
  const a = AREAS[area];
  const mods = waveModifiers(waveTier);
  const diff = DIFFICULTIES[difficulty].rewardMult;
  const levelMult = 1 + 0.15 * (level - 1);
  const gold = Math.round(randInt(rand, d.gold[0], d.gold[1]) * levelMult * mods.rewardMult * diff * (elite ? ELITE.goldMult : 1));
  const shards = elite ? (rand() < 0.25 ? 2 : 1) : 0;
  const items: LootDrop[] = [];
  const chance = Math.min(1, a.itemChance * mods.itemChanceMult * itemChanceMult * (elite ? 6 : KILL_LOOT.itemChanceMult));
  if (a.loot.length && rand() < chance) items.push(rollItem(area, rand, elite ? 1 : KILL_LOOT.materialQtyMult, disciplineId));
  // Legendary armor (content/legendarySets.ts): a very rare elite drop in the level-scaled areas, weighted to the player's discipline.
  // Rolled only when a discipline is passed, so seeded runs (balance harness, tests) keep their sequence.
  if (disciplineId && elite && a.scaling) {
    const id = rollLegendary(disciplineId, LEGENDARY_DROP.eliteChance, rand, ownedIds);
    if (id) items.push({ item_id: id, quantity: 1 });
  }
  // Reagents use their own stream: a seeded `rand` (balance harness, tests) keeps the same sequence it always had.
  items.push(...rollReagents(def, area, elite, itemChanceMult, reagentRand));
  // Relic runes (content/runes.ts): a small chance from elites, on their own stream so seeded harness runs keep every other roll.
  if (elite) {
    const rune = rollEliteRune(area, itemChanceMult * mods.itemChanceMult, runeRand);
    if (rune) items.push(rune);
  }
  const xp = Math.round(d.xp * (1 + 0.25 * (level - 1)) * mods.xpMult * diff * (elite ? ELITE.xpMult : 1));
  return { gold, shards, items, xp };
}

/**
 * Reagent drops (content/reagents.ts): independent of the area loot roll, per area and per enemy kind. Elites roll more
 * often, a fortune tonic helps, and nothing is rolled (no rand consumed) where no reagent can drop.
 */
export function rollReagents(def: EnemyId, area: AreaId, elite: boolean, itemChanceMult = 1, rand = Math.random): LootDrop[] {
  const specs = [...(AREA_REAGENT_DROPS[area] ?? []), ...(ENEMY_REAGENT_DROPS[def] ?? [])];
  const out: LootDrop[] = [];
  for (const s of specs) {
    if (rand() >= Math.min(1, s.chance * itemChanceMult * (elite ? ELITE_REAGENT_MULT : 1))) continue;
    out.push({ item_id: s.item, quantity: randInt(rand, s.qty[0], s.qty[1]) });
  }
  return out;
}

/** An elite's rune: ELITE_RUNE_CHANCE (times the item-chance multipliers), from the area's pool; null where the ground sheds none. */
export function rollEliteRune(area: AreaId, itemChanceMult = 1, rand: () => number = Math.random): LootDrop | null {
  const pool = AREA_RUNE_POOL[area];
  if (!pool?.length || rand() >= Math.min(1, ELITE_RUNE_CHANCE * itemChanceMult)) return null;
  const id = pickRune(pool, rand);
  return id ? { item_id: id, quantity: 1 } : null;
}

/** A Grave Surge's offering: the area's item, or (SURGE_RUNE_CHANCE) a rune from the area's pool in its place. */
export function rollSurgeItem(area: AreaId, rand: () => number = Math.random, disciplineId?: string): LootDrop {
  const pool = AREA_RUNE_POOL[area];
  if (pool?.length && rand() < SURGE_RUNE_CHANCE) {
    const id = pickRune(pool, rand);
    if (id) return { item_id: id, quantity: 1 };
  }
  return rollItem(area, rand, 1, disciplineId);
}

/**
 * A boss's rune: the Prelate always leaves one and so does a boss's first kill per character (`first`); repeats roll
 * BOSS_REPEAT_RUNE_CHANCE. Drawn from that boss's own pool (BOSS_RUNE_POOL).
 */
export function rollBossRune(boss: BossId, first: boolean, rand: () => number = Math.random): LootDrop | null {
  const pool = BOSS_RUNE_POOL[boss];
  if (!pool?.length) return null;
  if (!(boss === 'prelate' || first) && rand() >= BOSS_REPEAT_RUNE_CHANCE) return null;
  const id = pickRune(pool, rand);
  return id ? { item_id: id, quantity: 1 } : null;
}

export function rollItem(area: AreaId, rand = Math.random, materialQtyMult = 1, disciplineId?: string): LootDrop {
  const pick = pickWeighted(disciplineId ? smartTable(area, disciplineId) : AREAS[area].loot, rand())!;
  const meta = ITEMS[pick.item];
  return { item_id: pick.item, quantity: meta?.type === 'material' ? (1 + (rand() < 0.35 ? 1 : 0)) * materialQtyMult : 1 };
}

export { SMART_LOOT, smartTable } from './smartLoot';

/**
 * A boss's spoils. The Prelate's are unchanged (Sanctum loot, 3 shards back); an area boss rolls its own area's
 * loot and scales gold/XP by its shard cost (2/3/4 of the Prelate's 5) and returns fewer shards. Pass the boss id and
 * the spoils always include its ichor.
 */
export function rollBoss(waveTier: number, rand = Math.random, difficulty: Difficulty = 'medium', area: AreaId = 'sanctum', costShards = 5, boss?: BossId, disciplineId?: string, ownedIds?: () => ReadonlySet<string>): KillReward {
  const mods = waveModifiers(waveTier);
  const diff = DIFFICULTIES[difficulty].rewardMult;
  const k = costShards / 5;
  const items = [rollItem(area, rand, 1, disciplineId), rollItem(area, rand, 1, disciplineId), rollItem(area, rand, 1, disciplineId)];
  // Legendary armor: every area boss has a chance (15%; the Gravedigger King 3%), weighted to the player's discipline ("smart loot").
  if (disciplineId && legendaryBossChance(area) > 0) {
    const id = rollLegendary(disciplineId, legendaryBossChance(area), rand, ownedIds);
    if (id) items.push({ item_id: id, quantity: 1 });
  }
  // Every boss leaves exactly one ichor: the top-tier Alchemy reagent (content/reagents.ts).
  if (boss) items.push({ item_id: bossIchor(boss), quantity: 1 });
  return { gold: Math.round(320 * k * mods.rewardMult * diff), shards: costShards >= 5 ? 3 : Math.max(1, costShards - 1), items, xp: Math.round(900 * k * diff) };
}

/** A boss's first kill per character: a guaranteed rare-or-better item from ids the server knows. */
export function rollFirstKillItem(area: AreaId, rand = Math.random, disciplineId?: string): LootDrop {
  // A trophy is meant to be worn: when the area drops rare-or-better armour of the player's own set, three times in four it is one of those.
  if (disciplineId) {
    const own = AREAS[area].loot.map((e) => e.item).filter((id) => ARMOR_BY_ID[id]?.disciplineId === disciplineId && (ITEMS[id]?.rarity === 'rare' || ITEMS[id]?.rarity === 'epic'));
    if (own.length && rand() < 0.75) return { item_id: own[Math.floor(rand() * own.length)], quantity: 1 };
  }
  for (let i = 0; i < 30; i++) {
    const d = rollItem(area, rand, 1, disciplineId);
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
  const stackable = (type?: string) => type === 'material' || type === 'rune';
  // Gear never stacks on the server (max_stack_size 1, migration 018): a quantity above 1 spreads over slots instead of looping on a 400.
  const cap = meta?.stack ?? (meta && !stackable(meta.type) ? 1 : Infinity);
  const stack = slots.find((s) => s.item_id === drop.item_id && s.slot_index < BAG_SIZE && !s.equipped && (stackable(s.item_type) || stackable(meta?.type)) && s.quantity < cap);
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
    decorateSlot({
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
      // A rolled piece keeps the server's roll from the moment it is picked up (the save names it by id).
      ...(drop.instance ? { instance_id: drop.instance.id, ilvl: drop.instance.ilvl, affixes: drop.instance.affixes } : {}),
    }),
  ];
}

/** Payload shape for POST /api/inventory/save. */
/**
 * The save endpoint owns the bag only (slot_index 0..BAG_SIZE-1). Equipped gear lives in reserved
 * slots (100+) that /api/inventory/equip manages, so it is never sent back: one equipped item used to
 * make every save fail with "each slot_index must be between 0 and 23" (when the bag grew).
 */
export function toSavePayload(slots: InventorySlot[]) {
  return slots.filter((s) => s.slot_index >= 0 && s.slot_index < BAG_SIZE).map((s) => ({
    slot_index: s.slot_index,
    item_id: s.item_id,
    quantity: s.quantity,
    equipped: s.equipped,
    // Only the id of a roll the server made: the server rejects anything it did not mint for this account.
    instance_id: s.instance_id ?? null,
  }));
}

export type InventorySaveState = 'saved' | 'saving' | 'retrying';
type InventoryMutation = ({ kind: 'add'; drop: LootDrop } | { kind: 'consume'; itemId: string; slot?: number }) & { countAfter: number };

function itemCount(slots: InventorySlot[], itemId: string) {
  return slots.filter((s) => s.item_id === itemId).reduce((n, s) => n + s.quantity, 0);
}

function applyInventoryMutation(slots: InventorySlot[], mutation: InventoryMutation): InventorySlot[] | null {
  if (mutation.kind === 'add') return addToSlots(slots, mutation.drop);
  // A slot-specific consume (selling one copy of several) replays on that same slot, so a locked twin is never taken instead.
  // Only bag rows can be replayed on: worn gear, belt tools and sockets (slot 100+) are not part of a bag save.
  const inBag = (s: InventorySlot) => s.slot_index >= 0 && s.slot_index < BAG_SIZE && !s.equipped;
  const slot = (mutation.slot !== undefined ? slots.find((s) => s.slot_index === mutation.slot && s.item_id === mutation.itemId && s.quantity > 0 && inBag(s)) : undefined)
    ?? slots.find((s) => s.item_id === mutation.itemId && s.quantity > 0 && inBag(s));
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

  /** Consume one unit from a specific bag slot (selling one copy of several, with a locked twin elsewhere). */
  consumeAt(slotIndex: number): boolean {
    const slot = this.slots.find((s) => s.slot_index === slotIndex && s.quantity > 0 && !s.equipped);
    if (!slot) return false;
    this.slots = this.slots.map((s) => (s === slot ? { ...s, quantity: s.quantity - 1 } : s)).filter((s) => s.quantity > 0);
    this.pendingMutations.push({ kind: 'consume', itemId: slot.item_id, slot: slotIndex, countAfter: this.count(slot.item_id) });
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

  /**
   * A server action that moves items through the bag (deliver, harvest, collect, adopt): run it under exclusive(), then re-read the
   * bag. The action has already happened on the server by the time the bag is re-read, so its reply is returned even when the
   * re-read fails (`bagStale`): throwing there would drop the reply, and the panel would keep showing an order or plot the server
   * has already filled. The next successful bag read puts the bag right.
   */
  async exclusiveAction<T>(act: () => Promise<T>, readBag: () => Promise<InventorySlot[]>): Promise<{ reply: T; bagStale: boolean }> {
    return this.exclusive(async () => {
      const reply = await act();
      try {
        this.replace(await readBag());
        return { reply, bagStale: false };
      } catch (err) {
        console.warn('[inventory] bag re-read failed after a server action', err);
        return { reply, bagStale: true };
      }
    });
  }

  async flush(keepalive = false): Promise<void> {
    if (!this.dirty || this.held) return;
    if (this.inFlight) {
      // The tab is closing with a save already out (it may be cut off): send the newest bag now rather than skip it.
      if (!keepalive) return;
      this.dirty = false;
      try {
        await saveInventory(this.characterId, toSavePayload(this.slots), BAG_SIZE, true);
      } catch {
        this.dirty = true;
      }
      return;
    }
    this.inFlight = true;
    this.dirty = false;
    this.state = 'saving';
    const sent = this.slots;
    const sentMutations = this.pendingMutations;
    this.pendingMutations = [];
    this.inFlightMutations = sentMutations;
    try {
      const saved = await (keepalive ? saveInventory(this.characterId, toSavePayload(sent), BAG_SIZE, true) : saveInventory(this.characterId, toSavePayload(sent), BAG_SIZE));
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
