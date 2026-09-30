import type { EliteAffix } from './enemies';

/**
 * Weekly Omens (docs/GRIND-LOOP.md §3 #5): one world modifier per UTC week, the same for everyone, so a co-op party and the
 * whole friends list see the same sky. They change how old zones play (a reason to go back) and nudge rewards up a little.
 * Deterministic from the date: no server state, nothing to keep in sync.
 */
export type OmenId = 'blood_moon' | 'drowned_week' | 'tolling';

export interface Omen {
  id: OmenId;
  name: string;
  /** public/art/omens/<icon>.png */
  icon: string;
  blurb: string;
  /** Added to every combat area's elite chance. */
  eliteBonus: number;
  /** Multiplies every wave's size after the arrival wave. */
  waveSizeMult: number;
  /** Multiplies the XP and the gold every kill pays. */
  rewardMult: number;
  /** Multiplies the shards an elite drops (rounded up). */
  shardMult: number;
  /** Elites arrive with this affix (their normal roll otherwise). */
  affix?: EliteAffix;
  /** The sky: moon colour and how thick the fog gets. */
  sky: { moon: number; fogMult: number };
}

export const OMENS: Record<OmenId, Omen> = {
  blood_moon: {
    id: 'blood_moon',
    name: 'Blood Moon',
    icon: 'art/omens/blood_moon.png',
    blurb: 'The moon runs red: elites are far more common, and every kill pays 15% more.',
    eliteBonus: 0.06,
    waveSizeMult: 1,
    rewardMult: 1.15,
    shardMult: 1,
    sky: { moon: 0xd8403a, fogMult: 1 },
  },
  drowned_week: {
    id: 'drowned_week',
    name: 'Drowned Week',
    icon: 'art/omens/drowned_week.png',
    blurb: 'A cold mist rolls in and the dead arrive in larger waves: 25% bigger, 20% more XP and gold.',
    eliteBonus: 0,
    waveSizeMult: 1.25,
    rewardMult: 1.2,
    shardMult: 1,
    sky: { moon: 0x6fa0d8, fogMult: 1.5 },
  },
  tolling: {
    id: 'tolling',
    name: 'The Tolling',
    icon: 'art/omens/tolling.png',
    blurb: 'Every bell in the diocese is ringing: elites come Bell-Tolled, and they drop twice the shards.',
    eliteBonus: 0.03,
    waveSizeMult: 1,
    rewardMult: 1.05,
    shardMult: 2,
    affix: 'bellTolled',
    sky: { moon: 0xd9a441, fogMult: 1.1 },
  },
};

export const OMEN_ORDER: OmenId[] = ['blood_moon', 'drowned_week', 'tolling'];

const WEEK_MS = 7 * 24 * 3600 * 1000;
/** Weeks start on Monday 00:00 UTC (1970-01-05 was the first Monday). */
const EPOCH_MS = 4 * 24 * 3600 * 1000;

export function omenWeek(now: number | Date = Date.now()): number {
  const ms = typeof now === 'number' ? now : now.getTime();
  return Math.floor((ms - EPOCH_MS) / WEEK_MS);
}

export function omenFor(now: number | Date = Date.now()): Omen {
  const w = omenWeek(now);
  return OMENS[OMEN_ORDER[((w % OMEN_ORDER.length) + OMEN_ORDER.length) % OMEN_ORDER.length]];
}

/** When the current omen gives way to the next one. */
export function omenEnds(now: number | Date = Date.now()): number {
  return EPOCH_MS + (omenWeek(now) + 1) * WEEK_MS;
}

/** "3 days" / "5 hours" / "40 minutes" left of the omen, for the HUD tooltip. */
export function omenLeft(now: number = Date.now()): string {
  const ms = Math.max(0, omenEnds(now) - now);
  const h = ms / 3600000;
  if (h >= 48) return `${Math.floor(h / 24)} days`;
  if (h >= 1) return `${Math.floor(h)} hours`;
  return `${Math.max(1, Math.floor(ms / 60000))} minutes`;
}
