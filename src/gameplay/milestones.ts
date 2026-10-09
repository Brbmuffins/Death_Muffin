import { AREAS, type AreaId } from '../../server/rules/content/areas';

/**
 * Milestones (docs/GRIND-LOOP.md §3 #9): frequent small wins at the "minutes to hours" timescale. Each pays a one-off gold
 * purse and a toast the first time a counter crosses its line. Claims are remembered per character in the browser.
 */
export interface MilestoneCounters {
  totalKills: number;
  areaKills: Partial<Record<AreaId, number>>;
  bestChain: number;
}

export interface Milestone {
  id: string;
  title: string;
  /** One line under the title. */
  text: string;
  gold: number;
  reached: (c: MilestoneCounters) => boolean;
}

const TOTALS: [number, number][] = [[100, 40], [500, 150], [1000, 300], [2500, 700], [5000, 1400], [10000, 3000], [25000, 8000]];
const AREA_LINES: [number, number][] = [[100, 60], [500, 250], [1000, 500], [2500, 1200]];
const CHAINS: [number, number][] = [[10, 50], [25, 150], [50, 400], [100, 1000]];
const fmt = (n: number) => n.toLocaleString('en-US');

export function buildMilestones(): Milestone[] {
  const out: Milestone[] = [];
  for (const [n, gold] of TOTALS) {
    out.push({ id: `kills.${n}`, title: `${fmt(n)} dead`, text: `${fmt(n)} kills across the diocese`, gold, reached: (c) => c.totalKills >= n });
  }
  for (const [id, a] of Object.entries(AREAS) as [AreaId, (typeof AREAS)[AreaId]][]) {
    if (a.safe) continue;
    for (const [n, gold] of AREA_LINES) {
      out.push({ id: `area.${id}.${n}`, title: `${a.name}: ${fmt(n)}`, text: `${fmt(n)} of the dead felled in ${a.name}`, gold, reached: (c) => (c.areaKills[id] ?? 0) >= n });
    }
  }
  for (const [n, gold] of CHAINS) {
    out.push({ id: `chain.${n}`, title: `Chain of ${n}`, text: `${n} kills in one unbroken chain`, gold, reached: (c) => c.bestChain >= n });
  }
  return out;
}

export const MILESTONES = buildMilestones();

/** Milestones newly reached (not yet in `claimed`), in list order. Pure: the caller stores the ids it pays out. */
export function newlyReached(c: MilestoneCounters, claimed: ReadonlySet<string>, list: readonly Milestone[] = MILESTONES): Milestone[] {
  return list.filter((m) => !claimed.has(m.id) && m.reached(c));
}
