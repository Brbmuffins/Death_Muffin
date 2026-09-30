import { COMPOST_SPEED, PLOTS, seedDef, type PlotDef, type SeedDef } from '../content/gardening';

export { COMPOST_ITEM, PLOTS, SEEDS, seedDef } from '../content/gardening';
export { GARDEN_PET_CHANCE, petForSkill } from '../content/cosmetics';

/**
 * Grave Gardening rules, shared by the client (panel + offline mock) and the Death Muffin backend (`npm run build:server-rules`
 * bundles this into gathering/garden-rules.cjs). Growth is computed from server timestamps, so plots grow while you are away.
 * Pure and DOM-free; everything random takes an `rng`.
 */

export interface PlotRow {
  plot: string;
  seedId: string | null;
  /** Epoch ms when it was planted and when it is ready (both server time). */
  plantedAt: number;
  readyAt: number;
  composted: boolean;
}

export type PlotState = 'empty' | 'growing' | 'ready';

export const plotDef = (id: string): PlotDef | undefined => PLOTS.find((p) => p.id === id);

export const stateOf = (row: PlotRow | null | undefined, now: number): PlotState => (!row || !row.seedId ? 'empty' : now >= row.readyAt ? 'ready' : 'growing');

/** Real-time ms a seed takes to grow (composted plots grow 25% faster). */
export const growMs = (seed: SeedDef, composted: boolean) => Math.round(seed.growMin * 60_000 * (composted ? COMPOST_SPEED : 1));

/** Why this seed can't go in this plot right now, or null when it can. */
export function plantBlocker(plot: PlotDef | undefined, seedId: string, level: number, existing: PlotRow | null | undefined, now: number): string | null {
  const seed = seedDef(seedId);
  if (!plot) return 'There is no such plot.';
  if (!seed) return 'That cannot be planted.';
  if (seed.kind !== plot.kind) return seed.kind === 'tree' ? 'Saplings go in a Coffin Patch.' : 'Seeds go in a Mourning Bed.';
  if (level < seed.level) return `Requires Grave Gardening ${seed.level}.`;
  if (stateOf(existing, now) !== 'empty') return 'Something is already growing there.';
  return null;
}

export interface Harvest {
  itemId: string;
  qty: number;
  seedBack: string | null;
  xp: number;
}

export function rollHarvest(seed: SeedDef, rng: () => number): Harvest {
  const [lo, hi] = seed.yields;
  const qty = lo + Math.floor(rng() * (hi - lo + 1));
  return { itemId: seed.harvest, qty, seedBack: rng() < seed.seedBack ? seed.id : null, xp: seed.harvestXp };
}

/** "1h 20m", "35m", "45s" (for the countdown on a growing plot). */
export function remainingText(ms: number): string {
  const s = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h ? `${h}h ${m}m` : m ? `${m}m` : `${s}s`;
}
